#!/bin/bash
#==============================================================================
# register_domain.sh — Integração ao Active Directory via realmd/SSSD
#
# Versão 2.1 — compatível com Ubuntu 20.04/22.04/24.04, Debian 11/12 e
#               RHEL/Rocky/Alma 8/9 (detecta apt ou dnf/yum)
#
# Correções em relação à versão anterior:
#   * Não aborta silenciosamente no meio (remoção do "set -e" global)
#   * Usa "realm join --unattended" (o realmd 0.17.x do Ubuntu 24.04 não tem
#     --stdin-password; sem --unattended ele tenta ler a senha do terminal e
#     o join falha quando a execução é por script/pipeline)
#   * Valida o ingresso por "realm list", não pela existência de krb5.keytab
#     (keytab antigo de tentativa anterior gerava falso positivo)
#   * Sai do domínio com credenciais antes de reingressar (evita conta de
#     computador órfã / "Already joined to this domain")
#   * Pré-validação de DNS/SRV, relógio e portas com mensagem clara
#   * Edição idempotente do sssd.conf (sem sed que falha em silêncio)
#   * Valida o grupo no AD antes de ativar access_provider = simple
#     (evita bloquear todo o acesso por grupo inexistente)
#   * sudoers validado com visudo e sem aceitar senha como nome de grupo
#   * Home criada via pam-auth-update (Debian/Ubuntu) ou authselect (RHEL)
#
# Uso interativo:
#   sudo ./register_domain.sh
#
# Uso não interativo (variáveis de ambiente):
#   sudo DOMAIN=center.local ADMIN_USER=administrator ADMIN_GROUP=SUDOERS_HOST \
#        ADMIN_PASS_FILE=/root/.adpass ./register_domain.sh
#
#   ADMIN_PASS_FILE deve ter modo 600 e ser removido após o uso.
#==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/settings.conf"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="$LOG_DIR/register_domain_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR" 2>/dev/null || true

#------------------------------------------------------------------------------
# Saída / log
#------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET='\033[0m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'
else
    C_RESET=''; C_OK=''; C_WARN=''; C_ERR=''; C_INFO=''
fi

log()  { echo -e "${C_INFO}[INFO]${C_RESET} $*" | tee -a "$LOG_FILE" >/dev/null; echo -e "${C_INFO}[INFO]${C_RESET} $*"; }
ok()   { echo -e "${C_OK}[ OK ]${C_RESET} $*" | tee -a "$LOG_FILE" >/dev/null; echo -e "${C_OK}[ OK ]${C_RESET} $*"; }
warn() { echo -e "${C_WARN}[WARN]${C_RESET} $*" | tee -a "$LOG_FILE" >/dev/null; echo -e "${C_WARN}[WARN]${C_RESET} $*"; }
err()  { echo -e "${C_ERR}[FAIL]${C_RESET} $*" | tee -a "$LOG_FILE" >/dev/null; echo -e "${C_ERR}[FAIL]${C_RESET} $*"; }
die()  { err "$*"; echo "Log completo: $LOG_FILE"; exit 1; }

section() {
    echo "" | tee -a "$LOG_FILE" >/dev/null
    echo "==============================================================" | tee -a "$LOG_FILE" >/dev/null
    echo " $*" | tee -a "$LOG_FILE" >/dev/null
    echo "==============================================================" | tee -a "$LOG_FILE" >/dev/null
    echo ""
}

#------------------------------------------------------------------------------
# Verificações iniciais
#------------------------------------------------------------------------------
[ "$EUID" -eq 0 ] || die "Execute como root: sudo $0"
[ -r /etc/os-release ] || die "/etc/os-release não encontrado"
. /etc/os-release

# Família da distribuição e gerenciador de pacotes (mesma lógica de lib/common.sh)
case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*)                          DISTRO_FAMILY="debian" ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) DISTRO_FAMILY="rhel" ;;
    *)                                          DISTRO_FAMILY="unknown" ;;
esac

if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
else
    PKG_MGR=""
