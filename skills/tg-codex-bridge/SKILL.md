---
name: tg-codex-bridge
description: Use when a user wants to connect a Telegram chat to an existing local Codex thread, inspect that route, or stop it on macOS.
---

Use `./tg-codex-bridge.sh`; its runtime lives in this skill's `scripts/` directory.

Store `TELEGRAM_BOT_TOKEN` in `~/.config/tg-codex-bridge/.env` with mode `0600`. Never pass or print the token.

```bash
./tg-codex-bridge.sh CHAT_ID codex://threads/THREAD_ID
./tg-codex-bridge.sh status CHAT_ID
./tg-codex-bridge.sh stop CHAT_ID
```

Connect or stop a route only when the user authorizes it. `stop` affects only that CHAT_ID.
