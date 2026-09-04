#!/usr/bin/env bash
set -e

# setting up colors
BLU='\033[0;34m'
YLW='\033[0;33m'
GRN='\033[0;32m'
RED='\033[0;31m'
NOC='\033[0m' # No Color
echo_info() {
    printf "\n${BLU}%s${NOC}" "$1"
}
echo_step() {
    printf "\n${BLU}>>>>>>> %s${NOC}\n" "$1"
}
echo_sub_step() {
    printf "\n${BLU}>>> %s${NOC}\n" "$1"
}

echo_step_completed() {
    printf "${GRN} [✔]${NOC}"
}

echo_success() {
    printf "\n${GRN}%s${NOC}\n" "$1"
}
echo_warn() {
    printf "\n${YLW}%s${NOC}" "$1"
}
echo_error() {
    printf "\n${RED}%s${NOC}" "$1"
    exit 1
}

# ------------------------------
projectdir="$( cd "$( dirname "${BASH_SOURCE[0]}")"/../.. && pwd )"
scriptdir="$(dirname "$0")"

# get the build environment variables from the special build.vars target in the main makefile
eval $(make --no-print-directory -C ${projectdir} build.vars)

# ------------------------------

SAFEHOSTARCH="${SAFEHOSTARCH:-amd64}"
CONTROLLER_IMAGE="${BUILD_REGISTRY}/${PROJECT_NAME}-${SAFEHOSTARCH}"

K8S_CLUSTER="${K8S_CLUSTER:-${BUILD_REGISTRY}-inttests}"

PACKAGE_NAME="provider-sql"
# Image of the sidecar that serves the locally built package to Crossplane.
SIDECAR_IMAGE="alpine"
MARIADB_ROOT_PW=$(openssl rand -base64 32)
MARIADB_TEST_PW=$(openssl rand -base64 32)
MSSQL_SA_PW="$(openssl rand -base64 16)Aa1!"  # MSSQL requires complex password

# Keep the cluster between runs and prune it instead of recreating it.
# Local iteration only; see setup_cluster.
REUSE_CLUSTER="${REUSE_CLUSTER:-false}"

# Own kubeconfig for the run, inherited by kubectl, helm and the make
# targets. Without it the run follows whatever the current context happens
# to be, and anything that creates a cluster while it runs (another kind
# cluster, a context switch in another shell) redirects it mid-flight.
export KUBECONFIG="${TMPDIR:-/tmp}/kubeconfig-${K8S_CLUSTER}"
echo_info "using kubeconfig ${KUBECONFIG}"

# cleanup on exit
if [ "$skipcleanup" != true ] && [ "${REUSE_CLUSTER}" != true ]; then
  function cleanup {
    echo_step "Cleaning up..."
    cleanup_cluster
    rm -f "${KUBECONFIG}"
  }

  trap cleanup EXIT
fi

# Global variable to control API type
API_TYPE="cluster"

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
# shellcheck source="$SCRIPT_DIR/postgresdb_functions.sh"
source "$SCRIPT_DIR/postgresdb_functions.sh"
if [ $? -ne 0 ]; then
  echo "postgresdb_functions.sh failed. Exiting."
  exit 1
fi

# shellcheck source="$SCRIPT_DIR/mssqldb_functions.sh"
source "$SCRIPT_DIR/mssqldb_functions.sh"
if [ $? -ne 0 ]; then
  echo "mssqldb_functions.sh failed. Exiting."
  exit 1
fi

# delete_provider_config <api group>: remove a pass's ProviderConfig.
#
# A ProviderConfig carries an in-use finalizer that the provider removes
# once no ProviderConfigUsage refers to it. Those usages are owned by the
# managed resources and are collected by the kube garbage collector, which
# only reacts to owners whose kind it has already discovered. On the first
# pass the provider's CRDs are seconds old, so the collector misses the
# deletion and only notices on its next discovery resync: the first
# ProviderConfig of a run took ~20s to delete, every later one under 1s.
# Deleting the usages here makes it immediate, and asserts they are gone
# rather than trusting the collector's timing.
delete_provider_config() {
  local group=$1
  "${KUBECTL}" delete "providerconfigusages.${group}" --all -A --ignore-not-found > /dev/null
  "${KUBECTL}" delete "providerconfigs.${group}" default --ignore-not-found
}

