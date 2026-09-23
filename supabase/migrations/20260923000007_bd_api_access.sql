-- BD Radar: Data API (PostgREST) access to the bd schema.
--
-- Exposes bd alongside the Supabase defaults so the web app and the Claude
-- tasks can use the REST API with Accept-Profile: bd. The same setting lives
-- in Dashboard > Project Settings > Data API > Exposed schemas; if someone
-- edits that list, keep bd in it.
alter role authenticator set pgrst.db_schemas = 'public, graphql_public, bd';

-- Service-role API calls inherit the authenticator's 8s statement timeout.
-- The first scoring pass after a large queue import can take longer.
alter role service_role set statement_timeout = '120s';

notify pgrst, 'reload config';
notify pgrst, 'reload schema';
