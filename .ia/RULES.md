# Regras, Padrões e Restrições (Zabbix & Grafana)

## "Quirks" do Sistema e Contornos
- **Plugin Zabbix no Grafana (`alexanderzobnin-zabbix-app`):**
  - *Problema:* Em versões recentes do Grafana (v10+), plugins que não possuam assinatura oficial da comunidade Grafana Cloud são bloqueados por padrão.
  - *Contorno:* Configurar a variável de ambiente no Grafana: `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=alexanderzobnin-zabbix-datasource`.
- **Zabbix Housekeeper vs I/O do SSD:**
  - *Problema:* O processo Housekeeper nativo do Zabbix executa queries intensivas de `DELETE` em tabelas com milhões de linhas (`history`, `trends`), gerando gargalo severo de I/O de disco no Proxmox.
  - *Contorno:* Utilizar TimescaleDB com particionamento baseado em tempo (Hypertable) e descartar chunks antigos via políticas de retenção do próprio banco, desativando a limpeza de histórico no Housekeeper do Zabbix.
- **Cache de Configuração do Zabbix Server:**
  - *Problema:* Criar ou alterar itens e triggers na interface web não atualiza os pollers imediatamente devido ao cache em memória (intervalo padrão de até 60 segundos).
  - *Contorno:* Executar comando manual de recarga de cache no container: `zabbix_server -R config_cache_reload`.
- **Cache de Dashboards no Navegador / Grafana:**
  - *Problema:* Alterações feitas diretamente no JSON provisionado do Grafana podem não ser refletidas na interface devido ao cache local do browser ou do backend.
  - *Contorno:* Recarregar com `Ctrl + Shift + R` e reiniciar o container do Grafana ao alterar arquivos de provisioning.
- **Sanitização HTML do Grafana (DOMPurify em Text Panels):**
  - *Problema:* Por padrão (`disable_sanitize_html = false`), o Grafana sanitiza tags `<style>` e `<script>` em painéis de texto nativos, fazendo com que blocos CSS vazem na tela como texto bruto visível.
  - *Contorno:* Utilizar HTML com estilos inline (`style="..."`) e elementos vetoriais SVG nativos (`<svg>`, `<rect>`, `<circle>`, `<text>`, `<filter>`) que são 100% permitidos pelo DOMPurify sem necessidade de alterar o `grafana.ini` do servidor. Caso scripts dinâmicos de clique sejam obrigatórios, pode-se instalar o plugin `marcusolsson-dynamictext-panel` (Business Text) ou configurar `disable_sanitize_html = true`.
- **Plugin Business Text (`marcusolsson-dynamictext-panel`) - "Armadilha" de Indentação Markdown:**
  - *Problema:* O Business Text processa o HTML com parser Markdown. Qualquer linha indentada com 4 ou mais espaços após uma linha vazia é tratada como bloco de código indentado (`<pre><code>`), escapando tags HTML e vazando código cru na tela.
  - *Contorno:* SEMPRE higienizar templates HTML antes do deploy, aplicando `.Trim()` em todas as linhas e eliminando linhas vazias (`$htmlClean`).
- **Ciclo de Vida do React no Grafana vs JavaScript em `afterRender`:**
  - *Problema:* Durante re-renders do Grafana, elementos do DOM podem retornar temporariamente `null`. Executar `document.getElementById(...).innerText = ...` de forma síncrona causa unhandled exception (`TypeError: Cannot set properties of null`) capturado pelo React Error Boundary, quebrando o painel.
  - *Contorno:* Utilizar SEMPRE funções defensivas com null-checks e `try/catch` (`safeSetText`, `safeSetHtml`).
  - *Limpeza de Timers:* Sempre limpar intervalos anteriores (`clearInterval`) no início de `afterRender` para não acumular timers a cada re-render do painel.
  - *Cliques Imediatos:* Injetar disparadores inline `onclick="window.__arubaSelectPort(N)"` diretamente nas tags HTML das portas, sem depender de sincronia de montagem do React.
- **CORS Zabbix Server:**
  - *Descoberta:* O servidor Apache/Nginx do Zabbix retorna `Access-Control-Allow-Origin: *` por padrão, permitindo polling assíncrono direto do navegador do cliente (`fetch('http://<ZABBIX_HOST>/api_jsonrpc.php')`) sem sobrecarregar o backend do Grafana.

## Restrições do Ambiente e Recursos
- **Armazenamento:**
  - O host possui um SSD de ~240GB compartilhado entre o SO do Proxmox, containers de automação (Hermes, Home Assistant) e backups.
  - *Regra:* Limitar a retenção de dados brutos (`history`) a no máximo 7 a 14 dias; manter agregações (`trends`) por até 365 dias com compressão TimescaleDB.
- **Memória RAM:**
  - Limitar a alocação de memória no container da stack para no máximo 3GB a 4GB, garantindo folga para os demais serviços no host Proxmox.

## Padrões de Código e Convenções
- **Nomenclatura:**
  - Arquivos e diretórios: `kebab-case` (ex: `docker-compose.yml`, `deploy.sh`, `zabbix-server.conf`).
  - Variáveis de ambiente: `UPPER_SNAKE_CASE` (ex: `POSTGRES_PASSWORD`, `ZBX_SERVER_HOST`).
  - Nomes de Hosts no Zabbix: `[tipo]-[nome]-[ambiente]` (Ex: `srv-proxmox-pve`, `lxc-hermes-prod`, `lxc-homeassistant-prod`, `net-dellwyse-gw`).
  - Tags de Itens e Triggers: `service: <nome>`, `component: <modulo>`, `severity: <nivel>`.
- **Padrão Visual dos Dashboards Grafana:**
  - **Tema:** Sempre utilizar o tema Escuro (`Dark Theme`).
  - **Paleta de Severidade Oficial:**
    - OK / Normal: Verde (`#73BF69`)
    - Atenção / Warning: Amarelo (`#FADE2A`)
    - Médio / Average: Laranja Claro (`#FF9830`)
    - Alto / High: Laranja Escuro (`#FF780A`)
    - Desastre / Disaster: Vermelho (`#F2495C`)

## Restrições de Segurança
- **Segredos e Credenciais:**
  - NUNCA commitar senhas, tokens de API ou chaves privadas no repositório Git.
  - Toda credencial deve residir em arquivos `.env` listados no `.gitignore`.
  - Fornecer sempre um `.env.example` preenchido apenas com valores placeholder (`change_me`).
- **Acesso à API do Zabbix:**
  - Criar um usuário exclusivo no Zabbix para o Grafana (ex: `grafana-ro`) com permissão estrita de **Somente Leitura** (Read-Only) em todos os Host Groups.
  - Utilizar API Token (Zabbix 5.4+) em vez de usuário/senha com autenticação legada.
