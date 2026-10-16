# Documentação Técnica: Gêmeo Digital do Switch Aruba Instant On 1930 (SW01 BAMEX)

> **Ativo:** Switch SW01-BAMEX • Aruba Instant On 1930 24G 4SFP+ (JL682A)  
> **IP de Gerência:** `10.50.0.2`  
> **HostID Zabbix:** `10682`  
> **Grafana Dashboard UID:** `alpt2p5`  
> **Pasta Grafana:** `POC ALEX` (`Folder ID: 136`)  
> **Script Gerador Automatizado:** `scripts/build_aruba_interactive_twin.ps1`  
> **Repositório GitHub:** `https://github.com/IDhexter/Grafana-Switch.git`

---

## 1. Visão Geral da Arquitetura

O Gêmeo Digital (*Digital Twin*) em tempo real do Switch Aruba 1930 é renderizado através de uma única camada híbrida no Grafana utilizando o plugin `marcusolsson-dynamictext-panel`. Ele combina:

1. **Compilação em Build-time (PowerShell + Zabbix API):**
   - O script `build_aruba_interactive_twin.ps1` conecta-se à API JSON-RPC do Zabbix (`http://10.10.1.26/api_jsonrpc.php`).
   - Mapeia automaticamente as 28 portas físicas (24 portas 1GbE RJ45 + 4 gaiolas SFP+ 10G) descobrindo os `itemid` das métricas de tráfego de entrada (`net.if.in`), tráfego de saída (`net.if.out`), status operacional (`net.if.status`), velocidade negociada (`net.if.speed`), erros/descartes e consumo PoE.
   - Gera o layout HTML estático pré-renderizado, estilos CSS industriais e injeta o código JavaScript de runtime reativo.
   - Publica o dashboard via REST API do Grafana (`/api/dashboards/db`) com overwrite atômico.

2. **Runtime Reativo em Tempo Real no Navegador (JavaScript Canvas & Polling):**
   - **Ciclo de Telemetria Zabbix (15 s):** Atualiza de forma assíncrona o status das 28 portas, consumo agregado, alarmes (`problem.get`), eventos recentes (`event.get`) e uptime.
   - **Monitoramento da Frota BAMEX (30 s):** A função `pollBamexFleetStatus()` consulta os 4 switches da empresa (`SW01`, `SW02`, `SW03`, `SW04`) em paralelo e atualiza os LEDs de status na barra de navegação superior.
   - **Osciloscópio HTML5 Canvas (60 FPS):** Motor gráfico de alta performance com curvas suaves de entrada/saída, cálculo matemático de Percentil 95 (`P95`), detecção de picos com carimbo de data/hora, linha guia no hover, auréolas luminosas (*target halos*) e cápsula flutuante (*HUD Pill*).

---

## 2. Mapa Comparativo: Versão Anterior vs Versão Atual

| Recurso | Versão Anterior | Versão Atualizada (Upgrade) |
|---|---|---|
| **Corte Lateral do Chassi 1U** | Chassi cortava horizontalmente as portas SFP+ 25–28 e a orelha direita em telas de 1600px com menu aberto. | **Zero-Clipping Responsivo:** Proporções redimensionadas, 24 portas RJ45 + 4 SFP+ 10G e ambas as orelhas de rack visíveis com 100% de integridade. |
| **Comutação entre Switches** | Inexistente. Operador precisava voltar ao menu do Grafana para trocar de switch. | **Barra de Navegação BAMEX Fleet:** Atalhos instantâneos para `SW01`, `SW02`, `SW03`, `SW04` com LEDs de saúde ao vivo e contagem de portas UP. |
| **Acesso ao Switch & IP** | IP estático em texto simples. | **IP Interativo com Cópia:** Badge `IP: 10.50.0.2 ❐` com feedback visual imediato + botão direto `WEB GUI (10.50.0.2) ↗`. |
| **Gaveta de Inventário** | Inexistente. | **Drawer de Inventário e Diagnóstico:** Botão `ℹ INVENTÁRIO SNMP & WEB GUI` com especificações do hardware, serial, firmware e OIDs. |
| **KPIs de Topo** | Cards meramente informativos. | **Cards Interativos:** Clicar em `PORTAS ATIVAS` filtra a lista para portas UP; clicar em `ALERTAS` ou `VELOCIDADE DEGRADADA` seleciona diretamente a porta afetada. |
| **Detecção de Velocidade Degradada** | Contagem simples em texto. | **Chips Dinâmicos:** Identifica portas negociadas em 10/100 Mbps (Fast Ethernet) com chip âmbar clicável (ex: `⚠ Porta 12 (100M)`). |
| **Tráfego Agregado** | Apenas valor total em Mb/s. | **Decomposição Direcional:** Tráfego total com detalhamento em tempo real de `↓ In: X Mb/s • ↑ Out: Y Mb/s`. |
| **Osciloscópio: Linha P95** | Inexistente. | **Linha de Referência Percentil 95:** Linha amarela tracejada no gráfico + Mini-card de KPI dourado com valor sustentado. |
| **Osciloscópio: Pico** | Inexistente. | **Pico com Carimbo de Data/Hora:** Exibe o valor de pico na janela e o minuto exato do evento (ex: `22.06 Mb/s ÀS 12:46`). |
| **Osciloscópio: Janelas de Tempo** | Apenas 3h, 6h, 12h, 24h. | **1h, 3h, 6h, 12h, 24h e 7d:** Com fallback inteligente para `trend.get` na janela de 7 dias para evitar sobrecarga no Zabbix. |
| **Osciloscópio: Hover & HUD** | Sem guia vertical no hover. | **Inspeção HUD Pro:** Linha guia tracejada, bolinhas amostrais nas curvas, auréolas luminosas e cápsula superior flutuante com In/Out/Total. |
| **Ranking de Portas** | Limitado a apenas 3 itens fixos. | **Ranking Completo com Filtros:** Abas `ATIVAS UP (8)`, `DEGRADADAS (1)` e `TODAS (28)` com rolagem, medalhas, barras e status detalhado. |
| **Feed de Eventos Zabbix** | Eventos estáticos. | **Feed Interativo de Eventos:** Últimos 5 eventos com badges `RESOLVIDO` / `PROBLEMA` e clique direto para abrir a porta no osciloscópio. |

