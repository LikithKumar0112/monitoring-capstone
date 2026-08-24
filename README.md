# Monitoring Capstone — Section 5

Four progressive, Docker-based projects that build a production-style observability stack from the
ground up. Each project lives in its own folder, is self-contained, and is brought up with a single
`docker compose up -d`. They are designed to be run **one at a time** on a single AWS EC2 instance.

| # | Project | Stack | You'll produce |
|---|---------|-------|----------------|
| **5.1** | Comprehensive Monitoring | Prometheus · Grafana · Node Exporter · cAdvisor | Live metrics + custom dashboards |
| **5.2** | Centralized Logging | Elasticsearch · Logstash · Kibana · Filebeat | Searchable, parsed logs + visualizations |
| **5.3** | Advanced Monitoring | Prometheus rules · Alertmanager · Jaeger | Alerts to Slack + distributed traces |
| **5.4** | Scaling | Federation · Thanos · MinIO · Grafana | Durable, global, HA monitoring |

Each project maps 1:1 to the manual: **Overview → Tools → Architecture → Workflow → 6 Tasks →
Expected Outcome → Deliverables**, and each includes the manual's **"Beyond the Basics"** stretch goals.

## Quick start (on AWS EC2)

1. **Provision the instance and install Docker** — follow **[docs/AWS-SETUP.md](docs/AWS-SETUP.md)**.
2. Clone this repo onto the instance and pick a project:
   ```bash
   cd project-5.1-prometheus-grafana
   cp ../.env.example .env      # edit passwords/webhooks
   docker compose up -d
   docker compose ps            # wait until healthy
   ```
3. Open the UIs in your browser (use the EC2 **public IP**, ports listed in each project's README).
4. Capture the screenshots listed in **[docs/DELIVERABLES.md](docs/DELIVERABLES.md)**.
5. Tear the stack down before starting the next project (frees RAM):
   ```bash
   docker compose down -v
   ```

## Why one at a time?

The full set (especially ELK in 5.2 and the multi-Prometheus + Thanos setup in 5.4) is memory hungry.
Running a single stack keeps you comfortably inside an 8–16 GB instance. See
[docs/AWS-SETUP.md](docs/AWS-SETUP.md) for sizing.

## Repo layout

```
monitoring/
├── README.md                     ← you are here
├── .env.example                  ← copy to .env in each project folder
├── docs/
│   ├── AWS-SETUP.md              ← EC2 provisioning + Docker install + firewall
│   └── DELIVERABLES.md           ← exact screenshot checklist for all 4 projects
├── project-5.1-prometheus-grafana/
├── project-5.2-elk/
├── project-5.3-advanced/
└── project-5.4-scaling/
```

Start with **5.1** — projects 5.3 and 5.4 build on the Prometheus foundation you learn there.
