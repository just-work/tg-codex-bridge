---
name: tg-codex-bridge
description: Use when a user wants to connect or retarget a Telegram chat to an existing local Codex thread, inspect that route, or stop it on macOS.
---

Run the bridge repository's launcher from the intended Codex project or worktree. A route captures that current working directory.

Store `TELEGRAM_BOT_TOKEN` in `~/.config/tg-codex-bridge/.env` with mode `0600`. Never pass or print the token.

```bash
BRIDGE=/absolute/path/to/tg-codex-bridge/tg-codex-bridge.sh
cd /path/to/codex-project
"$BRIDGE" CHAT_ID codex://threads/THREAD_ID
"$BRIDGE" status CHAT_ID
"$BRIDGE" stop CHAT_ID
"$BRIDGE" --help
```

Connect, retarget, or stop a route only when the user authorizes it. Repeating a private `CHAT_ID` updates it live for the next Telegram message and normally does not restart the shared listener. Different private chat IDs share that listener. `status` and `stop` apply only to their `CHAT_ID`; stopping the last route stops the listener. Telegram `/help` and `/status` are local only for configured private chats.