# Belt and braces: every pass deletes its own ProviderConfig, so by the end
# there must be none left.
PROVIDER_CONFIG_KINDS="providerconfigs.mysql.sql.crossplane.io,providerconfigs.mysql.sql.m.crossplane.io,providerconfigs.postgresql.sql.crossplane.io,providerconfigs.postgresql.sql.m.crossplane.io,providerconfigs.mssql.sql.crossplane.io,providerconfigs.mssql.sql.m.crossplane.io"

wait_provider_configs_gone() {
  echo_step "checking all ProviderConfigs were deleted"
  local i left
  for i in $(seq 1 120); do
    left=$("${KUBECTL}" get "${PROVIDER_CONFIG_KINDS}" -A -o name 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "${left}" = "0" ]; then
      echo_step_completed
      return 0
    fi
    sleep 1
  done
  "${KUBECTL}" get "${PROVIDER_CONFIG_KINDS}" -A
  echo_error "ProviderConfigs were not deleted"
}

integration_tests_end() {
  echo_step "--- CLEAN-UP ---"
  wait_provider_configs_gone
  if [ "${REUSE_CLUSTER}" = true ]; then
    echo_step "REUSE_CLUSTER=true: leaving the cluster up for the next run"
    echo_success " All integration tests succeeded!"
    return
  fi
  cleanup_provider
  echo_success " All integration tests succeeded!"
}

# Get every image the run needs onto the node before the workload that
# wants it starts, in the background and in the order the run needs them.
#
#   on the host already -> kind load (no network at all)
#   not on the host     -> pull it early instead of letting the kubelet
#                          pull it on the critical path. Locally we pull
#                          into the host cache so the next run can load it;
#                          in CI the cache is cold every time, so we pull
#                          straight into the node's containerd.
#
# Nothing here is required for correctness: if a pull fails the kubelet
# still pulls the image itself, exactly as before.
PRELOAD_DIR="$(mktemp -d)"
preload_marker() { echo "${PRELOAD_DIR}/$(echo "$1" | tr '/:@' '___')"; }
preload_images() {
  (
    local img
    for img in "$@"; do
      if ! docker image inspect "${img}" >/dev/null 2>&1; then
        if [ -n "${CI:-}" ]; then
          docker exec "${K8S_CLUSTER}-control-plane" crictl pull "${img}" >/dev/null 2>&1
          touch "$(preload_marker "${img}")"
          continue
        fi
        docker pull "${img}" >/dev/null 2>&1
      fi
      "${KIND}" load docker-image "${img}" --name "${K8S_CLUSTER}" >/dev/null 2>&1 \
        || echo_warn "could not preload ${img}; the node will pull it"
      touch "$(preload_marker "${img}")"
    done
  ) &
  PRELOAD_PID=$!
}

wait_image() {
  local marker
  marker="$(preload_marker "$1")"
  while [ ! -e "${marker}" ] && kill -0 "${PRELOAD_PID:-0}" 2>/dev/null; do
    sleep 1
  done
}

# The background MariaDB start-up logs to a file so its output does not
# interleave with the provider install; replay it when we join.
PRESTART_LOG="$(mktemp)"
wait_prestart() {
  local rc=0
  wait "${PRESTART_PID}" || rc=$?
  cat "${PRESTART_LOG}"
  if [ "${rc}" -ne 0 ]; then
    echo_error "starting MariaDB in the background failed (exit ${rc})"
  fi
}

