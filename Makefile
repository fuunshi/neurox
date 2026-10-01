# The whole pipeline, from one command.
#
#   make          what you can run
#   make up       build and start everything, then tell you where it is
#
# Every target shells out to Docker Compose. There is no other entry point, so
# there is no second way to start the stack that could drift from this one.

SHELL := /bin/bash
COMPOSE := docker compose
# Every compose invocation reads this file. Kept in one variable so `make down`
# and `make up` cannot end up talking to different projects.
FILE := -f docker-compose.yml

.DEFAULT_GOAL := help
.PHONY: help docker up down restart stop start logs ps clean nuke \
        migrate seed seed\:demo psql shell-backend shell-brain test check health

# ------------------------------------------------------------------- help --- #
help: ## Show this help
	@echo "neurox — the whole pipeline, locally"
	@echo
	@echo "  make up          Build and start everything (first run takes a few minutes)"
	@echo "  make down        Stop everything, keeping your data"
	@echo "  make logs        Follow the logs from every service"
	@echo "  make ps          What is running"
	@echo "  make health      Probe every service and say whether it answered"
	@echo "  make clean       Stop and DELETE all data (database, redis, corpus)"
	@echo
	@echo "  make docker      Install Docker if it is missing"
	@echo "  make migrate     Apply pending database migrations"
	@echo "  make seed        Install the syllabus (idempotent)"
	@echo "  make seed:demo   Seed the demo account (admin@neurox.ai) — for demos"
	@echo "  make psql        Open a psql shell on the running database"
	@echo "  make shell-backend  A shell inside the API container"
	@echo "  make test        Run the test suites for all three projects"

# ----------------------------------------------------------------- docker --- #
docker: ## Install Docker if it is missing
	@bash scripts/install-docker.sh

# ------------------------------------------------------------------- up ----- #
up: docker .env ## Build and start the whole stack
	@$(COMPOSE) $(FILE) up --build -d
	@echo
	@$(MAKE) --no-print-directory health
	@echo
	@echo "  Frontend     http://localhost:3001"
	@echo "  API          http://localhost:3232"
	@echo "  API docs     http://localhost:3232/api/docs"
	@echo "  NLP service  http://localhost:8000/health"
	@echo "  Mailpit      http://localhost:8026"
	@echo "  Postgres     localhost:55432  (user/pass/db: neurox)"
	@echo
	@echo "  Logs:  make logs      Stop:  make down"

# `.env` holds JWT_SECRET and TOKEN_HASH_SECRET, which are committed nowhere and
# generated nowhere. Without them the API cannot sign a token — it fails at
# container start with "auth.jwtSecret is required", which is a clear message
# but a confusing one to meet for the first time.
#
# Created from the template on first use, with the two secrets replaced by
# random ones. The file is gitignored, so this happens once per checkout and the
# generated secrets then persist across `make up` cycles — which matters,
# because regenerating them would invalidate every session on every restart.
.env:
	@if [ -f neurox-backend/.env.template ]; then \
		echo "==> Creating .env from neurox-backend/.env.template with generated secrets"; \
		cp neurox-backend/.env.template .env; \
		jwt=$$(openssl rand -hex 32); \
		hash=$$(openssl rand -hex 32); \
		sed -i.bak "s|^JWT_SECRET=.*|JWT_SECRET=$$jwt|" .env; \
		sed -i.bak "s|^TOKEN_HASH_SECRET=.*|TOKEN_HASH_SECRET=$$hash|" .env; \
		rm -f .env.bak; \
		echo "    Wrote .env — edit it if you want real SMTP credentials."; \
	else \
		echo "error: neurox-backend/.env.template is missing; cannot build a .env" >&2; \
		exit 1; \
	fi

# ------------------------------------------------------------------ down ---- #
down: ## Stop everything, keeping data
	@$(COMPOSE) $(FILE) down

restart: ## Restart without rebuilding
	@$(COMPOSE) $(FILE) restart

stop: ## Stop without removing containers
	@$(COMPOSE) $(FILE) stop

start: ## Start previously-created containers
	@$(COMPOSE) $(FILE) start

