#!/usr/bin/env bash
# End-to-end test of a demo in a throwaway kind cluster.
#
# Real Kargo and real Argo CD run the demo's own files (everything in its kargo/
# and argocd/ folders). Only the addresses change: GitHub becomes an in-cluster
# Git server and GHCR an in-cluster registry (see infra.yaml). Each stage listed
# in the demo's demo.yaml is then promoted for real, in order, and the checks
# confirm every stage runs the same artifact digest and serves its own content.
#
#   e2e.sh up            create the cluster; install registry, Git server,
#                        Argo CD, cert-manager and Kargo (reused if it exists)
#   e2e.sh run <demo>    seed Git with the working tree, apply the demo, promote
#                        every stage, check (repeatable on a running cluster)
#   e2e.sh down          delete the cluster
#   e2e.sh all <demo>    up + run, then down unless KEEP=1
#
# Versions come from the root Taskfile: KARGO_VERSION, ARGOCD_VERSION, K8S_VERSION.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)" # tools/e2e
TOOLS="$(dirname "$HERE")"            # tools
REPO="$(dirname "$TOOLS")"            # repository root
# shellcheck source=tools/lib.sh
. "$TOOLS/lib.sh"

: "${KARGO_VERSION:?set KARGO_VERSION, e.g. v1.12.2}"
: "${ARGOCD_VERSION:?set ARGOCD_VERSION, e.g. v3.5.4}"
: "${K8S_VERSION:?set K8S_VERSION, e.g. 1.36.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.1}"

CLUSTER="${E2E_CLUSTER:-demos-e2e}"
CONTEXT="kind-$CLUSTER"
# The test cluster gets its own kubeconfig, so your ~/.kube/config (and its
# current context) is never touched. To look around: export KUBECONFIG=<this file>
KUBECONFIG_E2E="$HERE/kubeconfig"
INFRA=e2e-infra

k() { kubectl --kubeconfig "$KUBECONFIG_E2E" --context "$CONTEXT" "$@"; }
h() { helm --kubeconfig "$KUBECONFIG_E2E" --kube-context "$CONTEXT" "$@"; }

cluster_exists() { kind get clusters 2> /dev/null | grep -qx "$CLUSTER"; }