---

## 3. Como Reproduzir para Qualquer Switch da Rede

O script `scripts/build_aruba_interactive_twin.ps1` é **100% modular e parametrizado**. É possível criar ou atualizar qualquer switch Instant On 1930 / 1960 ou switch gerenciado executando apenas uma linha no terminal PowerShell:

### Exemplo de Comando de Reprodução:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_aruba_interactive_twin.ps1 `
  -TargetHostId "10682" `
  -TargetDashboardUid "alpt2p5" `
  -TargetDashboardTitle "[BAMEX] - SW01 - Aruba Instant On 1930 (10.50.0.2)" `
  -TargetSwitchShortName "SW01" `
  -TargetSwitchIp "10.50.0.2"
```

### Reprodução em Lote para Todos os Switches da Frota:
```powershell
# SW01
powershell -ExecutionPolicy Bypass -File .\scripts\build_aruba_interactive_twin.ps1 -TargetHostId "10682" -TargetDashboardUid "alpt2p5" -TargetDashboardTitle "[BAMEX] - SW01 - Aruba Instant On 1930 (10.50.0.2)" -TargetSwitchShortName "SW01" -TargetSwitchIp "10.50.0.2"

# SW02
powershell -ExecutionPolicy Bypass -File .\scripts\build_aruba_interactive_twin.ps1 -TargetHostId "10772" -TargetDashboardUid "bamex-sw02" -TargetDashboardTitle "[BAMEX] - SW02 - Aruba Instant On 1930 (10.50.0.4)" -TargetSwitchShortName "SW02" -TargetSwitchIp "10.50.0.4"

# SW03
powershell -ExecutionPolicy Bypass -File .\scripts\build_aruba_interactive_twin.ps1 -TargetHostId "10773" -TargetDashboardUid "bamex-sw03" -TargetDashboardTitle "[BAMEX] - SW03 - Aruba Instant On 1930 (10.50.0.5)" -TargetSwitchShortName "SW03" -TargetSwitchIp "10.50.0.5"

# SW04
powershell -ExecutionPolicy Bypass -File .\scripts\build_aruba_interactive_twin.ps1 -TargetHostId "10774" -TargetDashboardUid "bamex-sw04" -TargetDashboardTitle "[BAMEX] - SW04 - Aruba Instant On 1930 (10.50.0.6)" -TargetSwitchShortName "SW04" -TargetSwitchIp "10.50.0.6"
```

---

## 4. Estrutura dos Arquivos do Projeto (Repositório Switches)

- [`scripts/build_aruba_interactive_twin.ps1`](file:///c:/Users/alexs/Documents/Antigravity/Home%20-%20ASUS%20TUF%20R16/Zabbix-Grafana/scripts/build_aruba_interactive_twin.ps1): Script mestre PowerShell responsável pela extração SNMP, modelagem e publicação no Grafana.
- [`grafana/dashboards/aruba_interactive_twin.html`](file:///c:/Users/alexs/Documents/Antigravity/Home%20-%20ASUS%20TUF%20R16/Zabbix-Grafana/grafana/dashboards/aruba_interactive_twin.html): Template unificado HTML + CSS + JS gerado para inspeção e testes locais offline.
- [`.env`](file:///c:/Users/alexs/Documents/Antigravity/Home%20-%20ASUS%20TUF%20R16/Zabbix-Grafana/.env): Variáveis de ambiente (`ZABBIX_URL`, `ZABBIX_TOKEN`, `GRAFANA_URL`, `GRAFANA_USER`, `GRAFANA_PASSWORD`).
