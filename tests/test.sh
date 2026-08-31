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
export TGCB_FAKE_LIFECYCLE="$SANDBOX/lifecycle"
export TGCB_FAKE_FAIL_BOOTOUT="$SANDBOX/fail-bootout"
export TGCB_FAKE_CALLS="$SANDBOX/calls"
export TGCB_FAKE_PROMPT="$SANDBOX/prompt"
export TGCB_FAKE_PROMPTS="$SANDBOX/prompts"
export TGCB_FAKE_THREADS="$SANDBOX/threads"
export TGCB_FAKE_UPDATES="$SANDBOX/updates.json"
export TGCB_FAKE_MESSAGES="$SANDBOX/messages"
mkdir -p "$HOME" "$SANDBOX/bin"

cat > "$TGCB_LAUNCHCTL" <<'EOF'
#!/bin/bash
case "$1" in
  bootstrap)
    echo "$1" >> "$TGCB_FAKE_LIFECYCLE"
    test ! -f "$TGCB_FAKE_SERVICE" || exit 1
    : > "$TGCB_FAKE_SERVICE"
    ;;
  bootout)
    echo "$1" >> "$TGCB_FAKE_LIFECYCLE"
    if test -f "$TGCB_FAKE_FAIL_BOOTOUT"; then rm -f "$TGCB_FAKE_FAIL_BOOTOUT"; exit 1; fi
    rm -f "$TGCB_FAKE_SERVICE"
    ;;
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
  message=$(printf '%s\n' "$request" | sed -n 's/^data-urlencode = "text@\(.*\)"$/\1/p')
  cat "$message" >> "$TGCB_FAKE_MESSAGES"
  echo >> "$TGCB_FAKE_MESSAGES"
  exit "${TGCB_FAKE_SEND_STATUS:-0}"
fi
EOF

cat > "$TGCB_CODEX" <<'EOF'
#!/bin/bash
if [ "${TGCB_FAKE_CODEX_BUSY:-0}" = 1 ]; then
  echo 'thread already has an active writer' >&2
  exit 1
fi
while [ "$1" != --output-last-message ]; do shift; done
output=$2
cat > "$TGCB_FAKE_PROMPT"
cat "$TGCB_FAKE_PROMPT" >> "$TGCB_FAKE_PROMPTS"
echo >> "$TGCB_FAKE_PROMPTS"
echo "$4" >> "$TGCB_FAKE_THREADS"
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
retargeted='codex://threads/22222222-2222-2222-2222-222222222222'

help_output=$($BRIDGE --help 2>&1) || { echo 'FAIL: --help exited nonzero' >&2; exit 1; }
case $help_output in *Usage:*) ;; *) echo 'FAIL: --help omitted Usage' >&2; exit 1 ;; esac
case $help_output in *'unbound variable'*) echo 'FAIL: --help emitted an unbound-variable error' >&2; exit 1 ;; esac
expect 64 "$BRIDGE" --help extra
expect 64 "$BRIDGE" -h extra

chmod 644 "$TGCB_ENV"
expect 64 "$BRIDGE" 42 "$thread"
chmod 600 "$TGCB_ENV"
expect 0 "$BRIDGE" 42 "$thread"
lifecycle=$(cat "$TGCB_FAKE_LIFECYCLE")
expect 0 "$BRIDGE" 43 "$other"
expect 0 "$BRIDGE" 42 "$retargeted"
test "$(cat "$TGCB_FAKE_LIFECYCLE")" = "$lifecycle" || {
  echo 'FAIL: unchanged runtime restarted worker' >&2
  exit 1
}
/usr/bin/printf 'old runtime\n' > "$TGCB_HOME/tg-codex-bridge.sh"
/bin/mkdir "$TGCB_HOME/routes/44.tmp"
expect 1 "$BRIDGE" 44 "$thread"
/bin/rmdir "$TGCB_HOME/routes/44.tmp"
expect 0 "$BRIDGE" 44 "$thread"
expected_lifecycle="$lifecycle
bootout
bootstrap"
test "$(cat "$TGCB_FAKE_LIFECYCLE")" = "$expected_lifecycle" || {
  echo 'FAIL: failed route update lost required runtime restart' >&2
  exit 1
}
expect 0 "$BRIDGE" stop 44
/usr/bin/printf 'old runtime\n' > "$TGCB_HOME/tg-codex-bridge.sh"
: > "$TGCB_FAKE_FAIL_BOOTOUT"
expect 1 "$BRIDGE" 44 "$thread"
expect 0 "$BRIDGE" 44 "$thread"
expected_lifecycle="$expected_lifecycle
bootout
bootout
bootstrap"
test "$(cat "$TGCB_FAKE_LIFECYCLE")" = "$expected_lifecycle" || {
  echo 'FAIL: failed runtime reload was not retried' >&2
  exit 1
}
expect 0 "$BRIDGE" stop 44
test -x "$TGCB_HOME/tg-codex-bridge.sh"
test -f "$TGCB_PLIST"
status=$($BRIDGE status 42)
case $status in *running*"$retargeted"*) ;; *) exit 1 ;; esac

TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
test "$(cat "$TGCB_FAKE_PROMPT")" = 'Hello from Telegram'
test "$(cat "$TGCB_FAKE_THREADS")" = "${retargeted#codex://threads/}"
test "$(grep -c '^codex$' "$TGCB_FAKE_CALLS")" = 1
test "$(grep -c '^send$' "$TGCB_FAKE_CALLS")" = 2
test "$(cat "$TGCB_HOME/offset")" = 12

