import os
import sys
import json
import time
import requests
from dotenv import load_dotenv

load_dotenv('.env')

ZABBIX_URL = os.getenv('ZABBIX_URL', 'http://10.10.1.26/api_jsonrpc.php')
ZABBIX_TOKEN = os.getenv('ZABBIX_TOKEN')
GRAFANA_URL = os.getenv('GRAFANA_URL', 'http://10.10.1.25:3000')
GRAFANA_USER = os.getenv('GRAFANA_USER', 'admin')
GRAFANA_PASSWORD = os.getenv('GRAFANA_PASSWORD', 'admin')

DASHBOARD_TITLE = "[SGS] - Modems & Links WAN (SGS_LINKS)"
DASHBOARD_UID = "sgs-modems-wan"
TARGET_FOLDER_ID = 136  # POC ALEX

print(f"=== INICIANDO BUILD DO GÊMEO DIGITAL DE MODEMS/LINKS SGS ===")
print(f"Zabbix: {ZABBIX_URL}")
print(f"Grafana: {GRAFANA_URL} (Pasta ID: {TARGET_FOLDER_ID})")

headers = {'Authorization': f'Bearer {ZABBIX_TOKEN}', 'Content-Type': 'application/json-rpc'}

# 1. Obter todos os hosts do grupo 38 (SGS_LINKS)
print("1. Consultando hosts do grupo 38 (SGS_LINKS)...")
r_hosts = requests.post(ZABBIX_URL, json={
    'jsonrpc': '2.0',
    'method': 'host.get',
    'params': {
        'groupids': '38',
        'output': ['hostid', 'name', 'status', 'description'],
        'selectInterfaces': ['ip', 'port', 'type', 'available'],
        'selectParentTemplates': ['name']
    },
    'id': 1
}, headers=headers).json()

hosts = [h for h in r_hosts.get('result', []) if h['status'] == '0']
print(f"Encontrados {len(hosts)} hosts ativos no grupo SGS_LINKS.")

# 2. Obter itens de tráfego para os hosts
print("2. Consultando itens de tráfego (net.if) para identificar modems com telemetria ativa...")
host_ids = [h['hostid'] for h in hosts]

r_items = requests.post(ZABBIX_URL, json={
    'jsonrpc': '2.0',
    'method': 'item.get',
    'params': {
        'hostids': host_ids,
        'search': {'key_': 'net.if.'},
        'output': ['itemid', 'hostid', 'name', 'key_', 'lastvalue', 'units', 'value_type', 'status']
    },
    'id': 2
}, headers=headers).json()

items = [i for i in r_items.get('result', []) if i['status'] == '0']
print(f"Encontrados {len(items)} itens net.if ativos.")

# Também obter itens de ICMP (ping e latência)
r_icmp = requests.post(ZABBIX_URL, json={
    'jsonrpc': '2.0',
    'method': 'item.get',
    'params': {
        'hostids': host_ids,
        'search': {'key_': 'icmp'},
        'output': ['itemid', 'hostid', 'name', 'key_', 'lastvalue', 'units', 'value_type']
    },
    'id': 3
}, headers=headers).json()

icmp_items = r_icmp.get('result', [])

# Estruturar catálogo de modems e interfaces
hosts_catalog = []

for h in hosts:
    if 'switch' in h['name'].lower():
        continue
    hid = h['hostid']
    h_items = [i for i in items if i['hostid'] == hid]
    if not h_items:
        continue
    
    # Identificar interfaces agrupando pares In e Out
    # Padrão típico Zabbix: net.if.in[ifInOctets.X] ou net.if.in[ifHCInOctets.X] ou net.if.in[eth0]
    ifaces_map = {}
    
    for it in h_items:
        k = it['key_']
        # extrair índice ou nome da interface
        idx = None
        if '[' in k and ']' in k:
            param = k.split('[')[1].split(']')[0]
            # ifInOctets.2 -> 2
            if '.' in param:
                idx = param.split('.')[-1]
            else:
                idx = param
        else:
            idx = it['name']
        
        if idx not in ifaces_map:
            # limpar nome amigável da interface
            # Ex: Interface eth1(WAN): Bits received -> eth1 (WAN)
            raw_name = it['name']
            clean_name = raw_name
            if 'Interface ' in raw_name:
                clean_name = raw_name.split('Interface ')[1].split(':')[0].strip()
            elif ':' in raw_name:
                clean_name = raw_name.split(':')[0].strip()
            
            ifaces_map[idx] = {
                'id': idx,
                'name': clean_name,
                'rawName': it['name'],
                'inItem': None,
                'outItem': None,
                'errorsItem': None,
                'discardsItem': None,
                'speed': 1000000000,
                'status': 1
            }
        
        # Mapear papéis
        if 'net.if.in[' in k:
            ifaces_map[idx]['inItem'] = {
                'itemid': it['itemid'],
                'key': k,
                'valueType': it['value_type'],
                'lastvalue': float(it['lastvalue']) if it['lastvalue'] and it['lastvalue'].replace('.','',1).isdigit() else 0
            }
        elif 'net.if.out[' in k:
            ifaces_map[idx]['outItem'] = {
                'itemid': it['itemid'],
                'key': k,
                'valueType': it['value_type'],
                'lastvalue': float(it['lastvalue']) if it['lastvalue'] and it['lastvalue'].replace('.','',1).isdigit() else 0
            }
        elif 'errors' in k:
            ifaces_map[idx]['errorsItem'] = it['itemid']
        elif 'discards' in k:
            ifaces_map[idx]['discardsItem'] = it['itemid']
    
    # Filtrar apenas interfaces que têm In ou Out
    valid_ifaces = []
    for idx, ifdata in ifaces_map.items():
        if ifdata['inItem'] or ifdata['outItem']:
            valid_ifaces.append(ifdata)
    
    if not valid_ifaces:
        continue
    
    # Ordenar interfaces priorizando as que têm mais tráfego ou nomes com WAN/INTERNET
    def iface_priority(x):
        score = 0
        name_upper = x['name'].upper()
        if 'WAN' in name_upper or 'INTERNET' in name_upper or 'LINK' in name_upper:
            score += 100000000
        in_val = x['inItem']['lastvalue'] if x['inItem'] else 0
        out_val = x['outItem']['lastvalue'] if x['outItem'] else 0
        score += (in_val + out_val)
        return score
    
    valid_ifaces.sort(key=iface_priority, reverse=True)
    
    # Determinar operadora a partir do nome
    h_name = h['name']
    isp = "TELECOM"
    for op in ["VIVO", "ALGAR", "VEGANET", "DESKTOP", "HUGHESNET", "EMBRATEL", "OI", "NET", "CLARO", "EVOLNET", "GT CONECT", "DBT"]:
        if op in h_name.upper():
            isp = op
            break
    
    # Determinar IP
    ip = h.get('interfaces', [{}])[0].get('ip', 'N/A')
    
    # Verificar ICMP
    h_icmp = [i for i in icmp_items if i['hostid'] == hid]
    ping_item = next((i['itemid'] for i in h_icmp if 'icmpping[' in i['key_'] or i['key_'] == 'icmpping'), None)
    sec_item = next((i['itemid'] for i in h_icmp if 'icmppingsec' in i['key_']), None)
    loss_item = next((i['itemid'] for i in h_icmp if 'icmppingloss' in i['key_']), None)
    
    hosts_catalog.append({
        'hostid': hid,
        'name': h_name,
        'isp': isp,
        'ip': ip,
        'templates': [t['name'] for t in h.get('parentTemplates', [])],
        'interfaces': valid_ifaces,
        'pingItem': ping_item,
        'secItem': sec_item,
        'lossItem': loss_item,
        'totalTraffic': sum(((x['inItem']['lastvalue'] if x['inItem'] else 0) + (x['outItem']['lastvalue'] if x['outItem'] else 0)) for x in valid_ifaces)
    })

# Ordenar hosts pelo nome
hosts_catalog.sort(key=lambda x: x['name'])
print(f"Total de {len(hosts_catalog)} modems catalogados com sucesso!")

# Identificar os Top 5 links com maior tráfego atual
top_active = sorted(hosts_catalog, key=lambda x: x['totalTraffic'], reverse=True)[:5]
print("Top 5 Links em Consumo Agora:")
for t in top_active:
    print(f"  * {t['name']}: {t['totalTraffic']/1000000:.2f} Mbps (IP: {t['ip']}, Operadora: {t['isp']})")

# Serializar catálogo para embutir no cliente JS
catalog_json = json.dumps(hosts_catalog, ensure_ascii=False)

# 3. Construir o HTML, CSS e JavaScript do Business Text
print("3. Construindo componentes da UI (HTML, CSS, JS)...")

