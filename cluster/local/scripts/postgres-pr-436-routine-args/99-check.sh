#!/usr/bin/env bash
# Convergence and delete checks for PR #436 (schema-qualified routine args).
#
# Gating assertions (fail the run):
#   1. pr436-composite, pr436-nine-text and pr436-mixed-case reach Ready.
#   2. The composite-typed overload is EXECUTE-granted and the nine-text
#      overload is granted through its own Grant only (signature
#      disambiguation on both the write and the read side).
#   3. A forced re-reconcile keeps Ready=True (no Create/Update churn).
#   4. Deleting pr436-composite revokes exactly that overload; the sibling
#      overload's privilege survives.
#   5. Deleting the remaining Grants leaves the role with no EXECUTE on any
#      probed function.
#
# Informational probes (printed, gate only with PR436_STRICT=true):
#   - pr436-public-qualified, pr436-pgcatalog-qualified, pr436-dollar-qualified:
#     format_type() drops the schema for search_path-visible and built-in
#     types and double-quotes names containing "$", so the Observe signature
#     never matches the CR. Expected today: GRANT applied, Ready=False
#     (Creating), and on delete the privilege is orphaned because Observe
#     reports "does not exist" and Delete is skipped. The "$" case predates
#     #436; the qualified cases are newly expressible because of it.
set -uo pipefail

GVR="grants.postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"
TIMEOUT="${PR436_TIMEOUT:-90s}"
STRICT="${PR436_STRICT:-false}"
DB=pr436_db
ROLE=pr436_role
rc=0
warn=0

COMPOSITE='aws_s3.table_import_from_s3(text,text,text,aws_commons._s3_uri_1,aws_commons._aws_credentials_1)'
NINETEXT='aws_s3.table_import_from_s3(text,text,text,text,text,text,text,text,text)'
MIXED='aws_s3.mixed_case(aws_commons.mixed_case_probe)'
DOLLAR='aws_s3.dollar_type(aws_commons.cred$v2)'
PUBLIC_T='public.pr436_public_type(public.pr436_pair)'
PGCAT_T='public.pr436_pgcatalog_type(text)'

psql_db() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d "${DB}" -wtA -c "$1"
}

has_exec() {
    # $1: regprocedure literal. Prints t/f.
    psql_db "SELECT has_function_privilege('${ROLE}', '$1'::regprocedure, 'EXECUTE')"
}

fail() { echo ">>> pr436: FAIL — $*"; rc=1; }
info() { echo ">>> pr436: $*"; }

expect_exec() {
    # $1: regprocedure, $2: t|f, $3: context
    local got
    got=$(has_exec "$1")
    if [ "${got}" = "$2" ]; then
        info "EXECUTE on $1 = ${got} (${3})"
    else
        fail "EXECUTE on $1 = ${got}, expected $2 (${3})"
    fi
}

ready_reason() {
    "${KUBECTL}" get "${GVR}/$1" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true
}

wait_ready() {
    if "${KUBECTL}" wait --timeout "${TIMEOUT}" --for condition=Ready "${GVR}/$1" >/dev/null 2>&1; then
        info "$1 is Ready"
        return 0
    fi
    return 1
}

show_status() {
    echo "    Ready.reason=$(ready_reason "$1")"
    "${KUBECTL}" get "${GVR}/$1" \
        -o jsonpath='{.status.conditions[?(@.type=="Synced")].message}' 2>/dev/null \
        | sed 's/^/    Synced.message=/' || true
    echo
}

echo ">>> pr436: format_type() spellings the Observe query will compare against:"
psql_db "SELECT p.oid::regprocedure::text || '  ->  ' || p.proname || '(' ||
           coalesce((SELECT string_agg(pg_catalog.format_type(a.t, NULL), ',' ORDER BY a.ord)
                     FROM unnest(p.proargtypes) WITH ORDINALITY AS a(t, ord)), '') || ')'
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname IN ('aws_s3','public')
           AND (p.proname IN ('table_import_from_s3','dollar_type','mixed_case') OR p.proname LIKE 'pr436%')
         ORDER BY 1" | sed 's/^/    /'