cat > "$TGCB_FAKE_UPDATES" <<'EOF'
{"ok":true,"result":[
  {"update_id":12,"message":{"chat":{"id":42,"type":"private"},"text":"Binding failure"}}
]}
EOF
mkdir "$TGCB_HOME/route-binding.tmp"
binding_messages=$(wc -l < "$TGCB_FAKE_MESSAGES")
expect 0 env TGCB_FAKE_CODEX_BUSY=1 TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
test "$(cat "$TGCB_HOME/offset")" = 13
test "$(wc -l < "$TGCB_FAKE_MESSAGES")" -gt "$binding_messages"
case $(tail -2 "$TGCB_FAKE_MESSAGES") in *'Не удалось отложить сообщение. Повторите его.'*) ;; *) echo 'FAIL: binding failure was not explained' >&2; exit 1 ;; esac
rmdir "$TGCB_HOME/route-binding.tmp"

cat > "$TGCB_FAKE_UPDATES" <<'EOF'
{"ok":true,"result":[
  {"update_id":13,"message":{"chat":{"id":42,"type":"private"},"text":"Busy message"}},
  {"update_id":14,"message":{"chat":{"id":43,"type":"private"},"text":"Later message"}}
]}
EOF
busy_calls=$(wc -l < "$TGCB_FAKE_CALLS")
busy_messages=$(wc -l < "$TGCB_FAKE_MESSAGES")
busy_prompts=$(wc -l < "$TGCB_FAKE_PROMPTS")
expect 75 env TGCB_FAKE_CODEX_BUSY=1 TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
test "$(cat "$TGCB_HOME/offset")" = 13 || { echo 'FAIL: busy update was acknowledged' >&2; exit 1; }
test "$(wc -l < "$TGCB_FAKE_CALLS")" = "$busy_calls" || { echo 'FAIL: busy update completed a Codex call' >&2; exit 1; }
test "$(wc -l < "$TGCB_FAKE_MESSAGES")" = "$busy_messages" || { echo 'FAIL: busy update sent a reply' >&2; exit 1; }
test "$(wc -l < "$TGCB_FAKE_PROMPTS")" = "$busy_prompts" || { echo 'FAIL: later update was processed after busy update' >&2; exit 1; }
test -f "$TGCB_HOME/route-binding"
test "$(stat -f '%Lp' "$TGCB_HOME/route-binding")" = 600
test "$(sed -n 's/^UPDATE_ID=//p' "$TGCB_HOME/route-binding")" = 13
test "$(sed -n 's/^THREAD_ID=//p' "$TGCB_HOME/route-binding")" = "${retargeted#codex://threads/}"
if grep -q 'Busy message' "$TGCB_HOME/route-binding"; then
  echo 'FAIL: busy message was persisted in route snapshot' >&2
  exit 1
fi

expect 0 "$BRIDGE" 42 "$other"
TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
test "$(cat "$TGCB_FAKE_PROMPT")" = 'Later message'
test "$(sed -n '2p' "$TGCB_FAKE_PROMPTS")" = 'Busy message'
test "$(sed -n '3p' "$TGCB_FAKE_PROMPTS")" = 'Later message'
test "$(sed -n '2p' "$TGCB_FAKE_THREADS")" = "${retargeted#codex://threads/}"
test "$(sed -n '3p' "$TGCB_FAKE_THREADS")" = "${other#codex://threads/}"
test "$(grep -c '^codex$' "$TGCB_FAKE_CALLS")" = 3
test "$(cat "$TGCB_HOME/offset")" = 15
test ! -e "$TGCB_HOME/route-binding"

cat > "$TGCB_FAKE_UPDATES" <<'EOF'
{"ok":true,"result":[
  {"update_id":15,"message":{"chat":{"id":42,"type":"private"},"text":"Cancelled message"}},
  {"update_id":16,"message":{"chat":{"id":43,"type":"private"},"text":"After cancellation"}}
]}
EOF
expect 75 env TGCB_FAKE_CODEX_BUSY=1 TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
test "$(sed -n 's/^CHAT_ID=//p' "$TGCB_HOME/route-binding")" = 42 || { echo 'FAIL: busy binding omitted chat ID' >&2; exit 1; }
expect 0 "$BRIDGE" stop 42
expect 0 "$BRIDGE" 42 "$thread"
TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
if grep -q 'Cancelled message' "$TGCB_FAKE_PROMPTS"; then
  echo 'FAIL: stopped busy update was resumed after reconnect' >&2
  exit 1
fi
test "$(sed -n '4p' "$TGCB_FAKE_PROMPTS")" = 'After cancellation'
test "$(cat "$TGCB_HOME/offset")" = 17

cat > "$TGCB_FAKE_UPDATES" <<'EOF'
{"ok":true,"result":[
  {"update_id":17,"message":{"chat":{"id":43,"type":"private"},"text":"Delivery error"}}
]}
EOF
codex_calls=$(grep -c '^codex$' "$TGCB_FAKE_CALLS")
expect 0 env TGCB_FAKE_SEND_STATUS=75 TGCB_ONCE=1 "$TGCB_HOME/tg-codex-bridge.sh" run
test "$(grep -c '^codex$' "$TGCB_FAKE_CALLS")" = $((codex_calls + 1))
test "$(cat "$TGCB_HOME/offset")" = 18
test ! -e "$TGCB_HOME/route-binding"

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
