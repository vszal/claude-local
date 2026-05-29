#!/usr/bin/env bash
# llm-switch.sh — Switch Claude Code between a local model and Anthropic cloud
#
# USAGE: source ./llm-switch.sh
# Then use: llm-local | llm-cloud | llm-status
#
# LOCAL backend: mlx_lm.server or llama-server (port 8081) → litellm proxy (port 8082)
#   litellm translates Anthropic /v1/messages → OpenAI /v1/chat/completions.
#   Start the model server first: ./mlx-server.sh  (or ./llama-server.sh)
#
# Auth model:
#   - LOCAL: sets ANTHROPIC_BASE_URL to the litellm proxy. Claude Code uses its
#            existing Keychain OAuth; litellm ignores auth (disable_key_check: true).
#   - CLOUD: unsets ANTHROPIC_BASE_URL, so Claude Code falls back to OAuth
#            credentials in the macOS Keychain (the normal `claude login` state).
#            If you have a saved real ANTHROPIC_API_KEY, it's restored.

# Capture own path when sourced so public wrappers can auto-reload.
# BASH_SOURCE[0] works in bash; ${(%):-%x} is the zsh equivalent.
_LLM_SWITCH_PATH="${BASH_SOURCE[0]:-${(%):-%x}}"

# ── Config ─────────────────────────────────────────────────────────────────────
_LLM_LLAMA_BASE="http://localhost:8081"
_LLM_PROXY_PORT=8082
_LLM_PROXY_URL="http://localhost:${_LLM_PROXY_PORT}"
_LLM_CONFIG_DIR="${HOME}/.config/llm-switch"
_LLM_PID_FILE="${_LLM_CONFIG_DIR}/litellm.pid"
_LLM_LOG_FILE="${_LLM_CONFIG_DIR}/litellm.log"
_LLM_LITELLM_CONFIG="${_LLM_CONFIG_DIR}/litellm_config.yaml"
_LLM_SAVED_KEY_FILE="${_LLM_CONFIG_DIR}/saved_api_key"
# ───────────────────────────────────────────────────────────────────────────────

# Resolve the litellm CLI path, preferring Homebrew Python 3.11 install.
_llm_litellm_bin() {
    # Prefer Homebrew litellm (requires Python 3.11 — system Python 3.9 too old)
    local brew_litellm="/opt/homebrew/bin/litellm"
    if [[ -x "${brew_litellm}" ]]; then
        echo "${brew_litellm}"
        return 0
    fi
    # Fallback: litellm on PATH
    if command -v litellm &>/dev/null; then
        command -v litellm
        return 0
    fi
    # Fallback: user site-packages
    local user_base
    user_base=$(python3 -m site --user-base 2>/dev/null)
    if [[ -n "${user_base}" && -x "${user_base}/bin/litellm" ]]; then
        echo "${user_base}/bin/litellm"
        return 0
    fi
    return 1
}

_llm_ensure_litellm() {
    if [[ -z "$(_llm_litellm_bin)" ]]; then
        echo "  litellm not found. Install with: pip3 install 'litellm[proxy]'"
        return 1
    fi
    return 0
}

_llm_write_config() {
    local model i=0
    # Retry up to 5s — server may still be starting when llm-local is first called.
    while (( i < 10 )); do
        model="$(_llm_get_model)"
        [[ -n "${model}" ]] && break
        sleep 0.5
        (( i++ ))
    done
    if [[ -z "${model}" ]]; then
        echo "  Error: could not detect model from model server — is it running?"
        echo "         Start ./mlx-server.sh (or ./llama-server.sh) first, then re-run llm-local."
        return 1
    fi
    mkdir -p "${_LLM_CONFIG_DIR}"
    cat > "${_LLM_LITELLM_CONFIG}" <<EOF
# litellm proxy config — routes any Claude model name to local MLX backend
model_list:
  - model_name: "claude-*"
    litellm_params:
      model: hosted_vllm/${model}
      api_base: ${_LLM_LLAMA_BASE}/v1
      api_key: "dummy"
    model_info:
      max_tokens: 32768
      max_input_tokens: 28672
      max_output_tokens: 4096

litellm_settings:
  drop_params: true
  modify_params: true
  set_verbose: false
  request_timeout: 600

general_settings:
  disable_key_check: true
EOF
}

# True if the PID file points at a live process OR something is bound to :PORT.
_llm_proxy_running() {
    if [[ -f "${_LLM_PID_FILE}" ]] && kill -0 "$(cat "${_LLM_PID_FILE}")" 2>/dev/null; then
        return 0
    fi
    lsof -ti ":${_LLM_PROXY_PORT}" &>/dev/null
}

