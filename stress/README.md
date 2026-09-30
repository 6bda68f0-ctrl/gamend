# Load testing

**[SUMMARY.md](SUMMARY.md) — what the stress test found, in one page.** Start
there; the rest of this file is how to run it yourself.

Two questions, two tools, one directory:

- **What does each operation cost?** `scenarios/` — one isolated k6 scenario
  per feature, run sequentially by `suite.sh`, rendered by `report.mjs`. This
  is the regression benchmark: run it before and after a change and diff.
- **How many players fit?** `journeys/` — a weighted player session ramped
  until the SLO breaks, plus an idle-socket test and a broadcast-storm test.

The plan behind it, including the machine matrix and what we expect to find, is
[docs/specs/load-testing.md](../docs/specs/load-testing.md).

## Quick start (local)

For **checking a change works under load** — every scenario's checks pass, no
errors — start the server in bench mode. For **numbers you compare or publish**,
use the `MIX_ENV=prod` server under [What a local number means](#what-a-local-number-means)
instead: a plain `mix phx.server` measures the code reloader, not gamend.

```bash
cd modules/plugins_examples/stress_hook && mix deps.get && mix compile && mix plugin.bundle && cd -
GAMEND_DEV_BENCH=1 MIX_BUILD_PATH=_build/bench \
  GAMEND_CONTENT_PLUGINS_DIR=modules/plugins_examples GAMEND_RATELIMIT_ENABLED=false \
  GAMEND_FEATURES_LIST_LOBBIES_ENABLED=true GAMEND_FEATURES_LIST_GROUPS_ENABLED=true \
  mix phx.server
```

(`GAMEND_DEV_BENCH=1` switches off the code reloader, HEEx annotations and
expensive runtime checks; its own build path avoids a `mix clean` when you
toggle it. The `gamend-bench` launch config does the same on port 4020.)

Then, in another shell — each run into its own directory, so the report shows
that run and nothing left over from an earlier one:

```bash
cd stress && RESULTS_DIR=results/$(date +%F-%H%M) BASE_URL=http://localhost:4000 ./suite.sh
```

To compare two builds, run each into its own `RESULTS_DIR` on a freshly migrated
database. A database already carrying a previous run's million rows is slower on
every read, and that difference will look like a regression in whichever build
ran second.

That runs all 19 scenarios one at a time (a few minutes at the defaults), prints
a table, and writes the two report files described under
[The report](#the-report).

One scenario at a time while iterating:

```bash
BASE_URL=http://localhost:4000 k6 run --vus 2 --iterations 4 scenarios/chat.js
```

### What a local number means

Only one thing: the same laptop, before and after your change.

```bash
BASE_URL=http://localhost:4000 VUS=20 DURATION=30s RESULTS_DIR=results/before ./suite.sh
# …make the change, restart the server…
BASE_URL=http://localhost:4000 VUS=20 DURATION=30s RESULTS_DIR=results/after ./suite.sh
node report.mjs --diff results/before results/after
```

k6 and the server share your cores, so keep VUs modest (a few hundred at most)
and never compare a laptop number with a Fly number.

**Run the server with `MIX_ENV=prod`, always.** This is not a rounding error:
the same `me` scenario on the same machine measured **293 req/s at 50 ms** in
dev and **18,918 req/s at 0.6 ms** in prod — a 60x difference. Dev mode checks
for changed files on every request, so a dev-mode benchmark measures the code
reloader and nothing else.

```bash
MIX_ENV=prod GAMEND_AUTH_SECRET_KEY_BASE=$(mix phx.gen.secret) \
  GAMEND_DB_SQLITE_PATH=/tmp/bench.db GAMEND_CONTENT_PLUGINS_DIR=stress/.plugins \
  GAMEND_RATELIMIT_ENABLED=false GAMEND_AUTH_DEVICE_AUTH_ENABLED=true \
  GAMEND_FEATURES_LIST_LOBBIES_ENABLED=true GAMEND_FEATURES_LIST_GROUPS_ENABLED=true \
  mix phx.server
```

(`mix assets.deploy` once first, and `mix ecto.create && mix ecto.migrate`
against that database path.)

### Rate limiting will stop a run in seconds

The limiter buckets per **IP**: 10 auth requests and 240 general requests per
minute. Every VU on one machine shares one bucket, so a run without
`GAMEND_RATELIMIT_ENABLED=false` measures the limiter and nothing else. The
`rate_limit deny` counter on `/metrics` is the check that it really is off.

### Load only `stress_hook`, not the whole example set

`example_hook` submits a leaderboard score on **every login** and rejects
matchmaking modes outside `casual|ranked`. Left loaded, it charges core for a
sample plugin's writes — a device-login benchmark silently includes an extra
leaderboard write. For numbers you intend to publish, point the plugins
directory at a copy containing only `stress_hook`:

```bash
mkdir -p .plugins && cp -R ../modules/plugins_examples/stress_hook .plugins/
GAMEND_CONTENT_PLUGINS_DIR=stress/.plugins mix phx.server
```

(`stress/.plugins/` is gitignored — it is a staging directory, not a second
copy of the plugin to maintain.)

`fly/matrix.sh` does the same thing on the bench machine (`stage_plugins`).
For everyday iteration, `modules/plugins_examples` is fine — the scenarios are
written to pass with both plugins loaded.

### Sockets: two different questions

`journeys/ws_idle.js` holds N sockets to find the memory ceiling;
`journeys/ws_storm.js` opens N as fast as it can, drops them all at once and
brings them back, to find connects/s and recovery. Both take `FRIENDS=N`, which
seeds the socket's user with N friends through the plugin: the user channel runs
a friends query on join and memoises the result on the socket's heap for its
lifetime, so friend count changes both connect cost and per-socket memory.


## On Fly

`fly/matrix.sh --setup` prints the one-time commands (they create billable
resources, so it will not run them for you). After that:

```bash
cd stress/fly
DRY_RUN=1 ./matrix.sh        # see what it will do
./matrix.sh B                # one cell
./matrix.sh                  # the whole matrix, ~35 min per cell
```

The generator is a k6 machine in the same region hitting the bench app over
`.internal`, so the numbers are the server's rather than the internet's. Server
metrics come from the existing PromEx `/metrics` endpoint via Fly's own
Prometheus — watch them on fly-metrics.net while a run is in flight; RSS during
`ws_idle` is the only place the per-socket memory cost shows up.

## Layout

| Path | What it is |
|---|---|
| `lib/config.js` | env → `BASE_URL`/`VUS`/`DURATION`, the SLO, k6 option builders, the summary writer |
| `lib/auth.js` | device login (a fresh user per VU), email login, refresh, per-VU token cache |
| `lib/api.js` | one thin wrapper per endpoint, each tagged so metrics group per route |
| `lib/phx.js` | Phoenix channel client over `k6/ws` — join, push, wait-for-event with timing |
| `lib/hooks.js` | `POST /hooks/call` — the plugin path and the seeding helpers |
| `lib/checks.js` | shared correctness checks, including read-your-write |
| `scenarios/*.js` | one feature each, isolated |
| `journeys/*.js` | mixed load: capacity ramp, idle sockets, connect storm, broadcast storm, soak |
| `suite.sh` | runs every scenario in turn, then prints the table |
| `sweep.sh` | one scenario up a ladder of VU counts — where it stops scaling |
| `SUMMARY.md` | the findings, one page — authored, and rendered at the top of the report page |
| `report.mjs` | `results/*.json` → table, `--md`/`--page` reports, `--diff before after` |
| `page.mjs` | the Markdown and HTML report templates, including the SVG charts |
| `fly/` | the bench app, the generator machine, and the matrix driver |
| `baselines/` | committed summaries for runs that were published — see [2026-08-19](baselines/2026-08-19-macbook-air-m1.md) |

The server-side half is [`modules/plugins_examples/stress_hook`](../modules/plugins_examples/stress_hook):
the micro-benchmark RPCs, plus the triggers for writes a player has no endpoint
for (quest progress, score submission, wallet credits, user seeding).

## Finding the ceiling

`suite.sh` answers "what does this cost" at one concurrency. `sweep.sh` answers
"where does it stop scaling" by running one scenario up a ladder of VU counts:

```bash
BASE_URL=http://localhost:4000 ./sweep.sh me 15 30 60 120 240
```

Read the three columns together — rising req/s with flat p95 is headroom, flat
req/s with rising p95 is saturation (work is queueing, not going faster), and
rising errors is past it. A path whose throughput *falls* as concurrency rises
is contending, not queueing, and that is the interesting case.

The isolated scenarios run flat out (`THINK=0`) because a microbenchmark that
pauses measures its own pacing. Player-like think time lives in
`journeys/player_session.js` under `SESSION_THINK`, where modelling a person is
the point.

## The report

`suite.sh` prints a table when it finishes. For something you can keep, send to
someone, or put in a post, generate the full report:

```bash
node report.mjs results/ --md results/report.md --page results/report.html \
  --summary SUMMARY.md
```

`--summary` leads the page with `SUMMARY.md`, so whoever opens it reads what was
learned before the tables. `--sweep <label>=<dir>` adds saturation curves, and
two of them put two configurations on the same axes.

- **`report.md`** — every table plus unicode bar charts, so it renders anywhere
  a Markdown file renders and needs no image assets.
- **`report.html`** — a self-contained page: total requests, peak throughput,
  concurrent users, measured time, checks run and failed, error rate, bytes
  transferred, then throughput and latency charts (SVG, inline, dark-mode
  aware) and the per-scenario and per-operation tables. No network, no CDN, so
  it opens from a file path, from a repo, or from anywhere you host it.

Both are built from the same `results/*.json` the run already wrote, so they can
be regenerated at any time without re-running anything.

## Reading a run

```
| scenario     | VUs | rps  | med  | p95  | p99  | errors | checks |
| me           | 200 | 1840 | 22.1 | 48.0 | 91.2 |  0.00% | 100.00%|
```

Latency is the boring column. The one that decides whether a run counts is
**checks**: every write scenario reads its own write back, so a cache serving
stale data shows up as a check failure while the latency still looks excellent.
A run with failed checks is not a slower run, it is a wrong one, and
`report.mjs` lists those separately at the bottom.

Then look at the server side for the same window: CPU, RSS, BEAM run queue,
Ecto queue time, cache hit ratio, and the log's `[error]` count. A p95 that
looks fine over a page of `DBConnection` errors is a failed run that k6 cannot
see from the outside.

## Everything, once

The full local pass — all 19 scenarios and all 5 journeys — with the server
configured as above:

```bash
cd stress
BASE_URL=http://localhost:4000 VUS=5 DURATION=15s ./suite.sh
node report.mjs results/ --md results/report.md --page results/report.html

# journeys are not part of the suite: each answers its own question
BASE_URL=http://localhost:4000 PEAK=50 RAMP=1m HOLD=1m  k6 run journeys/player_session.js
BASE_URL=http://localhost:4000 SOCKETS=200 DWELL=60s    k6 run journeys/ws_idle.js
BASE_URL=http://localhost:4000 SOCKETS=200 HOLD=60s     k6 run journeys/ws_storm.js
BASE_URL=http://localhost:4000 SUBSCRIBERS=100 WRITERS=5 DURATION=1m k6 run journeys/lobbies_storm.js
BASE_URL=http://localhost:4000 RATE=30 SOAK=30m         k6 run journeys/soak.js
```

On a laptop keep `VUS` and `SOCKETS` modest — k6 and the server share the same
cores, so past a few hundred you are measuring the generator.

## Verifying a script still works

Every scenario should pass a single-iteration run against a local server:

```bash
for f in scenarios/*.js; do
  echo "== $f"
  BASE_URL=http://localhost:4000 k6 run --quiet --vus 1 --iterations 1 "$f" || echo "FAILED $f"
done
```

That is the whole test strategy for the harness: these scripts are exercised by
running them, not by unit tests.
