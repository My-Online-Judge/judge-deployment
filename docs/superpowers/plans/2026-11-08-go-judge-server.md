# Go Judge Server Implementation Plan (part 1 of 2: proto, server, mock, image)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Go gRPC sandbox (`judge-server`) that judges a submission the way qduoj does, with bounded memory, and a
Go mock of the same API, both shipped as one image.

**Architecture:** One static Go binary with subcommands `serve`, `healthcheck`, `mock`. `serve` accepts `Judge`/`Ping`
over mutual TLS, admits jobs through a slot/queue, compiles and runs each case through a small C shim (`runner`) that
applies setrlimit, setuid, oom_score_adj and a libseccomp filter before `execve`, derives qduoj's result codes from
`wait4` rusage, and compares md5s of normalised output. The proto lives in oj-common next to `problem_internal.proto`.

**Tech Stack:** Go 1.23, `google.golang.org/grpc` 1.68+, `google.golang.org/protobuf` 1.36+, `golang.org/x/sync`
(weighted semaphore), buf 1.47 for code generation (committed output), C11 shim linked statically against libseccomp
2.5 (Ubuntu 22.04), Docker multi-stage image on `ubuntu:22.04`.

**Spec:** `judge-deployment/docs/superpowers/specs/2026-11-08-go-judge-server-design.md` (sections cited as §N).

Part 2 (`2026-11-08-go-judge-server-cutover.md`) covers the worker's gRPC client, the migrations, compose and the
parity run. Part 1 produces a server you can drive with `grpcurl` and a mock the worker's compose can use.

## Global Constraints

- New repo `my-oj/judge-server`, module `github.com/My-Online-Judge/judge-server`, Go 1.23, `CGO_ENABLED=0` for the Go
  binary. The C shim is the only cgo-free exception: a separate static C binary.
- Proto package `oj.judge.v1`, file `oj-common/src/main/proto/judge_server.proto`, Java options as in
  `problem_internal.proto`, `go_package = "github.com/My-Online-Judge/judge-server/internal/pb/judgev1;judgev1"`.
- Verdict codes exactly: -1 WA, 0 AC, 1 CPU TLE, 2 real TLE, 3 MLE, 4 RE, 5 SE. Judger error codes: 0 ok, -1
  INVALID_CONFIG, -2 FORK_FAILED, -4 WAIT_FAILED, -6 LOAD_SECCOMP_FAILED, -7 SETRLIMIT_FAILED, -8 DUP2_FAILED,
  -9 SETUID_FAILED, -10 EXECVE_FAILED, -11 SPJ_ERROR (§5.4).
- Users: `compiler` 12001, `code` 12002, `spj` 12003. Directories: `/test_case` (ro), `/work` (tmpfs, exec), `/tmp`.
- Container capabilities available: CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID, KILL only; `no-new-privileges`;
  read-only root. Nothing in the server may need more (§2 anti-goals).
- Defaults (§5.5): `LISTEN=:8080`, `TLS_DIR=/etc/oj/tls`, `JUDGE_ALLOWED_CLIENTS=judge-worker,run-worker`,
  `MAX_JOBS=2`, `MAX_QUEUE=4`, `RUN_POOL_BUDGET_BYTES=1073741824`, `COMPILE_MAX_MEMORY_BYTES=536870912`,
  `GOCACHE_CAP_BYTES=134217728`, `OUTPUT_FILE_CAP_BYTES=33554432`, `OUTPUT_RESPONSE_CAP_BYTES=65536`,
  `COMPILE_MESSAGE_CAP_BYTES=65536`, `INLINE_INPUT_CAP_BYTES=1048576`, `LOG_FORMAT=json`.
- Judge outcomes are payload; only infrastructure failures are gRPC status codes (§4.1, §4.2).
- Commit messages: one line, imperative, `type(scope): ...`, no body, no attribution. Branch `feat/go-judge-server`
  in each repo touched. Never push or open PRs; the owner does.
- Linux-only tests carry build tag `sandbox` and run inside the image (Task 13). Everything else runs with plain
  `go test ./...` on the Mac inside `golang:1.23` (`docker run --rm -v "$PWD":/src -w /src golang:1.23 go test ./...`),
  since the owner has no local Go toolchain.

## Review Focus

1. A program that prints 1 GiB to stdout: must end as RE (SIGXFSZ from `RLIMIT_FSIZE`), the tmpfs must not fill, and
   the response carries at most `OUTPUT_RESPONSE_CAP_BYTES` with `output_truncated = true`. Test in Task 13.
2. A `test_case_id` like `../../etc` or `a__b/../c`: `INVALID_ARGUMENT`, nothing read outside `/test_case`. Test in Task 4.
3. Client disconnects mid-judge (deadline): every child is killed, the slot and pool reservations are released, the
   job dir is gone, and the next job is admitted immediately. Test in Task 11 (unit, fake runner) and Task 13 (real).
4. Two sandboxes' worth of load on one server: `MAX_JOBS` running + `MAX_QUEUE` waiting, the next caller gets
   `RESOURCE_EXHAUSTED` at once and the queue never grows unbounded. Test in Task 10.
