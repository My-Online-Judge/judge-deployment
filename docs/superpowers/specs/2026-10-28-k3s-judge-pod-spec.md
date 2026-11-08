# Spec: Worker/Sandbox hardening và chuyển sang K3s (Judge Pod sidecar)

Ngày: 2026-10-28. Nguồn: tài liệu "ĐẶC TẢ SỰ CỐ & YÊU CẦU NÂNG CẤP" của chủ dự án (phần 1) + bản đánh giá toàn hệ
thống cùng ngày (phần 2) + các quyết định đã chốt (phần 3). Hai plan thực hiện:
`../plans/2026-10-28-phase1-fixes.md` (trên compose, trước) và `../plans/2026-10-28-k3s-migration.md` (sau).

## 1. Yêu cầu gốc (tóm tắt, giữ nguyên giá trị)

- **Judge Pod**: 1 Pod = `sandbox` (qduoj/judge-server) + `worker` (judge-worker), worker gọi sandbox qua
  `localhost:8080`; `terminationGracePeriodSeconds: 120`; `POD_NAME` qua Downward API.
- **Worker**: `enable_auto_commit=False`, `max_poll_records=1`, `max_poll_interval_ms=600000`; bắt SIGTERM/SIGINT,
  hoàn thành bài đang chấm → publish → commit → thoát; log và verdict mang `judged_by` = `POD_NAME`.
- **KEDA**: trigger Kafka lag, `lagThreshold: "5"`, `minReplicaCount: 1`, `maxReplicaCount: 4`,
  `cooldownPeriod: 300`.
- **Tài nguyên**: PVC `local-path` cho postgres/kafka/minio; JVM `-XX:MaxRAMPercentage=50.0 -XX:+UseSerialGC`;
  Kafka `KAFKA_HEAP_OPTS="-Xmx512M -Xms512M"`.
- **Nghiệm thu**: mỗi sandbox nhận đúng 1 request/lúc; `kubectl delete pod` giữa bài C++ 10 s vẫn ra verdict và
  commit; không rebalance khi bài chạy lâu; stress 100 bài không OOM, không vượt `maxReplicaCount`; `judged_by`
  khớp tên Pod.

## 2. Đối chiếu với code hiện tại (những chỗ spec gốc đã cũ)

| # | Spec gốc | Thực tế (2026-10-28) | Quyết định |
|---|---|---|---|
| 1 | `privileged: true`, image `:latest` | Non-privileged từ 2026-10-05: `cap_drop ALL` + CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID, KILL; `no-new-privileges`; read-only root; tmpfs; digest `sha256:a580a164…` (`docker-compose.yml:66-102`) | Giữ hardening, map sang `securityContext`. Không `:latest`. |
| 2 | Tắt auto-commit, `max_poll_records=1` | Đã có (`judge-worker/main.py:26,31`) | Chỉ còn tăng `MAX_POLL_INTERVAL_MS` và đưa MinIO sync vào budget. |
| 3 | KEDA đo group `judge-api-results` | Đó là group của submission-service. Worker: `judge-workers`; run-worker: `run-workers` (`config.py:38`, compose `run-worker`) | KEDA trỏ `judge-workers` / `run-workers`. |
| 4 | `http://localhost:8080` | Sandbox chỉ trả lời mTLS (gunicorn yêu cầu client cert) | `https://localhost:8080`, cert như hiện tại, NetworkPolicy chặn pod khác. |
| 5 | Sandbox `cpu: 1.0`, `memory: 1Gi` | Compile C++ cần 1 GiB (`V3`); tmpfs tính vào memory cgroup; qduoj chạy case song song | Khởi điểm `limits: cpu 2, memory 2.5Gi`, tmpfs `/judger` 512Mi; **bench a+b trước khi chốt**. **Cập nhật 2026-11-08 (sandbox Go, `specs/2026-11-08-go-judge-server-design.md` §6):** server giới hạn số case chạy cùng lúc nên `limits: cpu 2, memory 1.5Gi` (`requests: cpu 1, memory 768Mi`), tmpfs `/work` 512Mi (exec) + `/tmp` 64Mi, không còn `/judger`, `/log`, `/dev/shm`; probe là `judge-server healthcheck`. |
| 6 | `JAVA_OPTS` | `ENTRYPOINT ["java","-jar"]` không đọc `JAVA_OPTS`; OTel agent đi qua `JAVA_TOOL_OPTIONS` | Dùng `JAVA_TOOL_OPTIONS`, nối với chuỗi OTel. |
| 7 | Kafka 3.9.0; (`kafka_2_nats.md` muốn NATS) | Compose 3.8.1 | **Giữ Kafka**, cap heap 512M + `mem_limit`/limits 1Gi. NATS không nằm trong scope. |
| 8 | Gateway public :8000 | Caddy edge 443, private CA, mTLS mọi hop, Kafka ACL theo CN | K3s: Traefik + cert-manager; nội bộ: cert-manager CA issuer thay `pki.sh`. |
| 9 | Registry sandbox theo hostname cố định | `t_judge_servers` keyed `judge-server`/`judge-server-2` | Key = `POD_NAME`; dọn row Offline > 24 h. **Cập nhật 2026-11-08 (sandbox Go):** `healthcheck` kiểm cert theo hostname nên pod đặt `hostname: judge-server`; các judge pod dùng chung một row `judge-server` trong registry (không còn key theo pod) cho tới khi `healthcheck` đọc tên server từ `HEALTHCHECK_SERVER_NAME`; `judged_by` vẫn là `POD_NAME`. |

