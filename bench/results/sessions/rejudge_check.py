#!/usr/bin/env python3
"""SP11 Task 25 Step 7 on the bench stack: break a bench-ab test case, rejudge, check WA, restore, rejudge, check AC."""
import os, sys, time, subprocess, requests
API = "https://localhost/api/v1"; CA = "/home/tuan/Project/my-oj/judge-deployment/pki/out/ca/ca.crt"
DEPLOY = "/home/tuan/Project/my-oj/judge-deployment"

def admin():
    s = requests.Session(); s.verify = CA
    r = s.post(f"{API}/auth/login", json={"username": "admin", "password": os.environ["OJ_ADMIN_PASSWORD"]}, timeout=15)
    r.raise_for_status(); tok = s.cookies.get("accessToken")
    if tok: s.headers["Authorization"] = f"Bearer {tok}"
    return s

def sql(db, q):
    return subprocess.run(["docker", "--context", "default", "exec", db, "sh", "-c", f'psql -U "$POSTGRES_USER" "$POSTGRES_DB" -tAc "{q}"'],
                          capture_output=True, text=True, check=True).stdout.strip()

def drain(label):
    t0 = time.time()
    while time.time() - t0 < 600:
        n = int(sql("oj-submission-db", "select count(*) from t_submissions where status in (6,7)"))
        if n == 0: print(f"{label}: queue drained in {time.time()-t0:.0f}s"); return
        time.sleep(3)
    sys.exit(f"{label}: queue not drained")

def stats_check(label):
    r = subprocess.run(["bash", "scripts/stats-check.sh"], cwd=DEPLOY, capture_output=True, text=True,
                       env={**os.environ, "SUBMISSION_DB_CONTAINER": "oj-submission-db", "PROBLEM_DB_CONTAINER": "oj-problem-db"})
    print(f"{label}: stats-check rc={r.returncode} {r.stdout.strip()[-300:]}")
    return r.returncode == 0

def verdicts():
    return sql("oj-submission-db", "select s.status, count(*) from t_submissions s join (select id from t_submissions) x using (id) "
               "where s.problem_id = (select problem_id from t_submissions where id in (select id from t_submissions) limit 1) group by 1")

s = admin()
tcs = s.get(f"{API}/problems/bench-ab/test-cases", timeout=15).json()["data"]
tc = tcs[0] if isinstance(tcs, list) else tcs["content"][0]
tid = tc["id"]
full = s.get(f"{API}/problems/bench-ab/test-cases/{tid}", timeout=15).json()["data"]
inp, out = full.get("input") or full.get("inputContent"), full.get("output") or full.get("outputContent")
print("test case", tid, "keys", sorted(full.keys())[:12])
def put(o):
    r = s.put(f"{API}/problems/bench-ab/test-cases/{tid}", files={"input": ("1.in", inp.encode()), "output": ("1.out", o.encode())}, timeout=60)
    print("PUT", r.status_code, r.text[:160]); r.raise_for_status()
ok = True
drain("before")
ok &= stats_check("baseline")
put("999999999\n")
r = s.post(f"{API}/problems/bench-ab/rejudge", timeout=60); print("rejudge(break)", r.status_code, r.text[:200]); r.raise_for_status()
q1 = r.json()["data"]["queued"]; ok &= q1 > 0
time.sleep(6); drain("after break")
pid = sql("oj-problem-db", "select id from t_problems where problem_slug='bench-ab'")
print("bench-ab verdicts after break:", sql("oj-submission-db", f"select status, count(*) from t_submissions where problem_id='{pid}' group by 1 order by 1"))
ok &= stats_check("after break")
put(out)
time.sleep(6)
r = s.post(f"{API}/problems/bench-ab/rejudge", timeout=60); print("rejudge(restore)", r.status_code, r.text[:200]); r.raise_for_status()
time.sleep(6); drain("after restore")
print("bench-ab verdicts after restore:", sql("oj-submission-db", f"select status, count(*) from t_submissions where problem_id='{pid}' group by 1 order by 1"))
ok &= stats_check("after restore")
print("STEP7", "PASS" if ok else "FAIL")
