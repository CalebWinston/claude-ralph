#!/bin/bash
# Claude Ralph - Autonomous AI agent loop using Claude CLI
# Runs Claude repeatedly until all PRD items are complete
# Usage: ./claude-ralph.sh [options]
#
# Options:
#   -n, --max-iterations N    Maximum iterations (default: 10)
#   -c, --config FILE         Config file path (default: claude-ralph.config.json)
#   --dry-run                 Preview without running Claude
#   --skip STORY_ID           Skip specific story (can be repeated)
#   --only STORY_ID           Only run specific story (can be repeated)
#   --resume                  Resume from last incomplete story
#   --create-pr               Create PR when complete
#   --no-hooks                Disable pre/post hooks
#   -v, --verbose             Verbose output
#   -q, --quiet               Minimal output
#   -h, --help                Show this help

set -e

# ============================================================================
# DEFAULT CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/claude-ralph.config.json"

# Defaults (can be overridden by config file or CLI args)
MAX_ITERATIONS=10
MAX_RETRIES=3
RETRY_DELAY=5
MAX_TOKENS=0  # 0 = unlimited
MAX_COST=0    # 0 = unlimited
DRY_RUN=false
VERBOSE=false
QUIET=false
CREATE_PR=false
ENABLE_HOOKS=true
WEBHOOK_URL=""
SLACK_WEBHOOK=""

# Runtime state
declare -a SKIP_STORIES=()
declare -a ONLY_STORIES=()
RESUME_MODE=false
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
ESTIMATED_COST=0

# File paths
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LOGS_DIR="$SCRIPT_DIR/logs"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
STATE_FILE="$SCRIPT_DIR/.ralph-state.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log_info() {
    if [ "$QUIET" != "true" ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    if [ "$QUIET" != "true" ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    fi
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

show_help() {
    cat << 'EOF'
Claude Ralph - Autonomous AI Agent Loop

Usage: ./claude-ralph.sh [options]

Options:
  -n, --max-iterations N    Maximum iterations (default: 10)
  -c, --config FILE         Config file path (default: claude-ralph.config.json)
  --dry-run                 Preview without running Claude
  --skip STORY_ID           Skip specific story (can be repeated)
  --only STORY_ID           Only run specific story (can be repeated)
  --resume                  Resume from last incomplete story
  --create-pr               Create PR when complete
  --no-hooks                Disable pre/post hooks
  -v, --verbose             Verbose output
  -q, --quiet               Minimal output
  -h, --help                Show this help

Configuration:
  Create claude-ralph.config.json to set defaults. See claude-ralph.config.example.json

Examples:
  ./claude-ralph.sh                      # Run with defaults
  ./claude-ralph.sh -n 5                 # Max 5 iterations
  ./claude-ralph.sh --dry-run            # Preview mode
  ./claude-ralph.sh --skip US-003        # Skip story US-003
  ./claude-ralph.sh --only US-001        # Only run US-001
  ./claude-ralph.sh --resume --create-pr # Resume and create PR when done
EOF
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_debug "Loading config from $CONFIG_FILE"

        # Load values from config file
        MAX_ITERATIONS=$(jq -r '.maxIterations // 10' "$CONFIG_FILE")
        MAX_RETRIES=$(jq -r '.maxRetries // 3' "$CONFIG_FILE")
        RETRY_DELAY=$(jq -r '.retryDelay // 5' "$CONFIG_FILE")
        MAX_TOKENS=$(jq -r '.maxTokens // 0' "$CONFIG_FILE")
        MAX_COST=$(jq -r '.maxCost // 0' "$CONFIG_FILE")
        WEBHOOK_URL=$(jq -r '.webhookUrl // ""' "$CONFIG_FILE")
        SLACK_WEBHOOK=$(jq -r '.slackWebhook // ""' "$CONFIG_FILE")
        CREATE_PR=$(jq -r '.createPrOnComplete // false' "$CONFIG_FILE")
        ENABLE_HOOKS=$(jq -r '.enableHooks // true' "$CONFIG_FILE")

        log_debug "Config loaded: maxIterations=$MAX_ITERATIONS, maxRetries=$MAX_RETRIES, maxTokens=$MAX_TOKENS"
    else
        log_debug "No config file found, using defaults"
    fi
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--max-iterations)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip)
                SKIP_STORIES+=("$2")
                shift 2
                ;;
            --only)
                ONLY_STORIES+=("$2")
                shift 2
                ;;
            --resume)
                RESUME_MODE=true
                shift
                ;;
            --create-pr)
                CREATE_PR=true
                shift
                ;;
            --no-hooks)
                ENABLE_HOOKS=false
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # Legacy: first positional arg is max_iterations
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    MAX_ITERATIONS="$1"
                else
                    log_error "Unknown option: $1"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================

