#!/usr/bin/env bash
# Assert that issue #240 is fixed: a Grant requesting a SUBSET of privileges on
# a database the role OWNS must reach Ready.
#
# Root cause (pkg/controller/{cluster,namespaced}/postgresql/grant/reconciler.go,
# selectDatabaseGrantQuery): the existence check demands exact set equality
#
#   HAVING array_agg(acl.privilege_type ORDER BY privilege_type ASC)
#        = (SELECT array(SELECT unnest($4::text[]) AS perms ORDER BY perms ASC))
#
# Creating the database with OWNER leaves datacl NULL. The provider's first
# REVOKE/GRANT materialises it to the owner's full implicit set
# {CONNECT, CREATE, TEMPORARY}. This Grant asks only for CONNECT, so the
# equality can never hold: Observe reports ResourceExists=false forever and
# Create loops. Requesting ALL masks the bug (ExpandPrivileges expands it to
# exactly that three-element set).
#
# This bundle only runs when CUSTOM_POSTGRES_SCRIPTS_DIR points at it, so it is
# safe for this check to FAIL the run — that is the point. Set
# ISSUE_240_INFORMATIONAL=true to downgrade it to a warning while the bug is
# still open (e.g. when using the bundle to demo the repro rather than to gate
# a fix).
set -uo pipefail

NAME="issue-240-grant"
GVR="grants.postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"
TIMEOUT="${ISSUE_240_TIMEOUT:-60s}"

echo ">>> issue-240: waiting up to ${TIMEOUT} for ${NAME} (${GVR}) to become Ready"

if "${KUBECTL}" wait --timeout "${TIMEOUT}" --for condition=Ready "${GVR}/${NAME}" >/dev/null 2>&1; then
    echo ">>> issue-240: PASS — Grant is Ready; the owner's implicit privileges are tolerated."
    exit 0
fi

reason=$("${KUBECTL}" get "${GVR}/${NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
message=$("${KUBECTL}" get "${GVR}/${NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Synced")].message}' 2>/dev/null || true)

echo ">>> issue-240: Grant did NOT become Ready within ${TIMEOUT}."
echo ">>> issue-240:   Ready.reason  = ${reason:-<none>}"
echo ">>> issue-240:   Synced.message= ${message:-<none>}"
echo ">>> issue-240: A Ready.reason of 'Creating' means Observe keeps returning"
echo ">>> issue-240: ResourceExists=false — the array_agg equality never matches the"
echo ">>> issue-240: owner's implicit {CONNECT,CREATE,TEMPORARY}."
echo ">>> issue-240: inspect with:"
echo "    kubectl get ${GVR}/${NAME} -o jsonpath='{.status.conditions}' | jq ."

# Show the actual ACL so the failure is self-explanatory.
if command -v psql >/dev/null 2>&1; then
    echo ">>> issue-240: datacl for the owned database:"
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d postgres -At \
        -c "SELECT datname, datacl FROM pg_database WHERE datname='my-service';" 2>/dev/null \
        | sed 's/^/    /' || true
fi

if [ "${ISSUE_240_INFORMATIONAL:-false}" = true ]; then
    echo ">>> issue-240: ISSUE_240_INFORMATIONAL=true — reporting as a warning, not failing."
    exit 0
fi

echo ">>> issue-240: FAIL — bug reproduced."
exit 1
