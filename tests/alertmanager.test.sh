#!/usr/bin/env bash
# Alertmanager (sp12 task 17): render.sh builds /tmp/alertmanager.yml from the environment, and amtool accepts it with
# and without the Telegram variables. The final `exec alertmanager` line is cut off so the container ends after rendering.
# Prints key names only, never the (fake) token's value.
set -euo pipefail
cd "$(dirname "$0")/.."
img=prom/alertmanager:v0.34.1
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# run_render <name> [VAR=value ...]: renders in a throwaway container, then prints the stdout of render.sh, a marker, the
# config, and amtool's verdict. Everything the container prints is kept in $out.
run_render() {
  local name=$1; shift
  local envs=() e
  for e in "$@"; do envs+=(-e "$e"); done
  docker run --rm --network none --name "sp12t17-$name-$$" --entrypoint sh "${envs[@]}" \
    -v "$PWD/alertmanager:/etc/alertmanager:ro" "$img" -c '
      sed "/^exec /d" /etc/alertmanager/render.sh > /tmp/render-test.sh
      sh /tmp/render-test.sh; rc=$?
      echo "--- rc=$rc"
      [ -f /tmp/alertmanager.yml ] && cat /tmp/alertmanager.yml
      echo "--- amtool"
      amtool check-config /tmp/alertmanager.yml 2>&1
      echo "--- mode"
      ls -l /tmp/telegram_bot_token 2>&1 || true' 2>&1 || true
}

out=$(run_render plain)
if grep -q '^alertmanager receiver: ui-only$' <<< "$out" && grep -q 'SUCCESS' <<< "$out" && ! grep -q 'telegram' <<< "$(sed -n '/^--- rc/,/^--- amtool/p' <<< "$out")" \
   && grep -q 'receiver: ui-only' <<< "$out"; then ok "no Telegram variables: receiver ui-only, no telegram receiver, amtool SUCCESS"; else bad "no Telegram variables: receiver ui-only, no telegram receiver, amtool SUCCESS"; fi
if grep -q "group_by: \[alertname\]" <<< "$out" && grep -q 'group_wait: 30s' <<< "$out" && grep -q 'repeat_interval: 4h' <<< "$out" && grep -q "/etc/alertmanager/\*.tmpl" <<< "$out"; then ok "route groups by alertname, waits 30s, repeats after 4h, loads /etc/alertmanager/*.tmpl"; else bad "route groups by alertname, waits 30s, repeats after 4h, loads /etc/alertmanager/*.tmpl"; fi

