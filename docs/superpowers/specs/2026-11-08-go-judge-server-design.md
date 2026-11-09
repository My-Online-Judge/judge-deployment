# Design: Go judge server (sandbox) replacing qduoj/judge-server

Date: 2026-11-08. Status: approved by the owner on 2026-11-08 (reviewer's questions answered, §11). Source: brainstorming with the project owner on 2026-11-08, grounded in
the current contract between `judge-worker`, `oj-submission-service` and the qduoj sandbox (`judge-deployment`
compose). Related: `2026-10-28-k3s-judge-pod-spec.md` (the sandbox stays a sidecar in the Judge Pod; this design
changes what the sidecar is, not the pod shape).

Decisions the owner made are marked **(owner)**. Everything else is the designer's call and may be revisited.

## 1. Intent

The two qduoj sandboxes are the largest memory consumers in the stack: each is capped at 3 GiB plus 1.25 GiB of tmpfs
(`x-sandbox`), and the caps are needed because qduoj runs every test case of a submission in parallel with no bound,
compiles with a 1 GiB allowance, and carries a Python/gunicorn baseline. Replace them with a Go server that does the
same job with the same idea (a small HTTP-style request/response judge that compiles, runs each case under
`setrlimit` + seccomp + setuid, compares output md5s, and reports one result per case) but:

- speaks gRPC over mutual TLS instead of HTTP JSON **(owner)**,
- runs a bounded number of cases at once and fits in 1.5 GiB per sandbox **(owner)**,
- is adjusted to this system's conventions (bundle layout, checker convention, heartbeat fields, clear error
  classes) rather than carrying qduoj's generic ones.

Success: the same submission corpus (AC/WA/TLE/MLE/RE/CE/SE in all eight languages, a checker problem, a Run request)
gives the same verdicts on the Go sandbox as on qduoj; both sandboxes together stay under 3 GiB at peak; nothing in
submission-service or problem-service changes meaning.

## 2. Goals, non-goals, anti-goals

Goals

- Drop-in for the worker: the worker's contract (request fields, result fields, verdict codes, failover semantics,
  heartbeat relay) is preserved at the gRPC layer; only the transport client in the worker changes.
- All eight seeded languages work on day one: C, C++, Java, Python 2, Python 3, Go, JavaScript, PHP **(owner)**.
- Memory: 1.5 GiB container cap per sandbox **(owner)**, 2 CPUs, both sandboxes ≤ 3 GiB at peak. See §6.
- Same hardening posture as today's compose: non-privileged, `cap_drop ALL` + the same six capabilities, read-only
  root, tmpfs work dir, `sandbox-net` only, mutual TLS.
- Conformance is testable without a real sandbox: a Go mock sharing the proto types replaces the Python mock.

Non-goals

- Rewriting `judge-worker` in Go. The worker keeps Kafka, MinIO sync, failover, heartbeat and DLQ handling; the gRPC
  contract is the seam, and a Go worker remains possible later as its own project.
- Changing the bundle format, the `SubmissionRequestedEvent`, the `JudgedEvent`, or any verdict code.
- cgroup-based limits. Neither compose nor the k3s pod gives the sandbox a writable cgroup fs without privilege;
  limits are `setrlimit` + the container cap, as today. A cgroup backend can be added later behind the same
  interface.
- Short-circuiting after the first failing case. The worker requires one result per case and the portal shows
  every case; keep judging them all.
- Java without the security-manager policy. JDK 17 still honours `java.policy`; its retirement is tied to a JDK
  upgrade, which is out of scope.

Anti-goals (a build that does these has failed even if it "works")

- A sandbox that needs `privileged`, `CAP_SYS_ADMIN`, or a route to Kafka/MinIO/Postgres.
- A response with fewer results than the bundle has cases, or a verdict code outside `-2..5`.
- A compile or run whose output can fill the tmpfs or the response (unbounded output).
- Honouring a `test_case_id` that escapes `/test_case` (path traversal), or a `src_name`/`exe_name` that resolves
  outside the job directory.

## 3. Constraints from the current system (facts, verified 2026-11-08)

- Caller: `judge-worker/dispatcher.py` builds the body from the event; fields: `src`, `language_config`
  (`compile{src_name, exe_name, max_cpu_time, max_real_time, max_memory, compile_command, env[]}`,
  `run{command, seccomp_rule, env[], memory_limit_check_only}`), `max_cpu_time` (ms), `max_memory` (bytes),
  `output` (bool, default true), and either `test_case_id` (string `<slug>__<hash>`, a directory under
  `/test_case`) or `test_case[]` (inline `{input, output}` for a Run), plus when the problem has a checker:
  `spj_version`, `spj_config{exe_name, command, seccomp_rule}`, `spj_compile_config{src_name, exe_name, max_cpu_time,
  max_real_time, max_memory, compile_command, env[]}`, `spj_src`.