_llm_backend_up() {
    curl -sf -m 2 "${_LLM_LLAMA_BASE}/v1/models" &>/dev/null
}

# Returns the model currently loaded by the running model server.
# mlx_lm.server v0.31+ lists ALL cached models via /v1/models, not just the
# active one — so we read the --model flag from the server process instead.
# Falls back to the API first entry (correct for llama-server).
_llm_get_model() {
    # Primary: parse --model from the live process command line
    local active
    active=$(ps aux | grep -E '[m]lx_lm\.server|[l]lama-server' \
        | grep -- '--model' \
        | sed 's/.*--model //' | awk '{print $1}')
    if [[ -n "${active}" ]]; then
        echo "${active}"
        return 0
    fi
    # Fallback: API (works correctly for llama-server single-model responses)
    curl -sf -m 2 "${_LLM_LLAMA_BASE}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null
}

_llm_start_proxy() {
    if ! _llm_backend_up; then
        echo "  Warning: model server not responding at ${_LLM_LLAMA_BASE}."
        echo "           Start it first (e.g. ./mlx-server.sh) or local calls will fail."
    fi

    if lsof -ti ":${_LLM_PROXY_PORT}" &>/dev/null; then
        echo "  Port ${_LLM_PROXY_PORT} already in use — assuming proxy is up."
        return 0
    fi

    _llm_write_config

    local litellm_cmd
    litellm_cmd="$(_llm_litellm_bin)"
    [[ -z "${litellm_cmd}" ]] && return 1

    echo "  Starting litellm proxy on port ${_LLM_PROXY_PORT}..."
    nohup "${litellm_cmd}" \
        --config "${_LLM_LITELLM_CONFIG}" \
        --port "${_LLM_PROXY_PORT}" \
        > "${_LLM_LOG_FILE}" 2>&1 &
    echo $! > "${_LLM_PID_FILE}"

    # Wait up to 8s for the proxy to be ready
    local i=0
    while (( i < 16 )); do
        if curl -sf -m 1 "${_LLM_PROXY_URL}/health" &>/dev/null || \
           curl -sf -m 1 "${_LLM_PROXY_URL}/v1/models" &>/dev/null; then
            echo "  Proxy ready."
            return 0
        fi
        sleep 0.5
        (( i++ ))
    done
    echo "  Warning: proxy did not respond within 8s. Check log: ${_LLM_LOG_FILE}"
    return 1
}

