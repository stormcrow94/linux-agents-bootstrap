# Shell Install Applications Script

Colecao de scripts Bash para preparar servidores Linux com:

- configuracao de hostname
- instalacao de Zabbix Agent
- instalacao de Wazuh Agent
- instalacao do Sophos (script oficial `SophosSetup.sh`)
- registro no dominio via Realmd/SSSD

O projeto pode ser executado por menu interativo (`installer.sh`) ou por scripts individuais.

## Principais recursos

- Menu interativo com deteccao automatica de distribuicao
- Biblioteca compartilhada com funcoes de validacao, log e operacoes comuns (`lib/common.sh`)
- Configuracao centralizada em `config/settings.conf`
- Logs por execucao em `logs/installer_YYYYMMDD_HHMMSS.log`
- Suporte para Ubuntu, Debian, RHEL, Rocky, CentOS e AlmaLinux (conforme script)
- `bootstrap.sh` para instalar em servidor novo com um unico comando

## Estrutura atual do repositorio

```text
.
├── installer.sh
├── bootstrap.sh
├── install_zabbix.sh
├── install_wazuh.sh
├── register_domain.sh
├── hostname.sh
├── SophosSetup.sh
├── lib/
│   └── common.sh
├── config/
│   └── settings.conf
├── README.md
├── PROJECT_DOCUMENTATION.md
├── QUICKSTART.md
├── QUICKSTART_WAZUH.md
├── WAZUH_IMPLEMENTATION.md
├── DEBIAN_GUIDE.md
├── EXAMPLES.md
└── WIKI.md
```

## Pre-requisitos

- Linux com systemd
- Bash 4+
- Acesso root (ou `sudo`)
- Conectividade de rede para baixar pacotes

## Uso rapido

No diretorio do projeto:

```bash
chmod +x *.sh lib/common.sh
sudo ./installer.sh
```

### Menu principal (`installer.sh`)

Opcoes disponiveis:

1. Instalar Zabbix Agent
2. Configurar Hostname
3. Instalar Wazuh Agent
4. Instalar Sophos
5. Registrar no Dominio
6. Executar Tudo (Modo Completo)
7. Configuracoes
8. Ver Logs
0. Sair

## Instalacao em uma linha (servidor novo)

Baixa o repositorio e abre o menu, sem clonar nada manualmente:

```bash
curl -fsSL https://raw.githubusercontent.com/stormcrow94/shell-install-applications-script/main/bootstrap.sh -o /tmp/bootstrap.sh
sudo bash /tmp/bootstrap.sh
```

Executar somente o registro no dominio:

```bash
curl -fsSL https://raw.githubusercontent.com/stormcrow94/shell-install-applications-script/main/bootstrap.sh -o /tmp/bootstrap.sh
sudo bash /tmp/bootstrap.sh --domain
```

Etapas isoladas: `--zabbix`, `--wazuh`, `--sophos`, `--hostname`, `--download-only`.
Os arquivos ficam em `/opt/shell-install-applications-script` (use `--dir` para mudar) e
`--keep-settings` preserva um `config/settings.conf` ja ajustado.

### Zabbix Agent: pacote oficial ou binario estatico

Em Debian/Ubuntu o agente vem do repositorio oficial (`repo.zabbix.com`) por padrao:

| `ZABBIX_INSTALL_MODE` | Comportamento |
| --- | --- |
| `auto` (padrao) | tenta o pacote `.deb`; se o repo falhar, instala o tarball estatico |
| `package` | somente pacote oficial (falha se o repo nao responder) |
| `static` | somente tarball estatico (comportamento antigo) |

O pacote tem suporte a TLS/PSK e IPv6 e recebe correcao de bibliotecas pelo `apt`. A
configuracao gerada e a mesma nos dois modos (`Server`, `ServerActive`, `Hostname`,
`HostMetadata`, `DebugLevel`, `LogFileSize`). Ao migrar um host que estava no estatico, o
script move o unit antigo para `/etc/systemd/system/zabbix-agent.service.bak.<data>` e volta a
usar o unit do pacote. RHEL/CentOS/Rocky/Alma continuam usando RPM oficial.

## Execucao por script individual

```bash
sudo ./install_zabbix.sh [IP_OU_HOST_ZABBIX]
sudo ./install_wazuh.sh [WAZUH_MANAGER]
sudo ./hostname.sh
sudo ./register_domain.sh
sudo ./SophosSetup.sh
```

### Registro no dominio

`register_domain.sh` funciona em Ubuntu 20.04/22.04/24.04, Debian 11/12 e
RHEL/Rocky/Alma 8/9. Ele detecta `apt` ou `dnf`/`yum`, valida DNS/SRV, relogio e
portas antes do `realm join`, e e idempotente (pode ser executado de novo).

```bash
sudo DOMAIN=center.local \
     ADMIN_USER=fortigate \
     ADMIN_PASS_FILE=/root/.adpass \
     ADMIN_GROUP=SUDOERS_NOMEDOSERVIDOR \
     COMPUTER_OU='OU=Computadores,DC=center,DC=local' \
     ./register_domain.sh
```

Sem variaveis ele pergunta dominio, usuario, senha, grupo e OU. O grupo informado
recebe SSH e sudo (`/etc/sudoers.d/sudoers`) e e validado no AD antes de ser aplicado.

## Configuracao

Edite `config/settings.conf` para ajustar parametros como:

- `ZABBIX_PROXY_SERVER`
- `ZABBIX_SERVER_PORT`
- `ZABBIX_AGENT_PORT`
- `ZABBIX_BRANCH` (major.minor do servidor; hoje `7.0`)
- `ZABBIX_AGENT_VERSION` (`latest` = ultimo patch do branch no CDN)
- `WAZUH_MANAGER`
- `WAZUH_VERSION`
- `DEFAULT_DOMAIN`
- `DEFAULT_ADMIN_GROUP`
- `CHECK_INTERNET`

## Logs

Todos os scripts geram logs em `logs/`:

```bash
ls -lh logs/
```

Para acompanhar a ultima execucao:

```bash
tail -f logs/installer_*.log
```

## Validacao basica pos-instalacao

```bash
systemctl status zabbix-agent
systemctl status wazuh-agent
realm list
```

## Documentacao

- [PROJECT_DOCUMENTATION.md](PROJECT_DOCUMENTATION.md) - documentacao tecnica consolidada do projeto
- [WIKI.md](WIKI.md) - guia geral em formato wiki
- [QUICKSTART.md](QUICKSTART.md) - inicio rapido
- [QUICKSTART_WAZUH.md](QUICKSTART_WAZUH.md) - guia rapido de Wazuh
- [WAZUH_IMPLEMENTATION.md](WAZUH_IMPLEMENTATION.md) - detalhes de implementacao Wazuh
- [DEBIAN_GUIDE.md](DEBIAN_GUIDE.md) - orientacoes para Debian
- [EXAMPLES.md](EXAMPLES.md) - exemplos praticos de uso
