# Memória da IA (Context Bootstrapping) - Zabbix & Grafana

## Objetivo do Projeto
Implantar, automatizar e manter uma infraestrutura completa de observabilidade, telemetria e monitoramento baseada em **Zabbix** e **Grafana** para o ecossistema de servidores, containers e dispositivos de rede do laboratório.

## Resumo do Ambiente & Regras de Negócio Essenciais
- **Centralização de Métricas:** Monitoramento contínuo de hosts físicos (Dell OptiPlex 3080 Proxmox VE, Dell Wyse Gateway/VPN Tailscale), containers LXC (Hermes Agent, Home Assistant) e ativos de rede.
- **Divisão de Responsabilidades:**
  - **Zabbix:** Coleta de métricas via Zabbix Agent 2, SNMP e ICMP, além do motor de gatilhos, correlação e alertas.
  - **Grafana:** Visualização unificada, dashboards analíticos executivos e operacionais, consultando o Zabbix via plugin oficial (`alexanderzobnin-zabbix-app`).
- **Eficiência e Proteção de Recursos:**
  - O host de virtualização possui SSD de ~240GB e memória compartilhada. A retenção de histórico detalhado e o particionamento do banco devem ser rigorosamente controlados para evitar esgotamento de I/O e armazenamento.
- **Segurança:**
  - Não expor portas sensíveis diretamente à internet pública; acesso restrito à rede local (`172.1.0.0/24`) e malha VPN Tailscale.
  - Credenciais e segredos isolados em variáveis de ambiente, nunca versionados em repositório.

## Estado Atual do Projeto
- **Fase:** Produção / Gêmeos Digitais Multi-Switch em Massa (v56).
- **Ambientes Conectados (Ativos):**
  - **Zabbix API:** `http://10.10.1.26/api_jsonrpc.php` (Proxy 1, SNMP Community `vegasnmp`).
  - **Switches Monitorados:**
    - `[BAMEX] - SW01` (Host ID: `10682`, IP: `10.50.0.2`): Dashboard Grafana `alpt2p5`
    - `[BAMEX] - SW02` (Host ID: `10683`, IP: `10.50.0.3`): Dashboard Grafana `bamex-sw02`
    - `[BAMEX] - SW03` (Host ID: `11125`, IP: `10.50.0.4`): Dashboard Grafana `bamex-sw03`
    - `[BAMEX] - SW04` (Host ID: `11126`, IP: `10.50.0.5`): Dashboard Grafana `bamex-sw04`
  - **Grafana:** `http://10.10.1.25:3000` (Pasta `POC ALEX`, Folder ID: 136).
  - **Repositório GitHub:** `https://github.com/IDhexter/Grafana-Switch` (branch `main`).
