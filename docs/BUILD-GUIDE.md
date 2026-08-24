# Monitoring Capstone — Complete Build Guide

This is the single, self-contained walkthrough for **Section 5 (Monitoring)** of the SkillfyMe capstone.
Follow it top to bottom. You build everything yourself on one AWS EC2 instance; every command and every
config file is here, with a short explanation of *why* it exists.

**How to use this guide**
- Every ```` ```bash ```` block is meant to be pasted into your EC2 SSH session.
- Every ```` ```yaml/conf/python ```` block that starts with `cat > path <<'EOF'` **creates a file** — paste
  the whole block (including the `EOF`) and it writes the file for you.
- Do the projects **one at a time**. Tear each down (`docker compose down -v`) before the next.

**Contents**
- [Phase 0 — Provision AWS + install Docker](#phase-0)
- [Project 5.1 — Prometheus + Grafana](#project-51)
- [Project 5.2 — ELK logging](#project-52)
- [Project 5.3 — Alerting + Tracing](#project-53)
- [Project 5.4 — Scaling with Thanos](#project-54)
- [Troubleshooting](#troubleshooting)
- [Teardown & cost control](#teardown)

---

<a name="phase-0"></a>
## Phase 0 — Provision AWS + install Docker

### 0.1 Launch the EC2 instance

AWS Console → **EC2 → Launch instance**:

| Setting | Value | Why |
|---------|-------|-----|
| **Name** | `monitoring-capstone` | |
| **AMI** | **Ubuntu Server 22.04 LTS** | smoothest Docker install; this guide's commands assume it |
| **Instance type** | **m7i-flex.large** (2 vCPU / **8 GB**) — *or* t3.large (8 GB) / t3.xlarge (16 GB) | Need **≥ 8 GB RAM**; ELK (5.2) & Thanos (5.4) get OOM-killed below that. **Don't** use t3.micro (1 GB), t3.small (2 GB), or c7i-flex.large (4 GB) — too small |
| **Key pair** | Create new → RSA → `.pem` → download | your SSH login key; **can't be re-downloaded**, keep it safe |
| **Storage** | **30 GB gp3** | Docker images + metric/log data fill the default 8 GB |
| **Security group** | new `monitoring-sg`, SSH(22) source = **My IP** | only you can reach it |

Launch, then wait on **EC2 → Instances** until **Running** + **2/2 checks passed**. Copy the
**Public IPv4 address** — call it `<IP>` from here on.

> **Firewall note:** we open app ports (3000, 9090, …) *per project* as we reach them. Keeping the
> source = **My IP** matters — these dashboards have weak default auth and must not face the whole internet.

### 0.2 Connect over SSH

**Windows (PowerShell):** first lock down the key file's permissions (OpenSSH refuses world-readable keys):
```powershell
icacls "$env:USERPROFILE\Downloads\monitoring-capstone.pem" /inheritance:r
icacls "$env:USERPROFILE\Downloads\monitoring-capstone.pem" /grant:r "$($env:USERNAME):(R)"
ssh -i "$env:USERPROFILE\Downloads\monitoring-capstone.pem" ubuntu@<IP>
```
**macOS/Linux:**
```bash
chmod 400 ~/Downloads/monitoring-capstone.pem
ssh -i ~/Downloads/monitoring-capstone.pem ubuntu@<IP>
```
Type `yes` at the fingerprint prompt. You're now on the server (prompt shows `ubuntu@ip-...`).

### 0.3 Install Docker + Compose

```bash
# Prereqs
sudo apt-get update
sudo apt-get install -y ca-certificates curl git

# Docker's official apt repo
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Engine + compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Use docker without sudo
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker version
docker compose version
```

### 0.4 One-time kernel setting for Elasticsearch (needed in 5.2)

Elasticsearch won't start unless the OS allows enough memory-map areas. Set it now (persists across reboots):
```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
sudo sysctl --system
sysctl vm.max_map_count      # must print 262144
```

### 0.5 Create the project tree

```bash
mkdir -p ~/monitoring && cd ~/monitoring
```
Each project below builds its own subfolder under `~/monitoring`. Let's go.

---

<a name="project-51"></a>
## Project 5.1 — Comprehensive Monitoring with Prometheus & Grafana

**Goal:** stand up a metrics pipeline — **Node Exporter** (and **cAdvisor**) expose metrics → **Prometheus**
scrapes & stores them → **Grafana** visualizes them.

```
Node Exporter (host metrics) ┐
cAdvisor (container metrics) ┼─▶ Prometheus (scrape + store, TSDB) ─▶ Grafana (dashboards)
Prometheus (self metrics)    ┘
```

**Open these ports** in `monitoring-sg` (Source = My IP): **3000, 9090, 9100, 8080**.

### Step 1 — Create the folder and files

```bash
mkdir -p ~/monitoring/5.1/prometheus/rules ~/monitoring/5.1/grafana/provisioning/datasources
cd ~/monitoring/5.1
```

**Prometheus config** — the heart of the stack. `scrape_interval` = how often to pull metrics;
each `job` is a set of targets Prometheus reaches over Docker's internal DNS (by service name).
```bash
cat > prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s          # how often to scrape targets
  evaluation_interval: 15s      # how often to evaluate rules
  external_labels:
    monitor: capstone-5-1

rule_files:
  - /etc/prometheus/rules/*.yml   # loads the alert rule below (stretch goal)

scrape_configs:
  - job_name: prometheus          # Prometheus scraping itself
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: node-exporter       # host CPU/mem/disk metrics
    static_configs:
      - targets: ["node-exporter:9100"]
        labels: { instance: capstone-host }

  - job_name: cadvisor            # per-container metrics (stretch goal)
    static_configs:
      - targets: ["cadvisor:8080"]
EOF
```

**Alert rule (stretch goal)** — fires when CPU stays above 80%. In 5.1 there's no Alertmanager yet, so it
just appears on Prometheus's `/alerts` page; 5.3 wires alerts to Slack.
```bash
cat > prometheus/rules/alerts.yml <<'EOF'
groups:
  - name: host-alerts
    rules:
      - alert: HighCpuUsage
        expr: 100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 2m
        labels: { severity: warning }
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU above 80% for 2m (now {{ printf \"%.1f\" $value }}%)."
EOF
```

**Grafana data source (Task 4, auto-provisioned)** — so you don't click through the UI to connect
Prometheus. The fixed `uid` lets dashboards reference it reliably.
```bash
cat > grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      timeInterval: 15s
EOF
```

**The stack itself** — `docker-compose.yml` defines every container, its image, ports, and volumes.
`node-exporter` mounts the host root read-only so it can read real host metrics; `cadvisor` needs a few
privileged mounts to read container stats.
```bash
cat > docker-compose.yml <<'EOF'
name: monitoring-5-1
services:
  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --web.enable-lifecycle
    volumes:
      - ./prometheus:/etc/prometheus:ro
      - prometheus_data:/prometheus
    ports: ["9090:9090"]

  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node-exporter
    restart: unless-stopped
    command: [ "--path.rootfs=/host" ]
    pid: host
    volumes: [ "/:/host:ro,rslave" ]
    ports: ["9100:9100"]

  cadvisor:                         # stretch goal: container metrics
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    devices: [ "/dev/kmsg" ]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports: ["8080:8080"]

  grafana:
    image: grafana/grafana:11.2.0
    container_name: grafana
    restart: unless-stopped
    depends_on: [prometheus]
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: change_me_admin   # change this!
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana_data:/var/lib/grafana
    ports: ["3000:3000"]

volumes:
  prometheus_data:
  grafana_data:
EOF
```

### Step 2 — Bring it up (Tasks 1–2)

```bash
docker compose up -d
docker compose ps        # wait until all are "running"
```

### Step 3 — Verify targets (Task 3)

Browser → **`http://<IP>:9090/targets`**. You should see `prometheus`, `node-exporter`, and `cadvisor`
all **UP**. (If cAdvisor is DOWN, give it ~30s.)
📸 **Deliverable:** screenshot this page with everything **UP**.

Try a query: **`http://<IP>:9090/graph`** → run `node_memory_MemAvailable_bytes` → **Execute**.

### Step 4 — Grafana data source (Task 4)

Browser → **`http://<IP>:3000`** → log in (`admin` / the password you set).
Go to **Connections → Data sources → Prometheus** — it's already there (provisioned). Click
**Save & test** → "Data source is working."
📸 **Deliverable:** screenshot the working data source page.

### Step 5 — Build a dashboard + import a community one (Task 5)

**Import the famous community dashboard (ID 1860, "Node Exporter Full"):**
Grafana → **Dashboards → New → Import** → enter **1860** → **Load** → pick **Prometheus** as the data
source → **Import**. You now have dozens of host panels.

**Build your own CPU/Memory dashboard:**
1. **Dashboards → New → New dashboard → Add visualization** → select **Prometheus**.
2. In the query box paste this **CPU busy %** expression, set unit to *Percent (0–100)*, title "CPU Usage %":
   ```
   100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
   ```
3. **Add → Visualization** again for **Memory used %**:
   ```
   (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
   ```
4. Add one more for **Disk I/O** (unit *bytes/sec*):
   ```
   irate(node_disk_read_bytes_total[5m])
   irate(node_disk_written_bytes_total[5m])
   ```
5. **Save** the dashboard (name it "Host Metrics").
📸 **Deliverable:** screenshot your custom dashboard showing CPU + Memory.

### Step 6 — Explore PromQL (Task 6) + stretch goals

- **PromQL practice** in Grafana Explore or `:9090/graph`: `rate(container_cpu_usage_seconds_total[5m])`
  (from cAdvisor), `topk(3, ...)`, etc.
- **Stretch – dashboard variable (`$host`):** dashboard **Settings → Variables → New variable** →
  type *Query*, name `host`, query `label_values(node_cpu_seconds_total, instance)`. Then edit each panel's
  query to add `{instance=~"$host"}`. A dropdown appears top-left to switch hosts.
  📸 optional deliverable.
- **Stretch – alert rule:** already loaded; see it at **`http://<IP>:9090/alerts`** (**HighCpuUsage**).
  📸 optional deliverable.
- **Stretch – cAdvisor:** already scraped; its targets are UP and container metrics appear under
  `container_*` names.

### Step 7 — Tear down before the next project
```bash
docker compose down -v
```

---

<a name="project-52"></a>
## Project 5.2 — Centralized Logging with the ELK Stack

**Goal:** ship logs from a file → parse them → store & search them.
```
log-generator (writes app.log) ─▶ Filebeat (ship) ─▶ Logstash (grok parse) ─▶ Elasticsearch (store/index) ─▶ Kibana (search/visualize)
```

**Open ports** in `monitoring-sg`: **5601 (Kibana), 9200 (Elasticsearch)**.
(Make sure you did the `vm.max_map_count` step in Phase 0.4 — ELK won't start otherwise.)

### Step 1 — Files

```bash
mkdir -p ~/monitoring/5.2/logstash/pipeline ~/monitoring/5.2/filebeat ~/monitoring/5.2/log-generator ~/monitoring/5.2/logs
cd ~/monitoring/5.2
```

**Log generator (Task: produce sample logs)** — a tiny Python loop writing structured app logs with mixed
levels, so we have realistic data to parse.
```bash
cat > log-generator/generate.py <<'EOF'
import time, random, datetime, os

LEVELS   = ["INFO","INFO","INFO","DEBUG","WARN","ERROR"]   # weighted toward INFO
SERVICES = ["orders","payments","auth","catalog"]
MESSAGES = [
    "request completed", "user logged in", "payment authorized",
    "cache miss", "db timeout", "invalid token", "order shipped",
    "retrying upstream", "rate limit hit", "record not found",
]
os.makedirs("/logs", exist_ok=True)
path = "/logs/app.log"
print("log-generator writing to", path, flush=True)
while True:
    ts  = datetime.datetime.utcnow().isoformat() + "Z"
    lvl = random.choice(LEVELS)
    svc = random.choice(SERVICES)
    msg = random.choice(MESSAGES)
    line = f"{ts} {lvl} {svc} - {msg}\n"
    with open(path, "a") as f:
        f.write(line)
    time.sleep(random.uniform(0.3, 1.5))
EOF
```

**Filebeat config** — tails the log file and forwards each line to Logstash on port 5044.
```bash
cat > filebeat/filebeat.yml <<'EOF'
filebeat.inputs:
  - type: filestream
    id: app-logs
    paths:
      - /logs/app.log

output.logstash:
  hosts: ["logstash:5044"]

logging.level: info
EOF
```

**Logstash pipeline** — the parsing brain. `grok` turns the raw line into fields; `date` promotes the log's
own timestamp to `@timestamp`; `mutate` cleans up. This is the file you screenshot for the deliverable.
```bash
cat > logstash/pipeline/logstash.conf <<'EOF'
input {
  beats { port => 5044 }
}

filter {
  # Parse: "2026-08-22T12:00:00.000Z INFO orders - request completed"
  grok {
    match => { "message" => "%{TIMESTAMP_ISO8601:log_timestamp} %{LOGLEVEL:log_level} %{DATA:service} - %{GREEDYDATA:log_message}" }
  }
  # Use the log's own time as the event time (stretch: date filter)
  date {
    match  => [ "log_timestamp", "ISO8601" ]
    target => "@timestamp"
  }
  # Tidy up (stretch: mutate filter)
  mutate {
    uppercase    => [ "log_level" ]
    remove_field => [ "log_timestamp" ]
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "app-logs-%{+YYYY.MM.dd}"
  }
  stdout { codec => rubydebug }   # also print to logstash logs so you can watch parsing
}
EOF
```

**The stack** — ES single-node with security **off** (keeps the core simple; we enable auth as a stretch
goal below). Heaps are capped so it fits an 8 GB box.
```bash
cat > docker-compose.yml <<'EOF'
name: logging-5-2
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.3
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
      - bootstrap.memory_lock=true
    ulimits:
      memlock: { soft: -1, hard: -1 }
    volumes:
      - es_data:/usr/share/elasticsearch/data
    ports: ["9200:9200"]
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://localhost:9200/_cluster/health || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10

  logstash:
    image: docker.elastic.co/logstash/logstash:8.15.3
    container_name: logstash
    environment:
      - LS_JAVA_OPTS=-Xms512m -Xmx512m
      - xpack.monitoring.enabled=false
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline:ro
    ports: ["5044:5044"]
    depends_on:
      elasticsearch: { condition: service_healthy }

  kibana:
    image: docker.elastic.co/kibana/kibana:8.15.3
    container_name: kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    ports: ["5601:5601"]
    depends_on:
      elasticsearch: { condition: service_healthy }

  filebeat:
    image: docker.elastic.co/beats/filebeat:8.15.3
    container_name: filebeat
    user: root
    command: ["filebeat", "-e", "--strict.perms=false"]
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - ./logs:/logs:ro
    depends_on: [logstash]

  log-generator:
    image: python:3.12-slim
    container_name: log-generator
    command: ["python", "/app/generate.py"]
    volumes:
      - ./log-generator:/app:ro
      - ./logs:/logs
    restart: unless-stopped

volumes:
  es_data:
EOF
```

### Step 2 — Bring it up (Tasks 1–4)
```bash
docker compose up -d
docker compose ps
# Watch Logstash actually parse lines (you'll see rubydebug output with log_level, service, ...):
docker compose logs -f logstash
```
ES takes ~1 min to go healthy the first time. Confirm data is landing:
```bash
curl -s "http://localhost:9200/_cat/indices/app-logs-*?v"      # should show a growing doc count
```

### Step 3 — Explore in Kibana (Task 5)

Browser → **`http://<IP>:5601`**.
1. **Menu → Stack Management → Data Views → Create data view.**
2. Name: `app-logs`, index pattern: `app-logs-*`, timestamp field: `@timestamp` → **Save**.
3. **Menu → Discover.** Pick the `app-logs` data view. You'll see parsed events; expand one to see
   `log_level`, `service`, `log_message` fields. Filter with the search bar, e.g. `log_level : "ERROR"`.
📸 **Deliverable:** Discover showing parsed, indexed events.
📸 **Deliverable:** the `logstash.conf` open in an editor (input / filter / output visible) —
   `nano logstash/pipeline/logstash.conf` or view it locally.

### Step 4 — Visualizations (Task 6)

**Menu → Dashboard → Create dashboard → Create visualization** (Lens):
- **Bar chart of log levels:** X-axis = **Top values of `log_level.keyword`**, Y-axis = **Count**.
- **Log frequency over time:** X-axis = **`@timestamp` (date histogram)**, Y-axis = **Count**.
Save both to a dashboard.
📸 **Deliverable:** a Kibana dashboard with at least one visualization.

### Stretch goals
- **Custom grok:** the pipeline already uses a custom grok pattern — tweak `MESSAGES`/format and adjust the
  grok to prove you can parse a new shape. Test patterns at Kibana → **Dev Tools** or the Grok Debugger.
- **`mutate`/`date` enrich:** already in the pipeline (`uppercase`, `@timestamp` from the log line).
- **Basic auth (secure the stack):** flip `xpack.security.enabled=true` in the compose, set
  `ELASTIC_PASSWORD`, and point Kibana/Logstash/Filebeat at those credentials. Then `curl -u elastic:...`
  is required to hit `:9200`. (Details in the repo's `project-5.2-elk/README.md`; do this last since it
  touches every service's config.)

### Tear down
```bash
docker compose down -v
```

---

<a name="project-53"></a>
## Project 5.3 — Advanced Monitoring, Alerting & Distributed Tracing

**Goal:** add **recording rules** (pre-computed queries), **alerting rules** → **Alertmanager** → **Slack**,
and **Jaeger** distributed tracing with a demo app.
```
node-exporter, flaky-app ─▶ Prometheus ─(rules)─▶ Alertmanager ─▶ Slack
HotROD demo app ───────────(traces)──────────────▶ Jaeger UI
```

**Open ports:** **9090 (Prometheus), 9093 (Alertmanager), 16686 (Jaeger), 8080 (HotROD)**.

### Step 1 — Files
```bash
mkdir -p ~/monitoring/5.3/prometheus/rules ~/monitoring/5.3/alertmanager ~/monitoring/5.3/flaky-app
cd ~/monitoring/5.3
```

**A "flaky" demo app** — exposes Prometheus metrics and deliberately errors ~20% of the time, so the
`HighErrorRate` alert has something real to fire on.
```bash
cat > flaky-app/app.py <<'EOF'
import random, threading, time
from prometheus_client import start_http_server, Counter

REQS = Counter("app_requests_total", "App requests", ["status"])

def traffic():
    while True:
        status = "500" if random.random() < 0.2 else "200"   # ~20% errors
        REQS.labels(status=status).inc()
        time.sleep(0.2)

if __name__ == "__main__":
    start_http_server(8000)              # /metrics on :8000
    threading.Thread(target=traffic, daemon=True).start()
    print("flaky-app metrics on :8000", flush=True)
    while True:
        time.sleep(60)
EOF
```

**Recording rules** — pre-compute expensive/re-used expressions so dashboards & alerts read a ready value.
```bash
cat > prometheus/rules/recording.yml <<'EOF'
groups:
  - name: recordings
    interval: 30s
    rules:
      - record: instance:node_cpu:busy_pct
        expr: 100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
      - record: app:request_error_ratio
        expr: sum(rate(app_requests_total{status="500"}[5m])) / sum(rate(app_requests_total[5m]))
EOF
```

**Alerting rules** — `InstanceDown` fires when any target disappears; `HighErrorRate` fires on the flaky app.
```bash
cat > prometheus/rules/alerts.yml <<'EOF'
groups:
  - name: alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Target {{ $labels.instance }} is down"
          description: "{{ $labels.job }} / {{ $labels.instance }} unreachable for >1m."

      - alert: HighErrorRate
        expr: app:request_error_ratio > 0.1
        for: 2m
        labels: { severity: warning }
        annotations:
          summary: "High error rate on demo app"
          description: "5xx ratio is {{ printf \"%.0f\" (mul $value 100) }}% (>10%)."
EOF
```

**Prometheus config** — now points at Alertmanager and scrapes the new targets (incl. Jaeger's own metrics,
a stretch goal).
```bash
cat > prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: prometheus
    static_configs: [ { targets: ["localhost:9090"] } ]
  - job_name: node-exporter
    static_configs: [ { targets: ["node-exporter:9100"] } ]
  - job_name: flaky-app
    static_configs: [ { targets: ["flaky-app:8000"] } ]
  - job_name: jaeger            # stretch: monitor the tracing system itself
    static_configs: [ { targets: ["jaeger:14269"] } ]
EOF
```

**Alertmanager config** — routes alerts to Slack and includes an **inhibition rule** (stretch): while a
`critical` alert fires, matching `warning` alerts are suppressed.
> Replace the `api_url` with your Slack **Incoming Webhook** URL (Slack → Apps → Incoming Webhooks →
> Add to a channel → copy the URL). No Slack? Leave it; alerts still show in the Alertmanager UI.
```bash
cat > alertmanager/alertmanager.yml <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: slack-notifications
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 3h

receivers:
  - name: slack-notifications
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/REPLACE/WITH/YOURS'
        channel: '#alerts'
        send_resolved: true
        title: '{{ .CommonAnnotations.summary }}'
        text: "{{ range .Alerts }}*{{ .Labels.alertname }}* ({{ .Labels.severity }})\n{{ .Annotations.description }}\n{{ end }}"

inhibit_rules:
  - source_matchers: [ 'severity="critical"' ]
    target_matchers: [ 'severity="warning"' ]
    equal: ['instance']
EOF
```

**The stack** — Prometheus, Alertmanager, node-exporter, the flaky app (installs its one dependency at
start, no image build needed), Jaeger all-in-one, and the HotROD demo that generates traces.
```bash
cat > docker-compose.yml <<'EOF'
name: advanced-5-3
services:
  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.enable-lifecycle
    volumes:
      - ./prometheus:/etc/prometheus:ro
    ports: ["9090:9090"]

  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: alertmanager
    restart: unless-stopped
    command: [ "--config.file=/etc/alertmanager/alertmanager.yml" ]
    volumes:
      - ./alertmanager:/etc/alertmanager:ro
    ports: ["9093:9093"]

  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node-exporter
    restart: unless-stopped
    command: [ "--path.rootfs=/host" ]
    pid: host
    volumes: [ "/:/host:ro,rslave" ]

  flaky-app:
    image: python:3.12-slim
    container_name: flaky-app
    command: ["sh", "-c", "pip install --quiet prometheus_client && python /app/app.py"]
    volumes: [ "./flaky-app:/app:ro" ]
    restart: unless-stopped

  jaeger:
    image: jaegertracing/all-in-one:1.60
    container_name: jaeger
    restart: unless-stopped
    environment:
      - COLLECTOR_OTLP_ENABLED=true
    ports:
      - "16686:16686"     # Jaeger UI
      - "4317:4317"       # OTLP gRPC
      - "4318:4318"       # OTLP HTTP

  hotrod:
    image: jaegertracing/example-hotrod:1.60
    container_name: hotrod
    restart: unless-stopped
    command: ["all"]
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318
    ports: ["8080:8080"]
    depends_on: [jaeger]
EOF
```

### Step 2 — Bring it up (Tasks 1–4)
```bash
docker compose up -d
docker compose ps
```

### Step 3 — Verify rules (Tasks 1–2)
Browser → **`http://<IP>:9090/rules`** — you'll see the **recordings** and **alerts** groups.
Then **`http://<IP>:9090/alerts`** — `HighErrorRate` should move to **PENDING → FIRING** within ~2–3 min
(the flaky app runs at ~20% errors).
📸 **Deliverable:** the `/rules` page showing recording + alerting rules.

### Step 4 — Alert reaches Slack (Task 3)
With a real webhook in `alertmanager.yml`, watch your `#alerts` channel — the firing `HighErrorRate` alert
arrives. Also see it grouped in the Alertmanager UI at **`http://<IP>:9093`**.
📸 **Deliverable:** the Slack message (or Alertmanager UI if you skipped Slack).
> To also demo **`InstanceDown`**: `docker compose stop node-exporter` — within ~1 min the critical alert
> fires (and, via the inhibition rule, warnings for that instance are suppressed). `docker compose start
> node-exporter` to recover.

### Step 5 — Generate & analyze traces (Tasks 4–6)
1. Browser → **`http://<IP>:8080`** (HotROD). Click the customer buttons a few times — each click sends a
   request through several simulated microservices and emits a trace.
2. Browser → **`http://<IP>:16686`** (Jaeger UI). Service = **frontend** → **Find Traces**. Open one.
3. You'll see the trace broken into **spans** across services (frontend → route → driver → …), with timing.
   Find the slowest span — that's the latency bottleneck.
📸 **Deliverable:** a Jaeger trace expanded into multiple spans.

### Stretch goals
- **Jaeger self-monitoring:** already scraped (`jaeger` job at `:14269`) — check it's **UP** on `/targets`.
- **Inhibition rule:** already configured (critical suppresses warning on the same `instance`). Demo it with
  the `InstanceDown` trick above.
- **Custom spans/tags:** HotROD emits rich spans out of the box; explore span **Tags/Logs** in the trace
  detail to see attributes like SQL queries and driver IDs.

### Tear down
```bash
docker compose down -v
```

---

<a name="project-54"></a>
## Project 5.4 — Scaling Monitoring Infrastructure (Thanos)

**Goal:** make monitoring **global, durable, and highly available**. Two regional ("leaf") Prometheus
instances each get a **Thanos sidecar** that uploads their data to **MinIO** (S3-compatible object storage).
**Thanos Query** fans out across sidecars + the historical store to give Grafana one global view — and the
data survives even if a leaf dies.
```
Prometheus us-east ─ sidecar ┐
Prometheus eu-west ─ sidecar ┼─▶ MinIO (object store) ◀─ Thanos Store ─┐
                              └────────────────────────────────────────┼─▶ Thanos Query ─▶ Grafana
                                                       Thanos Compact ──┘
```

**Open ports:** **3000 (Grafana), 10902 (Thanos Query), 9001 (MinIO console)**.

### Step 1 — Files
```bash
mkdir -p ~/monitoring/5.4/prometheus-us ~/monitoring/5.4/prometheus-eu ~/monitoring/5.4/prometheus-fed \
         ~/monitoring/5.4/thanos ~/monitoring/5.4/grafana/provisioning/datasources
cd ~/monitoring/5.4
```

**Two leaf Prometheus configs** — identical except `external_labels`, which stamp every series with its
origin (`region`). The `replica` label lets Thanos de-duplicate HA pairs later.
```bash
cat > prometheus-us/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  external_labels: { region: us-east, replica: A }
scrape_configs:
  - job_name: prometheus
    static_configs: [ { targets: ["localhost:9090"] } ]
  - job_name: node
    static_configs: [ { targets: ["node-us:9100"] } ]
EOF

cat > prometheus-eu/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  external_labels: { region: eu-west, replica: A }
scrape_configs:
  - job_name: prometheus
    static_configs: [ { targets: ["localhost:9090"] } ]
  - job_name: node
    static_configs: [ { targets: ["node-eu:9100"] } ]
EOF
```

**Federation master (demonstrates the other scaling technique)** — one Prometheus that scrapes a summarized
slice of the leaves via their `/federate` endpoint.
```bash
cat > prometheus-fed/prometheus.yml <<'EOF'
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: federate
    honor_labels: true
    metrics_path: /federate
    params:
      'match[]': [ '{job=~".+"}' ]
    static_configs:
      - targets: [ "prometheus-us:9090", "prometheus-eu:9090" ]
EOF
```

**Thanos object-store config** — tells every Thanos component how to reach the MinIO bucket.
```bash
cat > thanos/objstore.yml <<'EOF'
type: S3
config:
  bucket: thanos
  endpoint: minio:9000
  access_key: minioadmin
  secret_key: change_me_minio      # must match MINIO_ROOT_PASSWORD below
  insecure: true                   # plain HTTP inside the Docker network
EOF
```

**Grafana data source → Thanos Query** (not a single Prometheus — that's the whole point).
```bash
cat > grafana/provisioning/datasources/thanos.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Thanos
    uid: thanos
    type: prometheus
    access: proxy
    url: http://thanos-query:10902
    isDefault: true
EOF
```

**The stack.** Key details: each leaf Prometheus runs with fixed 2h blocks and **no local compaction**
(`--storage.tsdb.max-block-duration=2h` etc.) so its **sidecar** can upload blocks; sidecars share each
Prometheus's data volume; `minio-init` creates the bucket once.
```bash
cat > docker-compose.yml <<'EOF'
name: scaling-5-4
x-prom-cmd: &prom-cmd
  - --config.file=/etc/prometheus/prometheus.yml
  - --storage.tsdb.path=/prometheus
  - --storage.tsdb.min-block-duration=2h
  - --storage.tsdb.max-block-duration=2h
  - --web.enable-lifecycle

services:
  minio:
    image: minio/minio:RELEASE.2024-09-13T20-26-02Z
    container_name: minio
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: change_me_minio
    volumes: [ "minio_data:/data" ]
    ports: ["9000:9000", "9001:9001"]

  minio-init:                       # creates the "thanos" bucket, then exits
    image: minio/mc:RELEASE.2024-09-16T17-43-14Z
    depends_on: [minio]
    entrypoint: >
      /bin/sh -c "
      until mc alias set m http://minio:9000 minioadmin change_me_minio; do sleep 2; done;
      mc mb --ignore-existing m/thanos;
      echo bucket-ready; "

  node-us:
    image: prom/node-exporter:v1.8.2
    command: [ "--path.rootfs=/host" ]
    pid: host
    volumes: [ "/:/host:ro,rslave" ]

  node-eu:
    image: prom/node-exporter:v1.8.2
    command: [ "--path.rootfs=/host" ]
    pid: host
    volumes: [ "/:/host:ro,rslave" ]

  prometheus-us:
    image: prom/prometheus:v2.54.1
    container_name: prometheus-us
    command: *prom-cmd
    volumes:
      - ./prometheus-us:/etc/prometheus:ro
      - prom_us_data:/prometheus

  prometheus-eu:
    image: prom/prometheus:v2.54.1
    container_name: prometheus-eu
    command: *prom-cmd
    volumes:
      - ./prometheus-eu:/etc/prometheus:ro
      - prom_eu_data:/prometheus

  prometheus-fed:                   # federation demo (not part of the Thanos path)
    image: prom/prometheus:v2.54.1
    container_name: prometheus-fed
    command: [ "--config.file=/etc/prometheus/prometheus.yml" ]
    volumes: [ "./prometheus-fed:/etc/prometheus:ro" ]
    ports: ["9091:9090"]

  thanos-sidecar-us:
    image: thanosio/thanos:v0.36.1
    container_name: thanos-sidecar-us
    command:
      - sidecar
      - --tsdb.path=/prometheus
      - --prometheus.url=http://prometheus-us:9090
      - --objstore.config-file=/etc/thanos/objstore.yml
      - --grpc-address=0.0.0.0:10901
      - --http-address=0.0.0.0:10902
    volumes:
      - prom_us_data:/prometheus
      - ./thanos:/etc/thanos:ro
    depends_on: [prometheus-us, minio-init]

  thanos-sidecar-eu:
    image: thanosio/thanos:v0.36.1
    container_name: thanos-sidecar-eu
    command:
      - sidecar
      - --tsdb.path=/prometheus
      - --prometheus.url=http://prometheus-eu:9090
      - --objstore.config-file=/etc/thanos/objstore.yml
      - --grpc-address=0.0.0.0:10901
      - --http-address=0.0.0.0:10902
    volumes:
      - prom_eu_data:/prometheus
      - ./thanos:/etc/thanos:ro
    depends_on: [prometheus-eu, minio-init]

  thanos-store:                     # serves historical blocks from the object store
    image: thanosio/thanos:v0.36.1
    container_name: thanos-store
    command:
      - store
      - --objstore.config-file=/etc/thanos/objstore.yml
      - --grpc-address=0.0.0.0:10901
      - --http-address=0.0.0.0:10902
      - --data-dir=/var/thanos/store
    volumes: [ "./thanos:/etc/thanos:ro" ]
    depends_on: [minio-init]

  thanos-compact:                   # compaction + downsampling (stretch)
    image: thanosio/thanos:v0.36.1
    container_name: thanos-compact
    command:
      - compact
      - --objstore.config-file=/etc/thanos/objstore.yml
      - --http-address=0.0.0.0:10902
      - --data-dir=/var/thanos/compact
      - --wait
    volumes: [ "./thanos:/etc/thanos:ro" ]
    depends_on: [minio-init]

  thanos-query:                     # the global fan-out endpoint Grafana talks to
    image: thanosio/thanos:v0.36.1
    container_name: thanos-query
    command:
      - query
      - --http-address=0.0.0.0:10902
      - --query.replica-label=replica
      - --endpoint=thanos-sidecar-us:10901
      - --endpoint=thanos-sidecar-eu:10901
      - --endpoint=thanos-store:10901
    ports: ["10902:10902"]
    depends_on: [thanos-sidecar-us, thanos-sidecar-eu, thanos-store]

  grafana:
    image: grafana/grafana:11.2.0
    container_name: grafana
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: change_me_admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana_data:/var/lib/grafana
    ports: ["3000:3000"]
    depends_on: [thanos-query]

volumes:
  minio_data:
  prom_us_data:
  prom_eu_data:
  grafana_data:
EOF
```

### Step 2 — Bring it up (Tasks 1–4)
```bash
docker compose up -d
docker compose ps
```
Give it a couple of minutes: the leaves must scrape, and sidecars upload the first 2h block only after a
block is cut (recent data is served live from the sidecars immediately, historical from the store later).

### Step 3 — Verify the global view (Tasks 4–5)
Browser → **`http://<IP>:10902`** (Thanos Query) → **Stores** page: you should see both **sidecars**, the
**store**, and their health.
📸 **Deliverable:** the Thanos **Stores** page, all components connected & healthy.

On the Thanos Query **Graph** tab, run: `count by (region) (up)` — you'll get **two** results, `us-east`
and `eu-west`, proving one endpoint queries both leaves.

### Step 4 — Grafana over Thanos (Task 5)
Browser → **`http://<IP>:3000`** → the **Thanos** data source is pre-provisioned. Build a panel with
`node_load1` or `up` and **Group by `region`** — one dashboard shows both regions' data through a single
endpoint.
📸 **Deliverable:** a Grafana panel showing series from **both** `us-east` and `eu-west`.

### Step 5 — Durability test (Task 6)
```bash
docker compose stop prometheus-eu thanos-sidecar-eu     # simulate a region going down
```
Wait, then re-run your Thanos query. **Recent** eu-west data goes stale, but any block already uploaded to
MinIO is still served by **thanos-store** — the historical data survives the outage. That's the durability
win. Restart with `docker compose start prometheus-eu thanos-sidecar-eu`.

### Deliverables recap
📸 Thanos Stores page · 📸 Grafana panel spanning two regions · 📸 the architecture diagram above.

### Stretch goals
- **Downsampling:** `thanos-compact` already runs with `--wait`; it creates 5m/1h downsampled series for
  older data automatically (watch `docker compose logs thanos-compact`).
- **Multi-tenancy via relabeling:** the `region` external label already partitions tenants; extend with a
  `tenant` label and Thanos Query's `--selector-label` to enforce isolation.
- **HA Grafana:** run two `grafana` replicas backed by a shared **Postgres** (`GF_DATABASE_TYPE=postgres`,
  `GF_DATABASE_HOST=postgres:5432`, …) so dashboards survive a Grafana restart and load-balance. (Add a
  `postgres:16` service; see the repo's `project-5.4-scaling/README.md`.)

### Tear down
```bash
docker compose down -v
```

---

<a name="troubleshooting"></a>
## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Can't open a UI in the browser | The port isn't open in the security group, or you used a private IP. Open the port (Source = My IP) and use the **Public IPv4**. |
| A target is **DOWN** in Prometheus | `docker compose logs <service>`; check the service name/port in `prometheus.yml` matches the compose service. |
| Elasticsearch container exits immediately | You skipped **Phase 0.4** (`vm.max_map_count=262144`), or the box is out of RAM. Check `docker compose logs elasticsearch` and `free -h`. |
| Everything is slow / containers keep restarting | Out of memory. Run one project at a time; `docker compose down -v` the previous one; consider t3.xlarge. |
| Kibana "server not ready" | Give ES ~1 min to go healthy first; `curl localhost:9200/_cluster/health`. |
| Thanos Query shows no stores | Sidecars need `--grpc-address`; confirm `minio-init` printed `bucket-ready` (`docker compose logs minio-init`). |
| Slack alert never arrives | Real webhook pasted in `alertmanager.yml`? Check `docker compose logs alertmanager` and the Alertmanager UI at `:9093`. |
| Reclaim disk between projects | `docker system prune -af --volumes` (only when no stack you care about is running). |

---

<a name="teardown"></a>
## Teardown & cost control

- **Between projects:** `docker compose down -v` frees RAM and the named volumes.
- **Pausing for the day:** EC2 Console → select instance → **Instance state → Stop**. Stopped instances
  bill only for the 30 GB EBS volume, not compute.
- **All done:** **Instance state → Terminate** to delete the instance, and delete the EBS volume + security
  group if you won't reuse them.

You've now built the full observability stack: metrics (5.1), logs (5.2), alerting + tracing (5.3), and a
scalable, durable, global setup (5.4). Capture the screenshots in each project's "Deliverable" callouts —
that's your capstone submission.