check_prerequisites() {
    local missing=false

    if ! command -v claude &> /dev/null; then
        log_error "Claude CLI is not installed."
        echo "  Install it from: https://github.com/anthropics/claude-code"
        missing=true
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed."
        echo "  Install it with: brew install jq (macOS) or apt install jq (Linux)"
        missing=true
    fi

    if [ ! -f "$PRD_FILE" ]; then
        log_error "prd.json not found at $PRD_FILE"
        echo "  Create one using the PRD skill or copy from prd.json.example"
        missing=true
    fi

    if [ ! -f "$PROMPT_FILE" ]; then
        log_error "prompt.md not found at $PROMPT_FILE"
        missing=true
    fi

    if [ "$missing" = true ]; then
        exit 1
    fi

    # Create logs directory
    mkdir -p "$LOGS_DIR"
    mkdir -p "$ARCHIVE_DIR"
}

# ============================================================================
# TOKEN & COST TRACKING
# ============================================================================

# Extract token usage from Claude output
# Claude CLI outputs usage info that we can parse
extract_token_usage() {
    local output="$1"
    local log_file="$2"

    # Try to extract token counts from output
    # Claude CLI may output: "Input tokens: X, Output tokens: Y"
    local input_tokens=$(echo "$output" | grep -oE 'input[_ ]tokens[: ]+([0-9]+)' | grep -oE '[0-9]+' | tail -1 || echo "0")
    local output_tokens=$(echo "$output" | grep -oE 'output[_ ]tokens[: ]+([0-9]+)' | grep -oE '[0-9]+' | tail -1 || echo "0")

    # If we couldn't extract, estimate based on output length
    if [ "$input_tokens" = "0" ] || [ -z "$input_tokens" ]; then
        # Rough estimate: ~4 chars per token for input (prompt)
        local prompt_length=$(wc -c < "$PROMPT_FILE" 2>/dev/null || echo "0")
        input_tokens=$((prompt_length / 4))
    fi

    if [ "$output_tokens" = "0" ] || [ -z "$output_tokens" ]; then
        # Rough estimate: ~4 chars per token for output
        local output_length=${#output}
        output_tokens=$((output_length / 4))
    fi

    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + input_tokens))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + output_tokens))

    # Estimate cost (Claude Sonnet pricing: $3/1M input, $15/1M output)
    local input_cost=$(echo "scale=4; $input_tokens * 0.000003" | bc 2>/dev/null || echo "0")
    local output_cost=$(echo "scale=4; $output_tokens * 0.000015" | bc 2>/dev/null || echo "0")
    local iteration_cost=$(echo "scale=4; $input_cost + $output_cost" | bc 2>/dev/null || echo "0")
    ESTIMATED_COST=$(echo "scale=4; $ESTIMATED_COST + $iteration_cost" | bc 2>/dev/null || echo "0")

    log_debug "Tokens this iteration: input=$input_tokens, output=$output_tokens, cost=\$$iteration_cost"

    # Log to file
    echo "Input tokens: $input_tokens" >> "$log_file"
    echo "Output tokens: $output_tokens" >> "$log_file"
    echo "Estimated cost: \$$iteration_cost" >> "$log_file"
}

check_token_limits() {
    # Check if we've exceeded token limit
    if [ "$MAX_TOKENS" -gt 0 ]; then
        local total_tokens=$((TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS))
        if [ "$total_tokens" -ge "$MAX_TOKENS" ]; then
            log_warn "Token limit reached: $total_tokens >= $MAX_TOKENS"
            return 1
        fi
    fi

    # Check if we've exceeded cost limit
    if [ "$MAX_COST" != "0" ] && command -v bc &> /dev/null; then
        local exceeded=$(echo "$ESTIMATED_COST >= $MAX_COST" | bc 2>/dev/null || echo "0")
        if [ "$exceeded" = "1" ]; then
            log_warn "Cost limit reached: \$$ESTIMATED_COST >= \$$MAX_COST"
            return 1
        fi
    fi

    return 0
}

