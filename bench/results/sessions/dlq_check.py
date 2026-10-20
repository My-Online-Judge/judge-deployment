#!/usr/bin/env python3
"""SP11 Task 25 Step 8 on the bench stack: a verdict dead-lettered while submission-db is down, then replayed."""
import os, sys, time, subprocess, requests, json
API = "https://localhost/api/v1"; CA = "/home/tuan/Project/my-oj/judge-deployment/pki/out/ca/ca.crt"
DEPLOY = "/home/tuan/Project/my-oj/judge-deployment"; PROM = "http://127.0.0.1:9090"
def dk(*a, check=True): return subprocess.run(["docker", "--context", "default", *a], capture_output=True, text=True, check=check).stdout.strip()
def log(m): print(time.strftime("%H:%M:%S"), m, flush=True)
def prom(q):
    r = requests.get(f"{PROM}/api/v1/query", params={"query": q}, timeout=10).json()["data"]["result"]
    return r[0]["value"][1] if r else "absent"
s = requests.Session(); s.verify = CA
r = s.post(f"{API}/auth/login", json={"username": "admin", "password": os.environ["OJ_ADMIN_PASSWORD"]}, timeout=15); r.raise_for_status()
s.headers["Authorization"] = f"Bearer {s.cookies.get('accessToken')}"
workers = dk("ps", "-q", "--filter", "label=com.docker.compose.project=oj-bench", "--filter", "label=com.docker.compose.service=judge-worker").split()
for w in workers: dk("pause", w)
log(f"paused {len(workers)} workers")
r = s.post(f"{API}/submissions", json={"sourceCode": "a, b = map(int, input().split())\nprint(a + b)\n", "languageIdentifier": "python3", "problemSlug": "bench-ab"}, timeout=30)
r.raise_for_status(); sid = r.json()["data"]["id"]; log(f"submitted {sid}")
time.sleep(3)   # the outbox relay sends submission.requested
dk("stop", "oj-submission-db"); log("submission-db stopped")
for w in workers: dk("unpause", w)
log("workers resumed; waiting 6.5 min for the verdict consumer's 5-min budget")
time.sleep(390)
dlq = dk("exec", "oj-kafka", "bash", "-c", "/opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell --bootstrap-server 127.0.0.1:9092 --topic submission.judged.dlq 2>/dev/null | awk -F: '{s+=$3} END {print s+0}'", check=False)
log(f"records on submission.judged.dlq: {dlq}")
log(f"oj_verdict_dead_lettered_total: {prom('sum(oj_verdict_dead_lettered_total)')}")
alerts = requests.get(f"{PROM}/api/v1/alerts", timeout=10).json()["data"]["alerts"]
log("VerdictDeadLettered: " + ",".join(a["state"] for a in alerts if a["labels"]["alertname"] == "VerdictDeadLettered") or "absent")
dk("start", "oj-submission-db"); log("submission-db started")
for _ in range(60):
    try:
        st = s.get(f"{API}/submissions/{sid}", timeout=10)
        if st.status_code == 200: break
    except Exception: pass
    time.sleep(5)
status = st.json()["data"]["status"]; log(f"status after the DB returned: {status} (6 PENDING expected)")
out = subprocess.run(["bash", "scripts/replay-dlq.sh", "submission.judged.dlq", "submission.judged"], cwd=DEPLOY, capture_output=True, text=True)
log(f"replay rc={out.returncode}: {out.stdout.strip()} {out.stderr.strip()[-200:]}")
for _ in range(30):
    status = s.get(f"{API}/submissions/{sid}", timeout=10).json()["data"]["status"]
    if status not in (6, 7): break
    time.sleep(2)
log(f"final status: {status} (0 = ACCEPTED)")
print("STEP8", "PASS" if status == 0 else "FAIL")
