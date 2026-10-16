# 🔌 Grafana Switch Digital Twin (Zabbix SNMP)

[![Grafana](https://img.shields.io/badge/Grafana-10%2B%20%7C%2011%2B-orange?logo=grafana)](https://grafana.com/)
[![Zabbix](https://img.shields.io/badge/Zabbix-6.0%20%7C%207.0%2B-red?logo=zabbix)](https://www.zabbix.com/)
[![Plugin](https://img.shields.io/badge/Business%20Text-marcusolsson--dynamictext--panel-blue)](https://grafana.com/grafana/plugins/marcusolsson-dynamictext-panel/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Production Ready](https://img.shields.io/badge/Production-Ready-00e676)](https://github.com/IDhexter/Grafana-Switch)

Uma solução completa e pronta para produção para criar **Gêmeos Digitais (Digital Twins)** interativos e fiéis ao hardware de switches de rede no **Grafana**, alimentados por telemetria SNMP em tempo real extraída diretamente do **Zabbix**.

Desenvolvido para operar em ambientes de missão crítica (NOCs, Datacenters, Provedores e Racks de Telecom), este projeto demonstra a implementação completa para o switch **Aruba Instant On 1930 24G 4SFP+ (JL682A)** e fornece a metodologia, arquitetura e scripts para reproduzir em **qualquer modelo ou fabricante de switch** (Cisco, Dell, Mikrotik, Ubiquiti, Huawei, Juniper, HP ProCurve, Fortinet).

---

## 📸 Demonstração Visual

### Painel Principal do Switch com Motor v12 Precision & Chassi 1U Zero-Clipping
![Aruba Switch Digital Twin v12](assets/bamex_sw01_dashboard.png)

---

## 🌟 Principais Recursos

1. **Modelagem Fiel de Hardware 1U (100% Zero-Clipping)**:
   * Chassi metálico usinado com orelhas de rack laterais e parafusos sextavados de fixação.
   * Disposição espacial modular em bancos (*PORTAS 1 - 12* e *PORTAS 13 - 24*) com ranhura divisória central.
   * 24 portas RJ45 GbE generosas com pinos dourados, travas RJ45 e LEDs duplos de status/atividade por porta.
   * 4 gaiolas metálicas para módulos SFP+ 10GbE em grade 2x2.
   * **Layout Responsivo Perfeito**: Proporções recalibradas para que 100% das 28 portas e fixações permaneçam visíveis sem qualquer corte horizontal, mesmo com a barra lateral do Grafana aberta em monitores padrão.

2. **Barra de Comutação Rápida entre Switches da Frota (Multi-Switch Selector)**:
   * Navegação direta entre múltiplos switches do mesmo rack/site (`SW01`, `SW02`, `SW03`, `SW04`) no topo do painel.
   * **LEDs de Saúde em Tempo Real**: Rotina `pollBamexFleetStatus()` consulta os switches em background, exibindo status verde/âmbar e contagem de portas ativas.
   * Atalhos com 1 clique para copiar o IP do switch (`IP: 10.50.0.X ❐`), abrir a **Web GUI nativa do equipamento** e abrir a **Gaveta de Inventário Técnico SNMP**.

3. **LEDs de Sistema Inteligentes Conectados à Telemetria Real**:
   * ☁️ **Cloud**: Pulsa em ciano durante chamadas da API do Zabbix. Fica verde esmeralda contínuo em caso de sucesso (com tooltip do timestamp da sincronização) e âmbar em caso de erro. Permite clique direto para forçar sincronização imediata.
   * ⚡ **Power**: Monitora a disponibilidade operacional do switch via `icmpping`. Fica verde quando o switch está online e vermelho caso o ping falhe.
   * 🚨 **Fault**: Integrado à chamada `problem.get` do Zabbix. Acende em vermelho pulsante em caso de alarmes e sincroniza o card interativo de alertas.
   * 🔍 **Loc (Inventário Técnico do Ativo)**: Abre uma gaveta lateral com dados cadastrais oficiais do Zabbix via SNMP MIB-2 (`sysDescr`, `sysLocation`, `sysContact`, serial, firmware, Linux kernel, U-Boot e consumo PoE).

4. **Detecção e Destaque de Portas Degradadas**:
   * Identifica automaticamente portas operacionais (`OperStatus == UP`), mas com velocidade auto-negociada rebaixada para **100 Mb/s (Fast Ethernet)** ou **10 Mb/s** (em vez do 1 Gb/s nativo).
   * Destaca essas portas em **Âmbar (`#f59e0b`)** no painel frontal e cria chips clicáveis de atalho (ex: `⚠ Porta 12 (100M)`), que selecionam imediatamente a porta no gráfico.

5. **Osciloscópio v12 Precision Canvas (HTML5 Canvas + ResizeObserver)**:
   * **Linha de Referência Percentil 95 (`P95`)**: Renderizada em linha amarela tracejada com mini-card dourado de KPI indicando a taxa sustentada.
   * **Pico com Carimbo de Data/Hora**: Mini-card exibindo o pico máximo na janela e o minuto exato em que ocorreu (`ÀS HH:MM`).
   * **Janelas Temporais Expandidas (`1h | 3h | 6h | 12h | 24h | 7d`)**: Chaveamento automático de granularidade; para 7 dias, utiliza transparentemente a API `trend.get` do Zabbix para evitar payloads pesados e lentidão.
   * **Inspeção no Hover Avançada**: Linha guia tracejada, bolinhas amostrais nas curvas, auréolas luminosas (*target halos*) e cápsula flutuante (*HUD Pill*) no topo exibindo `[ HH:MM:SS | ● In | ● Out | Total ]`.
   * **Zero Corte no Eixo Y**: `padLeft = 84` no Canvas garantindo margem perfeita para valores de tráfego.

6. **Ranking de Portas Completo e Filtrável**:
   * Substituição do antigo "TOP 3" estático por um catálogo navegável completo com abas: `ATIVAS UP`, `DEGRADADAS` e `TODAS 28`.
   * Medalhas visuais (1º Ouro, 2º Prata, 3º Bronze), badges de velocidade (`1G` verde, `100M` âmbar) e mini barras de ocupação.

7. **Painel de Eventos de Porta em Tempo Real (Zabbix `event.get`)**:
   * Linha do tempo cronológica com os últimos eventos de link das interfaces do switch com selo de gravidade (`RESOLVIDO` / `PROBLEMA`) e clique direto para abrir a porta no osciloscópio.

8. **Filtro Crítico de Interfaces Virtuais SNMP**:
   * Pipeline possui filtros estritos tanto no PowerShell quanto no JavaScript do navegador para ignorar `ifIndex >= 100000`, impedindo que interfaces lógicas sobrescrevam a velocidade real da porta física.

---

## 🏗️ Arquitetura de Dados

```mermaid
flowchart TD
    subgraph CPD["Rack CPD / Datacenter"]
        SW["Switch Físico (ex: Aruba 1930 / Cisco 2960)"]
    end

    subgraph ZABBIX["Infraestrutura Zabbix (Zabbix Server / API)"]
        POLL["Zabbix Poller (SNMPv2 / SNMPv3 a cada 15s)"]
        DB[("Zabbix Database (History & Items)")]
        API["Zabbix JSON-RPC API (/api_jsonrpc.php)"]
        POLL -->|"IF-MIB & MIB-2"| DB
        DB --> API
    end

    subgraph GRAFANA["Servidor Grafana (Grafana Server)"]
        DASH["Dashboard: POC - Switch Digital Twin"]
        PANEL["Plugin: marcusolsson-dynamictext-panel"]
        DASH --> PANEL
    end

    subgraph CLIENT["Navegador do Operador (NOC / TV / Desktop)"]
        UI["Interface Digital Twin (HTML5 + CSS3 + Canvas 2D)"]
        JS["Motor JavaScript (afterRender)"]
        UI <--> JS
    end

    SW -->|"SNMP Requests"| POLL
    PANEL -->|"Renderiza HTML + CSS + JS"| UI
    JS -->|"Direct CORS fetch() (15s polling & history.get)"| API
```

---

## 📋 Pré-Requisitos

1. **Zabbix Server (v6.0, v6.4 ou v7.0+)**:
   * Switch monitorado via SNMP com template padrão de rede (`Network Generic Device by SNMP` ou similar).
   * Token de API gerado no Zabbix (*Administration ➔ API Tokens* ou *Users ➔ API Tokens*).
2. **Grafana (v10+ ou v11+)**:
   * Plugin **Business Text** instalado:
     ```bash
     grafana-cli plugins install marcusolsson-dynamictext-panel
     ```
   * Reinicie o serviço do Grafana após a instalação (`systemctl restart grafana-server` ou equivalente).
3. **PowerShell (v5.1+ no Windows ou PowerShell 7+ no Linux/macOS)**.

---

## 🚀 Como Executar o Deploy Automatizado (3 Minutos)

### Opção 1: Deploy Automatizado via PowerShell (Recomendado)

1. **Clone o repositório**:
   ```bash
   git clone https://github.com/IDhexter/Grafana-Switch.git
   cd Grafana-Switch
   ```

2. **Crie e configure seu arquivo `.env`**:
   Copie o modelo de exemplo:
   ```bash
   cp .env.example .env
   ```
   Edite com os dados do seu ambiente:
   ```ini
   # ZABBIX
   ZABBIX_URL="http://<IP_DO_ZABBIX>/api_jsonrpc.php"
   ZABBIX_TOKEN="seu_token_api_zabbix_aqui"
   ZABBIX_HOST_ID="10001"

   # GRAFANA
   GRAFANA_URL="http://<IP_DO_GRAFANA>:3000"
   GRAFANA_DASHBOARD_UID="seu_dashboard_uid"
   GRAFANA_USER="seu_usuario_grafana"
   GRAFANA_PASSWORD="sua_senha_grafana"
   ```

3. **Execute o script de compilação e deploy**:
   ```powershell
   # Deploy padrão (utiliza variáveis do .env):
   powershell -ExecutionPolicy Bypass -File scripts\build_aruba_interactive_twin.ps1

   # Ou deploy parametrizado para qualquer switch específico:
   powershell -ExecutionPolicy Bypass -File scripts\build_aruba_interactive_twin.ps1 `
     -TargetHostId "10682" `
     -TargetDashboardUid "alpt2p5" `
     -TargetDashboardTitle "[BAMEX] - SW01 - Aruba Instant On 1930 (10.50.0.2)" `
     -TargetSwitchShortName "SW01" `
     -TargetSwitchIp "10.50.0.2"
   ```
   O script irá:
   * Conectar à API do Zabbix e coletar a telemetria inicial de todas as 28 portas.
   * Detectar automaticamente interfaces ativas, degradadas e tráfego total.
   * Compilar o HTML usinado e o motor JavaScript do Canvas responsivo.
   * Publicar ou atualizar o dashboard diretamente na API do Grafana.

4. **Abra o Grafana**:
   Acesse a URL informada pelo terminal e visualize o switch operando ao vivo!

> 📘 Para detalhes completos da arquitetura e comparativo técnico, consulte o [Manual Técnico do Gêmeo Digital (SW01 BAMEX)](docs/BAMEX_SW01_DIGITAL_TWIN.md).

---

### Opção 2: Importação Direta do Dashboard JSON no Grafana

Se preferir não rodar scripts e importar manualmente pelo navegador:

1. Baixe o arquivo sanitizado [`grafana/dashboards/aruba_instant_on_1930.json`](grafana/dashboards/aruba_instant_on_1930.json).
2. No Grafana, vá em **Dashboards ➔ New ➔ Import**.
3. Carregue o arquivo JSON ou cole seu conteúdo.
4. No painel Dynamic Text importado, edite a aba **After Content Ready** substituindo as variáveis `__ZABBIX_URL_PLACEHOLDER__` e `__ZABBIX_TOKEN_PLACEHOLDER__` pelas credenciais do seu Zabbix.
5. Salve o dashboard.

---

## 📖 Guia de Replicação para Qualquer Outro Switch (Cisco, Dell, HP, Mikrotik, etc.)

A arquitetura do projeto foi projetada de forma modular. Para replicar para **qualquer outro switch**, basta seguir estes passos:

### 1. Mapeamento dos Itens SNMP no Zabbix
Todo switch gerenciado expõe as métricas padronizadas pela MIB-II (`RFC 1213` e `IF-MIB`):

| Métrica | Chave do Item no Zabbix | Significado / Valores |
| :--- | :--- | :--- |
| **Status Operacional** | `net.if.status[ifOperStatus.X]` | `1` = UP (Verde), `2` = DOWN (Cinza) |
| **Velocidade** | `net.if.speed[ifHighSpeed.X]` ou `net.if.speed[ifSpeed.X]` | `1000000000` = 1 Gbps, `100000000` = 100 Mbps |
| **Tráfego Entrada (In)** | `net.if.in[ifHCInOctets.X]` | Bits por segundo (calculado via delta Zabbix) |
| **Tráfego Saída (Out)** | `net.if.out[ifHCOutOctets.X]` | Bits por segundo (calculado via delta Zabbix) |
| **Erros de Entrada** | `net.if.in.errors[ifInErrors.X]` | Contador de pacotes descartados / CRC |
| **Localização Física** | `system.location[sysLocation.0]` | MIB-2 padrão (`Rack CPD`, `Sala TI`) |
| **Contato do Responsável**| `system.contact[sysContact.0]` | MIB-2 padrão (`NOC`, `Engenharia`) |
| **Disponibilidade** | `icmpping` | `1` = Online (Power Verde), `0` = Offline (Power Vermelho) |

### 2. Adaptação do Layout Físico
No script PowerShell:
* **Switch de 24 Portas**: 2 linhas de 12 portas (Ímpares em cima `1, 3, 5... 23`, Pares embaixo `2, 4, 6... 24`).
* **Switch de 48 Portas**: 2 linhas de 24 portas (Ímpares `1, 3... 47`, Pares `2, 4... 48`).
* **Uplinks Ópticos (SFP+ / QSFP)**: Gaiolas posicionadas à direita com identificação de 10G, 25G, 40G ou 100G.

### 3. Ajuste do Host ID
No `.env`, altere `ZABBIX_HOST_ID` para o ID do novo switch no Zabbix e rode o script novamente.

---

## ⚠️ Armadilhas Técnicas e Gotchas de Produção (Obrigatório Conhecer)

Se você for desenvolver ou customizar painéis com o plugin **Business Text (`marcusolsson-dynamictext-panel`)**, guarde estas lições aprendidas em produção:

### 1. A Armadilha de Indentação Markdown
> [!CAUTION]
> O plugin Business Text interpreta o conteúdo HTML através de um parser CommonMark. **Qualquer linha com 4 espaços ou mais de indentação que seja precedida por uma linha em branco é tratada como bloco de código (`<pre><code>`)**.
> 
> Se isso acontecer, seu HTML será escapado e exibido como texto puro monoespaçado na tela, quebrando o DOM e desativando o JavaScript.
> 
> **Solução**: Sempre processe a string HTML no PowerShell com `$cleanLines = $htmlContent -split "`r?`n"` e aplique `.Trim()` para eliminar indentações e linhas vazias antes de enviar ao Grafana.

### 2. Por que Usar Botões Segmentados em Vez de `<select>` Nativo no Grafana
> [!WARNING]
> O Grafana roda sobre React 18, que possui um sistema de eventos sintéticos para formulários.
> * Tags `<select>` nativas sofrem interferência de CSS global do Grafana (`appearance: none;`), fazendo com que o texto selecionado fique invisível no tema escuro.
> * O evento inline `onchange="..."` de um `<select>` nativo pode ser suprimido pelo React, impedindo a atualização do gráfico.
> 
> **Solução**: Utilize botões segmentados (`<button type="button">`) com classes e `onclick="..."`. Eles oferecem feedback visual imediato (botão ativo em ciano), não sofrem interferência do React e executam a troca de dados instantaneamente.

### 3. Filtro de Interfaces Virtuais (`ifIndex >= 100000`)
> [!IMPORTANT]
> O firmware de switches modernos (como Aruba CX, Instant On e Cisco) gera interfaces lógicas internas (`propVirtual`) que repetem os nomes das interfaces físicas (ex: `Interface 1()`), mas com `ifIndex` alto (ex: `ifSpeed.100000 = 0`).
> 
> Se não filtradas, a interface virtual sobrescreve a porta física real, exibindo velocidade zerada (`--`).
> 
> **Solução**: Sempre filtre com `if ($key -match '\.(\d+)\]') { if ([int64]$matches[1] -ge 100000) { continue } }` tanto no PowerShell quanto no JavaScript do navegador.

### 4. Ciclo de Vida do React e Limpeza de Timers
> [!TIP]
> A cada atualização de variáveis do dashboard, o Grafana reexecuta o script `afterRender`. Se você criar um `setInterval` sem limpá-lo, múltiplos timers se acumularão, sobrecarregando o navegador e o Zabbix.
> 
> **Solução**: Guarde as instâncias no escopo global (`window.__aruba_zabbix_timer`) e execute `clearInterval` antes de instanciar novos timers.

---

## 📂 Estrutura do Repositório

```text
├── assets/
│   ├── aruba_switch_dashboard.png       # Screenshot em produção (Dashboard com 24h ativo)
│   └── port_selection_click.png         # Screenshot de detalhe de porta selecionada
├── grafana/
│   └── dashboards/
│       ├── aruba_interactive_twin.html  # Template HTML puro gerado pelo pipeline
│       └── aruba_instant_on_1930.json   # Dashboard exportado e 100% sanitizado para importação direta
├── scripts/
│   ├── build_aruba_interactive_twin.ps1 # Script principal de automação, compilação e deploy via REST API
│   ├── export_sanitized_dashboard.ps1   # Script utilitário para exportar o JSON limpo sem senhas
│   └── git_commit_and_push.ps1          # Utilitário seguro para versionamento com Git
├── .env.example                         # Arquivo de exemplo para configuração rápida
├── .gitignore                           # Proteção de credenciais locais (.env) e arquivos scratch
└── README.md                            # Esta documentação completa
```

---

## 📄 Licença

Este projeto está sob a licença [MIT](LICENSE) - sinta-se livre para usar, adaptar, modificar e estender para seus próprios switches, data centers e clientes.

---

**Desenvolvido por [IDhexter](https://github.com/IDhexter)**  
*Observabilidade Avançada, Automação de Infraestrutura de Redes, Zabbix & Grafana.*
