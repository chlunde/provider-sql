#!/usr/bin/env bash
# Gate for MySQL column grants converging. Fails on master: every reconcile
# of colgrant-split issues REVOKE + GRANT because SHOW GRANTS returns the
# merged, reordered form of the spec.
#
# Ground truth comes from information_schema and from the general log, never
# from the Ready condition (Observe sets Available even when out of date).
set -euo pipefail

G="grant.mysql.sql.${APIGROUP_SUFFIX}crossplane.io"
SPLIT="${G}/colgrant-split"
MULTI="${G}/colgrant-multi"

step() { echo ">>> $*"; }
fail() { echo "[FAIL] $*"; exit 1; }
q() { mariadb_sql -e "$1"; }

# Number of statements with the given prefix the provider issued for the user.
stmts() { q "SELECT COUNT(*) FROM mysql.general_log WHERE argument LIKE '$1%colgrant%'"; }
last_grant() { q "SELECT argument FROM mysql.general_log WHERE argument LIKE 'GRANT%colgrant%' ORDER BY event_time DESC LIMIT 1"; }

# Table and column privileges of the user as one sorted, comma-separated line:
# "t SELECT a,t SELECT b,t2 INSERT *"
privs() {
  q "SELECT TABLE_NAME, PRIVILEGE_TYPE, COLUMN_NAME FROM information_schema.COLUMN_PRIVILEGES WHERE GRANTEE = \"'colgrant'@'%'\"
     UNION ALL
     SELECT TABLE_NAME, PRIVILEGE_TYPE, '*' FROM information_schema.TABLE_PRIVILEGES WHERE GRANTEE = \"'colgrant'@'%'\"
     ORDER BY 1, 2, 3" | tr '\t' ' ' | paste -sd, -
}

assert_privs() {
  local got
  got="$(privs)"
  [ "${got}" = "$1" ] || fail "privileges: want [$1] got [${got}]"
  echo "    privileges ok: ${got}"
}

assert_no_revoke() {
  local n
  n="$(stmts REVOKE)"
  [ "${n}" = "0" ] || fail "provider issued ${n} REVOKE statement(s): $(q "SELECT argument FROM mysql.general_log WHERE argument LIKE 'REVOKE%colgrant%'")"
}

poke() {
  "${KUBECTL}" annotate "$1" poke="$(date +%s)" --overwrite >/dev/null
}

# Poke a Grant a few times and require the provider to write nothing.
assert_stable() {
  local before after
  before="$(stmts GRANT)"
  for _ in 1 2 3; do
    poke "$1"
    sleep 5
  done
  sleep 5
  after="$(stmts GRANT)"
  assert_no_revoke
  [ "${before}" = "${after}" ] || fail "$1: ${after} GRANT statements after pokes, ${before} before"
  echo "    $1 stable: ${after} GRANT, 0 REVOKE"
}

step "1. both Grants reach Ready"
"${KUBECTL}" wait --timeout 2m --for condition=Ready "${SPLIT}" "${MULTI}"

step "2. ground truth: split spec is one merged grant, table-wide next to column"
assert_privs "t SELECT a,t SELECT b,t UPDATE a,t UPDATE b,t2 INSERT *,t2 SELECT a,t2 SELECT b,t2 SELECT c"

step "3. re-reconcile issues zero writes"
assert_stable "${SPLIT}"
assert_stable "${MULTI}"

step "4. adding a column grants only that column"
before="$(stmts GRANT)"
"${KUBECTL}" patch "${SPLIT}" --type json \
  -p '[{"op":"add","path":"/spec/forProvider/privileges/-","value":"SELECT (`c`)"}]'
for _ in $(seq 1 24); do
  [ "$(stmts GRANT)" != "${before}" ] && break
  sleep 5
done
assert_no_revoke
[ "$(stmts GRANT)" = "$((before + 1))" ] || fail "want exactly one GRANT for the new column, got $(( $(stmts GRANT) - before ))"
want="GRANT SELECT (\`c\`) ON \`colgrant\`.\`t\` TO 'colgrant'@'%'"
[ "$(last_grant)" = "${want}" ] || fail "want [${want}] got [$(last_grant)]"
sleep 5
assert_privs "t SELECT a,t SELECT b,t SELECT c,t UPDATE a,t UPDATE b,t2 INSERT *,t2 SELECT a,t2 SELECT b,t2 SELECT c"
assert_stable "${SPLIT}"

step "5. delete precision: only the deleted Grant's privileges go"
"${KUBECTL}" delete "${MULTI}" --wait --timeout 2m
assert_privs "t SELECT a,t SELECT b,t SELECT c,t UPDATE a,t UPDATE b"

step "6. delete completeness"
"${KUBECTL}" delete "${SPLIT}" --wait --timeout 2m
assert_privs ""

echo ">>> mariadb-column-grants: all checks passed"
