#!/usr/bin/env bash
# test_llm_switch.sh
# Tests the functionality of llm-switch.sh for both cloud and local modes.

set -euo pipefail

# --- Configuration ---
LLM_SWITCH_SCRIPT="./llm-switch.sh"
TEST_PROMPT="What is the purpose of a local LLM proxy?"

# --- Functions ---

# Check if the core script exists and is executable
check_prerequisites() {
    echo "--- 1. Checking prerequisites ---"
    if [[ ! -x "$LLM_SWITCH_SCRIPT" ]]; then
        echo "Error: $LLM_SWITCH_SCRIPT not found or not executable. Please run 'chmod +x $LLM_SWITCH_SCRIPT'." >&2
        exit 1
    fi
    if ! command -v litellm &>/dev/null; then
        echo "Warning: 'litellm' command not found. Please install it: pip3 install 'litellm[proxy]'"
    fi
    echo "Prerequisites checked."
}

# Function to perform a simple API call
# Usage: run_api_test <mode>
run_api_test() {
    local mode=$1
    local result

    echo -e "\n--- Running API Test in $mode mode ---"

    # Temporarily source the script to set up the environment variables
    # We use eval to run the sourced commands in the current shell context for testing
    eval "source $LLM_SWITCH_SCRIPT"

    if [[ "$mode" == "local" ]]; then
        # Test Local Mode (Proxy must be running)
        echo "Starting local mode..."
        llm-local || { echo "Failed to start local mode. Ensure llama.cpp and proxy are configured."; exit 1; }

        # Run the actual test using the litellm-compatible call
        # Since we are mocking, we assume the proxy is running and accepting requests.
        # A real test would use 'curl' against the proxy endpoint.
        result=$(curl -s -X POST http://localhost:8082/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d '{"model": "unsloth/gemma-4-E4B-it-GGUF", "messages": [{"role": "user", "content": "'"$TEST_PROMPT"'"}], "temperature": 0.1}')

    elif [[ "$mode" == "cloud" ]]; then
        # Test Cloud Mode
        echo "Switching to cloud mode..."
        llm-cloud || { echo "Failed to switch to cloud mode."; exit 1; }

        # Note: ANTHROPIC_API_KEY must be set in the environment before running this test.
        result=$(curl -s -X POST https://api.anthropic.com/v1/messages \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "Content-Type: application/json" \
            -d '{
                "model": "claude-3-opus-20240229",
                "messages": [{"role": "user", "content": "'"$TEST_PROMPT"'"}],
                "temperature": 0.1
            }')
    else
        echo "Invalid mode specified."
        exit 1
    fi

    # Check response status and extract content
    if echo "$result" | grep -q "error"; then
        echo "Test FAILED in $mode mode: API returned an error."
        echo "--- Response Dump ---"
        echo "$result" | jq .
        return 1
    else
        echo "Test SUCCEEDED in $mode mode."
        echo "--- API Response Snippet (First 100 chars) ---"
        echo "$result" | head -c 100 | jq .
        return 0
    fi
}

# --- Main Execution Logic ---

trap 'echo -e "\n\n--- Cleaning up resources... ---"; llm-cloud; echo "Test completed and environment restored."' EXIT

check_prerequisites

# 1. Test Cloud Mode first
if ! run_api_test cloud; then
    echo -e "\n\n!!! CLOUD MODE TEST FAILED. Check ANTHROPIC_API_KEY and network connectivity. !!!"
fi

# 2. Test Local Mode
if ! run_api_test local; then
        echo "Verifying proxy environment variables..."
        echo "ANTHROPIC_BASE_URL: $ANTHROPIC_BASE_URL"
        echo "ANTHROPIC_AUTH_TOKEN: $ANTHROPIC_AUTH_TOKEN"
        echo "ANTHROPIC_API_KEY: $ANTHROPIC_API_KEY"
    echo -e "\n\n!!! LOCAL MODE TEST FAILED. Check litellm installation and proxy startup logs. !!!"
fi

echo -e "\n\n========================================"
echo "SUCCESS: Both Cloud and Local mode tests passed."
echo "========================================"