show_usage_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Usage Summary${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  Total input tokens:  ${YELLOW}$TOTAL_INPUT_TOKENS${NC}"
    echo -e "  Total output tokens: ${YELLOW}$TOTAL_OUTPUT_TOKENS${NC}"
    echo -e "  Estimated cost:      ${YELLOW}\$$ESTIMATED_COST${NC}"
    echo ""
}

# ============================================================================
# SESSION LOGGING
# ============================================================================

init_session_log() {
    SESSION_ID=$(date +%Y%m%d_%H%M%S)
    SESSION_LOG="$LOGS_DIR/session_$SESSION_ID.log"

    {
        echo "═══════════════════════════════════════════════════════════"
        echo "Claude Ralph Session Log"
        echo "Started: $(date)"
        echo "Session ID: $SESSION_ID"
        echo "Config: MAX_ITERATIONS=$MAX_ITERATIONS, MAX_RETRIES=$MAX_RETRIES"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
    } > "$SESSION_LOG"

    log_debug "Session log: $SESSION_LOG"
}

log_iteration() {
    local iteration="$1"
    local story_id="$2"
    local status="$3"
    local output="$4"

    local iteration_log="$LOGS_DIR/iteration_${SESSION_ID}_${iteration}.log"

    {
        echo "═══════════════════════════════════════════════════════════"
        echo "Iteration: $iteration"
        echo "Story: $story_id"
        echo "Status: $status"
        echo "Timestamp: $(date)"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        echo "$output"
        echo ""
    } > "$iteration_log"

    # Also append summary to session log
    {
        echo "--- Iteration $iteration: $story_id - $status ---"
    } >> "$SESSION_LOG"

    # Extract and log token usage
    extract_token_usage "$output" "$iteration_log"
}

# ============================================================================
# STORY MANAGEMENT
# ============================================================================

