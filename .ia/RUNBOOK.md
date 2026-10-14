# Runbook e Procedimentos Operacionais (Zabbix & Grafana)

## Procedimentos de Deploy e Operação da Stack

### 1. Inicializar ou Atualizar a Stack (Docker Compose)
Para iniciar ou atualizar os containers em background com rebuild de imagens alteradas:
```bash
# Navegar até o diretório da stack no servidor
cd /opt/zabbix-grafana/docker

# Validar sintaxe do arquivo de composição
docker compose config

# Subir todos os serviços em segundo plano
docker compose up -d

# Verificar estado dos containers
docker compose ps
```

### 2. Parar ou Reiniciar Serviços
```bash
# Reiniciar um serviço específico (ex: Grafana ou Zabbix Server)
docker compose restart grafana
docker compose restart zabbix-server

# Parar a stack completa com segurança
docker compose down
```

### 3. Recarregar Cache de Configuração do Zabbix (Sem Downtime)
```bash
docker compose exec zabbix-server zabbix_server -R config_cache_reload
```

---

## Leitura de Logs e Diagnóstico de Falhas

### 1. Logs da Stack Conteinerizada (Docker)
```bash
# Visualizar logs em tempo real do Zabbix Server
docker compose logs -f --tail=100 zabbix-server

# Visualizar logs da interface Web (Nginx / PHP-FPM)
docker compose logs -f --tail=100 zabbix-web

# Visualizar logs do Grafana
docker compose logs -f --tail=100 grafana

# Visualizar logs do Banco de Dados PostgreSQL
docker compose logs -f --tail=100 postgres-server
```

### 2. Caminhos de Logs no Sistema Operacional / Host LXC
- **Zabbix Server:** `/var/log/zabbix/zabbix_server.log`
- **Zabbix Agent 2:** `/var/log/zabbix/zabbix_agent2.log`
- **Grafana Server:** `/var/log/grafana/grafana.log`
- **Nginx Web Server:** `/var/log/nginx/error.log` e `/var/log/nginx/access.log`
- **Systemd Journal (serviços nativos):**
  ```bash
  journalctl -u zabbix-server -n 100 --no-pager
  journalctl -u grafana-server -n 100 --no-pager
  ```

---

## Comandos Padrão para Banco de Dados Remoto (PostgreSQL)

### 1. Conexão Interativa com o PostgreSQL via Container
```bash
docker compose exec -it postgres-server psql -U zabbix -d zabbix
```

### 2. Verificar Status de Extensões (TimescaleDB) e Tamanho do Banco
```sql
-- Dentro do psql:
\dx
SELECT pg_size_pretty(pg_database_size('zabbix'));
SELECT hypertable_name, num_chunks FROM timescaledb_information.hypertables;
```

### 3. Rotina de Backup do Banco de Dados
```bash
# Gerar dump comprimido da base Zabbix
docker compose exec -t postgres-server pg_dump -U zabbix zabbix | gzip > /opt/zabbix-grafana/backups/zabbix_db_$(date +%Y%m%d_%H%M%S).sql.gz
```

### 4. Procedimento de Restauração de Backup
```bash
# Restaurar a partir de arquivo compactado
gunzip -c /opt/zabbix-grafana/backups/zabbix_db_YYYYMMDD_HHMMSS.sql.gz | docker compose exec -T postgres-server psql -U zabbix -d zabbix
```

---

## Passos Exatos para Sincronizar o GitHub

Execute a sequência padrão de versionamento a partir da raiz do repositório:

```bash
# 1. Verificar arquivos modificados e não rastreados
git status

# 2. Adicionar alterações ao stage (respeitando o .gitignore)
git add .

# 3. Criar commit descritivo e padronizado (Conventional Commits)
git commit -m "feat: implementar estrutura inicial do Zabbix e Grafana"

# 4. Enviar alterações para a branch principal no repositório remoto
git push origin main
```
