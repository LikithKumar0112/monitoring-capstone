# Project 5.2 — Centralized Logging with the ELK Stack

Elasticsearch + Logstash + Kibana + Filebeat, with a small Python log generator.

```
log-generator ──writes──▶ /logs/app.log ──Filebeat tails──▶ Logstash (grok+date)
                                                                   │
                                                                   ▼
                                            Elasticsearch app-logs-YYYY.MM.dd ──▶ Kibana
```

## Run

```bash
docker compose up -d --build
docker compose ps            # wait until elasticsearch/logstash/kibana are "healthy"
```

- Kibana UI:        http://EC2_IP:5601
- Elasticsearch:    http://EC2_IP:9200
- Logstash beats input (5044) is internal only — not published.

## First-time Kibana setup

1. Kibana → **Stack Management → Data Views → Create data view**.
2. Name/index pattern: `app-logs-*`, time field: `@timestamp`.
3. Open **Discover** to see parsed logs (fields: `log_level`, `service`, `log_message`).
4. Aggregations (e.g. counts by level) use **`log_level.keyword`**, because terms
   aggregations need the exact keyword sub-field, not the analysed `text` field.

## Quick checks

```bash
curl -s localhost:9200/_cluster/health | jq .status        # green or yellow
curl -s 'localhost:9200/app-logs-*/_count' | jq .count     # should be > 0
```

## Ports to open in the security group

`5601` (Kibana), `9200` (Elasticsearch). Keep Logstash `5044` internal.

## Notes

- Ships pinned image tags (8.15.3), never `:latest`.
- Security (xpack) is off for the single-box demo; enabling it with real
  passwords is the manual's "Beyond the Basics" stretch goal.
- Heaps are capped (`ES_JAVA_OPTS`, `LS_JAVA_OPTS`) and `mem_limit` set so a
  runaway JVM can't take the box down: ES 1g heap / 2g cap, Logstash 512m / 1g,
  Kibana 1g, Filebeat 128m, generator 64m ≈ 4.3 GB total — fits an 8 GB host.
