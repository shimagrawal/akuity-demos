#!/usr/bin/env bash
# End-to-end test of the oci-flow demo in a throwaway kind cluster.
#
# Real Kargo and real Argo CD run this demo's own files (Warehouse,
# PromotionTasks, Stages, AppProject, ApplicationSet). Only the addresses change:
# GitHub becomes an in-cluster Git server and GHCR an in-cluster registry (see
# infra.yaml). dev, test and prod are then promoted for real, and the checks
# confirm every stage runs the same artifact digest and serves its own content.
#
#   e2e.sh up     create the cluster; install registry, Git server, Argo CD,
#                 cert-manager and Kargo (reused if the cluster exists)
#   e2e.sh run    seed Git with the working tree, apply the demo, promote
#                 dev -> test -> prod, check (repeatable on a running cluster)
#   e2e.sh down   delete the cluster
#   e2e.sh all    up + run, then down unless KEEP=1
#
# Versions come from the root Taskfile: KARGO_VERSION, ARGOCD_VERSION, K8S_VERSION.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)" # oci-flow/e2e
DEMO="$(dirname "$HERE")"             # oci-flow
REPO="$(dirname "$DEMO")"             # repository root

: "${KARGO_VERSION:?set KARGO_VERSION, e.g. v1.12.2}"
: "${ARGOCD_VERSION:?set ARGOCD_VERSION, e.g. v3.5.4}"
: "${K8S_VERSION:?set K8S_VERSION, e.g. 1.36.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.1}"

CLUSTER="${E2E_CLUSTER:-oci-e2e}"
CONTEXT="kind-$CLUSTER"
INFRA=e2e-infra
PROJECT=oci-flow
STAGES=(dev test prod)

k() { kubectl --context "$CONTEXT" "$@"; }
say() { printf '\n==> %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
die() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

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
  if kind get clusters 2> /dev/null | grep -qx "$CLUSTER"; then
    say "Reusing kind cluster $CLUSTER"
  else
    say "Creating kind cluster $CLUSTER (Kubernetes $K8S_VERSION)"
    # kind switches kubectl's current context to the new cluster; put yours back.
    local previous
    previous="$(kubectl config current-context 2> /dev/null || true)"
    kind create cluster --name "$CLUSTER" --image "kindest/node:v$K8S_VERSION" --wait 120s
    if [ -n "$previous" ]; then kubectl config use-context "$previous" > /dev/null; fi
  fi

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
  helm upgrade --install cert-manager cert-manager \
    --repo https://charts.jetstack.io --version "$CERT_MANAGER_VERSION" \
    --kube-context "$CONTEXT" --namespace cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 6m > /dev/null
  ok "cert-manager ready"

  # Installed after Argo CD, so Kargo finds Argo CD's CRDs and enables its integration.
  say "Kargo $KARGO_VERSION"
  helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
    --version "${KARGO_VERSION#v}" \
    --kube-context "$CONTEXT" --namespace kargo --create-namespace \
    --set api.enabled=false --wait --timeout 8m > /dev/null
  ok "Kargo ready"
}

# ------------------------------------------------------------------ run

seed() {
  say "Seeding the in-cluster Git server with this repository's working tree"
  local work pod
  work="$(mktemp -d "${TMPDIR:-/tmp}/oci-e2e.XXXXXX")"
  # The working tree, not the last commit: uncommitted changes are tested too.
  # Copied with tar so it works on any machine (no rsync needed).
  mkdir -p "$work/src"
  tar -C "$REPO" --exclude ./.git --exclude ./.env --exclude ./tools/schemas \
    --exclude '*/.validate' --exclude '*/.out' -cf - . | tar -C "$work/src" -xf -
  git -C "$work/src" init -q -b main
  git -C "$work/src" add -A
  git -C "$work/src" -c user.email=e2e@example.test -c user.name='oci e2e' \
    commit -q -m "e2e $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git clone -q --bare "$work/src" "$work/akuity-demos.git"
  git -C "$work/akuity-demos.git" update-server-info

  pod="$(k -n "$INFRA" get pod -l app=git -o jsonpath='{.items[0].metadata.name}')"
  k -n "$INFRA" exec "$pod" -- rm -rf /usr/share/nginx/html/akuity-demos.git
  k -n "$INFRA" cp "$work/akuity-demos.git" "$pod:/usr/share/nginx/html/akuity-demos.git" > /dev/null
  COMMIT="$(git -C "$work/src" rev-parse HEAD)"
  rm -rf "$work"
  ok "commit $COMMIT on main"
}