- Placeholders in commands: `{src_path}`, `{exe_path}`, `{exe_dir}`, and in the checker command `{in_file_path}`,
  `{user_out_file_path}`. Commands are split on single spaces (qduoj's `split(" ")`), no shell.
- Rows in `t_languages` (V2, V3, V9) are the only source of commands. They name literal binaries: `/usr/bin/gcc`,
  `/usr/bin/g++`, `/usr/bin/javac`, `/usr/bin/java`, `/usr/bin/python`, `/usr/bin/python3`, `/usr/bin/go`,
  `/usr/bin/node`, `/usr/bin/php`. The Python 3 row's `exe_name` is `__pycache__/solution.cpython-36.pyc`. The Java
  row runs with `-Djava.security.manager -Djava.security.policy==/opt/oj/java.policy` (file from
  `judge-deployment/sandbox/java.policy`). Seccomp rule names in use: `c_cpp`, `general`, `''`/NULL (none).
- `JudgeService` (submission-service) marks `java` and `go` as `memory_limit_check_only = 1` (`javascript` joins them
  with the cut-over, §5.3); sets compile env for Go
  (`GOCACHE=/tmp`, `GOPATH=/root/go`) and run env (`GODEBUG=madvdontneed=1`); checker constants: exe `spj-{spj_version}`,
  source `spj-{spj_version}.cpp`, command `{exe_path} {in_file_path} {user_out_file_path}`, seccomp `c_cpp`, compile
  10 s CPU / 20 s real.
- Bundle (`TestCaseBundleBuilder`): files `N.in`, `N.out`, `info` = `{test_case_number, spj, [spj_version],
  test_cases: {"N": {input_name, input_size, output_name, output_size, output_md5, stripped_output_md5}}}`.
  `stripped_output_md5` is the md5 of the output with trailing whitespace stripped (`comparedOutput`).
- Response the worker understands (`handler.py`, `verdict.py`): `{"err": null, "data": [case...]}` with
  `case = {cpu_time, real_time, memory, signal, exit_code, error, result, test_case, output_md5, output}`;
  or `{"err": "CompileError"|"SPJCompileError"|other, "data": "<text>"}`. `result` codes: -1 WA, 0 AC, 1 CPU TLE,
  2 real TLE, 3 MLE, 4 RE, 5 SE. `error != 0` anywhere → SYSTEM_ERROR. Fewer results than `test_case_number` →
  SYSTEM_ERROR. `CompileError` → COMPILE_ERROR (-2); any other `err` → SYSTEM_ERROR.
- Failover (`dispatcher._is_retryable`): connection errors and 5xx fail over to the next sandbox and mark it down;
  4xx and read timeouts do not fail over (a read timeout means the sandbox is still judging).
- Heartbeat (`sandbox_status.py` → `JudgeServerService`): the worker posts the `/ping` answer plus `action=heartbeat`,
  `service_url`; the registry upserts by `hostname` and stores `judger_version`, `cpu_core`, `cpu`, `memory`;
  offline after 30 s without a heartbeat.
- Auth today: `X-Judge-Server-Token: sha256hex(TOKEN)` and mutual TLS (gunicorn `--cert-reqs=2`). Certificates come
  from `pki/identities.txt` via `tls-init`, mounted at `/etc/oj/tls/{ca.crt,tls.crt,tls.key}`.
- Existing gRPC convention (`oj-common/src/main/proto/problem_internal.proto`): proto3, `package oj.<svc>.v1`, mutual
  TLS with allowed peer CNs enforced by an interceptor, optional additive service token in metadata.
- Compose: two sandboxes `judge-server`, `judge-server-2` on `sandbox-net`, `test_case_cache` mounted read-only at
  `/test_case`, healthcheck is a Python one-liner posting `/ping`; `docker-compose.mock.yml` swaps in
  `mock-judge-server` (Python, HTTP) for development; the worker's `JUDGE_SERVER_URL` is a comma list of `https://`
  URLs.
- No Go toolchain on the owner's Mac today; Docker is available. Linux-only syscalls (`setrlimit`, seccomp, `wait4`)
  mean the real server runs only in a Linux container.

## 4. The contract: `oj.judge.v1`

### 4.1 Proto (sketch; the builder finalises field numbers and comments)

File: `oj-common/src/main/proto/judge_server.proto`, package `oj.judge.v1`, `go_package` set so the Go repo
generates from the same file. Java generation stays enabled (oj-common builds every proto) even though no Java service
calls it yet; the Python worker generates its stubs at image build.

```proto
service JudgeServer {
  rpc Judge(JudgeRequest) returns (JudgeResponse);
  rpc Ping(PingRequest) returns (PingResponse);
}

message JudgeRequest {
  string src = 1;
  LanguageConfig language_config = 2;
  int32 max_cpu_time_ms = 3;
  int64 max_memory_bytes = 4;
  bool output = 5;                       // include each case's (capped) output in the response
  oneof cases {
    string test_case_id = 6;             // "<slug>__<hash>": a bundle under /test_case
    InlineTestCases test_case = 7;       // a Run: cases carried in the request
  }
  Checker spj = 8;                       // absent when the problem has no checker
}
message LanguageConfig { CompileConfig compile = 1; RunConfig run = 2; }
message CompileConfig { string src_name = 1; string exe_name = 2; int32 max_cpu_time_ms = 3; int32 max_real_time_ms = 4;
                        int64 max_memory_bytes = 5; string compile_command = 6; repeated string env = 7; }
message RunConfig     { string command = 1; string seccomp_rule = 2; repeated string env = 3; bool memory_limit_check_only = 4; }
message InlineTestCases { repeated InlineTestCase cases = 1; }
message InlineTestCase  { string input = 1; string output = 2; }
message Checker { string version = 1; string src = 2; CompileConfig compile = 3;
                  string exe_name = 4; string command = 5; string seccomp_rule = 6; }

message JudgeResponse {
  oneof outcome {
    CaseResults results = 1;             // one CaseResult per case, in bundle order
    CompileError compile_error = 2;      // the submission does not compile
    CompileError spj_compile_error = 3;  // the problem's checker does not compile
  }
}
message CaseResults { repeated CaseResult cases = 1; }
message CaseResult {
  string test_case = 1;                  // the case name: "1", "2", ...
  int32 result = 2;                      // -1 WA, 0 AC, 1 CPU TLE, 2 real TLE, 3 MLE, 4 RE, 5 SE
  int32 error = 3;                       // 0, or a judger error (see §5.4)
  int64 cpu_time_ms = 4; int64 real_time_ms = 5; int64 memory_bytes = 6;
  int32 signal = 7; int32 exit_code = 8;
  string output_md5 = 9;                 // md5 of the stripped output the judge compared
  bytes output = 10;                     // first `output_cap_bytes` of the program's stdout; empty when !output
  bool output_truncated = 11;
}
message CompileError { string message = 1; }   // compiler output, capped

message PingRequest {}
message PingResponse {
  string hostname = 1; string judger_version = 2;
  int32 cpu_core = 3; double cpu = 4; double memory = 5;   // usage percentages, as the registry stores today
  int32 running_jobs = 6; int32 max_jobs = 7;             // new: load signal for the registry
}
```

Judge outcomes are payload, never gRPC errors: a compile error, a wrong answer and a crashed program are results of the
submission, so they travel in `JudgeResponse` and the worker's mapping stays `compile_error → -2`, `spj_compile_error →
SYSTEM_ERROR` with the fixed user-facing message it already has, `results → resolve_verdict`.

### 4.2 gRPC status codes and the worker's failover table

| Code | When the server returns it | Worker behaviour |
|---|---|---|
| `UNAUTHENTICATED` | token metadata missing or wrong | raise, no failover (same everywhere) |
| `PERMISSION_DENIED` | client CN not in the allow-list | raise, no failover |
| `INVALID_ARGUMENT` | malformed request: unknown seccomp rule, `src_name`/`exe_name` absolute, containing `..`, or resolving outside the job dir (a relative sub-path such as `__pycache__/x.pyc` is fine), `test_case_id` not `<slug>__<hash>`, empty command, inline input over the cap | raise, no failover; the worker's existing path turns it into SYSTEM_ERROR with the status message |
| `NOT_FOUND` | the bundle directory or its `info` does not exist | raise, no failover; SYSTEM_ERROR "test-case bundle <id> not on this sandbox" (today this is a generic SE; the message now says which) |
| `RESOURCE_EXHAUSTED` | `running_jobs == MAX_JOBS` **and** the wait queue (`MAX_QUEUE`) is full; with the deployment's `MAX_QUEUE=0`, as soon as every slot is taken | try the next sandbox; do **not** mark this one down. When every sandbox is full, `infra_errors.transient_reason` classifies it as transient `"sandbox"` and the worker's existing infra backoff (2,4,8…60 s, 300 s total; 30 s for run-worker) retries the dispatch. The job ends as SYSTEM_ERROR "Judge infrastructure unavailable" only when that window is exhausted. |
| `UNAVAILABLE`, `INTERNAL`, connection errors | server not up, TLS handshake failed, judger failure before any case ran | fail over and mark down (today's 5xx/connection rule); when every sandbox failed, the worker retries within its window, except an `UNAVAILABLE` whose details name `ssl` or `certificate`, which is a permanent TLS failure and ends the submission at once, with a fixed message and no details (§8) |
| `DEADLINE_EXCEEDED` (client-side) | the worker's deadline passed while the sandbox judges | no failover (today's read-timeout rule). The server observes the call's context: when the client goes away it kills the running children, frees the slot and discards the job, so an abandoned job never holds a slot. |

Admission: a `Judge` call takes a slot when one is free, otherwise waits in a FIFO of at most `MAX_QUEUE` (default 4)
callers; a waiting call still counts against the client's deadline, which is why the server cancels on context done.
The worker cannot tell a queued call from one being judged, and `DEADLINE_EXCEEDED` is not retried (the row above), so a
call that queued behind slow jobs would end as SYSTEM_ERROR for nothing but being busy. Each worker process also counts
sandboxes on its own, so several workers can land on the same sandbox while the other is idle, and then no queue is ever
full to trigger a fail-over. The deployment therefore sets `MAX_QUEUE=0` (compose `x-sandbox-env`, the k3s sandbox
containers; the server's own default stays 4, §5.5): a full sandbox answers `RESOURCE_EXHAUSTED` at once. Slots per
sandbox `MAX_JOBS=2`, two sandboxes, so 4 slots, with up to 3 judge-workers + 2 run-workers calling: all-full is routine
under load, and a burst beyond the 4 slots is retried by the worker with backoff (judge lane up to 300 s, run lane 30 s);
only when that budget is spent does it end as SYSTEM_ERROR "Judge infrastructure unavailable".

Auth: mutual TLS is mandatory; the server verifies the client chain against `ca.crt` and admits only CNs in
`JUDGE_ALLOWED_CLIENTS` (default `judge-worker,run-worker`). The shared token is additive, as in problem-service: when
`TOKEN` is set, every call must carry metadata `x-judge-server-token: sha256hex(TOKEN)` (same digest the worker computes
today, so `JUDGE_SERVER_TOKEN` keeps its value).

Implementation notes (2026-11-08): an empty allow-list is a start-up error (fail closed, never "allow all"). `Ping` is
exempt from the CN check but not from the token, so the `healthcheck` subcommand can call it with the sandbox's own
certificate (CN `judge-server`), verifying the server certificate against `os.Hostname()`; the compose `hostname` and
the certificate SAN must therefore agree, as they do today, unless `HEALTHCHECK_SERVER_NAME` (§5.5, added 2026-11-08)
names the SAN to verify instead: on k3s the pod's host name is the pod's own and in no SAN, so the manifests can drop
the forced `hostname: judge-server` once they set it. The worker must raise gRPC's default 4 MiB receive limit
(`grpc.max_receive_message_length`) since many cases × 64 KiB of output can exceed it.

### 4.3 Semantics preserved from qduoj

- Case order: the bundle's `test_cases` keys sorted numerically when all are integers, else lexicographically; one
  `CaseResult` per key, always, even after a failing case. Inline cases are named `"1".."n"` in request order.
- Comparison: normalise the program's stdout bytes exactly as `TestCaseBundleBuilder.comparedOutput` normalises the
  expected output (drop the CR of every CRLF, strip trailing ASCII whitespace), md5 it, compare with
  `stripped_output_md5`; mismatch → WA. For inline cases the expected md5 is computed from `output` the same way.
  **Intended divergence from qduoj**, which only `rstrip()`s the user's output: a CRLF-printing program is WA today
  and AC tomorrow, and the two sides of the comparison finally use the same rule.
- stderr never affects the verdict **(owner)**: a run's stderr goes to `/dev/null` (§5.1a; compile and checker
  stderr are captured). **Intended divergence from qduoj**, which points stderr at the same file as stdout, so a stray debug
  print to stderr is WA today.
- Checker: compiled once per sandbox per `spj_version` into a cache dir and reused; run as
  `exe in_file user_out_file`; exit 0 → AC, exit 1 → WA, anything else → `error = -11` (SPJ_ERROR, i.e. SYSTEM_ERROR).
  Checker run limits: CPU = 3 × the case's `max_cpu_time`, memory 1 GiB virtual, as qduoj.
- `max_real_time` for a run = 3 × `max_cpu_time`.
- `memory_limit_check_only`: no `RLIMIT_AS`; the MLE check on `ru_maxrss` still applies.
- Compile failure text: the compiler's stderr+stdout, capped at 64 KiB. A compile that times out or crashes is a
  `compile_error` with the message `Compiler Runtime Error, info: ...`, as qduoj reports it.

## 5. The server

### 5.1 Process layout

One static Go binary, `judge-server`, running as root inside the container (it needs the same six capabilities qduoj
uses: CHOWN/DAC_OVERRIDE/FOWNER to prepare job dirs for the unprivileged users, SETUID/SETGID to drop to them, KILL to
stop a run). The image has the users `compiler` (12001) and `spj` (12003) as today, and the per-slot run users `code0`..`code7`
(12100-12107, §5.1a); `code` (12002) is still created but the engine no longer runs anything as it.

Subcommands: `serve` (default), `healthcheck` (performs `Ping` against itself over mTLS; used by the compose/k8s probe),
`mock` (see §8).

Per request: `Job` = one `Judge` call. A job has a private directory under the work tmpfs (`/work/jobs/<job-id>/`,
root:<slotgid> 0710, §5.1a) with `compile.out` (both compiler streams through one fd, deleted once read), `src/`
(the source and the compiled artifact, `{exe_dir}`), `in/` (a Run's inline inputs), `out/` (the per-case `N.out`,
created by the shim as root and written through the already-open fd, deleted once the case is judged), and `tmp/`
(the compiler's `TMPDIR`, deleted before the runs); modes and owners per §5.1a. The checker cache `<WorkDir>/spj/<version>/` is compiled to a temp name and renamed
into place as a root-owned 0555 binary, so a half-written binary from a crash is never a cache hit; both `jobs/` and
`spj/` are wiped at start-up. `/work` itself is root-owned and not
writable by any judge uid. The directory is removed when the response is sent, success or failure, and on
cancellation.

### 5.1a Isolation between concurrent jobs (added after the part-1 final review, 2026-11-08)

Two jobs can run on one sandbox (`MAX_JOBS`), and the final review showed that one shared run uid lets a submission
read the other job's files through `/proc/<pid>/cmdline`, kill or trace its programs under `""`, exhaust the shared
`RLIMIT_NPROC` with detached children, and fill the shared `/work`. The design therefore uses **per-slot identities**:

- The image pre-creates run users `code0`..`code7` (uids 12100-12107) each with its own primary group (gids
  12100-12107). `config.Validate` rejects `MAX_JOBS > 8`. Admission hands each job a slot index; the job runs its
  program as `(12100+slot, 12100+slot)`, its compiler as `(12001, 12100+slot)` and its checker as
  `(12003, 12100+slot)`: the gid is the job's, the uids keep their roles.
- Job dir `root:<slotgid> 0710`; `src/` `root:<slotgid> 0770` (source 0640, artifact as the compiler leaves it);
  `in/` and `out/` `root:<slotgid> 0750` (files 0640, created by the shim as root); the job's `TMPDIR` is
  `/tmp/jobs/<id>` (`root:<slotgid> 0770`) on the separate 64 MiB `/tmp` tmpfs, so temporary files can never fill
  `/work`. Another slot's processes cannot traverse any of it.
- After every run, and on cancellation, the server kills every process whose uid is the slot's (a `/proc` sweep),
  so a child that escaped the process group with `setsid` dies with the job. `RLIMIT_NPROC` is then per slot.
- Output: the program's stderr goes to `/dev/null` for runs (it never affects the verdict, §4.3; compile and
  checker stderr are still captured). `N.out` is deleted as soon as the case is judged, so a job holds at most
  `pool × OUTPUT_FILE_CAP_BYTES` on `/work`. `OUTPUT_FILE_CAP_BYTES` defaults to 16 MiB and `Serve`
  refuses (after the work dir exists) a configuration where `MAX_JOBS × 8 × OUTPUT_FILE_CAP_BYTES + GOCACHE_CAP_BYTES` exceeds the size of the
  `/work` filesystem. The seccomp open rules for `c_cpp`/`general` also deny `O_CREAT`, `O_TRUNC` and `O_TMPFILE`,
  and `general` additionally denies `mkdir(at)`, `mknod(at)`, `symlink(at)`, `link(at)`, `rename(at,at2)`, `truncate`
  and `memfd_create`, so a filtered run cannot create or rename filesystem entries (`c_cpp` is an allow-list and never
  could).
- The output comparison streams the file through the normaliser into md5 (no whole-file buffers), reading only
  `OUTPUT_RESPONSE_CAP_BYTES + 1` bytes for the response.
- Refinements settled during implementation: the checker runs as `(12003, <slotgid>)` with supplementary group
  12003 (shim flag `--groups`), because the worker installs checker bundles as group 12003 (`test_case_sync.py`);
  `src/` is 0770 only while compiles run and is closed to 0750 before the first run; `in/` and `out/` are setgid so
  files the shim creates belong to the slot group (chmod before chown: the container has no CAP_FSETID), created
  0640; the compiler's `TMPDIR`/`HOME` are `<job>/tmp` on `/work` (deleted before the runs), only runs and the checker
  use `/tmp/jobs/<id>`; the server chmods its tmp root (`TMP_DIR`, default `/tmp`, new §5.5 setting) to 0711 at
  start; `compile.out` is deleted once read; the uid sweep spares processes whose session leader is a live shim
  (shims start as session leaders and `Run` keeps a registry of live shim pids), kills by pidfd, is bounded (~1 s),
  and also runs at job end; the checker's two stream files (trusted) are outside the disk formula.
- Implementation notes (W2, 2026-11-08): the disk check runs in `Serve` after the work dir exists (`statfs`), not in
  `config.Validate`; the checker's compile also runs as `(12003, <slotgid>)` with supplementary group 12003; `TMP_DIR`
  must differ from `WORK_DIR`; the Go cache warm-up sets its own `TMPDIR` because the tmp root is 0711; compose must
  keep a small tmpfs at `/tmp` (and, until the image carried tini, `init: true`); detached children of the compiler (12001) and checker (12003) are not
  swept — the accepted residual above.
- Follow-up (2026-11-08): a Java run under the closed tmp root as production has it (`TMP_DIR=/tmp`, 0711) is tested
  (engine test `TestEngineJavaTmpRootClosed`, which closes the test container's `/tmp` for its duration; `make smoke`
  judges `ac.java` too). HotSpot's perf-data directory `/tmp/hsperfdata_<user>` is compiled in, not taken from `TMPDIR`,
  so a run user cannot create it under a closed `/tmp`; HotSpot falls back to anonymous memory, the program runs and
  nothing is created there. A `TMP_DIR` of its own under an open `/tmp` would not exercise that. The sweep's log line is
  `job: cleaned up processes of the slot's uid after a step` at Info: it cannot tell a `setsid` escape from a group-killed
  grandchild that was still dying, so it no longer claims "stray".
- Residual, accepted: uids 12001 (compiler) and 12003 (checker) are shared by both sandbox containers and by both
  slots; they run only trusted tools on contestant-controlled input, bounded by compile limits. The slot uids are
  also the same numbers in both sandbox containers, so `RLIMIT_NPROC` for slot N is shared host-wide between the two
  sandboxes during a run; the sweep shortens the window, a per-container uid base would close it.

### 5.2 Job pipeline

1. Validate (§4.2 `INVALID_ARGUMENT` rules), resolve the bundle (`/test_case/<id>/info`, `NOT_FOUND`), admit the job
   (`RESOURCE_EXHAUSTED` when full).
2. Write `src_name` into `src/` (root:<slotgid> 0640, §5.1a).
3. Compile (if `compile_command` non-empty) as `compiler` with the compile limits (§6), seccomp off (compilers fork),
   network already absent at the container level. Non-zero exit → `compile_error`.
4. If a checker is requested and `spj_cache/<version>` is absent: compile it the same way as `spj`; failure →
   `spj_compile_error`.
5. Run the cases through a worker pool of size `pool(max_memory)` (§6). Each case: fork/exec the run command as
   `code` with stdin from `N.in`, stdout to `N.out` (`RLIMIT_FSIZE` capped), stderr to `/dev/null` (§5.1a); limits and
   seccomp per §5.3; wait with `wait4` for rusage; derive `result` per §5.4; compare or run the checker.
6. Build `CaseResults` in case order; attach `output` (capped, `output_truncated` flagged) when requested.

Throughout: the job watches the call's context; cancellation kills every live child (`SIGKILL` to the process, then
reap), releases the slot and the pool reservations, and removes the job dir.

