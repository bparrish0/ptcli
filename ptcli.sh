#!/usr/bin/env bash
# ptcli.sh -- Parrish Technology CLI
# Query llama-server to get shell commands from natural language descriptions

API_KEY="3-26API"
API_URL="http://ai.parrish.biz:56767/v1/chat/completions"

# Colors
if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_CYAN="\033[36m"
    C_YELLOW="\033[33m"
    C_GREEN="\033[32m"
    C_RED="\033[31m"
    C_DIM="\033[2m"
    C_MAGENTA="\033[35m"
else
    C_RESET="" C_BOLD="" C_CYAN="" C_YELLOW="" C_GREEN="" C_RED="" C_DIM="" C_MAGENTA=""
fi

# Check dependencies
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${C_RED}Error:${C_RESET} $cmd is required but not installed." >&2
        exit 1
    fi
done

# Parse -explain flag from anywhere in args
EXPLAIN=0
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "-explain" ] || [ "$arg" = "-e" ]; then
        EXPLAIN=1
    else
        ARGS+=("$arg")
    fi
done

QUERY="${ARGS[*]}"
if [ -z "$QUERY" ]; then
    echo -e "${C_CYAN}${C_BOLD}ptcli${C_RESET} -- Parrish Technology CLI"
    echo ""
    echo -e "${C_BOLD}Usage:${C_RESET} ptcli.sh [-e|-explain] <describe what you want to do>"
    echo ""
    echo -e "${C_BOLD}Options:${C_RESET}"
    echo -e "  ${C_YELLOW}-e, -explain${C_RESET}    Show what the command and each argument does"
    echo ""
    echo -e "${C_BOLD}Examples:${C_RESET}"
    echo -e "  ${C_DIM}\$${C_RESET} ptcli.sh Find the recording.mp3 file somewhere on this system"
    echo -e "  ${C_DIM}\$${C_RESET} ptcli.sh -explain Find all large files over 1GB"
    exit 1
fi

# Gather system info
SYS_OS="$(uname -s)"
SYS_ARCH="$(uname -m)"
SYS_KERNEL="$(uname -r)"
if [ "$SYS_OS" = "Darwin" ]; then
    SYS_DISTRO="macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
elif [ -f /etc/os-release ]; then
    SYS_DISTRO="$(. /etc/os-release && echo "$PRETTY_NAME")"
else
    SYS_DISTRO="unknown"
fi

