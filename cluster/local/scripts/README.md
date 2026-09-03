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

`.yaml` files are piped through `envsubst` first, so one file can serve both
passes:

- write the API group as `postgresql.sql.${APIGROUP_SUFFIX}crossplane.io`;
- write the provider config reference as

  ```yaml
    providerConfigRef:
      ${PROVIDERCONFIG_KIND_LINE}
      name: default
  ```

  which expands to `kind: ProviderConfig` on the namespaced pass and to a blank
  line on the cluster pass (namespaced resources require the kind, cluster
  ones reject it);
- keep the spec to fields both CRD variants accept: the namespaced Grant has
  no `spec.deletionPolicy`, and the API server rejects the whole document if
  it is present.

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
| `postgres-routine-grant/` | Routine Grant on a multi-argument function (Observe cross join, fixed on master); 1-arg control |
| `postgres-pr-436-routine-args/` | https://github.com/crossplane-contrib/provider-sql/pull/436 — schema-qualified composite types in `routines[].args`: admission contract, overload disambiguation, re-reconcile stability, delete precision, plus informational probes for `public.`/`pg_catalog.`-qualified spellings |
| `postgres-issue-440-extension-schema/` | https://github.com/crossplane-contrib/provider-sql/issues/440 — `Extension.spec.forProvider.schema`: postgis (non-relocatable) into `gis`, hstore into `"Mixed Case"`, late-init control, missing-schema rejection, out-of-band drift revert, impossible-move error surfacing, delete completeness. Needs `POSTGRES_IMAGE=imresamu/postgis:18-3.6` |

## Choosing the PostgreSQL image

`POSTGRES_VERSION=<tag>` picks a tag of the official `postgres` image (default
`18`). `POSTGRES_IMAGE=<image>` replaces the whole image reference, for
bundles that need extensions the official image lacks:

```
POSTGRES_IMAGE=imresamu/postgis:18-3.6 \
  CUSTOM_POSTGRES_SCRIPTS_DIR=$PWD/cluster/local/scripts/postgres-issue-440-extension-schema \
  DB_TYPES=postgresql make e2e
```

`imresamu/postgis` is used because the official `postgis/postgis` tags are
amd64-only.

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