get_next_story() {
    local stories

    # Get incomplete stories sorted by priority
    stories=$(jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority) | .[].id' "$PRD_FILE" 2>/dev/null)

    for story_id in $stories; do
        # Check if story should be skipped
        local skip=false
        for skip_id in "${SKIP_STORIES[@]}"; do
            if [ "$story_id" = "$skip_id" ]; then
                skip=true
                break
            fi
        done

        # Check if we're in --only mode
        if [ ${#ONLY_STORIES[@]} -gt 0 ]; then
            local found=false
            for only_id in "${ONLY_STORIES[@]}"; do
                if [ "$story_id" = "$only_id" ]; then
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                skip=true
            fi
        fi

        if [ "$skip" = false ]; then
            echo "$story_id"
            return 0
        fi
    done

    return 1
}

should_skip_story() {
    local story_id="$1"

    for skip_id in "${SKIP_STORIES[@]}"; do
        if [ "$story_id" = "$skip_id" ]; then
            return 0
        fi
    done
    return 1
}

# ============================================================================
# HOOKS
# ============================================================================

run_pre_hook() {
    local iteration="$1"

    if [ "$ENABLE_HOOKS" != "true" ]; then
        return 0
    fi

    local hook_file="$SCRIPT_DIR/hooks/pre-iteration.sh"
    if [ -f "$hook_file" ] && [ -x "$hook_file" ]; then
        log_debug "Running pre-iteration hook"
        ITERATION="$iteration" "$hook_file" || log_warn "Pre-iteration hook failed"
    fi
}

run_post_hook() {
    local iteration="$1"
    local status="$2"
    local story_id="$3"

    if [ "$ENABLE_HOOKS" != "true" ]; then
        return 0
    fi

    local hook_file="$SCRIPT_DIR/hooks/post-iteration.sh"
    if [ -f "$hook_file" ] && [ -x "$hook_file" ]; then
        log_debug "Running post-iteration hook"
        ITERATION="$iteration" STATUS="$status" STORY_ID="$story_id" "$hook_file" || log_warn "Post-iteration hook failed"
    fi
}

run_completion_hook() {
    local status="$1"  # "success" or "failed"

    if [ "$ENABLE_HOOKS" != "true" ]; then
        return 0
    fi

    local hook_file="$SCRIPT_DIR/hooks/on-complete.sh"
    if [ -f "$hook_file" ] && [ -x "$hook_file" ]; then
        log_debug "Running completion hook"
        STATUS="$status" TOTAL_TOKENS="$((TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS))" ESTIMATED_COST="$ESTIMATED_COST" "$hook_file" || log_warn "Completion hook failed"
    fi
}

# ============================================================================
# NOTIFICATIONS
# ============================================================================

send_notification() {
    local title="$1"
    local message="$2"
    local status="$3"  # success, warning, error

    # Slack webhook
    if [ -n "$SLACK_WEBHOOK" ]; then
        local color="good"
        [ "$status" = "warning" ] && color="warning"
        [ "$status" = "error" ] && color="danger"

        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            -d "{\"attachments\":[{\"color\":\"$color\",\"title\":\"$title\",\"text\":\"$message\"}]}" \
            > /dev/null 2>&1 || log_debug "Failed to send Slack notification"
    fi

    # Generic webhook
    if [ -n "$WEBHOOK_URL" ]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H 'Content-type: application/json' \
            -d "{\"title\":\"$title\",\"message\":\"$message\",\"status\":\"$status\"}" \
            > /dev/null 2>&1 || log_debug "Failed to send webhook notification"
    fi
}

# ============================================================================
# PR CREATION
# ============================================================================

create_pull_request() {
    if [ "$CREATE_PR" != "true" ]; then
        return 0
    fi

    if ! command -v gh &> /dev/null; then
        log_warn "gh CLI not installed, skipping PR creation"
        return 1
    fi

    local branch_name=$(jq -r '.branchName // ""' "$PRD_FILE")
    local project_name=$(jq -r '.project // "Project"' "$PRD_FILE")
    local description=$(jq -r '.description // ""' "$PRD_FILE")

    if [ -z "$branch_name" ]; then
        log_warn "No branch name in prd.json, skipping PR creation"
        return 1
    fi

    log_info "Creating pull request..."

    # Get completed stories for PR body
    local completed_stories=$(jq -r '.userStories[] | select(.passes == true) | "- \(.id): \(.title)"' "$PRD_FILE")

    local pr_body="## Summary
$description

## Completed Stories
$completed_stories

## Usage Stats
- Total tokens: $((TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS))
- Estimated cost: \$$ESTIMATED_COST

---
🤖 Generated with [Claude Ralph](https://github.com/CalebWinston/claude-ralph)"

    gh pr create \
        --title "feat: $project_name - $description" \
        --body "$pr_body" \
        2>&1 || {
            log_warn "Failed to create PR (may already exist or not on a branch)"
            return 1
        }

    log_success "Pull request created!"
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

save_state() {
    local iteration="$1"
    local last_story="$2"

    jq -n \
        --arg iter "$iteration" \
        --arg story "$last_story" \
        --arg input "$TOTAL_INPUT_TOKENS" \
        --arg output "$TOTAL_OUTPUT_TOKENS" \
        --arg cost "$ESTIMATED_COST" \
        --arg session "$SESSION_ID" \
        '{
            lastIteration: ($iter | tonumber),
            lastStory: $story,
            totalInputTokens: ($input | tonumber),
            totalOutputTokens: ($output | tonumber),
            estimatedCost: $cost,
            sessionId: $session,
            savedAt: now | todate
        }' > "$STATE_FILE"
}

load_state() {
    if [ "$RESUME_MODE" = "true" ] && [ -f "$STATE_FILE" ]; then
        log_info "Resuming from saved state..."
        TOTAL_INPUT_TOKENS=$(jq -r '.totalInputTokens // 0' "$STATE_FILE")
        TOTAL_OUTPUT_TOKENS=$(jq -r '.totalOutputTokens // 0' "$STATE_FILE")
        ESTIMATED_COST=$(jq -r '.estimatedCost // "0"' "$STATE_FILE")
        log_debug "Restored state: tokens=$((TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS)), cost=\$$ESTIMATED_COST"
    fi
}

# ============================================================================
# ARCHIVE & BRANCH MANAGEMENT
# ============================================================================

archive_previous_run() {
    if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
        CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
        LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

        if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
            DATE=$(date +%Y-%m-%d)
            FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^claude-ralph/||')
            ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

            log_info "Archiving previous run: $LAST_BRANCH"
            mkdir -p "$ARCHIVE_FOLDER"
            [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
            [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
            [ -d "$LOGS_DIR" ] && cp -r "$LOGS_DIR" "$ARCHIVE_FOLDER/" 2>/dev/null || true
            [ -f "$STATE_FILE" ] && cp "$STATE_FILE" "$ARCHIVE_FOLDER/"
            log_success "Archived to: $ARCHIVE_FOLDER"

            # Reset for new run
            echo "# Claude Ralph Progress Log" > "$PROGRESS_FILE"
            echo "Started: $(date)" >> "$PROGRESS_FILE"
            echo "---" >> "$PROGRESS_FILE"
            rm -f "$STATE_FILE"
        fi
    fi
}

track_branch() {
    if [ -f "$PRD_FILE" ]; then
        CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
        if [ -n "$CURRENT_BRANCH" ]; then
            echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
        fi
    fi
}

init_progress_file() {
    if [ ! -f "$PROGRESS_FILE" ]; then
        echo "# Claude Ralph Progress Log" > "$PROGRESS_FILE"
        echo "Started: $(date)" >> "$PROGRESS_FILE"
        echo "---" >> "$PROGRESS_FILE"
    fi
}

# ============================================================================
# STATUS DISPLAY
# ============================================================================

check_completion() {
    local incomplete

    # Consider skip/only filters
    if [ ${#ONLY_STORIES[@]} -gt 0 ]; then
        # Only check stories in the --only list
        incomplete=0
        for only_id in "${ONLY_STORIES[@]}"; do
            local passes=$(jq -r --arg id "$only_id" '.userStories[] | select(.id == $id) | .passes' "$PRD_FILE" 2>/dev/null)
            if [ "$passes" = "false" ]; then
                incomplete=$((incomplete + 1))
            fi
        done
    else
        incomplete=$(jq '[.userStories[] | select(.passes == false)] | length' "$PRD_FILE" 2>/dev/null || echo "1")

        # Subtract skipped stories
        for skip_id in "${SKIP_STORIES[@]}"; do
            local passes=$(jq -r --arg id "$skip_id" '.userStories[] | select(.id == $id) | .passes' "$PRD_FILE" 2>/dev/null)
            if [ "$passes" = "false" ]; then
                incomplete=$((incomplete - 1))
            fi
        done
    fi

    if [ "$incomplete" -le 0 ]; then
        return 0
    else
        return 1
    fi
}

show_status() {
    if [ "$QUIET" = "true" ]; then
        return
    fi

    echo -e "${BLUE}Current PRD Status:${NC}"

    while IFS= read -r line; do
        local id=$(echo "$line" | jq -r '.id')
        local title=$(echo "$line" | jq -r '.title')
        local passes=$(echo "$line" | jq -r '.passes')

        local mark=" "
        local color="$NC"

        if [ "$passes" = "true" ]; then
            mark="✓"
            color="$GREEN"
        fi

        # Check if skipped
        for skip_id in "${SKIP_STORIES[@]}"; do
            if [ "$id" = "$skip_id" ]; then
                mark="⊘"
                color="$YELLOW"
                break
            fi
        done

        echo -e "  ${color}[$mark]${NC} $id: $title"
    done < <(jq -c '.userStories[]' "$PRD_FILE" 2>/dev/null)

    echo ""
}

show_header() {
    if [ "$QUIET" = "true" ]; then
        return
    fi

    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Claude Ralph - Autonomous Agent Loop           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Max iterations: ${YELLOW}$MAX_ITERATIONS${NC}"
    echo -e "  Max retries:    ${YELLOW}$MAX_RETRIES${NC}"
    [ "$MAX_TOKENS" -gt 0 ] && echo -e "  Token limit:    ${YELLOW}$MAX_TOKENS${NC}"
    [ "$MAX_COST" != "0" ] && echo -e "  Cost limit:     ${YELLOW}\$$MAX_COST${NC}"
    [ "$DRY_RUN" = "true" ] && echo -e "  Mode:           ${MAGENTA}DRY RUN${NC}"
    [ ${#SKIP_STORIES[@]} -gt 0 ] && echo -e "  Skipping:       ${YELLOW}${SKIP_STORIES[*]}${NC}"
    [ ${#ONLY_STORIES[@]} -gt 0 ] && echo -e "  Only running:   ${YELLOW}${ONLY_STORIES[*]}${NC}"
    echo ""
}

# ============================================================================
# CLAUDE EXECUTION
# ============================================================================

run_claude_iteration() {
    local iteration="$1"
    local retry_count=0
    local success=false
    local output=""
    local story_id=""

    # Get next story
    story_id=$(get_next_story) || {
        log_info "No more stories to process"
        return 2  # Signal completion
    }

    log_info "Working on story: $story_id"

    # Run pre-hook
    run_pre_hook "$iteration"

    while [ $retry_count -lt $MAX_RETRIES ] && [ "$success" = false ]; do
        if [ $retry_count -gt 0 ]; then
            log_warn "Retry $retry_count of $MAX_RETRIES after ${RETRY_DELAY}s delay..."
            sleep "$RETRY_DELAY"
        fi

        # Prepare prompt with story context
        local prompt_content=$(cat "$PROMPT_FILE")
        prompt_content="$prompt_content

Current target story: $story_id
"

        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY RUN] Would execute Claude with story $story_id"
            output="[DRY RUN] Simulated output for $story_id"
            success=true
        else
            # Run Claude
            output=$(claude -p "$prompt_content" --dangerously-skip-permissions 2>&1 | tee /dev/stderr) || {
                log_warn "Claude execution failed"
                retry_count=$((retry_count + 1))
                continue
            }

            # Check for rate limiting or API errors
            if echo "$output" | grep -qiE "(rate limit|too many requests|503|502|429)"; then
                log_warn "Rate limited or API error detected"
                retry_count=$((retry_count + 1))
                RETRY_DELAY=$((RETRY_DELAY * 2))  # Exponential backoff
                continue
            fi

            success=true
        fi
    done

    # Log iteration
    local status="success"
    [ "$success" = false ] && status="failed"
    log_iteration "$iteration" "$story_id" "$status" "$output"

    # Run post-hook
    run_post_hook "$iteration" "$status" "$story_id"

    # Save state
    save_state "$iteration" "$story_id"

    if [ "$success" = false ]; then
        log_error "Iteration $iteration failed after $MAX_RETRIES retries"
        return 1
    fi

    # Check for completion signal
    if echo "$output" | grep -q "RALPH_COMPLETE"; then
        return 2  # Signal completion
    fi

    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse arguments first (may override config file path)
    parse_args "$@"

    # Load config
    load_config

    # Re-parse args to override config values
    parse_args "$@"

    # Check prerequisites
    check_prerequisites

    # Initialize
    archive_previous_run
    track_branch
    init_progress_file
    init_session_log
    load_state

    # Show header
    show_header
    show_status

    # Check if already complete
    if check_completion; then
        log_success "All stories already complete! Nothing to do."
        show_usage_summary
        run_completion_hook "success"
        exit 0
    fi

    # Main loop
    local completed=false
    for i in $(seq 1 $MAX_ITERATIONS); do
        echo ""
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}  Claude Ralph Iteration $i of $MAX_ITERATIONS${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo ""

        # Check token/cost limits before running
        if ! check_token_limits; then
            log_error "Token or cost limit exceeded. Stopping."
            send_notification "Claude Ralph" "Stopped due to token/cost limit" "warning"
            break
        fi

        # Run iteration
        run_claude_iteration "$i"
        local result=$?

        if [ $result -eq 2 ]; then
            # Completion signal
            completed=true
            break
        elif [ $result -eq 1 ]; then
            # Failed iteration
            log_error "Iteration failed, continuing to next..."
        fi

        # Also check prd.json directly
        if check_completion; then
            completed=true
            break
        fi

        log_info "Iteration $i complete. Continuing..."
        sleep 2
    done

    # Final status
    echo ""
    if [ "$completed" = true ]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║          Claude Ralph completed all tasks!               ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
        show_status
        show_usage_summary

        # Create PR if requested
        create_pull_request

        # Notifications and hooks
        send_notification "Claude Ralph Complete" "All stories finished successfully" "success"
        run_completion_hook "success"

        exit 0
    else
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  Claude Ralph reached max iterations without completing  ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Check logs at: $LOGS_DIR"
        echo "Check progress at: $PROGRESS_FILE"
        show_status
        show_usage_summary

        # Notifications and hooks
        send_notification "Claude Ralph Incomplete" "Reached max iterations" "warning"
        run_completion_hook "failed"

        exit 1
    fi
}

main "$@"
