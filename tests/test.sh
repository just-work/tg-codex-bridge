#!/bin/bash

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BRIDGE="$ROOT/tg-codex-bridge.sh"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tgcb.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export TGCB_HOME="$SANDBOX/bridge"
export TGCB_PLIST="$SANDBOX/bridge.plist"
export TGCB_LAUNCHCTL="$SANDBOX/bin/launchctl"
export TGCB_CURL="$SANDBOX/bin/curl"
export TGCB_CODEX="$SANDBOX/bin/codex"
export TGCB_ENV="$SANDBOX/.env"
export TGCB_FAKE_SERVICE="$SANDBOX/service"
export TGCB_FAKE_CALLS="$SANDBOX/calls"
export TGCB_FAKE_PROMPT="$SANDBOX/prompt"
export TGCB_FAKE_UPDATES="$SANDBOX/updates.json"
mkdir -p "$HOME" "$SANDBOX/bin"

cat > "$TGCB_LAUNCHCTL" <<'EOF'
#!/bin/bash
case "$1" in
  bootstrap) : > "$TGCB_FAKE_SERVICE" ;;
  bootout) rm -f "$TGCB_FAKE_SERVICE" ;;
  print) test -f "$TGCB_FAKE_SERVICE" ;;
esac
EOF

cat > "$TGCB_CURL" <<'EOF'
#!/bin/bash
while [ "$1" != --config ]; do shift; done
request=$(cat "$2")
if printf '%s' "$request" | grep -q getUpdates; then
  cat "$TGCB_FAKE_UPDATES"
else
  echo send >> "$TGCB_FAKE_CALLS"
fi
EOF

cat > "$TGCB_CODEX" <<'EOF'
#!/bin/bash
while [ "$1" != --output-last-message ]; do shift; done
output=$2
cat > "$TGCB_FAKE_PROMPT"
echo 'Codex answer' > "$output"
echo codex >> "$TGCB_FAKE_CALLS"
EOF
chmod +x "$SANDBOX/bin/"*

echo 'TELEGRAM_BOT_TOKEN=test-token' > "$TGCB_ENV"
chmod 600 "$TGCB_ENV"
cat > "$TGCB_FAKE_UPDATES" <<'EOF'
{"ok":true,"result":[
  {"update_id":10,"message":{"chat":{"id":42,"type":"private"},"text":"/status"}},
  {"update_id":11,"message":{"chat":{"id":42,"type":"private"},"text":"Hello from Telegram"}}
]}
EOF

expect() {
  expected=$1
  shift
  if "$@" >/dev/null 2>&1; then actual=0; else actual=$?; fi
  test "$actual" = "$expected" || { echo "FAIL: expected $expected, got $actual" >&2; exit 1; }
}

thread='codex://threads/00000000-0000-0000-0000-000000000000'
other='codex://threads/11111111-1111-1111-1111-111111111111'

chmod 644 "$TGCB_ENV"
expect 64 "$BRIDGE" 42 "$thread"
chmod 600 "$TGCB_ENV"
expect 0 "$BRIDGE" 42 "$thread"
expect 0 "$BRIDGE" 43 "$other"
test -x "$TGCB_HOME/tg-codex-bridge.sh"
test -f "$TGCB_PLIST"
status=$($BRIDGE status 42)
case $status in *running*"$thread"*) ;; *) exit 1 ;; esac

TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
test "$(cat "$TGCB_FAKE_PROMPT")" = 'Hello from Telegram'
test "$(grep -c '^codex$' "$TGCB_FAKE_CALLS")" = 1
test "$(grep -c '^send$' "$TGCB_FAKE_CALLS")" = 2
test "$(cat "$TGCB_HOME/offset")" = 12

expect 0 "$BRIDGE" stop 42
expect 1 "$BRIDGE" status 42
case $($BRIDGE status 43) in *"$other"*) ;; *) exit 1 ;; esac
test -e "$TGCB_PLIST"
expect 0 "$BRIDGE" stop 43
test ! -e "$TGCB_PLIST"
expect 64 "$BRIDGE" start 42 "$thread"
expect 64 "$BRIDGE" status
expect 1 "$BRIDGE" stop 43

echo PASS
