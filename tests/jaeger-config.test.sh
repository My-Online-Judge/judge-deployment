#!/usr/bin/env bash
# jaeger/config.yaml (sub-project 10, task 13): both OTLP receivers serve TLS and require a client certificate from our CA
# (client_ca_file), OTLP is the only way in, the query API stays plain HTTP, and the in-memory store keeps at most 100k
# traces. Jaeger then validates the file itself. Prints descriptions only.
set -euo pipefail
cd "$(dirname "$0")/.."
config=jaeger/config.yaml
[[ -f $config ]] || { echo "FAIL $config exists"; exit 1; }
fail=0
# Pull first: on a cold host, docker run's "Unable to find image … Pulling" lines would land in the first check's output.
docker --context default pull -q mikefarah/yq:4.44.3 > /dev/null
check() { # check <description> <yq expression that must print true>
  local got
  got=$(docker --context default run --rm -i --network none mikefarah/yq:4.44.3 "$2" < "$config" 2>&1) || true
  if [[ $got == true ]]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# yq 4.44 compares only scalars with ==, so lists are joined; and it binds `|` tighter than `,` and `and`, so each check
# is a list of comparisons (true when all are) with every pipe inside parentheses.
tls='.cert_file == "/etc/oj/tls/tls.crt", .key_file == "/etc/oj/tls/tls.key", .client_ca_file == "/etc/oj/tls/ca.crt"'
for proto in grpc:4317 http:4318; do
  check "OTLP ${proto%:*} listens on 0.0.0.0:${proto#*:} with Jaeger's certificate and requires a client certificate from the CA" \
    ".receivers.otlp.protocols.${proto%:*} | [.endpoint == \"0.0.0.0:${proto#*:}\", (.tls | ($tls))] | all"
done
check "OTLP is the only receiver (no plaintext jaeger or zipkin ingest)" \
  '[(.receivers | keys | join(",")) == "otlp", (.service.pipelines | keys | join(",")) == "traces", (.service.pipelines.traces.receivers | join(",")) == "otlp"] | all'
check "the query API (16686) stays plain HTTP" \
  '[.extensions.jaeger_query.http.tls == null, .extensions.jaeger_query.grpc.tls == null] | all'
check "spans are stored in memory, at most 100000 traces, where the query API reads them" \
  '.extensions.jaeger_query.storage.traces as $s | [.exporters.jaeger_storage_exporter.trace_storage == $s, .extensions.jaeger_storage.backends[$s].memory.max_traces == 100000] | all'

# Jaeger's own check of the file (components, keys, values). It does not open the certificate files.
if out=$(docker --context default run --rm --network none -v "$PWD/$config:/etc/jaeger/config.yaml:ro" \
    jaegertracing/jaeger:2.21.0 validate --config file:/etc/jaeger/config.yaml 2>&1); then
  echo "ok   jaeger 2.21.0 validate accepts $config"
else
  echo "FAIL jaeger 2.21.0 validate accepts $config: $(grep -v 'application version' <<< "$out" | head -c 400 | tr '\n' ' ')"
  fail=1
fi
exit $fail
