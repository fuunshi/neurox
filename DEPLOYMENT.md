# Deploying neurox

Three services, three homes, one database. This is the order to do them in and
the things that will bite you if you do them in another one.

The compose file in this directory is **not** the deployment. It exists so the
whole pipeline can be run and understood on one machine, and it deliberately
trades away what production needs — TLS, real secrets, backups, more than one
replica. What carries over is the images: each service's `Dockerfile` is the
same one used here and on Render.

---

## What runs where

| Piece | Home | Configured by |
| --- | --- | --- |
| `neurox-web` | Vercel | `neurox-web/vercel.json` |
| `neurox-backend` (API) | Render — web service | `neurox-backend/render.yaml` |
| `neurox-backend` (worker) | Render — background worker | `neurox-backend/render.yaml` |
| `neurox-brain` | Render — web service | `neurox-brain/Dockerfile` |
| Postgres | Neon | connection string |
| Redis, RabbitMQ | your own host | connection strings |
| Mail | any SMTP provider | `SMTP_*` |

---

## The order, and why it is that order

Each step needs the one before it to already exist:

1. **Neon** — nothing can start without a database.
2. **Redis and RabbitMQ** — the API connects to both at boot.
3. **`neurox-brain`** — because step 4 needs its URL.
4. **`neurox-backend`** — because step 5 fetches from it *at build time*.
5. **`neurox-web`** — last.

**Step 5 is not a formality.** Vercel runs `next build` on its own machines, and
that build calls `generateStaticParams`, which fetches the syllabus tree from
`BACKEND_BASE_URL`. If the API is not reachable at that moment the tree comes
back empty, nothing prerenders, and the site deploys with every content URL
rendering on demand. It still works — the code is written to degrade rather than
fail — but the first visitor pays for the first render of every page and the
build log will carry a warning saying exactly this. Deploy the API first.

---

## 1. Neon

Create a project. Put it in the region closest to where the API will run
(Singapore, if you follow `render.yaml` as written) — a cross-region round trip
on every query is the easiest way to make a fast application slow.

Neon gives you **two** connection strings and they are not interchangeable:

| | Use it for | Looks like |
| --- | --- | --- |
| **Pooled** | the running API and worker | `…@ep-xxx-pooler.ap-southeast-1.aws.neon.tech/neondb?sslmode=require` |
| **Direct** | migrations | `…@ep-xxx.ap-southeast-1.aws.neon.tech/neondb?sslmode=require` |

The pooled host goes through PgBouncer, which is what keeps a serverless
Postgres from running out of connections — its limit is per *instance*, and
Render may start several. Migrations want the direct host because PgBouncer in
transaction mode does not hold the session-level state a long migration wants.

`render.yaml` runs migrations through `preDeployCommand`, which reads
`DATABASE_URL`. So: **set `DATABASE_URL` to the pooled string and run migrations
by hand against the direct one**, once, before the first deploy:

```bash
DATABASE_URL='<direct url>' node_modules/.bin/mikro-orm migration:up
```

If the pooled host then gives you trouble on deploy, that is the trade to
revisit — not the other way round.

Two things about the URL itself:

- **Keep `sslmode=require`.** Neon refuses an unencrypted connection and the
  `pg` driver opens one unless the URL asks for TLS. The config strips Prisma's
  `?schema=public` and nothing else, precisely so this survives; a connection
  error that reads like bad credentials is usually this.
- **Copy it whole.** It contains a password, so it belongs in Render's
  environment, never in a file that is committed.

---

## 2. Redis and RabbitMQ

Both are required at boot. Neither speaks TLS by default, so if they are
reachable from the public internet, put them on a private network or in front of
a proxy that terminates TLS — an open Redis is a well-known way to lose a
database that was perfectly well secured.

| | Used for | Managed options |
| --- | --- | --- |
| Redis | queue state, rate-limit counters, caches | Upstash, Redis Cloud, Azure Cache |
| RabbitMQ | the brain's `amqp` transport, background jobs | CloudAMQP, Amazon MQ |

**RabbitMQ is optional in one specific sense:** `NEUROX_BRAIN_TRANSPORT=http` is
the default and needs no broker at all. Set it to `amqp` only when documents get
large enough that holding an HTTP request open is the wrong shape — the compose
file runs RabbitMQ because it runs everything.

---

## 3. `neurox-brain` on Render

New → **Web Service** → build from the `neurox-brain` repository → **Docker**.

Render passes the port in `$PORT` and the image honours it, so there is nothing
to configure there. What you do need:

- **A disk mounted at `/app/data`.** This is the one piece of state this service
  has: the document-frequency corpus that the IDF half of every keyword score is
  computed against. Without a disk it is rebuilt from the cold-start prior on
  every deploy, and keyword weights get measurably worse for a while after each
  one. A small disk is plenty — it is a JSON file.
- **A generous health check grace period.** The spaCy model is loaded during
  start-up and takes about 30 seconds. `/health` answers `200` with
  `"status": "loading"` throughout, on purpose: the process is up before it is
  ready, which is what lets Render tell "starting" from "dead" instead of
  killing a container that is working correctly.

Environment:

| Variable | Value | Notes |
| --- | --- | --- |
| `BRAIN_TRANSPORT` | `http` | `amqp` only if you are running RabbitMQ for it |
| `BRAIN_AMQP_URL` | — | required only for `amqp` |
| `BRAIN_WORKERS` | `2` | one process per core; match `--workers` if you change the command |
| `BRAIN_MAX_TEXT_CHARS` | `500000` | below the API's own cap on purpose — a request this large is 30+ seconds of parsing |
| `BRAIN_SPACY_MODEL` | `en_core_web_sm` | see the note below |

