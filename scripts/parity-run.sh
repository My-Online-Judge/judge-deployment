#!/usr/bin/env bash
# Parity run of the sandbox: submits every program of the judge-server corpus through the gateway, as test users, waits for
# each verdict and compares it with what corpus.json expects (spec docs/superpowers/specs/2026-11-08-go-judge-server-design.md
# section 9.3). Run it against the stack whose sandbox you want to check; to compare two sandboxes, run it once per stack and
# diff the two tables (README "Go sandbox", "Parity and memory").
#
#   scripts/parity-run.sh [--baseline qduoj] [--parallel N] [--passes N] [--only lang/file ...]   the corpus, then the checker set
#   scripts/parity-run.sh --latency N         N submissions of cpp/ac.cpp on a 20-case problem (each must be AC)
#   scripts/parity-run.sh --latency-worst N   N submissions of a program that is over the CPU limit on all 20 cases (each must be CPU_TLE)
#
# stdout is the table, one line per program in corpus order:   lang file expected got cases=<result of each case>
# (names: AC WA CPU_TLE REAL_TLE MLE RE SE CE; `REFUSED` is a submit the platform's source policy answered with 400, so the
# program never reaches a sandbox). Progress and the summary go to stderr. Exit 0: every verdict is as expected or listed in
# scripts/parity-exceptions.txt; 1: a verdict differs from the corpus and is not listed; 2: the run could not be made (also a
# crash of this script, never 1).
#
# The exceptions file says which differences are accepted. A line whose `got` is REFUSED always applies (the platform refuses the same
# source whatever sandbox is behind it). The other lines are the divergences of the qduoj sandbox from the corpus (the corpus describes the
# Go sandbox) and apply only with `--baseline qduoj`: run against the Go sandbox they would hide a regression. `--baseline qduoj` also skips
# the javascript and php programs, which the qduoj image has no runtime for (the migration that offers them, V11, belongs to the Go image).
#
# Setup is idempotent and made through the admin API: test users parity_1..parity_N (their passwords are random for each run
# and reset when the user exists) and the problems parity-sum-128 (1 s, 128 MiB, three cases of "a + b"), parity-sum-java
# (the same at 256 MiB, which Java's row allows), parity-checker (the same with a checker, replaced per checker program)
# and, for --latency, parity-sum-20. Submissions are made by the test users, one submission cooldown each, in turn.
#
# --parallel N   N submissions at once (default 1); the checker programs always run one at a time, after the others, because
#                they replace the checker of one problem
# --passes N     the whole run N times (default 1), e.g. 2 passes of 8 parallel submissions for the memory check
# --only X       only this program (repeatable; `lang/file`, or `checker/<checker>+<submission>`); a name that is none is refused
#
# Environment: OJ_PARITY_BASE (default https://localhost), OJ_PARITY_CA (default pki/out/ca/ca.crt),
# OJ_PARITY_CORPUS (default ../judge-server/testdata/corpus), OJ_PARITY_EXCEPTIONS (default scripts/parity-exceptions.txt),
# OJ_ADMIN_PASSWORD (default: .env, else the seeded admin password), OJ_PARITY_COOLDOWN (seconds between two submissions of
# one user, default 10.5: SUBMISSION_COOLDOWN_SECONDS of submission-service is 10), OJ_PARITY_POLL (seconds between two polls of a
# verdict, default 0.5).
set -euo pipefail

