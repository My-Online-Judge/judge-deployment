#!/usr/bin/env bash
# fault.sh acts only on oj-bench containers (spec §6). docker is a stub: inspect answers STUB_PROJECT.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
cat > "$stub/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
case "$1" in
  inspect) echo "${STUB_PROJECT:-oj-bench}" ;;
  ps) echo oj-bench-judge-worker-1 ;;
esac
exit 0
EOF
chmod +x "$stub/docker"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
fault() { STUB_LOG="$stub/log" PATH="$stub:$PATH" "$here/../chaos/fault.sh" "$@"; }
expect_call() { # expect_call <description> <grep pattern> <fault args…>
  local desc=$1 pat=$2; shift 2
  : > "$stub/log"
  if fault "$@" >/dev/null 2>&1 && grep -q -- "$pat" "$stub/log"; then ok "$desc"; else bad "$desc"; fi
}
expect_call "c1 stops problem-service" '^docker stop oj-problem-service$' c1 inject
expect_call "c2 crashes the first bench worker (no grace period)" '^docker stop --time 0 oj-bench-judge-worker-1$' c2 inject
expect_call "c3 restores the second sandbox" '^docker start oj-judge-server-2$' c3 remove
expect_call "c4 stops kafka" '^docker stop oj-kafka$' c4 inject
expect_call "c5 stops submission-service" '^docker stop oj-submission-service$' c5 inject
expect_call "c6 stops redis" '^docker stop oj-redis$' c6 inject

: > "$stub/log"
if STUB_PROJECT=judge-deployment fault c1 inject >/dev/null 2>&1; then bad "a live container is refused"
elif grep -qE '^docker (stop|start)' "$stub/log"; then bad "a live container is refused before any stop/start"
else ok "a container of another project is refused before any stop/start"; fi
if fault c7 inject >/dev/null 2>&1; then bad "an unknown fault is refused"; else ok "an unknown fault is refused"; fi
if fault c1 pause >/dev/null 2>&1; then bad "an unknown action is refused"; else ok "an unknown action is refused"; fi
exit $fail
