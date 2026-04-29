# Aider

[Aider](https://aider.chat) has no native slash-command system for arbitrary protocols. Use `/run`.

## Status

**Doc-only.** Aider's design favors `/run`-based ad-hoc commands. No deeper integration planned.

## Usage

In an Aider session:

```
/run ~/.agent-message-cmd inbox
/run echo "lgtm" | ~/.agent-message-cmd reply
/run echo "ping" | ~/.agent-message-cmd send <alias>
```

## Optional: shell aliases

For terser invocations, add to `~/.bashrc` / `~/.zshrc`:

```bash
amail() { ~/.agent-message-cmd inbox; }
amail-send() { echo "$2" | ~/.agent-message-cmd send "$1"; }
amail-reply() { echo "$1" | ~/.agent-message-cmd reply; }
```

Then in Aider:

```
/run amail
/run amail-send peer "ping"
/run amail-reply "lgtm"
```

## Verify

```
/run ~/.agent-message-cmd --version
```

Should print `agent-message 1.0.0 (SAMP v1)`.