# Editable prompt helper -- macOS bash 3.2 doesn't support read -i
prompt_editable() {
    local default="$1"
    if [ "$SYS_OS" = "Darwin" ] && [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        echo -e "  ${C_DIM}(press Enter to accept, or type a modified command)${C_RESET}"
        echo -e "  ${C_BOLD}$default${C_RESET}"
        read -e -p "$ " FINAL_CMD
        if [ -z "$FINAL_CMD" ]; then
            FINAL_CMD="$default"
        fi
    else
        read -e -i "$default" -p "$ " FINAL_CMD
    fi
}
SYS_SHELL="$(basename "$SHELL")"
SYS_PVE=""
if command -v pveversion &>/dev/null; then
    SYS_PVE="$(pveversion 2>/dev/null)"
fi

SYS_INFO="OS=$SYS_OS, Arch=$SYS_ARCH, Kernel=$SYS_KERNEL, Distro=$SYS_DISTRO, Shell=$SYS_SHELL"
if [ -n "$SYS_PVE" ]; then
    SYS_INFO="$SYS_INFO, Proxmox=$SYS_PVE"
fi

SYSTEM_PROMPT="You are a command-line assistant. The user's system: $SYS_INFO.

CRITICAL RULES -- you MUST follow these exactly:
- Your response must be ONLY one of the two formats below. Nothing else.
- NEVER use markdown. NEVER use backticks. NEVER add explanations or commentary.
- Do NOT wrap your response in a code block.

FORMAT 1 - You have enough information to provide the command:
Output ONLY the raw shell command on a single line. Nothing before or after it.
Example: ps aux --sort=-%mem | head -10

FORMAT 2 - You need more information from the system first:
Output ONLY this JSON with no other text:
{\"need_info\": \"reason\", \"commands\": [\"cmd1\", \"cmd2\"]}
Keep commands read-only and safe. You may request info multiple times."

EXPLAIN_PROMPT="You are a command-line assistant. The user's system: $SYS_INFO.

CRITICAL RULES -- you MUST follow these exactly:
- Your response must be ONLY valid JSON. Nothing else.
- NEVER use markdown. NEVER use backticks. NEVER add text outside the JSON.
- Do NOT wrap your response in a code block.

FORMAT 1 - You have enough information to provide the command:
Output ONLY this JSON:
{\"command\": \"the full shell command\", \"explain\": \"one sentence description\", \"args\": [{\"arg\": \"part\", \"desc\": \"what it does\"}]}
Include every meaningful part -- base command, flags, paths, pipes, redirects.

FORMAT 2 - You need more information from the system first:
Output ONLY this JSON:
{\"need_info\": \"reason\", \"commands\": [\"cmd1\", \"cmd2\"]}
Keep commands read-only and safe. You may request info multiple times."

if [ "$EXPLAIN" -eq 1 ]; then
    ACTIVE_PROMPT="$EXPLAIN_PROMPT"
else
    ACTIVE_PROMPT="$SYSTEM_PROMPT"
fi

# Build initial messages array
MESSAGES=$(jq -n \
    --arg sys "$ACTIVE_PROMPT" \
    --arg usr "$QUERY" \
    '[
        {"role": "system", "content": $sys},
        {"role": "user", "content": $usr}
    ]')

echo -e "${C_DIM}Thinking...${C_RESET}"

while true; do
    PAYLOAD=$(jq -n \
        --argjson msgs "$MESSAGES" \
        '{
            "messages": $msgs,
            "temperature": 0.1
        }')

    RESPONSE=$(curl -s --max-time 30 "$API_URL" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    CURL_EXIT=$?
    if [ $CURL_EXIT -ne 0 ]; then
        echo -e "${C_RED}Error:${C_RESET} Failed to connect to $API_URL - curl exit code: $CURL_EXIT" >&2
        exit 1
    fi

    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$ERROR" ]; then
        echo -e "${C_RED}Error from API:${C_RESET} $ERROR" >&2
        exit 1
    fi

    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    # Strip markdown code fences if the LLM wrapped its response
    CONTENT=$(echo "$CONTENT" | sed '/^```[a-z]*$/d' | sed '/^```$/d')
    # Trim leading/trailing whitespace
    CONTENT=$(echo "$CONTENT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [ -z "$CONTENT" ]; then
        echo -e "${C_RED}Error:${C_RESET} No response from API." >&2
        echo -e "${C_DIM}Raw response: $RESPONSE${C_RESET}" >&2
        exit 1
    fi

    # Check if the LLM is requesting more information
    NEED_INFO=$(echo "$CONTENT" | jq -r '.need_info // empty' 2>/dev/null)

    if [ -z "$NEED_INFO" ]; then
        if [ "$EXPLAIN" -eq 1 ]; then
            # Parse explain JSON response
            ECMD=$(echo "$CONTENT" | jq -r '.command // empty' 2>/dev/null)
            EDESC=$(echo "$CONTENT" | jq -r '.explain // empty' 2>/dev/null)

            if [ -n "$ECMD" ] && [ -n "$EDESC" ]; then
                echo ""
                echo -e "${C_BOLD}${C_GREEN}Command:${C_RESET} ${C_BOLD}$ECMD${C_RESET}"
                echo ""
                echo -e "${C_CYAN}$EDESC${C_RESET}"
                echo ""
                echo -e "${C_YELLOW}${C_BOLD}Breakdown:${C_RESET}"
                ARG_COUNT=$(echo "$CONTENT" | jq -r '.args | length' 2>/dev/null)
                for i in $(seq 0 $((ARG_COUNT - 1))); do
                    ARG=$(echo "$CONTENT" | jq -r ".args[$i].arg" 2>/dev/null)
                    DESC=$(echo "$CONTENT" | jq -r ".args[$i].desc" 2>/dev/null)
                    echo -e "  ${C_MAGENTA}${C_BOLD}$ARG${C_RESET} ${C_DIM}--${C_RESET} $DESC"
                done
                echo ""
                prompt_editable "$ECMD"
                eval "$FINAL_CMD"
            else
                # Fallback if LLM didn't return proper JSON
                prompt_editable "$CONTENT"
                eval "$FINAL_CMD"
            fi
        else
            # Normal mode: present command directly
            prompt_editable "$CONTENT"
            eval "$FINAL_CMD"
        fi
        exit 0
    fi

    # MODE 2: LLM needs more info
    echo ""
    echo -e "${C_YELLOW}${C_BOLD}Info needed:${C_RESET} $NEED_INFO"
    echo ""
    echo -e "${C_BOLD}Commands to run:${C_RESET}"

    CMDS_JSON=$(echo "$CONTENT" | jq -r '.commands')
    CMD_COUNT=$(echo "$CMDS_JSON" | jq -r 'length')

    for i in $(seq 0 $((CMD_COUNT - 1))); do
        CMD_ITEM=$(echo "$CMDS_JSON" | jq -r ".[$i]")
        echo -e "  ${C_CYAN}$((i + 1)).${C_RESET} ${C_BOLD}$CMD_ITEM${C_RESET}"
    done

    echo ""
    read -p "$(echo -e "${C_GREEN}Allow these commands?${C_RESET} [Y/n] ")" CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo -e "${C_YELLOW}Cancelled.${C_RESET}"
        exit 0
    fi

    # Run each command and collect output
    CMD_OUTPUT=""
    for i in $(seq 0 $((CMD_COUNT - 1))); do
        CMD_ITEM=$(echo "$CMDS_JSON" | jq -r ".[$i]")
        echo -e "${C_DIM}Running: $CMD_ITEM${C_RESET}"
        RESULT=$(eval "$CMD_ITEM" 2>&1)
        CMD_OUTPUT="${CMD_OUTPUT}Command: ${CMD_ITEM}
Output:
${RESULT}

"
    done

    echo -e "${C_DIM}Thinking...${C_RESET}"

    # Append assistant message and user response with command output to conversation
    MESSAGES=$(echo "$MESSAGES" | jq \
        --arg assistant "$CONTENT" \
        --arg info "$CMD_OUTPUT" \
        '. + [
            {"role": "assistant", "content": $assistant},
            {"role": "user", "content": $info}
        ]')
done
