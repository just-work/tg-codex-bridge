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
CODEX=${TGCB_CODEX:-}

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

valid_codex() {
  test -n "${1:-}" && test -x "$1" && "$1" --version >/dev/null 2>&1
}

resolve_codex() {
  local candidate
  if test -n "$CODEX"; then
    valid_codex "$CODEX" || return 1
    return 0
  fi

  for candidate in \
    /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex \
    /Applications/ChatGPT.app/Contents/Resources/codex \
    "$(command -v codex 2>/dev/null || true)"; do
    if valid_codex "$candidate"; then
      CODEX=$candidate
      return 0
    fi
  done
  return 1
}

write_plist() {
  local runtime app home codex_home env_file codex
  runtime=$(printf '%s' "$RUNTIME" | xml)
  app=$(printf '%s' "$APP_DIR" | xml)
  home=$(printf '%s' "$HOME" | xml)
  codex_home=$(printf '%s' "${CODEX_HOME:-$HOME/.codex}" | xml)
  env_file=$(printf '%s' "$ENV_FILE" | xml)
  codex=$(printf '%s' "$CODEX" | xml)
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
<key>TGCB_CODEX</key><string>$codex</string>
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
  if ! resolve_codex; then
    printf '%s\n' 'Codex CLI is unavailable.' >&2
    return 1
  fi

  /bin/mkdir -p "$ROUTES_DIR"
  /bin/chmod 700 "$APP_DIR" "$ROUTES_DIR"
  file=$(route_file "$chat")
  temporary="$file.tmp"
  {
    printf 'THREAD_ID=%q\n' "$id"
    printf 'WORK_DIR=%q\n' "$PWD"
  } > "$temporary" && /bin/chmod 600 "$temporary" && /bin/mv -f "$temporary" "$file" || return 1

  runtime_changed=0
  if ! /usr/bin/cmp -s "$0" "$RUNTIME"; then
    runtime_temporary="$RUNTIME.tmp"
    /bin/cp "$0" "$runtime_temporary" && /bin/chmod 700 "$runtime_temporary" || return 1
    runtime_changed=1
  fi

  if test "$runtime_changed" = 1; then
    write_plist || return 1
    if "$LAUNCHCTL" print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
      "$LAUNCHCTL" bootout "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 || return 1
    fi
    /bin/mv -f "$runtime_temporary" "$RUNTIME" || return 1
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
  local chat file remaining binding binding_chat
  chat=$1
  valid_chat "$chat" || return 64
  file=$(route_file "$chat")
  test -f "$file" || return 1
  /bin/rm -f "$file"
  binding="$APP_DIR/route-binding"
  if test -f "$binding"; then
    binding_chat=$(/usr/bin/sed -n 's/^CHAT_ID=//p' "$binding")
    if test "$binding_chat" = "$chat"; then
      : > "$APP_DIR/route-binding.cancelled" || return 1
    fi
  fi
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
  if (cd "$WORK_DIR" && printf '%s' "$text" | "$CODEX" exec --output-last-message "$answer" resume --skip-git-repo-check "$THREAD_ID" - >/dev/null 2>"$error"); then
    response=$(/bin/cat "$answer")
    test -n "$response" || response='Codex завершил работу без ответа.'
  elif /usr/bin/grep -q 'already has an active writer' "$error"; then
    /bin/rm -f "$answer" "$error"
    return 75
  else
    response='Не удалось продолжить Codex thread.'
  fi
  /bin/cat "$error" >&2
  /bin/rm -f "$answer" "$error"
  send_message "$CHAT_ID" "$response"
  return 0
}

app_server_call() {
  local request temporary input output error server_pid line message_id status
  request=$1
  temporary=$(/usr/bin/mktemp -d "$APP_DIR/app-server.XXXXXX") || return 77
  input="$temporary/input"
  output="$temporary/output"
  error="$temporary/error"
  /usr/bin/mkfifo "$input" "$output" || {
    /bin/rm -f "$input" "$output" "$error"
    /bin/rmdir "$temporary" 2>/dev/null || true
    return 77
  }
  "$CODEX" app-server --stdio < "$input" > "$output" 2>"$error" &
  server_pid=$!
  exec 8>"$input"
  exec 9<>"$output"
  printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tg-codex-bridge","version":"1"},"capabilities":{"experimentalApi":true}}}' >&8
  status=77
  while IFS= read -r -t 15 line <&9; do
    message_id=$(printf '%s\n' "$line" | /usr/bin/jq -r '.id // empty' 2>/dev/null) || continue
    test "$message_id" = 1 || continue
    if printf '%s\n' "$line" | /usr/bin/jq -e '.error != null' >/dev/null 2>&1; then
      status=76
    elif printf '%s\n' "$line" | /usr/bin/jq -e '.result != null' >/dev/null 2>&1; then
      status=0
    fi
    break
  done
  if test "$status" = 0; then
    printf '%s\n' '{"method":"initialized"}' >&8
    printf '%s\n' "$request" >&8
    status=75
    while IFS= read -r -t 30 line <&9; do
      message_id=$(printf '%s\n' "$line" | /usr/bin/jq -r '.id // empty' 2>/dev/null) || continue
      test "$message_id" = 2 || continue
      if printf '%s\n' "$line" | /usr/bin/jq -e '.error != null' >/dev/null 2>&1; then
        status=76
      else
        printf '%s\n' "$line"
        status=0
      fi
      break
    done
  fi
  exec 8>&-
  exec 9<&-
  /bin/kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  /bin/rm -f "$input" "$output" "$error"
  /bin/rmdir "$temporary" 2>/dev/null || true
  return "$status"
}

