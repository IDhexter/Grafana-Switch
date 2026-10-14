# Arquitetura da Infraestrutura (Zabbix & Grafana)

## Stack Tecnológica Completa
- **Monitoramento & Coleta:**
  - Zabbix Server 7.0 LTS / 6.4 LTS (C / C++)
  - Zabbix Web Frontend (PHP 8.2+ / Nginx)
  - Zabbix Agent 2 (Go) para coleta de métricas em hosts e containers
- **Visualização & Dashboards:**
  - Grafana OSS 10.x / 11.x (Go / TypeScript / React)
  - Plugin Zabbix para Grafana: `alexanderzobnin-zabbix-app`
- **Banco de Dados & Armazenamento de Séries Temporais:**
  - PostgreSQL 16 com extensão **TimescaleDB** (recomendada para particionamento nativo de chunks, compressão e otimização de consultas históricas)
- **Orquestração & Execução:**
  - Docker & Docker Compose (dentro de Container LXC dedicado no Proxmox)

## Servidores e Infraestrutura

### Ambientes e Endpoints Ativos (POC Corporativa / Laboratório)
- **Zabbix Server / Web API:**
  - **IP / Host:** `10.0.0.26` (Porta 80)
  - **API Endpoint:** `http://10.0.0.26/api_jsonrpc.php`
  - **Autenticação:** API Token (armazenado em `.env` sob `ZABBIX_TOKEN`)
  - **Status de Conectividade:** Validado (TCP 80 OK)
- **Grafana Server:**
  - **IP / Host:** `10.0.0.25` (Porta 3000)
  - **URL Base:** `http://10.0.0.25:3000`
  - **Dashboard Principal:** `http://10.0.0.25:3000/d/alpt2p5/`
  - **Autenticação:** Usuário corporativo (armazenado em `.env`)
  - **Status de Conectividade:** Validado (TCP 3000 OK)

### Servidores Físicos e Virtualização Local
- **Servidor Físico 1 (Gateway & VPN):**
  - **Hardware:** DELL Wyse
  - **IP na Rede:** `172.1.0.30`
  - **SO:** Linux Debian
  - **Função:** Roteamento de entrada segura via Tailscale VPN.
- **Servidor Físico 2 (Host de Virtualização):**
  - **Hardware:** DELL OptiPlex 3080 Micro
  - **IP de Acesso:** `172.1.0.31`
  - **SO:** Proxmox VE 8.x (Debian 12 Bookworm)
  - **Armazenamento:** SSD ~240GB (Pool `local-lvm`)
- **Alocação de Nó/Container de Observabilidade (Planejado):**
  - **Tipo:** LXC Container Ubuntu 22.04 / Debian 12 com Docker habilitado (`nesting=1,keyctl=1`)
  - **Hostname Sugerido:** `mon-zabbix-grafana`
  - **IP Sugerido:** `172.1.0.34` (Rede interna `172.1.0.0/24`)
  - **Diretório de Deploy Remoto:** `/opt/zabbix-grafana`

## Banco de Dados
- **Engine:** PostgreSQL 16 (com módulo TimescaleDB ativado).
- **Estrutura Principal:**
  - Tabelas de histórico numérico e textual: `history`, `history_uint`, `history_str`, `history_text`, `history_log`.
  - Tabelas de tendências agregadas (médias horárias): `trends`, `trends_uint`.
  - Tabelas de configuração e metadados: `items`, `hosts`, `triggers`, `events`, `functions`.
- **Arquivos de Conexão Ocultos & Protegidos:**
  - `.env` (armazena `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `ZBX_SERVER_HOST`, `GF_SECURITY_ADMIN_PASSWORD`).
  - `.env.db` (credenciais isoladas do banco de dados).
  - Todos ignorados pelo `.gitignore` e documentados apenas via `.env.example`.

## Estrutura de Pastas do Repositório (Local e Remoto)
```text
Zabbix-Grafana/
├── .ia/                            # Context Bootstrapping e documentação viva da IA
│   ├── MEMORY.md
│   ├── ARCHITECTURE.md
│   ├── RULES.md
│   ├── TASKS.md
│   └── RUNBOOK.md
├── docker/                         # Manifestos de conteinerização
│   ├── docker-compose.yml          # Definição dos serviços Zabbix, DB e Grafana
│   ├── .env.example                # Template de variáveis sem credenciais
│   └── .env                        # [OCULTO / NÃO VERSIONADO] Variáveis reais
├── zabbix/                         # Arquivos de customização do Zabbix
│   ├── alertscripts/               # Scripts de disparo de alertas (ex: Telegram, Webhook)
│   ├── externalscripts/            # Scripts de checagem customizada
│   └── zabbix_server.conf.d/       # Configurações adicionais do servidor
├── grafana/                        # Provisionamento de dashboards e data sources
│   ├── provisioning/
│   │   ├── datasources/            # Conexão automática com o Zabbix
│   │   └── dashboards/             # Provedores de dashboards JSON
│   └── dashboards/                 # Arquivos JSON dos dashboards versionados
└── scripts/                        # Scripts utilitários de deploy, backup e validação
    ├── deploy.sh
    └── backup-db.sh
```
