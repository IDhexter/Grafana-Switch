# Gerenciamento de Tarefas (Zabbix & Grafana)

## ✅ Concluído
- [x] Criação da pasta `.ia` na raiz do repositório para a arquitetura de Context Bootstrapping.
- [x] Definição e padronização da memória do projeto (`MEMORY.md`).
- [x] Especificação da arquitetura física, lógica e de dados (`ARCHITECTURE.md`).
- [x] Estabelecimento de regras, padrões, segurança e contorno de quirks (`RULES.md`).
- [x] Autenticação e integração via novo Zabbix API Token em Zabbix 7.0.4.
- [x] Template do switch atualizado para `Network Generic Device by SNMP` com 32 interfaces descobertas.
- [x] Deploy da réplica visual idêntica (pixel-perfect) do dashboard de rack `SW-CORE-16` no Grafana.
- [x] Implementação de Floating Tooltips interativos em hover para todas as portas (1 a 52) exibindo Porta, Descrição, Status, Velocidade, Entrada e Saída conforme imagem de referência.
- [x] Resolução do vazamento de tags SVG no card 'DETALHE DA PORTA' com substituição por gráfico de curvas PNG anti-aliased via Data URI sem escape de sanitização.
- [x] Ajuste do grid inferior para proporção 59%/41% eliminando compressão da coluna 'EVENTOS DE PORTA'.
- [x] Verificação visual automatizada pré-entrega via headless browser com geração de screenshots comparativos.
- [x] Modelagem e deploy do **Gêmeo Digital (Digital Twin) do switch Aruba Instant On 1930 24G 4SFP+ (JL682A)** no Grafana (v50).
- [x] Mapeamento SNMP de 28 interfaces do switch: 24x 1GbE RJ45 + 4x 10GbE SFP+.
- [x] Coleta em tempo real via CORS direto Zabbix API a cada 15 segundos + botão manual de sincronização.
- [x] Descoberta dinâmica de IP real do switch via Zabbix API (`host.get`).
- [x] LEDs de alerta vermelho pulsante em portas caídas/com alarme (`Interface: Link down`).
- [x] Botão de fechar gaveta de inventário funcional e responsivo (`Fechar x`).
- [x] Interatividade de clique em portas com cursor azul neon, atualização instantânea de KPIs, velocidade (com suporte a degradado 10M/100M em âmbar) e osciloscópio HTML5 Canvas.
- [x] Resolução do quirk de escape de Markdown do Business Text e tratamento de erros do ciclo de vida React.
- [x] Criação do script de automação e deploy `scripts/build_aruba_interactive_twin.ps1`.
- [x] Escala dinâmica e adaptativa de volume de tráfego de rede (bps, Kb/s, Mb/s, Gb/s) para KPIs, detalhes de portas, hover tooltips e régua do gráfico Canvas.
- [x] Geração de backups de segurança da versão v51 (`*.v51.backup.*`) antes da evolução do painel.
- [x] Item 1: Remoção de dados mockados e adoção de nomenclatura 100% autêntica via Zabbix SNMP (`Interface (\d+)\(([^)]*)\)` com fallback estrito para hardware real `GigabitEthernetX` / `1GbE RJ45` / `SFP+ 10G`).
- [x] Item 2: Widget compacto Top Talkers ajustado estritamente para **Top 3** consumidores com ranking de medalhas (1º, 2º, 3º).
- [x] Item 3: Drag-to-Zoom interativo no gráfico Canvas com brush selection, botão flutuante `[ ↺ RESET ZOOM ]` e atalho de duplo clique.
- [x] Alinhamento vertical perfeito do grid inferior: card esquerdo (gráfico Canvas) e cards direitos (Top 3 + Alertas) nivelados na mesma linha reta com zero espaço desperdiçado (versão 54).
- [x] Correção do botão `[ ↺ RESET ZOOM ]` com bind direto de eventos de DOM (`onclick`, `onmousedown`, `ontouchend`) contornando a sanitização do Grafana e preservação de zoom ativo durante o polling periódico de telemetria (versão 55).
- [x] Parametrização modular do script `scripts/build_aruba_interactive_twin.ps1` com suporte a `-TargetHostId`, `-TargetDashboardUid`, `-TargetDashboardTitle`, `-TargetSwitchShortName`, `-TargetSwitchIp`.
- [x] Criação e deploy no Grafana de +3 dashboards para os switches da rede Bamex:
  - `[BAMEX] - SW02` (IP: `10.50.0.3`, Host ID: `10683`, UID: `bamex-sw02`)
  - `[BAMEX] - SW03` (IP: `10.50.0.4`, Host ID: `11125`, UID: `bamex-sw03`)
- [x] Exportação e sanitização de dados no repositório local e atualização da memória do projeto.
- [x] Elaboração do documento técnico completo de arquitetura, telemetria Zabbix e engenharia do dashboard (`docs/ARUBA_DIGITAL_TWIN_TECHNICAL_SPEC.md`).

## 🔜 Backlog Imediato (Próximos Passos)
- [ ] Criar estrutura base de pastas do repositório (`docker/`, `zabbix/`, `grafana/`, `scripts/`, `.gitignore`).
- [ ] Desenvolver `docker-compose.yml` para orquestrar Zabbix Server, PostgreSQL (TimescaleDB), Zabbix Web Frontend e Grafana.
- [ ] Criar arquivo `.env.example` com todas as variáveis documentadas e mapeamento de portas.
- [ ] Configurar provisionamento automatizado do Data Source Zabbix no Grafana (`grafana/provisioning/datasources/zabbix.yaml`).
- [ ] Configurar provisionamento automático de Dashboards no Grafana (`grafana/provisioning/dashboards/`).
- [ ] Criar script de automação para deploy da stack e verificação de saúde dos serviços (`scripts/deploy.sh`).
- [ ] Desenvolver dashboard base de visão geral da infraestrutura (Dell OptiPlex, Proxmox, containers e rede).
- [ ] Configurar integração de alertas do Zabbix (notificações via Telegram / Hermes).

## 🐛 Problemas e Bugs Não Resolvidos (Para Investigação Futura)
- Nenhum bug pendente. Todas as falhas de renderização e seleção de portas foram corrigidas e validadas.
