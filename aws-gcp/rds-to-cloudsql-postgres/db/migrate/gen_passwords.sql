-- Generate ALTER ROLE ... LOGIN PASSWORD statements for the application LOGIN roles, from the SOURCE
-- catalog. Run against the SOURCE with a password variable:
--   psql "$SOURCE_URL" -tAqf gen_passwords.sql -v pw="$APP_DB_PASSWORD"
-- (:'pw' quotes the value safely, so pass the raw password — no surrounding quotes.)
--
-- Passwords never travel in a dump. At cutover you assign each application login role its real
-- password on the target. This lab assigns the same APP_DB_PASSWORD to every seeded login role for
-- simplicity; a real migration would supply each role's own secret.

SELECT format('ALTER ROLE %I LOGIN PASSWORD %L;', r.rolname, :'pw')
FROM pg_roles r
WHERE r.rolcanlogin
  AND r.rolname NOT LIKE 'pg\_%'
  AND r.rolname NOT LIKE 'rds%'
  AND r.rolname NOT LIKE 'cloudsql%'
  AND r.rolname NOT IN ('postgres', current_user)
ORDER BY r.rolname;
