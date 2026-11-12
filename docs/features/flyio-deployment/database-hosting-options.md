# Database hosting options: Azure, Fly Managed Postgres, Neon

Exploratory comparison for the [Fly.io proposal](proposal.md). The question:
if the app tier moves to Fly, where should Postgres live, and can dev and QA
share one instance while prod stays separate? Researched 2026-10-16. Nothing
here has been decided.

The current Azure servers (size, networking, usage and cost) are documented
in [`../../INFRA.md` § Databases](../../INFRA.md#databases). This doc uses
that data.

## What any host has to provide

These requirements come from the current usage and the code:

- **Size:** about 2 GB of RAM per environment. Azure averages about 60% of
  2 GiB, with peaks near 90%. CPU averages 10–14% of one vCore, with short
  spikes. Data is under 5 GB.
- **Connections:** headroom for about 55 connections per environment, the
  worst case of the apps' pool settings. Azure B1ms caps at 50.
- **Always-on in practice.** pg-boss (supervise and monitor every 60s) and
  the fluent-ai job loop poll continuously, so scale-to-zero would never
  engage while the apps are running.
- **Roles.** The least-privilege model in fluent-api's `provision-db.ts`
  needs an administrator that can do all of the following:
  - `CREATE ROLE` (`api_migrator`, `api_user`, `ai_migrator`, `ai_user`);
  - `ALTER SCHEMA … OWNER TO`;
  - `GRANT CREATE ON DATABASE`;
  - `ALTER DEFAULT PRIVILEGES`.
- **pg-boss** owns the `pgboss` schema, and the runtime role creates
  queue tables at runtime.
- **Postgres version:** 16 to match prod. QA is on 18 today.
- **Region:** compute and database in the same metro. dev is in Europe;
  QA and prod are in Central India today.

## Option 1: stay on Azure

See `INFRA.md` for detail. Summary:

- **Cost:** about $63/month for all three.
- **Fit:** works today. The weaknesses:
  - every server is open to the whole internet;
  - no HA;
  - the 50-connection cap is close to the observed peaks;
  - no PgBouncer on Burstable.
- **Dev and QA on one server:** doesn't pay off. It saves about $19/month on
  one B1ms, which the combined load likely outgrows. A B2s costs more than
  the two B1ms servers.
- **Reached from Fly:** works now, but only because of the AllowAll rule.
  - Closing the firewall means allowlisting Fly static egress IPs, which are
    assigned per machine.
  - QA and prod have the latency problem described next.

**Fly has no region in India.** I confirmed this through Fly's
platform-regions API. The nearest region is `sin` (Singapore). Fly compute in
`sin` against the Central India databases would pay a cross-border round trip
on every query: likely 50–70 ms, not measured. fluent-api runs several
queries in sequence per request, so that adds up.

## Option 2: Fly Managed Postgres

Pricing from fly.io/pricing. Every plan includes HA, automated backups and
connection pooling.

| Plan    | CPU       | RAM  | $/month |
| ------- | --------- | ---- | ------- |
| Basic   | shared-2x | 1 GB | $38     |
| Starter | shared-2x | 2 GB | $72     |
| Launch  | perf-2x   | 8 GB | $282    |

Storage is $0.28/GB of data actually used, billed hourly. At about 4.5 GB
that is roughly $1.30 per environment. The pricing page doesn't say whether
plan prices vary by region the way compute does.

| Layout                                  | ≈ $/month | vs. Azure ($63) |
| --------------------------------------- | --------- | --------------- |
| 3 × Starter                             | 220       | +157            |
| dev+QA on one Starter, prod on Starter  | 148       | +85             |
| dev+QA on one Basic, prod on Starter    | 114       | +51             |
| 3 × Basic (1 GB is below current usage) | 118       | +55             |

**Fit problems:**

1. **No India region.** Of Fly's Managed Postgres regions, `sin` is the
   closest to Central India. QA and prod data would have to move out of
   India.
2. **Postgres 16 or 17 only**, with no in-place major upgrades. QA (on 18)
   would need a downgrade restore or a rebuild.
3. **No superuser, and only three role types** (`schema_admin`, `writer`,
   `reader`), created through Fly's API, not SQL. `provision-db.ts` cannot
   run as written, and the four-role model would need remapping.
   pg-boss's runtime table creation probably forces the API's runtime role
   up to `schema_admin`, weakening least-privilege. That needs confirming on
   a test cluster.
4. **Access is through the private network**, plus `fly mpg proxy` for
   outside access. That's fine for apps on Fly, but migrations would move to
   `release_command`, or GitHub runners would need a WireGuard step.
5. **Gaps in operations features:** no CPU or storage alerts, no automated
   migration in (only `pg_dump`/`pg_restore`), and patching rolls out "not
   on a fixed schedule".

**Verdict:** this is the most expensive option, and the hardest fit for the
role model. Its advantage is that HA is included, and Azure's current tier
has none.

## Option 3: Neon

Pricing from neon.com/pricing.

- **Compute:** billed per CU-hour. 1 CU is about 4 GB of RAM plus CPU.
- **Storage:** $0.35/GB-month.
- **Instant-restore history:** $0.20/GB-month.
- **Egress:** 500 GB per project included, then $0.10/GB.
- **Plans:** usage-based with no monthly minimum. I assume they apply to
  the whole Neon organization, not to individual projects; this needs
  verifying.

| Plan   | $/CU-hour | Relevant features                                                                                                                    |
| ------ | --------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Launch | 0.106     | Autoscaling up to 16 CU; scale-to-zero can be disabled; 7-day history. **No IP allowlist, no private networking, no SLA, no SOC 2.** |
| Scale  | 0.222     | IP allowlist; private networking (AWS PrivateLink); uptime SLA; SOC 2; 30-day history.                                               |

Always-on compute (730 h/month), from Neon's sizing table:

| Size    | RAM  | `max_connections` | Launch $/month | Scale $/month |
| ------- | ---- | ----------------- | -------------- | ------------- |
| 0.25 CU | 1 GB | 104 (97 usable)   | 19.35          | 40.52         |
| 0.5 CU  | 2 GB | 209               | 38.69          | 81.03         |
| 1 CU    | 4 GB | 419               | 77.38          | 162.06        |

Each environment also pays for storage: about $1.60 at 4.5 GB (an upper
bound, since Azure's figure includes WAL and system files). Instant-restore
history adds roughly $1–2. It is unmeasured; pg-boss churn drives it.

A natural setting is **autoscaling from 0.25 to 1 CU**. Given the 10–14%
average CPU, it would mostly sit at the minimum and scale up for spikes. I
estimate about $20–40/month per environment on Launch, but that's untested.

| Layout                                                                  | ≈ $/month | vs. Azure ($63) |
| ----------------------------------------------------------------------- | --------- | --------------- |
| All on Launch, 3 × 0.5 CU fixed                                         | 123       | +60             |
| All on Launch, dev+QA sharing one 0.5 CU compute, prod 0.5 CU           | 84        | +21             |
| All on Launch, 3 × autoscale 0.25–1 CU                                  | 65–125    | +2 to +62       |
| Non-prod on Launch (2 × 0.25 CU), prod on Scale 0.5 CU (separate orgs?) | 128       | +65             |
| All on Scale, 3 × 0.5 CU                                                | 252       | +189            |

**How it fits fluent:**

1. **Roles: the best fit of the three.** The `neon_superuser` role has
   `CREATEROLE` and `CREATEDB`, and `CREATE ROLE … LOGIN` works in plain
   SQL. `provision-db.ts` should run with small changes: connect as a
   console-created admin rather than `azure_pg_admin`.
   - The Neon docs don't explicitly cover `ALTER SCHEMA … OWNER TO` or
     `ALTER DEFAULT PRIVILEGES`. Postgres 16+ gives a role with `CREATEROLE`
     admin rights over the roles it creates, which should make them work.
     Confirm by running `provision-db.ts` against a scratch Neon branch.
2. **Postgres 14–18 all supported**, so prod (16) and QA (18) both migrate
   without a version change. QA should still be realigned to 16.
3. **Plenty of connections.** Even 0.25 CU allows 104 direct connections,
   double Azure's 50, so the apps can use direct connections. The pooler is
   PgBouncer in transaction mode:
   - session `SET`, `LISTEN/NOTIFY` and session-level advisory locks don't
     work through it;
   - protocol-level prepared statements do (PgBouncer 1.22+), which is what
     postgres.js uses;
   - migrations and `pg_dump` must use the direct endpoint.
4. **Dev and QA can share cheaply**, but only within one region:
   - **Two databases on one branch** share one compute, which saves compute.
     Roles are shared, so the role-name collision from the Azure analysis
     applies.
   - **Two branches** each get their own roles, which removes the collision
     without code changes. Each branch also needs its own compute, though,
     so there is no compute saving.
5. **Scale-to-zero won't help** while the apps are running, because the
   pollers keep the compute awake. It could help for dev and QA only if the
   apps are also stopped, for example overnight.
6. **No India region.** Neon runs only on AWS (its Azure regions are
   deprecated and closed to new projects). The nearest region to Central
   India is `aws-ap-southeast-1` (Singapore). The same data-residency
   decision as Fly applies.
7. **Network security:**
   - **On Launch**, the endpoint is public with password and TLS only. That
     is no worse than today's AllowAll, but no better.
   - **IP allowlisting needs Scale**, plus static Fly egress IPs, which
     brings back the per-machine problem.
   - **Private networking is AWS PrivateLink**, which Fly can't use.
   - TLS is required on every connection, and Neon enforces 60-bit password
     entropy.
8. **Pairing with Fly regions:** Fly `fra` with `aws-eu-central-1`
   (Frankfurt), Fly `lhr` with `aws-eu-west-2` (London), and Fly `sin` with
   `aws-ap-southeast-1`. Same metro, different providers; the latency
   should be low single-digit milliseconds, but measure it. Dev would move
   from `ams` to `fra`.
9. **Operational trade-offs:**
   - computes restart for platform updates, so connections drop briefly
     (postgres.js and pg-boss reconnect);
   - Postgres settings can't be changed at instance level on Launch;
   - no tablespaces and no `track_commit_timestamp` (neither is used today).

**Verdict:** on cost and code fit, Neon is the strongest option for running
alongside Fly. At current scale it is close to Azure's price (about $84–125
on Launch), and its role model works with `provision-db.ts`. The catches:

- it has no India region;
- network hardening (an IP allowlist) needs the Scale plan, which roughly
  doubles compute cost;
- the Scale features (SLA, SOC 2) are probably what prod should have.

## Side by side (per environment, about 2 GB of RAM)

|                       | Azure B1ms                    | Fly MPG Starter                    | Neon Launch 0.5 CU                  | Neon Scale 0.5 CU         |
| --------------------- | ----------------------------- | ---------------------------------- | ----------------------------------- | ------------------------- |
| ≈ $/month             | 19 (WE) / 22 (CI)             | 73                                 | 41                                  | 84                        |
| HA                    | No                            | Yes                                | Multi-AZ storage; compute restarts  | same                      |
| `max_connections`     | 50                            | not documented                     | 209                                 | 209                       |
| Pooler                | No (Burstable)                | PgBouncer, session default         | PgBouncer, transaction              | same                      |
| Postgres versions     | up to 18 (16 and 18 in use)   | 16, 17                             | 14–18                               | 14–18                     |
| Admin / `CREATE ROLE` | `azure_pg_admin`              | No; three API-managed roles        | `neon_superuser`, SQL `CREATE ROLE` | same                      |
| Network restriction   | Firewall (currently AllowAll) | Private network only               | None                                | IP allowlist, PrivateLink |
| India region          | Yes (Central India)           | No (`sin` nearest)                 | No (`ap-southeast-1` nearest)       | same                      |
| Backups / history     | 7 days                        | Included, retention not documented | 7 days                              | 30 days                   |

## What would settle it

1. **Why are QA and prod in Central India?** Is it user proximity, or a
   residency requirement? Neither Fly nor Neon can host in India. If the
   data must stay in India, the realistic choices are to keep QA and prod
   on Azure (perhaps hardened, as in Option 1), or to look at another
   provider with an India region. For example, AWS RDS and Aurora, Supabase
   (AWS), and DigitalOcean all have Mumbai or Bangalore regions; that is
   not yet verified for this purpose.
2. **Measure latency** from a Fly machine in `sin` to `fluent-db-prod`
   (Azure, Central India) and to a Neon `aws-ap-southeast-1` endpoint. Also
   measure `fra`/`ams` against Neon Frankfurt.
3. **Run `provision-db.ts` against a free Neon project** to confirm the role
   model works end to end, including pg-boss creating queues as `api_user`.
4. **Check Neon plan scope.** Do Launch and Scale apply per organization,
   so that non-prod and prod need separate organizations to mix plans?
5. **Fixes worth doing regardless:**
   - remove the AllowAll firewall rules;
   - bring QA back to Postgres 16;
   - make the database role names configurable per environment, which any
     shared-instance setup needs.
