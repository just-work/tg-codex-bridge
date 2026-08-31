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

Act only with user authorization. Repeating a private `CHAT_ID` retargets the next Telegram message live and normally keeps the shared listener. Private chats share it. `status` and `stop` apply only to their `CHAT_ID`; stopping the last route stops it. Telegram `/help` and `/status` stay local for configured private chats.

When a routed thread is active in Desktop, its update remains unacknowledged; later updates wait. Its originally captured thread/workdir stay bound if `CHAT_ID` is retargeted while it waits. After it frees, retry it as the next turn, then use current routes in order. Never inject into the active turn. Telegram is the ordered queue; local state only binds that busy update, never queues messages. A busy route blocks later shared-listener updates.