fi
[ -n "$PKG_MGR" ] || die "Nenhum gerenciador de pacotes suportado (apt/dnf/yum) encontrado."

case "$DISTRO_FAMILY" in
    debian|rhel) log "Distribuição: ${PRETTY_NAME:-$ID} (pacotes via $PKG_MGR)" ;;
    *) warn "Distribuição '${PRETTY_NAME:-${ID:-desconhecida}}' não testada; seguindo com $PKG_MGR." ;;
esac

section "Registro no Domínio — $(hostname -f 2>/dev/null || hostname)"

# Carrega defaults do projeto, se existirem
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

#------------------------------------------------------------------------------
# Coleta de parâmetros
#------------------------------------------------------------------------------
DOMAIN="${DOMAIN:-${DEFAULT_DOMAIN:-}}"
ADMIN_USER="${ADMIN_USER:-${DEFAULT_ADMIN_USER:-}}"
ADMIN_GROUP="${ADMIN_GROUP:-${DEFAULT_ADMIN_GROUP:-}}"
COMPUTER_OU="${COMPUTER_OU:-}"
COMPUTER_NAME="${COMPUTER_NAME:-${DOMAIN_COMPUTER_NAME:-}}"
ACCESS_MODE="${ACCESS_MODE:-restricted}"   # restricted | permissive
FORCE_REJOIN="${FORCE_REJOIN:-0}"

if [ -t 0 ]; then
    # Execução interativa
    if [ -z "$DOMAIN" ]; then
        read -r -p "Domínio (ex: center.local): " DOMAIN
    fi
    if [ -z "$ADMIN_USER" ]; then
        read -r -p "Usuário administrador do AD (ex: administrator): " ADMIN_USER
    fi
    if [ -z "${ADMIN_PASS_FILE:-}" ]; then
        read -r -s -p "Senha de $ADMIN_USER: " ADMIN_PASS
        echo ""
        read -r -s -p "Confirme a senha: " ADMIN_PASS2
        echo ""
        [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] || die "As senhas não conferem"
        unset ADMIN_PASS2
    fi
    if [ -z "$ADMIN_GROUP" ]; then
        echo ""
        echo "Grupo do AD que terá login SSH e sudo neste servidor."
        echo "Padrão do ambiente: SUDOERS_$(hostname -s | tr '[:lower:]' '[:upper:]')"
        read -r -p "Grupo [SUDOERS_$(hostname -s | tr '[:lower:]' '[:upper:]')]: " ADMIN_GROUP
        ADMIN_GROUP="${ADMIN_GROUP:-SUDOERS_$(hostname -s | tr '[:lower:]' '[:upper:]')}"
    fi
    if [ -z "$COMPUTER_OU" ]; then
        read -r -p "OU do computador no AD (vazio = padrão CN=Computers): " COMPUTER_OU
    fi
fi

if [ -z "${ADMIN_PASS:-}" ] && [ -n "${ADMIN_PASS_FILE:-}" ]; then
    [ -r "$ADMIN_PASS_FILE" ] || die "ADMIN_PASS_FILE não legível: $ADMIN_PASS_FILE"
    ADMIN_PASS="$(head -n1 "$ADMIN_PASS_FILE")"
fi

[ -n "$DOMAIN" ]      || die "Domínio não informado (DOMAIN=...)"
[ -n "$ADMIN_USER" ]  || die "Usuário administrador não informado (ADMIN_USER=...)"
[ -n "${ADMIN_PASS:-}" ] || die "Senha não informada (ADMIN_PASS_FILE=...)"
[ -n "$ADMIN_GROUP" ] || die "Grupo não informado (ADMIN_GROUP=...)"

# O grupo vai para o sudoers. Recusar valores que claramente não são grupo
# (a versão antiga permitia a senha cair aqui e gravava "%!q2w3e4r").
if ! printf '%s' "$ADMIN_GROUP" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    die "Nome de grupo inválido: '$ADMIN_GROUP'. Use apenas letras, números, ponto, hífen e underscore."
fi
case "$ADMIN_GROUP" in
    *senha*|*password*|*\!*|*@*|*\**) die "Nome de grupo inválido: '$ADMIN_GROUP'" ;;
