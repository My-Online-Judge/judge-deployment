#!/usr/bin/env bash
# Pins the seven images of ours that overlays/vps runs (docker.io/thanhtuanle/<name>) to one tag: a commit sha CI pushed, or `main`.
#   k3s/scripts/pin-images.sh <tag>     then: kubectl apply -k k3s/overlays/vps (or vps-stage1)
# Every repo's CI pushes :<commit sha> and :main, but the repos are separate: pin the sha of the commit you tested for each by hand if
# they differ (edit overlays/vps/kustomization.yaml), this script sets one tag for all, like compose's OJ_TAG.
# A tag is `main` or 7 to 40 hex digits; anything else is refused, so a typo never reaches the server.
# OJ_VPS_KUSTOMIZATION: the file to edit (default overlays/vps/kustomization.yaml; the test uses a copy).
set -euo pipefail
tag=${1:-}
[[ $tag == main || $tag =~ ^[0-9a-f]{7,40}$ ]] || { echo "pin-images.sh: '$tag' is not main or a 7 to 40 digit commit sha" >&2; exit 2; }
file=${OJ_VPS_KUSTOMIZATION:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlays/vps" && pwd)/kustomization.yaml}
python3 - "$file" "$tag" <<'PY'
import re, sys
path, tag = sys.argv[1:3]
text = open(path).read()
text, n = re.subn(r"(name: docker\.io/thanhtuanle/[\w.-]+\n\s+newTag: )\S+", lambda m: m.group(1) + tag, text)
if n != 7:
    sys.exit(f"pin-images.sh: expected 7 images in {path}, found {n}")
open(path, "w").write(text)
print(f"pinned {n} images to {tag} in {path}")
PY