5. A bundle whose `info` lists a case with no `.in` file on disk, or a `test_case_number` that disagrees with the
   `test_cases` map: the job fails with `INTERNAL` (a bad bundle is the sandbox's/worker's problem, not the
   contestant's) rather than returning fewer results. Test in Task 4.

---

## File Structure (new repo `judge-server`)

```
go.mod, go.sum
Makefile                      proto, test, sandbox-test, image targets
buf.gen.yaml                  remote plugins; input ../oj-common/src/main/proto, path judge_server.proto
cmd/judge-server/main.go      subcommand dispatch: serve | healthcheck | mock
internal/pb/judgev1/          generated (committed)
internal/config/config.go     env → Config struct with the §5.5 defaults
internal/bundle/bundle.go     id validation, info parsing, case ordering, on-disk checks
internal/compare/compare.go   Normalize(), MD5Hex()
internal/sandbox/spec.go      Spec, Result, error codes
internal/sandbox/runner.go    Run(ctx, Spec): exec the shim, timer, rusage          (build tag sandbox for tests)
internal/sandbox/runner.c     the C shim (built in the image, not by go build)
internal/judge/command.go     placeholder substitution, argv split
internal/judge/derive.go      Derive(raw, limits) → result code (§5.4)
internal/judge/pool.go        Reservation(), PoolSize(), shared weighted budget
internal/judge/job.go         Job pipeline: compile, checker cache, cases, cancel, cleanup, TMPDIR/GOCACHE
internal/judge/gocache.go     warm + cap the shared Go build cache
internal/api/auth.go          TLS config, CN allow-list, token interceptor
internal/api/admission.go     slots + bounded FIFO queue
internal/api/server.go        JudgeServer service: request→Job, Job→response, status codes
internal/api/ping.go          PingResponse fields from /proc and cgroup files
internal/mock/mock.go         the TRIGGER_* mock servicer
internal/testutil/             fake runner, bundle builder for tests, test TLS material
testdata/corpus/               <lang>/<case>.<ext> + corpus.json (expected verdicts), shared with part 2's parity run
Dockerfile, .dockerignore
scripts/sandbox-test.sh        build image, run the tagged tests inside it with compose's cap set
README.md
```

---

### Task 1: Proto in oj-common

**Files:**
- Create: `oj-common/src/main/proto/judge_server.proto`
- Modify: `oj-common/pom.xml:15` (version 0.10.0 → 0.11.0)

**Interfaces:**
- Produces: service `oj.judge.v1.JudgeServer { Judge(JudgeRequest) returns (JudgeResponse); Ping(PingRequest) returns (PingResponse); }` with the messages of §4.1 verbatim, field names and numbers as written there. Java package `vn.thanhtuanle.oj.common.grpc.judge.v1`.

- [ ] **Step 1: Write the proto** — copy §4.1 exactly; add the header comment in the style of `problem_internal.proto` lines 1-4 (port 8080, sandbox-net only, mTLS with allowed CNs `JUDGE_ALLOWED_CLIENTS`, token additive in metadata `x-judge-server-token`). Add `option go_package` and `option java_package`/`java_multiple_files`. Document on `JudgeResponse` that outcomes are payload and on each status code (§4.2) when the server returns it.

- [ ] **Step 2: Build oj-common** — Run: `cd oj-common && ./mvnw -q -DskipTests package` (or `mvn`). Expected: BUILD SUCCESS; `target/classes/vn/thanhtuanle/oj/common/grpc/judge/v1/JudgeServerGrpc.class` exists.

- [ ] **Step 3: Commit** — `git -C oj-common checkout -b feat/go-judge-server && git -C oj-common add src/main/proto/judge_server.proto pom.xml && git -C oj-common commit -m "feat(proto): add oj.judge.v1 JudgeServer for the Go sandbox (0.11.0)"`

---

### Task 2: Repo scaffold, generated code, config

**Files:**
- Create: `judge-server/go.mod`, `Makefile`, `buf.gen.yaml`, `cmd/judge-server/main.go`, `internal/pb/judgev1/*.pb.go`, `internal/config/config.go`, `.gitignore`, `README.md`
- Test: `internal/config/config_test.go`

**Interfaces:**
- Produces: `config.Load(getenv func(string) string) (Config, error)` with fields `Listen, TLSDir, Token, AllowedClients []string, TestCaseDir, WorkDir, MaxJobs, MaxQueue int, RunPoolBudget, CompileMaxMemory, GoCacheCap, OutputFileCap, OutputResponseCap, CompileMessageCap, InlineInputCap int64, LogFormat string`; `main` dispatches `os.Args[1]` ∈ {`serve`, `healthcheck`, `mock`}, default `serve`.

- [ ] **Step 1: `go mod init github.com/My-Online-Judge/judge-server`**, `go 1.23`; `buf.gen.yaml` v2 with `inputs: [{directory: ../oj-common/src/main/proto, paths: [judge_server.proto]}]`, plugins `buf.build/protocolbuffers/go:v1.36.1` and `buf.build/grpc/go:v1.5.1`, `out: internal/pb`, `opt: paths=source_relative` is wrong here because `go_package` carries the path: use `opt: module=github.com/My-Online-Judge/judge-server`. Makefile target `proto`: `docker run --rm -v "$PWD/..":/ws -w /ws/judge-server bufbuild/buf:1.47.2 generate`.
- [ ] **Step 2: Run `make proto`** — Expected: `internal/pb/judgev1/judge_server.pb.go` and `judge_server_grpc.pb.go` exist; `go build ./...` succeeds (inside `golang:1.23`).
- [ ] **Step 3: Write failing tests** in `config_test.go`: `TestLoadDefaults` (empty env → every §5.5 default, `AllowedClients == []string{"judge-worker","run-worker"}`), `TestLoadParsesBytesAndInts` (`MAX_JOBS=3`, `RUN_POOL_BUDGET_BYTES=1000` → 3, 1000), `TestLoadRejectsBadInt` (`MAX_JOBS=x` → error naming the variable).
- [ ] **Step 4: Run** `go test ./internal/config/` — Expected: FAIL, package has no `Load`.
- [ ] **Step 5: Implement `Load`** — plain `strconv` parsing; errors `fmt.Errorf("%s: %w", name, err)`.
- [ ] **Step 6: Run** `go test ./internal/config/` — Expected: PASS.
- [ ] **Step 7: `main.go`** — subcommand switch; `serve`/`healthcheck`/`mock` call `api.Serve`, `api.Healthcheck`, `mock.Serve` (stubs returning `errors.New("not implemented")` until Tasks 10-12). Structured logging with `log/slog` JSON handler when `LogFormat == "json"`.
- [ ] **Step 8: Commit** — `git init -b feat/go-judge-server` (repo is new) then `git add -A && git commit -m "feat(server): scaffold module, generated oj.judge.v1 stubs and env config"`.

---

### Task 3: Output normalisation and md5

**Files:**
- Create: `internal/compare/compare.go`
- Test: `internal/compare/compare_test.go`

**Interfaces:**
- Produces: `compare.Normalize(b []byte) []byte` (drop the CR of each CRLF, then strip trailing bytes in {0x20,0x09,0x0A,0x0D,0x0B,0x0C}); `compare.MD5Hex(b []byte) string`; `compare.Matches(actual []byte, expectedStrippedMD5 string) (md5Hex string, ok bool)`.

- [ ] **Step 1: Failing tests** mirroring `TestCaseBundleBuilder.comparedOutput`: `"a\r\nb\r\n"` → `"a\nb"`; `"x \t\n"` → `"x"`; `"\r"` alone → `""`; a lone CR not followed by LF is kept (`"a\rb"` → `"a\rb"`); bytes ≥ 0x80 untouched; `MD5Hex([]byte("1\n"))` compared against the md5 Java produces for `"1"` (`c4ca4238a0b923820dcc509a6f75849b`).
- [ ] **Step 2: Run** `go test ./internal/compare/` — Expected: FAIL (undefined).
- [ ] **Step 3: Implement** — single pass, no regexp.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(compare): normalise output like TestCaseBundleBuilder and hash it`

---

### Task 4: Bundle reading and validation

**Files:**
- Create: `internal/bundle/bundle.go`
- Test: `internal/bundle/bundle_test.go`

**Interfaces:**
- Produces:
  - `bundle.ValidateID(id string) error` — must match `^[A-Za-z0-9][A-Za-z0-9._-]*__[0-9a-f]{8,128}$` (slug then `__` then hex; `rpartition("__")` semantics as the worker) and contain no `/`.
  - `type Case struct { Name, InputPath string; StrippedOutputMD5 string }`
  - `type Bundle struct { Dir string; SPJ bool; SPJVersion string; Cases []Case }` (ordered: numeric when every name is an integer, else lexicographic)
  - `bundle.Load(root, id string) (*Bundle, error)` returning sentinel errors `bundle.ErrInvalidID`, `bundle.ErrNotFound` (dir or `info` missing), `bundle.ErrCorrupt` (JSON invalid, `test_case_number != len(test_cases)`, a listed `.in` missing on disk, md5 not 32 hex).
  - `bundle.Inline(cases []InlineCase) *Bundle` where `InlineCase{Input, Output []byte}` → names `"1".."n"`, inputs written later by the job (`InputPath` empty, `Input` kept on the Case as `InputBytes []byte`), `StrippedOutputMD5 = compare.MD5Hex(compare.Normalize(Output))`.

- [ ] **Step 1: Failing tests** with a temp dir and a helper `writeBundle(t, root, id, infoJSON, files map[string][]byte)`:
  `TestValidateID` (ok: `two-sum__abc123de`; bad: `../x__abc`, `a__b/../c`, `noSeparator`, `slug__XYZ` uppercase hex); `TestLoadOrdersNumerically` (`{"10","2","1"}` → `1,2,10`); `TestLoadLexicographicWhenNotAllNumeric`; `TestLoadNotFound` (missing dir; dir without `info`); `TestLoadCorrupt` (count mismatch; missing `3.in`; bad JSON); `TestLoadReadsSPJ` (`"spj": true, "spj_version": "v1"`); `TestInlineMD5` (output `"1 \r\n"` → md5 of `"1"`).
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** — `info` struct with `TestCaseNumber int`, `SPJ bool`, `SPJVersion string`, `TestCases map[string]struct{ InputName, OutputName, StrippedOutputMD5 string }`; resolve `filepath.Join(root, id)` and check `filepath.Rel(root, dir)` has no `..` after `EvalSymlinks` of root.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(bundle): read the worker's <slug>__<hash> bundles with numeric case order`

---

### Task 5: Command templates and result derivation

**Files:**
- Create: `internal/judge/command.go`, `internal/judge/derive.go`
- Test: `internal/judge/command_test.go`, `internal/judge/derive_test.go`

**Interfaces:**
- Produces:
  - `judge.Vars{SrcPath, ExePath, ExeDir, InFilePath, UserOutFilePath, SPJVersion string}`
  - `judge.Expand(template string, v Vars) string` — replaces `{src_path}`, `{exe_path}`, `{exe_dir}`, `{in_file_path}`, `{user_out_file_path}`, `{spj_version}` (unknown `{x}` left as is).
  - `judge.Split(cmd string) ([]string, error)` — `strings.Split(cmd, " ")` dropping empty fields; error on empty result.
  - `judge.ValidateName(name string) error` — relative, no empty, no `..` element, `filepath.Clean(name)` must not start with `../` or `/` (so `__pycache__/x.pyc` is fine).
  - `judge.Limits{MaxCPUTimeMs, MaxRealTimeMs int64; MaxMemoryBytes int64}`
  - `judge.Derive(r sandbox.Result, l Limits) int32` — §5.4, qduoj's Judger sequence (verified against src/runner.c): `r.Error != 0` → 5 and stop; else start at 0; `ExitCode != 0` → 4; if `Signal == SIGSEGV` → (`Memory > MaxMemory` ? 3 : 4) and STOP; else overwrite in order: `Signal != 0` → 4; `Memory > MaxMemory` → 3; `RealTime > MaxRealTime` → 2; `CPUTime > MaxCPUTime` → 1. Effective precedence (non-SIGSEGV) CPU TLE > real TLE > MLE > RE.

- [ ] **Step 1: Failing tests** — `TestExpandAll`, `TestExpandKeepsUnknown`, `TestSplitSingleSpaces` (`"a  b"` → `["a","b"]`), `TestValidateName` (`Main`, `__pycache__/solution.pyc` ok; `/abs`, `../x`, `a/../../b`, `` bad), and a table `TestDerive` with one row per branch above plus: SIGKILL with real time over → 2 only when CPU is under; SIGXCPU → 1; exit 0 / no signal / under limits → 0.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** (`sandbox.Result` from Task 6 — define `internal/sandbox/spec.go` first in this task so the test compiles: `type Result struct { CPUTimeMs, RealTimeMs, MemoryBytes int64; Signal, ExitCode int; Error int }`).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(judge): expand qduoj command templates and derive result codes from rusage`

---

### Task 6: The C runner shim and its Go wrapper

**Files:**
- Create: `internal/sandbox/runner.c`, `internal/sandbox/spec.go` (extend), `internal/sandbox/runner.go`, `internal/sandbox/seccomp_rules.md` (the ported lists with provenance)
- Test: `internal/sandbox/runner_sandbox_test.go` (`//go:build sandbox`)

**Interfaces:**
- Produces:
  - `type Spec struct { Argv []string; Env []string; Dir string; UID, GID uint32; Stdin, Stdout, Stderr string /* paths; "" = /dev/null */; MaxCPUTimeMs, MaxRealTimeMs int64; MaxAddressSpace int64 /* 0 = unlimited */; MaxStack int64; MaxOutputBytes int64; MaxProcs int64; Seccomp string /* "c_cpp" | "general" | "" */; ExePath string /* for the execve allow rule */ }`
  - `sandbox.Run(ctx context.Context, runnerPath string, s Spec) (Result, error)` — `error` only for the server's own failures (cannot start the shim); every child-side failure is `Result.Error`.
  - `const DefaultRunnerPath = "/usr/local/bin/judge-runner"`.
- Shim CLI: `judge-runner --uid U --gid G --cpu-ms N --as N --stack N --fsize N --nproc N --seccomp RULE --exe PATH --chdir DIR --stdin P --stdout P --stderr P -- argv...`; env inherited from the parent exec; fd 3 is a CLOEXEC pipe: on setup failure it writes one signed byte (the §5.4 error code) and `_exit(255)`; on success the pipe closes at `execve`.

- [ ] **Step 1: Write the sandbox-tagged failing tests** (they run only in Task 13's container, write them now): `TestRunHelloC` (compile `int main(){puts("hi");}` with `/usr/bin/gcc` through `Run` as uid 12001 then run as 12002 under `c_cpp`: `Error==0`, `ExitCode==0`, stdout file `"hi\n"`); `TestRunCPUTimeLimit` (busy loop, `--cpu-ms 1000`: `Signal==SIGXCPU || CPUTimeMs>1000`); `TestRunRealTimeLimit` (`sleep 5`, real 1000 ms: `Signal==SIGKILL`, `RealTimeMs>=1000`); `TestRunAddressSpace` (malloc 300 MiB and touch, `--as 268435456`: `Signal==SIGSEGV || ExitCode!=0`); `TestRunFsize` (write 100 MiB, `--fsize 1048576`: `Signal==SIGXFSZ`, file ≤ 1 MiB); `TestRunSeccompCCppDeniesSocket` (`socket()` under `c_cpp` → killed by SIGSYS); `TestRunSeccompGeneralDeniesFork` (`fork()` under `general` → SIGSYS); `TestRunSeccompDeniesWriteOpen` (`open("x", O_WRONLY|O_CREAT)` → SIGSYS under both rules); `TestRunStdlibCppUnderCCpp` (iostream+vector+sort+`std::random_device` program runs AC; this is the glibc 2.35 allow-list driver); `TestRunPythonUnderGeneral` (`print(1)`); `TestRunSetuidFailureReported` (uid 0 requested from a non-root test → `Error==-9`, skipped when running as root); `TestRunExecveFailure` (missing binary → `Error==-10`); `TestOOMScoreAdj` (`cat /proc/self/oom_score_adj` → `1000`).
- [ ] **Step 2: Write `runner.c`** — parse flags; `setpgid(0,0)`; open stdin/stdout/stderr paths (stdout/stderr `O_WRONLY|O_CREAT|O_TRUNC`, 0644) and `dup2` (→ -8); `chdir` (→ -1); write `1000` to `/proc/self/oom_score_adj` (ignore failure); `setrlimit` for CPU (`cpu_ms/1000 + 1`), AS when > 0, STACK, FSIZE, NPROC, CORE=0 (→ -7); `setgid`, `setgroups(0,NULL)`, `setuid` (→ -9); `prctl(PR_SET_NO_NEW_PRIVS,1)`; load seccomp per rule (→ -6); `execve(argv[0], argv, environ)` (→ -10). Seccomp with libseccomp: `c_cpp` = allow-list from upstream `QingdaoU/Judger` `src/rules/c_cpp.c` plus the syscalls glibc 2.35 start-up needs (find them with `strace -f` on the Task-1 C++ test program; record each addition in `seccomp_rules.md`), `execve` allowed only when `arg0 == ExePath` pointer value is not checkable portably → follow upstream: `SCMP_A0(SCMP_CMP_EQ, (scmp_datum_t)exe_path)` with the exe path string passed to the shim, and `open/openat` denied when `flags & (O_WRONLY|O_RDWR)`; `general` = default allow with deny-list from upstream `general.c` (`clone`, `fork`, `vfork`, `kill`, `execveat`, plus `socket`), the same `execve` and `open/openat` conditions. Default action for a denied syscall: `SCMP_ACT_KILL_PROCESS`.
- [ ] **Step 3: Write `runner.go`** — build argv for the shim, `exec.Cmd` with `ExtraFiles = [pipeW]`, `SysProcAttr{Setpgid: true}`; after `Start`, close `pipeW`, read the pipe (one byte → `Result.Error`, EOF → 0); start a timer at `MaxRealTimeMs` that `syscall.Kill(-pid, SIGKILL)`; also kill on `ctx.Done()`; `Wait`; fill `Result` from `ProcessState.SysUsage().(*syscall.Rusage)` (`Utime+Stime` → ms, `Maxrss*1024`), `WaitStatus` signal/exit; `RealTimeMs` from wall clock.
- [ ] **Step 4: Build check** — `go vet ./internal/sandbox/` passes on the Mac (the file compiles everywhere; only the tests are tagged). The C shim compiles in Task 13's image stage; the tests run there (Task 13 Step 4 is the first time Step 1's tests go green).
- [ ] **Step 5: Commit** — `feat(sandbox): C runner shim (rlimit, setuid, seccomp, oom_score_adj) and Go wrapper`

---

### Task 7: Memory pool

**Files:**
- Create: `internal/judge/pool.go`
- Test: `internal/judge/pool_test.go`

**Interfaces:**
- Produces: `judge.Reservation(maxMemory int64, checkOnly bool) int64` (= `2*maxMemory`, or `maxMemory + 256 MiB` when `checkOnly`); `judge.PoolSize(budget, reservation int64) int` (= clamp(floor(budget/reservation), 1, 8)); `judge.CompileReservation(compileMax int64, cap, budget int64) int64` (= `budget` when `compileMax <= 0`, else `min(compileMax, cap)`); `type Budget = *semaphore.Weighted` created with `judge.NewBudget(bytes int64)`; acquiring more than the budget must not deadlock: `judge.Acquire(ctx, b, n, budget)` clamps `n` to `budget`.

- [ ] **Step 1: Failing tests** — the §6 examples: `(128 MiB,false)` → 256 MiB → pool 4 at 1 GiB; `(64 MiB,false)` → 8; `(256 MiB,true)` → 512 MiB → 2; `(1 GiB,false)` → pool 1; `CompileReservation(-1, 512 MiB, 1 GiB) == 1 GiB`; `CompileReservation(1 GiB, 512 MiB, 1 GiB) == 512 MiB`; `TestAcquireClampsToBudget` (acquire 2 GiB from a 1 GiB budget returns once released).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(judge): size the case pool from the memory reservation and share one budget`

---

### Task 8: Go build cache keeper

**Files:**
- Create: `internal/judge/gocache.go`
- Test: `internal/judge/gocache_test.go`

**Interfaces:**
- Produces: `judge.NewGoCache(dir string, capBytes int64, uid, gid uint32, runner func(ctx, sandbox.Spec) (sandbox.Result, error)) *GoCache`; `(*GoCache).Warm(ctx) error` (compile a hello-world with `/usr/bin/go build` as `compiler` when `/usr/bin/go` exists, else no-op); `(*GoCache).Trim() error` (if `du(dir) > cap`: remove contents, re-warm); `(*GoCache).Dir() string`. The job (Task 9) rewrites `GOCACHE=...` env entries to `Dir()` and calls `Trim()` after every Go compile.

- [ ] **Step 1: Failing tests** with a fake runner recording the Spec: `TestWarmRunsGoBuildAsCompiler` (Spec.Argv[0]=="/usr/bin/go", UID 12001, env contains `GOCACHE=<dir>`; skipped when `/usr/bin/go` is absent → test injects `goPath` via an unexported field), `TestTrimRemovesWhenOverCap` (write 2 files > cap, Trim → dir empty then Warm called once), `TestTrimKeepsUnderCap`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** (size via `filepath.WalkDir`). **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(judge): warm and cap the shared Go build cache`

---

### Task 9: The job pipeline

**Files:**
- Create: `internal/judge/job.go`, `internal/testutil/fakerunner.go`, `internal/testutil/bundle.go`
- Test: `internal/judge/job_test.go`

**Interfaces:**
- Consumes: Tasks 3-8.
- Produces:
  - `type LanguageConfig struct { Compile CompileConfig; Run RunConfig }`, `CompileConfig{SrcName, ExeName string; MaxCPUTimeMs, MaxRealTimeMs int64; MaxMemory int64; Command string; Env []string}`, `RunConfig{Command, SeccompRule string; Env []string; MemoryLimitCheckOnly bool}`, `Checker{Version, Src string; Compile CompileConfig; ExeName, Command, SeccompRule string}`
  - `type Request struct { Src string; Lang LanguageConfig; MaxCPUTimeMs, MaxMemory int64; Output bool; Bundle *bundle.Bundle; Checker *Checker }`
  - `type CaseResult struct { Name string; Result int32; Error int32; CPUTimeMs, RealTimeMs, MemoryBytes int64; Signal, ExitCode int32; OutputMD5 string; Output []byte; OutputTruncated bool }`
  - `type Outcome struct { Cases []CaseResult; CompileError string; SPJCompileError string }` (exactly one of the three populated; `CompileError`/`SPJCompileError` non-empty strings when set, capped at `CompileMessageCap`)
  - `type Deps struct { Runner func(context.Context, sandbox.Spec) (sandbox.Result, error); RunnerPath, WorkDir string; Budget judge.Budget; Cfg config.Config; GoCache *GoCache; Now func() time.Time }`
  - `judge.NewEngine(d Deps) *Engine`; `(*Engine).Judge(ctx context.Context, jobID string, r Request) (Outcome, error)` — `error` is `ErrInvalidRequest` (wrapping the reason), `ErrBundle` (corrupt bundle), or an internal error; never for a judge outcome.
  - Job dir layout: `<WorkDir>/jobs/<jobID>/{src, out, tmp}`; `src/` 0750 root:compiler, `out/` 0770 root:code (checker runs as `spj`, reads `N.out` via group? → make `out/` 0775 and user-output files 0644 so `spj` can read them); `tmp/` 1777.
  - Checker cache: `<WorkDir>/spj/<version>/spj-<version>` guarded by a `sync.Map` of `*sync.Once` per version; a failed compile is not cached.

- [ ] **Step 1: Write `testutil.FakeRunner`** — scripted by `Argv[0]` and a per-call queue: returns a `sandbox.Result` and optionally writes a given stdout file; records every `Spec`. `testutil.WriteBundle(t, root, id, cases []struct{Name, In, Out string}, spjVersion string)` builds a real on-disk bundle with the Java `info` shape.
- [ ] **Step 2: Failing tests** (fake runner; no Linux needed):
  - `TestJudgeCompileThenRunsEveryCase`: 3 cases → compile Spec as uid 12001 with `MaxAddressSpace == min(compileMax, 512 MiB)`, then 3 run Specs as uid 12002 with `Stdin == <case>.in`, `MaxRealTimeMs == 3*MaxCPUTimeMs`, `Seccomp == "c_cpp"`, `Env` contains `TMPDIR=<job>/tmp`; 3 results in bundle order.
  - `TestJudgeCompileErrorStopsBeforeRuns`: compile exit 1 with stderr text → `Outcome.CompileError == text`, no run Specs.
  - `TestJudgeCompileTimeoutMessage`: compile `Signal == SIGKILL` → `CompileError` starts with `Compiler Runtime Error, info: `.
  - `TestJudgeWrongAnswerByMD5`: fake writes `"2\n"` where expected is md5(`"1"`) → `Result == -1`, `OutputMD5 == md5("2")`.
  - `TestJudgeAcceptedCRLF`: fake writes `"1\r\n"` → `Result == 0` (intended divergence, §4.3).
  - `TestJudgeStderrIgnored`: fake writes to the stderr path and `"1\n"` to stdout → AC.
  - `TestJudgeOutputCapAndTruncation`: fake writes 100 KiB; `Output` length == `OutputResponseCap`, `OutputTruncated == true`; `Output` empty when `r.Output == false`.
  - `TestJudgeCheckerFlow`: Checker set, bundle `spj: true`: first a compile Spec as uid 12003 into `<WorkDir>/spj/v1/spj-v1`, then per case a run Spec with `Argv == [exe, <in>, <user out>]`, `Seccomp == "c_cpp"`, `MaxCPUTimeMs == 3*case cpu`; exit 0 → AC, exit 1 → WA, exit 2 → `Error == -11`, `Result == 5`; second job with the same version compiles the checker 0 times.
  - `TestJudgeCheckerCompileError`: → `Outcome.SPJCompileError` set, no case run.
  - `TestJudgeMemoryCheckOnlySkipsAS`: `MemoryLimitCheckOnly` → run Spec `MaxAddressSpace == 0`, but `memory > max` still gives 3.
  - `TestJudgeUnlimitedCompileReservesWholeBudget`: `Compile.MaxMemory == -1` → `MaxAddressSpace == 0` and the budget semaphore is fully held during the compile (assert via a second goroutine that `TryAcquire(1)` fails while the fake compile blocks).
  - `TestJudgePoolBounded`: 8 cases at 256 MiB → at most 4 concurrent run Specs (fake blocks on a channel, test counts in-flight).
  - `TestJudgeCancelKillsAndCleans`: cancel ctx while runs block → `Judge` returns `ctx.Err()`, the fake saw `ctx.Done()` for every in-flight run, job dir removed, budget fully released.
  - `TestJudgeGoEnvRewrite`: compile env `GOCACHE=/tmp` → Spec env has `GOCACHE=<GoCache.Dir()>`; a run env `GODEBUG=madvdontneed=1` passes through; a `FOO=/tmp` entry becomes `FOO=<job>/tmp`.
  - `TestJudgeInlineCases`: `bundle.Inline` → inputs written under `<job>/src/N.in`, expected md5 from normalised output.
  - `TestJudgeRejectsBadNames`: `SrcName == "../x"` → `ErrInvalidRequest`.
- [ ] **Step 3: Run** `go test ./internal/judge/` — FAIL.
- [ ] **Step 4: Implement `Engine.Judge`** following §5.2 steps 1-6; use `errgroup` with `SetLimit(pool)`; each case acquires its reservation from `Budget` before running and releases after; compile acquires `CompileReservation`; output read with `io.LimitReader(f, OutputResponseCap+1)`; file ownership via `os.Chown`/`os.Chmod` (needs CHOWN/FOWNER, available).
- [ ] **Step 5: Run** — PASS. Run `go vet ./...`.
- [ ] **Step 6: Commit** — `feat(judge): job pipeline with compile, checker cache, bounded case pool and cancellation`

---

### Task 10: Admission (slots and bounded queue)

**Files:**
- Create: `internal/api/admission.go`
- Test: `internal/api/admission_test.go`

**Interfaces:**
- Produces: `api.NewAdmission(maxJobs, maxQueue int) *Admission`; `(*Admission).Acquire(ctx) (release func(), err error)` with `err == api.ErrBusy` when `running == maxJobs && waiting == maxQueue` (checked atomically under a mutex), `ctx.Err()` when cancelled while waiting; `(*Admission).Running() int`, `(*Admission).Max() int`.

- [ ] **Step 1: Failing tests** — `TestAdmissionRunsUpToMax` (2 acquires succeed immediately), `TestAdmissionQueuesThenBusy` (max 2 / queue 1: third blocks, fourth returns `ErrBusy` within 10 ms), `TestAdmissionReleaseAdmitsWaiter`, `TestAdmissionCancelWhileWaiting` (returns `ctx.Err()`, waiting count back to 0), `TestAdmissionFIFO` (two waiters admitted in order).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** with a mutex, a counter and a slice of waiter channels. **Step 4: Run** — PASS, also with `-race`.
- [ ] **Step 5: Commit** — `feat(api): admit MAX_JOBS jobs with a bounded FIFO wait queue`

---

### Task 11: gRPC server, auth and ping

**Files:**
- Create: `internal/api/auth.go`, `internal/api/server.go`, `internal/api/ping.go`, `internal/testutil/tls.go` (generate a CA, a server cert `judge-server`, client certs `judge-worker` and `stranger` at test time with `crypto/x509`)
- Test: `internal/api/server_test.go`, `internal/api/ping_test.go`
- Modify: `cmd/judge-server/main.go` (`serve` and `healthcheck` wired)

**Interfaces:**
- Consumes: `judge.Engine`, `api.Admission`, `config.Config`, `bundle`.
- Produces:
  - `api.TLSConfig(dir string) (*tls.Config, error)` — server cert from `tls.crt`/`tls.key`, `ClientCAs` from `ca.crt`, `ClientAuth: tls.RequireAndVerifyClientCert`, min TLS 1.2.
  - `api.AuthInterceptor(allowedCNs []string, tokenSHA256Hex string) grpc.UnaryServerInterceptor` — `UNAUTHENTICATED` when a token is configured and metadata `x-judge-server-token` ≠ digest; `PERMISSION_DENIED` when the peer's leaf CN ∉ allowed, except for `/oj.judge.v1.JudgeServer/Ping` (CN exempt, token still required).
  - `api.NewServer(cfg config.Config, eng *judge.Engine, adm *Admission, version string) *Server` implementing `judgev1.JudgeServerServer`.
  - Request mapping: `JudgeRequest` → `judge.Request` (`bundle.Load(cfg.TestCaseDir, id)` with `ErrInvalidID` → `INVALID_ARGUMENT`, `ErrNotFound` → `NOT_FOUND`, `ErrCorrupt` → `INTERNAL`; inline: sum of inputs > `InlineInputCap` → `INVALID_ARGUMENT`; unknown seccomp rule (not in {`c_cpp`,`general`,``}) → `INVALID_ARGUMENT`); `ErrBusy` → `RESOURCE_EXHAUSTED`; `judge.ErrInvalidRequest` → `INVALID_ARGUMENT`; `ctx` cancelled → `CANCELLED`/`DEADLINE_EXCEEDED` as the context says; other errors → `INTERNAL`.
  - Response mapping: `Outcome.Cases` → `CaseResults`; `CompileError` → `compile_error`; `SPJCompileError` → `spj_compile_error`.
  - `api.PingInfo(hostname string, version string, running, max int, sampler *CPUSampler) *judgev1.PingResponse`; `api.NewCPUSampler()` reading `/proc/stat` (two samples ≥ 200 ms apart, cached 5 s) and memory % from `/sys/fs/cgroup/memory.current` / `memory.max` when present else `/proc/meminfo` (`1 - MemAvailable/MemTotal`).
  - `api.Serve(ctx, cfg, version) error` — builds everything, `GoCache.Warm`, listens, graceful stop on SIGTERM (waits for running jobs up to 120 s).
  - `api.Healthcheck(cfg) error` — dials `127.0.0.1` + port of `cfg.Listen` with the server's own cert as client cert, `ServerName` = `os.Hostname()`, sends `Ping` with the token; exit 0 iff OK within 3 s.

- [ ] **Step 1: Failing tests** using an in-process listener over real TLS from `testutil.TLS` and a fake `Engine` (interface `Judger { Judge(ctx, id, judge.Request) (judge.Outcome, error) }` — introduce it in `server.go` so tests can stub):
  `TestJudgeMapsResults` (3 cases → 3 `CaseResult`s with every field), `TestJudgeMapsCompileError`, `TestJudgeMapsSPJCompileError`, `TestStatusInvalidID`, `TestStatusNotFound`, `TestStatusCorruptIsInternal`, `TestStatusBusy` (admission 1/0, first call blocks → second gets `RESOURCE_EXHAUSTED`), `TestStatusInlineCap`, `TestStatusUnknownSeccomp`, `TestAuthTokenMissing` (→ `UNAUTHENTICATED`), `TestAuthStrangerCN` (→ `PERMISSION_DENIED` on Judge, OK on Ping), `TestAuthNoClientCertHandshakeFails`, `TestPingFields` (hostname, version, `cpu_core == runtime.NumCPU()`, `running_jobs`/`max_jobs`, `0 ≤ cpu,memory ≤ 100`), `TestDeadlinePropagates` (client deadline 50 ms, fake engine blocks → engine's ctx is done, client gets `DEADLINE_EXCEEDED`).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS with `-race`.
- [ ] **Step 5: Wire `serve` and `healthcheck`** in `main.go`; `version` from `-ldflags "-X main.version=..."`, default `dev`.
- [ ] **Step 6: Commit** — `feat(api): gRPC JudgeServer over mutual TLS with CN allow-list, status mapping and ping`

---

### Task 12: Mock subcommand

**Files:**
- Create: `internal/mock/mock.go`
- Test: `internal/mock/mock_test.go`
- Modify: `cmd/judge-server/main.go`

**Interfaces:**
- Produces: `mock.NewServer(testCaseDir string, slow time.Duration) judgev1.JudgeServerServer`; `mock.Serve(ctx, cfg config.Config, slow time.Duration) error` (same TLS/auth as `serve`; `MOCK_SLOW_SECONDS` env default 3 parsed in main). Behaviour ported from `judge-deployment/mock-judge-server/app.py`: `TRIGGER_CE` → `compile_error` with the fixed message; `TRIGGER_SLOW` → sleep; bundle id → one AC result per case from `info` (`cpu_time 12, real_time 15, memory 3624960, output "mock"`), with `TRIGGER_SE/WA/TLE/MLE/RE` replacing the second case (first when only one) with codes 5 (error -10), -1, 1, 3, 4; inline cases → one result per case echoing the input as output; unreadable bundle → the fixed 3-case answer. `Ping` returns `judger_version "mock"`.

- [ ] **Step 1: Failing tests** mirroring `mock-judge-server/test_app.py` cases (read it first; port each assertion): count equals bundle cases, trigger replaces the second case, inline echo, CE envelope, unreadable bundle fallback.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(mock): gRPC mock with the Python mock's TRIGGER_* behaviour`

---

### Task 13: Image, runner build, sandbox test run, corpus

**Files:**
- Create: `Dockerfile`, `.dockerignore`, `scripts/sandbox-test.sh`, `testdata/corpus/corpus.json`, `testdata/corpus/<lang>/*`
- Test: `internal/judge/engine_sandbox_test.go` (`//go:build sandbox`), plus Task 6's tests

**Interfaces:**
- Image stages: `builder-go` (`golang:1.23-bookworm`: `CGO_ENABLED=0 go build -ldflags "-s -w -X main.version=$VERSION" ./cmd/judge-server`; also `go test -c -tags sandbox -o /out/<pkg>.test` for `internal/sandbox` and `internal/judge`); `builder-c` (`ubuntu:22.04` + `gcc libseccomp-dev`: `gcc -O2 -static -o judge-runner runner.c -lseccomp`); `runtime` (`ubuntu:22.04`: `apt-get install --no-install-recommends gcc g++ openjdk-17-jdk-headless python2 python3 golang-go nodejs php8.1-cli`, `ln -s /usr/bin/python2 /usr/bin/python`, users 12001-12003 with `nologin`, `COPY judge-server /usr/local/bin/`, `COPY judge-runner /usr/local/bin/`, `/work` and `/test_case` dirs, `ENTRYPOINT ["/usr/local/bin/judge-server"]`, `CMD ["serve"]`, `HEALTHCHECK` none here: compose declares it); `test` stage = runtime + the `.test` binaries + `testdata`.
- `scripts/sandbox-test.sh`: `docker build --target test -t judge-server:test .` then `docker run --rm --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --cap-add KILL --security-opt no-new-privileges:true --read-only --tmpfs /work:exec,size=512m --tmpfs /tmp:size=64m --memory 1536m --cpus 2 judge-server:test /tests/run-all.sh` where `run-all.sh` runs each `.test` binary with `-test.v`.
- Corpus (`corpus.json`: `[{"lang":"cpp","file":"ac.cpp","expect":0}, ...]`): per language {c, cpp, java, python2, python3, go, javascript, php}: `ac`, `wa`, `tle` (busy loop), `re` (non-zero exit / exception), `ce` (syntax error; for interpreted languages without a compile step, `ce` is omitted and documented), plus for C++: `mle` (allocate 2× limit and touch), `rtle` (sleep), `flood` (print 1 GiB → RE and truncation), `crlf` (prints `1\r\n` → AC), `stderr` (prints to stderr and correct stdout → AC), `fork` (under general: python `os.fork()` → RE), `socket` (C `socket()` → RE), `checker/{ok.cpp, spj.cpp, spj_ce.cpp, spj_crash.cpp}`. Problem for all: read two ints, print the sum; bundle of 3 cases built by the test.

- [ ] **Step 1: Write `engine_sandbox_test.go`** — builds the real `Engine` (`sandbox.Run`, `/usr/local/bin/judge-runner`) with the §3 language rows copied verbatim from `V2`/`V3`/`V9` (as a Go table `languageRows`), the Python 3 row with the part-2 V10 command (`-c import py_compile;...`, `exe_name solution.pyc`), and the Java row's `-Djava.security.policy==/opt/oj/java.policy` dropped for the test (the policy file is a compose mount, see part 2; the test documents this). For each `corpus.json` entry: judge and assert the first failing case's `Result` (or `CompileError != ""` for `expect == -2`). Extra assertions: `flood` → `OutputTruncated`, tmpfs usage after the run < 10 MiB (`du /work`); `TestEngineMissingBundle` → `bundle.ErrNotFound`; `TestEngineCancel` (Go program sleeping 10 s, cancel after 200 ms → returns in < 1 s, `pgrep -u 12002` empty, `/work/jobs` empty); `TestEngineCheckerCorpus`.
- [ ] **Step 2: Write the Dockerfile, `.dockerignore`, scripts, corpus files.**
- [ ] **Step 3: Run `scripts/sandbox-test.sh`** — Expected: FAIL at first on seccomp (Task 6 allow-list) or packaging; iterate on `runner.c`/`Dockerfile` until every tagged test passes. Record the glibc 2.35 additions in `seccomp_rules.md`.
- [ ] **Step 4: Run again** — Expected: every `.test` reports `PASS`; `docker image ls judge-server:test` size noted in README.
- [ ] **Step 5: Smoke `serve`** — run the runtime image with the test TLS material from `testutil` exported by a tiny `go run ./internal/testutil/cmd/mktls` into a temp dir, `grpcurl -cacert ca.crt -cert judge-worker.crt -key judge-worker.key -H 'x-judge-server-token: <sha256>' localhost:8080 oj.judge.v1.JudgeServer/Ping` → JSON with `hostname`, `max_jobs: 2`.
- [ ] **Step 6: README.md** — what it is, the contract pointer (spec §4), env table (§5.5), how to build/test (`make test`, `make sandbox-test`), the corpus, the seccomp provenance.
- [ ] **Step 7: Commit** — `feat(image): ubuntu 22.04 runtime with the eight toolchains, runner shim, sandbox tests and corpus`

---

## Self-review notes

- Spec coverage: §4.1 Task 1/11; §4.2 Tasks 10-11; §4.3 Tasks 3, 4, 9; §5.1-5.2 Tasks 9, 13; §5.3 Task 6; §5.4 Task 5;
  §5.5 Task 2; §5.6 Task 2 (slog) + Task 11 ping; §6 Tasks 7, 9; §7 image Task 13 (migrations in part 2); §8 mock
  Task 12 (worker/compose in part 2); §9.1-9.2 Tasks 3-13; §9.3-9.4 part 2.
- Type consistency: `sandbox.Result{CPUTimeMs, RealTimeMs, MemoryBytes, Signal, ExitCode, Error}` is defined in Task 5
  and used in Tasks 6, 9; `judge.Outcome` in Tasks 9, 11; `api.ErrBusy` in Tasks 10, 11; `bundle.Err*` in Tasks 4, 11.
- Review Focus items 1-5 each have a named test (Tasks 13, 4, 9/11/13, 10, 4).
