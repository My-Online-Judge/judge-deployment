# The stack on K3s

Kustomize: `base/` is what runs, `overlays/local` is k3d on a laptop (mock sandbox, images built by
`scripts/local-stack.sh build`), `overlays/vps` is the server. The migration plan is
`docs/superpowers/plans/2026-10-28-k3s-migration.md`; the spec it argues from is
`docs/superpowers/specs/2026-10-28-k3s-judge-pod-spec.md`.

```bash
scripts/k3d-up.sh up            # a K3s cluster `oj` in Docker; https://localhost:18443 and http://localhost:18080 are Traefik
scripts/local-stack.sh build    # the images (arm64 Macs: see the README's "Run it on one machine")
scripts/k3d-up.sh import        # load them into the cluster
kubectl apply -k k3s/overlays/local
bash tests/k3s-render.test.sh   # every overlay renders and validates (OJ_DOCKER_CONTEXT=desktop-linux on a Mac)
scripts/k3d-up.sh down
```

The compose stack keeps 80, 443 and 9000, so both can run at once; `K3D_HTTPS_PORT` and `K3D_HTTP_PORT` change the
cluster's host ports (the script stops, naming the holder, when one is taken).

## What cannot be done on a laptop

The real qduoj sandbox is amd64 and needs the Linux host's kernel, so locally the Judge Pod runs the mock. Left for the
server (the checklist grows as the plan's tasks land):

- Task 6, sizing the sandbox's memory and CPU with real judgements (a+b, a heavy compile, a time-limit overrun, an
  out-of-memory kill, `kubectl delete pod` in the middle of a 10 s C++ judgement).
- Task 10, the cutover from compose.
