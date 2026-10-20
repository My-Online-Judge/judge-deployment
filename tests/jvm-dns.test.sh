#!/usr/bin/env bash
# The JVM services' DNS cache, measured in their runtime image with compose's JAVA_TOOL_OPTIONS and configs (sub-project
# 6 §3.2 A): a resolved address kept 1 s, a failed lookup not at all. It checks the effect, not a flag: the image's
# java.security sets networkaddress.cache.negative.ttl=10, which a -Dsun.net.inetaddr.* system property cannot
# override (final review C1). The resolved config holds .env values, so it stays in a private temp dir; prints none.
# grpc-java's DnsNameResolver reads networkaddress.cache.ttl as a SYSTEM property (default 30 s), which the Security
# properties above do not set (sub-project 7 §2): grpc= is that property.
set -euo pipefail
cd "$(dirname "$0")/.."
deploy_dir=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
tmp=$(mktemp -d); chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json > "$tmp/config.json"
cat > "$tmp/DnsPolicy.java" <<'EOF'
public class DnsPolicy {
    public static void main(String[] args) throws Exception {
        Class<?> policy = Class.forName("sun.net.InetAddressCachePolicy");
        System.out.println("positive=" + policy.getMethod("get").invoke(null)
                + " negative=" + policy.getMethod("getNegative").invoke(null)
                + " grpc=" + System.getProperty("networkaddress.cache.ttl"));
    }
}
EOF
javac -d "$tmp" "$tmp/DnsPolicy.java"
fail=0
for svc in api-gateway identity-service problem-service submission-service; do
  # The service's JAVA_TOOL_OPTIONS without the tracing agent, and every config it mounts, at the same paths.
  args=$(python3 - "$tmp" "$svc" <<'PY'
import json, shlex, sys
tmp, svc = sys.argv[1], sys.argv[2]
c = json.load(open(f"{tmp}/config.json"))
s = c["services"][svc]
opts = " ".join(o for o in s["environment"]["JAVA_TOOL_OPTIONS"].split() if not o.startswith("-javaagent:"))
out = ["-e", f"JAVA_TOOL_OPTIONS={opts}"]
for i, ref in enumerate(s.get("configs") or []):
    path = f"{tmp}/config-{svc}-{i}"
    with open(path, "w") as f:
        f.write(c["configs"][ref["source"]]["content"])
    out += ["-v", f"{path}:{ref['target']}:ro"]
print(shlex.join(out))
PY
)
  image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"][sys.argv[2]]["image"])' "$tmp/config.json" "$svc")
  got=$(eval docker run --rm --network none --user "$(id -u):$(id -g)" "$args" -v "$tmp:/probe:ro" --entrypoint java \
    "$image" --add-exports java.base/sun.net=ALL-UNNAMED -cp /probe DnsPolicy 2>/dev/null | tail -1)
  if [ "$got" = "positive=1 negative=0 grpc=1" ]; then echo "ok   $svc keeps a resolved address 1 s, never caches a failed lookup, and grpc-java's resolver keeps an answer 1 s"
  else echo "FAIL $svc: $got (want positive=1 negative=0 grpc=1)"; fail=1; fi
done
exit $fail