**Do not change `BRAIN_SPACY_MODEL` to `en_core_web_md`.** It looks like the
obvious upgrade for its word vectors, and its vectors are quantised to a 20,000
entry table — 26 to 34 unrelated words share each one, so cosine similarity
comes out as either exactly `1.0` or an artefact of bucket assignment. Graded
similarity is the entire point of using vectors for distractors, and `md` does
not provide it. There is no parsing argument either: about a point of accuracy
for 40MB and 250MB resident. The reasoning is written out in
`src/neurox_brain/config.py`; the docs in `docs/` cover what each stage does.

Note the brain is a **plain HTTP service with no authentication**. It must not
be publicly reachable. Render's private networking, or a shared secret in front
of it, is the intended arrangement.

---

## 4. `neurox-backend` on Render

New → **Blueprint** → point at the `neurox-backend` repository. Render reads
`render.yaml` and creates both services: the API and its worker.

Both run the same image and differ only in their command. The worker imports the
same domain modules, so a second image would be a second thing to keep in step
for no benefit.

**Migrations run in `preDeployCommand`**, once per deploy, after the image is
built and before the new version takes traffic. This is the only correct place
for them. Putting `migration:up` in the container's start command would run it
again on every restart and in every replica, and two migrators racing is how a
schema ends up half applied. The backend deliberately never migrates on boot.

Fill in these — every one is `sync: false` in the blueprint, so Render prompts
rather than reading a value from the repository:

| Variable | Where it comes from |
| --- | --- |
| `DATABASE_URL` | Neon, **pooled** host |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` | step 2 |
| `RABBITMQ_URL` | step 2 |
| `JWT_SECRET` | generate: `openssl rand -hex 32` |
| `TOKEN_HASH_SECRET` | generate separately |
| `APP_BASE_URL` | this API's own public URL |
| `FRONTEND_URL` | the Vercel URL |
| `CORS_ORIGINS` | the Vercel URL — comma-separated if there is more than one |
| `SMTP_*`, `SUPPORT_EMAIL` | your mail provider |
| `NEUROX_BRAIN_URL` | step 3's URL |
| `NEUROX_BRAIN_ENABLED` | `true`, once step 3 answers |

`PORT` is deliberately **not** set. Render injects it and routes to the value it
chose; pinning it would mean the app listening somewhere Render is not sending
traffic.

Two notes:

- **`NEUROX_BRAIN_ENABLED=false` is a supported state.** Generation falls back
  to the heuristic generator, which needs no network. Useful for getting the API
  up before the brain is, and as a kill switch.
- **Set `THROTTLE_*` if you expect crawlers.** The defaults in `throttler.config.ts`
  are 3/sec, 20/10s and 100/min, sized for a signed-in application. The public
  content routes carry their own `@Throttle` override, but the global budget
  still governs everything else.

---

## 5. `neurox-web` on Vercel

New Project → import the `neurox-web` repository → framework preset **Next.js**.
`vercel.json` is committed and sets the build and install commands.

Environment variables — these are the whole deployment:

| Variable | Value | Read at |
| --- | --- | --- |
| `BACKEND_BASE_URL` | step 4's public API URL | **build and run time** |
| `SITE_URL` | this site's own public origin, e.g. `https://neurox.app` | **build and run time** |

Both are marked *build and run* for the same reason: `generateStaticParams` runs
during the Vercel build and uses `BACKEND_BASE_URL`, and `metadataBase` needs
`SITE_URL` at build time to emit absolute canonical URLs. Neither is
`NEXT_PUBLIC_*` — the browser never needs to know the API's address, which is
the point of the BFF.

**`SITE_URL` is not optional.** It falls back to `http://localhost:3001`, and a
canonical link pointing at localhost is worse than no canonical at all: it tells
a search engine the real page lives somewhere that does not resolve.

Once the domain is live, go back and set `CORS_ORIGINS` on the Render service to
match it, and re-run step 4's check that `/health` answers.

---

## Afterwards

```bash
curl -s https://<api-host>/health
curl -s https://<web-host>/robots.txt
curl -s https://<web-host>/sitemap.xml | head
curl -sI https://<web-host>/some/published/note | grep -i cache
```

The sitemap listing real URLs is the sign that the build-time fetch worked. An
empty one means `BACKEND_BASE_URL` was wrong or unreachable when Vercel built,
and a rebuild is all it needs.

---

## Things that will bite you

- **A canonical pointing at localhost.** `SITE_URL` unset. Silent, and it undoes
  the point of the pivot. It is the first thing to check if rankings never
  appear.
- **Migrations that ran nowhere.** `preDeployCommand` reads `DATABASE_URL`; if
  that is the direct host and the app uses the pooled one, both work — but if
  `NODE_ENV` is not `production`, MikroORM looks for TypeScript migrations that
  the image does not contain and reports success for an empty set. The deploy
  goes green and every request 500s. `render.yaml` sets `NODE_ENV=production`
  for exactly this reason.
- **`sslmode` stripped from the database URL.** Reads as a credentials failure.
- **Redis or RabbitMQ without TLS, reachable.** Do not.
- **The brain's disk missing.** Not an error, just gradually worse keyword
  scores after every deploy.
- **Vercel's first build racing the API.** Content URLs still render, but on
  demand and without the prerender the design is built around. Rebuild.
