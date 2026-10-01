# neurox

The whole pipeline, in one repository.

```
neurox/
├── neurox-web       Next.js frontend          — the public site and the app
├── neurox-backend   NestJS API + worker       — the domain, the queue, the socket
├── neurox-brain     Python NLP service        — text into cards, quizzes, keywords
├── docker-compose.yml
└── Makefile
```

Each is its own repository, linked here as a **git submodule** — so this
repository records exactly which commit of each one works together, and a clone
gets that trio rather than whatever `main` happens to be today.

## Run it

```bash
git clone --recurse-submodules git@github.com:fuunshi/neurox.git
cd neurox
make up
```

`make up` installs Docker if it is missing, writes a `.env` with generated
secrets if there is not one, builds all three services, starts Postgres, Redis,
RabbitMQ, Mailpit and the NLP service, applies migrations, installs the
syllabus, and waits for each service to answer before telling you it is ready.

| | |
| --- | --- |
| Frontend | http://localhost:3001 |
| API | http://localhost:3232 |
| API docs (Swagger) | http://localhost:3232/api/docs |
| NLP service | http://localhost:8000/health |
| Mailpit (captured email) | http://localhost:8026 |
| Postgres | `localhost:55432` — user, password and database are all `neurox` |

`make` on its own lists every target. The common ones:

```bash
make logs     # follow every service
make ps       # what is running
make health   # probe each service
make down     # stop, keeping data
make clean    # stop and DELETE all data
```

## Showing it to somebody

```bash
make seed:demo
```

Creates `admin@neurox.ai` / `demo_admin@123` — five decks, sixty days of
review history, completed quizzes and an activity feed, so the app has
something in it without anyone first having to use it. Run it again any time;
it clears that account's data and rebuilds it.

Two things about it. The password is in `Makefile`, so it belongs on a laptop
and not anywhere shared. And the streak it reports is the one the app will
show, which is measured in the account's own timezone — `Asia/Kathmandu` — so
a seeded account can honestly read "1-day streak" while the reviews behind it
run back two months. That is the streak rule working, not a gap in the data.

## Already cloned without submodules?

```bash
git submodule update --init --recursive
```

## Why the ports are unusual

This stack is meant to run on a laptop, where 3000, 5432, 6379 and 8025 are very
often already taken. So each service publishes on a host port chosen not to
collide, while the containers keep talking to each other on the standard ones.
Only the left-hand side of a port mapping is a local convention; change it
freely.

## Deployment

The three services have different homes, and each has config for its target
committed beside its code:

| Service | Runs on | Config |
| --- | --- | --- |
| `neurox-web` | Vercel | `neurox-web/vercel.json` |
| `neurox-backend` | Render | `neurox-backend/render.yaml` |
| `neurox-brain` | Render (or any container host) | `neurox-brain/Dockerfile` |
| Postgres | Neon | connection string only |
| Redis, RabbitMQ | Your own host | not covered here |

See **[DEPLOYMENT.md](DEPLOYMENT.md)** for the order to do it in and the
environment each one needs. The short version: the database first, then the NLP
service, then the API, then the frontend — because each depends on the one
before it being reachable.

The local compose file is not the deployment. It exists so the whole thing can
be run and understood on one machine, and it deliberately trades away the things
production needs — TLS, real secrets, backups, more than one replica.

## Working on one service

You do not need the whole stack to work on one part. Each subdirectory has its
own README, and each runs on its own:

```bash
cd neurox-brain  && ./scripts/dev.sh      # the NLP service alone
cd neurox-backend && pnpm start:dev       # the API alone, against your own database
cd neurox-web    && pnpm dev              # the frontend alone
```

## Submodules, briefly

A submodule is a pointer, not a copy: this repository stores the commit hash of
each child. That is what makes the trio reproducible, and it is also the one
thing that surprises people — **a change inside `neurox-web` is not recorded
here until you commit the updated pointer.**

```bash
cd neurox-web && git commit -am "…" && git push
cd .. && git add neurox-web && git commit -m "chore: bump neurox-web"
```

If a submodule shows as modified without you changing it, it usually means
someone else pushed to it and your checkout is behind.
