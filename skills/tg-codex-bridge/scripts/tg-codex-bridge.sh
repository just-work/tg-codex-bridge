#!/usr/bin/env bash

set -u
umask 077

APP_DIR=${TGCB_HOME:-"$HOME/Library/Application Support/tg-codex-bridge"}
ROUTES_DIR="$APP_DIR/routes"
RUNTIME="$APP_DIR/tg-codex-bridge.sh"
PLIST=${TGCB_PLIST:-"$HOME/Library/LaunchAgents/com.just-work.tg-codex-bridge.plist"}
LABEL=com.just-work.tg-codex-bridge
ENV_FILE=${TGCB_ENV:-"$HOME/.config/tg-codex-bridge/.env"}
LAUNCHCTL=${TGCB_LAUNCHCTL:-/bin/launchctl}
CURL=${TGCB_CURL:-/usr/bin/curl}
CODEX=${TGCB_CODEX:-/Applications/ChatGPT.app/Contents/Resources/codex}

usage() {
  printf '%s\n' "Usage: $0 CHAT_ID codex://threads/THREAD_ID" \
    "       $0 status CHAT_ID" \
    "       $0 stop CHAT_ID" >&2
  return 64
}

valid_chat() {
  case ${1:-} in ''|0|0*|*[!0-9]*) return 1 ;; esac
}

thread_id() {
  local id
  id=${1#codex://threads/}
  case ${1:-}:$id in
    codex://threads/????????-????-????-????-????????????:*[!0-9a-f-]*) return 1 ;;
    codex://threads/????????-????-????-????-????????????:*) printf '%s\n' "$id" ;;
    *) return 1 ;;
  esac
}

route_file() {
  printf '%s/%s\n' "$ROUTES_DIR" "$1"
}

read_token() {
  test -f "$ENV_FILE" && test ! -L "$ENV_FILE" || return 1
  test "$(/usr/bin/stat -f '%u:%Lp' "$ENV_FILE")" = "$(/usr/bin/id -u):600" || return 1
  TOKEN=$(/usr/bin/sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE")
  case $TOKEN in ''|*[!A-Za-z0-9_:-]*) return 1 ;; esac
}

