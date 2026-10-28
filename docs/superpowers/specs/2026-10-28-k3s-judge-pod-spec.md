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
| 5 | Sandbox `cpu: 1.0`, `memory: 1Gi` | Compile C++ cần 1 GiB (`V3`); tmpfs tính vào memory cgroup; qduoj chạy case song song | Khởi điểm `limits: cpu 2, memory 2.5Gi`, tmpfs `/judger` 512Mi; **bench a+b trước khi chốt**. |
| 6 | `JAVA_OPTS` | `ENTRYPOINT ["java","-jar"]` không đọc `JAVA_OPTS`; OTel agent đi qua `JAVA_TOOL_OPTIONS` | Dùng `JAVA_TOOL_OPTIONS`, nối với chuỗi OTel. |
| 7 | Kafka 3.9.0; (`kafka_2_nats.md` muốn NATS) | Compose 3.8.1 | **Giữ Kafka**, cap heap 512M + `mem_limit`/limits 1Gi. NATS không nằm trong scope. |
| 8 | Gateway public :8000 | Caddy edge 443, private CA, mTLS mọi hop, Kafka ACL theo CN | K3s: Traefik + cert-manager; nội bộ: cert-manager CA issuer thay `pki.sh`. |
| 9 | Registry sandbox theo hostname cố định | `t_judge_servers` keyed `judge-server`/`judge-server-2` | Key = `POD_NAME`; dọn row Offline > 24 h. |

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