_llm_stop_proxy() {
    local stopped=0
    if [[ -f "${_LLM_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${_LLM_PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null
            stopped=1
        fi
        rm -f "${_LLM_PID_FILE}"
    fi
    # Also catch orphans bound to the port.
    for p in $(lsof -ti ":${_LLM_PROXY_PORT}" 2>/dev/null); do
        kill "${p}" 2>/dev/null
        stopped=1
    done
    (( stopped )) && echo "  Stopped litellm proxy on :${_LLM_PROXY_PORT}."
    return 0
}

# True if OAuth credentials exist in the macOS Keychain (typical `claude login`).
_llm_has_keychain_creds() {
    [[ "$(uname)" == "Darwin" ]] || return 1
    security find-generic-password -s "Claude Code-credentials" -a "${USER}" &>/dev/null
}

_llm_save_cloud_key() {
    # Persist a real Anthropic key so we can restore it later.
    # Skip empty strings and our own local stubs.
    if [[ -n "${ANTHROPIC_API_KEY:-}" && "${ANTHROPIC_API_KEY}" != "local-stub" ]]; then
        mkdir -p "${_LLM_CONFIG_DIR}"
        printf '%s' "${ANTHROPIC_API_KEY}" > "${_LLM_SAVED_KEY_FILE}"
        chmod 600 "${_LLM_SAVED_KEY_FILE}"
    fi
}

# ── Implementations ────────────────────────────────────────────────────────────
# Named _impl so the public wrappers below can re-source this file (getting
# fresh definitions) and then delegate — auto-reload without circular aliases.

_llm_local_impl() {
    _llm_ensure_litellm || return 1
    _llm_save_cloud_key

    if _llm_proxy_running; then
        echo "  litellm proxy already running."
    else
        _llm_start_proxy || return 1
    fi

    # Only set ANTHROPIC_BASE_URL — litellm ignores auth (disable_key_check: true),
    # so no stub API key needed. Avoids conflict with Keychain OAuth credentials.
    export ANTHROPIC_BASE_URL="${_LLM_PROXY_URL}"
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_MODEL CLAUDE_SMALL_MODEL CLAUDE_LARGE_MODEL

    echo ""
    echo "Switched to LOCAL mode"
    echo "  Model  : $(_llm_get_model)"
    echo "  Proxy  : ${_LLM_PROXY_URL} → ${_LLM_LLAMA_BASE}"
    echo "  Log    : ${_LLM_LOG_FILE}"
    echo ""
    echo "Run 'claude' to use Claude Code with the local model."
    echo "Run 'llm-cloud' to switch back."
}

_llm_cloud_impl() {
    _llm_stop_proxy

    # Wipe anything LOCAL set, then optionally restore a saved real key.
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
    unset CLAUDE_MODEL CLAUDE_SMALL_MODEL CLAUDE_LARGE_MODEL

    if [[ -f "${_LLM_SAVED_KEY_FILE}" ]]; then
        export ANTHROPIC_API_KEY="$(cat "${_LLM_SAVED_KEY_FILE}")"
    fi

    echo ""
    echo "Switched to CLOUD mode"
    echo "  Endpoint : Anthropic default (api.anthropic.com)"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        echo "  Auth     : ANTHROPIC_API_KEY (${#ANTHROPIC_API_KEY} chars, ${ANTHROPIC_API_KEY:0:12}…)"
    elif _llm_has_keychain_creds; then
        echo "  Auth     : OAuth credentials in Keychain (from 'claude login')"
    else
        echo "  Auth     : NONE — run 'claude login' or export ANTHROPIC_API_KEY."
    fi
    echo ""
}

_llm_status_impl() {
    echo ""
    if [[ "${ANTHROPIC_BASE_URL:-}" == "${_LLM_PROXY_URL}" ]]; then
        echo "Mode    : LOCAL  (litellm proxy → model server)"
        echo "Proxy   : ${_LLM_PROXY_URL}"
        echo "Backend : ${_LLM_LLAMA_BASE}"
        echo "Model   : $(_llm_get_model)"
        if _llm_backend_up; then
            echo "Backend : reachable"
        else
            echo "Backend : NOT reachable — start ./mlx-server.sh (or ./llama-server.sh)"
        fi
    elif [[ -z "${ANTHROPIC_BASE_URL:-}" || "${ANTHROPIC_BASE_URL}" == "https://api.anthropic.com" ]]; then
        echo "Mode    : CLOUD  (Anthropic)"
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
            echo "Auth    : ANTHROPIC_API_KEY (${#ANTHROPIC_API_KEY} chars)"
        elif _llm_has_keychain_creds; then
            echo "Auth    : OAuth credentials in Keychain"
        else
            echo "Auth    : NONE"
        fi
    else
        echo "Mode    : CUSTOM"
        echo "Base URL: ${ANTHROPIC_BASE_URL}"
        [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && echo "Auth    : ANTHROPIC_AUTH_TOKEN set"
        [[ -n "${ANTHROPIC_API_KEY:-}"   ]] && echo "Auth    : ANTHROPIC_API_KEY set (${#ANTHROPIC_API_KEY} chars)"
    fi
    echo ""
}

# ── Public wrappers ─────────────────────────────────────────────────────────────
# Re-source the script on every call so edits take effect immediately without
# needing to open a new shell. The _impl functions above carry the real logic;
# sourcing redefines them, then we delegate.
#
# In zsh, aliases shadow function definitions of the same name and cause a parse
# error. Clear any aliases before defining our functions.
unalias llm-local llm-cloud llm-status 2>/dev/null || true

llm-local()  { source "${_LLM_SWITCH_PATH}"; _llm_local_impl  "$@"; }
llm-cloud()  { source "${_LLM_SWITCH_PATH}"; _llm_cloud_impl  "$@"; }
llm-status() { source "${_LLM_SWITCH_PATH}"; _llm_status_impl "$@"; }

# ── Direct execution ────────────────────────────────────────────────────────────
# When executed directly (not sourced), dispatch the argument as a command.
# Note: llm-local / llm-cloud export env vars — those only persist when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    case "${cmd}" in
        llm-local|llm-cloud|llm-status)
            if [[ "${cmd}" != "llm-status" ]]; then
                echo "Warning: env var changes won't persist when run as a script."
                echo "  Use: source $(dirname "$0")/llm-switch.sh && ${cmd}"
            fi
            "${cmd}"
            ;;
        "")
            echo "Usage: llm-switch.sh [llm-local|llm-cloud|llm-status]"
            echo "Or source this file and call commands directly."
            ;;
        *)
            echo "Unknown command: ${cmd}"
            echo "Valid commands: llm-local | llm-cloud | llm-status"
            exit 1
            ;;
    esac
elif [[ -z "${_LLM_SWITCH_LOADED:-}" ]]; then
    # Only print the banner on the initial source, not on every auto-reload.
    export _LLM_SWITCH_LOADED=1
    echo "llm-switch loaded. Commands: llm-local | llm-cloud | llm-status"
fi
