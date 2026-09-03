#!/usr/bin/env bash
# Checks for PR #442 (Role password loss on restore, issue #441).
#
# Ground truth is "does the published password log in", not "is the
# secret non-empty". Logins go through the Service from inside the
# postgres pod: the e2e port-forward arrives as loopback, which the
# postgres image trusts without a password, so a psql over the
# port-forward proves nothing about the password.
#
# Gating (fail the run):
#   1. Recreate: a Role with managementPolicies minus Delete is deleted
#      together with its connection secret and re-applied while the DB
#      role survives. Its first reconcile takes the Update path with an
#      empty status (#441). It must reach Ready+Synced, publish a
#      password that logs in, and record lastPasswordChange.
#   2. Late failure: a fresh-status password reset whose Update fails
#      after ALTER ROLE PASSWORD (invalid configurationParameters). While
#      it fails, lastPasswordChange must stay unset. Once the spec is
#      fixed the role converges and the published password logs in.
#   3. Trigger rotation: passwordRotationTrigger set to "now" rotates;
#      the new password logs in, the old one is refused.
#   4. Second reconcile: with the trigger in the past a forced reconcile
#      changes neither the password nor Ready.lastTransitionTime.
#   5. Delete: both Roles delete cleanly and the DB roles are gone.
#
# Informational (gate only with PR442_STRICT=true):
#   - After the recreate rotation, does the password rotate again with
#     no trigger within 20s (seen once: cache-lag double rotation)?
#   - A trigger in the future (now+1h, the shape the PR's own e2e uses)
#     rotates on every reconcile until the clock passes it.
set -uo pipefail

GVR="roles.postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"
STRICT="${PR442_STRICT:-false}"
PGPOD=postgresdb-postgresql-0
PGSVC=postgresdb-postgresql.default.svc.cluster.local
rc=0
warn=0

fail() { echo ">>> pr442: FAIL — $*"; rc=1; }
info() { echo ">>> pr442: $*"; }
soft() {
    if [ "${STRICT}" = "true" ]; then fail "$*"; else echo ">>> pr442: WARN — $*"; warn=1; fi
}

# --- helpers ---------------------------------------------------------------

apply_role() {
    # $1 name, $2 extra forProvider lines (indented 4), $3 extra spec lines (indented 2)
    local name=$1 fp=${2:-} spec=${3:-} ns_line="" secret_ns=""
    if [ "${API_TYPE}" = "namespaced" ]; then
        ns_line="  namespace: default"
    else
        secret_ns="    namespace: default"
    fi
    "${KUBECTL}" apply -f - <<EOF
apiVersion: postgresql.sql.${APIGROUP_SUFFIX}crossplane.io/v1alpha1
kind: Role
metadata:
  name: ${name}
${ns_line}
spec:
  forProvider:
    privileges:
      login: true
${fp}
  writeConnectionSecretToRef:
    name: ${name}-secret
${secret_ns}
  providerConfigRef:
    ${PROVIDERCONFIG_KIND_LINE}
    name: default
${spec}
EOF
}

secret_pw() {
    "${KUBECTL}" get secret "$1-secret" -n default -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode
}

can_login() {
    # $1 role, $2 password. Prints t/f. Runs inside the pod, via the
    # Service address, so pg_hba applies scram (not loopback trust).
    if "${KUBECTL}" exec -n default "${PGPOD}" -- env PGPASSWORD="$2" \
        psql -h "${PGSVC}" -U "$1" -d postgres -wtA -c 'select 1' >/dev/null 2>&1; then
        echo t
    else
        echo f
    fi
}

psql_root() {
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" -d postgres -wtA -c "$1"
}
role_exists() { psql_root "select count(*) from pg_roles where rolname='$1'"; }
pw_hash() {
    # SCRAM verifier gets a new salt on every ALTER ROLE ... PASSWORD, so
    # this changes on each rotation even if the password did not.
    psql_root "select md5(rolpassword) from pg_authid where rolname='$1'"
}