esac

REALM="$(printf '%s' "$DOMAIN" | tr '[:lower:]' '[:upper:]')"

log "Domínio.........: $DOMAIN ($REALM)"
log "Administrador...: $ADMIN_USER"
log "Grupo de acesso.: $ADMIN_GROUP"
log "Hostname........: $(hostname -s)"
[ -n "$COMPUTER_OU" ] && log "OU..............: $COMPUTER_OU"
log "Log.............: $LOG_FILE"

#------------------------------------------------------------------------------
# 1. Pacotes
#------------------------------------------------------------------------------
section "1/8 — Pacotes"

export DEBIAN_FRONTEND=noninteractive

pkg_installed() {
    case "$PKG_MGR" in
        apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
        *)   rpm -q "$1" >/dev/null 2>&1 ;;
    esac
}

if [ "$DISTRO_FAMILY" = "rhel" ]; then
    PACKAGES=(
        realmd sssd sssd-ad sssd-tools adcli samba-common-tools
        oddjob oddjob-mkhomedir krb5-workstation
    )
else
    PACKAGES=(
        realmd sssd sssd-tools libnss-sss libpam-sss adcli
        samba-common-bin oddjob oddjob-mkhomedir krb5-user
    )
fi

log "Atualizando índice de pacotes..."
case "$PKG_MGR" in
    apt) apt-get update -qq || warn "apt-get update retornou erro; tentando instalar com o índice atual." ;;
    dnf) dnf -q makecache || warn "dnf makecache retornou erro; tentando com o cache atual." ;;
    yum) yum -q makecache || warn "yum makecache retornou erro; tentando com o cache atual." ;;
esac

missing=()
for p in "${PACKAGES[@]}"; do
    pkg_installed "$p" || missing+=("$p")
done

if [ ${#missing[@]} -gt 0 ]; then
    log "Instalando: ${missing[*]}"
    case "$PKG_MGR" in
        apt) apt-get install -y --no-install-recommends "${missing[@]}" \
                || die "Falha ao instalar pacotes. Verifique repositórios: apt-get update && apt-get install -f" ;;
        dnf) dnf install -y "${missing[@]}" \
                || die "Falha ao instalar pacotes. Verifique repositórios: dnf makecache && dnf install -f" ;;
        yum) yum install -y "${missing[@]}" \
                || die "Falha ao instalar pacotes. Verifique repositórios: yum makecache && yum install -f" ;;
    esac
else
    ok "Todos os pacotes já estão instalados."
fi

# sssd-ad é dependência do metapacote sssd, mas garantimos explicitamente:
if [ "$DISTRO_FAMILY" != "rhel" ]; then
    pkg_installed sssd-ad || apt-get install -y sssd-ad || warn "Não foi possível instalar sssd-ad; o provedor AD pode faltar."
fi

ok "Pacotes prontos."

#------------------------------------------------------------------------------
# 2. Pré-requisitos de rede
#------------------------------------------------------------------------------
section "2/8 — DNS, relógio e conectividade"

# 2.1 DNS resolve o domínio
if getent hosts "$DOMAIN" >/dev/null 2>&1; then
    ok "DNS resolve $DOMAIN ($(getent hosts "$DOMAIN" | awk '{print $1}' | tr '\n' ' '))"
else
    err "DNS não resolve $DOMAIN"
    echo "   Ajuste /etc/resolv.conf ou o systemd-resolved para apontar para os DCs."
    echo "   DCs conhecidos: $(getent hosts spoad12.center.local spoad13.center.local 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    die "Corrija o DNS antes de continuar."
fi

# 2.2 Registros SRV (necessários para o realm discover)
if command -v dig >/dev/null 2>&1; then
    if dig +short SRV "_ldap._tcp.dc._msdcs.$DOMAIN" | grep -q "389"; then
        ok "Registros SRV _ldap._tcp.dc._msdcs.$DOMAIN presentes."
    else
        warn "Nenhum SRV _ldap._tcp.dc._msdcs.$DOMAIN encontrado. O 'realm discover' pode falhar."
    fi
