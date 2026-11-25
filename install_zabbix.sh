#!/bin/bash

#==============================================================================
# Script de Instalação do Zabbix Agent
# Detecta automaticamente a distribuição e instala o agente Zabbix apropriado
# Pode ser executado individualmente ou através do menu principal
#==============================================================================

# Obter o diretório do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carregar biblioteca de funções comuns
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    source "$SCRIPT_DIR/lib/common.sh"
else
    echo "ERRO: Biblioteca comum não encontrada em $SCRIPT_DIR/lib/common.sh"
    exit 1
fi

# Carregar configurações
if [ -f "$SCRIPT_DIR/config/settings.conf" ]; then
    source "$SCRIPT_DIR/config/settings.conf"
else
    print_warning "Arquivo de configuração não encontrado, usando valores padrão"
    ZABBIX_PROXY_SERVER="zabbix.example.com"
    ZABBIX_SERVER_PORT="10051"
    ZABBIX_AGENT_PORT="10050"
    ZABBIX_DEBUG_LEVEL="3"
    ZABBIX_LOG_SIZE="10"
    ZABBIX_BRANCH="7.0"
    ZABBIX_AGENT_VERSION="latest"
    ZABBIX_STATIC_AGENT_URL=""
    ZABBIX_RPM_BRANCH="7.0"
fi

# Modo de instalacao em Debian/Ubuntu (pode ser definido em config/settings.conf):
#   auto    - tenta o pacote oficial e cai para o tarball estatico se falhar (padrao)
#   package - somente pacote oficial; falha se o repositorio nao responder
#   static  - somente tarball estatico (comportamento anterior)
ZABBIX_INSTALL_MODE="${ZABBIX_INSTALL_MODE:-auto}"

#==============================================================================
# Funções Específicas do Zabbix
#==============================================================================

# Caminho do PidFile (alinhado ao unit systemd)
get_zabbix_pid_file() {
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        echo "/var/run/zabbix/zabbix_agentd.pid"
    else
        echo "/run/zabbix/zabbix_agentd.pid"
    fi
}

# Ultima versao <branch>.x publicada no CDN oficial (ex.: 7.0.32)
zabbix_latest_patch() {
    local branch="$1" page ver pattern
    pattern="$(printf '%s' "$branch" | sed 's/\./\\./g')\.[0-9]+"
    if command -v curl &>/dev/null; then
        page=$(curl -fsSL --connect-timeout 10 --max-time 25 "https://cdn.zabbix.com/zabbix/binaries/stable/${branch}/" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        page=$(wget -qO- --timeout=25 "https://cdn.zabbix.com/zabbix/binaries/stable/${branch}/" 2>/dev/null)
    fi
    [ -n "${page:-}" ] || return 1
    ver=$(printf '%s\n' "$page" | grep -oE "$pattern" | sort -t. -k3,3n -u | tail -n1)
    [ -n "$ver" ] || return 1
    printf '%s' "$ver"
}

# Resolve a URL do tarball estatico:
#   1. ZABBIX_STATIC_AGENT_URL, se definido (pin manual)
#   2. ZABBIX_AGENT_VERSION, se nao for "latest"
#   3. ultima versao do branch no CDN (padrao)
resolve_zabbix_static_url() {
    local branch="${ZABBIX_BRANCH:-7.0}"
    local version="${ZABBIX_AGENT_VERSION:-latest}"
    local fallback="7.0.32"

    if [ -n "${ZABBIX_STATIC_AGENT_URL:-}" ]; then
        printf '%s' "$ZABBIX_STATIC_AGENT_URL"
        return 0
    fi

    if [ "$version" = "latest" ]; then
        version="$(zabbix_latest_patch "$branch")" || version=""
        if [ -z "$version" ]; then
            if [ "$branch" = "7.0" ]; then
                version="$fallback"
                print_warning "CDN do Zabbix indisponivel; usando $version (ultima conhecida)." >&2
            else
                print_error "Nao foi possivel descobrir a ultima versao do branch $branch." >&2
                return 1
            fi
        fi
    fi

    printf 'https://cdn.zabbix.com/zabbix/binaries/stable/%s/%s/zabbix_agent-%s-linux-3.0-amd64-static.tar.gz' \
        "$branch" "$version" "$version"
}

# Remover pacote zabbix-agent do sistema de pacotes, se existir.
# Sem isso, apt/dnf pode sobrescrever /usr/sbin/zabbix_agentd numa atualização futura.
remove_zabbix_agent_package_if_installed() {
    case "$DISTRO" in
        ubuntu|debian)
            if dpkg -l zabbix-agent 2>/dev/null | grep -q '^ii'; then
                print_info "Removendo pacote zabbix-agent (migração ou atualização para binário estático)..."
                log_info "Removendo pacote zabbix-agent (Debian/Ubuntu)"
                apt-get remove -y zabbix-agent >> "$LOG_FILE" 2>&1 || {
                    print_warning "Não foi possível remover o pacote zabbix-agent; o binário estático ainda será instalado"
                    log_warning "apt-get remove zabbix-agent falhou"
                }
            fi
            ;;
        rhel|centos|rocky|almalinux)
            if rpm -q zabbix-agent &>/dev/null; then
                print_info "Removendo pacote zabbix-agent (migração ou atualização para binário estático)..."
                log_info "Removendo pacote zabbix-agent (RHEL)"
                local pkg_manager
                pkg_manager=$(get_package_manager)
                $pkg_manager remove -y zabbix-agent >> "$LOG_FILE" 2>&1 || {
                    print_warning "Não foi possível remover o pacote zabbix-agent; o binário estático ainda será instalado"
                    log_warning "dnf/yum remove zabbix-agent falhou"
                }
            fi
            ;;
    esac
}

