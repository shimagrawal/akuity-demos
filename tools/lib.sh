# shellcheck shell=bash
# Shared helpers for tools/*.sh. Sourced, not executed. Works with bash 3.2.

die() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# demo_dir <path>: sets DEMO_DIR (absolute) and DEMO_CFG (its demo.yaml).
demo_dir() {
  [ -n "${1:-}" ] || die "no demo given (e.g. oci-flow)"
  [ -d "$1" ] || die "no such demo directory: $1"
  DEMO_DIR="$(cd "$1" && pwd)"
  DEMO_CFG="$DEMO_DIR/demo.yaml"
  [ -f "$DEMO_CFG" ] || die "$1 has no demo.yaml"
}

# cfg <yq expression>: a scalar from the demo's demo.yaml ("" when unset).
cfg() { yq -r "($1) // \"\"" "$DEMO_CFG"; }

# cfg_list <yq expression>: the items of a list, one per line.
cfg_list() { yq -r "($1) // [] | .[]" "$DEMO_CFG"; }

# with_stage <text> <stage>: replaces {stage} and {STAGE} (upper case).
with_stage() {
  local text="$1" stage="$2" upper
  upper="$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]')"
  text="${text//\{stage\}/$stage}"
  text="${text//\{STAGE\}/$upper}"
  printf '%s' "$text"
}