Temporary files: the server exports `TMPDIR=<job dir>/tmp` to every compile and run, and rewrites an env entry whose
value is exactly `/tmp` (today `GOCACHE=/tmp` from `JudgeService.COMPILE_ENV`) to the job's tmp dir, so nothing a job
writes outlives it. Exception for the Go build cache, which would otherwise rebuild the standard library on every
compile: `GOCACHE` is rewritten to a sandbox-wide `/work/gocache` owned by `compiler`, warmed at start-up by compiling
a hello-world, and trimmed (`go clean -cache` equivalent: delete and re-warm) when it exceeds `GOCACHE_CAP_BYTES`
(default 128 MiB). The cap is soft: a trim is skipped while any Go compile or warm is in flight (every Go compile
holds a read lock on the cache, the trim needs the write lock and does not wait), so a cache is never deleted under a
running `go build`, and the next Go compile re-measures. The warm-up's own source and build log live in a root-owned
sibling directory (`<gocache>-warm`), never inside the compiler-writable cache tree, so root never writes through a
path the compiler uid controls. `JudgeService.COMPILE_ENV` keeps saying `GOCACHE=/tmp`; changing it there is a leftover, not needed
for correctness.

### 5.3 Isolation of one process (the same idea as qduoj's Judger)

In the child before `execve`: `chdir(job dir)`; `setrlimit`: `RLIMIT_STACK` = 128 MiB (qduoj's `max_stack`, kept for
parity), `RLIMIT_CPU` = max_cpu_time/1000 + 1 s (integer division, as qduoj), `RLIMIT_AS` = 2 × `max_memory` unless
`memory_limit_check_only`, `RLIMIT_FSIZE` = output cap (§6), `RLIMIT_NPROC` = 256 for every role (per slot uid, §5.1a),
`RLIMIT_CORE` = 0; `dup2` the three streams; `setgid/setuid` to the role user; `prctl(PR_SET_NO_NEW_PRIVS)`; write
`1000` to `/proc/self/oom_score_adj` so the kernel's OOM killer, if the container cap is hit, kills the submission and
never the server; load the seccomp filter; `execve` with the configured env plus `PATH`.

