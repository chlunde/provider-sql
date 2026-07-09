# Custom DB Scripts

This directory holds optional script bundles that the e2e harness can run
against the running databases. The mechanism exists to make it easy to
reproduce GitHub issues end-to-end without modifying the core e2e flow.

## How it works

Set `CUSTOM_POSTGRES_SCRIPTS_DIR` (and/or, in the future,
`CUSTOM_MARIADB_SCRIPTS_DIR`, `CUSTOM_MSSQL_SCRIPTS_DIR`) to a directory
containing files to run. The harness sorts the entries lexically and
dispatches by extension:

| Extension | Action                                              |
|-----------|-----------------------------------------------------|
| `.sql`    | Piped to `psql` as superuser against the root DB    |
| `.yaml`   | `kubectl apply -f <file>`                           |
| `.yml`    | `kubectl apply -f <file>`                           |
| `.sh`     | Executed; receives env vars described below         |

Numeric prefixes (`01-…`, `02-…`) are the simplest way to control order.

## When the scripts run

For PostgreSQL the hook fires inside `integration_tests_postgres` after
the provider config is applied but before the built-in test resources
(`Database`, `Role`, `Schema`, `Grant`) are created. The database is
reachable on `localhost:5432` via the port-forward established in
`setup_postgresdb_no_tls`.

## Environment available to scripts

| Variable             | Value                                            |
|----------------------|--------------------------------------------------|
| `POSTGRES_HOST`      | `localhost`                                      |
| `POSTGRES_PORT`      | `5432`                                           |
| `POSTGRES_USER`      | `postgres`                                       |
| `POSTGRES_PASSWORD`  | the randomly generated root password             |
| `POSTGRES_DB`        | `postgres` (root DB)                             |
| `KUBECTL`            | path to the project-pinned `kubectl`             |
| `API_TYPE`           | `cluster` or `namespaced`                        |
| `APIGROUP_SUFFIX`    | empty or `m.` (cluster vs namespaced API groups) |

`.sql` files are run with `PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST
-p $POSTGRES_PORT -U $POSTGRES_USER -d postgres -v ON_ERROR_STOP=1`. Use
`\c <db>` inside the script to switch databases.

## Running only PostgreSQL

The same harness lets you skip the other DB engines:

```
DB_TYPES=postgresql skipcleanup=true make e2e
```

`DB_TYPES` is a comma-separated subset of `mariadb,postgresql,mssql`. The
default is all three. `skipcleanup=true` keeps the KIND cluster, the
provider, the postgres StatefulSet, and the port-forward up after the run
so you can inspect resources with `kubectl`.

## Bundled bundles

| Directory             | Reproduces                                           |
|-----------------------|------------------------------------------------------|
| `postgres-issue-240/` | https://github.com/crossplane-contrib/provider-sql/issues/240 — Grant on a DB the role already owns never reaches Ready |

## Example: reproducing issue #240

```
CUSTOM_POSTGRES_SCRIPTS_DIR=$PWD/cluster/local/scripts/postgres-issue-240 \
  DB_TYPES=postgresql \
  skipcleanup=true \
  make e2e
```

After the run, the cluster is still up:

```
kubectl get grants.postgresql.sql.crossplane.io issue-240-grant \
  -o jsonpath='{.status.conditions}' | jq .
```

Expected (bug present): `Ready=False, reason=Creating` indefinitely.
Expected (bug fixed): `Ready=True`.