# HTML Content
html_content = r"""
<div class="sgs-modem-container">
  <!-- Top Control Bar -->
  <div class="sgs-top-bar">
    <div class="sgs-brand-block">
      <span class="sgs-status-orb" id="sgs-orb-status"></span>
      <div class="sgs-brand-text">
        <span class="sgs-title-main">SGS WAN GATEWAY & MODEM TWIN</span>
        <span class="sgs-title-sub">Digital Twin Gêmeo Digital • Modems & Links SNMP</span>
      </div>
    </div>
    
    <div class="sgs-selectors-group">
      <div class="sgs-field">
        <label><span class="sgs-icon">🌐</span> ATIVO / LINK (SGS_LINKS):</label>
        <select id="sgs-host-select" class="sgs-select">
          <!-- Injetado dinamicamente -->
        </select>
      </div>

      <div class="sgs-field">
        <label><span class="sgs-icon">🔌</span> INTERFACE:</label>
        <select id="sgs-iface-select" class="sgs-select">
          <!-- Injetado dinamicamente -->
        </select>
      </div>

      <div class="sgs-time-pill-group">
        <button class="sgs-time-pill" data-sec="3600">1H</button>
        <button class="sgs-time-pill" data-sec="10800">3H</button>
        <button class="sgs-time-pill active" data-sec="21600">6H</button>
        <button class="sgs-time-pill" data-sec="43200">12H</button>
        <button class="sgs-time-pill" data-sec="86400">24H</button>
      </div>

      <button id="sgs-sync-btn" class="sgs-btn-refresh" title="Atualizar Métricas Agora">
        <span class="sgs-spin-icon">↺</span>
      </button>
    </div>
  </div>

  <!-- Physical Chassis of the Modem / ONT -->
  <div class="sgs-chassis-wrap">
    <div class="sgs-chassis">
      <!-- Metallic Bevel Top -->
      <div class="sgs-chassis-top-bevel">
        <div class="sgs-vent-slots">
          <span></span><span></span><span></span><span></span><span></span>
          <span></span><span></span><span></span><span></span><span></span>
        </div>
      </div>

      <!-- Main Faceplate -->
      <div class="sgs-faceplate">
        <!-- Device Info Left -->
        <div class="sgs-device-badge">
          <div class="sgs-isp-tag" id="sgs-isp-badge">VIVO FIBRA</div>
          <div class="sgs-dev-name" id="sgs-dev-name">[SGS] SANTOS - INTERNET VIVO</div>
          <div class="sgs-dev-meta">
            <span class="sgs-meta-pill" id="sgs-dev-ip">IP: 186.200.179.145</span>
            <span class="sgs-meta-pill" id="sgs-dev-ping">LATÊNCIA: --</span>
            <span class="sgs-meta-pill" id="sgs-dev-health">STATUS: ONLINE 100%</span>
          </div>
        </div>

        <!-- Center: Authentic LED Cluster -->
        <div class="sgs-led-cluster">
          <div class="sgs-led-unit" title="Status de Alimentação Elétrica (Host UP)">
            <div class="sgs-led sgs-led-pwr sgs-led-green" id="sgs-led-pwr"></div>
            <span class="sgs-led-label">PWR</span>
          </div>
          <div class="sgs-led-unit sgs-clickable-wan" id="sgs-btn-wan-pon" title="Sincronismo Óptico / WAN (Clique para ver no osciloscópio)">
            <div class="sgs-led sgs-led-pon sgs-led-green" id="sgs-led-pon"></div>
            <span class="sgs-led-label">PON</span>
          </div>
          <div class="sgs-led-unit sgs-clickable-wan" id="sgs-btn-wan-net" title="Tráfego Internet WAN (Clique para ver no osciloscópio)">
            <div class="sgs-led sgs-led-wan sgs-led-cyan sgs-led-flicker" id="sgs-led-wan"></div>
            <span class="sgs-led-label">INTERNET</span>
          </div>
          <div class="sgs-led-unit" title="WLAN / Wi-Fi">
            <div class="sgs-led sgs-led-blue" id="sgs-led-wifi"></div>
            <span class="sgs-led-label">WI-FI</span>
          </div>
          <div class="sgs-led-separator"></div>
          
          <!-- LAN 1 to 4 Ports (Mini Receptacles with Dynamic LEDs) -->
          <div class="sgs-lan-ports" id="sgs-lan-ports">
            <div class="sgs-lan-unit" id="sgs-lan-unit-0" data-slot="0">
              <div class="sgs-mini-rj45" id="sgs-rj45-0">
                <div class="sgs-rj45-pins"><i></i><i></i><i></i><i></i></div>
              </div>
              <div class="sgs-led sgs-led-lan" id="sgs-led-lan0"></div>
              <span class="sgs-led-label" id="sgs-label-lan0">LAN 1</span>
            </div>
            <div class="sgs-lan-unit" id="sgs-lan-unit-1" data-slot="1">
              <div class="sgs-mini-rj45" id="sgs-rj45-1">
                <div class="sgs-rj45-pins"><i></i><i></i><i></i><i></i></div>
              </div>
              <div class="sgs-led sgs-led-lan" id="sgs-led-lan1"></div>
              <span class="sgs-led-label" id="sgs-label-lan1">LAN 2</span>
            </div>
            <div class="sgs-lan-unit" id="sgs-lan-unit-2" data-slot="2">
              <div class="sgs-mini-rj45" id="sgs-rj45-2">
                <div class="sgs-rj45-pins"><i></i><i></i><i></i><i></i></div>
              </div>
              <div class="sgs-led sgs-led-lan" id="sgs-led-lan2"></div>
              <span class="sgs-led-label" id="sgs-label-lan2">LAN 3</span>
            </div>
            <div class="sgs-lan-unit" id="sgs-lan-unit-3" data-slot="3">
              <div class="sgs-mini-rj45" id="sgs-rj45-3">
                <div class="sgs-rj45-pins"><i></i><i></i><i></i><i></i></div>
              </div>
              <div class="sgs-led sgs-led-lan" id="sgs-led-lan3"></div>
              <span class="sgs-led-label" id="sgs-label-lan3">LAN 4</span>
            </div>
          </div>
        </div>

        <!-- Right Quick Meter -->
        <div class="sgs-chassis-right">
          <div class="sgs-speed-pill-box">
            <div class="sgs-speed-row">
              <span class="sgs-dir-icon in">⬇ RX:</span>
              <span class="sgs-speed-val" id="sgs-quick-in">0.00 Mb/s</span>
            </div>
            <div class="sgs-speed-row">
              <span class="sgs-dir-icon out">⬆ TX:</span>
              <span class="sgs-speed-val" id="sgs-quick-out">0.00 Mb/s</span>
            </div>
          </div>
          <button id="sgs-btn-drawer" class="sgs-btn-info" title="Inventário & Dados do Ativo">
            ℹ️ INVENTÁRIO
          </button>
        </div>
      </div>
    </div>
  </div>

  <!-- KPI Cards Grid -->
  <div class="sgs-kpi-grid">
    <div class="sgs-kpi-card sgs-kpi-in">
      <div class="sgs-kpi-header">
        <span class="sgs-kpi-title">DOWNLOAD ATUAL (IN)</span>
        <span class="sgs-kpi-badge in">RX BITS</span>
      </div>
      <div class="sgs-kpi-val" id="sgs-kpi-in-val">--</div>
      <div class="sgs-kpi-sub" id="sgs-kpi-in-sub">Amostragem em tempo real</div>
    </div>

    <div class="sgs-kpi-card sgs-kpi-out">
      <div class="sgs-kpi-header">
        <span class="sgs-kpi-title">UPLOAD ATUAL (OUT)</span>
        <span class="sgs-kpi-badge out">TX BITS</span>
      </div>
      <div class="sgs-kpi-val" id="sgs-kpi-out-val">--</div>
      <div class="sgs-kpi-sub" id="sgs-kpi-out-sub">Amostragem em tempo real</div>
    </div>

    <div class="sgs-kpi-card">
      <div class="sgs-kpi-header">
        <span class="sgs-kpi-title">PICO MÁXIMO</span>
        <span class="sgs-kpi-badge peak">MAX RX</span>
      </div>
      <div class="sgs-kpi-val" id="sgs-kpi-peak-val">--</div>
      <div class="sgs-kpi-sub" id="sgs-kpi-peak-sub">No período selecionado</div>
    </div>

    <div class="sgs-kpi-card">
      <div class="sgs-kpi-header">
        <span class="sgs-kpi-title">MÉDIA DE TRÁFEGO</span>
        <span class="sgs-kpi-badge avg">AVG RX</span>
      </div>
      <div class="sgs-kpi-val" id="sgs-kpi-avg-val">--</div>
      <div class="sgs-kpi-sub" id="sgs-kpi-avg-sub">No período selecionado</div>
    </div>

    <div class="sgs-kpi-card">
      <div class="sgs-kpi-header">
        <span class="sgs-kpi-title">SAÚDE & CONEXÃO</span>
        <span class="sgs-kpi-badge status">DISCARDS</span>
      </div>
      <div class="sgs-kpi-val" id="sgs-kpi-health-val">0 ERROS</div>
      <div class="sgs-kpi-sub" id="sgs-kpi-health-sub">Buffer e Interface</div>
    </div>
  </div>

  <!-- Main Oscilloscope Section -->
  <div class="sgs-chart-card">
    <div class="sgs-chart-header">
      <div class="sgs-chart-title-wrap">
        <span class="sgs-chart-title">OSCILOSCÓPIO DE TRÁFEGO WAN EM TEMPO REAL</span>
        <span class="sgs-chart-sub" id="sgs-chart-sub">Interface: --</span>
      </div>
      <div class="sgs-chart-legend">
        <span class="sgs-leg-item"><i class="leg-in"></i> Download (Inbound)</span>
        <span class="sgs-leg-item"><i class="leg-out"></i> Upload (Outbound)</span>
        <button id="sgs-btn-reset-zoom" class="sgs-btn-reset-zoom" style="display:none;">↺ RESET ZOOM</button>
        <span class="sgs-chart-hint">✦ arraste para zoom • duplo clique reset</span>
      </div>
    </div>
    
    <!-- Canvas container with drag-to-zoom and tooltip HUD -->
    <div class="sgs-canvas-wrap" id="sgs-canvas-wrap">
      <!-- Floating Interactive Tooltip HUD like the Switch -->
      <div id="sgs-canvas-tooltip" class="sgs-canvas-tooltip" style="display: none;">
        <span id="sgs-tt-time" class="sgs-tt-time">--:--:--</span>
        <span class="sgs-tt-in"><span class="sgs-tt-dot in"></span>In: <span id="sgs-tt-in-val">0 bps</span></span>
        <span class="sgs-tt-out"><span class="sgs-tt-dot out"></span>Out: <span id="sgs-tt-out-val">0 bps</span></span>
        <span class="sgs-tt-total">Total: <span id="sgs-tt-total-val">0 bps</span></span>
      </div>
      <canvas id="sgs-traffic-canvas"></canvas>
    </div>
  </div>

  <!-- Bottom Grid: Interfaces & Top Active Links -->
  <div class="sgs-bottom-grid">
    <!-- Left: Interfaces Table -->
    <div class="sgs-panel-box sgs-iface-box">
      <div class="sgs-panel-header">
        <span>INTERFACES DETECTADAS NO MODEM / ATIVO</span>
        <span class="sgs-panel-badge" id="sgs-iface-count">0 interfaces</span>
      </div>
      <div class="sgs-table-wrap">
        <table class="sgs-table">
          <thead>
            <tr>
              <th>Interface</th>
              <th>Status</th>
              <th>In (Download)</th>
              <th>Out (Upload)</th>
              <th>Ação</th>
            </tr>
          </thead>
          <tbody id="sgs-iface-tbody">
            <!-- Populado dinamicamente -->
          </tbody>
        </table>
      </div>
    </div>

    <!-- Right: Quick Links / Top Active SGS Links -->
    <div class="sgs-panel-box sgs-top-links-box">
      <div class="sgs-panel-header">
        <span>TOP LINKS SGS (MAIOR CONSUMO AGORA)</span>
        <span class="sgs-panel-badge live">LIVE</span>
      </div>
      <div class="sgs-top-links-list" id="sgs-top-links-list">
        <!-- Populado dinamicamente -->
      </div>
    </div>
  </div>

  <!-- Slide-out Inventory Drawer -->
  <div class="sgs-drawer" id="sgs-drawer" style="display:none;">
    <div class="sgs-drawer-content">
      <div class="sgs-drawer-header">
        <span class="sgs-drawer-title">INVENTÁRIO DO ATIVO & DADOS SNMP</span>
        <button id="sgs-drawer-close" class="sgs-drawer-close">✕ FECHAR</button>
      </div>
      <div class="sgs-drawer-body" id="sgs-drawer-body">
        <!-- Populado dinamicamente -->
      </div>
    </div>
  </div>
</div>
"""

