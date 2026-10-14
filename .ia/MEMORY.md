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
- **Fase:** Produção / POC Avançada de Gêmeo Digital (Digital Twin) de Ativos de Rede (v50).
- **Ambientes Conectados (Ativos):**
  - **Zabbix API:** `http://10.0.0.26/api_jsonrpc.php` (Host ID do Switch mapeado via `.env`, IP de gerência descoberto dinamicamente via `host.get`).
  - **Grafana:** `http://10.0.0.25:3000` (Dashboard UID: `alpt2p5`).
  - **Repositório GitHub:** `https://github.com/IDhexter/Grafana-Switch` (branch `main`).
- **O que está 100% funcionando:**
  - **Gêmeo Digital do Switch Aruba Instant On 1930 24G 4SFP+ (JL682A)**:
    - Layout generoso e espaçado (portas RJ45 de 50x60px, SFP+ 10G em 2x2, bancos modulares 1-12 e 13-24).
    - **4 LEDs de Diagnóstico do Chassi conectados à telemetria:**
      - **Cloud**: Pulsa ciano no fetch, verde esmeralda no sucesso, âmbar em erro, clique manual para sincronizar.
      - **Power**: Verde para ping `icmpping` UP, vermelho se inacessível.
      - **Fault**: Conectado a `problem.get` (sem `recent: true` para ignorar eventos já resolvidos); apagado/cinza neutro quando saudável, vermelho pulsante quando há alarmes ativos.
      - **Loc**: Botão interativo. Ao clicar, ativa/desativa o LED azul neon pulsante (`#00b0ff`) E abre a **Gaveta de Inventário do Ativo** contendo dados reais do Zabbix: `system.descr`, `system.location`, `system.contact`, `system.name`, IP de gerência real obtido dinamicamente via Zabbix API, OID SNMP, link direto para a Web GUI e botão funcional de fechar (`Fechar x`).
    - **LEDs de Alerta em Portas com Queda (Link Down)**: Portas com alarmes ativos no Zabbix piscam em vermelho brilhante (`#ef4444`, `sw-port-fault-pulse`) e exibem badge `DOWN (ALARME)`.
    - **Descoberta Dinâmica de IP**: IP do switch é consultado via Zabbix API (`host.get` -> `interfaces[0].ip`) tanto no build quanto no client-side polling, atualizando cabeçalho, gaveta e links sem hardcoding.
  - **Gráfico Histórico Interativo de Tráfego (`history.get`):**
    - Substituição total da senoide matemática por um gráfico de área e linha de alta fidelidade desenhado em HTML5 Canvas, consumindo os últimos pontos reais de telemetria SNMP (`net.if.in` e `net.if.out`) do Zabbix para a porta selecionada.
    - **Totalmente Interativo:**
      - Mira vertical (crosshair) com snap nos pontos de amostragem ao passar o mouse.
      - Alvos ampliados com anel brilhante nas curvas Inbound e Outbound no ponto inspecionado.
      - Tooltip HUD flutuante com timestamp exato (`HH:mm:ss`), tráfego de entrada, saída e total somado.
      - Alternância de visibilidade de séries clicando nos itens da legenda (*Entrada (Inbound)* e *Saída (Outbound)*).
  - **Painel de Eventos de Porta em Tempo Real (`event.get`):**
    - Substituição do texto estático por eventos cronológicos reais retornados pelo Zabbix (ex: quedas e recuperações de portas, timestamps exatos `HH:mm:ss`, badges coloridos de `RESOLVIDO` / `PROBLEMA`).
  - **Resolução Crítica de CORS no Zabbix:**
    - O Nginx do Zabbix só permite `Content-Type` nos cabeçalhos CORS (`Access-Control-Allow-Headers: Content-Type`), bloqueando o cabeçalho `Authorization`.
    - **Regra obrigatória:** Enviar a autenticação do Zabbix **sempre dentro do corpo JSON** (`"auth": "TOKEN"`), nunca em cabeçalhos HTTP nos scripts de browser!
  - **Script de automação:** `scripts/build_aruba_interactive_twin.ps1` (versão 41 publicada no Grafana) e exportação sanitizada em `grafana/dashboards/aruba_instant_on_1930.json`.
- **Último Commit:** `c439056` (*feat(chart): add interactive crosshair, hover HUD tooltip, and series toggles to real traffic canvas*) na branch `main`.

---
> **INSTRUÇÃO EXPLÍCITA PARA A IA:**
> Ao iniciar uma nova sessão ou retomar este projeto, a IA DEVE LER OBRIGATORIAMENTE TODOS OS ARQUIVOS DA PASTA `.ia` (`MEMORY.md`, `ARCHITECTURE.md`, `RULES.md`, `TASKS.md`, `RUNBOOK.md`) antes de responder ao usuário ou tomar qualquer ação no código.