token=fake:TOKEN-sp12t17-0123456789
out=$(run_render tg "ALERT_TELEGRAM_BOT_TOKEN=$token" ALERT_TELEGRAM_CHAT_ID=-100123)
cfg=${out#*--- rc}
if grep -q '^alertmanager receiver: telegram$' <<< "$out" && grep -q 'SUCCESS' <<< "$out" && grep -q 'receiver: telegram' <<< "$cfg" \
   && grep -q 'bot_token_file: /tmp/telegram_bot_token' <<< "$cfg" && grep -q 'send_resolved: true' <<< "$cfg" \
   && grep -q 'chat_id: -100123' <<< "$cfg" && grep -q "message: '{{ template \"oj.telegram\" . }}'" <<< "$cfg" \
   && grep -q 'name: ui-only' <<< "$cfg"; then ok "both variables set: telegram receiver with bot_token_file, chat_id -100123, send_resolved; amtool SUCCESS"; else bad "both variables set: telegram receiver with bot_token_file, chat_id -100123, send_resolved; amtool SUCCESS"; fi
if ! grep -qF "$token" <<< "$out"; then ok "neither the stdout nor the rendered config contains the token"; else bad "neither the stdout nor the rendered config contains the token"; fi
if grep -q -- '-rw------- .*/tmp/telegram_bot_token' <<< "$out"; then ok "the token file is mode 0600"; else bad "the token file is mode 0600"; fi

out=$(run_render half "ALERT_TELEGRAM_BOT_TOKEN=$token")
if grep -q '^alertmanager receiver: ui-only$' <<< "$out" && ! grep -q 'bot_token_file' <<< "$out"; then ok "only one of the two variables: ui-only"; else bad "only one of the two variables: ui-only"; fi

out=$(run_render badid "ALERT_TELEGRAM_BOT_TOKEN=$token" ALERT_TELEGRAM_CHAT_ID=abc)
if grep -q 'ALERT_TELEGRAM_CHAT_ID must be an integer' <<< "$out" && grep -q -- '--- rc=1' <<< "$out" && ! grep -qF "$token" <<< "$out"; then ok "a non-integer chat id is refused with exit 1"; else bad "a non-integer chat id is refused with exit 1"; fi

for k in .Labels.alertname .Labels.severity .Annotations.summary .Status; do
  if grep -qF "$k" alertmanager/telegram.tmpl; then ok "telegram.tmpl uses $k"; else bad "telegram.tmpl uses $k"; fi
done
grep -q 'define "oj.telegram"' alertmanager/telegram.tmpl && ok "telegram.tmpl defines oj.telegram" || bad "telegram.tmpl defines oj.telegram"

# Compose.
if [[ -n ${OJ_ENV_DIR:-} ]]; then deploy_dir=$OJ_ENV_DIR
elif [[ -f .env ]]; then deploy_dir=$PWD
else deploy_dir=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)"); fi
config=$(ALERT_TELEGRAM_BOT_TOKEN='' ALERT_TELEGRAM_CHAT_ID='' docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json)
raw=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --no-interpolate --format json)
py() { python3 -c "import json,sys; c=json.load(sys.stdin); s=c['services']; a=s.get('alertmanager', {}); sys.exit(0 if ($2) else 1)" <<< "$1"; }
chk() { if py "$config" "$2"; then ok "$1"; else bad "$1"; fi; }
chk "alertmanager: pinned image, container oj-alertmanager, 127.0.0.1:9093 only, oj-net only" \
  "a.get('image') == 'prom/alertmanager:v0.34.1' and a.get('container_name') == 'oj-alertmanager' and [(p.get('host_ip'), p.get('published'), p.get('target')) for p in a.get('ports', [])] == [('127.0.0.1', '9093', 9093)] and list(a.get('networks', {})) == ['oj-net']"
chk "alertmanager: mem_limit 64 MiB, restarts unless stopped, rotated logs" \
  "a.get('mem_limit') in (67108864, '67108864') and a.get('restart') == 'unless-stopped' and a.get('logging') == s['prometheus'].get('logging')"
chk "alertmanager: render.sh entrypoint; config dir read-only; data on alertmanagerdata" \
  "a.get('entrypoint') == ['/bin/sh', '/etc/alertmanager/render.sh'] and any(m.get('target') == '/etc/alertmanager' and m.get('read_only') for m in a.get('volumes', [])) and any(m.get('source') == 'alertmanagerdata' and m.get('target') == '/alertmanager' for m in a.get('volumes', [])) and 'alertmanagerdata' in c.get('volumes', {})"
if py "$raw" "a.get('environment', {}).get('ALERT_TELEGRAM_BOT_TOKEN') == '\${ALERT_TELEGRAM_BOT_TOKEN:-}' and a['environment'].get('ALERT_TELEGRAM_CHAT_ID') == '\${ALERT_TELEGRAM_CHAT_ID:-}'"; then ok "alertmanager: both Telegram variables pass through from .env, empty by default"; else bad "alertmanager: both Telegram variables pass through from .env, empty by default"; fi
python3 - <<'PY' && ok "prometheus.yml sends alerts to alertmanager:9093" || bad "prometheus.yml sends alerts to alertmanager:9093"
import yaml, sys
p = yaml.safe_load(open("prometheus.yml"))
sys.exit(0 if p.get("alerting", {}).get("alertmanagers", [{}])[0].get("static_configs", [{}])[0].get("targets") == ["alertmanager:9093"] else 1)
PY
grep -q '^# ALERT_TELEGRAM_BOT_TOKEN=' .env.example && grep -q '^# ALERT_TELEGRAM_CHAT_ID=' .env.example && ok ".env.example documents both variables, commented" || bad ".env.example documents both variables, commented"
grep -q 'alertmanager: {profiles: \["off"\]}' bench/compose.bench.yml && ok "the bench overlay switches alertmanager off" || bad "the bench overlay switches alertmanager off"
exit $fail