# CSS Styles
css_styles = r"""
.sgs-modem-container {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  color: #e2e8f0;
  background: #070b12;
  padding: 16px;
  border-radius: 8px;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

/* Top Control Bar */
.sgs-top-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: #0d131f;
  border: 1px solid #1e293b;
  border-radius: 8px;
  padding: 10px 16px;
  box-shadow: 0 4px 12px rgba(0,0,0,0.5);
  flex-wrap: wrap;
  gap: 12px;
}
.sgs-brand-block {
  display: flex;
  align-items: center;
  gap: 10px;
}
.sgs-status-orb {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: #00e676;
  box-shadow: 0 0 10px #00e676;
  display: inline-block;
  animation: sgsOrbPulse 2s infinite ease-in-out;
}
@keyframes sgsOrbPulse {
  0% { transform: scale(0.9); opacity: 0.8; }
  50% { transform: scale(1.15); opacity: 1; box-shadow: 0 0 16px #00e676; }
  100% { transform: scale(0.9); opacity: 0.8; }
}
.sgs-brand-text {
  display: flex;
  flex-direction: column;
}
.sgs-title-main {
  font-size: 13.5px;
  font-weight: 700;
  letter-spacing: 0.8px;
  color: #f8fafc;
}
.sgs-title-sub {
  font-size: 10.5px;
  color: #64748b;
  letter-spacing: 0.4px;
}
.sgs-selectors-group {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
}
.sgs-field {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: #94a3b8;
  font-weight: 600;
}
.sgs-select {
  background: #131b2e url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='%2338bdf8' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m6 9 6 6 6-6'/%3E%3C/svg%3E") no-repeat right 10px center;
  appearance: none;
  -webkit-appearance: none;
  -moz-appearance: none;
  color: #38bdf8;
  border: 1px solid #25334d;
  border-radius: 5px;
  padding: 6px 30px 6px 12px;
  font-size: 11.5px;
  font-weight: 600;
  outline: none;
  cursor: pointer;
  transition: all 0.2s ease;
  min-width: 250px;
  max-width: 380px;
}
.sgs-select:hover, .sgs-select:focus {
  border-color: #00b0ff;
  box-shadow: 0 0 8px rgba(0, 176, 255, 0.4);
}
.sgs-time-pill-group {
  display: flex;
  background: #131b2e;
  border: 1px solid #25334d;
  border-radius: 5px;
  overflow: hidden;
}
.sgs-time-pill {
  background: transparent;
  color: #94a3b8;
  border: none;
  padding: 6px 10px;
  font-size: 10.5px;
  font-weight: 700;
  cursor: pointer;
  transition: all 0.15s ease;
}
.sgs-time-pill:hover {
  color: #f8fafc;
  background: #1e293b;
}
.sgs-time-pill.active {
  background: #00b0ff;
  color: #050b14;
}
.sgs-btn-refresh {
  background: #1e293b;
  color: #38bdf8;
  border: 1px solid #334155;
  border-radius: 5px;
  padding: 6px 12px;
  cursor: pointer;
  font-size: 12px;
  transition: all 0.2s ease;
}
.sgs-btn-refresh:hover {
  background: #00b0ff;
  color: #050b14;
  border-color: #00b0ff;
  box-shadow: 0 0 10px rgba(0, 176, 255, 0.5);
}

/* Modem / ONT Physical Chassis */
.sgs-chassis-wrap {
  width: 100%;
}
.sgs-chassis {
  background: linear-gradient(180deg, #161e2e 0%, #0c121d 100%);
  border: 1px solid #223049;
  border-radius: 8px;
  box-shadow: 0 8px 24px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.08);
  overflow: hidden;
}
.sgs-chassis-top-bevel {
  background: #101725;
  border-bottom: 1px solid #1a253a;
  padding: 4px 16px;
  display: flex;
  justify-content: flex-end;
}
.sgs-vent-slots {
  display: flex;
  gap: 4px;
}
.sgs-vent-slots span {
  width: 14px;
  height: 2px;
  background: #06090e;
  border-radius: 1px;
}
.sgs-faceplate {
  padding: 12px 18px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}
.sgs-device-badge {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 250px;
}
.sgs-isp-tag {
  display: inline-block;
  align-self: flex-start;
  font-size: 9.5px;
  font-weight: 800;
  letter-spacing: 0.8px;
  padding: 2px 7px;
  border-radius: 3px;
  background: #660099;
  color: #ffffff;
  box-shadow: 0 0 8px rgba(102, 0, 153, 0.6);
}
.sgs-dev-name {
  font-size: 13.5px;
  font-weight: 700;
  color: #f1f5f9;
  letter-spacing: 0.3px;
}
.sgs-dev-meta {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}
.sgs-meta-pill {
  font-size: 10px;
  color: #94a3b8;
  background: #111827;
  padding: 2px 6px;
  border-radius: 3px;
  border: 1px solid #1f2937;
  font-family: monospace;
}

/* LED Cluster */
.sgs-led-cluster {
  display: flex;
  align-items: center;
  gap: 14px;
  background: #090e17;
  padding: 8px 16px;
  border-radius: 6px;
  border: 1px solid #182234;
  box-shadow: inset 0 2px 6px rgba(0,0,0,0.8);
}
.sgs-led-unit {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}
.sgs-led {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  background: #334155;
  box-shadow: inset 0 1px 2px rgba(0,0,0,0.8);
  transition: all 0.2s ease;
}
.sgs-led-green {
  background: #00e676;
  box-shadow: 0 0 8px #00e676, inset 0 1px 1px rgba(255,255,255,0.6);
}
.sgs-led-cyan {
  background: #00b0ff;
  box-shadow: 0 0 8px #00b0ff, inset 0 1px 1px rgba(255,255,255,0.6);
}
.sgs-led-blue {
  background: #3b82f6;
  box-shadow: 0 0 8px #3b82f6;
}
.sgs-led-red {
  background: #ef4444;
  box-shadow: 0 0 8px #ef4444;
}
.sgs-led-amber {
  background: #f59e0b;
  box-shadow: 0 0 8px #f59e0b;
}
@keyframes sgsFlicker {
  0% { opacity: 1; filter: drop-shadow(0 0 3px currentColor); }
  15% { opacity: 0.2; }
  30% { opacity: 0.95; filter: drop-shadow(0 0 5px currentColor); }
  55% { opacity: 0.3; }
  75% { opacity: 1; filter: drop-shadow(0 0 4px currentColor); }
  90% { opacity: 0.25; }
  100% { opacity: 1; }
}
.sgs-led-flicker {
  animation: sgsFlicker 0.4s infinite cubic-bezier(0.4, 0, 0.6, 1);
}
.sgs-led-label {
  font-size: 8.5px;
  font-weight: 700;
  color: #64748b;
  letter-spacing: 0.5px;
}
.sgs-led-separator {
  width: 1px;
  height: 24px;
  background: #1e293b;
}

/* LAN Mini Receptacles */
.sgs-lan-ports {
  display: flex;
  gap: 10px;
}
.sgs-lan-unit {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 3px;
  padding: 3px 5px;
  border-radius: 4px;
  transition: all 0.2s ease;
  user-select: none;
}
.sgs-lan-unit.clickable {
  cursor: pointer;
}
.sgs-lan-unit.clickable:hover {
  background: rgba(255, 255, 255, 0.08);
}
.sgs-lan-unit.selected {
  background: rgba(0, 176, 255, 0.2);
  box-shadow: 0 0 8px rgba(0, 176, 255, 0.5);
}
.sgs-clickable-wan {
  cursor: pointer;
  padding: 3px 5px;
  border-radius: 4px;
  transition: all 0.2s ease;
  user-select: none;
}
.sgs-clickable-wan:hover {
  background: rgba(255, 255, 255, 0.08);
}
.sgs-clickable-wan.selected {
  background: rgba(0, 176, 255, 0.2);
  box-shadow: 0 0 8px rgba(0, 176, 255, 0.5);
}
.sgs-mini-rj45 {
  width: 16px;
  height: 12px;
  background: #141b27;
  border: 1px solid #334155;
  border-radius: 2px;
  display: flex;
  align-items: center;
  justify-content: center;
  box-shadow: inset 0 1px 3px rgba(0,0,0,0.8);
  transition: all 0.2s ease;
}
.sgs-mini-rj45.active {
  border-color: #00e676;
}
.sgs-mini-rj45.selected {
  border-color: #00b0ff;
  box-shadow: 0 0 8px #00b0ff;
}
.sgs-rj45-pins {
  display: flex;
  gap: 1.5px;
}
.sgs-rj45-pins i {
  width: 1px;
  height: 4px;
  background: #ffd700;
  display: inline-block;
}

/* Chassis Right Info & Button */
.sgs-chassis-right {
  display: flex;
  align-items: center;
  gap: 12px;
}
.sgs-speed-pill-box {
  background: #090e17;
  border: 1px solid #1a253a;
  border-radius: 5px;
  padding: 6px 10px;
  display: flex;
  flex-direction: column;
  gap: 3px;
}
.sgs-speed-row {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  font-family: monospace;
}
.sgs-dir-icon.in { color: #00e676; font-weight: 700; }
.sgs-dir-icon.out { color: #38bdf8; font-weight: 700; }
.sgs-speed-val { color: #f8fafc; font-weight: 700; }
.sgs-btn-info {
  background: #131b2e;
  border: 1px solid #25334d;
  color: #38bdf8;
  font-size: 10.5px;
  font-weight: 700;
  padding: 8px 12px;
  border-radius: 5px;
  cursor: pointer;
  transition: all 0.2s ease;
}
.sgs-btn-info:hover {
  background: #00b0ff;
  color: #050b14;
  border-color: #00b0ff;
  box-shadow: 0 0 10px rgba(0, 176, 255, 0.5);
}

/* KPI Cards Grid */
.sgs-kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 12px;
}
.sgs-kpi-card {
  background: #0d131f;
  border: 1px solid #1e293b;
  border-radius: 7px;
  padding: 12px 14px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  box-shadow: 0 3px 8px rgba(0,0,0,0.3);
}
.sgs-kpi-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.sgs-kpi-title {
  font-size: 10px;
  font-weight: 700;
  color: #94a3b8;
  letter-spacing: 0.5px;
}
.sgs-kpi-badge {
  font-size: 9px;
  font-weight: 800;
  padding: 1px 5px;
  border-radius: 3px;
  font-family: monospace;
}
.sgs-kpi-badge.in { background: rgba(0, 230, 118, 0.15); color: #00e676; }
.sgs-kpi-badge.out { background: rgba(56, 189, 248, 0.15); color: #38bdf8; }
.sgs-kpi-badge.peak { background: rgba(245, 158, 11, 0.15); color: #f59e0b; }
.sgs-kpi-badge.avg { background: rgba(168, 85, 247, 0.15); color: #a855f7; }
.sgs-kpi-badge.status { background: rgba(16, 185, 129, 0.15); color: #10b981; }
.sgs-kpi-val {
  font-size: 20px;
  font-weight: 800;
  color: #f8fafc;
  letter-spacing: -0.5px;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", monospace;
}
.sgs-kpi-in .sgs-kpi-val { color: #00e676; }
.sgs-kpi-out .sgs-kpi-val { color: #38bdf8; }
.sgs-kpi-sub {
  font-size: 10px;
  color: #64748b;
}

/* Oscilloscope Chart */
.sgs-chart-card {
  background: #0d131f;
  border: 1px solid #1e293b;
  border-radius: 8px;
  padding: 14px 16px;
  box-shadow: 0 4px 12px rgba(0,0,0,0.4);
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.sgs-chart-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px;
}
.sgs-chart-title {
  font-size: 12px;
  font-weight: 700;
  color: #f8fafc;
  letter-spacing: 0.6px;
}
.sgs-chart-sub {
  font-size: 11px;
  color: #38bdf8;
  margin-left: 8px;
  font-family: monospace;
}
.sgs-chart-legend {
  display: flex;
  align-items: center;
  gap: 14px;
}
.sgs-leg-item {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: #94a3b8;
  font-weight: 600;
}
.sgs-leg-item i {
  width: 10px;
  height: 10px;
  border-radius: 2px;
  display: inline-block;
}
.sgs-leg-item i.leg-in { background: #00e676; box-shadow: 0 0 6px #00e676; }
.sgs-leg-item i.leg-out { background: #a855f7; box-shadow: 0 0 6px #a855f7; }
.sgs-btn-reset-zoom {
  background: #1e293b;
  color: #f59e0b;
  border: 1px solid #f59e0b;
  border-radius: 4px;
  padding: 3px 8px;
  font-size: 10.5px;
  font-weight: 700;
  cursor: pointer;
  transition: all 0.2s ease;
}
.sgs-btn-reset-zoom:hover {
  background: #f59e0b;
  color: #050b14;
}
.sgs-canvas-wrap {
  position: relative;
  width: 100%;
  height: 220px;
  background: #080c14;
  border: 1px solid #162032;
  border-radius: 6px;
  overflow: hidden;
  cursor: crosshair;
}
#sgs-traffic-canvas {
  width: 100%;
  height: 100%;
  display: block;
}
.sgs-chart-hint {
  font-size: 9.5px;
  color: #64748b;
  font-family: monospace;
  margin-left: 6px;
}
.sgs-canvas-tooltip {
  position: absolute;
  top: 10px;
  background: rgba(11, 16, 26, 0.96);
  border: 1px solid #00b0ff;
  border-radius: 6px;
  padding: 4px 12px;
  font-size: 11px;
  color: #f8fafc;
  pointer-events: none;
  z-index: 1000;
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.9);
  backdrop-filter: blur(8px);
  display: flex;
  align-items: center;
  gap: 12px;
  white-space: nowrap;
  width: max-content;
  flex-shrink: 0;
}
.sgs-tt-time {
  color: #94a3b8;
  font-family: monospace;
  font-size: 10.5px;
  border-right: 1px solid #334155;
  padding-right: 8px;
  white-space: nowrap;
  flex-shrink: 0;
}
.sgs-tt-in {
  color: #00e676;
  font-weight: 700;
  display: flex;
  align-items: center;
  gap: 5px;
  white-space: nowrap;
  flex-shrink: 0;
}
.sgs-tt-out {
  color: #a855f7;
  font-weight: 700;
  display: flex;
  align-items: center;
  gap: 5px;
  white-space: nowrap;
  flex-shrink: 0;
}
.sgs-tt-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  display: inline-block;
  flex-shrink: 0;
}
.sgs-tt-dot.in {
  background: #00e676;
  box-shadow: 0 0 6px #00e676;
}
.sgs-tt-dot.out {
  background: #a855f7;
  box-shadow: 0 0 6px #a855f7;
}
.sgs-tt-total {
  color: #ffffff;
  font-weight: 700;
  border-left: 1px solid #334155;
  padding-left: 8px;
  white-space: nowrap;
  flex-shrink: 0;
}

/* Bottom Grid */
.sgs-bottom-grid {
  display: grid;
  grid-template-columns: 3fr 2fr;
  gap: 14px;
}
@media (max-width: 900px) {
  .sgs-bottom-grid { grid-template-columns: 1fr; }
}
.sgs-panel-box {
  background: #0d131f;
  border: 1px solid #1e293b;
  border-radius: 8px;
  padding: 12px 14px;
  box-shadow: 0 3px 10px rgba(0,0,0,0.3);
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.sgs-panel-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 11px;
  font-weight: 700;
  color: #94a3b8;
  letter-spacing: 0.6px;
}
.sgs-panel-badge {
  font-size: 9.5px;
  background: #1e293b;
  color: #38bdf8;
  padding: 2px 6px;
  border-radius: 3px;
  font-family: monospace;
}
.sgs-panel-badge.live {
  background: rgba(0, 230, 118, 0.2);
  color: #00e676;
}
.sgs-table-wrap {
  overflow-x: auto;
}
.sgs-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 11px;
}
.sgs-table th {
  text-align: left;
  color: #64748b;
  padding: 6px 8px;
  border-bottom: 1px solid #1e293b;
  font-weight: 700;
}
.sgs-table td {
  padding: 6px 8px;
  border-bottom: 1px solid #141c2c;
  color: #cbd5e1;
}
.sgs-table tr:hover td {
  background: #141d2e;
}
.sgs-badge-status {
  padding: 1px 5px;
  border-radius: 3px;
  font-size: 9px;
  font-weight: 700;
}
.sgs-badge-status.up { background: rgba(0, 230, 118, 0.15); color: #00e676; }
.sgs-badge-status.down { background: rgba(239, 68, 68, 0.15); color: #ef4444; }
.sgs-btn-select-if {
  background: #1e293b;
  border: 1px solid #334155;
  color: #38bdf8;
  padding: 2px 7px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.15s ease;
}
.sgs-btn-select-if:hover {
  background: #00b0ff;
  color: #050b14;
}

/* Top Links Quick List */
.sgs-top-links-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.sgs-top-link-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: #111827;
  border: 1px solid #1f2937;
  border-radius: 5px;
  padding: 8px 10px;
  cursor: pointer;
  transition: all 0.2s ease;
}
.sgs-top-link-item:hover {
  border-color: #00b0ff;
  background: #152238;
  transform: translateX(3px);
}
.sgs-top-link-info {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.sgs-top-link-name {
  font-size: 11.5px;
  font-weight: 600;
  color: #f1f5f9;
}
.sgs-top-link-meta {
  font-size: 10px;
  color: #64748b;
  font-family: monospace;
}
.sgs-top-link-rate {
  font-size: 12px;
  font-weight: 800;
  color: #00e676;
  font-family: monospace;
}

/* Slide Drawer */
.sgs-drawer {
  position: fixed;
  top: 0; right: 0; bottom: 0;
  width: 360px;
  background: #0d131f;
  border-left: 1px solid #00b0ff;
  box-shadow: -8px 0 24px rgba(0,0,0,0.8);
  z-index: 99999;
  display: flex;
  flex-direction: column;
}
.sgs-drawer-content {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 14px;
  height: 100%;
}
.sgs-drawer-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-bottom: 1px solid #1e293b;
  padding-bottom: 10px;
}
.sgs-drawer-title {
  font-size: 12px;
  font-weight: 700;
  color: #38bdf8;
}
.sgs-drawer-close {
  background: #1e293b;
  border: 1px solid #334155;
  color: #cbd5e1;
  padding: 3px 8px;
  border-radius: 4px;
  cursor: pointer;
}
.sgs-drawer-close:hover {
  background: #ef4444;
  color: #fff;
}
.sgs-drawer-body {
  font-size: 11px;
  color: #94a3b8;
  line-height: 1.6;
  overflow-y: auto;
}
"""

