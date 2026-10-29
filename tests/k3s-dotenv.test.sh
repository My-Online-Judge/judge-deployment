#!/usr/bin/env bash
# k3s/scripts/dotenv.py (what env-to-secrets.sh reads the .env files with) gives every value the way `docker compose` reads the same
# file: surrounding quotes dropped, an inline ` # comment` dropped from an unquoted value, `export KEY=value` accepted, CRLF line endings
# ignored, a `#` or `=` inside a value kept. The expected values are asked of compose itself. Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

printf '%s\r\n' \
  'PLAIN=abc123' \
  'SPACES=  padded value  ' \
  'DQUOTED="double quoted"' \
  "SQUOTED='single quoted'" \
  'INLINE=value # a comment' \
  'HASHKEEP=pa#ss' \
  'EQUALS=a=b=c' \
  'EMPTY=' \
  'DQ_HASH="has # inside"' \
  "SQ_DOLLAR='\$notexpanded'" \
  'export EXPORTED=exp' \
  '# COMMENT=skipped' \
  '' \
  'LAST=end' > "$tmp/.env"
keys=(PLAIN SPACES DQUOTED SQUOTED INLINE HASHKEEP EQUALS EMPTY DQ_HASH SQ_DOLLAR EXPORTED LAST)
{ echo "services:"; echo "  x:"; echo "    image: scratch"; echo "    environment:"; for k in "${keys[@]}"; do echo "      $k: \"\${$k-UNSET}\""; done; } > "$tmp/compose.yml"
docker compose --project-directory "$tmp" --env-file "$tmp/.env" -f "$tmp/compose.yml" config --format json > "$tmp/compose.json"

python3 - "$tmp" <<'PY' || fail=1
import json, sys
sys.path.insert(0, "k3s/scripts")
import dotenv
tmp = sys.argv[1]
# `compose config` prints a literal $ as $$ (its own interpolation escape); the container gets one $
want = {k: v.replace("$$", "$") for k, v in json.load(open(f"{tmp}/compose.json"))["services"]["x"]["environment"].items()}
got = dotenv.parse(f"{tmp}/.env")
failed = False
for k, v in want.items():
    ok = got.get(k) == v
    print(("ok   " if ok else "FAIL ") + f"{k}: compose reads {v!r}, dotenv.py reads {got.get(k)!r}")
    failed |= not ok
extra = sorted(set(got) - set(want))
print(("ok   " if not extra else "FAIL ") + "no key compose does not see (comments and blank lines are skipped)" + (f": {extra}" if extra else ""))
sys.exit(1 if failed or extra else 0)
PY
exit $fail
