# rate-limiter chart

Deploys the OpenResty edge rate limiter, the Node backend, and (optionally) the
Redis that holds the shared counter.

## What is and isn't highly available

The **stateless tiers are HA**: `edge` and `app` each run 3 replicas by default,
spread across nodes with pod anti-affinity, guarded by PodDisruptionBudgets, and
rolled with `maxUnavailable: 0` plus an `openresty -s quit` preStop drain, so
updates don't drop in-flight requests.

**Redis is a single primary and the one SPOF.** That is deliberate: the limiter's
correctness depends on one authoritative counter, and `lua-resty-redis` is
neither Sentinel- nor Cluster-aware, so failover would require teaching the hot
path to discover a new primary. Options:

- default: one Redis, recovered by pod reschedule. With `rateLimit.failOpen=false`
  a Redis outage rejects traffic; with `true` it degrades to no limiting.
- production: `redis.enabled=false` and point `redis.external.*` at a managed or
  Sentinel-fronted Redis.

Scaling the edge does **not** loosen the limit — the counter lives in Redis, so
the cap is global across pods. That is the property worth testing after install
(see NOTES).

## Client IP correctness

Behind an Ingress or a LoadBalancer, `remote_addr` is the proxy, so all
anonymous traffic collapses into one IP bucket. Either:

```yaml
edge:
  realIp:
    enabled: true
    trustedCIDRs: ["10.0.0.0/8"]   # only CIDRs you control
```

or set `edge.service.externalTrafficPolicy: Local`. Never trust
`X-Forwarded-For` from arbitrary sources — callers could forge a fresh bucket.

## Config layout

`files/` is the **single source of truth** for the edge config and is shared
verbatim with `docker-compose.yml` at the repo root (Helm's `.Files.Get` cannot
read outside the chart, so the files live here and compose mounts them).

| Path | Shared? |
|---|---|
| `files/conf.d/main.main` | shared — `env` declarations, `error_log` |
| `files/conf.d/default.conf` | shared — resolver, `init_by_lua`, server block |
| `files/lua/rate_limit.lua` | shared — access-phase limiter |
| `files/redis/rate_limiter.lua` | shared — Redis-side fixed-window script |
| `files/conf.d/upstream.inc` | compose only; the chart renders its own |
| `tuning.main` (`worker_processes`) | chart only; compose uses nginx's default |

`worker_processes` is pinned from values rather than `auto` because `auto` is not
cgroup-aware and would start one worker per node core inside a CPU-limited pod.
Connections to Redis land near `edge.replicaCount * workerProcesses *
edge.redis.keepalivePoolSize`; keep that under Redis `maxclients`.

## Install

```sh
# Local cluster: the app image must exist in the cluster first.
docker build -t distributed-rate-limiter-app:latest .
kind load docker-image distributed-rate-limiter-app:latest

helm install rl ./helm/rate-limiter
```