# wait_until <seconds> <condition>: poll a shell condition once a second.
wait_until() {
  local deadline=$1 cond=$2 i
  for i in $(seq 1 "${deadline}"); do
    if eval "${cond}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# wait_reconciled <resource>: block until the Synced condition carries the
# current spec generation, i.e. the provider has processed the latest patch.
wait_reconciled() {
  local res=$1 gen seen i
  gen=$("${KUBECTL}" get "${res}" -o jsonpath='{.metadata.generation}')
  for i in $(seq 1 60); do
    seen=$("${KUBECTL}" get "${res}" -o jsonpath='{.status.conditions[?(@.type=="Synced")].observedGeneration}')
    if [ "${seen}" = "${gen}" ]; then
      return 0
    fi
    sleep 1
  done
  echo_error "timeout waiting for ${res} generation ${gen} to be reconciled (observed ${seen})"
}

setup_cluster() {
  local node_image="kindest/node:${KIND_NODE_IMAGE_TAG}"

  # REUSE_CLUSTER keeps the cluster (and Crossplane) between runs and
  # prunes what the previous run left behind. Creating the cluster and
  # installing Crossplane is ~40s of a run that is otherwise ~80s. It is
  # for local iteration only: CI always wants a cluster nothing has
  # touched, and a run that died mid-way can leave state a prune cannot
  # reason about.
  if [ "${REUSE_CLUSTER}" = true ] && "${KIND}" get clusters 2>/dev/null | grep -qx "${K8S_CLUSTER}"; then
    echo_step "reusing existing cluster ${K8S_CLUSTER}"
    "${KIND}" export kubeconfig --name "${K8S_CLUSTER}" --kubeconfig "${KUBECONFIG}" > /dev/null
    prune_cluster
    return
  fi

  # Derive a node image with the CNI config already in place; see
  # Dockerfile.node. Everything but the last layer is the stock image, so
  # this is a few hundred milliseconds once the base has been pulled.
  local e2e_image="provider-sql-e2e/node:${KIND_NODE_IMAGE_TAG}"
  if docker build --quiet --build-arg "BASE=${node_image}" \
      -t "${e2e_image}" -f "${SCRIPT_DIR}/Dockerfile.node" "${SCRIPT_DIR}" > /dev/null 2>&1; then
    node_image="${e2e_image}"
  else
    echo_warn "could not build the pre-seeded node image; using ${node_image}"
  fi

  echo_step "creating k8s cluster using kind ${KIND_VERSION} and node image ${node_image}"

  "${KIND}" create cluster --name="${K8S_CLUSTER}" --wait=5m --image="${node_image}" \
    --config "${SCRIPT_DIR}/kind.yaml" --kubeconfig "${KUBECONFIG}"

  # With the CNI config pre-seeded the node reports Ready before the rest
  # of the control plane has caught up, so kind returns earlier than it
  # used to. Nothing can be scheduled until the default ServiceAccount
  # exists, so wait for that here. DNS is only needed once the provider
  # dials a database server, so that wait lives in wait_dns_ready.
  echo_step "waiting for the cluster to accept workloads"
  local i
  for i in $(seq 1 480); do
    "${KUBECTL}" -n default get serviceaccount default > /dev/null 2>&1 && break
    sleep 0.25
  done
  "${KUBECTL}" -n default get serviceaccount default > /dev/null \
    || echo_error "the default ServiceAccount never appeared"
  echo_step_completed
}

# The provider reaches its database servers by Service DNS, so CoreDNS has
# to be serving before the first pass. By this point in the run it always
# is; this only guards against the pre-seeded node image letting the run
# get ahead of the control plane.
wait_dns_ready() {
  local i
  for i in $(seq 1 480); do
    "${KUBECTL}" -n kube-system get deployment coredns > /dev/null 2>&1 && break
    sleep 0.25
  done
  "${KUBECTL}" -n kube-system rollout status deployment/coredns --timeout=180s > /dev/null \
    || echo_error "CoreDNS did not become available"
}

# Delete everything a previous run may have left in a reused cluster:
# managed resources first (their finalizers need the provider, which is
# still installed at this point), then the ProviderConfigs, then the
# database servers and the secrets the tests create.
prune_cluster() {
  echo_step "pruning leftovers from the previous run"

  local kinds
  kinds=$("${KUBECTL}" get crd -o name 2>/dev/null \
    | sed 's|customresourcedefinition.apiextensions.k8s.io/||' \
    | grep -E '\.sql\.(m\.)?crossplane\.io$' \
    | grep -v '^providerconfig' | paste -sd, -)
  if [ -n "${kinds}" ]; then
    "${KUBECTL}" delete "${kinds}" --all -A --ignore-not-found --timeout=120s > /dev/null
  fi
  "${KUBECTL}" delete "${PROVIDER_CONFIG_KINDS}" --all -A --ignore-not-found --timeout=120s > /dev/null 2>&1

  "${KUBECTL}" -n default delete statefulset,service,configmap,secret \
      -l e2e.provider-sql/managed=true --ignore-not-found > /dev/null 2>&1
  "${KUBECTL}" -n default delete statefulset mariadb mssql postgresdb-postgresql --ignore-not-found > /dev/null
  "${KUBECTL}" -n default delete service mariadb mssql postgresdb-postgresql --ignore-not-found > /dev/null
  "${KUBECTL}" -n default delete configmap mariadb-init-script --ignore-not-found > /dev/null
  "${KUBECTL}" -n default delete secret mariadb-creds mariadb-server-tls mariadb-client-tls \
      mssql-creds postgresdb-creds example-pw example-connection-secret shared-login-pw \
      --ignore-not-found > /dev/null
  "${KUBECTL}" -n default delete pvc --all --ignore-not-found > /dev/null

  # A previous run's provider is removed here, not reused: the local
  # package digest is fixed, so Crossplane would keep serving the old
  # revision even after the image was rebuilt.
  "${KUBECTL}" delete provider.pkg.crossplane.io "${PACKAGE_NAME}" --ignore-not-found --timeout=120s > /dev/null
  "${KUBECTL}" delete deploymentruntimeconfig.pkg.crossplane.io "runtimeconfig-${PACKAGE_NAME}" \
      --ignore-not-found > /dev/null
  echo_step_completed
}

cleanup_cluster() {
  "${KIND}" delete cluster --name="${K8S_CLUSTER}"
}

setup_crossplane() {
  local channel="${CROSSPLANE_HELM_CHANNEL:-stable}"
  echo_step "installing crossplane from ${channel} channel"

  "${HELM}" repo add crossplane-channel "https://charts.crossplane.io/${channel}/" --force-update

  local chart_version="${CROSSPLANE_HELM_CHART_VERSION:-}"
  if [ -z "${chart_version}" ]; then
    chart_version="$("${HELM}" search repo crossplane-channel/crossplane | awk 'FNR == 2 {print $2}')"
  fi
  echo_info "using crossplane version ${chart_version}"
  echo

  MARIADB_IMAGE="$(awk '/image:/ {print $2}' "${scriptdir}/mariadb.tls.server.yaml")"
  POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:${POSTGRES_VERSION:-18}}"
  # In the order the run needs them. The crossplane chart's appVersion
  # tracks its chart version, so no extra `helm show chart` round trip.
  local images=("xpkg.crossplane.io/crossplane/crossplane:v${chart_version}" "${SIDECAR_IMAGE}")
  # Locally built, so only loadable, never pullable.
  if docker image inspect "${CONTROLLER_IMAGE}" >/dev/null 2>&1; then
    images+=("${CONTROLLER_IMAGE}")
  fi
  preload_images "${images[@]}" "${MARIADB_IMAGE}" "${POSTGRES_IMAGE}" "${MSSQL_IMAGE}"

  if [ "${REUSE_CLUSTER}" = true ] && "${HELM}" status crossplane -n crossplane-system > /dev/null 2>&1; then
    echo_info "crossplane is already installed; keeping it"
    "${KUBECTL}" -n crossplane-system wait pods -l app=crossplane,patched=true \
      --for condition=Ready --timeout=180s
    return
  fi

  # The dev sidecar (which serves the locally built package to Crossplane)
  # is declared here rather than patched in afterwards by local.xpkg.init:
  # patching rolls the deployment out a second time. local.xpkg.init sees
  # the container and skips its patch, and local.xpkg.sync finds the pod by
  # the "patched" label, which customLabels supplies.
  #
  # No --wait either: we wait for the one pod those two targets need.
  # The chart's default limits.cpu of 500m caps Crossplane at half a core
  # for start-up work that is one-off and CPU-bound: generating
  # certificates, decoding 1MB of core CRDs, then parsing our package and
  # establishing 39 more. (The chart also derives GOMAXPROCS from that
  # limit, which is the right setting for the quota - the quota is what
  # binds.) The rbac-manager's 100m matters too: a provider cannot
  # authenticate until it has created the revision's ClusterRoleBinding.
  # Raising limits does not change requests, so scheduling on the single
  # node is unaffected.
  #
  # webhooks: nothing here has a conversion or admission webhook, and the
  # one shipped webhook only matches objects labelled crossplane.io/in-use.
  # leader election: pointless at one replica.
  "${HELM}" install crossplane --namespace crossplane-system --create-namespace \
    crossplane-channel/crossplane \
    --version "${chart_version}" \
    --set-string customLabels.patched=true \
    --set "resourcesCrossplane.limits.cpu=${CROSSPLANE_CPU_LIMIT:-4}" \
    --set "resourcesRBACManager.limits.cpu=${RBAC_MANAGER_CPU_LIMIT:-2}" \
    --set webhooks.enabled=false \
    --set leaderElection=false \
    --set rbacManager.leaderElection=false \
    --set-json 'args=["--max-concurrent-package-establishers=40"]' \
    --set-json "sidecarsCrossplane=[{\"name\":\"dev\",\"image\":\"${SIDECAR_IMAGE}\",\"command\":[\"sleep\",\"infinity\"],\"volumeMounts\":[{\"mountPath\":\"/tmp/cache\",\"name\":\"package-cache\"}]}]"

  echo_step "waiting for crossplane to be ready"
  "${KUBECTL}" -n crossplane-system wait pods -l app=crossplane,patched=true \
    --for condition=Ready --timeout=180s
}

