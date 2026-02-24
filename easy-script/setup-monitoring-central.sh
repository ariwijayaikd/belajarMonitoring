#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Central Monitoring Stack (Docker Compose)
# - Prometheus (30d local retention)
# - VictoriaMetrics (long-term retention)
# - Grafana (provision datasources + dashboard)
# - Blackbox Exporter (Go)
# - Alertmanager (minimal)
#
# Working dir expected:
#   /home/perbudakan/monitoring/
# =========================================================

ROOT_DIR="$(pwd)"

if [[ "$ROOT_DIR" != "/home/perbudakan/monitoring" ]]; then
  echo "ERROR: Jalankan script dari /home/perbudakan/monitoring/"
  echo "Saat ini: $ROOT_DIR"
  exit 1
fi

echo "[1/8] Membuat struktur folder..."
mkdir -p \
  prometheus/rules \
  grafana/provisioning/datasources \
  grafana/provisioning/dashboards \
  grafana/dashboards \
  blackbox \
  alertmanager

echo "[2/8] Menulis docker-compose.yml..."
cat > docker-compose.yml <<'YAML'
services:
  victoriametrics:
    image: victoriametrics/victoria-metrics:v1.104.0
    container_name: victoriametrics
    command:
      - "-storageDataPath=/storage"
      # Retensi long-term (bulan). Ubah sesuai kebutuhan.
      # 120 = 10 tahun
      - "-retentionPeriod=120"
    volumes:
      - vm_data:/storage
    ports:
      - "8428:8428"
    restart: unless-stopped

  blackbox:
    image: prom/blackbox-exporter:v0.25.0
    container_name: blackbox_exporter
    command:
      - "--config.file=/etc/blackbox_exporter/blackbox.yml"
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox_exporter/blackbox.yml:ro
    ports:
      - "9115:9115"
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    ports:
      - "9093:9093"
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v2.55.0
    container_name: prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      # Retensi lokal Prometheus untuk query cepat:
      - "--storage.tsdb.retention.time=30d"
      - "--web.enable-lifecycle"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prom_data:/prometheus
    ports:
      - "9090:9090"
    restart: unless-stopped
    depends_on:
      - blackbox
      - victoriametrics
      - alertmanager

  grafana:
    image: grafana/grafana:11.2.0
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin123!   # GANTI PASSWORD INI
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "3000:3000"
    restart: unless-stopped
    depends_on:
      - prometheus
      - victoriametrics

volumes:
  prom_data:
  grafana_data:
  vm_data:
YAML

echo "[3/8] Menulis config blackbox exporter..."
cat > blackbox/blackbox.yml <<'YAML'
modules:
  http_2xx_15s:
    prober: http
    timeout: 5s
    http:
      method: GET
      follow_redirects: true
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]

  tcp_connect:
    prober: tcp
    timeout: 3s
YAML

echo "[4/8] Menulis Alertmanager config minimal..."
cat > alertmanager/alertmanager.yml <<'YAML'
route:
  receiver: "default"

receivers:
  - name: "default"
YAML

echo "[5/8] Menulis Prometheus config (prometheus.yml)..."
cat > prometheus/prometheus.yml <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# Simpan jangka panjang ke VictoriaMetrics
remote_write:
  - url: "http://victoriametrics:8428/api/v1/write"

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["prometheus:9090"]

  # =========================================================
  # EDIT DI BAGIAN INI SESUAI TARGET VM KAMU
  # =========================================================

  - job_name: "node_exporter"
    static_configs:
      - targets:
          - "10.0.1.11:9100"
          - "10.0.1.12:9100"

  - job_name: "cadvisor"
    static_configs:
      - targets:
          - "10.0.1.11:8080"
          - "10.0.1.12:8080"

  - job_name: "blackbox_http"
    scrape_interval: 15s
    metrics_path: /probe
    params:
      module: [http_2xx_15s]
    static_configs:
      - targets:
          - "https://app-01.domainmu.go.id/health"
          - "https://app-02.domainmu.go.id/health"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "blackbox:9115"

  - job_name: "blackbox_tcp"
    scrape_interval: 15s
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets:
          - "10.0.1.11:8088"
          - "10.0.1.12:5432"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "blackbox:9115"
YAML

echo "[6/8] Menulis Prometheus rules (SLA + latency threshold)..."

# Default threshold 0.30s (300ms) - ubah di bawah jika perlu:
LATENCY_THRESHOLD_SECONDS="${LATENCY_THRESHOLD_SECONDS:-0.30}"

