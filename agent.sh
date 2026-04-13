#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/.agent-work}"
MAX_STEPS="${MAX_STEPS:-8}"
MAX_TOOL_OUTPUT_CHARS="${MAX_TOOL_OUTPUT_CHARS:-8000}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-5.4}"
OPENAI_API_BASE="${OPENAI_API_BASE:-https://api.openai.com/v1}"
AGENT_WORKDIR="${AGENT_WORKDIR:-$ROOT_DIR}"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env" # Load .env if it exists
  set +a
fi

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
require_cmd curl; require_cmd jq; require_cmd timeout # Local tools

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is not set. Put it in .env or export it before running." >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$AGENT_WORKDIR"


CHAT_HISTORY_JSON="$STATE_DIR/messages.json"
SYSTEM_PROMPT="$(cat <<EOF
You are a tiny Bash coding agent working inside $AGENT_WORKDIR.
You have exactly one tool: run_bash.
When the task is complete, answer briefly in plain text with no tool calls.
EOF
)"
TOOLS_JSON='[{"type":"function","function":{"name":"run_bash","description":"Run one short bash command in the working directory.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"],"additionalProperties":false}}}]'

append_to_chat_history() { # Add one message to chat history
  local new_message_json="$1"
  local temp_file="$(mktemp)"
  jq --slurpfile msg "$new_message_json" '. + $msg' "$CHAT_HISTORY_JSON" >"$temp_file"
  mv "$temp_file" "$CHAT_HISTORY_JSON"
}

truncate_text() {
  local text="$1" max_chars="$2" # Keep tool output small
  if (( ${#text} > max_chars )); then
    printf '%s\n[truncated to %s chars]' "${text:0:max_chars}" "$max_chars"
  else
    printf '%s' "$text"
  fi
}

is_blocked_command() { # Small safety guard for demo use
  case "$1" in
    *"rm -rf /"*|*"rm -rf ~"*|*"git reset --hard"*|*"curl http"*|*"curl https"*|*"wget http"*|*"wget https"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_bash_tool_json() { # Run the only local tool
  local command="$1" stdout_file stderr_file stdout_text stderr_text exit_code=0

  if is_blocked_command "$command"; then
    jq -n \
      --arg cwd "$AGENT_WORKDIR" \
      --arg command "$command" \
      '{
        cwd: $cwd,
        command: $command,
        exit_code: 126,
        blocked: true,
        stdout: "",
        stderr: "blocked by minimal safety guard"
      }'
    return
  fi

  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  
  set +e # A bad command should not kill the whole agent.
  (cd "$AGENT_WORKDIR" && timeout --foreground 10s bash -lc "$command") >"$stdout_file" 2>"$stderr_file"
  exit_code=$?
  set -e

  if [[ "$exit_code" == "124" ]]; then
    printf '\ncommand timed out after 10s\n' >>"$stderr_file"
  fi

  stdout_text="$(cat "$stdout_file")"
  stderr_text="$(cat "$stderr_file")"
  rm -f "$stdout_file" "$stderr_file"

  stdout_text="$(truncate_text "$stdout_text" "$MAX_TOOL_OUTPUT_CHARS")"
  stderr_text="$(truncate_text "$stderr_text" "$MAX_TOOL_OUTPUT_CHARS")"

  jq -n \
    --arg cwd "$AGENT_WORKDIR" \
    --arg command "$command" \
    --arg stdout "$stdout_text" \
    --arg stderr "$stderr_text" \
    --argjson exit_code "$exit_code" \
    '{
      cwd: $cwd,
      command: $command,
      exit_code: $exit_code,
      stdout: $stdout,
      stderr: $stderr
    }'
}

# Call the model once
call_model_once() {
  local step="$1" request_json="$STATE_DIR/step-$step-request.json" response_json="$STATE_DIR/step-$step-response.json"

  jq -n \
    --arg model "$OPENAI_MODEL" \
    --argjson messages "$(cat "$CHAT_HISTORY_JSON")" \
    --argjson tools "$TOOLS_JSON" \
    '{
      model: $model,
      messages: $messages,
      tools: $tools,
      tool_choice: "auto",
      parallel_tool_calls: false
    }' > "$request_json"

  curl -sS "$OPENAI_API_BASE/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$request_json" >"$response_json"

  if jq -e '.error' "$response_json" >/dev/null; then
    echo "OpenAI API error:" >&2
    jq '.error' "$response_json" >&2
    exit 1
  fi

  printf '%s\n' "$response_json"
}

main() {
  local user_task="${*:-}"
  local step=1

  if [[ -z "$user_task" ]]; then
    read -r -p "Enter prompt: " user_task
  fi

  # Start history with system + user
  jq -n --arg system "$SYSTEM_PROMPT" --arg task "$user_task" '[{"role":"system","content":$system},{"role":"user","content":$task}]' > "$CHAT_HISTORY_JSON"

  echo "Workdir: $AGENT_WORKDIR"
  echo "Model:   $OPENAI_MODEL"

  # Main loop
  while (( step <= MAX_STEPS )); do
    local response_json tool_call_count assistant_message_json

    echo
    echo "== step $step =="

    response_json="$(call_model_once "$step")"
    assistant_message_json="$(mktemp)"
    jq '.choices[0].message | {role, content, tool_calls}' "$response_json" >"$assistant_message_json"
    append_to_chat_history "$assistant_message_json"
    rm -f "$assistant_message_json"

    tool_call_count="$(jq '.choices[0].message.tool_calls | if . == null then 0 else length end' "$response_json")"

    if [[ "$tool_call_count" == "0" ]]; then
      echo "[final]"
      jq -r '.choices[0].message.content // ""' "$response_json"
      return 0
    fi

    local index=0
    while (( index < tool_call_count )); do
      local tool_id tool_name tool_args command_text tool_result tool_result_json tool_message_json

      tool_id="$(jq -r ".choices[0].message.tool_calls[$index].id" "$response_json")"
      tool_name="$(jq -r ".choices[0].message.tool_calls[$index].function.name" "$response_json")"
      tool_args="$(jq -r ".choices[0].message.tool_calls[$index].function.arguments" "$response_json")"

      [[ "$tool_name" == "run_bash" ]] || { echo "Unknown tool requested: $tool_name" >&2; exit 1; }

      command_text="$(jq -r '.command' <<<"$tool_args")"

      echo "[tool] $tool_name"
      echo "       $command_text"

      # Save tool output as a JSON message and send it back to the model.
      tool_result_json="$(mktemp)"
      tool_message_json="$(mktemp)"
      run_bash_tool_json "$command_text" >"$tool_result_json"
      tool_result="$(cat "$tool_result_json")"

      echo "[result]"
      jq -r '"exit_code=\(.exit_code) blocked=\(.blocked // false)"' "$tool_result_json"
      if [[ "$(jq -r '.stderr // ""' "$tool_result_json")" != "" ]]; then
        echo "[stderr]"
        jq -r '.stderr' "$tool_result_json"
      fi

      # Add tool output to history
      jq -n --arg tool_call_id "$tool_id" --arg content "$tool_result" '{role:"tool", tool_call_id:$tool_call_id, content:$content}' > "$tool_message_json"
      append_to_chat_history "$tool_message_json"
      rm -f "$tool_result_json" "$tool_message_json"

      index=$((index + 1))
    done

    step=$((step + 1))
  done

  echo "Stopped after MAX_STEPS=$MAX_STEPS without a final answer." >&2
  return 2
}

main "$@"