# JavaScript Runtime (afterRender)
js_script = r"""
(function() {
  const ZABBIX_URL = "__ZABBIX_URL__";
  const ZABBIX_TOKEN = "__ZABBIX_TOKEN__";
  const CATALOG = __CATALOG_JSON__;

  function getEl(id) {
    try {
      if (typeof element !== 'undefined' && element && element.querySelector) {
        const found = element.querySelector('#' + id);
        if (found) return found;
      }
      return document.getElementById(id);
    } catch(e) {
      return document.getElementById(id);
    }
  }

  console.log("[SGS-MODEM-TWIN] Inicializando runtime dinâmico com", CATALOG.length, "hosts...");

  // Singleton de Ciclo de Vida
  if (window.__SGS_MODEM_TWIN_RUNTIME__) {
    try { window.__SGS_MODEM_TWIN_RUNTIME__.destroy(); } catch(e){}
  }

  const state = {
    hosts: CATALOG,
    currentHost: CATALOG[0] || null,
    currentIface: (CATALOG[0] && CATALOG[0].interfaces[0]) || null,
    timeRangeSec: 21600, // 6h default
    historyIn: [],
    historyOut: [],
    isPolling: false,
    pollTimer: null,
    zoomStart: null,
    zoomEnd: null,
    isZooming: false,
    dragStartX: null,
    dragCurrentX: null,
    hoveredIdx: null
  };

  // Helper formatador de banda
  function formatBps(bps) {
    if (bps === null || bps === undefined || isNaN(bps)) return "0 bps";
    const b = Number(bps);
    if (b >= 1000000000) return (b / 1000000000).toFixed(2) + " Gb/s";
    if (b >= 1000000) return (b / 1000000).toFixed(2) + " Mb/s";
    if (b >= 1000) return (b / 1000).toFixed(1) + " Kb/s";
    return b.toFixed(0) + " bps";
  }

  // Cores por ISP
  const ISP_COLORS = {
    "VIVO": "#660099",
    "ALGAR": "#00b04f",
    "VEGANET": "#0088cc",
    "DESKTOP": "#ff6600",
    "HUGHESNET": "#003366",
    "EMBRATEL": "#d6001c",
    "CLARO": "#da291c",
    "OI": "#ffcc00",
    "NET": "#da291c",
    "EVOLNET": "#00a86b",
    "TELECOM": "#2563eb"
  };

  // Montar Dropdown de Hosts
  function renderHostSelect() {
    const sel = getEl("sgs-host-select");
    if (!sel) return;
    sel.innerHTML = "";
    state.hosts.forEach((h, idx) => {
      const opt = document.createElement("option");
      opt.value = h.hostid;
      opt.textContent = `${h.name} (${h.ip})`;
      if (state.currentHost && state.currentHost.hostid === h.hostid) {
        opt.selected = true;
      }
      sel.appendChild(opt);
    });

    sel.onchange = function(e) {
      const hid = e.target.value;
      const found = state.hosts.find(x => x.hostid === hid);
      if (found) {
        selectHost(found);
      }
    };
  }

  // Montar Dropdown de Interfaces
  function renderIfaceSelect() {
    const sel = getEl("sgs-iface-select");
    if (!sel || !state.currentHost) return;
    sel.innerHTML = "";
    state.currentHost.interfaces.forEach((iface, idx) => {
      const opt = document.createElement("option");
      opt.value = iface.id;
      opt.textContent = iface.name;
      if (state.currentIface && state.currentIface.id === iface.id) {
        opt.selected = true;
      }
      sel.appendChild(opt);
    });

    sel.onchange = function(e) {
      const ifid = e.target.value;
      const found = state.currentHost.interfaces.find(x => x.id === ifid);
      if (found) {
        selectInterface(found);
      }
    };
  }

  // Selecionar Host
  function selectHost(host) {
    state.currentHost = host;
    state.currentIface = host.interfaces[0] || null;
    state.zoomStart = null;
    state.zoomEnd = null;
    const btnReset = getEl("sgs-btn-reset-zoom");
    if (btnReset) btnReset.style.display = "none";

    updateChassisUI();
    renderIfaceSelect();
    renderInterfacesTable();

    const sub = getEl("sgs-chart-sub");
    if (sub && state.currentIface) sub.textContent = "Interface: " + state.currentIface.name;

    fetchTelemetry();
  }

  // Selecionar Interface
  function selectInterface(iface) {
    state.currentIface = iface;
    state.zoomStart = null;
    state.zoomEnd = null;
    const btnReset = getEl("sgs-btn-reset-zoom");
    if (btnReset) btnReset.style.display = "none";

    const sub = getEl("sgs-chart-sub");
    if (sub) sub.textContent = "Interface: " + iface.name;

    // Atualizar seletor dropdown
    const sel = getEl("sgs-iface-select");
    if (sel) sel.value = iface.id;

    // Atualizar tabela de interfaces para refletir seleção
    renderInterfacesTable();

    // Atualizar LEDs e destaque das portas no chassi
    updateChassisLEDs();

    fetchTelemetry();
  }

  // Identificar interfaces LAN do Host
  function getHostLanInterfaces(host) {
    if (!host || !host.interfaces) return [];
    // 1. Procurar interfaces com 'LAN' explícito no nome ou descrição
    const explicitLan = host.interfaces.filter(i => {
      const n = (i.name || '').toUpperCase();
      return n.includes('LAN') && !n.includes('WAN');
    });
    if (explicitLan.length > 0) {
      return explicitLan.slice(0, 4);
    }
    // 2. Se não tiver termo 'LAN', pegar interfaces diferentes da WAN principal
    const otherIfaces = host.interfaces.filter((i, idx) => {
      const n = (i.name || '').toUpperCase();
      return !n.includes('WAN') && !n.includes('INTERNET') && idx > 0;
    });
    if (otherIfaces.length > 0) return otherIfaces.slice(0, 4);

    // 3. Caso o host tenha várias portas físicas (ex: eth1, eth2)
    return host.interfaces.slice(1, 5);
  }

  // Atualizar LEDs do Chassi (WAN + LAN 1 a 4 100% Funcionais)
  function updateChassisLEDs() {
    const host = state.currentHost;
    if (!host) return;

    const wanIface = host.interfaces[0] || null;
    const lanIfaces = getHostLanInterfaces(host);
    const isWanSelected = state.currentIface && wanIface && (state.currentIface.id === wanIface.id);

    // WAN Cluster (PON & INTERNET)
    const btnPon = getEl("sgs-btn-wan-pon");
    const btnNet = getEl("sgs-btn-wan-net");
    if (btnPon && wanIface) {
      btnPon.classList.toggle("selected", isWanSelected);
      btnPon.title = `WAN / PON: ${wanIface.name}\nStatus: UP\n✦ Clique para inspecionar a WAN no osciloscópio`;
      btnPon.onclick = () => selectInterface(wanIface);
    }
    if (btnNet && wanIface) {
      btnNet.classList.toggle("selected", isWanSelected);
      btnNet.title = `INTERNET (WAN): ${wanIface.name}\n✦ Clique para inspecionar a WAN no osciloscópio`;
      btnNet.onclick = () => selectInterface(wanIface);
    }

    // LAN 1 a 4
    for (let slot = 0; slot < 4; slot++) {
      const unit = getEl("sgs-lan-unit-" + slot);
      const rj45 = getEl("sgs-rj45-" + slot);
      const led = getEl("sgs-led-lan" + slot);
      const label = getEl("sgs-label-lan" + slot);
      if (!unit || !rj45 || !led) continue;

      const iface = lanIfaces[slot];
      if (iface) {
        // Interface LAN Real e Monitorada!
        const isSelected = state.currentIface && (state.currentIface.id === iface.id);
        unit.classList.add("clickable");
        unit.classList.toggle("selected", isSelected);
        unit.style.opacity = "1";

        rj45.classList.add("active");
        if (isSelected) {
          rj45.classList.add("selected");
        } else {
          rj45.classList.remove("selected");
        }

        // Tráfego da porta LAN
        const inVal = (iface.inItem && iface.inItem.lastvalue) || 0;
        const outVal = (iface.outItem && iface.outItem.lastvalue) || 0;
        const totalBps = inVal + outVal;
        const isUp = iface.status !== 0;

        led.className = "sgs-led sgs-led-lan";
        if (isUp) {
          led.classList.add("sgs-led-green");
          if (totalBps > 0) {
            led.classList.add("sgs-led-flicker");
            if (totalBps > 20000000) {
              led.style.animationDuration = "0.18s";
            } else if (totalBps > 2000000) {
              led.style.animationDuration = "0.35s";
            } else {
              led.style.animationDuration = "0.7s";
            }
          } else {
            led.style.animationDuration = "";
          }
        } else {
          led.classList.add("sgs-led-red");
          led.style.animationDuration = "";
        }

        unit.title = `LAN ${slot + 1}: ${iface.name}\nStatus: ${isUp ? 'UP (Conectada)' : 'DOWN'}\nIn: ${formatBps(inVal)} | Out: ${formatBps(outVal)}\n✦ Clique para abrir esta porta no osciloscópio`;

        unit.onclick = () => selectInterface(iface);
      } else {
        // Porta sem interface vinculada / sem cabo no ativo real
        unit.classList.remove("clickable", "selected");
        unit.style.opacity = "0.38";
        unit.title = `LAN ${slot + 1}: Desconectada / Sem Telemetria`;
        rj45.classList.remove("active", "selected");
        led.className = "sgs-led sgs-led-lan";
        led.style.animationDuration = "";
        unit.onclick = null;
      }
    }
  }

  // Atualizar UI do Chassi Físico
  function updateChassisUI() {
    if (!state.currentHost) return;
    const h = state.currentHost;
    
    // Nome e IP
    const elName = getEl("sgs-dev-name");
    if (elName) elName.textContent = h.name;
    const elIp = getEl("sgs-dev-ip");
    if (elIp) elIp.textContent = "IP: " + (h.ip || "N/A");

    // Badge da Operadora
    const elIsp = getEl("sgs-isp-badge");
    if (elIsp) {
      elIsp.textContent = h.isp;
      const c = ISP_COLORS[h.isp] || "#2563eb";
      elIsp.style.background = c;
      elIsp.style.boxShadow = `0 0 8px ${c}`;
    }

    // Ping / Latência
    const elPing = getEl("sgs-dev-ping");
    if (elPing) elPing.textContent = "LATÊNCIA: MEDINDO...";

    // Uptime / Status
    const elHealth = getEl("sgs-dev-health");
    if (elHealth) elHealth.textContent = "STATUS: MONITORANDO";

    // Atualizar LEDs dinâmicos das portas LAN e WAN
    updateChassisLEDs();

    // Drawer info
    renderDrawerInfo();
  }

  // Renderizar Tabela de Interfaces
  function renderInterfacesTable() {
    const tbody = getEl("sgs-iface-tbody");
    const countBadge = getEl("sgs-iface-count");
    if (!tbody || !state.currentHost) return;
    
    const ifaces = state.currentHost.interfaces;
    if (countBadge) countBadge.textContent = ifaces.length + " interfaces";
    
    tbody.innerHTML = "";
    ifaces.forEach(iface => {
      const tr = document.createElement("tr");
      const inVal = iface.inItem ? iface.inItem.lastvalue : 0;
      const outVal = iface.outItem ? iface.outItem.lastvalue : 0;
      const isSelected = state.currentIface && state.currentIface.id === iface.id;

      tr.innerHTML = `
        <td style="font-weight: 600; color: ${isSelected ? '#00b0ff' : '#f1f5f9'};">
          ${isSelected ? '▶ ' : ''}${iface.name}
        </td>
        <td><span class="sgs-badge-status up">UP</span></td>
        <td style="color: #00e676; font-family: monospace;">${formatBps(inVal)}</td>
        <td style="color: #38bdf8; font-family: monospace;">${formatBps(outVal)}</td>
        <td>
          <button class="sgs-btn-select-if" data-id="${iface.id}">
            ${isSelected ? 'SELECIONADA' : 'EXIBIR'}
          </button>
        </td>
      `;

      tr.querySelector("button").onclick = function() {
        selectInterface(iface);
        renderIfaceSelect();
        renderInterfacesTable();
      };

      tbody.appendChild(tr);
    });
  }

  // Renderizar Top Links Rápidos
  function renderTopLinks() {
    const list = getEl("sgs-top-links-list");
    if (!list) return;
    
    const sorted = [...state.hosts].sort((a,b) => b.totalTraffic - a.totalTraffic).slice(0, 5);
    list.innerHTML = "";

    sorted.forEach((h, idx) => {
      const item = document.createElement("div");
      item.className = "sgs-top-link-item";
      item.innerHTML = `
        <div class="sgs-top-link-info">
          <span class="sgs-top-link-name">#${idx+1} ${h.name}</span>
          <span class="sgs-top-link-meta">IP: ${h.ip} • ${h.isp}</span>
        </div>
        <span class="sgs-top-link-rate">${formatBps(h.totalTraffic)}</span>
      `;
      item.onclick = function() {
        selectHost(h);
        renderHostSelect();
      };
      list.appendChild(item);
    });
  }

  // Renderizar Drawer de Inventário
  function renderDrawerInfo() {
    const body = getEl("sgs-drawer-body");
    if (!body || !state.currentHost) return;
    const h = state.currentHost;
    
    body.innerHTML = `
      <div style="margin-bottom: 12px; padding: 10px; background: #131b2e; border-radius: 6px;">
        <div style="font-size: 13px; font-weight: 700; color: #fff;">${h.name}</div>
        <div style="color: #38bdf8; font-size: 11px; margin-top: 2px;">Host ID Zabbix: ${h.hostid}</div>
      </div>
      <div style="display: flex; flex-direction: column; gap: 8px;">
        <div><b>IP de Gerência / WAN:</b> ${h.ip}</div>
        <div><b>Operadora / ISP:</b> ${h.isp}</div>
        <div><b>Interfaces Descobertas:</b> ${h.interfaces.length}</div>
        <div><b>Templates Vinculados:</b><br>
          <ul style="margin: 4px 0 0 16px; padding: 0;">
            ${h.templates.map(t => `<li>${t}</li>`).join('')}
          </ul>
        </div>
        <div style="margin-top: 10px;">
          <a href="${ZABBIX_URL.replace('/api_jsonrpc.php','')}/zabbix.php?action=host.edit&hostid=${h.hostid}" target="_blank" 
             style="color: #00b0ff; text-decoration: none; font-weight: 600;">
             ↗ Abrir Host no Zabbix Web Frontend
          </a>
        </div>
      </div>
    `;
  }

  // Buscar Telemetria (Últimos Valores e Histórico)
  async function fetchTelemetry() {
    if (!state.currentHost || !state.currentIface) return;
    const h = state.currentHost;
    const iface = state.currentIface;

    const btnSync = getEl("sgs-sync-btn");
    if (btnSync) btnSync.classList.add("sgs-spinning");

    async function zabbixCall(method, params, id = 1) {
      const resp = await fetch(ZABBIX_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          method: method,
          params: params,
          auth: ZABBIX_TOKEN,
          id: id
        })
      });
      return await resp.json();
    }

    try {
      const now = Math.floor(Date.now() / 1000);
      const timeFrom = now - state.timeRangeSec;

      // 1. Buscar Ping se houver item
      if (h.secItem) {
        const pingRes = await zabbixCall("history.get", {
          itemids: [h.secItem],
          history: 0,
          time_from: now - 300,
          limit: 1
        }, 10);
        
        if (pingRes.result && pingRes.result.length > 0) {
          const sec = parseFloat(pingRes.result[0].value);
          const ms = (sec * 1000).toFixed(1);
          const elPing = getEl("sgs-dev-ping");
          if (elPing) elPing.textContent = `LATÊNCIA: ${ms} ms`;
        }
      }

      // 2. Buscar Histórico Inbound
      let inData = [];
      if (iface.inItem) {
        const inRes = await zabbixCall("history.get", {
          itemids: [iface.inItem.itemid],
          history: parseInt(iface.inItem.valueType) || 3,
          time_from: timeFrom,
          time_till: now,
          sortfield: "clock",
          sortorder: "ASC",
          limit: 500
        }, 11);
        inData = inRes.result || [];
      }

      // 3. Buscar Histórico Outbound
      let outData = [];
      if (iface.outItem) {
        const outRes = await zabbixCall("history.get", {
          itemids: [iface.outItem.itemid],
          history: parseInt(iface.outItem.valueType) || 3,
          time_from: timeFrom,
          time_till: now,
          sortfield: "clock",
          sortorder: "ASC",
          limit: 500
        }, 12);
        outData = outRes.result || [];
      }

      state.historyIn = inData;
      state.historyOut = outData;

      // Atualizar KPIs
      updateKPIs(inData, outData);

      // Renderizar Gráfico Canvas
      renderCanvas();

    } catch (err) {
      console.error("[SGS-MODEM-TWIN] Erro ao buscar telemetria:", err);
    } finally {
      if (btnSync) btnSync.classList.remove("sgs-spinning");
    }
  }

  // Atualizar KPIs
  function updateKPIs(inData, outData) {
    const curIn = inData.length > 0 ? parseFloat(inData[inData.length - 1].value) : 0;
    const curOut = outData.length > 0 ? parseFloat(outData[outData.length - 1].value) : 0;

    // Quick Pill in Chassis
    const qIn = getEl("sgs-quick-in");
    if (qIn) qIn.textContent = formatBps(curIn);
    const qOut = getEl("sgs-quick-out");
    if (qOut) qOut.textContent = formatBps(curOut);

    // KPI Cards
    const kIn = getEl("sgs-kpi-in-val");
    if (kIn) kIn.textContent = formatBps(curIn);
    const kOut = getEl("sgs-kpi-out-val");
    if (kOut) kOut.textContent = formatBps(curOut);

    // Peak e Avg
    let maxIn = 0, sumIn = 0;
    inData.forEach(p => {
      const v = parseFloat(p.value);
      if (v > maxIn) maxIn = v;
      sumIn += v;
    });
    const avgIn = inData.length > 0 ? (sumIn / inData.length) : 0;

    const kPeak = getEl("sgs-kpi-peak-val");
    if (kPeak) kPeak.textContent = formatBps(maxIn);
    const kAvg = getEl("sgs-kpi-avg-val");
    if (kAvg) kAvg.textContent = formatBps(avgIn);

    // Ajustar velocidade da cintilação do LED da WAN conforme o tráfego
    const ledWan = getEl("sgs-led-wan");
    if (ledWan) {
      if (curIn > 20000000) {
        ledWan.style.animationDuration = "0.18s";
      } else if (curIn > 5000000) {
        ledWan.style.animationDuration = "0.32s";
      } else {
        ledWan.style.animationDuration = "0.65s";
      }
    }

    // Atualizar LEDs dinâmicos de WAN e LAN com os dados mais recentes
    updateChassisLEDs();
  }

  // Renderizar Gráfico Canvas
  function renderCanvas() {
    const canvas = getEl("sgs-traffic-canvas");
    const wrap = getEl("sgs-canvas-wrap");
    if (!canvas || !wrap) return;

    const rect = wrap.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const w = rect.width;
    const h = rect.height;

    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";

    const ctx = canvas.getContext("2d");
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, w, h);

    const inData = state.historyIn || [];
    const outData = state.historyOut || [];

    if (inData.length === 0 && outData.length === 0) {
      ctx.fillStyle = "#64748b";
      ctx.font = "12px sans-serif";
      ctx.textAlign = "center";
      ctx.fillText("Sem histórico de tráfego retornado no período.", w / 2, h / 2);
      return;
    }

    // Filtrar zoom se ativo
    let filteredIn = inData;
    let filteredOut = outData;
    if (state.zoomStart !== null && state.zoomEnd !== null) {
      filteredIn = inData.filter(p => p.clock >= state.zoomStart && p.clock <= state.zoomEnd);
      filteredOut = outData.filter(p => p.clock >= state.zoomStart && p.clock <= state.zoomEnd);
    }

    // Encontrar min/max tempo e max valor
    const allClocks = [...filteredIn.map(p => parseInt(p.clock)), ...filteredOut.map(p => parseInt(p.clock))];
    const allVals = [...filteredIn.map(p => parseFloat(p.value)), ...filteredOut.map(p => parseFloat(p.value))];

    if (allClocks.length === 0) return;

    const minTime = Math.min(...allClocks);
    const maxTime = Math.max(...allClocks);
    const maxVal = Math.max(...allVals, 1000); // no mínimo 1 Kbps
    const yMax = maxVal * 1.15; // 15% headroom

    const padLeft = 65;
    const padRight = 20;
    const padTop = 15;
    const padBottom = 28;
    const plotW = w - padLeft - padRight;
    const plotH = h - padTop - padBottom;
    const bottomY = padTop + plotH;
    const timeSpan = Math.max(1, maxTime - minTime);

    // Desenhar Linhas de Grade Horizontais
    ctx.strokeStyle = "#162032";
    ctx.lineWidth = 1;
    ctx.fillStyle = "#64748b";
    ctx.font = "10px monospace";
    ctx.textAlign = "right";

    const gridLines = 4;
    for (let i = 0; i <= gridLines; i++) {
      const yVal = (yMax / gridLines) * i;
      const yPos = bottomY - (yVal / yMax) * plotH;
      ctx.beginPath();
      ctx.moveTo(padLeft, yPos);
      ctx.lineTo(w - padRight, yPos);
      ctx.stroke();

      ctx.fillText(formatBps(yVal), padLeft - 8, yPos + 3);
    }

    // Desenhar Linhas de Grade Verticais (Tempo)
    ctx.textAlign = "center";
    const timeSteps = 5;
    for (let i = 0; i <= timeSteps; i++) {
      const t = minTime + (timeSpan / timeSteps) * i;
      const xPos = padLeft + ((t - minTime) / timeSpan) * plotW;
      
      const d = new Date(t * 1000);
      const hours = String(d.getHours()).padStart(2, '0');
      const mins = String(d.getMinutes()).padStart(2, '0');

      ctx.beginPath();
      ctx.strokeStyle = "#162032";
      ctx.moveTo(xPos, padTop);
      ctx.lineTo(xPos, bottomY);
      ctx.stroke();

      ctx.fillStyle = "#64748b";
      ctx.fillText(`${hours}:${mins}`, xPos, h - 8);
    }

    // Mapear Coordenadas
    function getX(clock) {
      if (maxTime === minTime) return padLeft + plotW / 2;
      return padLeft + ((clock - minTime) / timeSpan) * plotW;
    }
    function getY(val) {
      return bottomY - (val / yMax) * plotH;
    }

    const inCoords = filteredIn.map(p => ({
      x: getX(parseInt(p.clock)),
      y: getY(parseFloat(p.value)),
      clock: parseInt(p.clock),
      value: parseFloat(p.value)
    }));

    const outCoords = filteredOut.map(p => ({
      x: getX(parseInt(p.clock)),
      y: getY(parseFloat(p.value)),
      clock: parseInt(p.clock),
      value: parseFloat(p.value)
    }));

    // Função para desenhar série com gradiente e pontos amostrais
    function drawSeries(coords, strokeColor, r, g, b) {
      if (!coords || coords.length === 0) return;

      // Preenchimento com gradiente suave
      const grad = ctx.createLinearGradient(0, padTop, 0, bottomY);
      grad.addColorStop(0, `rgba(${r}, ${g}, ${b}, 0.28)`);
      grad.addColorStop(1, `rgba(${r}, ${g}, ${b}, 0.0)`);
      ctx.fillStyle = grad;

      ctx.beginPath();
      ctx.moveTo(coords[0].x, bottomY);
      coords.forEach(pt => ctx.lineTo(pt.x, pt.y));
      ctx.lineTo(coords[coords.length - 1].x, bottomY);
      ctx.closePath();
      ctx.fill();

      // Traçado da linha
      ctx.strokeStyle = strokeColor;
      ctx.lineWidth = 2.2;
      ctx.lineJoin = "round";
      ctx.beginPath();
      coords.forEach((pt, idx) => {
        if (idx === 0) ctx.moveTo(pt.x, pt.y);
        else ctx.lineTo(pt.x, pt.y);
      });
      ctx.stroke();

      // Pontos amostrais nas curvas (bolinhas guia)
      if (coords.length <= 160) {
        coords.forEach((pt, idx) => {
          const isLast = (idx === coords.length - 1);
          ctx.fillStyle = strokeColor;
          ctx.beginPath();
          ctx.arc(pt.x, pt.y, isLast ? 3.5 : 2.2, 0, Math.PI * 2);
          ctx.fill();

          if (isLast && state.hoveredIdx == null) {
            ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, 0.55)`;
            ctx.lineWidth = 2;
            ctx.beginPath();
            ctx.arc(pt.x, pt.y, 7, 0, Math.PI * 2);
            ctx.stroke();
          }
        });
      } else {
        const lastPt = coords[coords.length - 1];
        ctx.fillStyle = strokeColor;
        ctx.beginPath();
        ctx.arc(lastPt.x, lastPt.y, 3.5, 0, Math.PI * 2);
        ctx.fill();

        if (state.hoveredIdx == null) {
          ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, 0.55)`;
          ctx.lineWidth = 2;
          ctx.beginPath();
          ctx.arc(lastPt.x, lastPt.y, 7, 0, Math.PI * 2);
          ctx.stroke();
        }
      }
    }

    // Desenhar Upload (Roxo/Lilás: #a855f7)
    drawSeries(outCoords, "#a855f7", 168, 85, 247);

    // Desenhar Download (Verde Esmeralda: #00e676)
    drawSeries(inCoords, "#00e676", 0, 230, 118);

    // Hover Crosshair (Barrinha Tracejada) e Target Halos (Bolinhas com Auréola)
    if (state.hoveredIdx !== null) {
      const primaryCoords = inCoords.length > 0 ? inCoords : outCoords;
      if (primaryCoords.length > 0) {
        const hIdx = Math.min(state.hoveredIdx, primaryCoords.length - 1);
        const hoverX = primaryCoords[hIdx].x;

        // Vertical guideline (barrinha tracejada)
        ctx.strokeStyle = "rgba(255, 255, 255, 0.45)";
        ctx.lineWidth = 1;
        ctx.setLineDash([3, 3]);
        ctx.beginPath();
        ctx.moveTo(hoverX, padTop);
        ctx.lineTo(hoverX, bottomY);
        ctx.stroke();
        ctx.setLineDash([]);

        // Ponto Out mais próximo deste hoverX
        let ptOut = null;
        if (outCoords.length > 0) {
          let minDiff = Infinity;
          outCoords.forEach(p => {
            const d = Math.abs(p.x - hoverX);
            if (d < minDiff) { minDiff = d; ptOut = p; }
          });
        }

        // Ponto In mais próximo deste hoverX
        let ptIn = null;
        if (inCoords.length > 0) {
          let minDiff = Infinity;
          inCoords.forEach(p => {
            const d = Math.abs(p.x - hoverX);
            if (d < minDiff) { minDiff = d; ptIn = p; }
          });
        }

        // Auréola e ponto destacado Out (Upload - Roxo)
        if (ptOut) {
          ctx.fillStyle = "#a855f7";
          ctx.beginPath();
          ctx.arc(hoverX, ptOut.y, 5.5, 0, Math.PI * 2);
          ctx.fill();
          ctx.strokeStyle = "#ffffff";
          ctx.lineWidth = 1.5;
          ctx.stroke();
          ctx.strokeStyle = "rgba(168, 85, 247, 0.65)";
          ctx.lineWidth = 3.5;
          ctx.beginPath();
          ctx.arc(hoverX, ptOut.y, 10, 0, Math.PI * 2);
          ctx.stroke();
        }

        // Auréola e ponto destacado In (Download - Verde Esmeralda)
        if (ptIn) {
          ctx.fillStyle = "#00e676";
          ctx.beginPath();
          ctx.arc(hoverX, ptIn.y, 5.5, 0, Math.PI * 2);
          ctx.fill();
          ctx.strokeStyle = "#ffffff";
          ctx.lineWidth = 1.5;
          ctx.stroke();
          ctx.strokeStyle = "rgba(0, 230, 118, 0.65)";
          ctx.lineWidth = 3.5;
          ctx.beginPath();
          ctx.arc(hoverX, ptIn.y, 10, 0, Math.PI * 2);
          ctx.stroke();
        }
      }
    }

    // Drag Box Zoom Selection Overlay na tela
    if (state.isZooming && state.dragStartX != null && state.dragCurrentX != null) {
      const x1 = Math.max(padLeft, Math.min(state.dragStartX, state.dragCurrentX));
      const x2 = Math.min(w - padRight, Math.max(state.dragStartX, state.dragCurrentX));
      const boxW = Math.max(0, x2 - x1);

      ctx.fillStyle = "rgba(0, 176, 255, 0.22)";
      ctx.fillRect(x1, padTop, boxW, plotH);
      ctx.strokeStyle = "#00b0ff";
      ctx.lineWidth = 1.5;
      ctx.setLineDash([4, 2]);
      ctx.strokeRect(x1, padTop, boxW, plotH);
      ctx.setLineDash([]);
    }
  }

  // Configurar Interatividade de Mouse (Crosshair, Tooltip HUD e Drag-to-Zoom)
  function setupCanvasEvents() {
    const wrap = getEl("sgs-canvas-wrap");
    const tooltip = getEl("sgs-canvas-tooltip");
    const btnReset = getEl("sgs-btn-reset-zoom");
    if (!wrap) return;

    // Auto-resize com ResizeObserver
    if (!wrap.__hasResizeObserver && window.ResizeObserver) {
      wrap.__hasResizeObserver = true;
      const ro = new ResizeObserver(() => {
        renderCanvas();
      });
      ro.observe(wrap);
    }

    wrap.onmousemove = function(e) {
      const rect = wrap.getBoundingClientRect();
      const mouseX = e.clientX - rect.left;
      const padLeft = 65, padRight = 20;
      const plotW = rect.width - padLeft - padRight;

      // Arrastando caixa de zoom
      if (state.isZooming) {
        state.dragCurrentX = Math.max(padLeft, Math.min(rect.width - padRight, mouseX));
        if (tooltip) tooltip.style.display = "none";
        renderCanvas();
        return;
      }

      // Cursor fora da área do gráfico
      if (mouseX < padLeft || mouseX > rect.width - padRight) {
        if (tooltip) tooltip.style.display = "none";
        if (state.hoveredIdx !== null) {
          state.hoveredIdx = null;
          renderCanvas();
        }
        return;
      }

      const inData = state.historyIn || [];
      const outData = state.historyOut || [];
      if (inData.length === 0 && outData.length === 0) return;

      let filteredIn = inData;
      let filteredOut = outData;
      if (state.zoomStart !== null && state.zoomEnd !== null) {
        filteredIn = inData.filter(p => p.clock >= state.zoomStart && p.clock <= state.zoomEnd);
        filteredOut = outData.filter(p => p.clock >= state.zoomStart && p.clock <= state.zoomEnd);
      }

      const primary = filteredIn.length > 0 ? filteredIn : filteredOut;
      if (primary.length === 0) return;

      const allClocks = [...filteredIn.map(p => parseInt(p.clock)), ...filteredOut.map(p => parseInt(p.clock))];
      const minTime = Math.min(...allClocks);
      const maxTime = Math.max(...allClocks);
      const timeSpan = Math.max(1, maxTime - minTime);

      // Encontrar ponto mais próximo no eixo X
      let bestIdx = 0;
      let minDiff = Infinity;
      primary.forEach((p, idx) => {
        const ptX = (maxTime === minTime) ? (padLeft + plotW / 2) : (padLeft + ((p.clock - minTime) / timeSpan) * plotW);
        const diff = Math.abs(mouseX - ptX);
        if (diff < minDiff) {
          minDiff = diff;
          bestIdx = idx;
        }
      });

      state.hoveredIdx = bestIdx;
      renderCanvas();

      // Atualizar Tooltip HUD
      const ptIn = filteredIn.length > 0 ? (filteredIn[bestIdx] || filteredIn[filteredIn.length - 1]) : null;
      const valIn = ptIn ? parseFloat(ptIn.value) : 0;
      const refClock = ptIn ? ptIn.clock : (primary[bestIdx] ? primary[bestIdx].clock : 0);

      let valOut = 0;
      if (filteredOut.length > 0) {
        let minDiffOut = Infinity;
        filteredOut.forEach(p => {
          const diff = Math.abs(p.clock - refClock);
          if (diff < minDiffOut) {
            minDiffOut = diff;
            valOut = parseFloat(p.value);
          }
        });
      }

      const d = new Date(refClock * 1000);
      const hhmmss = d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      let timeStr = hhmmss;
      if (state.timeRangeSec >= 86400) {
        const day = String(d.getDate()).padStart(2, "0");
        const mo = String(d.getMonth() + 1).padStart(2, "0");
        timeStr = `${day}/${mo} ${hhmmss}`;
      }

      const ttTime = getEl("sgs-tt-time");
      if (ttTime) ttTime.textContent = timeStr;
      const ttIn = getEl("sgs-tt-in-val");
      if (ttIn) ttIn.textContent = formatBps(valIn);
      const ttOut = getEl("sgs-tt-out-val");
      if (ttOut) ttOut.textContent = formatBps(valOut);
      const ttTotal = getEl("sgs-tt-total-val");
      if (ttTotal) ttTotal.textContent = formatBps(valIn + valOut);

      if (tooltip) {
        const hoverX = (maxTime === minTime) ? (padLeft + plotW / 2) : (padLeft + ((refClock - minTime) / timeSpan) * plotW);
        const hoverPct = (hoverX / rect.width) * 100;
        if (hoverPct > 68) {
          tooltip.style.left = "auto";
          tooltip.style.right = "14px";
          tooltip.style.transform = "none";
        } else if (hoverPct < 32) {
          tooltip.style.left = "65px";
          tooltip.style.right = "auto";
          tooltip.style.transform = "none";
        } else {
          tooltip.style.left = hoverPct + "%";
          tooltip.style.right = "auto";
          tooltip.style.transform = "translateX(-50%)";
        }
        tooltip.style.display = "flex";
      }
    };

    wrap.onmouseleave = function() {
      if (tooltip) tooltip.style.display = "none";
      state.hoveredIdx = null;
      if (state.isZooming) {
        state.isZooming = false;
        state.dragStartX = null;
        state.dragCurrentX = null;
      }
      renderCanvas();
    };

    wrap.onmousedown = function(e) {
      if (e.button !== 0) return;
      const rect = wrap.getBoundingClientRect();
      const mouseX = e.clientX - rect.left;
      const padLeft = 65, padRight = 20;
      if (mouseX < padLeft || mouseX > rect.width - padRight) return;

      state.isZooming = true;
      state.dragStartX = mouseX;
      state.dragCurrentX = mouseX;
      if (tooltip) tooltip.style.display = "none";
      renderCanvas();
    };

    wrap.onmouseup = function(e) {
      if (!state.isZooming || state.dragStartX === null) return;
      state.isZooming = false;

      const rect = wrap.getBoundingClientRect();
      const mouseX = e.clientX - rect.left;
      const padLeft = 65, padRight = 20;
      const plotW = rect.width - padLeft - padRight;

      const x1 = Math.max(padLeft, Math.min(state.dragStartX, mouseX));
      const x2 = Math.min(rect.width - padRight, Math.max(state.dragStartX, mouseX));
      state.dragStartX = null;
      state.dragCurrentX = null;

      if (x2 - x1 > 15 && (state.historyIn.length > 0 || state.historyOut.length > 0)) {
        const allClocks = [...state.historyIn.map(p => parseInt(p.clock)), ...state.historyOut.map(p => parseInt(p.clock))];
        const minTime = Math.min(...allClocks);
        const maxTime = Math.max(...allClocks);
        const timeSpan = Math.max(1, maxTime - minTime);

        state.zoomStart = Math.floor(minTime + ((x1 - padLeft) / plotW) * timeSpan);
        state.zoomEnd = Math.ceil(minTime + ((x2 - padLeft) / plotW) * timeSpan);

        if (btnReset) btnReset.style.display = "inline-block";
      }
      renderCanvas();
    };

    // Duplo clique reseta zoom
    wrap.ondblclick = function() {
      state.zoomStart = null;
      state.zoomEnd = null;
      if (btnReset) btnReset.style.display = "none";
      renderCanvas();
    };

    // Reset Zoom
    if (btnReset) {
      btnReset.onclick = function() {
        state.zoomStart = null;
        state.zoomEnd = null;
        btnReset.style.display = "none";
        renderCanvas();
      };
    }
  }

  // Configurar Botões de Período de Tempo
  function setupTimeButtons() {
    const btns = document.querySelectorAll(".sgs-time-pill");
    btns.forEach(btn => {
      btn.onclick = function() {
        btns.forEach(b => b.classList.remove("active"));
        btn.classList.add("active");
        state.timeRangeSec = parseInt(btn.getAttribute("data-sec")) || 21600;
        state.zoomStart = null;
        state.zoomEnd = null;
        const btnReset = getEl("sgs-btn-reset-zoom");
        if (btnReset) btnReset.style.display = "none";
        fetchTelemetry();
      };
    });
  }

  // Configurar Drawer
  function setupDrawer() {
    const btnOpen = getEl("sgs-btn-drawer");
    const btnClose = getEl("sgs-drawer-close");
    const drawer = getEl("sgs-drawer");
    if (btnOpen && drawer) {
      btnOpen.onclick = () => { drawer.style.display = "flex"; };
    }
    if (btnClose && drawer) {
      btnClose.onclick = () => { drawer.style.display = "none"; };
    }
  }

  // Inicialização Geral
  function init() {
    renderHostSelect();
    renderIfaceSelect();
    renderInterfacesTable();
    renderTopLinks();
    updateChassisUI();
    setupCanvasEvents();
    setupTimeButtons();
    setupDrawer();

    const sub = getEl("sgs-chart-sub");
    if (sub && state.currentIface) sub.textContent = "Interface: " + state.currentIface.name;

    const btnSync = getEl("sgs-sync-btn");
    if (btnSync) {
      btnSync.onclick = () => fetchTelemetry();
    }

    // Redimensionamento de Janela
    window.addEventListener("resize", () => renderCanvas());

    // Polling contínuo a cada 15 segundos
    state.pollTimer = setInterval(() => {
      if (!document.hidden) fetchTelemetry();
    }, 15000);

    // Primeira busca
    fetchTelemetry();
  }

  // Singleton de runtime para limpeza segura
  window.__SGS_MODEM_TWIN_RUNTIME__ = {
    destroy: function() {
      if (state.pollTimer) clearInterval(state.pollTimer);
    }
  };

  // Executar após carga do DOM
  setTimeout(init, 50);

})();
"""
js_script = js_script.replace("__ZABBIX_URL__", ZABBIX_URL).replace("__ZABBIX_TOKEN__", ZABBIX_TOKEN).replace("__CATALOG_JSON__", catalog_json)