apply_demo() {
  say "Applying the demo's Argo CD and Kargo resources"
  local registry_ip f
  registry_ip="$(k -n "$INFRA" get svc registry -o jsonpath='{.spec.clusterIP}')"
  # The same placeholders as `task oci:apply-*`, pointed at in-cluster services.
  export GITOPS_REPO_URL="http://git.$INFRA.svc.cluster.local/akuity-demos.git"
  export OCI_REPO_PREFIX="$registry_ip:5000/akuity-demos"
  export ARGOCD_DESTINATION=in-cluster
  # shellcheck disable=SC2016 # literal names for envsubst, not expansions
  local vars='${GITOPS_REPO_URL} ${OCI_REPO_PREFIX} ${ARGOCD_DESTINATION}'

  envsubst "$vars" < "$HERE/argocd-repo.yaml" | k apply -f - > /dev/null
  for f in argocd/app-project.yaml argocd/applicationset.yaml; do
    envsubst "$vars" < "$DEMO/$f" | k apply -f - > /dev/null
    ok "$f"
  done

  envsubst "$vars" < "$DEMO/kargo/project.yaml" | k apply -f - > /dev/null
  wait_for "the $PROJECT project namespace" 120 k get namespace "$PROJECT"
  ok "kargo/project.yaml"
  for f in kargo/warehouse.yaml kargo/promotiontasks.yaml kargo/stages.yaml; do
    envsubst "$vars" < "$DEMO/$f" | k apply -f - > /dev/null
    ok "$f"
  done
}

freight_for_commit() {
  k -n "$PROJECT" get freight -o json | jq -re --arg c "$COMMIT" \
    'first(.items[] | select(any(.commits[]?; .id == $c)) | select((.images // []) | length > 0) | .metadata.name)'
}

find_freight() {
  say "Waiting for the Warehouse to produce Freight for commit ${COMMIT:0:7}"
  k -n "$PROJECT" annotate warehouse nginx kargo.akuity.io/refresh="$(date +%s)" --overwrite > /dev/null
  wait_for "Freight for commit $COMMIT" 300 freight_for_commit
  FREIGHT="$(freight_for_commit)"
  ok "Freight $FREIGHT: nginx $(k -n "$PROJECT" get freight "$FREIGHT" -o jsonpath='{.images[0].tag}'), commit ${COMMIT:0:7}"
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
  local digest stage app rev sync health page body failed=0
  digest="$(k -n "$PROJECT" get freight "$FREIGHT" -o jsonpath='{.status.metadata.ociManifests.digest}')"
  [ -n "$digest" ] || die "no ociManifests.digest recorded on Freight $FREIGHT"
  ok "Freight records digest $digest"

  for stage in "${STAGES[@]}"; do
    app="oci-flow-nginx-$stage"
    rev="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.revision}')"
    sync="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status}')"
    health="$(k -n argocd get application "$app" -o jsonpath='{.status.health.status}')"
    if [ "$rev" = "$digest" ] && [ "$sync" = Synced ] && [ "$health" = Healthy ]; then
      ok "$app: $sync, $health, same digest"
    else
      printf '  ✗ %s: %s, %s, revision %s\n' "$app" "$sync" "$health" "$rev" >&2
      failed=1
    fi

    page="$(k -n "$INFRA" exec curl -- curl -fsS "http://nginx.oci-flow-$stage.svc" 2>&1 || true)"
    body="$(k -n "$INFRA" exec curl -- curl -fsS "http://hello.oci-flow-$stage.svc" 2>&1 || true)"
    if printf '%s' "$page" | grep -qi "NGINX - $stage" && printf '%s' "$body" | grep -qi "Hello from Helm - $stage"; then
      ok "$stage serves: \"NGINX - $(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]')\", \"$(printf '%s' "$body" | tr -d '\n')\""
    else
      printf '  ✗ %s: nginx said %q, hello said %q\n' "$stage" "${page:0:80}" "${body:0:80}" >&2
      failed=1
    fi
  done

  [ "$failed" = 0 ] || die "End-to-end test failed"
  printf '\n✓ End-to-end test passed: dev, test and prod run %s\n' "$digest"
}

run() {
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
  kind delete cluster --name "$CLUSTER"
}

case "${1:-}" in
  up) up ;;
  run) run ;;
  down) down ;;
  all)
    if [ -z "${KEEP:-}" ]; then trap down EXIT; fi
    up
    run
    ;;
  *)
    echo "usage: $0 up|run|down|all   (KEEP=1 keeps the cluster after 'all')" >&2
    exit 2
    ;;
esac
