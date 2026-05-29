#!/usr/bin/env bash
# test_llm_switch.sh — Tests llm-switch.sh: mode switching, proxy health, inference round-trip.
#
# Safe to run:
#   - Restores your original mode (local OR cloud) on exit.
#   - Uses max_tokens=8 for inference so it can't OOM or GPU-timeout.
#   - Does NOT force llm-cloud on exit.
#
# Usage:  ./test_llm_switch.sh
# Requires: mlx-server.sh (or llama-server.sh) already running on :8081.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWITCH_SCRIPT="${SCRIPT_DIR}/llm-switch.sh"
PROXY_URL="http://localhost:8082"
BACKEND_URL="http://localhost:8081"

PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────
pass()    { echo "  ✓ $*"; (( PASS++ )) || true; }
fail()    { echo "  ✗ $*" >&2; (( FAIL++ )) || true; }
section() { echo -e "\n── $* $(printf '%.0s─' {1..50})" | head -c 60; echo; }

# ── Preserve original mode; restore it on exit ───────────────────────────────
_SAVED_BASE_URL="${ANTHROPIC_BASE_URL:-}"

_restore() {
    if [[ -n "${_SAVED_BASE_URL}" ]]; then
        export ANTHROPIC_BASE_URL="${_SAVED_BASE_URL}"
        echo -e "\n(Restored: ANTHROPIC_BASE_URL=${_SAVED_BASE_URL})"
    else
        unset ANTHROPIC_BASE_URL 2>/dev/null || true
        echo -e "\n(Restored: ANTHROPIC_BASE_URL unset — cloud mode)"
    fi
}
trap _restore EXIT

# ── Source llm-switch.sh so internal functions are available ─────────────────
if [[ ! -f "${LLM_SWITCH_SCRIPT}" ]]; then
    echo "Error: ${LLM_SWITCH_SCRIPT} not found." >&2
    exit 1
fi
# shellcheck source=./llm-switch.sh
source "${LLM_SWITCH_SCRIPT}"

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
section "1. Prerequisites"

[[ -x "${LLM_SWITCH_SCRIPT}" ]] \
    && pass "llm-switch.sh is executable" \
    || fail "llm-switch.sh not executable — run: chmod +x llm-switch.sh"

command -v curl &>/dev/null \
    && pass "curl found" \
    || fail "curl not found"

command -v jq &>/dev/null \
    && pass "jq found" \
    || { fail "jq not found — install: brew install jq"; exit 1; }

_litellm="$(_llm_litellm_bin 2>/dev/null || true)"
[[ -n "${_litellm}" ]] \
    && pass "litellm found: ${_litellm}" \
    || fail "litellm not found — install: pip3 install 'litellm[proxy]'"

# ── 2. Backend (model server) ─────────────────────────────────────────────────
section "2. Model server (port 8081)"

if _llm_backend_up; then
    _model="$(_llm_get_model)"
    pass "Model server responding — active model: ${_model:-<unknown>}"
else
    fail "Model server NOT responding at ${BACKEND_URL}"
    echo "     Start it first:  ./mlx-server.sh  (or ./llama-server.sh)"
    echo "     Cannot test local inference without it."
    exit 1
fi

# ── 3. llm-local: env var ─────────────────────────────────────────────────────
section "3. llm-local — env var check"

_llm_local_impl

if [[ "${ANTHROPIC_BASE_URL:-}" == "${PROXY_URL}" ]]; then
    pass "ANTHROPIC_BASE_URL → ${PROXY_URL}"
else
    fail "ANTHROPIC_BASE_URL not set correctly: '${ANTHROPIC_BASE_URL:-<unset>}'"
fi

# ── 4. Proxy health ───────────────────────────────────────────────────────────
section "4. Proxy health (port 8082)"

if curl -sf -m 5 "${PROXY_URL}/health" &>/dev/null \
   || curl -sf -m 5 "${PROXY_URL}/v1/models" &>/dev/null; then
    pass "Proxy responding at ${PROXY_URL}"
else
    fail "Proxy not responding at ${PROXY_URL}"
    echo "     Check log: ~/.config/llm-switch/litellm.log"
fi

# ── 5. Minimal inference round-trip (local) ───────────────────────────────────
section "5. Local inference (max_tokens=8 — tiny, safe)"

# Anthropic /v1/messages format — exactly what Claude Code sends.
# max_tokens=8: returns one or two words; won't stress the GPU.
# claude-3-5-sonnet-20241022: matches the claude-* route in litellm config.
_RESPONSE=$(curl -sf -m 60 -X POST "${PROXY_URL}/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: dummy" \
    -H "anthropic-version: 2023-06-01" \
    -d '{
        "model": "claude-3-5-sonnet-20241022",
        "max_tokens": 8,
        "messages": [{"role": "user", "content": "Say: hello"}]
    }' 2>&1) || _RESPONSE="<curl failed>"

if echo "${_RESPONSE}" | jq -e '.content[0].text' &>/dev/null; then
    _TEXT=$(echo "${_RESPONSE}" | jq -r '.content[0].text')
    pass "Got response: \"${_TEXT}\""
elif echo "${_RESPONSE}" | jq -e '.error' &>/dev/null; then
    _ERR=$(echo "${_RESPONSE}" | jq -r '.error.message // .error')
    fail "API error: ${_ERR}"
    echo "     Full response: ${_RESPONSE}"
else
    fail "Unexpected response (no .content[0].text and no .error)"
    echo "     Response: ${_RESPONSE}"
fi

# ── 6. llm-cloud: env var ─────────────────────────────────────────────────────
section "6. llm-cloud — env var check"

_llm_cloud_impl

if [[ -z "${ANTHROPIC_BASE_URL:-}" ]]; then
    pass "ANTHROPIC_BASE_URL unset — cloud mode active"
else
    fail "ANTHROPIC_BASE_URL still set: '${ANTHROPIC_BASE_URL}'"
fi

# ── 7. llm-status output ──────────────────────────────────────────────────────
section "7. llm-status — smoke tests"

# Verify LOCAL detection
export ANTHROPIC_BASE_URL="${PROXY_URL}"
_STATUS=$(_llm_status_impl 2>&1)
echo "${_STATUS}" | grep -q "LOCAL" \
    && pass "llm-status reports LOCAL when ANTHROPIC_BASE_URL=${PROXY_URL}" \
    || fail "llm-status did not report LOCAL"

# Verify CLOUD detection
unset ANTHROPIC_BASE_URL
_STATUS=$(_llm_status_impl 2>&1)
echo "${_STATUS}" | grep -q "CLOUD" \
    && pass "llm-status reports CLOUD when ANTHROPIC_BASE_URL unset" \
    || fail "llm-status did not report CLOUD"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n════════════════════════════════════════"
echo "  Passed: ${PASS}   Failed: ${FAIL}"
echo "════════════════════════════════════════"

(( FAIL == 0 )) && echo "All tests passed." || { echo "Some tests failed."; exit 1; }
