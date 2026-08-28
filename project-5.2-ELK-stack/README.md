# Project 5.2 — Centralized Logging with the ELK Stack

Elasticsearch + Logstash + Kibana + Filebeat, with a small Python log generator.

```
log-generator ──writes──▶ /logs/app.log ──Filebeat tails──▶ Logstash (grok + date)
                                                                   │
                                                                   ▼
                                            Elasticsearch app-logs-YYYY.MM.dd ──▶ Kibana :5601
```

## Folder layout

```
project-5.2-ELK-stack/
├── docker-compose.yml                 # elasticsearch, logstash, kibana, filebeat, log-generator
├── logstash/pipeline/logstash.conf    # grok → date → output to app-logs-*
├── filebeat/filebeat.yml              # tails /logs/app.log → logstash:5044
└── log-generator/                     # generate.py + Dockerfile
```

## Run

```bash
docker compose up -d --build
docker compose ps            # wait until elasticsearch/logstash/kibana are healthy
# Kibana http://EC2_IP:5601   ·   Elasticsearch http://EC2_IP:9200
```

**First-time Kibana setup:** Stack Management → Data Views → create `app-logs-*` with time field
`@timestamp`, then open **Discover**. Aggregations use `log_level.keyword` (see note below).

Quick checks:
```bash
curl -s localhost:9200/_cluster/health | jq .status        # green/yellow
curl -s 'localhost:9200/app-logs-*/_count' | jq .count     # > 0 after ~1 min
```

## Ports to open in the security group

`5601` Kibana · `9200` Elasticsearch. Keep the Logstash beats input `5044` **internal**.

## Deliverables

**ELK stack up (Elasticsearch healthy):**
![compose up](../screenshots/5.2-compose-up.png)

**Logstash pipeline — grok extracts fields, date sets `@timestamp`, output to `app-logs-*`:**
![logstash pipeline](../screenshots/5.2-logstash-pipeline.png)

**Kibana data view `app-logs-*` and parsed logs in Discover:**
![data view](../screenshots/5.2-kibana-dataview.png)
![discover](../screenshots/5.2-kibana-discover.png)

**Kibana dashboard — volume over time and counts by `log_level.keyword`:**
![dashboard](../screenshots/5.2-kibana-dashboard.png)

## Notes

- Pinned tags (Elastic stack `8.15.3`). Heaps capped and `mem_limit` set so a runaway JVM can't
  take the box down (ES 1g heap / 2g cap, Logstash 512m / 1g, Kibana 1g).
- **grok before date:** grok creates `log_timestamp`; the date filter then parses it into
  `@timestamp`. Reversed, `@timestamp` would wrongly stay the ingest time.
- **`log_level.keyword`:** terms aggregations need the exact keyword sub-field, not the analysed
  `text` field.
- Security (xpack) is off for the single-box demo; enabling it with real passwords is the stretch goal.