fi

# 2.3 Relógio (Kerberos tolera no máximo 5 minutos de diferença)
if command -v timedatectl >/dev/null 2>&1; then
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]; then
        warn "Relógio não sincronizado. Diferença acima de 5 min quebra o Kerberos."
        warn "Corrija com: timedatectl set-ntp true  (ou configure o chrony/systemd-timesyncd)"
    else
        ok "Relógio sincronizado."
    fi
fi

# 2.4 Portas dos DCs (usa os alvos SRV, não o primeiro A de center.local)
DC_LIST=""
if command -v dig >/dev/null 2>&1; then
    DC_LIST="$(dig +short SRV "_ldap._tcp.dc._msdcs.$DOMAIN" 2>/dev/null \
        | awk '{print $NF}' | sed 's/\.$//' | sort -u)"
fi
[ -n "$DC_LIST" ] || DC_LIST="$DOMAIN"

for port in 88 389 445; do
    port_ok=0
    for dc in $DC_LIST; do
        dc_ip="$(getent hosts "$dc" | awk '{print $1}' | head -n1)"
        [ -n "$dc_ip" ] || continue
        if timeout 5 bash -c "echo > /dev/tcp/$dc_ip/$port" 2>/dev/null; then
            port_ok=1
            break
        fi
    done
    if [ "$port_ok" -eq 1 ]; then
        ok "Porta $port acessível em um DC ($DC_LIST)"
    else
        warn "Porta $port não respondeu em nenhum DC ($DC_LIST). O join pode falhar."
    fi
done

#------------------------------------------------------------------------------
# 3. Kerberos
#------------------------------------------------------------------------------
section "3/8 — Kerberos"

backup_file() {
    [ -f "$1" ] && cp -a "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)"
    return 0
}

if [ -f /etc/krb5.conf ] && grep -q "default_realm" /etc/krb5.conf; then
    backup_file /etc/krb5.conf
fi

cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    forwardable = true
    default_ccache_name = KEYRING:persistent:%{uid}

[realms]
    $REALM = {
        kdc = $DOMAIN
        admin_server = $DOMAIN
    }

[domain_realm]
    .$DOMAIN = $REALM
    $DOMAIN = $REALM
EOF

ok "/etc/krb5.conf gravado."

#------------------------------------------------------------------------------
# 4. Descobrir o domínio
#------------------------------------------------------------------------------
section "4/8 — realm discover"

DISCOVER_OUT="$(realm discover "$DOMAIN" 2>&1)"
DISCOVER_RC=$?
if [ $DISCOVER_RC -ne 0 ]; then
    err "realm discover $DOMAIN falhou (rc=$DISCOVER_RC):"
    echo "$DISCOVER_OUT" | sed 's/^/   /'
    echo ""
    echo "Causas comuns:"
    echo "  * DNS não aponta para os DCs (verifique /etc/resolv.conf)"
    echo "  * Registros SRV ausentes (_ldap._tcp.dc._msdcs.$DOMAIN)"
    echo "  * Relógio fora de sincronia"
    die "Corrija a descoberta antes do join."
fi
ok "Domínio descoberto."
echo "$DISCOVER_OUT" | sed 's/^/   /'

#------------------------------------------------------------------------------
# 5. Ingresso
#------------------------------------------------------------------------------
section "5/8 — realm join"

JOIN_OPTS=(--user="$ADMIN_USER" --unattended --verbose)
[ -n "$COMPUTER_OU" ]   && JOIN_OPTS+=(--computer-ou="$COMPUTER_OU")
[ -n "$COMPUTER_NAME" ] && JOIN_OPTS+=(--computer-name="$COMPUTER_NAME")

already_joined() { realm list 2>/dev/null | grep -qx "$DOMAIN"; }

