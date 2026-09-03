#!/usr/bin/env bash
# Admission-time contract of the widened pattern in PR #436:
#
#   ^[a-zA-Z_][a-zA-Z0-9_$]*(\.[a-zA-Z_][a-zA-Z0-9_$]*)?$
#
# Routine args are spliced into GRANT/REVOKE ... ON ROUTINE unquoted, so this
# pattern is the SQL-injection guard for the field. Every case below is sent
# as a server-side dry run, so nothing is created even if a case unexpectedly
# passes. Rejections must come from the CRD schema, not from a later stage.
set -uo pipefail

APIVERSION="postgresql.sql.${APIGROUP_SUFFIX}crossplane.io/v1alpha1"
rc=0

grant_with_arg() {
    # $1: the arg literal, emitted as a YAML double-quoted scalar with
    # backslashes and double quotes escaped so adversarial input stays inside
    # the scalar instead of breaking the document.
    local esc
    esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cat <<YAML
apiVersion: ${APIVERSION}
kind: Grant
metadata:
  name: pr436-admission-probe
spec:
  forProvider:
    database: pr436_db
    schema: aws_s3
    role: pr436_role
    privileges: [EXECUTE]
    routines:
      - name: table_import_from_s3
        args: ["${esc}"]
  providerConfigRef:
    ${PROVIDERCONFIG_KIND_LINE:-}
    name: default
YAML
}

expect_accept() {
    local arg="$1"
    if out=$(grant_with_arg "${arg}" | "${KUBECTL}" apply --dry-run=server -f - 2>&1); then
        echo ">>> pr436-admission: accepted  ${arg}"
    else
        echo ">>> pr436-admission: FAIL — expected accept for ${arg}"
        echo "${out}" | sed 's/^/    /'
        rc=1
    fi
}

expect_reject() {
    local arg="$1"
    if out=$(grant_with_arg "${arg}" | "${KUBECTL}" apply --dry-run=server -f - 2>&1); then
        echo ">>> pr436-admission: FAIL — expected REJECT for ${arg}, but it was accepted"
        rc=1
    elif echo "${out}" | grep -q 'should match'; then
        echo ">>> pr436-admission: rejected  ${arg}"
    else
        echo ">>> pr436-admission: FAIL — ${arg} was rejected, but not by the pattern:"
        echo "${out}" | sed 's/^/    /'
        rc=1
    fi
}

# Must still accept what worked before the PR.
expect_accept 'text'
expect_accept 'integer'
expect_accept '_underscore_first'
expect_accept 'has$dollar'
# The PR's purpose.
expect_accept 'aws_commons._s3_uri_1'
expect_accept 'AWS_Commons.Cred$V2'

# Exactly one dot, both halves well-formed identifiers.
expect_reject 'a.b.c'
expect_reject '.text'
expect_reject 'text.'
expect_reject 'aws_commons..s3'
expect_reject '1abc.def'
expect_reject 'abc.1def'
expect_reject 'abc.'\''x'\'''
# Injection shapes.
expect_reject 'text); DROP TABLE t; --'
expect_reject 'text) TO PUBLIC; --'
expect_reject 'aws_commons."_s3_uri_1"'
expect_reject '"aws_commons"._s3_uri_1'
expect_reject 'text,text'
expect_reject 'aws_commons. _s3_uri_1'
# Still out of scope for #436 (documented, not a regression).
expect_reject 'text[]'
expect_reject 'character varying'
expect_reject 'aws_commons._s3_uri_1[]'

if [ "${rc}" -ne 0 ]; then
    echo ">>> pr436-admission: FAIL"
    exit 1
fi
echo ">>> pr436-admission: PASS"