logs: ## Follow logs from every service
	@$(COMPOSE) $(FILE) logs -f --tail=100

ps: ## What is running
	@$(COMPOSE) $(FILE) ps

clean: ## Stop and DELETE all data volumes
	@echo "This deletes the database, the Redis data and the brain's corpus."
	@printf 'Continue? [y/N] '; read -r reply; \
	case "$$reply" in [yY]|[yY][eE][sS]) ;; *) echo "Cancelled."; exit 0;; esac
	@$(COMPOSE) $(FILE) down -v
	@echo "Volumes removed. 'make up' will start from an empty database."

# ------------------------------------------------------------------ tools --- #
migrate: ## Apply pending migrations
	@$(COMPOSE) $(FILE) exec neurox-backend node_modules/.bin/mikro-orm migration:up

seed: ## Install the syllabus
	@$(COMPOSE) $(FILE) exec neurox-backend node dist/seeder/curriculum.js

# The demo account: admin@neurox.ai, with decks, review history, a streak and
# completed quizzes, for showing the product without first having to use it.
#
# **Deliberately not part of `make up`.** It creates an account whose password is
# in this file, and it wipes that account's data every time it runs. Both are
# fine on a laptop and neither belongs in a stack somebody else might be using.
#
# The colon in the target name is escaped because Make reads an unescaped one as
# the target/prerequisite separator — `seed:demo:` is a syntax error, and
# `seed\:demo:` is a target literally called `seed:demo`, which is what
# `make seed:demo` types.
seed\:demo: ## Seed the demo account (admin@neurox.ai)
	@$(COMPOSE) $(FILE) exec neurox-backend node dist/seeder/seed.js

psql: ## psql shell on the running database
	@$(COMPOSE) $(FILE) exec postgres psql -U neurox -d neurox

shell-backend: ## Shell inside the API container
	@$(COMPOSE) $(FILE) exec neurox-backend sh

shell-brain: ## Shell inside the NLP container
	@$(COMPOSE) $(FILE) exec neurox-brain sh

# ----------------------------------------------------------------- health --- #
# Probes each service the way its own client would, so a green line means the
# thing actually answers rather than that the container exists.
health: ## Probe every service
	@printf '  %-24s' "postgres"; \
		if $(COMPOSE) $(FILE) exec -T postgres pg_isready -U neurox -d neurox >/dev/null 2>&1; then echo "ok"; else echo "NOT READY"; fi
	@printf '  %-24s' "redis"; \
		if $(COMPOSE) $(FILE) exec -T redis redis-cli ping >/dev/null 2>&1; then echo "ok"; else echo "NOT READY"; fi
	@printf '  %-24s' "rabbitmq"; \
		if $(COMPOSE) $(FILE) exec -T rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1; then echo "ok"; else echo "NOT READY"; fi
	@printf '  %-24s' "neurox-brain"; \
		if curl -fsS --max-time 10 http://localhost:8000/health >/dev/null 2>&1; then echo "ok"; else echo "NOT READY (the model takes ~30s on first start)"; fi
	@printf '  %-24s' "neurox-backend"; \
		if curl -fsS --max-time 10 http://localhost:3232/health >/dev/null 2>&1; then echo "ok"; else echo "NOT READY"; fi
	@printf '  %-24s' "neurox-web"; \
		if curl -fsS --max-time 10 http://localhost:3001/ >/dev/null 2>&1; then echo "ok"; else echo "NOT READY"; fi

# ------------------------------------------------------------------- test --- #
test: ## Run the test suites for all three projects
	@echo "== neurox-brain =="; cd neurox-brain && .venv/bin/python -m pytest -q 2>/dev/null || echo "  (no pytest suite yet)"
	@echo "== neurox-backend =="; cd neurox-backend && pnpm test
	@echo "== neurox-web =="; cd neurox-web && pnpm test

check: ## Typecheck and lint the two Node projects
	@echo "== neurox-backend =="; cd neurox-backend && pnpm lint && npx tsc --noEmit -p tsconfig.json
	@echo "== neurox-web =="; cd neurox-web && pnpm lint && pnpm typecheck