## 3. Quyết định đã chốt

- A. Broker: **Kafka**, giới hạn memory.
- B. Sandbox: **hardened non-privileged** (như compose).
- C. Java/Go seccomp: thử profile `general` của qduoj; nếu JVM/Go không chạy được → **disable** ngôn ngữ đó
  (`is_disabled = true`), ghi vào README.
- D. Run lane nhiều replica: **consumer group per instance** (`run-results-<instance>`), không Redis registry.
- E. Thứ tự: **Phase 1 trên compose trước**, rồi K3s.
- F. Manifests: `judge-deployment/k3s/` (Kustomize base + overlays `local`, `vps`).
- G. Không Jira, không ticket, không ghi gì ngoài workspace `~/Personal/my-oj`.

## 4. Phạm vi Phase 1 (blocker cho K3s) — chi tiết trong plan

1. judge-worker: poison pill, SIGTERM, `judgedBy`, poll budget bao MinIO sync, `is_expired` type-check,
   `resolve_verdict` đối chiếu số case.
2. oj-submission-service: `judged_by` cột + event `ignoreUnknown`; PENDING timeout đo theo queue; outbox
   row chết không chặn hàng; run lane group-per-instance.
3. identity/problem/submission: `spring-boot-starter-validation` + test 400.
4. Java/Go seccomp (quyết định C).
5. Caddy security headers + body limit; portal DOMPurify allow-list.
6. Compose: Kafka heap 512M + `mem_limit` 1g (chuẩn bị cho K3s limits cùng giá trị).

## 5. Ngoài phạm vi (ghi nhận, không làm trong hai plan này)

Phase 2 của bản đánh giá: xóa `/auth/introspect`, `iss`/`aud`/`typ`, ép đổi root admin password, privilege
containment, problem-service deny-by-default, MinIO write sau commit, V7 in-place, cache `GetSampleTestCases`, SSE
heartbeat, index `created_at`, backup off-host, CA key mã hóa. NATS migration.

## 6. Cập nhật 2026-11-08: sandbox Go thay qduoj

Thay `qduoj/judge-server` bằng sandbox Go (`../judge-server`, gRPC `oj.judge.v1`; thiết kế ở `2026-11-08-go-judge-server-design.md`).
Ảnh hưởng tới Judge Pod, mỗi mục khớp `k3s/base/judge/judge.yaml` (sinh bởi `k3s/scripts/gen_services.py`):

- Image `docker.io/thanhtuanle/judge-server:main` (không còn digest qduoj; `overlays/vps` pin tag cùng các image khác). Worker gọi
  `localhost:8080` (gRPC, mTLS từ `OJ_TLS_DIR`; không còn tiền tố `https://`), sandbox chỉ nhận CN `judge-worker`/`run-worker`.
- Tài nguyên: xem hàng 5. Không còn `GUNICORN_CMD_ARGS`, `SERVICE_URL`, `/log`, `/dev/shm`.
- `terminationGracePeriodSeconds: 360` (trước 120): deadline mỗi lần chấm tăng theo số case và bị chặn ở 300 s, cộng publish;
  `MAX_POLL_INTERVAL_MS` của worker 900000 (trước 600000). Compose: `stop_grace_period: 6m` cho hai worker, `130s` cho sandbox.
- Hàng 9: `judge-server healthcheck` kiểm chứng chỉ server theo hostname của pod, chứng chỉ `tls-judge-server` cấp cho `judge-server`,
  nên pod đặt `hostname: judge-server`. Hệ quả: mọi judge pod báo cùng hostname `judge-server`, registry chỉ còn một row chung (trước: key
  theo tên pod); `judged_by` vẫn là `POD_NAME`. Muốn trả lại một row mỗi pod: `healthcheck` đọc tên server từ `HEALTHCHECK_SERVER_NAME` (chưa có; việc của repo judge-server), rồi bỏ `hostname:` khỏi pod.
- `/work`: emptyDir của pod là 0777 (fsGroup thêm setgid) nên init container `sandbox-work-perms` chạy `chmod 0755 /work` trước sandbox (compose: tmpfs `mode=755`); `tests/k3s-judge.test.sh` kiểm tra bước này.
- Mở: image `docker.io/thanhtuanle/judge-server` chưa tồn tại (repo judge-server chưa có CI); đến lúc đó phải build và push/import tay (`k3s/README.md`).
- Mở: compose chạy sandbox với `init: true` để dọn tiến trình con của lần chạy bị kill; pod không có tương đương (xem `k3s/README.md`).
