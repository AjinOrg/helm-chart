#!/usr/bin/env bash
# orders specific smoke tests, run by verify.yaml after the generic checks (version + environment).
# Input: URL (http://<alb>/<env>/orders).
set -euo pipefail
fail() { echo "::error::$1"; exit 1; }

BODY=$(curl -fsS --max-time 10 "$URL") || fail "GET $URL failed"
# Service-to-service: orders reached my-app in the same namespace (Service DNS + NetworkPolicies allow it)
[ "$(echo "$BODY" | jq -r '.dependencies["my-app"].reachable')" = true ] \
  || fail "orders cannot reach my-app: $(echo "$BODY" | jq -c '.dependencies["my-app"]')"
echo "orders → my-app OK (my-app version $(echo "$BODY" | jq -r '.dependencies["my-app"].version'))"

[ "$(curl -fsS --max-time 5 "$URL/api/orders" | jq .count)" = 3 ] || fail "order list"
CODE=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$URL/api/orders/does-not-exist")
[ "$CODE" = 404 ] || fail "unknown order returned $CODE, expected 404"
for i in $(seq 1 20); do # stable under repeated requests (all replicas)
  curl -fsS --max-time 10 -o /dev/null "$URL" || fail "request $i failed"
done