if already_joined && [ "$FORCE_REJOIN" != "1" ]; then
    ok "Host já está ingressado em $DOMAIN. Reingresso não necessário (FORCE_REJOIN=1 para forçar)."
else
    if realm list 2>/dev/null | grep -q .; then
        log "Saindo do domínio atual antes de reingressar..."
        if printf '%s\n' "$ADMIN_PASS" | realm leave --user="$ADMIN_USER" --unattended "$DOMAIN" 2>&1 | tee -a "$LOG_FILE"; then
            ok "Saída do domínio concluída."
        else
            warn "realm leave falhou; removendo keytab antigo e seguindo."
            rm -f /etc/krb5.keytab
        fi
    fi

    systemctl stop sssd 2>/dev/null || true
    rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true

    log "Ingressando em $DOMAIN como $ADMIN_USER ..."
    JOIN_OUT="$(printf '%s\n' "$ADMIN_PASS" | realm join "${JOIN_OPTS[@]}" "$DOMAIN" 2>&1)"
    JOIN_RC=$?

    if [ $JOIN_RC -ne 0 ]; then
        err "Falha no ingresso (rc=$JOIN_RC):"
        echo "$JOIN_OUT" | sed 's/^/   /'
        echo ""
        case "$JOIN_OUT" in
            *"Couldn't authenticate"*|*"Preauthentication failed"*|*"Password"*)
                echo ">> Usuário ou senha do AD recusados. Confirme a conta e se ela não está bloqueada/expirada." ;;
            *"Already joined"*|*"already exists"*)
                echo ">> Conta de computador já existe no AD. Use FORCE_REJOIN=1 ou peça ao time de AD para remover o objeto." ;;
            *"Clock skew"*|*"clocks"*)
                echo ">> Relógio fora de sincronia. Ajuste o NTP e tente novamente." ;;
            *"Failed to create computer account"*|*"Insufficient access"*)
                echo ">> Sem permissão para criar a conta de computador. Informe COMPUTER_OU ou use uma conta com delegação." ;;
            *"No such realm"*|*"Cannot contact"*)
                echo ">> DC inacessível. Verifique DNS e as portas 88/389/445." ;;
        esac
        die "Ingresso não concluído. Nada foi alterado em sssd/sudoers."
    fi

    ok "Ingresso concluído."
    [ -n "$JOIN_OUT" ] && echo "$JOIN_OUT" | sed 's/^/   /'
fi

# Validação real do ingresso (não usar existência de keytab como prova)
if ! realm list 2>/dev/null | grep -qx "$DOMAIN"; then
    die "realm list não confirma $DOMAIN. Ingresso inválido."
fi
if ! klist -k /etc/krb5.keytab 2>/dev/null | grep -qi "host/$(hostname -s)"; then
    warn "Keytab não contém o principal host/$(hostname -s). Verifique o nome do computador no AD."
else
    ok "Keytab válido para host/$(hostname -s)."
fi

#------------------------------------------------------------------------------
# 6. SSSD
#------------------------------------------------------------------------------
section "6/8 — SSSD"

SSSD_CONF=/etc/sssd/sssd.conf
[ -f "$SSSD_CONF" ] || die "$SSSD_CONF não existe. O join não gerou a configuração."
backup_file "$SSSD_CONF"

# Detecta a seção de domínio real (realmd pode gravar em maiúsculas/minúsculas)
SSSD_SECTION="$(grep -oE '^\[domain/[^]]+\]' "$SSSD_CONF" | head -n1)"
[ -n "$SSSD_SECTION" ] || SSSD_SECTION="[domain/$DOMAIN]"
log "Seção SSSD: $SSSD_SECTION"

# Seta/atualiza uma chave dentro da seção do domínio, sem duplicar.
sssd_set() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp)"
    awk -v section="$SSSD_SECTION" -v key="$key" -v value="$value" '
        BEGIN { insec = 0; wrote = 0 }
        /^\[/ {
            if (insec && !wrote) { print key " = " value; wrote = 1 }
            insec = ($0 == section)
        }
        {
            if (insec && !wrote && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
                print key " = " value
                wrote = 1
                next
            }
            print
        }
        END { if (insec && !wrote) print key " = " value }
    ' "$SSSD_CONF" > "$tmp" && cat "$tmp" > "$SSSD_CONF"
    rm -f "$tmp"
}