# Instalar zabbix-agent pelo repositorio oficial .deb (Debian/Ubuntu).
# Usa o pacote distribuido (com TLS/IPv6 e libs do sistema) em vez do tarball estatico.
# Preserva a configuracao existente (--force-confold); o create_zabbix_config roda depois.
install_zabbix_package_debian() {
    local branch os_id version_id release_url deb_path unit_backup ts

    branch="${ZABBIX_BRANCH:-7.0}"
    os_id=$(. /etc/os-release 2>/dev/null && echo "$ID")
    version_id=$(. /etc/os-release 2>/dev/null && echo "$VERSION_ID")
    ts=$(date +%Y%m%d_%H%M%S)

    case "$os_id" in
        ubuntu|debian) ;;
        *)
            print_error "Modo pacote suportado apenas em Debian/Ubuntu (detectado: ${os_id:-desconhecido})"
            return 1
            ;;
    esac
    if [ -z "$version_id" ]; then
        print_error "Nao foi possivel ler VERSION_ID de /etc/os-release"
        return 1
    fi

    print_info "Instalando Zabbix Agent via repositorio oficial (${os_id} ${version_id}, branch ${branch})..."
    log_info "Instalacao via pacote: os=${os_id} versao=${version_id} branch=${branch}"

    release_url="https://repo.zabbix.com/zabbix/${branch}/${os_id}/pool/main/z/zabbix-release/zabbix-release_latest_${branch}+${os_id}${version_id}_all.deb"
    deb_path="/tmp/zabbix-release-${branch}-${os_id}${version_id}.deb"
    rm -f "$deb_path"

    print_info "Baixando zabbix-release..."
    if ! download_zabbix_tarball "$release_url" "$deb_path"; then
        print_error "Falha ao baixar $release_url"
        log_error "Download do zabbix-release falhou: $release_url"
        rm -f "$deb_path"
        return 1
    fi
    if ! dpkg -i "$deb_path" >> "$LOG_FILE" 2>&1; then
        print_error "Falha ao instalar zabbix-release"
        log_error "dpkg -i zabbix-release falhou"
        rm -f "$deb_path"
        return 1
    fi
    rm -f "$deb_path"

    print_info "Atualizando indices do apt..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update >> "$LOG_FILE" 2>&1; then
        print_warning "apt-get update retornou erro; tentando instalar o pacote mesmo assim"
        log_warning "apt-get update falhou"
    fi

    print_info "Instalando pacote zabbix-agent (mantendo configuracao atual)..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::="--force-confold" \
            -o Dpkg::Options::="--force-confdef" \
            zabbix-agent >> "$LOG_FILE" 2>&1; then
        print_error "Falha ao instalar o pacote zabbix-agent"
        log_error "apt-get install zabbix-agent falhou"
        return 1
    fi

    if ! dpkg -l zabbix-agent 2>/dev/null | grep -q '^ii'; then
        print_error "Pacote zabbix-agent nao consta como instalado apos o apt"
        log_error "zabbix-agent ausente em dpkg -l apos a instalacao"
        return 1
    fi

    # Diretorios usados pela configuracao gerada pelo instalador
    mkdir -p /var/log/zabbix /etc/zabbix/zabbix_agentd.d >> "$LOG_FILE" 2>&1
    chown -R zabbix:zabbix /var/log/zabbix /etc/zabbix/zabbix_agentd.d >> "$LOG_FILE" 2>&1 || true

    # O unit criado pelo instalador estatico tem precedencia sobre o unit do pacote.
    # Sem remove-lo, o systemd continuaria usando Type=simple do /etc/systemd/system.
    if [ -f /etc/systemd/system/zabbix-agent.service ]; then
        unit_backup="/etc/systemd/system/zabbix-agent.service.bak.${ts}"
        print_info "Removendo unit do instalador estatico (backup: $unit_backup)..."
        log_info "Unit customizado movido para $unit_backup"
        if cp -a /etc/systemd/system/zabbix-agent.service "$unit_backup" >> "$LOG_FILE" 2>&1; then
            rm -f /etc/systemd/system/zabbix-agent.service
        else
            print_warning "Nao foi possivel salvar backup do unit; mantendo o unit atual"
            log_warning "Backup do unit customizado falhou; unit preservado"
        fi
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
        systemctl reset-failed zabbix-agent >> "$LOG_FILE" 2>&1 || true
    fi

    print_success "Zabbix Agent instalado a partir do repositorio oficial (deb)"
    log_success "zabbix-agent instalado via pacote oficial"
    return 0
}