# Strip leading whitespace from all HTML lines to prevent Markdown from interpreting indented lines as code blocks
clean_lines = [l.strip() for l in html_content.splitlines() if l.strip()]
html_clean = "\n".join(clean_lines)

# 4. Construir o JSON do Dashboard do Grafana
print("4. Montando JSON do Dashboard para o Grafana...")

dashboard_obj = {
    "annotations": { "list": [] },
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 0,
    "links": [],
    "liveNow": False,
    "panels": [
        {
            "gridPos": { "h": 28, "w": 24, "x": 0, "y": 0 },
            "id": 1,
            "options": {
                "afterRender": js_script,
                "content": html_clean,
                "defaultContent": html_clean,
                "renderMode": "all",
                "styles": css_styles
            },
            "title": "",
            "transparent": True,
            "type": "marcusolsson-dynamictext-panel"
        }
    ],
    "refresh": "1m",
    "schemaVersion": 39,
    "tags": ["sgs", "modem", "wan", "link", "snmp"],
    "time": { "from": "now-6h", "to": "now" },
    "timepicker": {},
    "timezone": "browser",
    "title": DASHBOARD_TITLE,
    "uid": DASHBOARD_UID,
    "version": 1
}

full_html = f"{html_content}\n<style>{css_styles}</style>\n<script>{js_script}</script>"

