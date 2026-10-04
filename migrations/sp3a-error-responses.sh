#!/usr/bin/env bash
# Sub-project 3a: records, through the gateway, the error responses the services answer with, so the move of
# the shared error infrastructure into oj-common can be compared before and after the deploy:
#   migrations/sp3a-error-responses.sh > /tmp/sp3a-before.txt   ... deploy ...
#   migrations/sp3a-error-responses.sh | diff /tmp/sp3a-before.txt -
# One line per case: status, Retry-After (dynamic values shown as "set"), and the body without its timestamp. Two
# success cases ride along, for the envelope that moved too: a list and an (empty) page with its pagination block.
# Needs an existing USER account: PROBE_USERNAME / PROBE_PASSWORD. The login-lock case sets a lock in Redis for
# a username that does not exist (no IP counter is touched) and removes it again. Prints no credentials.
set -euo pipefail
: "${PROBE_USERNAME:?an existing USER account}" "${PROBE_PASSWORD:?its password}"
API=${API:-http://localhost:8000/api/v1}
JAR=$(mktemp); OUT=$(mktemp); trap 'rm -f "$JAR" "$OUT"' EXIT
LOCKED=sp3a-locked-probe

show() {   # case-name, then curl arguments
    local name=$1; shift
    local headers
    headers=$(curl -s -D - -o "$OUT" "$@")
    local status retry
    status=$(printf '%s' "$headers" | head -1 | awk '{print $2}')
    retry=$(printf '%s' "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="retry-after" {print $2}')
    case $name in cooldown*) [ -n "$retry" ] && retry=set ;; esac
    printf '%-28s %s retry-after=%s %s\n' "$name" "$status" "${retry:--}" \
        "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("timestamp",None); print(json.dumps(d,sort_keys=True))' "$OUT" 2>/dev/null || echo '<not json>')"
}

curl -s -o /dev/null -c "$JAR" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$PROBE_USERNAME\",\"password\":\"$PROBE_PASSWORD\"}" "$API/auth/login"

show "404 unknown problem"        "$API/problems/sp3a-no-such-problem"
show "401 bad credentials"        -H 'Content-Type: application/json' -d '{"username":"sp3a-nobody","password":"wrong"}' "$API/auth/login"
show "401 no token"               -H 'Content-Type: application/json' -d '{}' "$API/submissions"
show "403 user deletes problem"   -b "$JAR" -X DELETE "$API/problems/sp3a-no-such-problem"
show "403 user lists users"       -b "$JAR" "$API/users"
show "400 malformed json"         -b "$JAR" -H 'Content-Type: application/json' -d '{' "$API/submissions"
show "400 validation error"       -H 'Content-Type: application/json' -d '{}' "$API/auth/login"
show "200 language list"          "$API/languages"
show "200 empty problem page"     "$API/problems?page=0&size=1&search=sp3a-matches-nothing"
SUBMIT='{"sourceCode":"print(3)","languageIdentifier":"python3","problemSlug":"simple-a-plus-b"}'
curl -s -o /dev/null -b "$JAR" -H 'Content-Type: application/json' -d "$SUBMIT" "$API/submissions"
show "cooldown 429"               -b "$JAR" -H 'Content-Type: application/json' -d "$SUBMIT" "$API/submissions"
docker exec oj-redis redis-cli SET "oj:rl:lock:username:$LOCKED" 1 EX 900 > /dev/null
show "429 login locked"           -H 'Content-Type: application/json' -d "{\"username\":\"$LOCKED\",\"password\":\"x\"}" "$API/auth/login"
docker exec oj-redis redis-cli DEL "oj:rl:lock:username:$LOCKED" > /dev/null
show "unclaimed api path"         "$API/sp3a-unclaimed"
