#!/usr/bin/env bash
# Verify the reproducer state for issue #240.
#
# This script does NOT fail the e2e run — the bug is the expected outcome.
# It just prints whether the Grant became Ready within a short window.
set -u

NAME="issue-240-grant"
GVR="grants.postgresql.sql.${APIGROUP_SUFFIX}crossplane.io"

echo ">>> issue-240: waiting up to 30s for ${NAME} (${GVR}) to become Ready"

if "${KUBECTL}" wait --timeout 30s --for condition=Ready "${GVR}/${NAME}" >/dev/null 2>&1; then
    echo ">>> issue-240: Grant is Ready — bug appears to be FIXED."
else
    status=$("${KUBECTL}" get "${GVR}/${NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    echo ">>> issue-240: Grant did NOT become Ready (reason=${status:-unknown}) — bug REPRODUCED."
    echo ">>> issue-240: inspect with:"
    echo "    kubectl get ${GVR}/${NAME} -o jsonpath='{.status.conditions}' | jq ."
fi
