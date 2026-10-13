-- Roles come from globals.sql; this script only creates databases and grants.
SELECT 'CREATE DATABASE e5renew'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'e5renew')\gexec

GRANT ALL PRIVILEGES ON DATABASE e5renew TO postgres;

SELECT 'CREATE DATABASE casdoor'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'casdoor')\gexec
GRANT ALL PRIVILEGES ON DATABASE casdoor TO casdoor;

SELECT 'CREATE DATABASE gitea'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gitea')\gexec
GRANT ALL PRIVILEGES ON DATABASE gitea TO gitea;