Seccomp rules, ported from qduoj's Judger (`c_cpp`: allow-list incl. the file-open restriction to read-only except the
job's own output files; `general`: deny-list of `socket`, `fork/clone/vfork`, `execve*` except the first, `kill`,
`ptrace` and friends; `''`: none). `c_cpp_file_io`, `golang`, `node` exist in qduoj but no row uses them; they are
included only if porting is cheap, otherwise an unknown rule is `INVALID_ARGUMENT`.

Process shape (decided during implementation, 2026-11-08): the Go server execs a small static C shim (`judge-runner`);
the shim applies the limits above, then **forks** and execs the program, `wait4`s it and reports `ru_utime` (user time only,
as qduoj) → `cpu_time_ms`, `ru_maxrss` × 1024 → `memory_bytes`, signal and exit code to the server over a pipe. The fork inside the
shim is necessary: a process exec'd straight from the Go server inherits the server's peak RSS as its `ru_maxrss` floor
(Linux records the shared pre-exec mm's high-water mark), which made `/bin/true` read as 100+ MB. The real-time limit is
enforced inside the shim (a timer that `SIGKILL`s only the program, as qduoj's killer thread does), so a timed-out run
still reports its cpu time and memory and derives per §5.4 (CPU TLE when the CPU budget was also spent, else real TLE).
The Go server keeps a backstop kill of the whole process group at `max_real_time + 1 s` and runs the same group kill on
context cancellation (those two paths report cpu and memory 0). The server must run under
an init so that killed grandchildren are reaped: since 2026-11-08 the image's entrypoint is `tini -s`, so that holds
wherever it runs (k3s has no `init: true`); compose's `init: true` is redundant but harmless. `RLIMIT_NPROC` counts every process and thread
of the run uid across concurrent cases, so the run limit is 256, not 64; with per-slot uids (§5.1a) the count is per
slot. Fork bombs are stopped by seccomp under `general`/`c_cpp`, by the container's `pids_limit`, and detached children
by the per-slot uid sweep.

Filter notes from the first full-language run (2026-11-08): under `general`, `socket(AF_UNIX)` returns `EACCES` instead
of killing the process, because glibc's NSS probes the nscd socket when `HOME` is unset and Python 3 died before its
first line; every other socket domain is still killed, and the container has no network anyway. Node.js cannot run
under an `RLIMIT_AS` of 2 × the limit (it hangs until real TLE), so `javascript` joins Java and Go in
`JudgeService.MEMORY_CHECK_ONLY_LANGUAGES` when V11 re-enables it. submission-service appends `JUDGE_ENV`
(`LANG`, `LANGUAGE`, `LC_ALL`) to every run env; the sandbox passes it through like any other entry.

### 5.4 Result derivation (qduoj's rules, kept — verified against Judger `src/runner.c`, branch `newnew`, 2026-11-08)

qduoj's Judger assigns `result` in a fixed sequence without `else` between the later checks, so a later assignment
overrides an earlier one. Given the raw run: `error != 0` (fork/setrlimit/dup2/setuid/seccomp/execve failed, codes
-2..-10 as qduoj numbers them) → `result = 5`, nothing else considered. Otherwise start with 0 and:

1. exit code ≠ 0 → RE;
2. **if the signal is SIGSEGV**: `memory > max_memory` → MLE, else RE — **and stop** (a segfault never becomes a
   time-limit verdict);
3. otherwise, in order, each overwriting the previous value when its condition holds: any non-zero signal → RE;
   `memory > max_memory` → MLE; `real_time > max_real_time` → real TLE; `cpu_time > max_cpu_time` → CPU TLE.

Effective precedence for a non-SIGSEGV run: **CPU TLE > real TLE > MLE > RE**. The sandbox's own `SIGKILL` at the
real-time limit ends as real TLE unless CPU time is also over, in which case CPU TLE wins (as on qduoj, where a busy
loop that trips both reads as CPU TLE). `cpu_time` is **user time only** (`ru_utime`), as qduoj measures it. A result
of 0 then goes through comparison (WA) or the checker (WA / -11). Real time is measured with sub-millisecond
resolution before rounding, because the checks are strict `>`.

Two small, deliberate differences from upstream: qduoj maps a `SIGUSR1` termination to SYSTEM_ERROR because its own
setup failures surface that way; here setup failures arrive as `error != 0` over the shim's pipe, so a program that
kills itself with SIGUSR1 is an ordinary RE. Times are rounded half-up to milliseconds (upstream truncates), so a run
within half a millisecond of the limit can differ. The shim's real-time clock starts at `execve`; the Go backstop
(limit + 1 s) counts from the call.

(An earlier version of this section stated "real TLE > CPU TLE" and let a SIGSEGV run fall through to the time
checks; that was wrong and was corrected after reading the upstream source.)

### 5.5 Configuration (env, with defaults)

`LISTEN=:8080`, `TLS_DIR=/etc/oj/tls` (mandatory; refuses to start without the three files, never plaintext),
`TOKEN` (optional, additive), `JUDGE_ALLOWED_CLIENTS=judge-worker,run-worker`, `TEST_CASE_DIR=/test_case`,
`WORK_DIR=/work`, `MAX_JOBS=2`, `MAX_QUEUE=4`, `RUN_POOL_BUDGET_BYTES=1 GiB`, `COMPILE_MAX_MEMORY_BYTES=512 MiB`
(a ceiling over the request's compile `max_memory` when that is positive; see §6 for `-1`), `GOCACHE_CAP_BYTES=128 MiB`,
`OUTPUT_FILE_CAP_BYTES=16 MiB`, `OUTPUT_RESPONSE_CAP_BYTES=64 KiB`, `COMPILE_MESSAGE_CAP_BYTES=64 KiB`,
`INLINE_INPUT_CAP_BYTES=1 MiB` (sum over a Run's cases), `TMP_DIR=/tmp`, `HEALTHCHECK_SERVER_NAME` (empty = this host's
name; the name the `healthcheck` subcommand verifies the server certificate for; no whitespace), `LOG_FORMAT=json`.

### 5.6 Observability

Structured JSON logs to stdout: one line per job (job id, bundle id or inline count, language, verdict summary,
durations, pool size chosen) and one per failure class. No metrics endpoint in v1: the sandboxes are deliberately
excluded from Prometheus scraping (compose header comment), and the worker already exports `oj_sandbox_up` and dispatch
counters. `PingResponse.running_jobs/max_jobs` is the load signal.

## 6. Memory budget

| | Today (qduoj) | New |
|---|---|---|
| Container cap per sandbox | 3 GiB + 1.25 GiB tmpfs | 1.5 GiB (tmpfs counted inside it) |
| Both sandboxes at peak | 2 × (3 GiB + 1.25 GiB tmpfs) nominal, ~6 GiB real (tmpfs is inside the cgroup) | 3 GiB |
| CPUs per sandbox | 6 | 2 |
| Work tmpfs | 1 GiB `/judger` + 256 MiB `/tmp` | 512 MiB `/work` (exec) + 64 MiB `/tmp`; a job's files are wiped when it ends |
| Compile cap | 1 GiB | min(request, 512 MiB) virtual when the row gives a positive `compile_max_memory`; **no `RLIMIT_AS`** when it is `-1` (Java, Go: V3 records that the Go toolchain fails under any address-space limit up to 1 GiB, and javac's JVM reserves similarly) |
| Cases at once | all in parallel | `pool = clamp(floor(1 GiB / reservation), 1, 8)` |
| Jobs at once per sandbox | gunicorn workers | `MAX_JOBS = 2` (one judge-worker and one run-worker may collide on a sandbox); the pool budget is shared across jobs |

A compile also reserves from the shared 1 GiB pool: its cap when positive, the **whole pool** when `-1`. So a Java or
Go compile runs alone on the sandbox (no case of the other job runs concurrently) and is bounded only by the 1.5 GiB
container cap with the `oom_score_adj` backstop; javac and `go build` sit at 200-500 MiB RSS in practice. A capped
compile (C/C++ 512 MiB) leaves 512 MiB for another job's cases, i.e. two 128 MiB C++ cases or one Java case.

`reservation` per case = `2 × max_memory` for languages with `RLIMIT_AS` (what the address-space limit allows), and
`max_memory + 256 MiB` for `memory_limit_check_only` languages (JVM/Go/Node runtime overhead, unbounded by rlimit). Examples: C++ at a
128 MiB limit reserves 256 MiB → 4 cases at once; at 64 MiB → 8; Java at 256 MiB reserves 512 MiB → 2. The budget is conservative
on purpose: RSS is well under the address-space reservation, so real usage stays far below 1.5 GiB, and the container cap
plus `oom_score_adj=1000` on children is the backstop.

Why 1.5 GiB and 3 GiB total: the designer proposed 1 GiB / 2 GiB; the owner chose 1.5 GiB per sandbox to halve the
judging latency a bounded pool costs (§11.1). On the 8 GB floor VPS from the sizing discussion this still returns
~5.5 GiB to the JVM services, Kafka and the databases; on 16 GB it is slack.

## 7. Image

Base `ubuntu:22.04` (it still packages Python 2.7, which Debian 12 dropped). The resulting image is about 1.7 GB on disk (435 MB compressed): the JDK, the Go toolchain and
Node dominate; the Go server and shim are a few MB. Installed, at the exact paths the rows
name: `gcc`/`g++` 11, `openjdk-17-jdk-headless` (javac + java), `python2` with `/usr/bin/python` → python2,
`python3` (3.10), `golang-go` (1.18) with `/usr/bin/go`, `nodejs` with `/usr/bin/node`, `php8.1-cli` with `/usr/bin/php`. `tini` is the image entrypoint (`tini -s`), so stray children are reaped even where no `init` is available (k3s).
Users `compiler` 12001, `spj` 12003 and the per-slot run users `code0`..`code7` (12100-12107; `code`, 12002, stays in the image, unused). `/opt/oj/java.policy` is still mounted by compose for the Java row. The Go binary is built in a
separate stage and copied in; the image has no shell needs beyond the compilers.

Two Flyway migrations in submission-service. `V10` is safe on qduoj as well as on the Go sandbox, so its ordering and
rollback are not coupled to the compose change. `V11` is not: it offers JavaScript and PHP, which qduoj cannot run, and the gRPC worker
cannot talk to qduoj either. The compose switch, the worker image and the submission-service image that carries `V11` therefore go
live together, in one `docker compose up -d`: merge and deploy the four repositories (judge-deployment, judge-worker,
oj-submission-service, judge-server) as one release, or pin `OJ_WORKER_TAG`, `OJ_SUBMISSION_TAG` and `OJ_SANDBOX_TAG` to the
pre-cut-over images until the switch, because each repository's CI pushes `:main` on merge and a floating tag would move one of the
three early. The sandbox image is not published (judge-server has no CI): build it from a checkout, or `docker push` it by hand
before `docker compose pull` or any k3s apply. The runbook is README "Go sandbox", sections Cut-over and Rollback.

The two migrations:

- `V10__python3_flat_pyc.sql`: Python 3's compile command becomes
  `/usr/bin/python3 -c __import__('py_compile').compile('{src_path}',cfile='{exe_path}',doraise=True)` (no
  space inside the `-c` argument — `import py_compile` would be split — so the single-space split yields one argv entry) and its `exe_name`
  becomes `solution.pyc`. The artifact no longer encodes the CPython version, so the image's Python 3 can move
  without another migration, and the row works on qduoj's 3.6 too. Rollback of the compose change does not need to
  touch this row.
- `V11__enable_javascript_php.sql`: `is_disabled = false` for `javascript` and `php` (V3 disabled them because the
  qduoj image lacks the runtimes). This one must ship with the cut-over, not before it: it goes in the
  submission-service image tag that the cut-over compose change deploys, and on qduoj every JavaScript and PHP submission fails.
  Rollback of the cut-over disables them again by hand (`UPDATE t_languages SET is_disabled = true WHERE identifier IN
  ('javascript','php')`), documented in the README's rollback section, which also says to drain or hold back the JavaScript and PHP
  jobs still queued in Kafka, since qduoj fails them too.

Everything else in `t_languages` is honoured unchanged.

## 8. Worker, mock and deployment changes

Worker (`judge-worker`)

- `requirements.txt`: add `grpcio`, `grpcio-tools` (build time) or pre-generated stubs committed under
  `judge_server_pb2*.py` from the oj-common proto (the Dockerfile generates them from a pinned oj-common checkout,
  mirroring how the Java images pin oj-common).
- `dispatcher.py`: `call_judge_server` becomes a gRPC unary call with deadline = today's timeout; `_is_retryable`
  implements §4.2; `build_judge_body` becomes `build_judge_request` (same field mapping). `sandbox_status.py`: `Ping`
  over gRPC; the heartbeat JSON it relays keeps the same keys plus `running_jobs`.
- `tls.py`: a `grpc_channel_credentials()` helper (CA, cert, key). `config.py`: `JUDGE_SERVER_URL` keeps its name and
  comma-list shape; a value may be `host:port` or `https://host:port` (scheme stripped) so the compose change is a
  two-line edit. `sandbox_health.sandbox_label` handles both forms.
- `infra_errors.transient_reason` (a consumer of the dispatcher's exceptions): `grpc.RpcError` with `UNAVAILABLE`,
  `INTERNAL` or `RESOURCE_EXHAUSTED` → `"sandbox"` (transient, retried with the existing backoff); every other code →
  not transient (SYSTEM_ERROR now), matching today's 4xx rule.
  A gRPC `UNAVAILABLE` whose details contain `ssl` or `certificate` (case-insensitive) is a TLS verification failure, not
  an outage, and fails the submission at once, with no retry and no wait (`_is_grpc_certificate_failure`, checked before
  the generic retryable-code branch and after MinIO's urllib3 certificate rule, which stays): a wrong CA, hostname or
  client certificate is a permanent misconfiguration, gRPC reports it as `UNAVAILABLE` like a sandbox that is down, and
  waiting out the 300 s window would only delay the same SYSTEM_ERROR. Only `UNAVAILABLE` is the TLS signal, and
  `handshake` is not one of its words: a restart that cuts a connection reads like a handshake error but says
  `Socket closed` or `Connection reset by peer`, so every other `UNAVAILABLE` (refused, closed, reset, DNS), `INTERNAL`
  and `RESOURCE_EXHAUSTED` stays transient. `dispatch_judge` is unchanged: it still fails over to the next sandbox and
  raises the last error, and `transient_reason` classifies that one. Trade-off: a sandbox recreated onto a new address
  can answer `Peer name … is not in peer certificate` until the channel re-resolves the name (at most 1 s with
  `grpc.dns_min_time_between_resolutions_ms=1000`), and a call that meets it now fails fast instead of waiting it out;
  therefore workers are recreated after sandboxes (README, "Recreating a sandbox"). Known limit: under TLS 1.3 a client
  certificate the sandbox rejects reaches the worker after the handshake as only `Socket closed`, the same as a
  restarting sandbox, so it is waited out. The message that reaches the submitter for a non-transient failure is
  `infra_errors.describe(exc)`: one line, `<CODE>: <details>` for an RPC error (the details are server-written, e.g.
  "unknown seccomp rule"), capped at 500 characters, the full exception in the log. The one exception is `UNAVAILABLE`, which
  reaches `describe` only as a TLS failure: its details are gRPC's and OpenSSL's own text with the
  sandbox's internal address (`ipv4:10.0.0.5:8080: Ssl handshake failed ...`), so the submitter reads the fixed line
  `UNAVAILABLE: the judge sandbox's TLS certificate check failed` (`infra_errors.TLS_FAILURE_MESSAGE`) and the address
  and error text stay in the worker's log. The gRPC channel uses `grpc.initial_reconnect_backoff_ms=1000` and
  `grpc.max_reconnect_backoff_ms=5000` so a restarted sandbox is retried within seconds. The shared code/details
  helpers live in `grpc_errors.py` with `RETRYABLE_CODES`, used by both the dispatcher and `infra_errors`.
- Deadline: today a flat `JUDGE_TIMEOUT_SECONDS` (30 s) because qduoj runs all cases at once. With a bounded pool a
  judgement can take `compile + ceil(cases / pool) × 3 × max_cpu_time`. The worker already reads
  `test_case_number` from the bundle's `info`; the deadline becomes
  `JUDGE_TIMEOUT_SECONDS + test_case_number × 3 × max_cpu_time` (+ the checker compile allowance), capped at
  `JUDGE_TIMEOUT_MAX_SECONDS` (default 300 s). The consumer's worst-case stretch without a poll becomes MinIO
  3 × 60 s + two sandboxes × 300 s = 780 s, so `MAX_POLL_INTERVAL_MS` rises from 600 000 to 900 000 and the workers'
  `stop_grace_period` must cover one 300 s judgement plus the publish. For a Run, `test_case_number` is the inline count. See §11.1 for
  the latency consequence the owner accepted.
- Tests: `test_dispatcher.py`, `test_sandbox_status.py`, `test_tls.py` move to a fake gRPC servicer; `test_handler.py`
  and `test_verdict.py` are unchanged because the response is converted to today's dict shape at the dispatcher
  boundary (one function, `response_to_dict`, so the rest of the worker is untouched).

Mock: `judge-server mock` serves the same gRPC API with today's `TRIGGER_*` marker behaviour and bundle-aware case
counts (port of `mock-judge-server/app.py`). `docker-compose.mock.yml` points at the Go image with that subcommand;
the Python mock is deleted.

Compose (`judge-deployment/docker-compose.yml`), as built in the cut-over (2026-11-08): `x-sandbox` image
`${OJ_REGISTRY:-docker.io/thanhtuanle}/judge-server:${OJ_SANDBOX_TAG:-${OJ_TAG:-main}}` with `build: {context: ../judge-server,
target: release}`, like the other services (a tag, not a digest: the image is built and pushed by this project, and `OJ_SANDBOX_TAG`
pins it); `init: true` (the shim kills only the program, so a killed run's grandchildren need an init to be reaped; redundant since the image's
entrypoint is `tini -s`, and kept: the two coexist, docker's init as PID 1 and the image's tini below it as a subreaper);
`stop_grace_period: 130s` (the server's graceful stop is 120 s); `mem_limit: 1536m`, `cpus: 2`, `pids_limit: 1024`, tmpfs
`/work:exec,mode=755,size=512m` and `/tmp:size=64m`; no `shm_size` and no `/log` volumes; same `cap_add`, `read_only`,
`no-new-privileges`, `sandbox-net`; env `TOKEN`, `TLS_DIR`, `JUDGE_ALLOWED_CLIENTS`, `LOG_FORMAT` (the rest are the defaults of 5.5);
healthcheck `["CMD", "/usr/local/bin/judge-server", "healthcheck"]` with `start_period: 60s`, which needs each service's
compose `hostname:` to stay equal to its certificate name (or `HEALTHCHECK_SERVER_NAME` set to it). Worker `JUDGE_SERVER_URL: judge-server:8080,judge-server-2:8080`,
`stop_grace_period: 6m` on both workers. `pki/identities.txt` unchanged (same CNs). `README.md` ("Go sandbox"), the K3s manifests
(`k3s/scripts/gen_services.py`, the local overlay's `mock` patch, `overlays/vps` pinning the image) and the k3s spec row 5
(`cpu 2, memory 1.5Gi`) are updated to the new budget; the mock runs the same image (`docker-compose.mock.yml`, `command: ["mock"]`).

Repository: new sibling `my-oj/judge-server` (Go module), with `cmd/judge-server`, `internal/{api,judge,sandbox,
bundle,seccomp,mock}`, `Dockerfile`, and a `conformance/` corpus (see §9). The proto lives in oj-common.

## 9. Verification before cut-over

1. Unit tests (run anywhere): placeholder substitution, `info` parsing and ordering, stripped-md5 comparison, result
   derivation table (§5.4) over synthetic rusage inputs, request validation, failover table on the worker side.
2. Sandbox tests (Linux container only, run via `docker compose run` on the Mac and in CI): each language's AC, WA, CPU
   TLE, real TLE (sleep), MLE, RE (crash, non-zero exit), CE, output flood (hits `RLIMIT_FSIZE`, not the tmpfs), fork
   bomb under `general`, `socket()` under `c_cpp`, a checker problem (AC, WA, checker crash → SE, checker CE →
   `spj_compile_error`), a Run with inline cases, a missing bundle → `NOT_FOUND`, a third concurrent job →
   `RESOURCE_EXHAUSTED`.
3. Parity run: the same corpus submitted through the real stack against qduoj (`docker-compose.yml` today) and the Go
   sandbox; verdicts must match case by case; `cpu_time`/`memory` may differ within tolerance. Expected, documented
   differences (the corpus has one program for each): CRLF output (WA → AC) and stderr output (WA → AC), both §4.3.
   Anything else that differs is a bug.
4. Memory: `docker stats` during the parity run; both sandboxes ≤ 3 GiB, no container OOM kill.

Cut-over is a compose change plus the worker image plus `V11` (and the k3s manifests), deployed together (§7); rollback is the README's
steps, which restore the compose files from `502958c` and put the earlier worker image back. No dual-transport period.

## 10. Left to the builder

- Go module layout details, seccomp library (libseccomp-golang with cgo, or BPF generated with `golang.org/x/net/bpf`;
  the filter must be loadable without `CAP_SYS_ADMIN`, i.e. after `no_new_privs`).
- Exact port of the two seccomp rule sets from qduoj's Judger (MIT); same semantics, not necessarily same code.
- How `judger_version`, `cpu`, `memory` in `Ping` are measured (`/proc` is fine).
- CI for the Linux-only tests, and how the Dockerfile obtains oj-common's proto (git submodule, pinned checkout, or
  copy, following the Java images' convention).
- Whether to keep qduoj's extra rule names (`c_cpp_file_io`, `golang`, `node`).

## 11. Decisions the owner made on the reviewer's questions (2026-11-08)

1. **Latency for memory.** Bounded cases per job means a 20-case problem with a 1 s limit takes up to ~15 s in C++
   (pool 4 at 128 MiB) and ~30 s in Java (pool 2), where qduoj took ~3 s. The owner chose the 1.5 GiB cap with a
   1 GiB run pool over the designer's 1 GiB / 640 MiB proposal to keep that cost down; both sandboxes stay ≤ 3 GiB.
   The worker's deadline scales with the bundle (§8).
2. **stderr and the verdict.** A program's stderr never affects the verdict (run stderr discarded (`/dev/null`), §4.3).

## 12. Calls the designer made (for the owner to check)

- Keep the Python worker; gRPC is the seam (§2).
- 2 CPUs per sandbox, 512 MiB compile cap, `MAX_JOBS=2`, `MAX_QUEUE=4` as the server's defaults (§4.2, §6); the deployment overrides the queue with `MAX_QUEUE=0` (§4.2). The 1.5 GiB cap and 1 GiB pool are the owner's.
- Compiles with `compile_max_memory = -1` (Java, Go) get no address-space limit and reserve the whole pool (§6).
- Busy sandboxes answer `RESOURCE_EXHAUSTED` at once (`MAX_QUEUE=0`), then the worker fails over and retries with its infra
  backoff; busy becomes SYSTEM_ERROR only after that retry window (§4.2). The server's own queue (default 4) would put the wait
  inside the call's deadline, which is not retried.
- Limits via `setrlimit` + container cap + `oom_score_adj`, no cgroups, no namespaces beyond the container's (§2, §5.3).
- Stack limit 128 MiB as qduoj (§5.3). Output comparison uses the bundle builder's normalisation, CRLF included (§4.3).
- Keep JDK 17 and the `java.policy` security manager for Java, contrary to what was said in the brainstorm (§2).
- Ubuntu 22.04 base to keep Python 2. Python 3 compiles to a flat `solution.pyc` (V10); JavaScript and PHP are
  re-enabled with the cut-over (V11) (§7).
- `TMPDIR` scoped per job; `GOCACHE` redirected to a warmed, capped per-sandbox cache (§5.2).
- Judge outcomes as payload, infrastructure failures as gRPC status codes (§4).
- Mock rewritten in Go inside the new repo; Python mock removed (§8).
- Same `JUDGE_SERVER_URL` env with scheme optional, rather than a new variable (§8).
- No metrics endpoint on the sandbox in v1 (§5.6).

## 13. Per-case progress: `JudgeStream` and `submission.progress` (added 2026-11-08, after the cut-over)

The portal's product promise is a verdict that "streams live, test by test"; with the unary `Judge` the sandbox answered
all cases at once, so the portal only ever showed every tile at the end, and with the bounded pool a 20-case bundle
takes 15-30 s (§11.1) — longer than the portal's 20 s silence fallback. This section adds the per-case path. It is
additive: `Judge`, `JudgeResponse`, `submission.judged` and §2's non-goals are unchanged; an old worker or an old
sandbox keeps today's behaviour.

- **Proto** (`oj-common`): `rpc JudgeStream(JudgeRequest) returns (stream JudgeEvent)`. `JudgeEvent` is a oneof: `case`
  (a `CaseResult` as it finishes, in finishing order, with `output` empty) then exactly one `done` (the `JudgeResponse`
  the unary call would return, cases in bundle order, output included). A compile error sends only `done`. A failed
  call ends with its status code and no `done`; the client must not use the cases it saw.
- **Server** (`judge-server`): `judge.Request.OnCase` is called by `runCases` from the pool goroutines after each case;
  `api.Server.JudgeStream` serialises the sends and returns `done` after the engine returns. `AuthStreamInterceptor`
  applies the token and CN checks to streams (the unary interceptor alone would have let a stream skip them). The mock
  implements `JudgeStream` too and spreads a `TRIGGER_SLOW` pause over the cases, so the dev stack shows the ladder
  filling.
- **Worker** (`judge-worker`): a submission is judged with `JudgeStream`; each `case` event is published to the new
  advisory topic `submission.progress` (key = submissionId; `testCase`, `result`, `error`, `cpuTime`, `realTime`,
  `memory`, `total` = the bundle's case count or null, `rejudgeCount` when the request had one; never the output).
  `UNIMPLEMENTED` from an old sandbox falls back to `Judge` on the same sandbox. A sandbox that dies mid-stream fails
  over as before; the cases it reported are not retracted (the portal counts distinct case names and the verdict
  replaces everything). The run lane keeps `Judge`: a run has no ladder and no submission row.
- **submission-service**: `SubmissionProgressConsumer` (group `submission-progress`) forwards each record, without a
  database read or write, to the Redis channel `oj.judging`; `SubmissionStartedConsumer` publishes a `started` marker
  on the same channel after its commit. `JudgingPubSub` hands both to `SubmissionSseRegistry.send`, which writes a
  named SSE event (`started` with `{status: 7}`, `progress` with the fields above) to every open stream of the id
  without completing it; the verdict path (`oj.verdicts`, `VerdictPush`, `complete`) is unchanged. A subscriber that
  finds the row already JUDGING gets `started` at once. No generation check on progress: it only flows while a
  generation is judged and a stream closes with its verdict. A record of either advisory topic the consumer gives up
  on is dropped, not dead-lettered.
- **Deployment**: ACLs for `submission.progress` (judge-worker Write/Describe/Create; submission-service
  Read/Describe/Create/Alter/DescribeConfigs and group `submission-progress` Read) in `kafka/acls.sh`, the K3s
  init-scripts copy and `tests/kafka-acls.test.sh`. The topic bean lives in submission-service's `KafkaTopicConfig`.
  Nothing changes at the edge: the gateway has no response timeout on the stream and Caddy flushes SSE.
- **Portal**: `useSubmissionStream` accepts `started` and `progress`, resets its 20 s silence timer on each, and the
  console fills the ladder live. See `judge-portal/DESIGN.md` (Test Ladder) and `PRODUCT.md`.