xml() {
  /usr/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

write_plist() {
  local runtime app home codex_home env_file
  runtime=$(printf '%s' "$RUNTIME" | xml)
  app=$(printf '%s' "$APP_DIR" | xml)
  home=$(printf '%s' "$HOME" | xml)
  codex_home=$(printf '%s' "${CODEX_HOME:-$HOME/.codex}" | xml)
  env_file=$(printf '%s' "$ENV_FILE" | xml)
  /bin/mkdir -p "$(/usr/bin/dirname "$PLIST")"
  /bin/cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$runtime</string><string>run</string></array>
<key>EnvironmentVariables</key><dict>
<key>HOME</key><string>$home</string>
<key>CODEX_HOME</key><string>$codex_home</string>
<key>TGCB_HOME</key><string>$app</string>
<key>TGCB_ENV</key><string>$env_file</string>
</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>$app/bridge.log</string>
<key>StandardErrorPath</key><string>$app/bridge.log</string>
</dict></plist>
EOF
  /bin/chmod 600 "$PLIST"
}

start_route() {
  local chat uri id file temporary runtime_temporary runtime_changed
  chat=$1
  uri=$2
  if ! valid_chat "$chat" || ! id=$(thread_id "$uri") || ! read_token; then
    printf '%s\n' 'Invalid chat, thread URI, or Telegram credentials.' >&2
    return 64
  fi

  /bin/mkdir -p "$ROUTES_DIR"
  /bin/chmod 700 "$APP_DIR" "$ROUTES_DIR"
  runtime_changed=0
  if ! /usr/bin/cmp -s "$0" "$RUNTIME"; then
    runtime_temporary="$RUNTIME.tmp"
    /bin/cp "$0" "$runtime_temporary" && /bin/chmod 700 "$runtime_temporary" &&
      /bin/mv -f "$runtime_temporary" "$RUNTIME" || return 1
    runtime_changed=1
  fi

  file=$(route_file "$chat")
  temporary="$file.tmp"
  {
    printf 'THREAD_ID=%q\n' "$id"
    printf 'WORK_DIR=%q\n' "$PWD"
  } > "$temporary" && /bin/chmod 600 "$temporary" && /bin/mv -f "$temporary" "$file" || return 1

  if test "$runtime_changed" = 1; then
    write_plist || return 1
    "$LAUNCHCTL" bootout "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 || true
    "$LAUNCHCTL" bootstrap "gui/$(/usr/bin/id -u)" "$PLIST" || return 1
  elif ! "$LAUNCHCTL" print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
    write_plist || return 1
    "$LAUNCHCTL" bootstrap "gui/$(/usr/bin/id -u)" "$PLIST" || return 1
  fi
  printf 'running: chat %s -> %s\n' "$chat" "$uri"
}

status_route() {
  local chat file state
  chat=$1
  valid_chat "$chat" || return 64
  file=$(route_file "$chat")
  test -f "$file" || {
    printf 'stopped: chat %s\n' "$chat" >&2
    return 1
  }
  # shellcheck disable=SC1090
  . "$file"
  state=stopped
  "$LAUNCHCTL" print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 && state=running
  printf '%s: chat %s -> codex://threads/%s\n' "$state" "$chat" "$THREAD_ID"
}

stop_route() {
  local chat file remaining
  chat=$1
  valid_chat "$chat" || return 64
  file=$(route_file "$chat")
  test -f "$file" || return 1
  /bin/rm -f "$file"
  remaining=$(/usr/bin/find "$ROUTES_DIR" -type f -maxdepth 1 2>/dev/null | /usr/bin/head -1)
  if test -z "$remaining"; then
    "$LAUNCHCTL" bootout "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 || true
    /bin/rm -f "$PLIST"
  fi
  printf 'stopped: chat %s\n' "$chat"
}

send_message() {
  local chat text message request result
  chat=$1
  text=$2
  message=$(/usr/bin/mktemp "$APP_DIR/message.XXXXXX") || return 1
  request=$(/usr/bin/mktemp "$APP_DIR/request.XXXXXX") || { /bin/rm -f "$message"; return 1; }
  printf '%s' "$text" > "$message"
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\nrequest = "POST"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text@%s"\nsilent\nshow-error\n' \
    "$TOKEN" "$chat" "$message" > "$request"
  "$CURL" --connect-timeout 10 --max-time 45 --config "$request" >/dev/null
  result=$?
  /bin/rm -f "$message" "$request"
  return "$result"
}

run_codex() {
  local text answer error response
  text=$1
  answer=$(/usr/bin/mktemp "$APP_DIR/answer.XXXXXX") || return 1
  error=$(/usr/bin/mktemp "$APP_DIR/error.XXXXXX") || { /bin/rm -f "$answer"; return 1; }
  if (cd "$WORK_DIR" && printf '%s' "$text" | "$CODEX" exec --output-last-message "$answer" resume "$THREAD_ID" - >/dev/null 2>"$error"); then
    response=$(/bin/cat "$answer")
    test -n "$response" || response='Codex завершил работу без ответа.'
  elif /usr/bin/grep -q 'already has an active writer' "$error"; then
    response='Codex thread занят в приложении. Переключитесь с него и повторите сообщение.'
  else
    response='Не удалось продолжить Codex thread.'
  fi
  /bin/cat "$error" >&2
  /bin/rm -f "$answer" "$error"
  send_message "$CHAT_ID" "$response"
}

worker() {
  local offset response request update update_id file text
  read_token || { printf '%s\n' 'Telegram credentials are unavailable.' >&2; return 1; }
  test -x "$CODEX" || CODEX=$(command -v codex) || return 1
  offset=0
  test -f "$APP_DIR/offset" && offset=$(/bin/cat "$APP_DIR/offset")

  while :; do
    response=$(/usr/bin/mktemp "$APP_DIR/updates.XXXXXX") || return 1
    request=$(/usr/bin/mktemp "$APP_DIR/request.XXXXXX") || return 1
    printf 'url = "https://api.telegram.org/bot%s/getUpdates"\nget\ndata-urlencode = "timeout=30"\ndata-urlencode = "offset=%s"\ndata-urlencode = "allowed_updates=[\\"message\\"]"\nsilent\nshow-error\n' \
      "$TOKEN" "$offset" > "$request"
    if ! "$CURL" --connect-timeout 10 --max-time 45 --config "$request" > "$response" ||
       ! /usr/bin/jq -e '.ok == true and (.result | type == "array") and all(.result[]; (.update_id | type == "number"))' "$response" >/dev/null 2>&1; then
      /bin/rm -f "$response" "$request"
      test "${TGCB_ONCE:-0}" = 1 && return 1
      /bin/sleep 5
      continue
    fi
    /bin/rm -f "$request"

    while IFS= read -r update; do
      update_id=$(printf '%s' "$update" | /usr/bin/jq -r '.update_id')
      offset=$((update_id + 1))
      printf '%s\n' "$offset" > "$APP_DIR/offset.tmp" && /bin/mv -f "$APP_DIR/offset.tmp" "$APP_DIR/offset"

      CHAT_ID=$(printf '%s' "$update" | /usr/bin/jq -r '.message.chat.id // empty | tostring')
      test "$(printf '%s' "$update" | /usr/bin/jq -r '.message.chat.type // empty')" = private || continue
      file=$(route_file "$CHAT_ID")
      test -f "$file" || continue
      text=$(printf '%s' "$update" | /usr/bin/jq -r '.message.text // empty')
      test -n "$text" || continue
      # shellcheck disable=SC1090
      . "$file"
      case $text in
        /help) send_message "$CHAT_ID" 'Отправьте сообщение, чтобы продолжить связанный Codex thread. Команды: /help, /status.' ;;
        /status) send_message "$CHAT_ID" "Bridge работает. Thread: codex://threads/$THREAD_ID" ;;
        *) run_codex "$text" ;;
      esac
    done < <(/usr/bin/jq -c '.result[]' "$response")
    /bin/rm -f "$response"
    test "${TGCB_ONCE:-0}" = 1 && return 0
  done
}

main() {
  case ${1:-} in
    status) test "$#" -eq 2 || usage; status_route "${2:-}" ;;
    stop) test "$#" -eq 2 || usage; stop_route "${2:-}" ;;
    run) test "$#" -eq 1 || usage; worker ;;
    *) test "$#" -eq 2 || usage; start_route "$1" "$2" ;;
  esac
}

main "$@"
