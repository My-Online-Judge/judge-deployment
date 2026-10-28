#!/usr/bin/env bash
# The mock sandbox (mock-judge-server/app.py) answers like the real judge-server where the worker can tell: one result
# per test case of the bundle, a dict for /ping, the token check. stdlib only; prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
if python3 -m unittest discover -s mock-judge-server -p 'test_*.py' > /tmp/oj-mock-test.$$ 2>&1; then
  echo "ok   the mock judge-server answers one result per case of the bundle, a dict for /ping, and checks the token ($(grep -o 'Ran [0-9]* tests' /tmp/oj-mock-test.$$))"
  rm -f /tmp/oj-mock-test.$$
else
  echo "FAIL the mock judge-server's unit tests:"; sed 's/^/     /' /tmp/oj-mock-test.$$; rm -f /tmp/oj-mock-test.$$; exit 1
fi
