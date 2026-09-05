#!/usr/bin/env bash
# Gate: a failed COMMIT must surface as a reconcile error.
#
# Buggy master: ExecTx returns nil, Create "succeeds", Observe sees no
# grant, Create runs again every poll. Synced=True, Ready=False, no error.
# Fixed:        Synced=False reason=ReconcileError, message names the
#               deferred-trigger error from COMMIT.
# Either way the privilege must be absent (COMMIT was rolled back).
set -uo pipefail

GVR="grants.postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"
NAME=extx-commit-fail
rc=0

psql_db() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d extx_db -wtA -c "$1"
}
cond() { "${KUBECTL}" get "${GVR}" "${NAME}" -o jsonpath="{.status.conditions[?(@.type==\"$1\")].$2}"; }
fail() { echo ">>> extx: FAIL — $*"; rc=1; }
info() { echo ">>> extx: $*"; }

# 1. Wait for the first reconcile to land a Synced condition.
for _ in $(seq 1 30); do
    [ -n "$(cond Synced status)" ] && break
    sleep 2
done
info "Synced=$(cond Synced status) reason=$(cond Synced reason)"
info "Ready=$(cond Ready status) reason=$(cond Ready reason)"
info "message: $(cond Synced message)"

# 2. Ground truth: COMMIT rolled back, privilege absent (control).
granted=$(psql_db "SELECT has_schema_privilege('extx_role','extx_schema','USAGE')")
[ "${granted}" = "f" ] && info "privilege absent as expected" || fail "privilege present (${granted}) despite rejected COMMIT"

# 3. The discriminator.
if [ "$(cond Synced status)" = "False" ] && [ "$(cond Synced reason)" = "ReconcileError" ] \
   && cond Synced message | grep -q "COMMIT rejected"; then
    info "COMMIT failure surfaced as ReconcileError"
else
    fail "COMMIT failure swallowed: Synced=$(cond Synced status) reason=$(cond Synced reason)"
fi

# 4. Delete must complete (fixed path stamps external-create-failed, so no
#    creation-grace stall; buggy path re-stamps create-succeeded each poll).
"${KUBECTL}" delete "${GVR}" "${NAME}" --timeout=120s || fail "delete did not complete"

exit ${rc}
