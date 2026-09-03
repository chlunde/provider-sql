#!/usr/bin/env bash
# Convergence, drift and delete checks for issue #440 (Extension.schema).
#
# Gating assertions (fail the run):
#   1. i440-postgis, i440-hstore, i440-trgm reach Ready; i440-nope never does
#      and its Synced message names the missing schema.
#   2. Ground truth from pg_extension/pg_namespace: postgis in gis, hstore in
#      "Mixed Case", pg_trgm in public, ltree absent.
#   3. i440-trgm late-initialises spec.forProvider.schema=public.
#   4. A forced re-reconcile keeps Ready=True with an unchanged transition time.
#   5. Out-of-band ALTER EXTENSION hstore SET SCHEMA public is reverted by
#      Update (relocatable path).
#   6. Patching i440-postgis to schema=public yields Synced=False with the
#      engine's "does not support SET SCHEMA"; patching back recovers Ready.
#   7. Deleting all four leaves no extension behind; the schemas survive.
set -uo pipefail

GVR="extensions.postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"
TIMEOUT="${I440_TIMEOUT:-90s}"
DB=issue440_db
rc=0

psql_db() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d "${DB}" -wtA -c "$1"
}

# Prints the schema an extension is installed in, or nothing.
ext_schema() {
    psql_db "SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = '$1'"
}

fail() { echo ">>> i440: FAIL — $*"; rc=1; }
info() { echo ">>> i440: $*"; }

expect_schema() {
    # $1: extension, $2: expected schema ("" = not installed), $3: context
    local got
    got=$(ext_schema "$1")
    if [ "${got}" = "$2" ]; then
        info "$1 schema='${got}' (${3})"
    else
        fail "$1 schema='${got}', expected '$2' (${3})"
    fi
}

cond() {
    # $1: name, $2: condition type, $3: field
    "${KUBECTL}" get "${GVR}/$1" \
        -o jsonpath="{.status.conditions[?(@.type==\"$2\")].$3}" 2>/dev/null || true
}

wait_ready() {
    if "${KUBECTL}" wait --timeout "${TIMEOUT}" --for condition=Ready "${GVR}/$1" >/dev/null 2>&1; then
        info "$1 is Ready"
        return 0
    fi
    return 1
}

show_status() {
    echo "    Ready.reason=$(cond "$1" Ready reason)"
    echo "    Synced.message=$(cond "$1" Synced message)"
}

poke() {
    "${KUBECTL}" annotate "${GVR}/$1" i440/poke="$(date +%s)" --overwrite >/dev/null
}

# Polls $1 (a command) until its output equals $2, for up to $3 seconds.
until_eq() {
    local i
    for i in $(seq 1 "$3"); do
        if [ "$(eval "$1")" = "$2" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

echo ">>> i440: installed extensions before checks:"
psql_db "SELECT e.extname || ' ' || e.extversion || ' in ' || n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY 1" | sed 's/^/    /'

# --- 1. Ready ---------------------------------------------------------------
for x in i440-postgis i440-hstore i440-trgm; do
    if ! wait_ready "${x}"; then
        fail "${x} did not become Ready within ${TIMEOUT}"
        show_status "${x}"
    fi
done
if "${KUBECTL}" wait --timeout 20s --for condition=Ready "${GVR}/i440-nope" >/dev/null 2>&1; then
    fail "i440-nope became Ready although schema 'nope' does not exist"
else
    msg=$(cond i440-nope Synced message)
    case "${msg}" in
        *'schema "nope" does not exist'*) info "i440-nope rejected: ${msg}" ;;
        *) fail "i440-nope not Ready but Synced.message does not name the schema: ${msg}" ;;
    esac
fi

# --- 2. Ground truth after Create ------------------------------------------
expect_schema postgis "gis"        "created by i440-postgis"
expect_schema hstore  "Mixed Case" "created by i440-hstore"
expect_schema pg_trgm "public"     "created by i440-trgm, no schema in spec"
expect_schema ltree   ""           "i440-nope must not install anywhere"

