#!/usr/bin/env bash
# llm-switch.sh — Switch Claude Code between local llama.cpp and Anthropic cloud
#
# USAGE: source ./llm-switch.sh
# Then use: llm-local | llm-cloud | llm-status
#
# Requires litellm proxy to translate Anthropic API format → local OpenAI format.
# Install with: pip3 install 'litellm[proxy]'
#
# Auth model:
#   - LOCAL: sets ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN (bypasses OAuth path).
#   - CLOUD: unsets both, plus ANTHROPIC_API_KEY, so Claude Code falls back to
#            OAuth credentials in the macOS Keychain (the normal `claude login`
#            state). If you have a saved real ANTHROPIC_API_KEY, it's restored.

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

# Resolve the litellm CLI path, even if its install dir isn't on PATH.
_llm_litellm_bin() {
    if command -v litellm &>/dev/null; then
        command -v litellm
        return 0
    fi
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
    local model
    model="$(_llm_get_model)"
    if [[ -z "${model}" ]]; then
        echo "  Warning: could not detect model from llama-server — is it running?"
        model="unknown"
    fi
    mkdir -p "${_LLM_CONFIG_DIR}"
    cat > "${_LLM_LITELLM_CONFIG}" <<EOF
# litellm proxy config — routes any Claude model name to local llama.cpp
model_list:
  - model_name: "*"
    litellm_params:
      model: openai/${model}
      api_base: ${_LLM_LLAMA_BASE}/v1
      api_key: "dummy"
      extra_body:
        chat_template_kwargs:
          thinking: false

litellm_settings:
  drop_params: true
  set_verbose: false
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

# Returns the first model ID advertised by the live llama-server.
_llm_get_model() {
    curl -sf -m 2 "${_LLM_LLAMA_BASE}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null
}

_llm_start_proxy() {
    if ! _llm_backend_up; then
        echo "  Warning: llama-server not responding at ${_LLM_LLAMA_BASE}."
        echo "           Start it first (e.g. ./llama-server.sh) or local calls will fail."
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

# ── Public commands ─────────────────────────────────────────────────────────────
# In zsh, aliases shadow function definitions of the same name and cause a parse
# error. Clear any aliases before defining our functions.
unalias llm-local llm-cloud llm-status 2>/dev/null || true

llm-local() {
    _llm_ensure_litellm || return 1
    _llm_save_cloud_key

    if _llm_proxy_running; then
        echo "  litellm proxy already running."
    else
        _llm_start_proxy || return 1
    fi

    # Use ANTHROPIC_AUTH_TOKEN (Bearer header) — unambiguous for custom proxies
    # and won't collide with OAuth keychain creds. Clear ANTHROPIC_API_KEY so
    # there's no stale value floating around.
    export ANTHROPIC_BASE_URL="${_LLM_PROXY_URL}"
    export ANTHROPIC_AUTH_TOKEN="local-stub"
    unset ANTHROPIC_API_KEY

    echo ""
    echo "Switched to LOCAL mode"
    echo "  Model : $(_llm_get_model)"
    echo "  Proxy : ${_LLM_PROXY_URL} → ${_LLM_LLAMA_BASE}"
    echo "  Log   : ${_LLM_LOG_FILE}"
    echo ""
    echo "Run 'claude' to use Claude Code with the local model."
    echo "Run 'llm-cloud' to switch back."
}

llm-cloud() {
    _llm_stop_proxy

    # Wipe anything LOCAL set, then optionally restore a saved real key.
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY

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

llm-status() {
    echo ""
    if [[ "${ANTHROPIC_BASE_URL:-}" == "${_LLM_PROXY_URL}" ]]; then
        echo "Mode    : LOCAL  (via litellm proxy)"
        echo "Proxy   : ${_LLM_PROXY_URL}"
        echo "Backend : ${_LLM_LLAMA_BASE}"
        echo "Model   : $(_llm_get_model)"
        if _llm_proxy_running; then
            echo "Proxy   : running"
        else
            echo "Proxy   : NOT running (stale env — run llm-local or llm-cloud)"
        fi
        if _llm_backend_up; then
            echo "Backend : reachable"
        else
            echo "Backend : NOT reachable at ${_LLM_LLAMA_BASE}"
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
else
    echo "llm-switch loaded. Commands: llm-local | llm-cloud | llm-status"
fi
