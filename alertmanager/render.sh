#!/bin/sh
# Alertmanager's entrypoint (sp12 task 17): renders /tmp/alertmanager.yml from the environment, then becomes Alertmanager.
# Every alert is grouped by alertname (30s wait, repeated every 4h) and shown in the UI (http://127.0.0.1:9093). It also
# goes to Telegram when ALERT_TELEGRAM_BOT_TOKEN and ALERT_TELEGRAM_CHAT_ID are both set. The token is written to a
# 0600 file inside the container, never into the config or the output, and never into `docker compose config`.
set -eu
umask 077

r=ui-only
receivers="  - name: ui-only"
if [ -n "${ALERT_TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${ALERT_TELEGRAM_CHAT_ID:-}" ]; then
  case "$ALERT_TELEGRAM_CHAT_ID" in
    ''|*[!0-9-]*|*?-*|-) echo "ALERT_TELEGRAM_CHAT_ID must be an integer"; exit 1 ;;
  esac
  printf '%s' "$ALERT_TELEGRAM_BOT_TOKEN" > /tmp/telegram_bot_token
  receivers="$receivers
  - name: telegram
    telegram_configs:
      - bot_token_file: /tmp/telegram_bot_token
        chat_id: $ALERT_TELEGRAM_CHAT_ID
        parse_mode: ''
        send_resolved: true
        message: '{{ template \"oj.telegram\" . }}'"
  r=telegram
fi

cat > /tmp/alertmanager.yml <<YML
route:
  receiver: $r
  group_by: [alertname]
  group_wait: 30s
  repeat_interval: 4h
templates: ['/etc/alertmanager/*.tmpl']
receivers:
$receivers
YML
echo "alertmanager receiver: $r"
exec /bin/alertmanager --config.file=/tmp/alertmanager.yml --storage.path=/alertmanager --cluster.listen-address=