# --- 3. Late init -----------------------------------------------------------
li=$("${KUBECTL}" get "${GVR}/i440-trgm" -o jsonpath='{.spec.forProvider.schema}' 2>/dev/null)
if [ "${li}" = "public" ]; then
    info "i440-trgm late-initialised schema=public"
else
    fail "i440-trgm spec.forProvider.schema='${li}', expected late-init to public"
fi

# --- 4. Forced re-reconcile must not flip Ready -----------------------------
for x in i440-postgis i440-hstore i440-trgm; do
    before=$(cond "${x}" Ready lastTransitionTime)
    poke "${x}"
    sleep 10
    after=$(cond "${x}" Ready lastTransitionTime)
    if [ "$(cond "${x}" Ready reason)" = "Available" ] && [ "${before}" = "${after}" ]; then
        info "${x} stayed Ready across a forced reconcile (transition ${before})"
    else
        fail "${x} changed state on re-reconcile: reason=$(cond "${x}" Ready reason) before=${before} after=${after}"
    fi
done

# --- 5. Out-of-band drift on a relocatable extension is reverted ------------
psql_db 'ALTER EXTENSION hstore SET SCHEMA public' >/dev/null
expect_schema hstore "public" "moved out of band"
poke i440-hstore
if until_eq 'ext_schema hstore' "Mixed Case" 60; then
    info "hstore moved back to 'Mixed Case' by Update"
else
    fail "hstore still in '$(ext_schema hstore)' 60s after drift; Update did not move it back"
    show_status i440-hstore
fi

# --- 6. Non-relocatable move surfaces the engine error, then recovers -------
"${KUBECTL}" patch "${GVR}/i440-postgis" --type merge \
    -p '{"spec":{"forProvider":{"schema":"public"}}}' >/dev/null
if until_eq 'cond i440-postgis Synced status' "False" 60; then
    msg=$(cond i440-postgis Synced message)
    case "${msg}" in
        *'does not support SET SCHEMA'*) info "i440-postgis schema=public rejected: ${msg}" ;;
        *) fail "i440-postgis Synced=False but message is unexpected: ${msg}" ;;
    esac
else
    fail "i440-postgis stayed Synced after asking for an impossible move"
    show_status i440-postgis
fi
expect_schema postgis "gis" "must not have moved"
"${KUBECTL}" patch "${GVR}/i440-postgis" --type merge \
    -p '{"spec":{"forProvider":{"schema":"gis"}}}' >/dev/null
if until_eq 'cond i440-postgis Synced status' "True" 60 && [ "$(cond i440-postgis Ready status)" = "True" ]; then
    info "i440-postgis recovered after restoring schema=gis"
else
    fail "i440-postgis did not recover after restoring schema=gis"
    show_status i440-postgis
fi

# --- 7. Delete completeness -------------------------------------------------
"${KUBECTL}" delete "${GVR}/i440-postgis" "${GVR}/i440-hstore" "${GVR}/i440-trgm" --timeout=90s >/dev/null 2>&1 \
    || fail "extensions did not delete within 90s"
"${KUBECTL}" delete "${GVR}/i440-nope" --timeout=120s >/dev/null 2>&1 \
    || fail "i440-nope (never created externally) did not delete within 120s"
expect_schema postgis "" "after delete"
expect_schema hstore  "" "after delete"
expect_schema pg_trgm "" "after delete"
left=$(psql_db "SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE nspname IN ('gis','Mixed Case')")
if [ "${left}" = "Mixed Case,gis" ]; then
    info "schemas survive extension deletion"
else
    fail "schemas after delete: '${left}', expected 'Mixed Case,gis'"
fi

if [ "${rc}" -ne 0 ]; then
    echo ">>> i440: FAIL"
    exit 1
fi
echo ">>> i440: PASS"