setup_provider() {
  echo_step "deploying provider via local.xpkg.deploy"
  # The package has no dependencies; resolving them costs Lock round trips.
  make -C "${projectdir}" local.xpkg.deploy.provider.${PACKAGE_NAME} KIND_CLUSTER_NAME="${K8S_CLUSTER}" \
    DRC_FILE="${SCRIPT_DIR}/runtimeconfig.yaml" XPKG_SKIP_DEP_RESOLUTION=true

  echo_step "waiting for provider to be installed"
  "${KUBECTL}" wait "provider.pkg.crossplane.io/${PACKAGE_NAME}" --for=condition=healthy --timeout=60s
}

cleanup_provider() {
  echo_step "uninstalling provider"

  "${KUBECTL}" delete provider.pkg.crossplane.io "${PACKAGE_NAME}"
  "${KUBECTL}" delete deploymentruntimeconfig.pkg.crossplane.io runtimeconfig-${PACKAGE_NAME}

  # Poll twice a second: the revision usually goes within a second of the
  # Provider, and the old 3s step rounded that up to 3.
  echo_step "waiting for provider pods to be deleted"
  local i
  for i in $(seq 1 120); do
    if [ "$("${KUBECTL}" get providerrevision.pkg.crossplane.io -o name | wc -l | tr -d '[:space:]')" = "0" ]; then
      return 0
    fi
    sleep 0.5
  done
  echo_error "timeout of 60s has been reached waiting for provider revisions to go"
}