# --- 1. Ready ---------------------------------------------------------------
for g in pr436-composite pr436-nine-text pr436-mixed-case; do
    if ! wait_ready "${g}"; then
        fail "${g} did not become Ready within ${TIMEOUT}"
        show_status "${g}"
    fi
done

# --- 2. Ground truth after Create ------------------------------------------
expect_exec "${COMPOSITE}" t "granted by pr436-composite"
expect_exec "${NINETEXT}"  t "granted by pr436-nine-text"
expect_exec "${MIXED}"     t "granted by pr436-mixed-case"

# --- 3. Forced re-reconcile must not flip Ready -----------------------------
for g in pr436-composite pr436-mixed-case; do
    before=$("${KUBECTL}" get "${GVR}/${g}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}' 2>/dev/null)
    "${KUBECTL}" annotate "${GVR}/${g}" pr436/poke="$(date +%s)" --overwrite >/dev/null
    sleep 10
    after=$("${KUBECTL}" get "${GVR}/${g}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}' 2>/dev/null)
    if [ "$(ready_reason "${g}")" = "Available" ] && [ "${before}" = "${after}" ]; then
        info "${g} stayed Ready across a forced reconcile (transition ${before})"
    else
        fail "${g} changed state on re-reconcile: reason=$(ready_reason "${g}") before=${before} after=${after}"
    fi
done

# --- 4. Delete precision ----------------------------------------------------
"${KUBECTL}" delete "${GVR}/pr436-composite" --timeout=60s >/dev/null 2>&1 \
    || fail "pr436-composite did not delete within 60s"
expect_exec "${COMPOSITE}" f "after deleting pr436-composite"
expect_exec "${NINETEXT}"  t "sibling overload must survive deleting pr436-composite"
expect_exec "${MIXED}"     t "unrelated grant must survive deleting pr436-composite"

# --- 5. Delete completeness -------------------------------------------------
"${KUBECTL}" delete "${GVR}/pr436-nine-text" "${GVR}/pr436-mixed-case" --timeout=60s >/dev/null 2>&1 \
    || fail "pr436-nine-text / pr436-mixed-case did not delete within 60s"
expect_exec "${NINETEXT}" f "after deleting pr436-nine-text"
expect_exec "${MIXED}"    f "after deleting pr436-mixed-case"

# --- Informational: qualified spellings format_type() renders bare ----------
echo
info "known-limitation probes (PR436_STRICT=${STRICT}):"
for pair in "pr436-public-qualified:${PUBLIC_T}" "pr436-pgcatalog-qualified:${PGCAT_T}" "pr436-dollar-qualified:${DOLLAR}"; do
    g="${pair%%:*}"; fn="${pair#*:}"
    if "${KUBECTL}" wait --timeout 30s --for condition=Ready "${GVR}/${g}" >/dev/null 2>&1; then
        info "  ${g}: Ready (limitation no longer applies)"
    else
        info "  ${g}: NOT Ready, reason=$(ready_reason "${g}"); EXECUTE on ${fn} = $(has_exec "${fn}")"
        warn=1
    fi
    "${KUBECTL}" delete "${GVR}/${g}" --timeout=60s >/dev/null 2>&1 || info "  ${g}: delete timed out"
    info "  ${g}: after delete, EXECUTE on ${fn} = $(has_exec "${fn}")"
done
if [ "${warn}" -eq 1 ]; then
    info "  a spelling format_type() renders differently (bare for public.*/pg_catalog.*,"
    info "  double-quoted for names with \$) never converges and its privilege is orphaned"
    info "  on delete. Set PR436_STRICT=true to turn this into a failure."
    [ "${STRICT}" = true ] && rc=1
fi

if [ "${rc}" -ne 0 ]; then
    echo ">>> pr436: FAIL"
    exit 1
fi
echo ">>> pr436: PASS"
