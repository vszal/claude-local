# local-claude-code

Switch the Claude Code CLI between the Anthropic cloud and a **local** llama.cpp
model — without touching `~/.claude/settings.json` or re-running `claude login`.

A small litellm proxy translates between Anthropic's Messages API (what Claude
Code speaks) and the OpenAI-compatible API exposed by llama-server.

```
Claude Code (Anthropic SDK)
        │ ANTHROPIC_BASE_URL=http://localhost:8082
        │ ANTHROPIC_AUTH_TOKEN=local-stub
        ▼
  litellm proxy :8082  ß      ← translates Anthropic ↔ OpenAI format
        │ api_base=http://localhost:8081/v1
        ▼
  llama.cpp :8081            ← your local model
```

The proxy is configured with `model_name: "*"`, so any Claude model name
(`claude-opus-4-7`, `claude-sonnet-4-6`, etc.) is routed to the local model.
You don't have to change Claude Code's `--model` flag.

## Prerequisites

- macOS with `llama.cpp` installed (`brew install llama.cpp` provides `llama-server`)
- Python 3 with the litellm proxy extra:
  ```sh
  pip3 install 'litellm[proxy]'
  ```
- A `claude login` session already completed (OAuth credentials in the macOS
  Keychain) — see the [Authentication modes](#authentication-modes) section if
  you want to use an API key instead.

## One-time setup

Add to your shell profile so commands are always available:

```sh
echo './llm-switch.sh' >> ~/.zshrc
source ~/.zshrc
```

(Adjust the path if you cloned this repo somewhere else.)

## Usage

```sh
llm-local     # Start litellm proxy, point Claude Code at the local model
llm-cloud     # Stop proxy, restore Anthropic cloud
llm-status    # Show current mode and which auth source is active
```

Start the local model server in a separate terminal first:

```sh
./llama-server.sh
```

Then switch modes from any shell where `llm-switch.sh` is sourced.

## Authentication modes

Claude Code accepts auth from **three** sources, in order of precedence when
calling `api.anthropic.com`:

1. `ANTHROPIC_AUTH_TOKEN` env var (sent as `Authorization: Bearer …`)
2. `ANTHROPIC_API_KEY` env var (sent as `x-api-key: …`)
3. OAuth credentials in the macOS Keychain (created by `claude login`,
   stored under `Claude Code-credentials`)

This script supports **both** OAuth (the default for most users) and exported
API keys, and switches cleanly between them.

### Local mode (always)

`llm-local` sets:

```
ANTHROPIC_BASE_URL  = http://localhost:8082   # point at the proxy
ANTHROPIC_AUTH_TOKEN = local-stub              # proxy accepts anything
ANTHROPIC_API_KEY   = (unset)                  # avoid OAuth precedence collisions
```

`ANTHROPIC_AUTH_TOKEN` is used (rather than `ANTHROPIC_API_KEY`) deliberately:
it sidesteps any "is this a real Anthropic key?" validation and won't compete
with OAuth credentials in the Keychain.

### Cloud mode — OAuth path (default)

`llm-cloud` unsets all three Anthropic env vars. With nothing in the
environment, Claude Code falls back to reading OAuth credentials from the
Keychain — the normal `claude login` state.

`llm-status` reports this as:

```
Mode    : CLOUD  (Anthropic)
Auth    : OAuth credentials in Keychain
```

You don't need to do anything beyond `llm-cloud`. The script never touches the
Keychain entry.

### Cloud mode — API key path (dual mode, optional)

If you prefer to use an exported `ANTHROPIC_API_KEY` (e.g. a workspace key, a
service account, or a key with different rate limits than your OAuth login),
the script preserves it across switches:

1. **Before** running `llm-local`, export the key in your shell:
   ```sh
   export ANTHROPIC_API_KEY=sk-ant-…
   ```
2. `llm-local` saves it to `~/.config/llm-switch/saved_api_key` (mode 0600) so
   the switch to local mode doesn't lose it.
3. `llm-cloud` restores it back into the environment automatically.

`llm-status` then reports:

```
Mode    : CLOUD  (Anthropic)
Auth    : ANTHROPIC_API_KEY (108 chars)
```

To go back to OAuth-only mode, remove the saved file and unexport the key:

```sh
rm ~/.config/llm-switch/saved_api_key
unset ANTHROPIC_API_KEY
```

The next `llm-cloud` will fall back to Keychain OAuth.

### Quick reference

| Env state before `llm-cloud` | After `llm-cloud` | Claude Code uses |
|---|---|---|
| OAuth in Keychain, no saved key file | nothing exported | Keychain OAuth |
| Saved key file exists | `ANTHROPIC_API_KEY` re-exported | API key |
| Neither | nothing exported | Auth will fail — run `claude login` |

## Caveats

- A smaller, local model behaves very differently from Claude — tool use, long
  context, and complex reasoning will be weaker.
- litellm drops unsupported parameters automatically (`drop_params: true`).
- **Don't resume cloud sessions that contain local-mode turns.** Local model
  responses can produce empty extended-thinking blocks that
  `api.anthropic.com` rejects with `400 messages.N.content.0.thinking: each
  thinking block must contain thinking`. Fix: run `/clear` in Claude Code, or
  pick a non-thinking model with `/model` before going local.
- Proxy logs: `~/.config/llm-switch/litellm.log`. Proxy PID: `~/.config/llm-switch/litellm.pid`.

## Recommended llama-server tunings

macOS limits the memory a single process can "wire" (lock into GPU/RAM). You
can safely raise this to give the model more headroom. Run before starting
the server:

```sh
sudo sysctl iogpu.wired_limit_mb=20000
# iogpu.wired_limit_mb: 0 -> 20000
```

This setting resets on reboot.
