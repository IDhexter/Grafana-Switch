# Regras do Workspace & Memória Persistente (Zabbix-Grafana & Grafana-Modens)

## 1. Separação Estrita de Repositórios GitHub (REGRA CRÍTICA)
- **Switches (Aruba / HPE / 1930 / 1960):**
  - Repositório: `https://github.com/IDhexter/Grafana-Switch.git`
  - Workspace: `c:\Users\alexs\Documents\Antigravity\Home - ASUS TUF R16\Zabbix-Grafana`
  - Dashboards Principais:
    - `Aruba 1960 - Gêmeo Digital Tempo Real (v58)` (`UID: aruba-1960-realtime-twin`)
    - `[BAMEX] - SW01 - Aruba Instant On 1930 (10.50.0.2)` (`UID: alpt2p5`, HostID: 10682)
    - `[BAMEX] - SW02 - Aruba Instant On 1930 (10.50.0.4)` (`UID: bamex-sw02`, HostID: 10772)
    - `[BAMEX] - SW03 - Aruba Instant On 1930 (10.50.0.5)` (`UID: bamex-sw03`, HostID: 10773)
    - `[BAMEX] - SW04 - Aruba Instant On 1930 (10.50.0.6)` (`UID: bamex-sw04`, HostID: 10774)
  - Script Gerador Automatizado: `scripts/build_aruba_interactive_twin.ps1`
- **Modems & Links WAN (`SGS_LINKS_GRAFANA` / `SGS_LINKS`):**
  - Repositório Exclusivo: `https://github.com/IDhexter/Grafana-Modens.git`
  - Diretório Local Dedicado: `C:\Users\alexs\Documents\Antigravity\Grafana-Modens`
  - Dashboard: `[SGS] - Modems & Links WAN (SGS_LINKS)` (`UID: sgs-modems-wan`, Pasta `POC ALEX`, `Folder ID: 136`, versão `v12+`)
  - Script Gerador: `scripts/build_sgs_modem_twin.py`
  - **IMPORTANTE:** Nunca envie arquivos de Modems para o repositório de Switches, e nunca inclua imagens ou scripts de Switches no repositório `IDhexter/Grafana-Modens`.

## 2. Padrões de Produção (Modems & Switches)
- **Zero Estética Falsa:** Todos os LEDs (`PWR`, `PON/LINK`, `INTERNET`, `LOS/ALM`, `Cloud`, `Fault`), gaiolas ópticas (`WAN SFP`, `Uplinks 10G`) e portas (`LAN 1–4`, `Portas 1–28`) são 100% funcionais em produção, refletindo o status SNMP real no Zabbix e permitindo clicar para inspecionar a interface no Osciloscópio.
- **Chassi 1U Zero-Clipping:** O design visual do chassi Aruba 1930 deve manter proporções responsivas milimétricas para que todas as 28 portas físicas (24x RJ45 + 4x SFP+ 10G) e as duas orelhas laterais de rack sejam renderizadas com 100% de integridade, sem corte horizontal mesmo com a barra lateral do Grafana aberta.
- **Barra de Comutação Rápida de Frota:** Todos os dashboards de switches de um mesmo rack/site devem conter barra superior de navegação cruzada (`pollBamexFleetStatus()`), exibindo LEDs de saúde em tempo real e atalhos com 1 clique para a Web GUI e Inventário MIB-2 do ativo.
- **Auto-Discovery Dinâmico (`SGS_LINKS_GRAFANA`):** A função `syncCatalogFromZabbix()` roda direto no navegador (no boot, a cada 45s e no botão `↻ SYNC`). Tudo o que o NOC colocar no grupo `SGS_LINKS_GRAFANA` no Zabbix entra automaticamente na dashboard (com fallback transparente para `SGS_LINKS` enquanto `SGS_LINKS_GRAFANA` estiver vazio).
- **Osciloscópio HTML5 Canvas (v12 Precision):**
  - Linha guia tracejada no hover (`setLineDash([3, 3])`), bolinhas amostrais nas curvas, auréolas luminosas (*target halos*).
  - Cápsula HUD flutuante no topo (`[ HH:MM:SS | ● In: X | ● Out: Y | Total: Z ]`).
  - Linha tracejada amarela de referência de **Percentil 95 (`P95`)** e mini-card de KPI dourado com valor sustentado.
  - Mini-card de **Pico na Janela** com indicação exata do minuto do evento (`ÀS HH:MM`).
  - Janelas `1h | 3h | 6h | 12h | 24h | 7d` com fallback transparente para `trend.get` (`value_max`/`value_avg`) em 7d.
  - `padLeft = 84` no Canvas para garantir que rótulos longos de tráfego do eixo Y (`Mb/s`) nunca sejam cortados.
- **Ranking Completo Filtrável:** Abas de filtro instantâneo (`ATIVAS UP`, `DEGRADADAS`, `TODAS 28`) com rolagem suave, badges de velocidade (`1G` verde, `100M` âmbar) e feed de eventos Zabbix com clique direto para abrir a porta no osciloscópio.
