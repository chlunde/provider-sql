#!/usr/bin/env bash
# Probes for PR #434 (shared connection pool).
#
# Gating (fail the run):
#   1. Database, Schema, Extension and Grant reach Ready.
#   2. Deleting Schema/Extension/Grant completes.
#
# Informational (printed as ">>> pr434: RESULT ..."; gate only with
# PR434_STRICT=true):
#   A. Sessions consumed per reconcile round, from pg_stat_database.sessions
#      (PG14+). Unpooled statements show one session per statement.
#   B. Provider backends still connected inside pr434-db after the
#      resources are Ready (pooled sessions that outlive the reconcile).
#   C. Whether DROP DATABASE via the Database MR succeeds within
#      PR434_DROP_WAIT seconds, or is blocked by those sessions.
set -uo pipefail

SFX="postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"
TIMEOUT="${PR434_TIMEOUT:-120s}"
DROP_WAIT="${PR434_DROP_WAIT:-90}"
STRICT="${PR434_STRICT:-false}"
DB='pr434-db'
rc=0
warn=0

psql_root() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d postgres -wtA -c "$1"
}

fail() { echo ">>> pr434: FAIL — $*"; rc=1; }
info() { echo ">>> pr434: $*"; }
result() { echo ">>> pr434: RESULT — $*"; }
soft() {
    if [ "${STRICT}" = "true" ]; then fail "$*"; else info "WARN — $*"; warn=1; fi
}

synced_msg() {
    "${KUBECTL}" get "$1" \
        -o jsonpath='{.status.conditions[?(@.type=="Synced")].message}' 2>/dev/null || true
}

wait_ready() {
    if "${KUBECTL}" wait --timeout "${TIMEOUT}" --for condition=Ready "$1" >/dev/null 2>&1; then
        info "$1 is Ready"
        return 0
    fi
    fail "$1 not Ready after ${TIMEOUT}: $(synced_msg "$1")"
    return 1
}

sessions() {
    # Total sessions ever established, per database (cumulative counter).
    psql_root "SELECT coalesce(sum(sessions),0) FROM pg_stat_database WHERE datname IN ('postgres','${DB}')"
}

backends() {
    # Provider sessions currently connected, per database and state.
    psql_root "SELECT datname||' '||state||' '||count(*) FROM pg_stat_activity
               WHERE backend_type='client backend' AND pid<>pg_backend_pid()
                 AND datname IN ('postgres','${DB}')
               GROUP BY datname, state ORDER BY 1"
}

RES=(
    "database.${SFX}/${DB}"
    "schema.${SFX}/pr434-schema"
    "extension.${SFX}/pr434-hstore"
    "grant.${SFX}/pr434-schema-usage"
)

# --- 1. converge -------------------------------------------------------------
for r in "${RES[@]}"; do
    wait_ready "$r"
done
if [ "${rc}" -ne 0 ]; then
    echo ">>> pr434: aborting, resources did not converge"
    exit 1
fi

# --- A. sessions per reconcile round ----------------------------------------
before=$(sessions)
stamp=$(date +%s)
for r in "${RES[@]}"; do
    "${KUBECTL}" annotate "$r" pr434-poke="${stamp}" --overwrite >/dev/null
done
sleep 15
after=$(sessions)
result "A: sessions established during one forced reconcile of 4 resources = $((after - before)) (pg_stat_database.sessions, postgres + ${DB})"

# --- B. lingering backends ---------------------------------------------------
info "B: client backends now (datname state count):"
backends | sed 's/^/    /'
lingering=$(psql_root "SELECT count(*) FROM pg_stat_activity WHERE datname='${DB}' AND backend_type='client backend'")
result "B: provider backends still inside ${DB} after Ready = ${lingering}"

# --- 2. delete the in-database resources ------------------------------------
for r in "${RES[@]:1}"; do
    "${KUBECTL}" delete "$r" --wait=false >/dev/null
done
for r in "${RES[@]:1}"; do
    if "${KUBECTL}" wait --timeout "${TIMEOUT}" --for=delete "$r" >/dev/null 2>&1; then
        info "$r deleted"
    else
        fail "$r not deleted after ${TIMEOUT}: $(synced_msg "$r")"
    fi
done
info "B': client backends after deleting Schema/Extension/Grant:"
backends | sed 's/^/    /'

# --- C. DROP DATABASE via the Database MR ------------------------------------
"${KUBECTL}" delete "${RES[0]}" --wait=false >/dev/null
t0=$(date +%s)
dropped=false
while [ $(( $(date +%s) - t0 )) -lt "${DROP_WAIT}" ]; do
    if ! "${KUBECTL}" get "${RES[0]}" >/dev/null 2>&1; then
        dropped=true
        break
    fi
    sleep 3
done
elapsed=$(( $(date +%s) - t0 ))
if [ "${dropped}" = true ]; then
    result "C: DROP DATABASE succeeded, Database MR gone after ${elapsed}s"
else
    msg=$(synced_msg "${RES[0]}")
    result "C: DROP DATABASE still blocked after ${elapsed}s; Synced message: ${msg}"
    info "C: backends holding ${DB}:"
    psql_root "SELECT pid||' '||state||' '||coalesce(application_name,'')||' idle_since='||coalesce(state_change::text,'')
               FROM pg_stat_activity WHERE datname='${DB}' AND backend_type='client backend'" | sed 's/^/    /'
    soft "Database delete blocked by pooled sessions"
    # Unblock so the rest of the run (and the next pass) can proceed.
    psql_root "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname='${DB}' AND pid<>pg_backend_pid()" >/dev/null
    if "${KUBECTL}" wait --timeout "${TIMEOUT}" --for=delete "${RES[0]}" >/dev/null 2>&1; then
        info "C: Database MR gone after terminating its backends"
    else
        fail "Database MR still present after terminating backends: $(synced_msg "${RES[0]}")"
    fi
fi

still=$(psql_root "SELECT count(*) FROM pg_database WHERE datname='${DB}'")
if [ "${still}" != "0" ]; then
    fail "${DB} still exists in pg_database"
fi

if [ "${rc}" -ne 0 ]; then
    echo ">>> pr434: FAIL"
    exit 1
fi
if [ "${warn}" -ne 0 ]; then
    echo ">>> pr434: PASS with warnings (PR434_STRICT=true to gate)"
else
    echo ">>> pr434: PASS"
fi