sssd_set use_fully_qualified_names False
sssd_set fallback_homedir /home/%u
sssd_set default_shell /bin/bash
sssd_set cache_credentials True
sssd_set ldap_id_mapping True

chmod 600 "$SSSD_CONF"

# Remove qualquer resíduo de tentativa anterior que possa bloquear acesso
if grep -q '^simple_allow_groups' "$SSSD_CONF"; then
    log "simple_allow_groups existente será reavaliado após o restart do SSSD."
fi

log "Reiniciando SSSD..."
systemctl enable sssd >/dev/null 2>&1 || true
systemctl restart sssd || die "Falha ao reiniciar o SSSD. Veja: journalctl -u sssd -n 80"
sleep 2
if ! systemctl is-active --quiet sssd; then
    journalctl -u sssd -n 40 --no-pager | sed 's/^/   /'
    die "SSSD não está ativo."
fi
ok "SSSD ativo."

#------------------------------------------------------------------------------
# 7. Controle de acesso e sudo
#------------------------------------------------------------------------------
section "7/8 — Grupo de acesso e sudoers"

# 7.1 O grupo precisa resolver via SSSD antes de ser usado como filtro.
GROUP_OK=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if getent group "$ADMIN_GROUP" >/dev/null 2>&1; then
        GROUP_OK=1
        break
    fi
    sleep 1
done

if [ "$GROUP_OK" -eq 1 ]; then
    ok "Grupo '$ADMIN_GROUP' resolvido pelo SSSD."
else
    err "Grupo '$ADMIN_GROUP' NÃO foi encontrado no AD."
    echo "   Grupos SUDOERS existentes podem ser consultados no AD."
    echo "   Se o nome estiver errado, o acesso ficaria bloqueado — abortando sem alterar o acesso."
    die "Grupo inexistente: $ADMIN_GROUP"
fi

# 7.2 Política de login
if [ "$ACCESS_MODE" = "permissive" ]; then
    warn "ACCESS_MODE=permissive: qualquer usuário do domínio poderá autenticar."
    log "Removendo restrição de grupo..."
    # Mantém o grupo no sudoers, mas libera autenticação para todo o domínio.
    if grep -q '^access_provider' "$SSSD_CONF"; then
        sssd_set access_provider permit
    fi
    if grep -q '^simple_allow_groups' "$SSSD_CONF"; then
        sed -i 's/^simple_allow_groups/#simple_allow_groups/' "$SSSD_CONF"
    fi
else
    log "Restringindo login ao grupo '$ADMIN_GROUP' ..."
    sssd_set access_provider simple
    sssd_set simple_allow_groups "$ADMIN_GROUP"
fi

systemctl restart sssd || die "Falha ao reiniciar o SSSD após ajustar o acesso."
sleep 2
systemctl is-active --quiet sssd || die "SSSD não subiu após ajuste de acesso."

if [ "$ACCESS_MODE" != "permissive" ]; then
    if getent group "$ADMIN_GROUP" >/dev/null 2>&1; then
        ok "Login restrito a '$ADMIN_GROUP'."
    else
        die "Grupo deixou de resolver após aplicar o filtro. Reverta o sssd.conf a partir do backup."
    fi
fi

# 7.3 sudoers
SUDOERS_FILE=/etc/sudoers.d/sudoers
if [ -f "$SUDOERS_FILE" ]; then
    backup_file "$SUDOERS_FILE"
    # Preserva regras de outros grupos, remove apenas a linha deste grupo.
    grep -v "^%${ADMIN_GROUP}[[:space:]]" "$SUDOERS_FILE" > "${SUDOERS_FILE}.tmp" || true
    mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
else
    : > "$SUDOERS_FILE"
fi

echo "%${ADMIN_GROUP} ALL=(ALL) ALL" >> "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"