# Refreshes the test cluster's kubeconfig, e.g. after a reboot or when the
# cluster was created by an earlier run.
use_cluster() {
  cluster_exists || die "no kind cluster $CLUSTER: run \`task e2e:up\` first"
  kind get kubeconfig --name "$CLUSTER" > "$KUBECONFIG_E2E"
}
say() { printf '\n==> %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }

# wait_for "description" timeout-seconds command...
wait_for() {
  local what="$1" timeout="$2" end
  shift 2
  end=$((SECONDS + timeout))
  until "$@" > /dev/null 2>&1; do
    ((SECONDS < end)) || die "timed out after ${timeout}s waiting for $what"
    sleep 3
  done
}

# ------------------------------------------------------------------- up

up() {
  if cluster_exists; then
    say "Reusing kind cluster $CLUSTER"
  else
    say "Creating kind cluster $CLUSTER (Kubernetes $K8S_VERSION)"
    kind create cluster --name "$CLUSTER" --image "kindest/node:v$K8S_VERSION" \
      --kubeconfig "$KUBECONFIG_E2E" --wait 120s
  fi
  use_cluster

  say "In-cluster registry and Git server"
  k apply -f "$HERE/infra.yaml" > /dev/null
  k -n "$INFRA" wait --for=condition=available deploy/registry deploy/git --timeout=180s > /dev/null
  k -n "$INFRA" wait --for=condition=ready pod/curl --timeout=180s > /dev/null
  ok "registry at $(k -n "$INFRA" get svc registry -o jsonpath='{.spec.clusterIP}'):5000"

  say "Argo CD $ARGOCD_VERSION"
  k create namespace argocd --dry-run=client -o yaml | k apply -f - > /dev/null
  # Server-side apply: the ApplicationSet CRD is too large for client-side apply.
  k -n argocd apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" > /dev/null
  k -n argocd wait --for=condition=available deploy --all --timeout=300s > /dev/null
  k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s > /dev/null
  ok "Argo CD ready"

  say "cert-manager $CERT_MANAGER_VERSION"
  h upgrade --install cert-manager cert-manager \
    --repo https://charts.jetstack.io --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 6m > /dev/null
  ok "cert-manager ready"

  # Installed after Argo CD, so Kargo finds Argo CD's CRDs and enables its integration.
  say "Kargo $KARGO_VERSION"
  h upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
    --version "${KARGO_VERSION#v}" \
    --namespace kargo --create-namespace \
    --set api.enabled=false --wait --timeout 8m > /dev/null
  ok "Kargo ready"
}

# ------------------------------------------------------------------ run

# Reads the demo's demo.yaml: PROJECT, STAGES, WAREHOUSE, APP_TEMPLATE, ...
load_demo() {
  demo_dir "$1"
  PROJECT="$(cfg '.name')"
  [ -n "$PROJECT" ] || die "$DEMO_CFG needs name:"
  STAGES=()
  local stage
  while IFS= read -r stage; do STAGES+=("$stage"); done < <(cfg_list '.stages')
  [ "${#STAGES[@]}" -gt 0 ] || die "$DEMO_CFG needs stages:"
  WAREHOUSE="$(cfg '.e2e.warehouse')"
  APP_TEMPLATE="$(cfg '.e2e.application')"
  DIGEST_FROM="$(cfg '.e2e.digestFrom')"
  OCI_REPOSITORY="$(cfg '.e2e.ociRepository')"
  if [ -z "$WAREHOUSE" ] || [ -z "$APP_TEMPLATE" ]; then
    die "$DEMO_CFG needs e2e.warehouse and e2e.application"
  fi
}

seed() {
  say "Seeding the in-cluster Git server with this repository's working tree"
  local work pod
  work="$(mktemp -d "${TMPDIR:-/tmp}/demos-e2e.XXXXXX")"
  # The working tree, not the last commit: uncommitted changes are tested too.
  # Copied with tar so it works on any machine (no rsync needed).
  mkdir -p "$work/src"
  tar -C "$REPO" --exclude ./.git --exclude ./.env --exclude ./tools/schemas \
    --exclude '*/.validate' --exclude '*/.out' -cf - . | tar -C "$work/src" -xf -
  git -C "$work/src" init -q -b main
  git -C "$work/src" add -A
  git -C "$work/src" -c user.email=e2e@example.test -c user.name='demos e2e' \
    commit -q -m "e2e $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git clone -q --bare "$work/src" "$work/repo.git"
  git -C "$work/repo.git" update-server-info

  pod="$(k -n "$INFRA" get pod -l app=git -o jsonpath='{.items[0].metadata.name}')"
  k -n "$INFRA" exec "$pod" -- rm -rf /usr/share/nginx/html/repo.git
  k -n "$INFRA" cp "$work/repo.git" "$pod:/usr/share/nginx/html/repo.git" > /dev/null
  COMMIT="$(git -C "$work/src" rev-parse HEAD)"
  rm -rf "$work"
  ok "commit $COMMIT on main"
}

apply_demo() {
  say "Applying $PROJECT's Argo CD and Kargo resources"
  local registry_ip f projects others
  registry_ip="$(k -n "$INFRA" get svc registry -o jsonpath='{.spec.clusterIP}')"
  # The same placeholders the demo's apply tasks fill from .env, pointed at
  # in-cluster services instead.
  export GITOPS_REPO_URL="http://git.$INFRA.svc.cluster.local/repo.git"
  export OCI_REPO_PREFIX="$registry_ip:5000/akuity-demos"
  export ARGOCD_DESTINATION=in-cluster
  export E2E_NAME="$PROJECT" E2E_OCI_REPOSITORY="$OCI_REPOSITORY"
  # shellcheck disable=SC2016 # literal names for envsubst, not expansions
  local vars='${GITOPS_REPO_URL} ${OCI_REPO_PREFIX} ${ARGOCD_DESTINATION} ${E2E_NAME} ${E2E_OCI_REPOSITORY}'

  if [ -n "$OCI_REPOSITORY" ]; then
    envsubst "$vars" < "$HERE/argocd-repo.yaml" | k apply -f - > /dev/null
  fi
  for f in "$DEMO_DIR"/argocd/*.yaml; do
    envsubst "$vars" < "$f" | k apply -f - > /dev/null
    ok "argocd/$(basename "$f")"
  done

  # Kargo Projects first: everything else lives in the namespace they create.
  projects="$(grep -l '^kind: Project$' "$DEMO_DIR"/kargo/*.yaml || true)"
  others="$(grep -L '^kind: Project$' "$DEMO_DIR"/kargo/*.yaml || true)"
  for f in $projects; do
    envsubst "$vars" < "$f" | k apply -f - > /dev/null
    ok "kargo/$(basename "$f")"
  done
  wait_for "the $PROJECT project namespace" 120 k get namespace "$PROJECT"
  for f in $others; do
    envsubst "$vars" < "$f" | k apply -f - > /dev/null
    ok "kargo/$(basename "$f")"
  done
}

freight_for_commit() {
  k -n "$PROJECT" get freight -o json | jq -re --arg c "$COMMIT" \
    'first(.items[] | select(any(.commits[]?; .id == $c)) | .metadata.name)'
}

find_freight() {
  say "Waiting for Warehouse $WAREHOUSE to produce Freight for commit ${COMMIT:0:7}"
  k -n "$PROJECT" annotate warehouse "$WAREHOUSE" kargo.akuity.io/refresh="$(date +%s)" --overwrite > /dev/null
  wait_for "Freight for commit $COMMIT" 300 freight_for_commit
  FREIGHT="$(freight_for_commit)"
  ok "Freight $FREIGHT: $(k -n "$PROJECT" get freight "$FREIGHT" -o json | jq -r '
    [(.images // [])[] | "\(.repoURL | split("/") | last) \(.tag)"]
    + [(.charts // [])[] | "\(.name) \(.version)"]
    + [(.commits // [])[] | "commit \(.id[0:7])"] | join(", ")')"
}

promotion_phase() { k -n "$PROJECT" get promotion "$1" -o jsonpath='{.status.phase}' 2> /dev/null; }
promotion_done() { case "$(promotion_phase "$1")" in Succeeded | Failed | Errored | Aborted) return 0 ;; esac; return 1; }
verified_in() { k -n "$PROJECT" get freight "$FREIGHT" -o json | jq -e --arg s "$1" '.status.verifiedIn[$s]' > /dev/null; }

explain_promotion() {
  local name="$1"
  printf '    phase:   %s\n' "$(promotion_phase "$name")"
  printf '    message: %s\n' "$(k -n "$PROJECT" get promotion "$name" -o jsonpath='{.status.message}')"
  printf '    steps:\n'
  k -n "$PROJECT" get promotion "$name" -o json |
    jq -r '.status.stepExecutionMetadata // [] | .[] | "      \(.alias // "?"): \(.status) \(.message // "")"'
}

promote() {
  local stage="$1" name
  say "Promoting into $stage"
  name="$(k create -o name -f - << EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  generateName: e2e-$stage-
  namespace: $PROJECT
spec:
  stage: $stage
  freight: $FREIGHT
EOF
  )"
  name="${name#*/}"
  wait_for "the $stage promotion" 600 promotion_done "$name"
  if [ "$(promotion_phase "$name")" != Succeeded ]; then
    printf '  ✗ promotion %s did not succeed\n' "$name" >&2
    explain_promotion "$name" >&2
    exit 1
  fi
  ok "promotion $name succeeded"
  # The next stage only accepts Freight once it is verified (healthy) here.
  wait_for "Freight to be verified in $stage" 300 verified_in "$stage"
  ok "Freight verified in $stage"
}

