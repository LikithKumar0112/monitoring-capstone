COMPOSE = docker compose

.PHONY: up-metrics up-logging up-alerting up-tracing up-scaling up-all down nuke ps logs verify

up-metrics:
	$(COMPOSE) --profile metrics up -d

up-logging:
	$(COMPOSE) --profile logging up -d

up-alerting:
	$(COMPOSE) --profile metrics --profile alerting up -d

up-tracing:
	$(COMPOSE) --profile tracing up -d

up-scaling:
	$(COMPOSE) --profile metrics --profile scaling up -d

up-all:
	$(COMPOSE) --profile all up -d

down:
	$(COMPOSE) --profile all down

nuke:
	$(COMPOSE) --profile all down -v

ps:
	$(COMPOSE) --profile all ps

logs:
	$(COMPOSE) --profile all logs -f --tail=100

verify:
	./verify.sh