# Escolher entre pacote oficial e tarball estatico em Debian/Ubuntu
install_zabbix_debian_family() {
    case "${ZABBIX_INSTALL_MODE:-auto}" in
        static)
            install_zabbix_static_binary
            ;;
        package)
            install_zabbix_package_debian
            ;;
        *)
            if ! install_zabbix_package_debian; then
                print_warning "Instalacao via pacote oficial falhou; usando binario estatico"
                log_warning "Fallback para binario estatico apos falha no pacote oficial"
                install_zabbix_static_binary
            fi
            ;;
    esac
}

# Instalar zabbix-agent via repositório oficial Zabbix (RPM). Usado em RHEL/CentOS/Rocky/Alma
# em vez do tarball estático (linux-3.0-amd64-static), frequentemente incompatível com glibc em EL8+.
install_zabbix_rhel_from_official_rpm() {
    local rhel_major pkg_mgr release_url branch

    detect_distro
    rhel_major="${DISTRO_VERSION%%.*}"
    if ! [[ "$rhel_major" =~ ^[0-9]+$ ]] || [ "$rhel_major" -lt 7 ] || [ "$rhel_major" -gt 9 ]; then
        print_error "Versão RHEL não suportada para RPM Zabbix: ${DISTRO_VERSION} (major $rhel_major; use EL 7–9)"
        log_error "RHEL major fora do intervalo: $rhel_major"
        return 1
    fi

    branch="${ZABBIX_RPM_BRANCH:-${ZABBIX_BRANCH:-7.0}}"
    pkg_mgr=$(get_package_manager)

    print_info "Instalando Zabbix Agent via repositório RPM oficial (Zabbix $branch, el$rhel_major)..."
    log_info "Zabbix RHEL RPM branch=$branch el=$rhel_major pkg=$pkg_mgr"

    print_info "Parando zabbix-agent se estiver em execução..."
    systemctl stop zabbix-agent >> "$LOG_FILE" 2>&1 || true

    if [ -f /etc/systemd/system/zabbix-agent.service ]; then
        print_info "Removendo unit em /etc/systemd/system (restaura o unit do pacote RPM)..."
        systemctl disable zabbix-agent >> "$LOG_FILE" 2>&1 || true
        rm -f /etc/systemd/system/zabbix-agent.service
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
        systemctl reset-failed zabbix-agent >> "$LOG_FILE" 2>&1 || true
    fi

    release_url="https://repo.zabbix.com/zabbix/${branch}/rhel/${rhel_major}/x86_64/zabbix-release-latest.el${rhel_major}.noarch.rpm"

    print_info "Instalando zabbix-release..."
    $pkg_mgr remove -y zabbix-release >> "$LOG_FILE" 2>&1 || true
    if ! $pkg_mgr install -y "$release_url" >> "$LOG_FILE" 2>&1; then
        print_error "Falha ao instalar zabbix-release ($release_url)"
        log_error "Instalação zabbix-release falhou"
        return 1
    fi

    print_info "Instalando pacote zabbix-agent..."
    if ! $pkg_mgr install -y zabbix-agent >> "$LOG_FILE" 2>&1; then
        print_error "Falha ao instalar o pacote zabbix-agent"
        log_error "Instalação zabbix-agent falhou"
        return 1
    fi

    print_success "Zabbix Agent instalado a partir do repositório oficial (RPM)"
    log_success "zabbix-agent RPM instalado"
    return 0
}

