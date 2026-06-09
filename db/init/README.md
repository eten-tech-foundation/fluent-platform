# Database Initialization

The `fluent-platform` **no longer manages database initialization**.
Each service (`fluent-api`, `fluent-ai`) is solely responsible for its own
schema, users, migrations, and seed data.

## Ecosystem mode

In ecosystem mode (`./fluent.sh up`), the shared PostgreSQL container starts
with only the default `postgres` superuser. Services self-provision by running
their own bootstrap scripts (which create roles and schemas idempotently) then
running their own migrations (Drizzle, Alembic) and seeds on startup.

## Standalone mode

In standalone mode (`./fapi.sh up`, `./fai.sh up`), the postgres container also
starts superuser-only. The service self-provisions on startup exactly as in
ecosystem mode: its bootstrap step creates its own roles and schemas
idempotently, then runs its migrations and seeds. Nothing is mounted into
`docker-entrypoint-initdb.d`.

## Shared resources

There are **no cross-service shared schemas**. The API owns `public`, `pgboss`,
and `drizzle`; the AI owns `ai`. Services communicate over HTTP (`FLUENT_AI_URL`),
never by reading each other's tables. pg-boss is the API's internal job queue.