setup_tls_certs() {
  echo_step "generating CA key and certificate"
  openssl genrsa -out ca-key.pem 2048
  openssl req -new -x509 -key ca-key.pem -out ca-cert.pem -days 365 -subj "/CN=CA"

  echo_step "generating server key and certificate"
  openssl genrsa -out server-key.pem 2048
  openssl req -new -key server-key.pem -out server-req.pem -subj "/CN=mariadb.default.svc.cluster.local"
  openssl x509 -req -in server-req.pem -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem -days 365

  echo_step "generating client key and certificate"
  openssl genrsa -out client-key.pem 2048
  openssl req -new -key client-key.pem -out client-req.pem -subj "/CN=client"
  openssl x509 -req -in client-req.pem -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out client-cert.pem -days 365

  echo_step "creating secret for the TLS certificates and keys"
  "${KUBECTL}" create secret generic mariadb-server-tls \
      --from-file=ca-cert.pem \
      --from-file=server-cert.pem \
      --from-file=server-key.pem

  echo_step "creating secret for the client TLS certificates and keys"
  "${KUBECTL}" create secret generic mariadb-client-tls \
      --from-file=ca-cert.pem \
      --from-file=client-cert.pem \
      --from-file=client-key.pem
}

cleanup_tls_certs() {
  echo_step "cleaning up TLS certificate files and secrets"
  for file in *.pem *.srl; do
      rm -f "$file"
  done
  "${KUBECTL}" delete secret mariadb-server-tls
  "${KUBECTL}" delete secret mariadb-client-tls
}

setup_provider_config_no_tls() {
  echo_step "creating ProviderConfig with no TLS ${API_TYPE}"
  "${KUBECTL}" apply -f "${scriptdir}/mariadb.providerconfig.notls.${API_TYPE}.yaml"
}

setup_provider_config_tls() {
  echo_step "creating ProviderConfig with TLS ${API_TYPE}"
  "${KUBECTL}" apply -f "${scriptdir}/mariadb.providerconfig.tls.${API_TYPE}.yaml"
}

cleanup_provider_config() {
  echo_step "cleaning up ProviderConfig"
  delete_provider_config "mysql.sql.${APIGROUP_SUFFIX}crossplane.io"
}

# The connection secret for the pass that configures no TLS: plain root
# credentials, no certificates. The server is the same one the TLS pass
# uses; what differs is what the provider is given to connect with.
#
# This does not prove the provider can talk to a server with TLS switched
# off, and it cannot: ProviderConfig.spec.tls has no "false", and when it
# is unset the MySQL driver defaults to "preferred", so it encrypts
# whenever the server offers to. What the pass does prove is that a
# ProviderConfig with no tlsConfig loads its credentials and connects.
setup_mariadb_no_tls() {
  echo_step "pointing the provider at MariaDB without TLS configuration"
  "${KUBECTL}" create secret generic mariadb-creds \
      --from-literal username="root" \
      --from-literal password="${MARIADB_ROOT_PW}" \
      --from-literal endpoint="mariadb.default.svc.cluster.local" \
      --from-literal port="3306"
}