# Baixar URL para arquivo (wget ou curl)
download_zabbix_tarball() {
    local url="$1"
    local dest="$2"
    if command -v wget &>/dev/null; then
        wget -q "$url" -O "$dest" >> "$LOG_FILE" 2>&1
    elif command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest" >> "$LOG_FILE" 2>&1
    else
        print_error "wget ou curl é necessário para baixar o agente Zabbix"
        log_error "wget/curl não encontrado"
        return 1
    fi
}

# Instalar binários estáticos oficiais e unit systemd (amd64)
install_zabbix_static_binary() {
    local url
    url="$(resolve_zabbix_static_url)" || {
        print_error "Nao foi possivel resolver a URL do agente Zabbix (branch ${ZABBIX_BRANCH:-7.0})."
        return 1
    }
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        print_error "Este tarball é amd64 (x86_64); arquitetura atual: $arch"
        log_error "Arquitetura não suportada para agente estático: $arch"
        return 1
    fi

    print_info "Instalando Zabbix Agent a partir do tarball estático..."
    log_info "Instalação estática Zabbix: $url"
    if ! command -v tar &>/dev/null; then
        print_error "Comando tar é necessário para extrair o agente Zabbix"
        return 1
    fi

    print_info "Parando zabbix-agent se estiver em execução (atualização de binários)..."
    systemctl stop zabbix-agent >> "$LOG_FILE" 2>&1 || true

    remove_zabbix_agent_package_if_installed

    if ! getent group zabbix &>/dev/null; then
        groupadd -r zabbix >> "$LOG_FILE" 2>&1 || groupadd --system zabbix >> "$LOG_FILE" 2>&1 || {
            print_error "Falha ao criar grupo zabbix"
            return 1
        }
    fi
    if ! getent passwd zabbix &>/dev/null; then
        useradd -r -g zabbix -d /var/lib/zabbix -s /sbin/nologin zabbix >> "$LOG_FILE" 2>&1 || \
        useradd --system -g zabbix -d /var/lib/zabbix -s /sbin/nologin zabbix >> "$LOG_FILE" 2>&1 || {
            print_error "Falha ao criar usuário zabbix"
            return 1
        }
    fi

    local pid_file
    pid_file=$(get_zabbix_pid_file)
    local pid_dir
    pid_dir=$(dirname "$pid_file")

    mkdir -p /etc/zabbix/zabbix_agentd.d /var/log/zabbix "$pid_dir" >> "$LOG_FILE" 2>&1
    chown -R zabbix:zabbix /etc/zabbix /var/log/zabbix "$pid_dir" >> "$LOG_FILE" 2>&1 || true

    local tarball="/tmp/zabbix-agent-static.tar.gz"
    rm -f "$tarball"
    print_info "Baixando tarball..."
    if ! download_zabbix_tarball "$url" "$tarball"; then
        print_error "Falha ao baixar o agente Zabbix"
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d /tmp/zabbix-static.XXXXXX)
    if ! tar -xzf "$tarball" -C "$tmpdir" >> "$LOG_FILE" 2>&1; then
        print_error "Falha ao extrair tarball"
        rm -rf "$tmpdir"
        rm -f "$tarball"
        return 1
    fi

    if [[ ! -f "$tmpdir/sbin/zabbix_agentd" ]]; then
        print_error "Arquivo sbin/zabbix_agentd não encontrado no tarball"
        rm -rf "$tmpdir"
        rm -f "$tarball"
        return 1
    fi

    install -m 755 "$tmpdir/sbin/zabbix_agentd" /usr/sbin/zabbix_agentd
    [[ -f "$tmpdir/bin/zabbix_get" ]] && install -m 755 "$tmpdir/bin/zabbix_get" /usr/bin/zabbix_get
    [[ -f "$tmpdir/bin/zabbix_sender" ]] && install -m 755 "$tmpdir/bin/zabbix_sender" /usr/bin/zabbix_sender

    rm -rf "$tmpdir"
    rm -f "$tarball"

    print_info "Instalando unit systemd zabbix-agent..."
    # Type=simple + -f: o agente estático em modo daemon fork confunde o systemd com Type=forking/PIDFile
    # em vários RHEL; primeiro plano evita timeout/falha no systemctl start.
    cat > /etc/systemd/system/zabbix-agent.service <<EOF
