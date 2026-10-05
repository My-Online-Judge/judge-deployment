#!/usr/bin/env bash
# Nothing under bench/results may carry a JWT: the bench stack signs with the live .env key.
set -uo pipefail
cd "$(dirname "$0")/.."
hits=$(grep -rlE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' results 2>/dev/null)
if [ -n "$hits" ]; then echo "FAIL: JWT found in:"; echo "$hits"; exit 1; fi
echo "PASS: no JWT under results/"
