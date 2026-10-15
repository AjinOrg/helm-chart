#!/usr/bin/env bash
# Renders every service in every environment exactly as ArgoCD deploys it:
#   chart  = charts/microservice at the environment's chartRevision (environments/<env>.yaml)
#   values = apps/<service>/values.yaml + apps/<service>/values-<env>.yaml (from this checkout)
# Environments pinned to a chart tag are ALSO rendered with this checkout's chart (<service>-<env>.next.yaml),
# so a chart change is checked against every service and environment before anyone pins it.
#
# Usage: bash scripts/render-all.sh [out-dir]      (default out-dir: rendered; needs git, helm, the chart-v* tags)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-rendered}"
rm -rf "$OUT"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "::error::$1" >&2; exit 1; }

# chart_dir <revision>: path of charts/microservice at that revision ("main" = this checkout)
chart_dir() {
  local rev="$1"
  if [ "$rev" = main ]; then echo charts/microservice; return; fi
  git rev-parse -q --verify "refs/tags/$rev^{commit}" >/dev/null || fail "chart revision '$rev' is not an existing git tag"
  if [ ! -d "$TMP/$rev" ]; then
    mkdir -p "$TMP/$rev"
    git archive "$rev" charts/microservice | tar -x -C "$TMP/$rev"
  fi
  echo "$TMP/$rev/charts/microservice"
}

render() { # render <service> <env> <chart-dir> <out-file>
  helm template "$1" "$3" -n "$2" -f "apps/$1/values.yaml" -f "apps/$1/values-$2.yaml" > "$4"
}

for envfile in environments/*.yaml; do
  env=$(sed -nE 's/^environment: *"?([a-z]+)"?.*/\1/p' "$envfile")
  rev=$(sed -nE 's/^chartRevision: *"?([^" #]+)"?.*/\1/p' "$envfile")
  [ -n "$env" ] && [ -n "$rev" ] || fail "$envfile needs 'environment' and 'chartRevision'"
  [ "$env.yaml" = "$(basename "$envfile")" ] || fail "$envfile: environment '$env' must match the file name"
  chart=$(chart_dir "$rev")

  for dir in apps/*/; do
    svc=$(basename "$dir")
    echo "$svc" | grep -Eq '^[a-z][a-z0-9-]{0,40}[a-z0-9]$' || fail "apps/$svc: service names are lowercase letters, digits and '-'"
    for f in values.yaml "values-$env.yaml"; do
      [ -f "apps/$svc/$f" ] || fail "apps/$svc/$f is missing (every service needs values.yaml and values-<env>.yaml per environment)"
    done
    render "$svc" "$env" "$chart" "$OUT/$svc-$env.yaml"
    if [ "$rev" != main ]; then
      render "$svc" "$env" charts/microservice "$OUT/$svc-$env.next.yaml"
    fi
    echo "rendered $svc in $env (chart $rev)"
  done
done
