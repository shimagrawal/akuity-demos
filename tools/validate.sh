#!/usr/bin/env bash
# Validates one demo against schemas pinned to your environment:
#
#   1. Kargo resources      <demo>/kargo/*.yaml   vs Kargo CRDs (flux-schema, incl. CEL rules)
#   2. Kargo step configs   PromotionTasks in it  vs Kargo's step schemas (tools/lint-task.py)
#   3. Argo CD resources    <demo>/argocd/*.yaml  vs Argo CD CRDs (flux-schema)
#   4. Rendered manifests   render: in demo.yaml  vs Kubernetes (flux-schema)
#
#   tools/validate.sh <demo>
#
# Every section runs, so all problems show at once; exits 1 if any failed.
# Expects KARGO_VERSION, ARGOCD_VERSION and K8S_VERSION, and the pinned schemas
# in tools/schemas (`task schemas`). Keep credentials out of kargo/ and argocd/:
# their files are written to <demo>/.validate with .env values substituted.

set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/lib.sh
. "$TOOLS/lib.sh"

: "${KARGO_VERSION:?}" "${ARGOCD_VERSION:?}" "${K8S_VERSION:?}"
SCHEMAS="$TOOLS/schemas"
KARGO_SCHEMAS="$SCHEMAS/kargo-$KARGO_VERSION"
KARGO_STEP_SCHEMAS="$SCHEMAS/kargo-steps-$KARGO_VERSION"
ARGOCD_SCHEMAS="$SCHEMAS/argocd-$ARGOCD_VERSION"
K8S_SCHEMAS="$SCHEMAS/k8s-$K8S_VERSION"
for d in "$KARGO_SCHEMAS" "$KARGO_STEP_SCHEMAS" "$ARGOCD_SCHEMAS" "$K8S_SCHEMAS"; do
  [ -d "$d" ] || die "missing $d: run \`task schemas\`"
done

# Only these are substituted, so Kargo's ${{ ... }} expressions are left alone.
# shellcheck disable=SC2016 # literal names for envsubst, not expansions
ENVSUBST_VARS='${GITOPS_REPO_URL} ${OCI_REPO_PREFIX} ${ARGOCD_DESTINATION} ${GITHUB_USERNAME} ${GITHUB_PAT}'

# Turns flux-schema's verbose lines into "✓ Kind/namespace/name   (file)".
PRETTY='s#^\.validate/##;
s#^\.out/([^/ ]+/[^/ ]+)/manifests\.yaml - #\1 - #;
s# - ([a-z0-9.-]+/)?v[0-9][a-z0-9]*/# - #;
s#^(.*) - (.*) is valid$#  ✓ \2   (\1)#;
s#^(.*) - (.*) is invalid: (.*)$#  ✗ \2: \3   (\1)#;
s#^(.*) - (.*) is skipped(.*)$#  - \2: skipped\3   (\1)#;
s#^  - /#      - /#;
s#^Summary:#  Summary:#'

demo_dir "${1:-}"
cd "$DEMO_DIR"
failed=0

# --- 1. Kargo resources, with .env values substituted ------------------------
rm -rf .validate && mkdir -p .validate/kargo .validate/argocd
for f in kargo/*.yaml argocd/*.yaml; do
  envsubst "$ENVSUBST_VARS" < "$f" > ".validate/$f"
done

echo "Kargo $KARGO_VERSION"
flux-schema validate .validate/kargo -v --concurrent 1 -s "$KARGO_SCHEMAS" | sed -E "$PRETTY" || failed=1

# --- 2. Step configs inside PromotionTasks -----------------------------------
# flux-schema can't see inside `config:`; tools/lint-task.py can.
echo "Kargo step configs $KARGO_VERSION"
for f in .validate/kargo/*.yaml; do
  yq -o=json ea '[.] | map(select(.kind == "PromotionTask" or .kind == "ClusterPromotionTask"))' "$f" > "$f.json"
  [ "$(yq 'length' "$f.json")" = 0 ] && continue
  name="${f#.validate/}"
  if python3 "$TOOLS/lint-task.py" "$KARGO_STEP_SCHEMAS" "$f.json" > "$f.lint"; then
    yq -r '.[] | .kind + "/" + .metadata.name + " " + (.spec.steps | length | tostring)' "$f.json" |
      while read -r res n; do
        [ "$n" = 1 ] && unit=step || unit=steps
        echo "  ✓ $res: $n $unit   ($name)"
      done
  else
    sed "s#^#  ✗ #; s#\$#   ($name)#" "$f.lint"
    failed=1
  fi
done

# --- 3. Argo CD resources ----------------------------------------------------
echo "Argo CD $ARGOCD_VERSION"
flux-schema validate .validate/argocd -v --concurrent 1 -s "$ARGOCD_SCHEMAS" | sed -E "$PRETTY" || failed=1

# --- 4. What the render steps produce, against your exact Kubernetes version -
QUIET=1 "$TOOLS/render.sh" "$DEMO_DIR"
echo "Rendered manifests (Kubernetes $K8S_VERSION)"
flux-schema validate .out -v --concurrent 1 -s "$K8S_SCHEMAS" | sed -E "$PRETTY" || failed=1

echo
if [ "$failed" = 1 ]; then
  echo "✗ Validation failed (see ✗ above)"
  exit 1
fi
echo "✓ All resources valid"