# Started in the background right after the cluster comes up, so MariaDB
# boots while Crossplane and the provider install. It is the first engine
# to run, and no second database server is up at this point, so this costs
# no extra peak memory.
prestart_mariadb() {
  wait_image "${MARIADB_IMAGE}"
  setup_tls_certs
  apply_mariadb
}

apply_mariadb() {
  echo_step "installing MariaDB with TLS"
  "${KUBECTL}" create secret generic mariadb-root \
      --from-literal password="${MARIADB_ROOT_PW}"

  # 'test' is the user the TLS pass connects as. REQUIRE X509 means the
  # server rejects it unless the client presents a certificate, so that
  # pass passing at all is proof the provider loaded the client key pair
  # out of its ProviderConfig.
  "${KUBECTL}" create configmap mariadb-init-script --from-literal=init.sql="
    CREATE USER 'test'@'%' IDENTIFIED BY '${MARIADB_TEST_PW}' REQUIRE X509;
    GRANT ALL PRIVILEGES ON *.* TO 'test'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
  "

  "${KUBECTL}" apply -f "${scriptdir}/mariadb.tls.server.yaml"
}

# The connection secret for the pass that configures TLS: the X509-only
# user plus the CA and client key pair.
setup_mariadb_creds_tls() {
  echo_step "pointing the provider at MariaDB with TLS"
  "${KUBECTL}" create secret generic mariadb-creds \
      --from-literal username="test" \
      --from-literal password="${MARIADB_TEST_PW}" \
      --from-literal endpoint="mariadb.default.svc.cluster.local" \
      --from-literal port="3306" \
      --from-file=ca-cert.pem \
      --from-file=client-cert.pem \
      --from-file=client-key.pem
}

wait_mariadb_ready() {
  echo_step "Waiting for MariaDB to be ready"
  "${KUBECTL}" rollout status statefulset/mariadb --timeout=120s
}

# Between passes only the connection secret changes; the server stays.
cleanup_mariadb_creds() {
  "${KUBECTL}" delete secret mariadb-creds
}

cleanup_mariadb() {
  echo_step "uninstalling MariaDB"
  "${KUBECTL}" delete statefulset mariadb -n default
  "${KUBECTL}" delete service mariadb -n default
  "${KUBECTL}" delete configmap mariadb-init-script -n default --ignore-not-found=true
  "${KUBECTL}" delete secret mariadb-root --ignore-not-found=true
  cleanup_tls_certs
}

test_create_database() {
  echo_step "test creating MySQL Database resource"
  "${KUBECTL}" apply -f ${projectdir}/examples/${API_TYPE}/mysql/database.yaml

  echo_info "check if is ready"
  "${KUBECTL}" wait --timeout 2m --for condition=Ready -f ${projectdir}/examples/${API_TYPE}/mysql/database.yaml
  echo_step_completed
}

test_database_charset() {
  echo_step "test database has correct charset and collation"

  local charset collation
  charset=$("${KUBECTL}" exec mariadb-0 -- bash -c \
    'mariadb -uroot -p${MARIADB_ROOT_PASSWORD} -N -e "SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name = '"'"'example-db'"'"'"')
  collation=$("${KUBECTL}" exec mariadb-0 -- bash -c \
    'mariadb -uroot -p${MARIADB_ROOT_PASSWORD} -N -e "SELECT default_collation_name FROM information_schema.schemata WHERE schema_name = '"'"'example-db'"'"'"')

  charset=$(echo "${charset}" | tr -d '[:space:]')
  collation=$(echo "${collation}" | tr -d '[:space:]')

  echo_info "charset=${charset}, collation=${collation}"

  if [ "${charset}" != "utf8mb4" ]; then
    echo_error "expected charset utf8mb4 but got ${charset}"
  fi
  if [ "${collation}" != "utf8mb4_bin" ]; then
    echo_error "expected collation utf8mb4_bin but got ${collation}"
  fi
  echo_step_completed
}