[Unit]
Description=Zabbix Agent
After=network.target

[Service]
Type=simple
User=zabbix
Group=zabbix
Restart=on-failure
KillMode=control-group
ExecStart=/usr/sbin/zabbix_agentd -f -c /etc/zabbix/zabbix_agentd.conf
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1

    print_success "Binários Zabbix Agent (estático) instalados"
    log_success "Agente Zabbix estático instalado"
    return 0
}

# Criar arquivo de configuração do Zabbix Agent
create_zabbix_config() {
    local config_file="$1"
    local hostname=$(get_hostname)
    local ip_address=$(get_ip_address)
    local pid_file
    pid_file=$(get_zabbix_pid_file)
    
    print_info "Criando arquivo de configuração do Zabbix..."
    log_info "Criando configuração do Zabbix Agent"
    
    # Fazer backup do arquivo original se existir
    if [ -f "$config_file" ]; then
        backup_file "$config_file"
    fi
    
    # Criar configuração
    cat > "$config_file" <<EOL
# Arquivo de configuração do Zabbix Agent
# Gerado automaticamente em $(date)
# Hostname: $hostname | IP: $ip_address

############ PARÂMETROS GERAIS #################

### Option: PidFile
PidFile=$pid_file

### Option: LogFile
LogFile=/var/log/zabbix/zabbix_agentd.log

### Option: LogFileSize
# Tamanho máximo do arquivo de log em MB
LogFileSize=$ZABBIX_LOG_SIZE

### Option: DebugLevel
# 0 - informações básicas
# 1 - informações críticas
# 2 - informações de erro
# 3 - avisos
# 4 - debug (produz muitas informações)
# 5 - debug estendido
DebugLevel=$ZABBIX_DEBUG_LEVEL

### Option: Server
# Lista de IPs dos servidores/proxies Zabbix separados por vírgula
Server=$ZABBIX_PROXY_SERVER

### Option: ListenPort
# Porta em que o agente escutará conexões do servidor
ListenPort=$ZABBIX_AGENT_PORT

### Option: ListenIP
# Lista de IPs em que o agente deve escutar
ListenIP=0.0.0.0

### Option: StartAgents
# Número de instâncias pré-forked do zabbix_agentd
StartAgents=3

### Option: ServerActive
# Lista de servidores/proxies Zabbix para verificações ativas
ServerActive=$ZABBIX_PROXY_SERVER:$ZABBIX_SERVER_PORT

### Option: Hostname
# Nome único do host (case sensitive)
Hostname=$hostname

### Option: HostMetadata
# Metadados do host para auto-registro
HostMetadata=Linux

### Option: Include
# Incluir arquivos de configuração adicionais
Include=/etc/zabbix/zabbix_agentd.d/*.conf

############ FIM DA CONFIGURAÇÃO #################
EOL

    # Ajustar permissões
    chown -R zabbix:zabbix /etc/zabbix 2>/dev/null || true
    chmod 644 "$config_file"
    
    print_success "Arquivo de configuração criado: $config_file"
    log_success "Configuração do Zabbix Agent criada"
    
    # Exibir informações
    print_info "Configuração:"
    echo "  - Hostname: $hostname"
    echo "  - IP: $ip_address"
    echo "  - Servidor Zabbix: $ZABBIX_PROXY_SERVER"
    echo "  - Porta do Agente: $ZABBIX_AGENT_PORT"
    
    return 0
}

# Configurar firewall (se necessário)
configure_firewall() {
    print_info "Configurando firewall..."
    log_info "Configurando regras de firewall"
    
    # Verificar se firewalld está ativo
    if systemctl is-active --quiet firewalld; then
        print_info "Firewalld detectado, abrindo porta $ZABBIX_AGENT_PORT/tcp..."
        firewall-cmd --add-port=${ZABBIX_AGENT_PORT}/tcp --permanent >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
        print_success "Regra de firewall adicionada"
        log_success "Porta $ZABBIX_AGENT_PORT/tcp liberada no firewalld"
    # Verificar se ufw está ativo
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        print_info "UFW detectado, abrindo porta $ZABBIX_AGENT_PORT/tcp..."
        ufw allow ${ZABBIX_AGENT_PORT}/tcp >> "$LOG_FILE" 2>&1
        print_success "Regra de firewall adicionada"
        log_success "Porta $ZABBIX_AGENT_PORT/tcp liberada no ufw"
    else
        print_info "Nenhum firewall ativo detectado, pulando configuração"
        log_info "Nenhum firewall ativo detectado"
    fi
}

# Instalar Zabbix Agent no Ubuntu
install_zabbix_ubuntu() {
    print_header "Instalação do Zabbix Agent - Ubuntu"
    
    if ! install_zabbix_debian_family; then
        print_error "Falha ao instalar o Zabbix Agent (modo: ${ZABBIX_INSTALL_MODE:-auto})"
        return 1
    fi
    
    # Criar configuração
    create_zabbix_config "/etc/zabbix/zabbix_agentd.conf"
    
    # Configurar firewall
    configure_firewall
    
    # Reiniciar e habilitar serviço
    if ! restart_service "zabbix-agent"; then
        print_info "Diagnóstico: journalctl -u zabbix-agent -n 40 --no-pager (detalhes também em $LOG_FILE)"
        return 1
    fi
    enable_service "zabbix-agent" || return 1
    
    print_separator
    if ! check_service_status "zabbix-agent"; then
        print_info "Diagnóstico: journalctl -u zabbix-agent -n 40 --no-pager"
        return 1
    fi
    
    return 0
}

# Instalar Zabbix Agent no Debian
install_zabbix_debian() {
    print_header "Instalação do Zabbix Agent - Debian"
    
    if ! install_zabbix_debian_family; then
        print_error "Falha ao instalar o Zabbix Agent (modo: ${ZABBIX_INSTALL_MODE:-auto})"
        return 1
    fi
    
    # Criar configuração
    create_zabbix_config "/etc/zabbix/zabbix_agentd.conf"
    
    # Configurar firewall
    configure_firewall
    
    # Reiniciar e habilitar serviço
    if ! restart_service "zabbix-agent"; then
        print_info "Diagnóstico: journalctl -u zabbix-agent -n 40 --no-pager (detalhes também em $LOG_FILE)"
        return 1
    fi
    enable_service "zabbix-agent" || return 1
    
    print_separator
    if ! check_service_status "zabbix-agent"; then
        print_info "Diagnóstico: journalctl -u zabbix-agent -n 40 --no-pager"
        return 1
    fi
    
    return 0
}

# Instalar Zabbix Agent no RHEL/Rocky/CentOS
install_zabbix_rhel() {
    print_header "Instalação do Zabbix Agent - RHEL/Rocky/CentOS"
    
    if ! install_zabbix_rhel_from_official_rpm; then
        print_error "Falha ao instalar Zabbix Agent (repositório RPM oficial)"
        return 1
    fi
    
    # Criar configuração
    create_zabbix_config "/etc/zabbix/zabbix_agentd.conf"
    
    # Configurar firewall
    configure_firewall
    
    # Reiniciar e habilitar serviço
    if ! restart_service "zabbix-agent"; then
        print_info "Diagnóstico: journalctl -u zabbix-agent -n 40 --no-pager (detalhes também em $LOG_FILE)"
        return 1
    fi
    enable_service "zabbix-agent" || return 1
    
    print_separator
    if ! check_service_status "zabbix-agent"; then
        print_info "Diagnóstico: journalctl -u zabbix-agent -n 40 --no-pager"
        return 1
    fi
    
    return 0
}

#==============================================================================
# Função Principal
#==============================================================================

main() {
    # Inicializar logging
    init_logging
    
    print_header "Instalador do Zabbix Agent"
    
    # Verificar root
    check_root
    
    # Verificar internet se configurado
    if [ "${CHECK_INTERNET:-true}" = "true" ]; then
        if ! check_internet; then
            print_error "Conexão com internet é necessária para instalação"
            exit 1
        fi
    fi
    
    # Detectar distribuição
    detect_distro
    print_info "Sistema: $DISTRO_NAME $DISTRO_VERSION"
    
    # Permitir override do servidor Zabbix via argumento
    if [ -n "$1" ]; then
        ZABBIX_PROXY_SERVER="$1"
        print_info "Usando servidor Zabbix: $ZABBIX_PROXY_SERVER"
    fi
    
    # Instalar baseado na distribuição
    local install_rc=1
    case "$DISTRO" in
        ubuntu)
            install_zabbix_ubuntu && install_rc=0
            ;;
        debian)
            install_zabbix_debian && install_rc=0
            ;;
        rhel|centos|rocky|almalinux)
            install_zabbix_rhel && install_rc=0
            ;;
        *)
            print_error "Distribuição não suportada: $DISTRO"
            log_error "Distribuição não suportada: $DISTRO"
            exit 1
            ;;
    esac
    
    if [ "$install_rc" -eq 0 ]; then
        print_separator
        print_success "Instalação do Zabbix Agent concluída com sucesso!"
        print_info "Log salvo em: $LOG_FILE"
        log_success "Instalação concluída com sucesso"
        return 0
    else
        print_error "Falha na instalação do Zabbix Agent"
        print_info "Verifique o log em: $LOG_FILE"
        log_error "Falha na instalação"
        return 1
    fi
}

# Executar apenas se for o script principal
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