queue_codex() {
  local text client request output status
  text=$1
  client=$2
  request=$(printf '%s' "$text" | /usr/bin/jq -Rsc --arg thread "$THREAD_ID" --arg client "$client" '
    {id:2,method:"thread/queue/add",params:{
      threadId:$thread,
      input:[{type:"text",text:.}],
      clientUserMessageId:$client
    }}') || return 77
  if output=$(app_server_call "$request"); then
    :
  else
    status=$?
    return "$status"
  fi
  printf '%s\n' "$output" | /usr/bin/jq -e '
    select(.id == 2)
    | .result.queuedSubmission.id
    | type == "string" and length > 0' >/dev/null 2>&1
}

queued_answer() {
  local client cursor request output match matched answer
  client=$1
  cursor=
  while :; do
    request=$(/usr/bin/jq -cn --arg thread "$THREAD_ID" --arg cursor "$cursor" '
      {id:2,method:"thread/turns/list",params:{threadId:$thread,limit:50,sortDirection:"desc",itemsView:"full"}}
      | if $cursor == "" then . else .params.cursor = $cursor end') || return 75
    output=$(app_server_call "$request") || return 75
    match=$(printf '%s\n' "$output" | /usr/bin/jq -crs --arg client "$client" '
      [.[]
        | select(.id == 2)
        | .result.data[]?
        | select(any(.items[]?; .type == "userMessage" and .clientId == $client))] as $turns
      | if ($turns | length) != 1 then {matched:false,answer:null}
        elif $turns[0].status != "completed" then {matched:true,answer:null}
        else [$turns[0].items[]?
          | select(.type == "agentMessage" and .phase == "final_answer")
          | .text] as $answers
        | if ($answers | length) == 1 and ($answers[0] | type) == "string" and ($answers[0] | length) > 0
          then {matched:true,answer:$answers[0]}
          else {matched:true,answer:null}
          end
        end') || return 75
    matched=$(printf '%s\n' "$match" | /usr/bin/jq -r '.matched') || return 75
    if test "$matched" = true; then
      answer=$(printf '%s\n' "$match" | /usr/bin/jq -jr '.answer // empty') || return 75
      test -z "$answer" || printf '%s' "$answer"
      return 0
    fi
    cursor=$(printf '%s\n' "$output" | /usr/bin/jq -jrs '[.[] | select(.id == 2) | .result.nextCursor // empty][0] // empty') || return 75
    test -n "$cursor" || return 0
  done
}

write_queue_binding() {
  local state client update_id temporary
  state=$1
  client=$2
  update_id=$3
  temporary="$APP_DIR/route-binding.tmp"
  {
    printf 'UPDATE_ID=%q\n' "$update_id"
    printf 'CHAT_ID=%q\n' "$CHAT_ID"
    printf 'THREAD_ID=%q\n' "$THREAD_ID"
    printf 'WORK_DIR=%q\n' "$WORK_DIR"
    printf 'QUEUE_STATE=%q\n' "$state"
    printf 'QUEUE_CLIENT_ID=%q\n' "$client"
  } > "$temporary" && /bin/chmod 600 "$temporary" && /bin/mv -f "$temporary" "$APP_DIR/route-binding"
}

write_pending_binding() {
  local update_id temporary
  update_id=$1
  temporary="$APP_DIR/route-binding.tmp"
  {
    printf 'UPDATE_ID=%q\n' "$update_id"
    printf 'CHAT_ID=%q\n' "$CHAT_ID"
    printf 'THREAD_ID=%q\n' "$THREAD_ID"
    printf 'WORK_DIR=%q\n' "$WORK_DIR"
  } > "$temporary" && /bin/chmod 600 "$temporary" && /bin/mv -f "$temporary" "$APP_DIR/route-binding"
}

run_queued_codex() {
  local text update_id client answer status
  text=$1
  update_id=$2
  case ${QUEUE_STATE:-} in
    submitting|queued)
      client=${QUEUE_CLIENT_ID:-}
      test -n "$client" || return 75
      ;;
    '')
      client=$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]') || return 75
      write_queue_binding submitting "$client" "$update_id" || return 75
      if queue_codex "$text" "$client"; then
        :
      else
        status=$?
        if test "$status" = 76 || test "$status" = 77; then
          write_pending_binding "$update_id" || return 75
        fi
        return 75
      fi
      write_queue_binding queued "$client" "$update_id" || return 75
      QUEUE_STATE=queued
      QUEUE_CLIENT_ID=$client
      ;;
    *) return 75 ;;
  esac
  answer=$(queued_answer "$client") || return 75
  test -n "$answer" || return 75
  test ! -f "$APP_DIR/route-binding.cancelled" || return 0
  send_message "$CHAT_ID" "$answer" || return 75
}