test_update_database_charset() {
  echo_step "test updating MySQL Database charset and collation"

  # Patch the database to use a different collation
  "${KUBECTL}" patch database.mysql.sql.${APIGROUP_SUFFIX}crossplane.io example-db --type merge \
    -p '{"spec":{"forProvider":{"defaultCollation":"utf8mb4_general_ci"}}}'

  echo_info "check if collation was updated in MariaDB"
  wait_collation utf8mb4_general_ci
  echo_step_completed

  # Restore original collation for subsequent tests
  "${KUBECTL}" patch database.mysql.sql.${APIGROUP_SUFFIX}crossplane.io example-db --type merge \
    -p '{"spec":{"forProvider":{"defaultCollation":"utf8mb4_bin"}}}'
  wait_collation utf8mb4_bin
}

mariadb_collation() {
  "${KUBECTL}" exec mariadb-0 -- bash -c \
    'mariadb -uroot -p${MARIADB_ROOT_PASSWORD} -N -e "SELECT default_collation_name FROM information_schema.schemata WHERE schema_name = '"'"'example-db'"'"'"' | tr -d '[:space:]'
}

# wait_collation <expected>: poll MariaDB until example-db has this collation.
wait_collation() {
  local i got
  for i in $(seq 1 60); do
    got=$(mariadb_collation)
    if [ "${got}" = "$1" ]; then
      echo_info "collation=${got}"
      return 0
    fi
    sleep 1
  done
  echo_error "expected collation $1 but got ${got}"
}

test_remove_database_charset() {
  echo_step "test removing charset/collation from spec leaves database unchanged"

  # Remove charset and collation from the spec (set forProvider to only have empty fields)
  "${KUBECTL}" patch database.mysql.sql.${APIGROUP_SUFFIX}crossplane.io example-db --type json \
    -p '[{"op":"remove","path":"/spec/forProvider/defaultCharacterSet"},{"op":"remove","path":"/spec/forProvider/defaultCollation"}]'

  # Late init should re-populate the fields without touching the database.
  wait_reconciled database.mysql.sql.${APIGROUP_SUFFIX}crossplane.io/example-db

  echo_info "check database resource is still Ready"
  "${KUBECTL}" wait --timeout 30s --for condition=Ready database.mysql.sql.${APIGROUP_SUFFIX}crossplane.io/example-db
  echo_step_completed

  echo_info "check charset/collation unchanged in MariaDB"
  local charset collation
  charset=$("${KUBECTL}" exec mariadb-0 -- bash -c \
    'mariadb -uroot -p${MARIADB_ROOT_PASSWORD} -N -e "SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name = '"'"'example-db'"'"'"')
  collation=$("${KUBECTL}" exec mariadb-0 -- bash -c \
    'mariadb -uroot -p${MARIADB_ROOT_PASSWORD} -N -e "SELECT default_collation_name FROM information_schema.schemata WHERE schema_name = '"'"'example-db'"'"'"')

  charset=$(echo "${charset}" | tr -d '[:space:]')
  collation=$(echo "${collation}" | tr -d '[:space:]')

  echo_info "charset=${charset}, collation=${collation}"

  if [ "${charset}" != "utf8mb4" ]; then
    echo_error "expected charset utf8mb4 after field removal but got ${charset}"
  fi
  if [ "${collation}" != "utf8mb4_bin" ]; then
    echo_error "expected collation utf8mb4_bin after field removal but got ${collation}"
  fi
  echo_step_completed
}

test_create_user() {
  echo_step "test creating MySQL User resource"
  local user_pw="asdf1234"
  "${KUBECTL}" create secret generic example-pw --from-literal password="${user_pw}" --save-config
  "${KUBECTL}" apply -f ${projectdir}/examples/${API_TYPE}/mysql/user.yaml

  echo_info "check if is ready"
  "${KUBECTL}" wait --timeout 2m --for condition=Ready -f ${projectdir}/examples/${API_TYPE}/mysql/user.yaml
  echo_step_completed

  echo_info "check if connection secret exists"
  local pw=$("${KUBECTL}" get secret example-connection-secret -ojsonpath='{.data.password}' | base64 --decode)
  [ "${pw}" == "${user_pw}" ]
  echo_step_completed
}

test_update_user_password() {
  echo_step "test updating MySQL User password"
  local user_pw="newpassword"
  "${KUBECTL}" create secret generic example-pw --from-literal password="${user_pw}" --dry-run=client --save-config -oyaml | \
    "${KUBECTL}" apply -f -

  # trigger reconcile
  "${KUBECTL}" annotate -f ${projectdir}/examples/${API_TYPE}/mysql/user.yaml reconcile=now

  echo_info "check if connection secret has been updated"
  wait_until 30 "[ \"\$(\"${KUBECTL}\" get secret example-connection-secret -ojsonpath='{.data.password}' | base64 --decode)\" = \"${user_pw}\" ]" \
    || echo_error "connection secret was not updated with the new password"
  local pw=$("${KUBECTL}" get secret example-connection-secret -ojsonpath='{.data.password}' | base64 --decode)
  [ "${pw}" == "${user_pw}" ]
  echo_step_completed
}

