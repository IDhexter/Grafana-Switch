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