- **O que está 100% funcionando:**
  - **Script de Automação e Deploy Multi-Switch Parametrizado (`scripts/build_aruba_interactive_twin.ps1`):**
    - Permite gerar e publicar dashboards individuais para qualquer switch da rede informando apenas `-TargetHostId`, `-TargetDashboardUid`, `-TargetDashboardTitle`, `-TargetSwitchShortName`, `-TargetSwitchIp`.
    - Clone automático de template base (`alpt2p5`), preservação de UID, sincronização de nome e IP em tempo real.
  - **Gêmeo Digital do Switch Aruba Instant On 1930 24G 4SFP+ (JL682A)**:
    - Layout generoso e espaçado (portas RJ45 de 50x60px, SFP+ 10G em 2x2, bancos modulares 1-12 e 13-24).
    - **4 LEDs de Diagnóstico do Chassi conectados à telemetria:**
      - **Cloud**: Pulsa ciano no fetch, verde esmeralda no sucesso, âmbar em erro, clique manual para sincronizar.
      - **Power**: Verde para ping `icmpping` UP, vermelho se inacessível.
      - **Fault**: Conectado a `problem.get` (sem `recent: true` para ignorar eventos já resolvidos); apagado/cinza neutro quando saudável, vermelho pulsante quando há alarmes ativos.
      - **Loc**: Botão interativo. Ao clicar, ativa/desativa o LED azul neon pulsante (`#00b0ff`) E abre a **Gaveta de Inventário do Ativo** contendo dados reais do Zabbix: `system.descr`, `system.location`, `system.contact`, `system.name`, IP de gerência real obtido dinamicamente via Zabbix API, OID SNMP, link direto para a Web GUI e botão funcional de fechar (`Fechar x`).
    - **LEDs de Alerta em Portas com Queda (Link Down)**: Portas com alarmes ativos no Zabbix piscam em vermelho brilhante (`#ef4444`, `sw-port-fault-pulse`) e exibem badge `DOWN (ALARME)`.
    - **Descoberta Dinâmica de IP**: IP do switch é consultado via Zabbix API (`host.get` -> `interfaces[0].ip`) tanto no build quanto no client-side polling, atualizando cabeçalho, gaveta e links sem hardcoding.
  - **Nomenclatura 100% Autêntica do Zabbix (Zero Dados Inventados / Mock):**
    - Remoção total de mapeamentos estáticos inventados. Os nomes de interface são extraídos estritamente via regex `Interface (\d+)\(([^)]*)\)` dos itens oficiais do Zabbix.
    - Se o switch tiver descrição configurada no SNMP (`ifAlias`), ela é usada; se não estiver configurada no switch (parênteses vazios), o painel adota exclusivamente a identificação física real de hardware: `Porta X`, `GigabitEthernetX`, `1GbE RJ45` (portas 1-24) e `SFP+ X`, `SFP+ 10G` (portas 25-28).
  - **Widget Compacto "Top Talkers" (Top 3 Consumidores de Tráfego em Tempo Real):**
    - Posicionado na coluna direita acima da timeline de eventos, ajustado exatamente para **Top 3** (1º Dourado, 2º Prata, 3º Bronze).
    - Exibe ranking dinâmico com badge ordinal, porta física, tráfego total somado, barra de progresso proporcional e detalhamento *In* / *Out*.
    - Ao clicar em qualquer item do ranking, a porta é imediatamente selecionada no switch, atualizando os KPIs, cards de velocidade e o osciloscópio histórico Canvas.
  - **Alinhamento Reto e Perfeito de Altura (Zero Espaço Desperdiçado):**
    - O card esquerdo (Gráfico Canvas + Controles + Estatísticas) e os cards direitos (Top 3 + Alertas/Eventos de Porta) estão nivelados na mesma linha reta inferior, replicando com precisão a referência visual enviada pelo usuário (sem espaços pretos vazios ou bordas esticadas).
  - **Drag-to-Zoom Interativo no Gráfico Canvas (Brush Zoom & Reset Zoom):**
    - Seleção de intervalo com arraste do mouse (caixa translúcida ciano com borda tracejada `#00b0ff`).
    - Ao soltar o mouse, o gráfico dá zoom instantâneo nos pontos de amostragem selecionados, reajustando automaticamente os eixos X e Y.
    - Botão `[ ↺ RESET ZOOM ]` com bind explícito de eventos JS (`onclick`, `onmousedown`, `ontouchend`) contornando a sanitização do Grafana Business Text, com atalho complementar de duplo clique.
    - Preservação inteligente de zoom contra colisões do polling periódico em background (15s).
  - **Painel de Eventos de Porta em Tempo Real (`event.get`):**
    - Eventos cronológicos reais retornados pelo Zabbix (Top 5 eventos compactos para perfeito equilíbrio de altura).
  - **Escala Dinâmica e Adaptativa de Tráfego de Rede (bps, Kb/s, Mb/s, Gb/s):**
    - Algoritmo inteligente transversal cobrindo KPIs, detalhe de porta, Top Talkers, hover tooltips de portas e réguas/tooltips do gráfico Canvas.
  - **Backups de Segurança Preservados:**
    - `scripts/build_aruba_interactive_twin.v51.backup.ps1`
    - `grafana/dashboards/aruba_instant_on_1930.v51.backup.json`
    - `grafana/dashboards/aruba_interactive_twin.v51.backup.html`
  - **Script de automação:** `scripts/build_aruba_interactive_twin.ps1` (versão 55 publicada com sucesso no Grafana) e exportação sanitizada em `grafana/dashboards/aruba_instant_on_1930.json`.
  - **Repositório GitHub:** `https://github.com/IDhexter/Grafana-Switch` (branch `main`).

---
> **INSTRUÇÃO EXPLÍCITA PARA A IA:**
> Ao iniciar uma nova sessão ou retomar este projeto, a IA DEVE LER OBRIGATORIAMENTE TODOS OS ARQUIVOS DA PASTA `.ia` (`MEMORY.md`, `ARCHITECTURE.md`, `RULES.md`, `TASKS.md`, `RUNBOOK.md`) antes de responder ao usuário ou tomar qualquer ação no código.