test_create_grant() {
  echo_step "test creating MySQL Grant resource"
  "${KUBECTL}" exec mariadb-0 -- bash -c \
  'mariadb -uroot -p${MARIADB_ROOT_PASSWORD} -N -e "CREATE TABLE \`example-db\`.\`example-table\` (id INT, status VARCHAR(50), updated_at TIMESTAMP);"'

  "${KUBECTL}" apply -f ${projectdir}/examples/${API_TYPE}/mysql/grant_database.yaml
  "${KUBECTL}" apply -f ${projectdir}/examples/${API_TYPE}/mysql/grant_table.yaml

  echo_info "check if is ready"
  "${KUBECTL}" wait --timeout 2m --for condition=Ready -f ${projectdir}/examples/${API_TYPE}/mysql/grant_database.yaml
  "${KUBECTL}" wait --timeout 2m --for condition=Ready -f ${projectdir}/examples/${API_TYPE}/mysql/grant_table.yaml
  echo_step_completed
}

test_all() {
  test_create_database
  test_database_charset
  test_update_database_charset
  test_remove_database_charset
  test_create_user
  test_update_user_password
  test_create_grant
}

cleanup_test_resources() {
  echo_step "cleaning up test resources"
  "${KUBECTL}" delete -f ${projectdir}/examples/${API_TYPE}/mysql/grant_database.yaml
  "${KUBECTL}" delete -f ${projectdir}/examples/${API_TYPE}/mysql/grant_table.yaml
  "${KUBECTL}" delete -f ${projectdir}/examples/${API_TYPE}/mysql/database.yaml
  "${KUBECTL}" delete -f ${projectdir}/examples/${API_TYPE}/mysql/user.yaml
  "${KUBECTL}" delete secret example-pw
}

setup_cluster
setup_crossplane

if [ "${QUICK_TEST:-}" == "true" ]; then
  setup_provider
  echo_success "Quick test passed: provider is healthy and running."
  exit 0
fi

# Boot the first database server while the provider installs.
prestart_mariadb > "${PRESTART_LOG}" 2>&1 &
PRESTART_PID=$!

setup_provider

# Both passes share one server (started before them by prestart_mariadb);
# only the connection secret and the ProviderConfig differ.
integration_tests_mariadb() {
  if [[ "${TLS}" == "true" ]]; then
    setup_mariadb_creds_tls
    setup_provider_config_tls
  else
    setup_mariadb_no_tls
    setup_provider_config_no_tls
  fi

  test_all

  cleanup_test_resources
  cleanup_provider_config
  cleanup_mariadb_creds
}

run_test() {
  APIGROUP_SUFFIX=""
  if [ "${API_TYPE}" == "namespaced" ]; then
    APIGROUP_SUFFIX="m."
  fi

  local testmain="$1"

  echo_step "--- TESTING $testmain $API_TYPE WITH TLS=$TLS ---"
  start=$(date +%s)

  $testmain

  duration=$(( $(date +%s) - start ))
  echo_step "--- TESTING $testmain DONE IN ${duration}s ---"
}

wait_prestart
wait_dns_ready
wait_mariadb_ready
TLS=true API_TYPE="namespaced" run_test integration_tests_mariadb
TLS=false API_TYPE="cluster" run_test integration_tests_mariadb
cleanup_mariadb

# PostgreSQL and MSSQL keep one server across the cluster and namespaced
# passes: each pass deletes what it created, and a server start is the
# most expensive step of a pass.
wait_image "${POSTGRES_IMAGE}"
setup_postgresdb_no_tls
TLS=false API_TYPE="cluster" run_test integration_tests_postgres
TLS=false API_TYPE="namespaced" run_test integration_tests_postgres
cleanup_postgresdb

wait_image "${MSSQL_IMAGE}"
setup_mssql
# no TLS=false variant - MSSQL uses built-in encryption
TLS=true API_TYPE="cluster" run_test integration_tests_mssql
TLS=true API_TYPE="namespaced" run_test integration_tests_mssql
cleanup_mssql

integration_tests_end
