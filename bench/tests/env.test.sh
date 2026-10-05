#!/usr/bin/env bash
# env.sh never touches the live stack (spec §4.2, §6): it refuses while a live container exists, and down names
# only oj-bench. docker is a stub that logs its arguments.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
cat > "$stub/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
if [ "$1" = ps ] && [[ "$*" == *"com.docker.compose.project=judge-deployment"* ]] && [ -n "${STUB_LIVE:-}" ]; then
  echo 0123456789ab
fi
exit 0
EOF
chmod +x "$stub/docker"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
run_env() { STUB_LOG="$stub/log" PATH="$stub:$PATH" BENCH_SKIP_SEED=1 "$here/../env.sh" "$@"; }

: > "$stub/log"
if STUB_LIVE=1 run_env up 2>"$stub/err" >/dev/null; then bad "up refuses while a live container exists"
elif grep -q ' compose ' "$stub/log"; then bad "up ran compose although the live stack has containers"
else ok "up refuses while a live container exists, before any compose call"; fi
if grep -q 'live stack' "$stub/err"; then ok "the refusal names the live stack"; else bad "the refusal names the live stack"; fi

: > "$stub/log"
if run_env up >/dev/null 2>&1; then ok "up proceeds when no live container exists"; else bad "up proceeds when no live container exists"; fi
if grep -q -- 'compose -p oj-bench .* up -d --no-build --wait' "$stub/log"; then ok "up starts oj-bench without building and waits for health"
else bad "up starts oj-bench without building and waits for health"; fi

: > "$stub/log"
run_env down >/dev/null 2>&1 || true
if grep -q -- 'compose -p oj-bench .* down -v' "$stub/log" && ! grep -q -- '-p judge-deployment' "$stub/log"; then
  ok "down removes only the oj-bench project and its volumes"
else bad "down removes only the oj-bench project and its volumes"; fi

if run_env bogus >/dev/null 2>&1; then bad "an unknown command is refused"; else ok "an unknown command is refused"; fi
exit $fail