# Salvar arquivos locais de backup e controle de versão
os.makedirs("grafana/dashboards", exist_ok=True)
with open("grafana/dashboards/sgs_modem_wan_twin.html", "w", encoding="utf-8") as f:
    f.write(full_html)

with open("grafana/dashboards/sgs_modem_wan_twin.json", "w", encoding="utf-8") as f:
    json.dump(dashboard_obj, f, indent=2, ensure_ascii=False)

print("Arquivos locais gerados em grafana/dashboards/sgs_modem_wan_twin.*")

# 5. Publicar no Grafana REST API
print(f"5. Publicando no Grafana ({GRAFANA_URL}/api/dashboards/db)...")

# Verificar se dashboard já existe para preservar ID
try:
    check_r = requests.get(f"{GRAFANA_URL}/api/dashboards/uid/{DASHBOARD_UID}", auth=(GRAFANA_USER, GRAFANA_PASSWORD))
    if check_r.status_code == 200:
        existing = check_r.json()
        dashboard_obj["id"] = existing["dashboard"]["id"]
        dashboard_obj["version"] = existing["dashboard"].get("version", 0) + 1
        print(f"Dashboard existente detectado (ID: {dashboard_obj['id']}). Incrementando versão para {dashboard_obj['version']}...")
except Exception as e:
    print("Novo dashboard será criado.", e)

deploy_payload = {
    "dashboard": dashboard_obj,
    "folderId": TARGET_FOLDER_ID,
    "overwrite": True
}

deploy_r = requests.post(
    f"{GRAFANA_URL}/api/dashboards/db",
    json=deploy_payload,
    auth=(GRAFANA_USER, GRAFANA_PASSWORD),
    headers={"Content-Type": "application/json"}
)

print(f"Status do Deploy: {deploy_r.status_code}")
print(f"Resposta Grafana: {deploy_r.text}")

if deploy_r.status_code == 200:
    res_data = deploy_r.json()
    print("\n[OK] SUCESSO! Dashboard de Modems/Links WAN implantada com sucesso no Grafana:")
    print(f"URL: {GRAFANA_URL}{res_data.get('url')}")
    print(f"UID: {DASHBOARD_UID}")
    print(f"Pasta: POC ALEX (Folder ID: {TARGET_FOLDER_ID})")
else:
    print("\n[FAIL] Falha no deploy no Grafana:", deploy_r.status_code, deploy_r.text)
