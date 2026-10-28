#!/usr/bin/env bash
# edge/Caddyfile (sub-project 15): the browser-facing security headers and the API body limit. `caddy adapt` turns the
# Caddyfile into its JSON, which is checked here; nothing is started and no certificate is read. Prints descriptions only.
set -euo pipefail
cd "$(dirname "$0")/.."
# OJ_DOCKER_CONTEXT overrides the host's `default` daemon (the repo's convention) for another machine.
image=caddy:2.11.7-alpine
docker --context "${OJ_DOCKER_CONTEXT:-default}" pull -q "$image" > /dev/null
json=$(docker --context "${OJ_DOCKER_CONTEXT:-default}" run --rm --network none -v "$PWD/edge/Caddyfile:/etc/caddy/Caddyfile:ro" "$image" \
  caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile)
fail=0
check() { # check <description> <python expression over c = the adapted config, routes = the site's routes>
  if python3 -c "
import json, sys
c = json.load(sys.stdin)
routes = [r for srv in c['apps']['http']['servers'].values() for r in srv['routes']]
def handlers(rs):
    for r in rs:
        for h in r.get('handle', []):
            yield h
            if h.get('handler') == 'subroute':
                yield from handlers(h.get('routes', []))
hs = list(handlers(routes))
sys.exit(0 if ($2) else 1)" <<< "$json"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
# The headers a site-level `header` block writes, whatever route answers.
headers='{k: v[0] for h in hs if h.get("handler") == "headers" for k, v in h.get("response", {}).get("set", {}).items()}'
check "every response carries a CSP of 'self' with frame-ancestors none, no inline script" \
  "(lambda csp: \"default-src 'self'\" in csp and \"script-src 'self'\" in csp and \"frame-ancestors 'none'\" in csp and \"'unsafe-inline'\" not in csp.split('style-src')[0] and \"object-src 'none'\" in csp and \"base-uri 'self'\" in csp)($headers.get('Content-Security-Policy', ''))"
check "the CSP lets the portal load KaTeX fonts, Monaco workers, HTTPS images and call its own API only" \
  "(lambda csp: \"font-src 'self' data:\" in csp and \"worker-src 'self' blob:\" in csp and 'img-src' in csp and 'https:' in csp and \"connect-src 'self'\" in csp)($headers.get('Content-Security-Policy', ''))"
check "nosniff, a referrer policy and X-Frame-Options DENY on every response" \
  "($headers.get('X-Content-Type-Options') == 'nosniff' and $headers.get('Referrer-Policy') == 'strict-origin-when-cross-origin' and $headers.get('X-Frame-Options') == 'DENY')"
check "the API route refuses a request body over 1 MB (a source is at most 10 KiB; this stops a body streamed to the gateway first)" \
  "any(h.get('handler') == 'request_body' and h.get('max_size') == 1000000 for h in hs)"
check "the API route still proxies to the gateway and everything else to the portal over TLS" \
  "sorted({h['upstreams'][0]['dial'] for h in hs if h.get('handler') == 'reverse_proxy'}) == ['api-gateway:8000', 'judge-portal:443']"
exit $fail