if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
    ok "sudoers válido: %$ADMIN_GROUP ALL=(ALL) ALL"
else
    err "Arquivo sudoers inválido — removendo para não quebrar o sudo."
    visudo -c -f "$SUDOERS_FILE" 2>&1 | sed 's/^/   /'
    rm -f "$SUDOERS_FILE"
    die "sudoers não aplicado."
fi

# 7.4 Home directory no primeiro login e nsswitch
case "$DISTRO_FAMILY" in
    rhel)
        # RHEL/Rocky/Alma: o authselect gerencia PAM e nsswitch em conjunto
        if command -v authselect >/dev/null 2>&1; then
            if authselect select sssd with-mkhomedir --force >/dev/null 2>&1; then
                ok "authselect: perfil 'sssd with-mkhomedir' aplicado."
            else
                warn "authselect falhou; habilite mkhomedir manualmente."
            fi
        elif command -v authconfig >/dev/null 2>&1; then
            if authconfig --enablemkhomedir --update >/dev/null 2>&1; then
                ok "authconfig: mkhomedir habilitado."
            else
                warn "authconfig falhou."
            fi
        else
            warn "authselect/authconfig ausentes; mkhomedir não configurado."
        fi
        ok "nsswitch.conf gerenciado pelo authselect."
        ;;
    *)
        if [ -f /usr/share/pam-configs/mkhomedir ]; then
            if pam-auth-update --enable mkhomedir >/dev/null 2>&1; then
                ok "pam_mkhomedir habilitado (pam-auth-update)."
            else
                warn "pam-auth-update --enable mkhomedir falhou."
            fi
        elif ! grep -q "pam_mkhomedir.so" /etc/pam.d/common-session 2>/dev/null; then
            echo "session optional pam_mkhomedir.so skel=/etc/skel umask=0077" >> /etc/pam.d/common-session
            ok "pam_mkhomedir adicionado em /etc/pam.d/common-session."
        else
            ok "pam_mkhomedir já configurado."
        fi

        # nsswitch idempotente
        for db in passwd group shadow; do
            if ! grep -Eq "^${db}:.*\bsss\b" /etc/nsswitch.conf; then
                sed -i "s/^${db}:.*/& sss/" /etc/nsswitch.conf
                log "nsswitch: '$db' agora usa sss."
            fi
        done
        ok "nsswitch.conf consistente."
        ;;
esac

#------------------------------------------------------------------------------
# 8. Verificação
#------------------------------------------------------------------------------
section "8/8 — Verificação"

echo "realm list:"
realm list | sed 's/^/   /'
echo ""

echo "sssd.conf (seção do domínio):"
awk -v s="$SSSD_SECTION" '$0==s{p=1} p{print "   "$0} p&&$0!=s&&/^\[/{exit}' "$SSSD_CONF"
echo ""

if getent group "$ADMIN_GROUP" >/dev/null 2>&1; then
    ok "getent group $ADMIN_GROUP -> OK"
else
    err "getent group $ADMIN_GROUP -> FALHOU"
fi

echo ""
echo "Teste de sudo para um membro do grupo (exemplo):"
echo "   sudo -l -U <usuario.do.dominio>"
echo ""
echo "Teste de login:"
echo "   ssh <usuario.do.dominio>@$(hostname -f 2>/dev/null || hostname)"
echo ""

if [ "$ACCESS_MODE" != "permissive" ]; then
    echo -e "${C_WARN}IMPORTANTE:${C_RESET} somente membros de '$ADMIN_GROUP' podem autenticar."
    echo "             O acesso local de root/console permanece disponível."
else
    echo -e "${C_WARN}IMPORTANTE:${C_RESET} modo permissivo — qualquer usuário do domínio autentica."
fi

section "Concluído"
echo "Domínio......: $DOMAIN"
echo "Grupo........: $ADMIN_GROUP"
echo "sudoers......: $SUDOERS_FILE"
echo "Log..........: $LOG_FILE"
echo ""

exit 0
