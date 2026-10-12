#!/usr/bin/env bash
# Renders a demo's apps per stage, as listed under `render:` in its demo.yaml.
#
#   tools/render.sh <demo>          every stage into <demo>/.out/<stage>/<app>/manifests.yaml
#                                   (the layout of the demo's artifact), listing the files
#   tools/render.sh <demo> <stage>  one stage to stdout, for a quick look
#
# Set QUIET=1 to skip the file listing.

set -euo pipefail
# shellcheck source=tools/lib.sh
. "$(dirname "$0")/lib.sh"

demo_dir "${1:-}"
only_stage="${2:-}"

render_app() { # index stage
  local i="$1" stage="$2" path chart release values
  path="$(cfg ".render[$i].kustomize")"
  if [ -n "$path" ]; then
    kubectl kustomize "$DEMO_DIR/$(with_stage "$path" "$stage")"
    return
  fi
  chart="$(cfg ".render[$i].helm.chart")"
  if [ -n "$chart" ]; then
    release="$(cfg ".render[$i].helm.release")"
    [ -n "$release" ] || release="$(cfg ".render[$i].app")"
    values="$(cfg ".render[$i].helm.values")"
    if [ -n "$values" ]; then
      helm template "$release" "$DEMO_DIR/$chart" -f "$DEMO_DIR/$(with_stage "$values" "$stage")"
    else
      helm template "$release" "$DEMO_DIR/$chart"
    fi
    return
  fi
  die "render[$i] in $DEMO_CFG needs either kustomize: or helm:"
}

apps="$(cfg '.render | length')"
[ "${apps:-0}" -gt 0 ] || die "$DEMO_CFG lists nothing under render:"

if [ -n "$only_stage" ]; then
  i=0
  while [ "$i" -lt "$apps" ]; do
    [ "$i" -gt 0 ] && echo "---"
    render_app "$i" "$only_stage"
    i=$((i + 1))
  done
  exit 0
fi

rm -rf "$DEMO_DIR/.out"
for stage in $(cfg_list '.stages'); do
  i=0
  while [ "$i" -lt "$apps" ]; do
    app="$(cfg ".render[$i].app")"
    mkdir -p "$DEMO_DIR/.out/$stage/$app"
    render_app "$i" "$stage" > "$DEMO_DIR/.out/$stage/$app/manifests.yaml"
    i=$((i + 1))
  done
done
[ -n "${QUIET:-}" ] || (cd "$DEMO_DIR" && find .out -type f | sort)