check() {
  say "Checking the result"
  local expected="" stage app rev sync health checks i url expect response failed=0
  if [ -n "$DIGEST_FROM" ]; then
    expected="$(k -n "$PROJECT" get freight "$FREIGHT" -o json | jq -r ".status.metadata.$DIGEST_FROM // empty")"
    [ -n "$expected" ] || die "no $DIGEST_FROM recorded on Freight $FREIGHT"
    ok "Freight records digest $expected"
  fi
  checks="$(cfg '.e2e.checks | length')"

  for stage in "${STAGES[@]}"; do
    # Every stage must run the same revision: the Freight's digest, or else dev's.
    app="$(with_stage "$APP_TEMPLATE" "$stage")"
    rev="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.revision}')"
    sync="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status}')"
    health="$(k -n argocd get application "$app" -o jsonpath='{.status.health.status}')"
    [ -n "$expected" ] || expected="$rev"
    if [ -n "$rev" ] && [ "$rev" = "$expected" ] && [ "$sync" = Synced ] && [ "$health" = Healthy ]; then
      ok "$app: $sync, $health, same digest"
    else
      printf '  ✗ %s: %s, %s, revision %s (expected %s)\n' "$app" "$sync" "$health" "$rev" "$expected" >&2
      failed=1
    fi

    i=0
    while [ "$i" -lt "${checks:-0}" ]; do
      url="$(with_stage "$(cfg ".e2e.checks[$i].url")" "$stage")"
      expect="$(with_stage "$(cfg ".e2e.checks[$i].expect")" "$stage")"
      response="$(k -n "$INFRA" exec curl -- curl -fsS "$url" 2>&1 || true)"
      if printf '%s' "$response" | grep -qiF -- "$expect"; then
        ok "$url → \"$expect\""
      else
        printf '  ✗ %s: expected "%s", got "%s"\n' "$url" "$expect" "$(printf '%s' "${response:0:80}" | tr -d '\n')" >&2
        failed=1
      fi
      i=$((i + 1))
    done
  done

  [ "$failed" = 0 ] || die "End-to-end test failed"
  printf '\n✓ End-to-end test passed: %s runs %s in %s\n' "$PROJECT" "$expected" "${STAGES[*]}"
}

run() {
  load_demo "$1"
  use_cluster
  seed
  apply_demo
  find_freight
  local stage
  for stage in "${STAGES[@]}"; do promote "$stage"; done
  check
}

# ----------------------------------------------------------------- main

down() {
  say "Deleting kind cluster $CLUSTER"
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG_E2E"
  rm -f "$KUBECONFIG_E2E"
}

usage() {
  echo "usage: $0 up | run <demo> | down | all <demo>   (KEEP=1 keeps the cluster after 'all')" >&2
  exit 2
}

case "${1:-}" in
  up) up ;;
  run) run "${2:-}" ;;
  down) down ;;
  all)
    [ -n "${2:-}" ] || usage
    if [ -z "${KEEP:-}" ]; then trap down EXIT; fi
    up
    run "$2"
    if [ -n "${KEEP:-}" ]; then
      printf '\nCluster kept. Look around with:\n  export KUBECONFIG=%s\n  kubectl -n %s get promotions,freight\n' "$KUBECONFIG_E2E" "$PROJECT"
    fi
    ;;
  *) usage ;;
esac