worker() {
  local offset response request update update_id file text result busy pending_update_id pending_match snapshot_temporary
  read_token || { printf '%s\n' 'Telegram credentials are unavailable.' >&2; return 1; }
  resolve_codex || return 1
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

    busy=0
    while IFS= read -r update; do
      update_id=$(printf '%s' "$update" | /usr/bin/jq -r '.update_id')
      CHAT_ID=$(printf '%s' "$update" | /usr/bin/jq -r '.message.chat.id // empty | tostring')
      pending_match=0
      if test -f "$APP_DIR/route-binding"; then
        pending_update_id=$(/usr/bin/sed -n 's/^UPDATE_ID=//p' "$APP_DIR/route-binding")
        test "$pending_update_id" = "$update_id" && pending_match=1
      fi
      if test "$(printf '%s' "$update" | /usr/bin/jq -r '.message.chat.type // empty')" = private; then
        file=$(route_file "$CHAT_ID")
        if test -f "$file"; then
          text=$(printf '%s' "$update" | /usr/bin/jq -r '.message.text // empty')
          if test -n "$text"; then
            if test "$pending_match" = 1; then
              file="$APP_DIR/route-binding"
            fi
            unset QUEUE_STATE QUEUE_CLIENT_ID
            # shellcheck disable=SC1090,SC1091
            . "$file"
            if test ! -f "$APP_DIR/route-binding.cancelled"; then case $text in
              /help) send_message "$CHAT_ID" 'Отправьте сообщение, чтобы продолжить связанный Codex thread. Команды: /help, /status.' ;;
              /status) send_message "$CHAT_ID" "Bridge работает. Thread: codex://threads/$THREAD_ID" ;;
              *)
                if test "$pending_match" = 1 && test -n "${QUEUE_STATE:-}"; then
                  run_queued_codex "$text" "$update_id"
                  result=$?
                  test "$result" = 75 && busy=1
                else
                  run_codex "$text"
                  result=$?
                  if test "$result" = 75; then
                    if test "$pending_match" != 1; then
                      snapshot_temporary="$APP_DIR/route-binding.tmp"
                      if {
                        printf 'UPDATE_ID=%q\n' "$update_id"
                        printf 'CHAT_ID=%q\n' "$CHAT_ID"
                        printf 'THREAD_ID=%q\n' "$THREAD_ID"
                        printf 'WORK_DIR=%q\n' "$WORK_DIR"
                      } > "$snapshot_temporary" &&
                        /bin/chmod 600 "$snapshot_temporary" &&
                        /bin/mv -f "$snapshot_temporary" "$APP_DIR/route-binding"; then
                        busy=1
                      else
                        test ! -f "$snapshot_temporary" || /bin/rm -f "$snapshot_temporary"
                        send_message "$CHAT_ID" 'Не удалось отложить сообщение. Повторите его.'
                      fi
                    else
                      run_queued_codex "$text" "$update_id"
                      result=$?
                      test "$result" = 75 && busy=1
                    fi
                  fi
                fi
                ;;
            esac; fi
          fi
        fi
      fi
      test "$busy" = 1 && break
      offset=$((update_id + 1))
      if printf '%s\n' "$offset" > "$APP_DIR/offset.tmp" && /bin/mv -f "$APP_DIR/offset.tmp" "$APP_DIR/offset"; then
        /bin/rm -f "$APP_DIR/route-binding" "$APP_DIR/route-binding.cancelled"
      fi
    done < <(/usr/bin/jq -c '.result[]' "$response")
    /bin/rm -f "$response"
    if test "$busy" = 1; then
      test "${TGCB_ONCE:-0}" = 1 && return 75
      /bin/sleep 5
      continue
    fi
    test "${TGCB_ONCE:-0}" = 1 && return 0
  done
}

main() {
  case ${1:-} in
    -h|--help) test "$#" -eq 1 || { usage; return 64; }; usage; return 0 ;;
    status) test "$#" -eq 2 || { usage; return 64; }; status_route "${2:-}" ;;
    stop) test "$#" -eq 2 || { usage; return 64; }; stop_route "${2:-}" ;;
    run) test "$#" -eq 1 || { usage; return 64; }; worker ;;
    *) test "$#" -eq 2 || { usage; return 64; }; start_route "$1" "$2" ;;
  esac
}

main "$@"
