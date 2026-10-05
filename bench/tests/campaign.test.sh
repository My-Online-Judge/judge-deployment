#!/usr/bin/env bash
# campaign.sh runs each family 3 times in an interleaved order, and re-creates a stack a failed run left behind.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
cat > "$stub/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "run $*" >> "$STUB_LOG"
if [ -n "${STUB_FAIL_ONCE:-}" ] && [[ "$*" == *"$STUB_FAIL_ONCE"* ]] && [ ! -e "$STUB_LOG.failed" ]; then touch "$STUB_LOG.failed"; exit 1; fi
d=$(mktemp -d "$STUB_DIRS/run.XXXX"); drain=empty
[ -n "${STUB_DIRTY:-}" ] && [[ "$*" == *"$STUB_DIRTY"* ]] && drain=timeout
echo "{\"drain\": \"$drain\"}" > "$d/run.json"; echo '{"ok": true}' > "$d/invariant.json"
echo "RUN_DIR=$d"
EOF
printf '#!/usr/bin/env bash\necho "env $*" >> "$STUB_LOG"\n' > "$stub/env.sh"
chmod +x "$stub/run.sh" "$stub/env.sh"
fail=0
mkdir -p "$stub/dirs"
camp() { : > "$stub/log"; rm -f "$stub/log.failed"; STUB_LOG="$stub/log" STUB_DIRS="$stub/dirs" RUN_SH="$stub/run.sh" ENV_SH="$stub/env.sh" "$here/../campaign.sh" "$@" >/dev/null 2>&1; }
camp e1
if [ "$(grep -c '^run e1' "$stub/log")" = 9 ] && [ "$(sed -n 1,3p "$stub/log" | tr '\n' ' ')" = "run e1 --rate 20 run e1 --rate 50 run e1 --rate 100 " ]; then
  echo "ok   e1: 3 rounds of 20, 50, 100 req/s"; else echo "FAIL e1: 3 rounds of 20, 50, 100 req/s"; fail=1; fi
camp e2 4 1,2,3,4
if [ "$(grep -c '^run e2 --workers 4 --steps 1,2,3,4$' "$stub/log")" = 3 ]; then echo "ok   e2: 3 runs"; else echo "FAIL e2: 3 runs"; fail=1; fi
camp e4 0.8
if [ "$(grep -c '^run e4' "$stub/log")" = 18 ] && [ "$(sed -n 2p "$stub/log")" = "run e4 --fault c2 --submit-rate 0.8" ]; then
  echo "ok   e4: 3 rounds of c1..c6"; else echo "FAIL e4: 3 rounds of c1..c6"; fail=1; fi
STUB_FAIL_ONCE="--fault c3" camp e4 0.8
if grep -q '^env down' "$stub/log" && grep -q '^env up' "$stub/log" && [ "$(grep -c '^run e4 --fault c3' "$stub/log")" = 4 ]; then
  echo "ok   e4: a failed run re-creates the stack and is run again"; else echo "FAIL e4: a failed run re-creates the stack and is run again"; fail=1; fi
STUB_DIRTY="--fault c2" camp e4 0.8
if [ "$(grep -c '^env down' "$stub/log")" = 3 ] && [ "$(grep -c '^run e4 --fault c2' "$stub/log")" = 3 ]; then
  echo "ok   e4: a run that leaves the queue undrained is kept and the stack re-created before the next run"
else echo "FAIL e4: a run that leaves the queue undrained is kept and the stack re-created before the next run"; fail=1; fi
STUB_DIRTY="--rate 50" camp e1
if [ "$(grep -c '^env up --history' "$stub/log")" = 3 ]; then echo "ok   e1: the stack comes back seeded with --history"; else echo "FAIL e1: the stack comes back seeded with --history"; fail=1; fi
exit $fail
