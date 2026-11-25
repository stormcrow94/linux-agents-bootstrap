#!/bin/bash
#==============================================================================
# bootstrap.sh — instalação rápida a partir do GitHub
#
# Baixa este repositório para /opt/shell-install-applications-script e executa
# o instalador. Não grava credenciais e não altera nada antes de baixar.
#
# Uso (a forma mais simples):
#   curl -fsSL https://raw.githubusercontent.com/stormcrow94/shell-install-applications-script/main/bootstrap.sh -o /tmp/bootstrap.sh
#   sudo bash /tmp/bootstrap.sh
#
# Execução direta de uma etapa:
#   sudo bash /tmp/bootstrap.sh --domain
#   sudo bash /tmp/bootstrap.sh --zabbix
#   sudo bash /tmp/bootstrap.sh --wazuh
#   sudo bash /tmp/bootstrap.sh --sophos
#   sudo bash /tmp/bootstrap.sh --hostname
#
# Variáveis para o registro no domínio (não interativo):
#   sudo DOMAIN=center.local ADMIN_USER=fortigate ADMIN_GROUP=SUDOERS_SERVIDOR \
#        ADMIN_PASS_FILE=/root/.adpass COMPUTER_OU='OU=Computadores,DC=center,DC=local' \
#        bash /tmp/bootstrap.sh --domain
#
# Opções:
#   --repo <owner/repo>   Repositório alternativo (padrão: stormcrow94/...)
#   --branch <nome>       Branch alternativo (padrão: main)
#   --dir <caminho>       Destino (padrão: /opt/shell-install-applications-script)
#==============================================================================

set -uo pipefail

ORIG_ARGS=("$@")

REPO="${REPO:-stormcrow94/shell-install-applications-script}"
BRANCH="${BRANCH:-main}"
RUN_DIR="${RUN_DIR:-/opt/shell-install-applications-script}"
MODE="menu"
KEEP_SETTINGS=0
DOWNLOAD_ONLY=0

C_OK='\033[0;32m'; C_ERR='\033[0;31m'; C_WARN='\033[1;33m'; C_INFO='\033[0;36m'; C_RESET='\033[0m'
ok()   { echo -e "${C_OK}[ OK ]${C_RESET} $*"; }
err()  { echo -e "${C_ERR}[FAIL]${C_RESET} $*" >&2; }
warn() { echo -e "${C_WARN}[WARN]${C_RESET} $*"; }
info() { echo -e "${C_INFO}[INFO]${C_RESET} $*"; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
bootstrap.sh — instalação rápida a partir do GitHub

Uso:
  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/bootstrap.sh -o /tmp/bootstrap.sh
  sudo bash /tmp/bootstrap.sh

Modos:
  (sem argumento)       abre o menu do instalador
  --domain              executa somente o registro no domínio
  --zabbix              instala o Zabbix Agent
  --wazuh               instala o Wazuh Agent
  --sophos              instala o Sophos
  --hostname            configura o hostname

Opções:
  --repo <owner/repo>   repositório alternativo
  --branch <nome>       branch alternativo (padrão: main)
  --dir <caminho>       destino (padrão: /opt/shell-install-applications-script)
  --keep-settings       preserva config/settings.conf já existente
  --download-only       baixa os arquivos e não executa nada
  -h, --help            esta ajuda
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --domain|--dominio) MODE="domain" ;;
        --zabbix)           MODE="zabbix" ;;
        --wazuh)            MODE="wazuh" ;;
        --sophos)           MODE="sophos" ;;
        --hostname)         MODE="hostname" ;;
        --menu)             MODE="menu" ;;
        --repo)             REPO="${2:?}"; shift ;;
        --branch)           BRANCH="${2:?}"; shift ;;
        --dir)              RUN_DIR="${2:?}"; shift ;;
        --keep-settings)    KEEP_SETTINGS=1 ;;
        --download-only)    DOWNLOAD_ONLY=1 ;;
        -h|--help)          usage ;;
        *) die "Opção desconhecida: $1 (use --help)" ;;
    esac
    shift
done

# Eleva para root preservando o ambiente e o terminal (necessário para prompts)
if [ "$EUID" -ne 0 ]; then
    info "Elevando privilégios com sudo..."
    exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
fi

command -v tar >/dev/null 2>&1 || die "tar não encontrado."

fetch() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        die "curl ou wget é necessário para baixar o repositório."
    fi
}

TARBALL_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"
TMP_DIR="$(mktemp -d)" || die "Não foi possível criar diretório temporário."
trap 'rm -rf "$TMP_DIR"' EXIT

info "Baixando ${REPO} (${BRANCH})..."
fetch "$TARBALL_URL" "$TMP_DIR/repo.tar.gz" || die "Falha ao baixar $TARBALL_URL"

tar -xzf "$TMP_DIR/repo.tar.gz" -C "$TMP_DIR" || die "Falha ao extrair o pacote."
SRC_DIR="$(find "$TMP_DIR" -maxdepth 1 -mindepth 1 -type d -name '*-*' | head -n1)"
[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || die "Estrutura do pacote inesperada."

# Preserva configuração local existente (proxy, servidores Zabbix/Wazuh, etc.)
if [ -f "$RUN_DIR/config/settings.conf" ] && [ "$KEEP_SETTINGS" -eq 1 ]; then
    cp -a "$RUN_DIR/config/settings.conf" "$TMP_DIR/settings.conf.keep"
    warn "settings.conf existente será preservado."
fi

mkdir -p "$RUN_DIR" || die "Não foi possível criar $RUN_DIR"
cp -a "$SRC_DIR"/. "$RUN_DIR"/ || die "Falha ao copiar os arquivos para $RUN_DIR"
if [ -f "$TMP_DIR/settings.conf.keep" ]; then
    cp -a "$TMP_DIR/settings.conf.keep" "$RUN_DIR/config/settings.conf"
fi

chmod +x "$RUN_DIR"/*.sh 2>/dev/null
ok "Arquivos prontos em $RUN_DIR"

if [ "$DOWNLOAD_ONLY" -eq 1 ]; then
    info "Download concluído (--download-only); nada foi executado."
    rm -rf "$TMP_DIR"; trap - EXIT
    exit 0
fi

cd "$RUN_DIR" || die "Não foi possível entrar em $RUN_DIR"
rm -rf "$TMP_DIR"
trap - EXIT

case "$MODE" in
    menu)     info "Abrindo o menu do instalador..."; exec bash ./installer.sh ;;
    domain)   exec bash ./register_domain.sh ;;
    zabbix)   exec bash ./install_zabbix.sh ;;
    wazuh)    exec bash ./install_wazuh.sh ;;
    sophos)   exec bash ./SophosSetup.sh ;;
    hostname) exec bash ./hostname.sh ;;
    *)        die "Modo inválido: $MODE" ;;
esac
