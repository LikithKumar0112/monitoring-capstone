# Deliverables — Screenshot Checklist

The manual grades each project on a small set of **screenshots**. This is the exact list, in the order
it's easiest to capture. Each project's own README repeats its slice with the precise URLs. Use the EC2
**public IP** in every URL.

---

## Project 5.1 — Comprehensive Monitoring

**Required (manual):**
- [ ] **Prometheus Targets UP** — `http://<IP>:9090/targets` showing every target in state **UP**.
- [ ] **Grafana data source** — Grafana → *Connections → Data sources → Prometheus*, page showing
      "Data source is working".
- [ ] **Custom dashboard** — a Grafana dashboard visualizing **CPU and Memory** metrics.

**Stretch (Beyond the Basics):**
- [ ] cAdvisor targets UP on the Prometheus Targets page (container metrics).
- [ ] Alerts page `http://<IP>:9090/alerts` showing the **HighCpuUsage** rule loaded.
- [ ] The dashboard's **`$host` variable** dropdown (top-left of the dashboard) switching instances.

---

## Project 5.2 — Centralized Logging (ELK)

**Required:**
- [ ] **Kibana Discover** — parsed, indexed log events with fields (`log_level`, `message`, …) expanded.
- [ ] **Logstash pipeline config** — the `logstash.conf` open in an editor showing `input`, `filter`
      (grok), and `output` sections.
- [ ] **Kibana dashboard** — at least one visualization (e.g., log events over time).

**Stretch:**
- [ ] A custom **grok** pattern parsing the app log format (visible in `logstash.conf`).
- [ ] Elasticsearch **basic auth** working (Kibana login screen / `curl -u` against `:9200`).
- [ ] A **mutate/date** filter result (e.g., `@timestamp` derived from the log line).

---

## Project 5.3 — Advanced Monitoring, Alerting & Tracing

**Required:**
- [ ] **Prometheus Rules** — `http://<IP>:9090/rules` showing both **recording** and **alerting** rules.
- [ ] **Alert notification** — the alert delivered to your configured channel (Slack message screenshot).
- [ ] **Jaeger trace** — `http://<IP>:16686` showing one trace expanded into **multiple spans**.

**Stretch:**
- [ ] Jaeger's own metrics scraped by Prometheus (a `jaeger` job UP on the Targets page).
- [ ] Alertmanager **inhibition** in action (low-severity alert suppressed while high-severity fires).
- [ ] A **custom span/tag** you added, visible in the Jaeger trace detail.

---

## Project 5.4 — Scaling Monitoring Infrastructure

**Required:**
- [ ] **Thanos Query UI** — `http://<IP>:10902` → *Stores* page showing all components connected & healthy.
- [ ] **Cross-instance dashboard** — a Grafana panel (via Thanos) showing data that originates from **two
      different leaf Prometheus** instances (e.g., `region="us-east"` and `region="eu-west"`).
- [ ] **Architecture diagram** — the final scaled architecture you built (the README's diagram is fine).

**Stretch:**
- [ ] Thanos **downsampling** active (thanos-compact logs / older data resolution).
- [ ] Multi-tenancy via **relabeling** (external labels / tenant labels on series).
- [ ] **HA Grafana** — two Grafana replicas backed by the shared Postgres DB.

---

### Tips for clean screenshots
- Full browser window, URL bar visible (proves which host/port).
- For terminal/config screenshots, show the filename in the editor title bar.
- Capture **after** `docker compose ps` reports everything healthy, so panels have data.
