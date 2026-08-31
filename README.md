# tg-codex-bridge  [![Tests and ShellCheck](https://github.com/just-work/tg-codex-bridge/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/just-work/tg-codex-bridge/actions/workflows/ci.yml)

![tg-codex-bridge](assets/github-social.png)

A tiny macOS bridge from Telegram chats to existing local Codex threads.

One LaunchAgent. No API key. No model calls while idle.

## Setup

Requires macOS, `jq`, ChatGPT with its bundled Codex CLI, and a Telegram bot token.

```bash
mkdir -p "$HOME/.config/tg-codex-bridge"
install -m 600 /dev/null "$HOME/.config/tg-codex-bridge/.env"
${EDITOR:-vi} "$HOME/.config/tg-codex-bridge/.env"
```

```dotenv
TELEGRAM_BOT_TOKEN=replace-me
```

## Commands

```bash
BRIDGE=/absolute/path/to/tg-codex-bridge/tg-codex-bridge.sh
cd /path/to/project
"$BRIDGE" CHAT_ID codex://threads/THREAD_ID
"$BRIDGE" status CHAT_ID
"$BRIDGE" stop CHAT_ID
"$BRIDGE" --help
```

Run the first command from the intended project or worktree: the route captures that working directory for Codex. Repeating its private `CHAT_ID` retargets it live for the next Telegram message without normally restarting the shared listener. Private chat IDs share that listener. `status` and `stop` are scoped to their `CHAT_ID`; stopping the final route stops the listener. Telegram `/help` and `/status` are handled locally only for configured private chats, without starting Codex.

## Security

- The token file must be owned by the current user, mode `0600`, and not a symlink.
- The token never appears in arguments or the LaunchAgent plist.
- Only configured private chat IDs can start Codex turns.
- Codex keeps its normal local permissions and approvals.

Treat Telegram access as access to the connected Codex threads.

## Test

```bash
/bin/bash tests/test.sh
shellcheck -x -s bash skills/tg-codex-bridge/scripts/tg-codex-bridge.sh tests/test.sh
```

## License

[MIT](LICENSE) © [Just Work](https://just-work.org/)
