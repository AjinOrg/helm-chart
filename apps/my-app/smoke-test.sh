#!/usr/bin/env bash
# my-app specific smoke tests, run by verify.yaml after the generic checks (version + environment).
# Input: URL (http://<alb>/<env>/my-app). Optional per service: a service without this file gets only the generic checks.
set -euo pipefail
fail() { echo "::error::$1"; exit 1; }

BODY=$(curl -fsS --max-time 5 "$URL") || fail "GET $URL failed"
echo "$BODY" | jq -r .greeting | grep -qv '^no GREETING' || fail "secret not mounted (External Secrets)"
for i in $(seq 1 20); do # stable under repeated requests (all replicas)
  curl -fsS --max-time 5 -o /dev/null "$URL" || fail "request $i failed"
done
