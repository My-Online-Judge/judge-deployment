# K3s Migration Implementation Plan (Judge Pod sidecar)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chạy toàn bộ stack trên K3s một node với Judge Pod = sandbox + worker ghép 1-1, KEDA scale theo Kafka lag, cert-manager thay `pki.sh`, Traefik thay Caddy; compose vẫn chạy được cho tới cutover.

**Architecture:** Kustomize `k3s/base` + overlays `local` (k3d, mock sandbox, CA tự ký) và `vps` (Let's Encrypt, limits thật). Mỗi identity trong `pki/identities.txt` thành một `Certificate` của cert-manager với cùng CN, nên `oj.tls.allowed-clients`, Kafka ACL và MinIO policy không đổi. Judge Pod chia sẻ `emptyDir` test-case cache; sandbox giữ nguyên hardening của compose.

**Tech Stack:** K3s ≥ 1.31 (Traefik, local-path), Kustomize, cert-manager 1.x, KEDA 2.x (Helm), k3d cho local, kubeconform + `kubectl --dry-run=server` cho test.

**Spec:** `judge-deployment/docs/superpowers/specs/2026-10-28-k3s-judge-pod-spec.md`

**Tiền đề:** Phase 1 (`2026-10-28-phase1-fixes.md`) đã merge và chạy trên compose.

## Global Constraints

- Namespace `oj`. Image `ghcr.io/my-online-judge/<name>:<tag>` như compose; sandbox pin digest `sha256:a580a1643277b4ec5a103a46fe1dbfe8537c437996955f82a5a22801ec73239e`.
- Judge Pod: `terminationGracePeriodSeconds: 120`; sandbox `securityContext` = compose `x-sandbox` (drop ALL; add CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID, KILL; `allowPrivilegeEscalation: false`; `readOnlyRootFilesystem: true`; `seccompProfile: RuntimeDefault`); worker `runAsUser: 10001`, drop ALL.
- Khởi điểm resources (bench ở T6 quyết định giá trị cuối): sandbox `requests cpu 1 / memory 1.5Gi`, `limits cpu 2 / memory 2.5Gi`; worker `requests 100m/128Mi`, `limits 300m/256Mi`; mỗi Java service `limits memory 1Gi`, `JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=60.0 -XX:+UseSerialGC"` nối trước chuỗi OTel; Kafka `KAFKA_HEAP_OPTS="-Xmx512M -Xms512M"`, `limits memory 1Gi`; Postgres mỗi cái `limits memory 512Mi`; Redis 128Mi; MinIO 512Mi.
- KEDA: `judge` ScaledObject trigger `kafka` `consumerGroup: judge-workers`, `topic: submission.requested`, `lagThreshold: "5"`, `minReplicaCount: 1`, `maxReplicaCount: 4`, `cooldownPeriod: 300`; `run-judge`: `consumerGroup: run-workers`, `topic: run.requested`, min 1, max 2.
- Mọi hop nội bộ vẫn mTLS; sandbox 8080 chỉ nhận từ Pod của nó (NetworkPolicy).
- Không ghi gì ngoài `~/Personal/my-oj`.

## Review Focus

1. Pod judge bị `kubectl delete` khi worker đang `wait()` vì Kafka down: pod phải thoát trong 120 s, không chờ hết retry — kiểm tra ở T6 Step 6 (kịch bản Kafka scaled to 0).
2. Sandbox OOMKilled giữa bài (`memory 2.5Gi` không đủ cho một bài compile nặng): worker nhận connection reset → phải thành SYSTEM_ERROR có `judgedBy`, không treo — T6 Step 5.
3. cert-manager chưa cấp xong cert khi Pod start: container phải `CrashLoop` rồi tự lên, không chạy plaintext — T2 Step 4 (xóa Secret, xem pod).
4. KEDA scale về 0 là **không** được phép (`minReplicaCount: 1`), vì heartbeat registry dựa vào worker — T7 Step 3.
5. Hai pod judge cùng tải một bundle từ MinIO (cache per pod): hai lần download là bình thường, nhưng không được lỗi — T6 Step 4 submit 8 bài cùng problem với 2 pod.

---

### Task 1: Kustomize skeleton, namespace, test harness

**Files:**
- Create: `judge-deployment/k3s/base/kustomization.yaml`, `k3s/base/namespace.yaml`, `k3s/overlays/local/kustomization.yaml`, `k3s/overlays/vps/kustomization.yaml`, `k3s/README.md`
- Create: `judge-deployment/tests/k3s-render.test.sh` (kustomize build cả hai overlay + `kubeconform -strict -ignore-missing-schemas`), thêm vào `.github/workflows/ci.yml` bước cài `kustomize`/`kubeconform` pinned version
- Create: `judge-deployment/scripts/k3d-up.sh` (`k3d cluster create oj --agents 0 -p "443:443@loadbalancer" --k3s-arg "--disable=traefik@server:0"` **không** disable — giữ Traefik; registry mirror cho GHCR)

**Interfaces:** `tests/k3s-render.test.sh` exit 0 khi cả hai overlay render và validate; mọi task sau thêm file vào `base/kustomization.yaml` và chạy test này.

- [ ] **Step 1: Viết test** `tests/k3s-render.test.sh` (PASS/FAIL theo pattern `tests/lib`), chạy → FAIL (`k3s/base` chưa có).
- [ ] **Step 2: Tạo skeleton**, namespace `oj`, overlay rỗng (`resources: [../../base]`).
- [ ] **Step 3: `bash tests/k3s-render.test.sh` PASS; CI job mới chạy nó.**
- [ ] **Step 4: Commit** — `feat(k3s): kustomize skeleton with render/validate test`

---

### Task 2: PKI qua cert-manager

**Files:**
- Create: `k3s/base/pki/cert-manager-ns.yaml` (HelmChart CRD của K3s: `cert-manager` pinned version), `k3s/base/pki/ca-issuer.yaml` (`ClusterIssuer` kind CA đọc Secret `oj-ca`), `k3s/base/pki/certificates.yaml` (một `Certificate` per dòng trong `pki/identities.txt`: `commonName` = id, `dnsNames` = `[<id>, <id>.oj.svc, <id>.oj.svc.cluster.local, localhost]`, `usages: [server auth, client auth]`, `duration: 8760h`, `renewBefore: 720h`, `secretName: tls-<id>`, `privateKey: {algorithm: RSA, size: 2048}`)
- Create: `k3s/scripts/ca-from-pki.sh` (tạo Secret `oj-ca` từ `pki/out/ca/ca.crt|ca.key` — cùng CA với compose để cutover không đổi trust) và `k3s/overlays/local/selfsigned-ca.yaml` (bootstrap `SelfSigned` → `oj-ca` khi không có `pki/out`)
- Create: `k3s/scripts/gen-certificates.sh` — sinh `certificates.yaml` từ `pki/identities.txt` để hai nguồn không lệch; `tests/k3s-pki.test.sh` kiểm tra file sinh ra khớp file commit
- Modify: `pki/identities.txt` thêm `keda`, `traefik`

**Interfaces:** mọi workload mount `secret: tls-<id>` tại `/etc/oj/tls` với key `tls.crt`, `tls.key`, `ca.crt` (cert-manager ghi đúng ba key này). Owner/mode: `defaultMode: 0640` + `fsGroup` = uid của service (10001 Java/worker, 101 portal, 999 postgres, 1000 kafka) — thay cho chown của `tls-init`.

- [ ] **Step 1: Test** `tests/k3s-pki.test.sh` FAIL (chưa có generator).
- [ ] **Step 2: Implement** generator, issuer, overlay bootstrap.
- [ ] **Step 3: Render test + pki test PASS.**
- [ ] **Step 4: Live k3d:** `kubectl apply -k overlays/local`, `kubectl get certificate -n oj` → tất cả `Ready=True`; `kubectl delete secret tls-identity-service` → được cấp lại trong < 1 phút.
- [ ] **Step 5: Commit** — `feat(k3s): cert-manager CA issuer and one Certificate per pki identity`

---

### Task 3: Data layer — Postgres ×3, Kafka, Redis, MinIO + init Jobs

**Files:**
- Create: `k3s/base/data/postgres-<identity|problem|submission>.yaml` (StatefulSet `postgres:16`, PVC `local-path` 10Gi, `pg_hba`/`postgresql.conf` ConfigMap như compose `configs: pg-hba`, TLS mount, `oj_monitor` role qua init script), `data/kafka.yaml` (StatefulSet `apache/kafka:3.8.1`, env như compose kể cả `KAFKA_HEAP_OPTS`, PVC 20Gi, PEM keystore từ Secret `tls-kafka` — cần `keystore.pem` = cert+key: thêm initContainer ghép), `data/kafka-init-job.yaml` (chạy `kafka/acls.sh`), `data/redis.yaml`, `data/minio.yaml` + `minio-init-job.yaml` (policies từ `minio/policies`)
- Create: `k3s/base/data/secrets.example.yaml` + `k3s/scripts/env-to-secrets.sh` (đọc `.env`, `.env.identity|problem|submission` của compose → `kubectl create secret generic ... --dry-run=client -o yaml`; không commit output)
- Modify: `kafka/acls.sh` nhận `KAFKA_BOOTSTRAP` để chạy trong Job

**Interfaces:** Service DNS: `identity-db`, `problem-db`, `submission-db` (:5432), `kafka` (:29092), `redis` (:6379), `minio` (:9000) — trùng tên compose nên config service không đổi.

- [ ] **Step 1: Render test** thêm assertion: mọi container trong `data/` có `resources.limits.memory`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Live k3d:** `kubectl -n oj get pods` tất cả Running; `kubectl -n oj logs job/kafka-init` in ACL đã tạo; `kubectl -n oj exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list`.
- [ ] **Step 4: Commit** — `feat(k3s): stateful data layer with local-path PVCs and the init jobs`

---

### Task 4: Java services, portal, edge (Traefik)

**Files:**
- Create: `k3s/base/services/<identity|problem|submission|gateway>.yaml` (Deployment 1 replica, `Recreate` cho submission-service — `container_name` hôm nay cũng 1 instance; Service `:8000`/`:8081`/`:9090`; `JAVA_TOOL_OPTIONS`; env từ Secret; TLS mount; `readinessProbe` `/actuator/health/readiness` qua HTTPS với client cert → dùng `exec curl` như sandbox), `services/networkpolicy.yaml` (default deny ingress trong ns; cho phép gateway→3 service, submission→problem:9090, mọi service→kafka/redis/db/minio tương ứng, prometheus→8081)
- Create: `k3s/base/portal/portal.yaml`, `k3s/base/edge/ingressroute.yaml` (Traefik `IngressRoute` websecure: `/api` → gateway, `/` → portal; `ServersTransport` với client cert `tls-traefik` + CA; middleware `headers` = CSP/nosniff/referrer/frame từ Phase 1 T11; `buffering maxRequestBodyBytes: 1048576`), `edge/cert-local.yaml` (Certificate từ CA cho `localhost`) và `overlays/vps/cert-le.yaml` (`ClusterIssuer` ACME + Certificate cho `OJ_PUBLIC_HOST`)
- Modify: gateway config `oj.gateway.edge.trust-forwarded-for` — Traefik đặt `X-Forwarded-For` và trình cert CN `traefik`: thêm `traefik` vào `oj.tls.allowed-clients` của gateway và vào `EdgeClientIp` CN allow-list (`oj-api-gateway/.../EdgeClientIp.java:25-43` hiện hard-code `edge`) → đổi thành property `oj.gateway.edge.cn: edge` và set `traefik` trong K3s env.

**Interfaces:** `https://localhost/` (local) hoặc `https://<OJ_PUBLIC_HOST>/` (vps) là entry duy nhất.

- [ ] **Step 1: gateway test** `EdgeClientIpTest.trustsTheConfiguredEdgeCn` FAIL → implement property → PASS → commit gateway.
- [ ] **Step 2: Render test PASS** với assertion: không Deployment nào thiếu `readinessProbe` và `resources.limits`.
- [ ] **Step 3: Live k3d:** `curl --cacert ca.crt https://localhost/api/v1/languages` → 200; login admin; tạo problem; headers CSP có mặt; POST 2 MB → 413.
- [ ] **Step 4: Commit** — `feat(k3s): the four Java services, the portal and the Traefik edge over mTLS`

---

### Task 5: Judge Pod và Run Pod manifests

**Files:**
- Create: `k3s/base/judge/judge.yaml` (Deployment `judge`: hai container như spec §3 của tài liệu gốc đã đối chiếu; volumes `cases` emptyDir 2Gi, `judger` emptyDir Memory 512Mi, `tmp` emptyDir Memory 256Mi, `tls-judge-server`, `tls-judge-worker`; sandbox `startupProbe`/`livenessProbe` `curl --cacert --cert --key https://localhost:8080/ping`; worker env `POD_NAME` Downward API, `JUDGE_SERVER_URL=https://localhost:8080`, `CONSUMER_GROUP=judge-workers`, `MAX_POLL_INTERVAL_MS=600000`, `SANDBOX_HEARTBEAT_URL`, MinIO worker key; `terminationGracePeriodSeconds: 120`; `shareProcessNamespace: false`), `judge/run-judge.yaml` (bản sao với `CONSUMER_GROUP=run-workers`, topic `run.*`, không MinIO, `JUDGE_INFRA_RETRY_SECONDS=30`), `judge/networkpolicy.yaml` (ingress: chỉ prometheus→9100; egress worker: kafka:29092, minio:9000, submission-service:8000, DNS; sandbox: không egress), `judge/pdb.yaml` (`minAvailable: 1` cho `judge`)
- Create: `k3s/overlays/local/mock-sandbox-patch.yaml` (thay image sandbox bằng `mock-judge-server`, bỏ cap/seccomp; sửa `mock-judge-server/app.py` `/ping` trả dict để heartbeat không luôn Offline — bug ghi nhận trong đánh giá)

**Interfaces:** label `app: judge` / `app: run-judge`; KEDA (T7) target `Deployment/judge`, `Deployment/run-judge`.

- [ ] **Step 1: Render test** thêm assertion: container `sandbox` không `privileged`, `capabilities.drop == [ALL]`, `readOnlyRootFilesystem: true`; container `worker` `runAsUser: 10001`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Live k3d với mock:** submit → verdict về SSE; `t_judge_servers` có row Online tên = tên pod (sandbox chung hostname với Pod); `judged_by` trong DB = tên pod.
- [ ] **Step 4: Commit** — `feat(k3s): judge and run-judge pods — sandbox and worker side by side`

---

### Task 6: Judge Pod với sandbox thật — bench, sizing, shutdown

**Files:**
- Modify: `k3s/base/judge/judge.yaml` (giá trị resources cuối), `k3s/README.md` (bảng kết quả bench), `bench/README.md` (mục K3s)
- Create: `k3s/scripts/judge-bench.sh` (submit N bài a+b C++/Java/Python qua API, đo thời gian tới verdict; dựa trên `bench/k6` nếu dùng lại được)

- [ ] **Step 1: Chạy 1 pod, 8 bài a+b C++ song song** → mọi verdict ACCEPTED, không OOMKilled (`kubectl describe pod` → `Last State` không `OOMKilled`). Nếu OOMKilled: tăng `limits.memory` theo bước 512Mi, ghi lại.
- [ ] **Step 2: Bài compile nặng** (`#include <bits/stdc++.h>` + template nặng) → ACCEPTED, không OOMKilled.
- [ ] **Step 3: Bài TLE thật (vòng lặp vô hạn, time limit 1 s)** → TLE, không SYSTEM_ERROR, thời gian cpu đo được ≈ time limit (không false TLE do throttle): so với compose cùng bài.
- [ ] **Step 4: 2 pod, 8 bài cùng problem** → cả hai pod tải bundle, cả 8 ACCEPTED (Review Focus 5).
- [ ] **Step 5: OOM giả lập** — tạm set sandbox `limits.memory 300Mi`, submit compile nặng → verdict SYSTEM_ERROR có `judgedBy`, pod sandbox restart, worker không treo (Review Focus 2). Khôi phục limit.
- [ ] **Step 6: Shutdown** — submit bài C++ chạy 10 s, `kubectl delete pod judge-xxx` ngay → verdict thật trong DB, `judged_by` = pod cũ, pod mới lên, không SYSTEM_ERROR; lặp lại với `kubectl scale sts kafka --replicas=0` trước khi delete pod → pod thoát trong < 120 s (Review Focus 1), scale kafka lại → bài được chấm lại bởi pod mới (at-least-once, verdict đầu thắng).
- [ ] **Step 7: Ghi số liệu vào `k3s/README.md`; commit** — `docs(k3s): judge pod sizing from the a+b, heavy-compile and shutdown runs`

---

### Task 7: KEDA

**Files:**
- Create: `k3s/base/keda/helmchart.yaml` (K3s `HelmChart` CRD, KEDA pinned version, `resources` nhỏ), `k3s/base/keda/trigger-auth.yaml` (`TriggerAuthentication` đọc Secret `tls-keda`: `ca`, `cert`, `key`, `tls: enable`), `k3s/base/keda/scaledobject-judge.yaml`, `scaledobject-run-judge.yaml` (giá trị ở Global Constraints; `bootstrapServers: kafka:29092`, `offsetResetPolicy: earliest`, `allowIdleConsumers: false`)
- Modify: `kafka/acls.sh` (CN `keda`: `Describe` trên group `judge-workers`, `run-workers` và topic `submission.requested`, `run.requested`), `tests/kafka-acls.test.sh`

- [ ] **Step 1: `tests/kafka-acls.test.sh` thêm case keda → FAIL → sửa acls.sh → PASS.**
- [ ] **Step 2: Render test PASS** (ScaledObject `minReplicaCount >= 1`).
- [ ] **Step 3: Live k3d (mock sandbox):** stress 100 bài (`judge-bench.sh 100`) → `kubectl get hpa -n oj` lên tới 4 và không hơn; sau khi lag = 0, 300 s sau về 1, **không bao giờ 0** (Review Focus 4). `kubectl top node` < 85 % RAM.
- [ ] **Step 4: Cập nhật submission-service `JUDGE_MAX_QUEUE_DEPTH` trong Secret** theo `maxReplicaCount × throughput đo ở T6 × 20 phút`; ghi công thức vào `k3s/README.md`.
- [ ] **Step 5: Commit** — `feat(k3s): KEDA scales the judge pods on submission.requested lag (1–4) and run-judge (1–2)`

---

### Task 8: Observability trên K3s

**Files:**
- Create: `k3s/base/observability/prometheus.yaml` (ConfigMap từ `prometheus.yml` chuyển sang `kubernetes_sd_configs` role `pod` cho job `judge-worker`/`run-worker` theo label; các job tĩnh giữ DNS), `alertmanager.yaml`, `grafana.yaml` (dashboards ConfigMap từ `grafana/`), `jaeger.yaml`, exporters như compose; tất cả có `resources.limits`
- Modify: `alerts.yml` — `JudgeWorkerDown` đổi điều kiện thành `count(up{job="judge-worker"}==1) < 1` (pod động), thêm `JudgePodOOMKilled` từ `kube_pod_container_status_last_terminated_reason{reason="OOMKilled",container="sandbox"}` (cần `kube-state-metrics` — thêm, pinned), `for:` của 4 alert service-down `15s` → `1m`
- Test: `tests/prometheus.test.sh`, `tests/grafana.test.sh` vẫn PASS với file mới

- [ ] **Step 1: Test PASS/FAIL theo rule mới.**
- [ ] **Step 2: Live:** `http://127.0.0.1:9090/targets` (port-forward) mọi target up; alert `JudgePodOOMKilled` bắn khi lặp T6 Step 5.
- [ ] **Step 3: Commit** — `feat(k3s): prometheus, alertmanager, grafana, jaeger and exporters; pod-aware judge alerts`

---

### Task 9: Backup, runbook cutover, CI

**Files:**
- Create: `k3s/base/backup/cronjob.yaml` (restic trong CronJob, PVC riêng; repo **ngoài host** qua `RESTIC_REPOSITORY` S3/B2 trong Secret — không cùng đĩa), `k3s/scripts/restore-drill.sh` (k3d từ snapshot), `k3s/README.md` mục "Cutover từ compose" (thứ tự: dump 3 Postgres + `mc mirror` MinIO → PVC; `ca-from-pki.sh`; `env-to-secrets.sh`; apply vps overlay; DNS; smoke theo README sp3b bước 5; `scripts/stats-check.sh` PASS; rollback = compose vẫn còn nguyên)
- Modify: `.github/workflows/ci.yml` — job `k3s`: k3d + overlay local + mock sandbox, chạy `judge-bench.sh 5` và `kubectl delete pod` test shutdown (acceptance chính của spec)

- [ ] **Step 1: CI job chạy xanh trên PR.**
- [ ] **Step 2: Restore drill từ snapshot thật → `stats-check.sh` PASS.**
- [ ] **Step 3: Commit** — `feat(k3s): off-host restic CronJob, restore drill, cutover runbook, CI on k3d`

---

### Task 10: Cutover VPS

- [ ] **Step 1:** Cài K3s, `kubectl apply -k overlays/vps` tới hết T4 (không judge/KEDA), import dữ liệu theo runbook T9.
- [ ] **Step 2:** Smoke test đọc (login, list, problem page) với DNS tạm (`/etc/hosts`).
- [ ] **Step 3:** `docker compose stop api-gateway` (ngừng nhận submit), chờ queue = 0, dump lại submission-db, import; apply judge + KEDA; đổi DNS.
- [ ] **Step 4:** Smoke test ghi (submit → SSE → stats +1), `stats-check.sh` PASS, Jaeger trace xuyên pod.
- [ ] **Step 5:** 24 h quan sát; rồi `docker compose down` (giữ volume 7 ngày), ghi ngày vào `k3s/README.md`.

---

## Self-review

- Spec coverage: Task 2 gốc (Judge Pod) → T5–T6; Task 1 gốc (worker) → Phase 1; Task 3 gốc (KEDA) → T7; Task 4 gốc (PVC, JVM, Kafka heap) → T3–T4; nghiệm thu "delete pod giữa bài" → T6 Step 6 + CI T9; "stress 100 bài" → T7 Step 3; "judged_by" → T5 Step 3. Mục 2 #8 (edge public) → T4 LE overlay. ✔
- Tên nhất quán: Secret `tls-<id>`, label `app: judge|run-judge`, group `judge-workers|run-workers`, Service DNS trùng compose. ✔
- Review Focus 1,2,5 → T6; 3 → T2; 4 → T7. ✔
- Mở: T6 có thể cho thấy `cpu: 2` vẫn gây false TLE khi qduoj chạy case song song — khi đó cân nhắc `cpu: 4` + `maxReplicaCount: 2` (giữ tổng CPU không đổi), quyết định ghi vào `k3s/README.md`.

---

## Rulings made while executing (the git log has the detail)

- **Platform split (T2, T7).** cert-manager and KEDA are cluster add-ons, not part of the stack's namespace: they live in
  `k3s/platform` (HelmChart objects in `kube-system`, applied once, before the overlays), not in `base/pki` / `base/keda`.
  A `kubectl wait` for their CRDs sits between the two applies. `tests/k3s-render.test.sh` renders `platform` too.
- **Namespaced Issuer, not ClusterIssuer (T2).** `Issuer oj-ca` signs with the Secret `oj-ca` of namespace `oj`; nothing
  cluster-scoped belongs to the stack. `overlays/local` bootstraps that Secret with a SelfSigned root; the server loads the
  compose stack's CA with `k3s/scripts/ca-from-pki.sh`.
- **Traefik's client certificate is the identity `edge` (T4).** The gateway and the portal admit CN=edge and the gateway trusts
  `X-Forwarded-For` only from it. Traefik presents `tls-edge`, so there is no `traefik` identity and **no change to
  oj-api-gateway** (the plan's `oj.gateway.edge.cn` property is dropped).
- **k3d host ports 18443/18080 (T1).** 8080 and 8443 are held by other containers on the development machine; the script
  checks and the ports are configurable.
- **No separate CI job for the render test (T1).** The workflow's "Offline tests" loop runs every `tests/*.test.sh`.
- **Data layer runs non-root (T3).** Postgres (uid 999), Kafka (1000), Redis (999) and MinIO (1000) run as their non-root user with
  `fsGroup`, so no pod needs `CHOWN`/`SETUID`; `RuntimeDefault` seccomp everywhere. TLS keys are root-owned `0640` with the group
  (Postgres accepts that). Kafka's PEM keystore (key + certificate) is made by an init container.
- **Two Kafka specifics (T3).** `enableServiceLinks: false` on every pod (service-link `KAFKA_PORT` would be read as broker
  configuration) and `publishNotReadyAddresses: true` on Service `kafka` (the broker joins `kafka:9093` before it is Ready).
- **Generated manifests (T3).** `postgres.yaml` and the init ConfigMaps are generated by `k3s/scripts/gen_data.py` and tested
  against drift, like `certificates.yaml`; `tests/k3s-data.test.sh` also compares Kafka's environment and the Postgres, Redis and
  MinIO command lines with compose's.
- **Jaeger moves into T4 (T4, T8).** The services export traces to `https://jaeger:4318`; without it every pod logs a failed export. It is
  a small Deployment (`services/jaeger.yaml`), and T8 keeps Prometheus, Alertmanager, Grafana and the exporters.
- **Services are generated like the data layer (T4).** `java.yaml` and `configs.yaml` come from `k3s/scripts/gen_services.py`; the
  environment of each service is compared with compose's by `tests/k3s-services.test.sh`.
- **Edge details (T4).** Traefik's ServersTransports verify each backend under its own name (`api-gateway`, `judge-portal`) and present
  `tls-edge`; the portal pod sets `net.ipv4.ip_unprivileged_port_start=0`; the consoles of MinIO and Jaeger are not Service ports.
- **NetworkPolicies per target app (T4).** One policy per app with a `matchLabels: {app: …}` selector plus a default deny, so the test can
  check that every Service port has an allow rule. Rules for the judge pods (T5), KEDA (T7) and Prometheus (T8) are added with them.
- **CPU requests of the JVMs 250m (T4).** The first start of three services missed its five-minute startup probe while the node was busy.
- **The sandbox is a native sidecar (T5).** An init container with `restartPolicy: Always` gives the order the plan wanted without a
  `depends_on`: it starts and passes its probe before the worker, and stops after it (K8s 1.28+; K3s here is 1.35).
- **A pod cannot isolate its sandbox's network (T5).** `sandbox-net: internal` separated the sandbox from the worker; two containers of a
  pod share one network namespace, so the plan's "sandbox: no egress" is not expressible. Compensations, tested: no ServiceAccount
  token on any pod, the worker's certificate is not mounted in the sandbox container, and `egress-judge` / `egress-run-judge` allow
  only the destinations the worker needs (no ipBlock). Residual risk: a Java or Go submission (no seccomp filter) can open sockets to
  those few destinations, none of which accepts it without a client certificate.
- **No CPU-limit surprise (T5).** The sandbox keeps the plan's limits (cpu 2, memory 2560Mi, requests 1 / 1536Mi) as a starting point; task 6 on
  the server decides whether a CPU limit causes false time-limit verdicts.
- **The mock needs `DAC_OVERRIDE` (T5).** The worker's bundles are mode 0700; the mock reads them as root like the real sandbox, so the
  local overlay patch keeps the base's capabilities (without them it silently falls back to its old fixed answer).
- **KEDA's scale-down is the HPA's window (T7).** `cooldownPeriod: 300` is kept as the plan says, but it only applies to the step down to
  zero; `advanced.horizontalPodAutoscalerConfig.behavior.scaleDown.stabilizationWindowSeconds: 300` is what keeps a pod five minutes
  between pods. The test checks both.
- **An alias for `kafka` in KEDA's namespace (T7).** Found live: KEDA connected to the bootstrap name but the metadata handed back the
  broker's advertised `kafka:29092`, which does not resolve outside `oj`. An ExternalName Service `kafka` in `keda` (platform) fixes it without
  changing the advertised listener, which the data-layer test pins to compose's.
- **The Deployments set no replicas (T7)** so KEDA's HPA owns the count and an apply cannot reset it.
- **Memory is the ceiling (T7).** Scheduling is by requests: with the sandbox at 1536Mi a judge pod reserves 1664Mi; the README gives the
  rule for `maxReplicaCount`. Observed on the 10Gi k3d node: 3 of 4 judge pods fit, the fourth stayed Pending.
- **The four `*ServiceDown` rules keep `for: 15s` (T8).** The plan raised them to `1m`; with `maxUnavailable: 0` a rolling update has no
  downtime, and the one Recreate service (submission-service) really does refuse submissions while it restarts, so the alert is
  truthful. `alerts.yml` is shared with compose and a longer `for:` would break `alerts_fast_test.yml`, whose point is that a rule
  fires on the second scrape. `JudgeWorkerDown` needed no change either: `absent(up{job="judge-worker"} == 1)` already means "no pod is up".
- **T8 scope: node-exporter and cAdvisor are left out (T8).** They need `hostPath` / `hostPID`, which `baseline` forbids in `oj`; the two
  alerts and the dashboard panels that depend on them have no data on K3s until they run in a privileged namespace (README lists it).
  Jaeger came with T4.
- **`JudgePodOOMKilled` uses the restart counter (T8).** `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` stays 1
  for the pod's life, so on its own the alert would never resolve; `increase(restarts_total[10m]) > 0` joined to it fires for ten
  minutes after a kill. It covers the worker and the sandbox. **Corrected after the final review:** the first version asked only `kube_pod_container_*`, but the sandbox is a native
  sidecar (an init container), which kube-state-metrics reports as `kube_pod_init_container_*`; my live proof used a regular container named sandbox and so
  proved the wrong thing. Both families are asked now, with a unit case and a live proof on a pod shaped like the real one.
- **Prometheus and kube-state-metrics are the only pods with a ServiceAccount token (T8)** (namespaced read-only Roles, no
  ClusterRole); the `no pod mounts a token` check in `tests/k3s-judge.test.sh` names them.
- **Grafana has no NetworkPolicy allow rule (T8).** Its UI is for `kubectl port-forward`, which no policy filters; `tests/k3s-services.test.sh`
  names it as the one Service port exempt from "every port has an allow rule".
- **The backup is three init containers, not one script on a host (T9).** `dump` (the Postgres image), `mirror` (the MinIO image, which has
  `mc` but no `find`, so it counts with `mc ls`) and `restic` (the version `backup/backup.sh` pins) each run the one tool they need, in order; the
  scripts are files shellchecked in CI and `backup/lib.sh` is shared with compose (the same `compare_counts`). The pod runs as uid 999 because
  restic keeps the files' modes (0600) and the drill must read what the backup wrote.
- **The restore drill is a suspended CronJob (T9)**, run with `kubectl create job --from`, so the local overlay patches both CronJobs the same
  way and the server gets it without a second manifest. The plan's "k3d from a snapshot" became "a throwaway Postgres in one pod": the same
  check as `backup/restore-drill.sh`, and the job also runs on the server.
- **The restic repository is not in the base (T9).** The plan said "off the host": the base has no volume for it and takes `RESTIC_REPOSITORY`
  from the Secret `restic`; only the local overlay mounts a claim (`restic-repo`), so a mistake cannot put the repository on the cluster's disk
  on the server. The Secrets and the CA key are not in the snapshot (listed in the README with the command to add them).
- **The CI job is manual (T9).** `k3s-live` runs on `workflow_dispatch` only: it pulls the service images from GHCR and needs about 6 GB, so it
  is not run on every push (the offline k3s tests are). It has not been run on GitHub from here, and the plan's `judge-bench.sh` and the
  delete-a-pod-mid-judgement acceptance are not in it: `judge-bench.sh` does not exist, and the real sandbox decides that test (T6).
- **Final review fixes (after T9).** The whole-branch reviewer's Critical and Important findings, each with a test that failed first: the cutover
  runbook now copies all three databases and the bucket twice with one script (`k3s/scripts/copy-from-compose.sh`, rehearsed live from compose into
  k3d, failure path included); `overlays/vps-stage1` makes step 2 of the runbook executable; `overlays/vps` carries the public host (`host.env`
  into the gateway, the certificate and the issuer) and a Let's Encrypt certificate; Traefik keeps the client address
  (`externalTrafficPolicy: Local`); `JudgePodOOMKilled` asks the init-container series too; the backup mirror uses the read-only worker key;
  `restic init` is explicit; `BackupFailed` / `BackupStale` / `BackupNeverCompleted` exist (kube-state-metrics now watches Jobs).
- **Ruling: certificate renewal needs a restart (final review #6).** Not automated: a reloader would be a new platform dependency and an annotation on every
  workload; instead the README says to run `kubectl -n oj rollout restart deploy,sts` about every eleven months, and `TlsCertificateExpiringSoon`
  covers the Java services if it is forgotten. Cost if wrong: an expired leaf on a database, Kafka, Redis or MinIO pod after a year with no restart,
  which breaks every mTLS hop to it at once; revisit with a reloader if the server is left unattended.
- **Ruling: MinIO stays reachable from the judge pod (final review #7).** It serves TLS only, so a submission without a seccomp filter can reach the S3 port
  anonymously; a certificate-verified hop in front of MinIO is out of proportion for the first server, and the README now says so instead of claiming otherwise.
- **Ruling: the client address behind ServiceLB is configured, not verified (final review #5).** `externalTrafficPolicy: Local` is set and Traefik still
  answers on k3d, but k3d's load balancer hides what a real host does; the runbook has a check after the DNS change.
- **Ruling: Let's Encrypt is configured, not exercised (final review #4).** The issuer and certificate render and are tested; whether the HTTP-01 challenge
  crosses Traefik's port-80 redirect is only known on the server.

