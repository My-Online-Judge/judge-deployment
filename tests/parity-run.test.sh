#!/usr/bin/env bash
# scripts/parity-run.sh refuses to start (exit 2, a message, nothing submitted) on a bad flag, a missing corpus or CA, or a gateway that
# does not answer. The runs against a stack are by hand (README "Go sandbox", Parity and memory).
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/scripts/parity-run.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

mkdir "$tmp/corpus"; echo '[]' > "$tmp/corpus/corpus.json"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=parity-test -days 1 -keyout "$tmp/ca.key" -out "$tmp/ca.crt" 2> /dev/null

# check <name> <want exit> <want output regex> <environment...> -- <arguments...>
check() {
  local name=$1 want=$2 re=$3 out rc=0
  shift 3
  local -a envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  out=$(env "${envs[@]}" bash "$script" "$@" 2>&1) || rc=$?
  if [[ $rc == "$want" ]] && grep -Eq -- "$re" <<< "$out"; then echo "ok   $name"
  else echo "FAIL $name: exit $rc (want $want), output:"; echo "$out"; fail=1; fi
}

good=(OJ_PARITY_CORPUS="$tmp/corpus" OJ_PARITY_CA="$tmp/ca.crt" OJ_PARITY_BASE=https://127.0.0.1:9)
check "an unknown flag is refused" 2 'unrecognized arguments' "${good[@]}" -- --bogus
check "--parallel above the number of test users is refused" 2 '--parallel is 1\.\.8' "${good[@]}" -- --parallel 9
check "--passes 0 is refused" 2 '--passes at least 1' "${good[@]}" -- --passes 0
check "a missing corpus is refused" 2 'no corpus at /nonexistent' OJ_PARITY_CORPUS=/nonexistent OJ_PARITY_CA="$tmp/ca.crt" --
check "a missing CA certificate is refused" 2 'no CA certificate at /nonexistent' OJ_PARITY_CORPUS="$tmp/corpus" OJ_PARITY_CA=/nonexistent --
check "a gateway that does not answer stops the run" 2 'GET /api/v1/languages' "${good[@]}" --
exit "$fail"
