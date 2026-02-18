sudo tee /root/install-smartendurance.sh >/dev/null <<'EOF'
#!/bin/sh
set -eu

# SmartEndurance Widgets Installer for OPNsense
# Installs:
#  - SmartEndurance (table widget)
#  - SmartEnduranceGauge (mini gauge widget)
# Plus metadata, permissions, backups to /conf, and restarts Web GUI.

WIDGET_DIR="/usr/local/opnsense/www/js/widgets"
META_DIR="${WIDGET_DIR}/Metadata"
BACKUP_BASE="/conf/custom_widgets"
BACKUP_JS="${BACKUP_BASE}/js"
BACKUP_META="${BACKUP_BASE}/Metadata"

say() { printf "\n==> %s\n" "$*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (use sudo)." >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${WIDGET_DIR}" "${META_DIR}" "${BACKUP_JS}" "${BACKUP_META}"
}

write_files() {
  say "Writing SmartEndurance.js"
  cat > "${WIDGET_DIR}/SmartEndurance.js" <<'JS_EOF'
export default class SmartEndurance extends BaseTableWidget {
  constructor() {
    super();
    this.tickTimeout = 3600;          // 1 hour (guard below makes it run once per page load)
    this.RATED_TBW = 500;             // fallback TBW for WD Red SN700 250GB
    this._ranOnce = false;
    this._last = null;                // cached computed data so Mode toggles without API calls
    this._modeKey = 'SmartEndurance:showDetails';
  }

  getMarkup() {
    const $container = $('<div></div>');
    const $table = this.createTable('smartendurance-table', { headerPosition: 'left' });
    $container.append($table);
    return $container;
  }

  _getShowDetails() {
    try {
      const v = localStorage.getItem(this._modeKey);
      if (v === null) return false; // default compact
      return v === '1';
    } catch (e) {
      return false;
    }
  }

  _setShowDetails(val) {
    try { localStorage.setItem(this._modeKey, val ? '1' : '0'); } catch (e) {}
  }

  _bindModeClick() {
    // Scoped, namespaced, safe. Rebind every render (table DOM may rebuild).
    try {
      const $t = $('#smartendurance-table');
      if (!$t.length) return;

      $t.off('click.smartendurance');
      $t.on('click.smartendurance', 'a.se-mode-toggle', (e) => {
        e.preventDefault();
        const cur = this._getShowDetails();
        this._setShowDetails(!cur);
        if (this._last) this._render(this._last); // re-render from cache; no SMART re-query
      });
    } catch (e) {}
  }

  _num(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  _tbFromUnits(units) {
    const u = this._num(units);
    if (u === null) return null;
    return (u * 512000) / 1e12; // TB (decimal)
  }

  _fmtTB(tb) {
    if (tb === null || !Number.isFinite(tb)) return '—';
    return tb.toFixed(2) + ' TB';
  }

  _fmtRate(tbPerDay) {
    if (tbPerDay === null || !Number.isFinite(tbPerDay)) return '—';
    return tbPerDay >= 0.1 ? tbPerDay.toFixed(2) + ' TB/day' : (tbPerDay * 1000).toFixed(1) + ' GB/day';
  }

  _fmtDays(days) {
    if (days === null || !Number.isFinite(days)) return '—';
    if (days < 365) return Math.round(days) + ' days';
    return (days / 365.0).toFixed(1) + ' years';
  }

  _badge(text, level) {
    const styles = {
      good: 'display:inline-block;padding:2px 8px;border-radius:12px;font-weight:700;background:#173a2a;color:#7CFFB2;border:1px solid #2a6a49;',
      warn: 'display:inline-block;padding:2px 8px;border-radius:12px;font-weight:700;background:#3a3217;color:#FFE08A;border:1px solid #6a5a2a;',
      bad:  'display:inline-block;padding:2px 8px;border-radius:12px;font-weight:700;background:#3a1717;color:#FF9C9C;border:1px solid #6a2a2a;'
    };
    return `<span style="${styles[level] || styles.good}">${text}</span>`;
  }

  _healthLevel({ criticalWarning, percentUsed, tempC, spare }) {
    if (criticalWarning !== null && criticalWarning !== 0) return 'bad';
    if (tempC !== null && tempC >= 70) return 'bad';
    if (tempC !== null && tempC >= 60) return 'warn';
    if (percentUsed !== null && percentUsed >= 80) return 'bad';
    if (percentUsed !== null && percentUsed >= 50) return 'warn';
    if (spare !== null && spare <= 5) return 'bad';
    if (spare !== null && spare <= 20) return 'warn';
    return 'good';
  }

  _detectRatedTBW(raw) {
    // Best-effort only. Most NVMe JSON won't have this; fallback is configured value.
    try {
      const c = [];
      if (raw?.endurance?.tbw !== undefined) c.push(this._num(raw.endurance.tbw));
      if (raw?.endurance?.rated_tbw !== undefined) c.push(this._num(raw.endurance.rated_tbw));
      if (raw?.device?.rated_tbw !== undefined) c.push(this._num(raw.device.rated_tbw));
      if (raw?.vendor?.rated_tbw !== undefined) c.push(this._num(raw.vendor.rated_tbw));
      if (raw?.nvme_id_ctrl?.rated_tbw !== undefined) c.push(this._num(raw.nvme_id_ctrl.rated_tbw));
      const good = c.filter(v => v !== null && v > 0 && v < 1000000);
      return good.length ? good[0] : null;
    } catch (e) {
      return null;
    }
  }

  _render(d) {
    try {
      const showDetails = this._getShowDetails();

      const rows = [
        [['Drive'], `${d.model} (${d.dev})`],
        [['Health'], this._badge(d.healthText, d.level)],
        [['Vitals'], `Temp ${d.tempC ?? '—'}°C · Wear ${d.wear ?? '—'}% · Spare ${d.spare ?? '—'}% · Warn ${d.crit ?? '—'}`],
        [['Usage'], `W ${this._fmtTB(d.tbW)} · R ${this._fmtTB(d.tbR)} · ${this._fmtRate(d.tbPerDay)}`],
        [['Remaining'], `TBW ${d.rated ? (d.rated + ' TB') : '—'} (${d.ratedSource}) · Left ${this._fmtTB(d.remainingTB)} · ${this._fmtDays(d.remainingLife)}`],
        [['Mode'], `<a href="#" class="se-mode-toggle" style="text-decoration:none;font-weight:700;opacity:.95;">${showDetails ? 'Detailed' : 'Compact'}</a> <span style="opacity:.75;">(click)</span>`],
      ];

      if (showDetails) {
        rows.push(
          [['Serial'], d.serial],
          [['Firmware'], d.firmware],
          [['Available Spare (%)'], String(d.spare ?? '—')],
          [['Spare Threshold (%)'], String(d.spareThresh ?? '—')],
          [['Unsafe Shutdowns'], String(d.unsafe ?? '—')],
          [['Media/Data Errors'], String(d.mediaErrors ?? '—')],
          [['Error Log Entries'], String(d.errLog ?? '—')],
          [['Controller Busy Time'], String(d.busy ?? '—')],
          [['Power Cycles'], String(d.cycles ?? '—')],
          [['Power On Hours'], String(d.poh ?? '—')],
          [['Data Units Written'], String(d.unitsW ?? '—')],
          [['Data Units Read'], String(d.unitsR ?? '—')],
          [['Host Read Cmds'], String(d.hostR ?? '—')],
          [['Host Write Cmds'], String(d.hostW ?? '—')],
        );
      }

      this.updateTable('smartendurance-table', rows);
      this._bindModeClick();
    } catch (e) {}
  }

  async onWidgetTick() {
    if (this._ranOnce) return;
    this._ranOnce = true;

    try {
      const list = await $.ajax({ url: '/api/smart/service/list', method: 'POST', dataType: 'json', data: {} });
      const devices = (list && Array.isArray(list.devices)) ? list.devices.filter(Boolean) : [];
      const dev = devices.includes('nvme0') ? 'nvme0' : (devices.find(x => /^nvme\\d+$/i.test(x)) || devices[0]);

      if (!dev) {
        this.updateTable('smartendurance-table', [[['Status'], `${this.translations.nodisk}`]]);
        return;
      }

      const info = await $.ajax({
        url: '/api/smart/service/info',
        method: 'POST',
        dataType: 'json',
        data: { device: dev, type: 'a', json: '1' }
      });

      if (info && info.message) {
        this.updateTable('smartendurance-table', [
          [['Drive'], dev],
          [['Status'], String(info.message)]
        ]);
        return;
      }

      let raw = info && info.output ? info.output : null;
      if (typeof raw === 'string') { try { raw = JSON.parse(raw); } catch (e) {} }
      if (!raw || typeof raw !== 'object') {
        this.updateTable('smartendurance-table', [
          [['Drive'], dev],
          [['Status'], `${this.translations.nosmart} ${dev}`]
        ]);
        return;
      }

      const deviceNode = raw.device || {};
      const model = raw.model_name || deviceNode.model_name || raw.model_family || '—';
      const serial = raw.serial_number || deviceNode.serial_number || '—';
      const firmware = raw.firmware_version || deviceNode.firmware_version || '—';

      const log = raw.nvme_smart_health_information_log || null;
      if (!log) {
        this.updateTable('smartendurance-table', [
          [['Drive'], `${model} (${dev})`],
          [['Status'], 'No NVMe SMART log found']
        ]);
        return;
      }

      const tempC = this._num(log.temperature);
      const wear = this._num(log.percentage_used);
      const spare = this._num(log.available_spare);
      const spareThresh = this._num(log.available_spare_threshold);
      const crit = this._num(log.critical_warning);
      const poh = this._num(log.power_on_hours);

      const unitsW = this._num(log.data_units_written);
      const unitsR = this._num(log.data_units_read);

      const tbW = this._tbFromUnits(unitsW);
      const tbR = this._tbFromUnits(unitsR);

      const daysOn = (poh && poh > 0) ? (poh / 24.0) : null;
      const tbPerDay = (tbW !== null && daysOn && daysOn > 0) ? (tbW / daysOn) : null;

      const ratedSmart = this._detectRatedTBW(raw);
      const ratedConfigured = this._num(this.RATED_TBW);
      const rated = (ratedSmart !== null) ? ratedSmart : ratedConfigured;
      const ratedSource = (ratedSmart !== null) ? 'SMART' : 'Configured';

      const remainingTB = (rated !== null && tbW !== null) ? Math.max(0, rated - tbW) : null;
      const remainingLife = (remainingTB !== null && tbPerDay && tbPerDay > 0) ? (remainingTB / tbPerDay) : null;

      const level = this._healthLevel({ criticalWarning: crit, percentUsed: wear, tempC, spare });
      const healthText = (level === 'good') ? 'Healthy' : (level === 'warn') ? 'Watch' : 'At Risk';

      this._last = {
        dev, model, serial, firmware,
        tempC, wear, spare, spareThresh, crit, poh,
        tbW, tbR, tbPerDay,
        rated, ratedSource, remainingTB, remainingLife,
        level, healthText,
        unsafe: this._num(log.unsafe_shutdowns),
        mediaErrors: this._num(log.media_errors),
        errLog: this._num(log.num_err_log_entries),
        busy: this._num(log.controller_busy_time),
        cycles: this._num(log.power_cycles),
        hostR: this._num(log.host_read_commands),
        hostW: this._num(log.host_write_commands),
        unitsW, unitsR
      };

      this._render(this._last);

    } catch (e) {
      try { this.updateTable('smartendurance-table', [[['Status'], `${this.translations.nosmart}`]]); } catch (e2) {}
    }
  }
}
JS_EOF

  say "Writing SmartEnduranceGauge.js"
  cat > "${WIDGET_DIR}/SmartEnduranceGauge.js" <<'JS_EOF'
export default class SmartEnduranceGauge extends BaseTableWidget {
  constructor() {
    super();
    this.tickTimeout = 3600; // 1 hour (guard below)
    this.RATED_TBW = 500;    // fallback TBW
    this._ranOnce = false;
  }

  getMarkup() {
    const $container = $('<div></div>');
    const $table = this.createTable('smartendurancegauge-table', { headerPosition: 'left' });
    $container.append($table);
    return $container;
  }

  _num(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  _tbFromUnits(units) {
    const u = this._num(units);
    if (u === null) return null;
    return (u * 512000) / 1e12; // TB (decimal)
  }

  _detectRatedTBW(raw) {
    try {
      const c = [];
      if (raw?.endurance?.tbw !== undefined) c.push(this._num(raw.endurance.tbw));
      if (raw?.endurance?.rated_tbw !== undefined) c.push(this._num(raw.endurance.rated_tbw));
      if (raw?.device?.rated_tbw !== undefined) c.push(this._num(raw.device.rated_tbw));
      if (raw?.vendor?.rated_tbw !== undefined) c.push(this._num(raw.vendor.rated_tbw));
      if (raw?.nvme_id_ctrl?.rated_tbw !== undefined) c.push(this._num(raw.nvme_id_ctrl.rated_tbw));
      const good = c.filter(v => v !== null && v > 0 && v < 1000000);
      return good.length ? good[0] : null;
    } catch (e) { return null; }
  }

  _bar(pct) {
    const p = Math.max(0, Math.min(100, pct));
    let fg = '#7CFFB2'; // green
    if (p >= 50) fg = '#FFE08A'; // yellow
    if (p >= 80) fg = '#FF9C9C'; // red

    return `
      <div style="width:100%;max-width:260px;">
        <div style="font-weight:700;margin-bottom:4px;">Used: ${p.toFixed(0)}%</div>
        <div style="height:10px;border-radius:999px;background:rgba(255,255,255,0.10);overflow:hidden;border:1px solid rgba(255,255,255,0.12);">
          <div style="height:100%;width:${p}%;background:${fg};"></div>
        </div>
      </div>
    `;
  }

  async onWidgetTick() {
    if (this._ranOnce) return;
    this._ranOnce = true;

    try {
      const list = await $.ajax({ url: '/api/smart/service/list', method: 'POST', dataType: 'json', data: {} });
      const devices = (list && Array.isArray(list.devices)) ? list.devices.filter(Boolean) : [];
      const dev = devices.includes('nvme0') ? 'nvme0' : (devices.find(x => /^nvme\\d+$/i.test(x)) || devices[0]);

      if (!dev) {
        this.updateTable('smartendurancegauge-table', [[['Status'], `${this.translations.nodisk}`]]);
        return;
      }

      const info = await $.ajax({
        url: '/api/smart/service/info',
        method: 'POST',
        dataType: 'json',
        data: { device: dev, type: 'a', json: '1' }
      });

      if (info && info.message) {
        this.updateTable('smartendurancegauge-table', [
          [['Drive'], dev],
          [['Status'], String(info.message)]
        ]);
        return;
      }

      let raw = info && info.output ? info.output : null;
      if (typeof raw === 'string') { try { raw = JSON.parse(raw); } catch (e) {} }
      const log = raw?.nvme_smart_health_information_log || null;

      if (!raw || !log) {
        this.updateTable('smartendurancegauge-table', [
          [['Drive'], dev],
          [['Status'], `${this.translations.nosmart} ${dev}`]
        ]);
        return;
      }

      const model = raw.model_name || raw?.device?.model_name || '—';
      const wear = this._num(log.percentage_used); // 0..100
      const unitsW = this._num(log.data_units_written);
      const tbW = this._tbFromUnits(unitsW);

      const ratedSmart = this._detectRatedTBW(raw);
      const ratedConfigured = this._num(this.RATED_TBW);
      const rated = (ratedSmart !== null) ? ratedSmart : ratedConfigured;
      const ratedSource = (ratedSmart !== null) ? 'SMART' : 'Configured';

      let usedPct = wear;
      if (usedPct === null && rated && tbW !== null) usedPct = Math.max(0, Math.min(100, (tbW / rated) * 100));
      if (usedPct === null) usedPct = 0;

      this.updateTable('smartendurancegauge-table', [
        [['Drive'], `${model} (${dev})`],
        [['Gauge'], this._bar(usedPct)],
        [['Written'], (tbW !== null) ? `${tbW.toFixed(2)} TB` : '—'],
        [['TBW'], rated ? `${rated} TB (${ratedSource})` : '—'],
      ]);

    } catch (e) {
      try { this.updateTable('smartendurancegauge-table', [[['Status'], `${this.translations.nosmart}`]]); } catch (e2) {}
    }
  }
}
JS_EOF

  say "Writing SmartEndurance metadata"
  cat > "${META_DIR}/SmartEndurance.xml" <<'XML_EOF'
<metadata>
    <smartendurance>
        <filename>SmartEndurance.js</filename>
        <endpoints>
            <endpoint>/api/smart/service/*</endpoint>
        </endpoints>
        <translations>
            <title>SSD Endurance</title>
            <nodisk>Error fetching disk list</nodisk>
            <nosmart>Error fetching SMART info for device</nosmart>
        </translations>
    </smartendurance>
</metadata>
XML_EOF

  say "Writing SmartEnduranceGauge metadata"
  cat > "${META_DIR}/SmartEnduranceGauge.xml" <<'XML_EOF'
<metadata>
  <smartendurancegauge>
    <filename>SmartEnduranceGauge.js</filename>
    <endpoints>
      <endpoint>/api/smart/service/*</endpoint>
    </endpoints>
    <translations>
      <title>SSD Endurance Gauge</title>
      <nodisk>Error fetching disk list</nodisk>
      <nosmart>Error fetching SMART info for device</nosmart>
    </translations>
  </smartendurancegauge>
</metadata>
XML_EOF
}

fix_perms() {
  say "Fixing ownership and permissions"
  chown root:wheel \
    "${WIDGET_DIR}/SmartEndurance.js" \
    "${WIDGET_DIR}/SmartEnduranceGauge.js" \
    "${META_DIR}/SmartEndurance.xml" \
    "${META_DIR}/SmartEnduranceGauge.xml"
  chmod 0644 \
    "${WIDGET_DIR}/SmartEndurance.js" \
    "${WIDGET_DIR}/SmartEnduranceGauge.js" \
    "${META_DIR}/SmartEndurance.xml" \
    "${META_DIR}/SmartEnduranceGauge.xml"
}

backup_files() {
  say "Backing up to ${BACKUP_BASE}"
  cp -f "${WIDGET_DIR}/SmartEndurance.js" "${BACKUP_JS}/SmartEndurance.js"
  cp -f "${WIDGET_DIR}/SmartEnduranceGauge.js" "${BACKUP_JS}/SmartEnduranceGauge.js"
  cp -f "${META_DIR}/SmartEndurance.xml" "${BACKUP_META}/SmartEndurance.xml"
  cp -f "${META_DIR}/SmartEnduranceGauge.xml" "${BACKUP_META}/SmartEnduranceGauge.xml"
}

restart_webgui() {
  say "Restarting Web GUI"
  if command -v configctl >/dev/null 2>&1; then
    configctl webgui restart || true
  else
    echo "WARN: configctl not found; restart Web GUI manually." >&2
  fi
}

list_installed() {
  say "Installed widget files"
  ls -la "${WIDGET_DIR}" | egrep -i 'SmartEndurance|Gauge' || true
  ls -la "${META_DIR}" | egrep -i 'SmartEndurance|Gauge' || true
}

need_root
ensure_dirs
write_files
fix_perms
backup_files
restart_webgui
list_installed

say "Done."
echo "Next: hard-refresh your browser, then Dashboard -> Add widget -> add:"
echo " - SSD Endurance"
echo " - SSD Endurance Gauge"
EOF

sudo tee /root/README-SmartEndurance.md >/dev/null <<'EOF'
# SmartEndurance Widgets for OPNsense

Two lightweight dashboard widgets that read SMART/NVMe data via the built-in OPNsense SMART API.

## Widgets

### 1) SSD Endurance (table)
Shows a compact summary in this order:

- **Drive** (model + device)
- **Health** (green/yellow/red badge)
- **Vitals** (Temp, Wear %, Spare %, Critical warning)
- **Usage** (TB written/read, estimated write-per-day)
- **Remaining** (TBW rating, remaining TB, estimated remaining life)
- **Mode** (click to toggle Compact/Detailed)

**Mode toggle is safe:** it re-renders from cached data only (no extra SMART calls).

### 2) SSD Endurance Gauge (mini bar)
A small wear gauge (0–100%) with quick TB written and rated TBW.

## SMART polling behavior (SSD-friendly)
Both widgets:
- call the SMART API **once per dashboard page load** (guarded),
- do **not** run rapid background polling,
- mode toggle does **not** trigger any new API calls.

## Installation

### One-file installer
Copy `install-smartendurance.sh` to your OPNsense box and run:

```sh
sudo sh /root/install-smartendurance.sh