cat > prometheus/rules/sla_blackbox.yml <<YAML
groups:
  - name: sla-blackbox
    interval: 15s
    rules:
      - record: slo:probe_p95_seconds
        expr: |
          histogram_quantile(
            0.95,
            sum by (le, instance) (
              rate(probe_duration_seconds_bucket{job="blackbox_http"}[5m])
            )
          )

      - record: slo:probe_up
        expr: |
          (probe_success{job="blackbox_http"} == 1)

      - record: slo:probe_latency_ok
        expr: |
          (slo:probe_p95_seconds <= ${LATENCY_THRESHOLD_SECONDS})

      - record: slo:probe_slo_ok
        expr: |
          slo:probe_up * on(instance) slo:probe_latency_ok

      - record: sla:probe_30d_percent
        expr: |
          avg_over_time(slo:probe_slo_ok[30d]) * 100

      - record: sla:probe_7d_percent
        expr: |
          avg_over_time(slo:probe_slo_ok[7d]) * 100

      - record: sla:probe_24h_percent
        expr: |
          avg_over_time(slo:probe_slo_ok[24h]) * 100
YAML

cat > prometheus/rules/alerts_blackbox.yml <<YAML
groups:
  - name: alerts-blackbox
    rules:
      - alert: ServiceSLOFailing
        expr: |
          avg_over_time(slo:probe_slo_ok[10m]) < 0.99
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "SLO gagal (up+latency) selama 10m"
          description: "Target {{ \$labels.instance }} SLO < 99% (10m)."

      - alert: HighP95Latency
        expr: |
          slo:probe_p95_seconds > ${LATENCY_THRESHOLD_SECONDS}
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "P95 latency tinggi"
          description: "Target {{ \$labels.instance }} p95 > threshold selama 10m."
YAML

echo "[7/8] Menulis Grafana provisioning (datasources + dashboards)..."
cat > grafana/provisioning/datasources/datasources.yml <<'YAML'
apiVersion: 1

datasources:
  - name: Prometheus-Local
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true

  - name: VictoriaMetrics-LongTerm
    type: prometheus
    access: proxy
    url: http://victoriametrics:8428
YAML

cat > grafana/provisioning/dashboards/dashboards.yml <<'YAML'
apiVersion: 1

providers:
  - name: "default"
    folder: ""
    type: file
    disableDeletion: true
    editable: true
    options:
      path: /var/lib/grafana/dashboards
YAML

echo "[7/8] Menulis dashboard SLA (Grafana JSON)..."
cat > grafana/dashboards/sla_blackbox.json <<'JSON'
{
  "uid": "sla-blackbox",
  "title": "SLA - Blackbox (Up + Latency Threshold)",
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "panels": [
    {
      "type": "stat",
      "title": "SLA 30d (%)",
      "gridPos": { "x": 0, "y": 0, "w": 8, "h": 5 },
      "targets": [
        { "expr": "sla:probe_30d_percent", "refId": "A" }
      ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
    },
    {
      "type": "stat",
      "title": "SLA 7d (%)",
      "gridPos": { "x": 8, "y": 0, "w": 8, "h": 5 },
      "targets": [
        { "expr": "sla:probe_7d_percent", "refId": "A" }
      ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
    },
    {
      "type": "stat",
      "title": "SLA 24h (%)",
      "gridPos": { "x": 16, "y": 0, "w": 8, "h": 5 },
      "targets": [
        { "expr": "sla:probe_24h_percent", "refId": "A" }
      ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
    },
    {
      "type": "timeseries",
      "title": "p95 Latency (seconds) per target",
      "gridPos": { "x": 0, "y": 5, "w": 24, "h": 8 },
      "targets": [
        { "expr": "slo:probe_p95_seconds", "refId": "A" }
      ]
    },
    {
      "type": "timeseries",
      "title": "Up (probe_success) per target",
      "gridPos": { "x": 0, "y": 13, "w": 24, "h": 8 },
      "targets": [
        { "expr": "probe_success{job=\"blackbox_http\"}", "refId": "A" }
      ]
    }
  ]
}
JSON

echo "[8/8] Menjalankan docker compose up -d..."
docker compose up -d

echo ""
echo "SELESAI"
echo "Grafana : http://<IP_VM_PUSAT>:3000 (admin / admin123!)"
echo "Prometheus : http://<IP_VM_PUSAT>:9090"
echo "VictoriaMetrics : http://<IP_VM_PUSAT>:8428"
echo ""
echo "Catatan:"
echo "- Edit target di prometheus/prometheus.yml (node_exporter, cadvisor, blackbox_http, blackbox_tcp)."
echo "- Ubah threshold via env var: LATENCY_THRESHOLD_SECONDS=0.25 ./setup-monitoring-central.sh"