--
-- voipappz database: extension prerequisites
-- The VoIPAppz API (Sequel/Pliny) manages tables via `rake db:migrate`.
-- We only pre-create the extensions the app depends on.
-- Seeds are handled by the app via `rake db:seed`.
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS prefix WITH SCHEMA public;

GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO PUBLIC;

-- NOTE: event_store_events is deliberately NOT created here.
-- It used to be, with a BIGSERIAL id — which broke the app in two ways:
--   1. It contradicted this file's own contract (above): the API owns tables.
--   2. db/migrate/1018935454_create_event_store.rb uses `create_table?`, so on
--      a fresh volume it found this table already present, skipped creation,
--      and still recorded itself as applied. The app then ran against a
--      pre-RubyEventStore schema (no event_id/metadata/valid_at) forever.
-- The event store is keyed by a single uuidv7 `event_id`; a bigserial is also
-- wrong under multi-master, where sequences are not conflict-free.

-- PostgREST removed 2026-08-03 along with its postgrest_anon/postgrest_auth
-- roles: nothing consumed that API, and postgrest_auth was a LOGIN role with a
-- hardcoded password holding SELECT over every table in this database.
