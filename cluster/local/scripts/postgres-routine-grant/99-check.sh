#!/usr/bin/env bash
# Assert that a routine Grant on a multi-argument function reaches Ready.
#
# Reported on v0.16.0-beta.0:
# https://github.com/crossplane-contrib/provider-sql/issues/240#issuecomment-4629228895
#
# selectRoutineGrantQuery builds:
#
#   FROM pg_proc p
#   LEFT JOIN unnest(p.proargtypes) WITH ORDINALITY AS args(t, ord) ON true
#   INNER JOIN pg_namespace n ON p.pronamespace = n.oid,
#   aclexplode(p.proacl) AS acl                    <-- cross join
#   ...
#   HAVING array_agg(acl.privilege_type ORDER BY privilege_type ASC)
#        = (SELECT array(SELECT unnest($5::text[]) AS perms ORDER BY perms ASC))
#
# unnest(proargtypes) yields one row per ARGUMENT; aclexplode(proacl) yields one
# row per PRIVILEGE. The comma is a cross join, so array_agg(privilege_type)
# collects one EXECUTE per argument. EXECUTE is the only privilege a function
# can hold, so the failure axis is purely argument count.
#
# Confirmed against PostgreSQL 18.4:
#   0 args -> observed OK    (LEFT JOIN yields a single NULL row)
#   1 arg  -> observed OK    <- what every existing unit test uses
#   2 args -> NEVER observed
#   9 args -> NEVER observed (the reported case)
#
# Fix: aggregate the privileges independently of the argument rows, e.g.
# compute the signature in a separate subquery/CTE from the ACL check, or
# use array_agg(DISTINCT acl.privilege_type).
#
# Set ROUTINE_GRANT_INFORMATIONAL=true to warn instead of fail.
set -uo pipefail

GVR="grants.postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"
TIMEOUT="${ROUTINE_GRANT_TIMEOUT:-60s}"
rc=0

check() {
    local name="$1" expectation="$2"
    echo ">>> routine-grant: waiting up to ${TIMEOUT} for ${name} (${expectation})"
    if "${KUBECTL}" wait --timeout "${TIMEOUT}" --for condition=Ready "${GVR}/${name}" >/dev/null 2>&1; then
        echo ">>> routine-grant: ${name} is Ready."
        return 0
    fi
    local reason
    reason=$("${KUBECTL}" get "${GVR}/${name}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    echo ">>> routine-grant: ${name} NOT Ready (reason=${reason:-<none>})"
    return 1
}

# The control must pass. If it does not, the diagnosis below is wrong.
if ! check routine-grant-onearg "1 arg, expected Ready today"; then
    echo ">>> routine-grant: UNEXPECTED — the single-argument control also failed."
    echo ">>> routine-grant: the cause is NOT the argument-count cartesian product."
    rc=1
fi

# The reported case.
if ! check routine-grant-multiarg "9 args, the reported bug"; then
    echo ">>> routine-grant: the GRANT was applied but Observe cannot confirm it."
    echo ">>> routine-grant: ground truth from PostgreSQL:"
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d routine-grant-db -At \
        -c "SELECT routine_name, privilege_type FROM information_schema.routine_privileges
             WHERE grantee='routine-grant-role';" 2>/dev/null | sed 's/^/    /' || true
    echo ">>> routine-grant: privileges the Observe query actually aggregates:"
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d routine-grant-db -At \
        -c "SELECT p.proname, cardinality(array_agg(acl.privilege_type)) AS rows_aggregated
             FROM pg_proc p
             LEFT JOIN unnest(p.proargtypes) WITH ORDINALITY AS args(t, ord) ON true
             INNER JOIN pg_namespace n ON p.pronamespace = n.oid,
             aclexplode(p.proacl) AS acl
             INNER JOIN pg_roles s ON acl.grantee = s.oid
             WHERE n.nspname='aws_s3' AND s.rolname='routine-grant-role'
             GROUP BY p.oid, p.proname;" 2>/dev/null | sed 's/^/    /' || true
    echo ">>> routine-grant: rows_aggregated should be 1 per function; it equals the arg count."
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    echo ">>> routine-grant: PASS — multi-argument routine grants are observed correctly."
    exit 0
fi

if [ "${ROUTINE_GRANT_INFORMATIONAL:-false}" = true ]; then
    echo ">>> routine-grant: ROUTINE_GRANT_INFORMATIONAL=true — warning only."
    exit 0
fi

echo ">>> routine-grant: FAIL — bug reproduced."
exit 1
