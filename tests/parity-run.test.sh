#!/usr/bin/env bash
# scripts/parity-run.sh: its refusals (exit 2, a message, nothing submitted) and its verdict logic (exit 0 or 1), against a fake gateway
# that answers every submission with the verdict its source names. The runs against a real stack are by hand (README "Go sandbox",
# Parity and memory).
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/scripts/parity-run.sh"
tmp=$(mktemp -d)
gateway=''
cleanup() { [[ -z $gateway ]] || { kill "$gateway" 2> /dev/null; wait "$gateway" 2> /dev/null; } || true; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0

# A corpus of programs whose source is `VERDICT <status>` (what the fake gateway judges it as) or `REFUSE` (HTTP 400) or `THROTTLE`
# (the first submit gets 429 with an HTTP-date Retry-After). expect: AC 0, WA -1, RE 4.
mkdir -p "$tmp/corpus/cpp" "$tmp/corpus/javascript"
printf 'VERDICT 0\n' > "$tmp/corpus/cpp/ac.cpp"
printf 'VERDICT -1\n' > "$tmp/corpus/cpp/crlf.cpp"       # judged WA, the corpus expects AC: what qduoj does
printf 'VERDICT 4\n' > "$tmp/corpus/cpp/re.cpp"
printf 'REFUSE\n' > "$tmp/corpus/cpp/socket.cpp"          # refused by the source policy, the corpus expects RE
printf 'THROTTLE\n' > "$tmp/corpus/cpp/slow.cpp"
printf 'VERDICT 4\n' > "$tmp/corpus/javascript/ac.js"     # judged RE, the corpus expects AC: a runtime qduoj lacks
cat > "$tmp/corpus/corpus.json" << 'JSON'
[{"lang": "cpp", "file": "ac.cpp", "expect": 0},
 {"lang": "cpp", "file": "crlf.cpp", "expect": 0},
 {"lang": "cpp", "file": "re.cpp", "expect": 4},
 {"lang": "cpp", "file": "socket.cpp", "expect": 4},
 {"lang": "cpp", "file": "slow.cpp", "expect": 0},
 {"lang": "javascript", "file": "ac.js", "expect": 0}]
JSON
mkdir "$tmp/empty"; echo '[]' > "$tmp/empty/corpus.json"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=parity-test -days 1 -addext 'subjectAltName=IP:127.0.0.1' \
  -keyout "$tmp/ca.key" -out "$tmp/ca.crt" 2> /dev/null

cat > "$tmp/gateway.py" << 'PY'
import http.server, itertools, json, ssl, sys, threading
port_file, crt, key = sys.argv[1:4]
counter, verdicts, throttled, lock = itertools.count(1), {}, set(), threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, headers=None):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw)
        except ValueError:
            return {}

    def do_GET(self):
        if self.path.startswith("/api/v1/submissions/"):
            status = verdicts[int(self.path.rsplit("/", 1)[1])]
            return self.reply(200, {"data": {"status": status, "details": [{"result": status}] * 3}})
        if self.path == "/api/v1/roles":
            return self.reply(200, {"data": [{"name": "USER", "id": "role-user"}]})
        self.reply(200, {"data": []})   # languages, problems

    def do_POST(self):
        body = self.body()
        if self.path == "/api/v1/submissions":
            source = body.get("sourceCode", "")
            if "REFUSE" in source:
                return self.reply(400, {"message": "Line 2: header <sys/socket.h> is not available on this judge"})
            with lock:
                if "THROTTLE" in source and body.get("problemSlug") not in throttled:
                    throttled.add(body.get("problemSlug"))
                    return self.reply(429, {"message": "slow down"}, {"Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"})
                n = next(counter)
                verdicts[n] = int(source.split()[1]) if source.startswith("VERDICT") else 0
            return self.reply(200, {"data": {"id": n}})
        self.reply(201 if self.path == "/api/v1/users" else 200, {"data": {}})

    do_PUT = do_POST

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(crt, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
open(port_file, "w").write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$tmp/gateway.py" "$tmp/port" "$tmp/ca.crt" "$tmp/ca.key" &
gateway=$!
for _ in $(seq 1 50); do [[ -s $tmp/port ]] && break; sleep 0.1; done
[[ -s $tmp/port ]] || { echo "FAIL the fake gateway did not start"; exit 1; }
base="https://127.0.0.1:$(cat "$tmp/port")"

# check <name> <want exit> <want output regex> <environment...> -- <arguments...>   (stdout and stderr are both searched)
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
exceptions() { printf '%s\n' "$@" > "$tmp/exceptions.txt"; echo "OJ_PARITY_EXCEPTIONS=$tmp/exceptions.txt"; }

fake=(OJ_PARITY_CORPUS="$tmp/corpus" OJ_PARITY_CA="$tmp/ca.crt" OJ_PARITY_BASE="$base" OJ_PARITY_COOLDOWN=0 OJ_PARITY_POLL=0.05 OJ_ADMIN_PASSWORD=x)
offline=(OJ_PARITY_CORPUS="$tmp/corpus" OJ_PARITY_CA="$tmp/ca.crt" OJ_PARITY_BASE=https://127.0.0.1:9)

# refusals: nothing is submitted
check "an unknown flag is refused" 2 'unrecognized arguments' "${offline[@]}" -- --bogus
check "--parallel above the number of test users is refused" 2 '--parallel is 1\.\.8' "${offline[@]}" -- --parallel 9
check "--passes 0 is refused" 2 '--passes at least 1' "${offline[@]}" -- --passes 0
check "an unknown --baseline is refused" 2 "invalid choice" "${offline[@]}" -- --baseline gunicorn
check "a missing corpus is refused" 2 'no corpus at /nonexistent' OJ_PARITY_CORPUS=/nonexistent OJ_PARITY_CA="$tmp/ca.crt" --
check "a missing CA certificate is refused" 2 'no CA certificate at /nonexistent' OJ_PARITY_CORPUS="$tmp/corpus" OJ_PARITY_CA=/nonexistent --
check "an empty corpus is refused" 2 'lists no program' OJ_PARITY_CORPUS="$tmp/empty" OJ_PARITY_CA="$tmp/ca.crt" OJ_PARITY_BASE="$base" --
check "--only naming no program is refused" 2 'names no program of the corpus: cpp/nope.cpp' "${fake[@]}" -- --only cpp/nope.cpp
check "--only with one name that is none is refused too" 2 'names no program of the corpus: cpp/nope.cpp' "${fake[@]}" -- --only cpp/ac.cpp --only cpp/nope.cpp
check "a baseline run of only skipped programs has nothing to run" 2 'skipped by --baseline' "${fake[@]}" -- --baseline qduoj --only javascript/ac.js
check "a malformed exceptions line is refused" 2 'expected `<lang>/<file> <got>-><expected>`' "${fake[@]}" "$(exceptions 'cpp/crlf.cpp WA')" -- --only cpp/ac.cpp
check "a gateway that does not answer stops the run" 2 'GET /api/v1/languages' "${offline[@]}" -- --only cpp/ac.cpp

# verdict logic. crlf is judged WA and expected AC; socket is refused and expected RE; javascript is judged RE and expected AC
check "every verdict as expected: exit 0" 0 '^cpp +ac.cpp +AC +AC +cases=AC,AC,AC' "${fake[@]}" "$(exceptions)" -- --only cpp/ac.cpp --only cpp/re.cpp
check "an unlisted mismatch is exit 1" 1 'MISMATCH cpp/crlf.cpp: expected AC, got WA' "${fake[@]}" "$(exceptions)" -- --only cpp/crlf.cpp
check "a listed divergence is accepted in a baseline run" 0 '1 accepted' "${fake[@]}" "$(exceptions 'cpp/crlf.cpp WA->AC')" -- --baseline qduoj --only cpp/crlf.cpp
check "the same divergence is a regression in a run against the Go sandbox" 1 'MISMATCH cpp/crlf.cpp: expected AC, got WA' \
  "${fake[@]}" "$(exceptions 'cpp/crlf.cpp WA->AC')" -- --only cpp/crlf.cpp
check "an exception in the other direction accepts nothing" 1 'MISMATCH cpp/crlf.cpp' "${fake[@]}" "$(exceptions 'cpp/crlf.cpp AC->WA')" -- --baseline qduoj --only cpp/crlf.cpp
check "an exception for another program accepts nothing" 1 'MISMATCH cpp/crlf.cpp' "${fake[@]}" "$(exceptions 'cpp/re.cpp WA->AC')" -- --baseline qduoj --only cpp/crlf.cpp

# the source policy: HTTP 400 is a REFUSED row, accepted by its own exception line in either mode, never by silence
check "a refused submit is a REFUSED row and a mismatch when unlisted" 1 'cpp +socket.cpp +RE +REFUSED +refused=.*not available on this judge' \
  "${fake[@]}" "$(exceptions)" -- --only cpp/socket.cpp
check "a REFUSED exception line is accepted against the Go sandbox" 0 '1 accepted' "${fake[@]}" "$(exceptions 'cpp/socket.cpp REFUSED->RE')" -- --only cpp/socket.cpp
check "a REFUSED exception line is accepted in a baseline run too" 0 '1 accepted' \
  "${fake[@]}" "$(exceptions 'cpp/socket.cpp REFUSED->RE')" -- --baseline qduoj --only cpp/socket.cpp

# javascript and php: a baseline run does not submit them (qduoj has no runtime), a Go run does
check "a baseline run skips the javascript program" 0 '1 javascript and php programs skipped' "${fake[@]}" "$(exceptions)" -- --baseline qduoj --only javascript/ac.js --only cpp/ac.cpp
check "a baseline run prints no javascript row" 0 '^cpp +ac.cpp' "${fake[@]}" "$(exceptions)" -- --baseline qduoj --only javascript/ac.js --only cpp/ac.cpp
out=$(env "${fake[@]}" "$(exceptions)" bash "$script" --baseline qduoj --only javascript/ac.js --only cpp/ac.cpp 2> /dev/null)
if grep -q '^javascript' <<< "$out"; then echo "FAIL a baseline run printed a javascript row"; fail=1; else echo "ok   the table of a baseline run has no javascript row"; fi
check "a Go run judges the javascript program: a wrong verdict is exit 1" 1 'MISMATCH javascript/ac.js: expected AC, got RE' "${fake[@]}" "$(exceptions)" -- --only javascript/ac.js

# a Retry-After that is an HTTP-date must not crash the run
check "a 429 with an HTTP-date Retry-After is waited out, not a crash" 0 '^cpp +slow.cpp +AC +AC' "${fake[@]}" "$(exceptions)" -- --only cpp/slow.cpp
exit "$fail"