cond() { # $1 role, $2 type, $3 field
    "${KUBECTL}" get "${GVR}/$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].$3}" 2>/dev/null || true
}
last_change() {
    "${KUBECTL}" get "${GVR}/$1" -o jsonpath='{.status.atProvider.lastPasswordChange}' 2>/dev/null || true
}
poke() {
    "${KUBECTL}" annotate "${GVR}/$1" pr442/poke="$(date +%s)-${RANDOM}" --overwrite >/dev/null
}
update_events() {
    # Count of "Successfully requested update" events for the role.
    "${KUBECTL}" get events -n default --field-selector "involvedObject.name=$1,reason=UpdatedExternalResource" \
        -o jsonpath='{.items[*].count}' 2>/dev/null | tr ' ' '+' | sed 's/^$/0/' | bc
}

wait_synced_ready() {
    # Ready is set from Observe even when Update fails, so gate on Synced too.
    local i
    for i in $(seq 1 60); do
        if [ "$(cond "$1" Ready status)" = "True" ] && [ "$(cond "$1" Synced status)" = "True" ]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_pw_changed() {
    # $1 role, $2 previous. Waits for a non-empty, different password.
    local i cur
    for i in $(seq 1 45); do
        cur=$(secret_pw "$1")
        if [ -n "${cur}" ] && [ "${cur}" != "$2" ]; then return 0; fi
        sleep 2
    done
    return 1
}

expect_login() { # $1 role, $2 pw, $3 t|f, $4 context
    local got
    got=$(can_login "$1" "$2")
    if [ "${got}" = "$3" ]; then
        info "login as $1 = ${got} ($4)"
    else
        fail "login as $1 = ${got}, expected $3 ($4)"
    fi
}

show() {
    echo "    Ready=$(cond "$1" Ready status)/$(cond "$1" Ready reason) Synced=$(cond "$1" Synced status)"
    echo "    Synced.message=$(cond "$1" Synced message)"
    echo "    lastPasswordChange=$(last_change "$1") updateEvents=$(update_events "$1")"
}

"${KUBECTL}" delete secret pr442-fresh-secret pr442-fail-secret -n default --ignore-not-found >/dev/null

# --- 0. Sanity: the login check must be able to fail ------------------------
psql_root "create role pr442_probe login password 'right'" >/dev/null
if [ "$(can_login pr442_probe wrong)" != "f" ] || [ "$(can_login pr442_probe right)" != "t" ]; then
    fail "login probe is not password-sensitive; every login assertion below is void"
fi
psql_root "drop role pr442_probe" >/dev/null

# --- 1. Recreate with empty status (#441) -----------------------------------
info "1. create pr442-fresh (managementPolicies without Delete)"
apply_role pr442-fresh "" '  managementPolicies: ["Observe", "Create", "Update", "LateInitialize"]'
if ! wait_synced_ready pr442-fresh; then
    fail "pr442-fresh did not reach Ready+Synced after create"; show pr442-fresh
fi
pw0=$(secret_pw pr442-fresh)
expect_login pr442-fresh "${pw0}" t "password from Create"
info "lastPasswordChange after Create = '$(last_change pr442-fresh)' (expected empty on this branch)"
h0=$(pw_hash pr442-fresh)

info "1. delete Role object + connection secret, keep DB role, re-apply"
"${KUBECTL}" delete "${GVR}/pr442-fresh" --timeout=60s
"${KUBECTL}" delete secret pr442-fresh-secret -n default --ignore-not-found >/dev/null
if [ "$(role_exists pr442-fresh)" != "1" ]; then
    fail "DB role pr442-fresh was dropped despite managementPolicies excluding Delete"
fi
apply_role pr442-fresh "" '  managementPolicies: ["Observe", "Create", "Update", "LateInitialize"]'
if ! wait_synced_ready pr442-fresh; then
    fail "pr442-fresh did not reach Ready+Synced after recreate"; show pr442-fresh
fi
if ! wait_pw_changed pr442-fresh "${pw0}"; then
    fail "pr442-fresh connection secret not republished after recreate (#441)"; show pr442-fresh
fi
pw1=$(secret_pw pr442-fresh)
lc1=$(last_change pr442-fresh)
expect_login pr442-fresh "${pw1}" t "password regenerated on recreate"
expect_login pr442-fresh "${pw0}" f "old password after recreate"
if [ -z "${lc1}" ]; then
    fail "pr442-fresh lastPasswordChange unset after recreate"
else
    info "pr442-fresh lastPasswordChange=${lc1}"
fi
"${KUBECTL}" get events -n default --field-selector involvedObject.name=pr442-fresh -o custom-columns=MSG:.message --no-headers 2>/dev/null \
    | grep -i 'compare desired' | sed 's/^/    event: /' && fail "errComparePrivileges surfaced in events"

info "1. probe: extra rotations with no trigger in the 20s after the recreate rotation"
sleep 20
pw1b=$(secret_pw pr442-fresh)
lc1b=$(last_change pr442-fresh)
h1=$(pw_hash pr442-fresh)
info "    hash before recreate=${h0:0:8} after=${h1:0:8} secret=${pw1:0:4}…->${pw1b:0:4}… last=${lc1}->${lc1b} updateEvents=$(update_events pr442-fresh)"
if [ "${pw1b}" != "${pw1}" ] || [ "${lc1b}" != "${lc1}" ]; then
    soft "pr442-fresh rotated again with no trigger after the recreate rotation"
    "${KUBECTL}" get events -n default --field-selector involvedObject.name=pr442-fresh \
        -o custom-columns=T:.lastTimestamp,N:.count,R:.reason,MSG:.message --no-headers 2>/dev/null | sed 's/^/    /'
fi
if ! wait_synced_ready pr442-fresh; then fail "pr442-fresh not Ready+Synced after settle"; show pr442-fresh; fi
pw1=$(secret_pw pr442-fresh)
expect_login pr442-fresh "${pw1}" t "settled password after recreate"

# --- 2. Update fails after the password was changed ------------------------
info "2. create pr442-fail, then reset its password with a spec whose Update fails late"
apply_role pr442-fail ""
if ! wait_synced_ready pr442-fail; then
    fail "pr442-fail did not reach Ready+Synced after create"; show pr442-fail
fi
fpw0=$(secret_pw pr442-fail)
fh0=$(pw_hash pr442-fail)
# Deleting the secret arms shouldResetPassword (lastPasswordChange is nil);
# the bogus parameter makes the configurationParameters step fail after
# ALTER ROLE ... PASSWORD has already run.
"${KUBECTL}" delete secret pr442-fail-secret -n default
apply_role pr442-fail '    configurationParameters:
      - name: bogus_param
        value: "1"'
poke pr442-fail
for i in $(seq 1 30); do
    [ "$(cond pr442-fail Synced status)" = "False" ] && break
    sleep 2
done
show pr442-fail
if [ "$(cond pr442-fail Synced status)" != "False" ]; then
    fail "pr442-fail did not report an Update failure for bogus_param"
fi
if [ "$(pw_hash pr442-fail)" = "${fh0}" ]; then
    fail "pr442-fail password hash unchanged: ALTER ROLE PASSWORD did not run before the failing step"
fi
expect_login pr442-fail "${fpw0}" f "old password after failed Update (ALTER PASSWORD ran)"
if [ -n "$(last_change pr442-fail)" ]; then
    fail "pr442-fail lastPasswordChange=$(last_change pr442-fail) stamped although Update failed (#441)"
else
    info "pr442-fail lastPasswordChange stays unset while Update fails"
fi
if [ -n "$(secret_pw pr442-fail)" ]; then
    fail "pr442-fail secret published although Update failed"
fi

info "2. fix the spec, expect convergence and a working password"
apply_role pr442-fail '    configurationParameters:
      - name: statement_timeout
        value: "5s"'
poke pr442-fail
if ! wait_synced_ready pr442-fail; then
    fail "pr442-fail did not converge after fixing the spec"; show pr442-fail
fi
if ! wait_pw_changed pr442-fail ""; then
    fail "pr442-fail secret never repopulated after fix (stranded password, #441)"; show pr442-fail
fi
fpw1=$(secret_pw pr442-fail)
expect_login pr442-fail "${fpw1}" t "password after recovery"
[ -n "$(last_change pr442-fail)" ] || fail "pr442-fail lastPasswordChange unset after recovery"

# --- 3. Trigger rotation ---------------------------------------------------
info "3. passwordRotationTrigger = now on pr442-fresh"
sleep 2   # trigger must be strictly after lastPasswordChange (second precision)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"${KUBECTL}" patch "${GVR}/pr442-fresh" --type merge \
    -p "{\"spec\":{\"forProvider\":{\"passwordRotationTrigger\":\"${now}\"}}}" >/dev/null
if ! wait_pw_changed pr442-fresh "${pw1}"; then
    fail "pr442-fresh did not rotate on passwordRotationTrigger"; show pr442-fresh
fi
pw2=$(secret_pw pr442-fresh)
expect_login pr442-fresh "${pw2}" t "password after trigger rotation"
expect_login pr442-fresh "${pw1}" f "previous password after trigger rotation"
info "lastPasswordChange after trigger=${now}: $(last_change pr442-fresh)"

# --- 4. Second reconcile is a no-op ----------------------------------------
info "4. forced reconcile with trigger in the past"
if ! wait_synced_ready pr442-fresh; then fail "pr442-fresh not Ready+Synced before poke"; fi
sleep 5
pw2=$(secret_pw pr442-fresh)
h2=$(pw_hash pr442-fresh)
before=$(cond pr442-fresh Ready lastTransitionTime)
ev_before=$(update_events pr442-fresh)
poke pr442-fresh; sleep 12
after=$(cond pr442-fresh Ready lastTransitionTime)
if [ "$(secret_pw pr442-fresh)" != "${pw2}" ] || [ "$(pw_hash pr442-fresh)" != "${h2}" ]; then
    fail "pr442-fresh password changed on a no-op reconcile (last=$(last_change pr442-fresh) trigger=${now})"
elif [ "${before}" != "${after}" ] || [ "$(cond pr442-fresh Ready reason)" != "Available" ]; then
    fail "pr442-fresh flipped Ready on re-reconcile: before=${before} after=${after}"
else
    info "pr442-fresh password and Ready stable across a forced reconcile"
fi
info "    update events before=${ev_before} after=$(update_events pr442-fresh) (Update runs on a no-op reconcile if these differ)"

# --- 5. Informational: future-dated trigger ---------------------------------
info "5. probe: trigger in the future (now+1h)"
future=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
"${KUBECTL}" patch "${GVR}/pr442-fresh" --type merge \
    -p "{\"spec\":{\"forProvider\":{\"passwordRotationTrigger\":\"${future}\"}}}" >/dev/null
if wait_pw_changed pr442-fresh "${pw2}"; then
    sleep 5
    pw3=$(secret_pw pr442-fresh)
    poke pr442-fresh; sleep 12
    pw4=$(secret_pw pr442-fresh)
    if [ "${pw4}" != "${pw3}" ]; then
        soft "future-dated trigger rotates on every reconcile (${pw3:0:4}… -> ${pw4:0:4}…); docs say 'later than lastPasswordChange'"
    else
        info "future-dated trigger rotated once only"
    fi
    expect_login pr442-fresh "$(secret_pw pr442-fresh)" t "password after future-trigger churn probe"
else
    fail "future-dated trigger did not rotate at all"
fi
# stop the churn before delete
"${KUBECTL}" patch "${GVR}/pr442-fresh" --type merge \
    -p '{"spec":{"forProvider":{"passwordRotationTrigger":null}}}' >/dev/null

# --- 6. Delete -------------------------------------------------------------
info "6. delete both Roles"
"${KUBECTL}" patch "${GVR}/pr442-fresh" --type merge -p '{"spec":{"managementPolicies":["*"]}}' >/dev/null
"${KUBECTL}" delete "${GVR}/pr442-fresh" "${GVR}/pr442-fail" --timeout=120s
for r in pr442-fresh pr442-fail; do
    if [ "$(role_exists "${r}")" != "0" ]; then fail "DB role ${r} survived delete"; else info "DB role ${r} dropped"; fi
done

echo
if [ "${rc}" -ne 0 ]; then
    echo ">>> pr442: FAILED"
    exit 1
fi
[ "${warn}" -ne 0 ] && echo ">>> pr442: passed with warnings"
echo ">>> pr442: PASSED"
