-- PostgreSQL roles and privileges for local development.
-- This file is executed automatically on first database initialization
-- via the postgres docker-entrypoint-initdb.d mechanism.
-- ================================================================
-- BOOTSTRAP: Run as Azure admin account (or superuser) for PROD
-- ================================================================


-- ================================================================
-- SECTION 1: LOGIN USERS
-- ================================================================

CREATE USER db_admin    WITH PASSWORD 'pa$$word' CREATEROLE;
CREATE USER migrations  WITH PASSWORD 'pa$$word';
CREATE USER web_user    WITH PASSWORD 'pa$$word';
CREATE USER ai_user     WITH PASSWORD 'pa$$word';


-- ================================================================
-- SECTION 2: GROUP ROLES (no login)
-- ================================================================

-- Data ownership/write roles
CREATE ROLE role_web_data;       -- full DML on public schema
CREATE ROLE role_pgboss_user;    -- full DML on pgboss schema
CREATE ROLE role_ai_data;        -- full DML on ai schema
CREATE ROLE role_ai_reader;      -- SELECT on public schema (cross-schema reads for fluent-ai)

-- Utility roles
CREATE ROLE role_migrations;     -- DDL + DML across all schemas


-- ================================================================
-- SECTION 3: ASSIGN ROLES TO LOGIN USERS
-- ================================================================

GRANT role_web_data     TO web_user;
GRANT role_pgboss_user  TO web_user;

GRANT role_ai_data      TO ai_user;
GRANT role_ai_reader    TO ai_user;
GRANT role_pgboss_user  TO ai_user;

GRANT role_migrations   TO migrations;


-- ================================================================
-- SECTION 3b: CREATE SCHEMAS (pgboss, drizzle, and ai do not exist yet)
-- ================================================================

CREATE SCHEMA IF NOT EXISTS pgboss;
CREATE SCHEMA IF NOT EXISTS drizzle;
CREATE SCHEMA IF NOT EXISTS ai;


-- ================================================================
-- SECTION 4: SCHEMA OWNERSHIP
-- Note: on Azure Flexible Server, run these as the Azure admin
-- account since true superuser is unavailable
-- ================================================================

ALTER SCHEMA public  OWNER TO db_admin;
ALTER SCHEMA pgboss  OWNER TO db_admin;
ALTER SCHEMA drizzle OWNER TO db_admin;
ALTER SCHEMA ai      OWNER TO db_admin;


-- ================================================================
-- SECTION 5: SCHEMA USAGE GRANTS
-- ================================================================

-- public: web, ai reader, and migrations need access
GRANT USAGE ON SCHEMA public  TO role_web_data, role_ai_reader, role_migrations;

-- pgboss: web, ai, and migrations need access
GRANT USAGE ON SCHEMA pgboss  TO role_pgboss_user, role_migrations;

-- drizzle: migrations only — web_user has zero access here
GRANT USAGE ON SCHEMA drizzle TO role_migrations;

-- ai: ai service and migrations need access
GRANT USAGE ON SCHEMA ai      TO role_ai_data, role_migrations;


-- ================================================================
-- SECTION 6: DDL RIGHTS (CREATE within schema)
-- Only migrations needs to create/alter/drop objects
-- ================================================================

GRANT CREATE ON SCHEMA public  TO role_migrations;
GRANT CREATE ON SCHEMA pgboss  TO role_migrations;
GRANT CREATE ON SCHEMA drizzle TO role_migrations;
GRANT CREATE ON SCHEMA ai      TO role_migrations;


-- ================================================================
-- SECTION 7: DML ON EXISTING OBJECTS
-- ================================================================

-- public schema: full DML for web, full DML+DDL support for migrations
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO role_web_data;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO role_web_data;

-- public schema: read-only for ai reader
GRANT SELECT ON ALL TABLES    IN SCHEMA public TO role_ai_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO role_ai_reader;

GRANT ALL ON ALL TABLES    IN SCHEMA public TO role_migrations;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO role_migrations;

-- pgboss schema: full DML for web and ai
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA pgboss TO role_pgboss_user;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA pgboss TO role_pgboss_user;

GRANT ALL ON ALL TABLES    IN SCHEMA pgboss TO role_migrations;
GRANT ALL ON ALL SEQUENCES IN SCHEMA pgboss TO role_migrations;

-- drizzle schema: migrations only
GRANT ALL ON ALL TABLES    IN SCHEMA drizzle TO role_migrations;
GRANT ALL ON ALL SEQUENCES IN SCHEMA drizzle TO role_migrations;

-- ai schema: full DML for ai service
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA ai TO role_ai_data;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA ai TO role_ai_data;

GRANT ALL ON ALL TABLES    IN SCHEMA ai TO role_migrations;
GRANT ALL ON ALL SEQUENCES IN SCHEMA ai TO role_migrations;


-- ================================================================
-- SECTION 8: DEFAULT PRIVILEGES FOR FUTURE OBJECTS
-- Scoped to the creating role to ensure new tables are covered
-- ================================================================

-- When migrations creates tables in public
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO role_web_data;
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA public
  GRANT USAGE, SELECT                  ON SEQUENCES TO role_web_data;

-- When migrations creates tables in public — ai reader gets SELECT
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA public
  GRANT SELECT ON TABLES    TO role_ai_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO role_ai_reader;

-- When migrations creates tables in pgboss
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA pgboss
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO role_pgboss_user;
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA pgboss
  GRANT USAGE, SELECT                  ON SEQUENCES TO role_pgboss_user;

-- When migrations creates tables in ai
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA ai
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO role_ai_data;
ALTER DEFAULT PRIVILEGES FOR ROLE role_migrations IN SCHEMA ai
  GRANT USAGE, SELECT                  ON SEQUENCES TO role_ai_data;

-- drizzle schema: no default privileges for web_user — intentionally locked out
