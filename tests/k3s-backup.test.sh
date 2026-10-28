#!/usr/bin/env bash
# Backup on K3s (sub-project 15): a nightly CronJob dumps the three databases and mirrors the test-case bucket into a restic
# repository that is NOT on the cluster's disk (the base names none: it comes from the Secret `restic`), and a suspended CronJob
# restores the latest snapshot into a throwaway Postgres and compares row counts, as backup/restore-drill.sh does for compose.
# The scripts are real files (k3s/backup/*.sh, checked by shellcheck in CI); the manifest carries them byte for byte. Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

f=k3s/base/backup/backup.yaml
if [[ -f $f ]] && python3 k3s/scripts/gen_backup.py | diff -q - "$f" > /dev/null; then ok "backup/backup.yaml is what gen_backup.py makes"
else bad "backup/backup.yaml is what gen_backup.py makes"; fi
for s in k3s/backup/*.sh; do
  if bash -n "$s"; then ok "$s parses"; else bad "$s parses"; fi
done

kubectl kustomize k3s/base > "$tmp/base.yaml" 2> "$tmp/err" || { bad "the base renders: $(head -3 "$tmp/err")"; exit 1; }
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/base.yaml" > "$tmp/base.json"
kubectl kustomize k3s/overlays/local > "$tmp/local.yaml" 2> "$tmp/err" || { bad "the local overlay renders: $(head -3 "$tmp/err")"; exit 1; }
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/local.yaml" > "$tmp/local.json"

python3 - "$tmp" <<'PY' || fail=1
import glob, json, os, re, sys
tmp = sys.argv[1]
base, local = json.load(open(f"{tmp}/base.json")), json.load(open(f"{tmp}/local.json"))
failed = False
def ok(m): print("ok   " + m)
def bad(m):
    global failed
    failed = True
    print("FAIL " + m)
def check(cond, m, detail=""): (ok(m) if cond else bad(m + (": " + detail if detail else "")))
def find(objs, kind, name): return next((o for o in objs if o.get("kind") == kind and o["metadata"]["name"] == name), None)
def pod(cj): return cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]

# the scripts in the manifest are the files
cm = (find(base, "ConfigMap", "backup-scripts") or {"data": {}})["data"]
files = {os.path.basename(p): open(p).read() for p in sorted(glob.glob("k3s/backup/*.sh"))}
files["lib.sh"] = open("backup/lib.sh").read()
check(cm == files and files, "backup-scripts holds k3s/backup/*.sh and backup/lib.sh (the row-count helper compose uses), byte for byte", str(sorted(cm)))

# the images are the ones compose and the data layer run
compose = open("docker-compose.yml").read() + open("backup/backup.sh").read()
restic = re.search(r'RESTIC_IMAGE="(restic/restic:[^"]+)"', open("backup/backup.sh").read()).group(1)
minio = find(base, "Job", "minio-init")["spec"]["template"]["spec"]["containers"][0]["image"]
pg = find(base, "StatefulSet", "identity-db")["spec"]["template"]["spec"]["containers"][0]["image"]

b = find(base, "CronJob", "backup")
check(b is not None, "a CronJob backup")
if b:
    s, p = b["spec"], pod(b)
    check(s["concurrencyPolicy"] == "Forbid" and s.get("timeZone") == "Asia/Ho_Chi_Minh" and s["schedule"] == "0 3 * * *",
          "it runs at 03:00 Ho Chi Minh time like backup/systemd/oj-backup.timer, never two at once", f'{s["schedule"]} {s.get("timeZone")} {s["concurrencyPolicy"]}')
    jt = s["jobTemplate"]["spec"]
    check(jt.get("activeDeadlineSeconds") and jt.get("backoffLimit") == 0 and p["restartPolicy"] == "Never", "a run has a deadline and is not retried inside itself (the next night is the retry)")
    check(s["failedJobsHistoryLimit"] >= 3 and s["successfulJobsHistoryLimit"] >= 3, "the last runs are kept for their logs")
    check([c["name"] for c in p["initContainers"]] == ["dump", "mirror"] and [c["name"] for c in p["containers"]] == ["restic"],
          "dump, then mirror, then restic: a snapshot is only taken of a complete staging directory")
    imgs = {c["name"]: c["image"] for c in p["initContainers"] + p["containers"]}
    check(imgs == {"dump": pg, "mirror": minio, "restic": restic}, "dump runs the Postgres image of the databases, mirror the MinIO image of minio-init, restic the version backup.sh pins", str(imgs))
    env = {e["name"]: e for c in p["containers"] for e in c.get("env", [])}
    refs = [r["secretRef"]["name"] for c in p["containers"] for r in c.get("envFrom", [])]
    check("restic" in refs and "RESTIC_REPOSITORY" not in env, "the repository and its password come from the Secret restic; the base names no repository (it must be off this disk)")
    check(not any("hostPath" in v or "persistentVolumeClaim" in v for v in p.get("volumes", [])), "the base mounts no volume for the repository (only the staging directory and certificates)")
    d = next(c for c in p["initContainers"] if c["name"] == "dump")
    prefixes = {r["prefix"]: r["secretRef"]["name"] for r in d.get("envFrom", []) if "prefix" in r}
    check(prefixes == {"IDENTITY_": "env-identity-db", "PROBLEM_": "env-problem", "SUBMISSION_": "env-submission"},
          "dump reads each database's own credentials from the Secret its service uses", str(prefixes))
    m = next(c for c in p["initContainers"] if c["name"] == "mirror")
    check("minio-init" in [r["secretRef"]["name"] for r in m.get("envFrom", [])], "mirror reads MinIO's root account and bucket from the Secret minio-init")
    check(any(v.get("secret", {}).get("secretName") == "tls-backup" for v in p["volumes"]), "dump and mirror present and verify with the identity backup (tls-backup)")
    allc = p["initContainers"] + p["containers"]
    check(all(c["securityContext"].get("allowPrivilegeEscalation") is False and c["securityContext"]["capabilities"]["drop"] == ["ALL"] and "memory" in c["resources"]["limits"] for c in allc)
          and p["securityContext"]["runAsNonRoot"] is True and p["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault" and p["automountServiceAccountToken"] is False,
          "non-root, no capabilities, RuntimeDefault seccomp, memory limits, no ServiceAccount token")

d = find(base, "CronJob", "restore-drill")
check(d is not None, "a CronJob restore-drill")
if d:
    p = pod(d)
    check(d["spec"].get("suspend") is True, "the drill never runs by itself (suspended); `kubectl create job --from=cronjob/restore-drill` runs it")
    check([c["name"] for c in p["initContainers"]] == ["restic-restore"] and [c["name"] for c in p["containers"]] == ["verify"], "restic restores, then verify restores the dumps and counts")
    check(next(c["image"] for c in p["initContainers"]) == restic and p["containers"][0]["image"] == pg, "the same restic and Postgres images")
    check(p["securityContext"]["runAsUser"] == 999, "verify runs as the postgres user (initdb needs a user that exists)")
    check(not any("tls-" in v.get("secret", {}).get("secretName", "") for v in p.get("volumes", [])) and not any(r["secretRef"]["name"].startswith(("env-", "minio")) for c in p["initContainers"] + p["containers"] for r in c.get("envFrom", [])),
          "it holds no certificate and no service credential: it needs the repository and nothing else")
    check(all("memory" in c["resources"]["limits"] and c["securityContext"]["capabilities"]["drop"] == ["ALL"] for c in p["initContainers"] + p["containers"]) and p["automountServiceAccountToken"] is False, "limits, no capabilities, no ServiceAccount token")

# the jobs' pods are labelled for the policies
check(b and pod(b) and b["spec"]["jobTemplate"]["spec"]["template"]["metadata"]["labels"].get("app") == "backup", "the backup pod is labelled app=backup")
check(d and d["spec"]["jobTemplate"]["spec"]["template"]["metadata"]["labels"].get("app") == "restore-drill", "the drill pod is labelled app=restore-drill")

# network: the backup pod reaches the three databases and MinIO, and nothing else is opened to it
pols = [o for o in base if o.get("kind") == "NetworkPolicy"]
def reach(app, port, source):
    return any(x["spec"]["podSelector"].get("matchLabels") == {"app": app} and any(pp.get("port") == port for r in x["spec"].get("ingress", []) for pp in r.get("ports", []))
               and any(f.get("podSelector", {}).get("matchLabels") == {"app": source} for r in x["spec"].get("ingress", []) for f in r["from"]) for x in pols)
check(all(reach(db, 5432, "backup") for db in ("identity-db", "problem-db", "submission-db")) and reach("minio", 9000, "backup"), "the databases and MinIO admit the backup pod")
check(not any(reach(a, pt, "backup") for a, pt in (("kafka", 29092), ("redis", 6379))) and not any(reach(a, pt, "restore-drill") for a, pt in (("identity-db", 5432), ("minio", 9000), ("kafka", 29092))),
      "Kafka and Redis do not admit the backup pod, and nothing admits the drill pod")

# the retention is compose's
sh = files.get("restic.sh", "")
want = re.search(r"restic forget (.*)", open("backup/backup.sh").read()).group(1).strip()
check(want.replace("--host oj ", "").split("--prune")[0].strip() in sh and "--prune" in sh, "retention is backup.sh's: 7 daily, 4 weekly, 6 monthly, pruned", want)
check("RESTIC_REPOSITORY" in sh and "RESTIC_PASSWORD" in sh and "exit 2" in sh, "restic.sh stops with a message when the repository or its password is not set")

# the local overlay keeps the repository on a claim (the drill and CI have no off-host repository) and only there
lb, ld = find(local, "CronJob", "backup"), find(local, "CronJob", "restore-drill")
claims = {o["metadata"]["name"] for o in local if o.get("kind") == "PersistentVolumeClaim"}
check("restic-repo" in claims, "the local overlay declares the claim restic-repo")
for name, cj, ctr in (("backup", lb, "restic"), ("restore-drill", ld, "restic-restore")):
    p = pod(cj) if cj else {"volumes": [], "containers": [], "initContainers": []}
    c = next((c for c in p.get("initContainers", []) + p.get("containers", []) if c["name"] == ctr), {})
    check(any(v.get("persistentVolumeClaim", {}).get("claimName") == "restic-repo" for v in p.get("volumes", [])) and any(m["mountPath"] == "/repo" for m in c.get("volumeMounts", [])),
          f"local {name}: {ctr} mounts the claim restic-repo at /repo")

# cert-manager makes tls-backup
certs = {o["spec"]["secretName"] for o in base if o.get("kind") == "Certificate"}
check("tls-backup" in certs, "an identity backup exists (cert-manager)")
sys.exit(1 if failed else 0)
PY
exit $fail