dep=${OJ_DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export OJ_PARITY_BASE=${OJ_PARITY_BASE:-https://localhost}
export OJ_PARITY_CA=${OJ_PARITY_CA:-$dep/pki/out/ca/ca.crt}
export OJ_PARITY_CORPUS=${OJ_PARITY_CORPUS:-$(dirname "$dep")/judge-server/testdata/corpus}
export OJ_PARITY_EXCEPTIONS=${OJ_PARITY_EXCEPTIONS:-$dep/scripts/parity-exceptions.txt}
if [[ -z ${OJ_ADMIN_PASSWORD:-} ]]; then
  OJ_ADMIN_PASSWORD=$(grep '^OJ_ADMIN_PASSWORD=' "$dep/.env" 2> /dev/null | cut -d= -f2- || true)
  export OJ_ADMIN_PASSWORD=${OJ_ADMIN_PASSWORD:-Admin@12345}   # the root admin identity's V2 migration seeds it
fi

command -v python3 > /dev/null || { echo "parity-run.sh: python3 is not installed" >&2; exit 2; }
exec python3 - "$@" << 'PY'
import argparse, http.cookiejar, io, json, os, queue, secrets, ssl, statistics, sys, threading, time, urllib.error, urllib.request, uuid, zipfile

BASE, CA = os.environ["OJ_PARITY_BASE"], os.environ["OJ_PARITY_CA"]
CORPUS, EXCEPTIONS = os.environ["OJ_PARITY_CORPUS"], os.environ["OJ_PARITY_EXCEPTIONS"]
ADMIN_PASSWORD = os.environ["OJ_ADMIN_PASSWORD"]
COOLDOWN = float(os.environ.get("OJ_PARITY_COOLDOWN", "10.5"))
POLL = float(os.environ.get("OJ_PARITY_POLL", "0.5"))
USERS = 8
BASELINE_SKIPPED = ("javascript", "php")   # --baseline qduoj: the qduoj image has neither runtime

NAMES = {-2: "CE", -1: "WA", 0: "AC", 1: "CPU_TLE", 2: "REAL_TLE", 3: "MLE", 4: "RE", 5: "SE", 8: "PARTIAL"}
PENDING, JUDGING = 6, 7
LANGUAGES = ("c", "cpp", "java", "python2", "python3", "go", "javascript", "php")

# Problems: slug -> (time limit ms, memory limit MiB, cases). The three cases of the corpus' "a + b" are the ones the
# engine tests use; the 20-case problem is for --latency.
SUM3 = [(1, 2), (10, 20), (-5, 5)]
SUM20 = [(i * 7 - 40, i * 13 + 3) for i in range(20)]
PROBLEMS = {
    "parity-sum-128": (1000, 128, SUM3),
    "parity-sum-java": (1000, 256, SUM3),
    "parity-checker": (1000, 128, SUM3),
    "parity-sum-20": (1000, 128, SUM20),
}
# --latency-worst: over the CPU limit on every case (the volatile counter keeps the loop from being optimised away).
WORST_SOURCE = "int main() { volatile unsigned long x = 0; for (;;) x++; }\n"
# The checker set (TestEngineCheckerCorpus): checker program, submission, expected status. spj_crash and spj_ce are system
# errors: a crashing checker is a failed case, a checker that does not compile fails the whole submission.
CHECKERS = [
    ("ok.cpp", "ac.cpp", 0), ("wa.cpp", "ac.cpp", -1), ("spj.cpp", "ac.cpp", 0), ("spj.cpp", "wa.cpp", -1),
    ("spj_crash.cpp", "ac.cpp", 5), ("spj_ce.cpp", "ac.cpp", 5),
]


def die(message):
    print(f"parity-run.sh: {message}", file=sys.stderr, flush=True)
    os._exit(2)   # not sys.exit: this is also called from the worker threads


def log(message):
    print(message, file=sys.stderr, flush=True)


class Session:
    """One user's cookie jar, the credentials to sign in again when the session expires in a long run, and the time its next
    submission may be made."""

    def __init__(self):
        jar = http.cookiejar.CookieJar()
        ctx = ssl.create_default_context(cafile=CA)
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler(context=ctx))
        self.ready_at = 0.0
        self.credentials = None

    def call(self, method, path, body=None, raw=None, headers=None, again=True):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        hdrs = {"Content-Type": "application/json"} if body is not None else {}
        hdrs.update(headers or {})
        request = urllib.request.Request(BASE + path, data=data, method=method, headers=hdrs)
        try:
            with self.opener.open(request, timeout=60) as response:
                code, text, rheaders = response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            code, text, rheaders = error.code, error.read(), error.headers
        except (urllib.error.URLError, OSError) as error:
            die(f"{method} {path}: {error}")
        if code == 401 and again and self.credentials and path != "/api/v1/auth/login":   # the session expired: sign in, once more
            self.login(*self.credentials)
            return self.call(method, path, body, raw, headers, again=False)
        try:
            return code, json.loads(text or b"{}"), rheaders
        except ValueError:
            return code, {"raw": text[:300].decode(errors="replace")}, rheaders

    def login(self, username, password):
        self.credentials = (username, password)
        code, body, _ = self.call("POST", "/api/v1/auth/login", {"username": username, "password": password})
        if code != 200:
            die(f"login of {username}: HTTP {code} {body}")


def multipart(parts):
    boundary = uuid.uuid4().hex
    chunks = []
    for name, ctype, filename, content in parts:
        disposition = f'form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        chunks.append(f"--{boundary}\r\nContent-Disposition: {disposition}\r\nContent-Type: {ctype}\r\n\r\n".encode() + content + b"\r\n")
    return b"".join(chunks) + f"--{boundary}--\r\n".encode(), {"Content-Type": f"multipart/form-data; boundary={boundary}"}


# ---- setup (admin) ---------------------------------------------------------------------------------------------------

def ensure_users(admin, count):
    """parity_1..count with a fresh random password each; returns their sessions, logged in."""
    code, body, _ = admin.call("GET", "/api/v1/roles")
    roles = {r["name"]: r["id"] for r in (body.get("data") or [])} if code == 200 else {}
    if "USER" not in roles:
        die(f"the admin cannot list the USER role (HTTP {code})")
    sessions = []
    for i in range(1, count + 1):
        username, password = f"parity_{i}", secrets.token_urlsafe(18) + "a1"
        code, body, _ = admin.call("POST", "/api/v1/users", {"username": username, "name": f"Parity test user {i}", "email": f"{username}@example.test",
                                                              "password": password, "status": 1, "roleIds": [roles["USER"]]})
        if code not in (200, 201):   # taken (or refused): find it and replace its password
            refusal = f"HTTP {code} {body.get('message')}"
            code, body, _ = admin.call("GET", f"/api/v1/users?search={username}&size=50")
            found = [u for u in (body.get("data") or []) if u.get("username") == username]
            if code != 200 or not found:
                die(f"user {username} can be neither created ({refusal}) nor found (HTTP {code})")
            code, body, _ = admin.call("POST", f"/api/v1/users/{found[0]['id']}/reset-password", {"newPassword": password})
            if code != 200:
                die(f"reset of the password of {username}: HTTP {code} {body}")
        session = Session()
        session.login(username, password)
        sessions.append(session)
    return sessions


def bundle_zip(cases):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as z:
        for i, (a, b) in enumerate(cases, 1):
            z.writestr(f"{i}.in", f"{a} {b}\n")
            z.writestr(f"{i}.out", f"{a + b}\n")
    return buffer.getvalue()


def ensure_problem(admin, slug):
    code, body, _ = admin.call("GET", f"/api/v1/problems/{slug}")
    if code == 200:
        return
    time_limit, memory, cases = PROBLEMS[slug]
    meta = json.dumps({"title": f"Parity: {slug}", "subject": "<p>Print the sum of two integers.</p>", "description": "<p>Read $a$ and $b$.</p>",
                       "timeLimit": time_limit, "memoryLimit": memory, "hardnessLevel": 1, "problemSlug": slug,
                       "inputDescription": "<p>Two integers.</p>", "outputDescription": "<p>Their sum.</p>",
                       "sampleInput": "1 2", "sampleOutput": "3", "status": "ACTIVE"}).encode()
    raw, headers = multipart([("data", "application/json", None, meta), ("file", "application/zip", "cases.zip", bundle_zip(cases))])
    code, body, _ = admin.call("POST", "/api/v1/problems", raw=raw, headers=headers)
    if code not in (200, 201):
        die(f"create problem {slug}: HTTP {code} {body}")
    log(f"created problem {slug}")


def put_checker(admin, slug, source):
    raw, headers = multipart([("file", "text/x-c++src", "spj.cpp", source.encode())])
    code, body, _ = admin.call("PUT", f"/api/v1/problems/{slug}/checker", raw=raw, headers=headers)
    if code != 200:
        die(f"upload of the checker of {slug}: HTTP {code} {body}")


# ---- one submission --------------------------------------------------------------------------------------------------

class Users:
    """The test users in turn: the one idle longest comes next, after its cooldown."""

    def __init__(self, sessions):
        self.idle = queue.Queue()
        for s in sessions:
            self.idle.put(s)

    def acquire(self):
        session = self.idle.get()
        wait = session.ready_at - time.time()
        if wait > 0:
            time.sleep(wait)
        return session

    def release(self, session):
        self.idle.put(session)


def retry_after(headers, default=3.0):
    """Seconds to wait as the Retry-After header says; an HTTP-date (or nothing readable) gets the default."""
    try:
        return max(0.0, float(headers.get("Retry-After") or default))
    except ValueError:
        return default


def judge(users, slug, language, source, poll=None, patience=420):
    """Submits source as the next test user; returns (verdict name or marker, per-case results, seconds). A marker is REFUSED (HTTP 400),
    ERR_* or TIMEOUT; for REFUSED and ERR_* the "results" are the reason, a string."""
    poll = POLL if poll is None else poll
    session = users.acquire()
    try:
        payload = {"sourceCode": source, "languageIdentifier": language, "problemSlug": slug}
        for _ in range(40):
            started = time.time()
            code, body, headers = session.call("POST", "/api/v1/submissions", payload)
            session.ready_at = started + COOLDOWN
            if code == 200 and (body.get("data") or {}).get("id"):
                break
            if code == 400:
                return "REFUSED", str(body.get("message") or body.get("error") or body)[:100], 0.0
            if code in (429, 503):   # cooldown or a full queue: wait as told
                time.sleep(retry_after(headers) + 0.5)
                continue
            return f"ERR_HTTP_{code}", str(body)[:100], 0.0
        else:
            return "ERR_THROTTLED", "429 or 503 for 40 attempts in a row", 0.0
        submission = body["data"]["id"]
        while time.time() - started < patience:
            time.sleep(poll)
            code, body, _ = session.call("GET", f"/api/v1/submissions/{submission}")
            data = body.get("data") or {}
            status = data.get("status", PENDING)
            if code == 200 and status not in (PENDING, JUDGING):
                wall = time.time() - started
                return NAMES.get(status, f"STATUS_{status}"), [d.get("result") for d in data.get("details") or []], wall
        return "TIMEOUT", [], time.time() - started
    finally:
        users.release(session)


# ---- the run ---------------------------------------------------------------------------------------------------------

def load_exceptions(baseline):
    """The accepted differences as {(program, "got->expected")}: the REFUSED ones always, the others only for a baseline run."""
    allowed = set()
    if os.path.exists(EXCEPTIONS):
        for number, line in enumerate(open(EXCEPTIONS), 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2 or "->" not in parts[1]:
                die(f"{EXCEPTIONS}:{number}: expected `<lang>/<file> <got>-><expected>`, got {line!r}")
            if baseline or parts[1].startswith("REFUSED->"):
                allowed.add((parts[0], parts[1]))
    return allowed


def read_source(path):
    try:
        return open(path).read()
    except OSError as error:
        die(f"cannot read {path}: {error}")


def corpus_programs():
    """Every program of corpus.json that has a file, as {key, lang, file, expect}."""
    try:
        listed = json.load(open(f"{CORPUS}/corpus.json"))
        return [{"key": f"{e['lang']}/{e['file']}", "lang": e["lang"], "file": e["file"], "expect": e["expect"]}
                for e in listed if "file" in e and e["lang"] in LANGUAGES]
    except (OSError, ValueError, KeyError, TypeError) as error:
        die(f"{CORPUS}/corpus.json: {error!r}")


def checker_key(checker, submission):
    return f"checker/{checker}+{submission}"


def cases_text(got, results):
    """The column after the verdicts: the result of each case, or why the submit was refused or failed."""
    if isinstance(results, str):
        return f"{'refused' if got == 'REFUSED' else 'error'}={results!r}"
    return "cases=" + (",".join(NAMES.get(r, str(r)) for r in results) or "-")


def run_one(users, entry):
    got, results, wall = judge(users, entry["slug"], entry["submit_lang"], entry["source"])
    expected = NAMES[entry["expect"]]
    entry["got"], entry["cases"], entry["wall"] = got, cases_text(got, results), wall
    log(f"  {entry['key']:30s} expected {expected:8s} got {got:8s} {wall:5.1f}s")


def run_pass(admin, users, entries, checkers, parallel):
    """Judges the corpus entries `parallel` at a time, then the checker set one at a time (each program replaces the checker of the one
    problem). Returns the entries, then the checker entries, with their verdicts."""
    todo = queue.Queue()
    for e in entries:
        todo.put(e)

    def worker():
        while True:
            try:
                run_one(users, todo.get_nowait())
            except queue.Empty:
                return

    threads = [threading.Thread(target=worker) for _ in range(parallel)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for c in checkers:
        put_checker(admin, "parity-checker", c["checker_source"])
        run_one(users, c)
    return entries + checkers


def report(rows, allowed):
    """Prints the table; returns (verdicts that differ and are not listed, verdicts that differ and are listed)."""
    unexpected = excepted = 0
    for e in rows:
        expected = NAMES[e["expect"]]
        print(f"{e['lang']:10s} {e['file']:24s} {expected:8s} {e['got']:8s} {e['cases']}")
        if e["got"] != expected:
            if (e["key"], f"{e['got']}->{expected}") in allowed:
                excepted += 1
            else:
                unexpected += 1
                log(f"MISMATCH {e['key']}: expected {expected}, got {e['got']} (not accepted by {os.path.basename(EXCEPTIONS)})")
    return unexpected, excepted


def latency(users, slug, label, source, expected, runs):
    """`runs` submissions, one after the other; each must end as `expected`, or the times mean nothing (exit 1)."""
    walls, wrong = [], 0
    for i in range(1, runs + 1):
        got, _, wall = judge(users, slug, "cpp", source, poll=min(POLL, 0.25))
        walls.append(wall)
        wrong += got != expected
        print(f"{label} run={i} verdict={got} wall={wall:.2f}s")
    print(f"{label} median={statistics.median(walls):.2f}s min={min(walls):.2f}s max={max(walls):.2f}s")
    if wrong:
        log(f"{wrong} of {runs} runs did not end as {expected}")
    sys.exit(1 if wrong else 0)


def main():
    parser = argparse.ArgumentParser(prog="parity-run.sh")
    parser.add_argument("--parallel", type=int, default=1)
    parser.add_argument("--passes", type=int, default=1)
    parser.add_argument("--latency", type=int, default=0, metavar="N")
    parser.add_argument("--latency-worst", type=int, default=0, metavar="N")
    parser.add_argument("--baseline", choices=["qduoj"])
    parser.add_argument("--only", action="append", default=[], metavar="lang/file")
    args = parser.parse_args()
    if args.parallel < 1 or args.passes < 1 or args.latency < 0 or args.latency_worst < 0 or args.parallel > USERS:
        die(f"--parallel is 1..{USERS}, --passes at least 1")
    if args.latency and args.latency_worst:
        die("--latency and --latency-worst are two runs")
    if not os.path.exists(f"{CORPUS}/corpus.json"):
        die(f"no corpus at {CORPUS} (OJ_PARITY_CORPUS)")
    if not os.path.exists(CA):
        die(f"no CA certificate at {CA} (OJ_PARITY_CA; scripts/local-stack.sh init makes it)")

    # What to run is settled before the gateway is asked anything.
    only, entries, checkers, allowed = set(args.only), [], [], set()
    if not (args.latency or args.latency_worst):
        programs = corpus_programs()
        if not programs:
            die(f"{CORPUS}/corpus.json lists no program")
        checks = [(c, s, x, checker_key(c, s)) for c, s, x in CHECKERS]
        unknown = sorted(only - {p["key"] for p in programs} - {k for *_, k in checks})
        if unknown:
            die(f"--only names no program of the corpus: {', '.join(unknown)}")
        skipped = [p["key"] for p in programs if args.baseline and p["lang"] in BASELINE_SKIPPED and (not only or p["key"] in only)]
        for p in programs:
            if (only and p["key"] not in only) or (args.baseline and p["lang"] in BASELINE_SKIPPED):
                continue
            entries.append({**p, "submit_lang": p["lang"], "slug": "parity-sum-java" if p["lang"] == "java" else "parity-sum-128",
                            "source": read_source(f"{CORPUS}/{p['lang']}/{p['file']}")})
        for checker, submission, expect, key in checks:
            if not only or key in only:
                checkers.append({"key": key, "lang": "checker", "file": f"{checker}+{submission}", "submit_lang": "cpp", "expect": expect,
                                 "slug": "parity-checker", "source": read_source(f"{CORPUS}/cpp/{submission}"),
                                 "checker_source": read_source(f"{CORPUS}/checker/{checker}")})
        if not entries and not checkers:
            die("no program to run: " + ("everything selected is skipped by --baseline" if skipped else "--only selects none"))
        if skipped:
            log(f"baseline {args.baseline}: {len(skipped)} javascript and php programs skipped (the image has neither runtime)")
        allowed = load_exceptions(args.baseline == "qduoj")

    admin = Session()
    code, _, _ = admin.call("GET", "/api/v1/languages")
    if code != 200:
        die(f"the gateway at {BASE} does not answer (HTTP {code}): is the stack up?")
    admin.login("admin", ADMIN_PASSWORD)
    slugs = ["parity-sum-20"] if (args.latency or args.latency_worst) else ["parity-sum-128", "parity-sum-java", "parity-checker"]
    for slug in slugs:
        ensure_problem(admin, slug)
    users = Users(ensure_users(admin, USERS))

    if args.latency:
        latency(users, "parity-sum-20", "latency parity-sum-20 (20 cases) cpp/ac.cpp", read_source(f"{CORPUS}/cpp/ac.cpp"), "AC", args.latency)
    if args.latency_worst:
        latency(users, "parity-sum-20", "latency-worst parity-sum-20 (20 cases, every one over the CPU limit)", WORST_SOURCE, "CPU_TLE",
                args.latency_worst)

    unexpected = excepted = 0
    for n in range(1, args.passes + 1):
        log(f"pass {n} of {args.passes}: {len(entries)} corpus programs and {len(checkers)} checker runs, {args.parallel} at once")
        if args.passes > 1:
            print(f"# pass {n}")
        rows = run_pass(admin, users, [dict(e) for e in entries], [dict(c) for c in checkers], args.parallel)
        u, x = report(rows, allowed)
        unexpected, excepted = unexpected + u, excepted + x
    log(f"{unexpected} verdicts differ from the corpus and are not accepted by {os.path.basename(EXCEPTIONS)}; {excepted} accepted")
    sys.exit(1 if unexpected else 0)


try:
    main()
except SystemExit:
    raise
except BaseException as error:   # a crash must never look like the exit 1 of a mismatch
    die(f"{type(error).__name__}: {error}")
PY
