# local-claude-code

Switch the [Claude Code](https://claude.ai/code) CLI between the Anthropic cloud
and a **fully local** LLM — without touching `~/.claude/settings.json` or
re-running `claude login`.

One environment variable (`ANTHROPIC_BASE_URL`) redirects Claude Code to a local
[litellm](https://github.com/BerriAI/litellm) proxy, which translates between
the Anthropic Messages API and the OpenAI-compatible API exposed by your local
model server.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   Claude Code  ──── POST /v1/messages ────▶  litellm proxy │
│   (claude CLI)       localhost:8082          port 8082      │
│        ▲                                        │           │
│        │                                 translates to      │
│   ANTHROPIC_BASE_URL                 /v1/chat/completions   │
│   =http://localhost:8082                        │           │
│                                        ┌────────▼────────┐  │
│                                        │  Local model    │  │
│                                        │  server :8081   │  │
│                                        │                 │  │
│                                        │  mlx_lm.server  │  │
│                                        │  (MLX / Metal)  │  │
│                                        │       or        │  │
│                                        │  llama-server   │  │
│                                        │  (llama.cpp)    │  │
│                                        └─────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

The litellm config maps `claude-*` model names to your local model, so Claude
Code's `--model` flag needs no changes.

## Prerequisites



- **Python 3.11+** — required by litellm (system Python on macOS is too old;
  install with `brew install python@3.11`)

- **litellm proxy** (v1.80.x recommended):
  ```sh
  pip3.11 install 'litellm[proxy]==1.80.15'
  ```
- **A local model server** — choose one:
  - [mlx-lm](https://github.com/ml-explore/mlx-examples/tree/main/llms) for
    Apple Silicon (fastest on Metal GPU):
    ```sh
    pip3 install 'mlx-lm>=0.25.2'
    ```
  - [llama.cpp](https://github.com/ggerganov/llama.cpp) for cross-platform GGUF
    support:
    ```sh
    brew install llama.cpp
    ```
- A completed `claude login` session (OAuth credentials) **or** an
  `ANTHROPIC_API_KEY` — needed for cloud mode.

## Setup

Clone the repo and source the switch script from your shell profile:

```sh
git clone https://github.com/your-username/local-claude-code.git
echo 'source ~/path/to/local-claude-code/llm-switch.sh' >> ~/.zshrc
source ~/.zshrc
```

## Local model server

### Option A — Apple Silicon (MLX, recommended)

Edit `mlx-server.sh` to set your model, then run it:

```sh
# mlx-server.sh
mlx_lm.server \
  --model mlx-community/Qwen3-14B-4bit \   # swap for any MLX model
  --host 127.0.0.1 \
  --port 8081
```

```sh
./mlx-server.sh
```

On first run, the model is downloaded from Hugging Face and cached locally.
Subsequent starts skip the download.

**Recommend using MLX models** on Apple Silicon, 16 GB+ unified memory.

### Option B — llama.cpp (cross-platform)

Edit `llama-server.sh` to set your model, then run it:

```sh
# llama-server.sh
llama-server \
  -m /path/to/your-model.gguf \
  --n-gpu-layers 999 \
  --ctx-size 32768 \
  --port 8081
```

```sh
./llama-server.sh
```

## Usage

Start the local model server first (in a separate terminal), then:

```sh
llm-local     # start litellm proxy, redirect Claude Code to local model
llm-cloud     # stop proxy, restore Anthropic cloud
llm-status    # show current mode, proxy state, and backend reachability
```

These commands are available in any shell that has sourced `llm-switch.sh`.
Changes take effect immediately — no need to restart Claude Code.

## How it works

`llm-local` sets a single environment variable:

```sh
ANTHROPIC_BASE_URL=http://localhost:8082
```

Claude Code reads this and sends all API requests to the litellm proxy instead
of `api.anthropic.com`. The proxy:

1. Receives `POST /v1/messages` (Anthropic Messages API)
2. Translates to `POST /v1/chat/completions` (OpenAI API)
3. Forwards to your local model server on port 8081
4. Translates the response back
5. Streams it to Claude Code

`llm-cloud` unsets `ANTHROPIC_BASE_URL`, and Claude Code falls back to its
normal cloud credentials (OAuth Keychain or `ANTHROPIC_API_KEY`).

## Authentication

Cloud mode supports two credential sources:

| Source | How to set up | `llm-status` reports |
|--------|--------------|----------------------|
| OAuth (default) | Run `claude login` | `Auth: OAuth credentials in Keychain` |
| API key | `export ANTHROPIC_API_KEY=sk-ant-…` | `Auth: ANTHROPIC_API_KEY (N chars)` |

`llm-local` saves your API key (if set) to `~/.config/llm-switch/saved_api_key`
(mode 0600) and restores it when you run `llm-cloud`, so switching modes never
loses your key.

## Configuration

The litellm config is written to `~/.config/llm-switch/litellm_config.yaml`
each time `llm-local` is run. It auto-detects the model name from the running
server. You can also edit it directly to tune `max_tokens`, timeouts, etc.

Key litellm settings used:

```yaml
litellm_settings:
  drop_params: true      # silently drop Anthropic-only params unsupported by OpenAI
  modify_params: true    # let litellm adjust params for the target backend
  request_timeout: 600   # long timeout for slow local inference

general_settings:
  disable_key_check: true  # skip auth validation for local-only use
```

## Logs

| File | Contents |
|------|----------|
| `~/.config/llm-switch/litellm.log` | litellm proxy stdout/stderr |
| `~/.config/llm-switch/litellm.pid` | proxy process ID |
| `~/.config/llm-switch/mlx-server.log` | mlx_lm.server stdout/stderr (if using mlx-server.sh) |

## Caveats

- **Local models are weaker than Claude.** Tool use, long context, and complex
  reasoning will be degraded compared to Claude
- **Don't resume cloud sessions that contain local-mode turns.** Local model
  responses can produce empty extended-thinking blocks that `api.anthropic.com`
  rejects with a `400` error. Run `/clear` in Claude Code before switching modes.
- **litellm version matters.** v1.83+ introduced an "experimental pass-through"
  that breaks local backends. Pin to v1.80.x: `pip3 install 'litellm[proxy]==1.80.15'`.
- **Context length.** Claude Code's system prompt is ~15k tokens. Set
  `--ctx-size` to at least `32768` on your model server.
