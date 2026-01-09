# Claude Ralph

An autonomous AI agent loop that runs [Claude CLI](https://github.com/anthropics/claude-code) repeatedly until all PRD items are complete.

Inspired by [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/) and [snarktank/ralph](https://github.com/snarktank/ralph), adapted for Claude CLI.

## Features

- **Autonomous Execution** - Runs Claude repeatedly until all stories pass
- **Token & Cost Tracking** - Monitor usage and set limits to control spending
- **Session Logging** - Full logs for every iteration for debugging
- **Retry Logic** - Automatic retries with exponential backoff
- **Story Management** - Skip, select, or resume specific stories
- **Notifications** - Slack and webhook notifications on completion
- **Auto PR Creation** - Automatically create pull requests when done
- **Custom Hooks** - Run scripts before/after iterations
- **Dry Run Mode** - Preview without executing

## How It Works

Claude Ralph spawns iterative Claude instances that:
1. Read a PRD (`prd.json`) containing user stories
2. Select the highest-priority incomplete story
3. Implement that single story
4. Run quality checks (typecheck, tests, lint)
5. Commit working code
6. Update progress tracking
7. Repeat until all stories pass

Each iteration is a **fresh Claude instance** with clean context. Memory persists through:
- Git commit history
- `progress.txt` (learnings across runs)
- `prd.json` (completion status)
- `CLAUDE.md` (project patterns)

## Prerequisites

- [Claude CLI](https://github.com/anthropics/claude-code) installed and authenticated
- `jq` command-line tool
- Git repository for your project
- `bc` (optional, for cost calculations)
- `gh` CLI (optional, for auto PR creation)

```bash
# Install dependencies
brew install jq gh       # macOS
apt install jq gh        # Ubuntu/Debian
```

## Quick Start

### 1. Copy to Your Project

```bash
# Clone this repo
git clone https://github.com/CalebWinston/claude-ralph.git

# Copy files to your project
cp claude-ralph/claude-ralph.sh your-project/scripts/
cp claude-ralph/prompt.md your-project/scripts/
cp claude-ralph/prd.json.example your-project/prd.json
```

### 2. Create Your PRD

Option A: Use the PRD skill (if installed):
```bash
claude "Create a PRD for [your feature]"
```

Option B: Manually create `prd.json` based on the example.

### 3. Convert to JSON Format

If you have a markdown PRD:
```bash
claude "Convert tasks/prd-my-feature.md to ralph format"
```

### 4. Run Claude Ralph

```bash
./scripts/claude-ralph.sh [options]
```

## Command Line Options

```
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
```

### Examples

```bash
# Run with defaults (10 iterations)
./claude-ralph.sh

# Limit to 5 iterations
./claude-ralph.sh -n 5

# Preview what would happen without running Claude
./claude-ralph.sh --dry-run

# Skip a problematic story
./claude-ralph.sh --skip US-003

# Only run specific stories
./claude-ralph.sh --only US-001 --only US-002

# Resume from where you left off and create PR when done
./claude-ralph.sh --resume --create-pr

# Run with verbose output
./claude-ralph.sh -v
```

## Configuration File

Create `claude-ralph.config.json` to set defaults:

```json
{
  "maxIterations": 10,
  "maxRetries": 3,
  "retryDelay": 5,
  "maxTokens": 500000,
  "maxCost": 10.00,
  "webhookUrl": "",
  "slackWebhook": "https://hooks.slack.com/services/...",
  "createPrOnComplete": true,
  "enableHooks": true
}
```

| Setting | Description | Default |
|---------|-------------|---------|
| `maxIterations` | Maximum loop iterations | 10 |
| `maxRetries` | Retries per iteration on failure | 3 |
| `retryDelay` | Seconds between retries | 5 |
| `maxTokens` | Stop if total tokens exceed this (0 = unlimited) | 0 |
| `maxCost` | Stop if estimated cost exceeds this in USD (0 = unlimited) | 0 |
| `webhookUrl` | Generic webhook URL for notifications | "" |
| `slackWebhook` | Slack webhook URL for notifications | "" |
| `createPrOnComplete` | Auto-create PR when all stories complete | false |
| `enableHooks` | Enable pre/post iteration hooks | true |

## Token & Cost Tracking

Claude Ralph tracks token usage and estimates costs across all iterations:

```
═══════════════════════════════════════════════════════════
  Usage Summary
═══════════════════════════════════════════════════════════
  Total input tokens:  45,230
  Total output tokens: 12,450
  Estimated cost:      $0.32
```

### Setting Limits

Prevent runaway costs by setting limits in the config:

```json
{
  "maxTokens": 500000,
  "maxCost": 10.00
}
```

When limits are reached, Claude Ralph stops gracefully and sends a notification.

## Session Logging

Every iteration is logged to the `logs/` directory:

```
logs/
├── session_20240115_143022.log      # Session summary
├── iteration_20240115_143022_1.log  # Full output for iteration 1
├── iteration_20240115_143022_2.log  # Full output for iteration 2
└── ...
```

Use logs to debug failed iterations or review what Claude did.

## Custom Hooks

Run custom scripts at key points in the execution:

```
hooks/
├── pre-iteration.sh     # Runs before each iteration
├── post-iteration.sh    # Runs after each iteration
└── on-complete.sh       # Runs when all done (or max iterations)
```

### Hook Environment Variables

**pre-iteration.sh:**
- `ITERATION` - Current iteration number

**post-iteration.sh:**
- `ITERATION` - Current iteration number
- `STATUS` - "success" or "failed"
- `STORY_ID` - Story that was worked on

**on-complete.sh:**
- `STATUS` - "success" or "failed"
- `TOTAL_TOKENS` - Total tokens used
- `ESTIMATED_COST` - Estimated cost in USD

### Example Hook

```bash
#!/bin/bash
# hooks/post-iteration.sh - Push after each successful iteration

if [ "$STATUS" = "success" ]; then
    git push origin HEAD
    echo "Pushed changes for $STORY_ID"
fi
```

## Notifications

### Slack

Set up Slack notifications by adding your webhook URL:

```json
{
  "slackWebhook": "https://hooks.slack.com/services/T00/B00/xxx"
}
```

### Generic Webhook

For other services, use the generic webhook:

```json
{
  "webhookUrl": "https://your-service.com/webhook"
}
```

Payload format:
```json
{
  "title": "Claude Ralph Complete",
  "message": "All stories finished successfully",
  "status": "success"
}
```

## Auto PR Creation

Automatically create a pull request when all stories complete:

```bash
./claude-ralph.sh --create-pr
```

Or set in config:
```json
{
  "createPrOnComplete": true
}
```

The PR includes:
- Summary from prd.json description
- List of completed stories
- Token usage statistics

Requires `gh` CLI to be installed and authenticated.

## File Structure

```
your-project/
├── scripts/
│   ├── claude-ralph.sh              # Main loop script
│   └── prompt.md                    # Instructions for each Claude instance
├── claude-ralph.config.json         # Configuration (optional)
├── prd.json                         # User stories with pass/fail status
├── progress.txt                     # Append-only learnings log
├── CLAUDE.md                        # Project-specific Claude instructions
├── hooks/                           # Custom hooks (optional)
│   ├── pre-iteration.sh
│   ├── post-iteration.sh
│   └── on-complete.sh
├── logs/                            # Session and iteration logs
└── archive/                         # Archived previous runs
```

## PRD Format

```json
{
  "project": "MyApp",
  "branchName": "claude-ralph/feature-name",
  "description": "Feature description",
  "userStories": [
    {
      "id": "US-001",
      "title": "Story title",
      "description": "As a [role], I want [feature]...",
      "acceptanceCriteria": [
        "Specific criterion 1",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

## Skills

### PRD Generator (`skills/prd/`)

Generates comprehensive Product Requirements Documents through interactive Q&A.

Usage:
```bash
claude "Create a PRD for user authentication"
```

### PRD to JSON Converter (`skills/ralph/`)

Converts markdown PRDs to `prd.json` format for Claude Ralph execution.

Usage:
```bash
claude "Convert this PRD to ralph format"
```

### Installing Skills Globally

Copy skills to your Claude CLI config:

```bash
mkdir -p ~/.claude/commands
cp -r skills/prd ~/.claude/commands/
cp -r skills/ralph ~/.claude/commands/
```

## Critical Concepts

### Fresh Context Per Iteration

Each Claude instance is independent. No conversation history carries over. Memory flows through:
- Git commits from previous work
- `progress.txt` with accumulated learnings
- `prd.json` completion markers

### Small, Focused Tasks

Stories must be completable within one context window:

**Good story sizes:**
- Add a database column
- Create a single UI component
- Implement one API endpoint
- Add a specific validation rule

**Too large (split these up):**
- Build entire dashboard
- Implement full authentication system
- Create complete admin panel

### Quality Feedback Loops

Every iteration runs quality checks. Broken code compounds across iterations, so:
- Typecheck must pass
- Tests must pass
- Lint must pass

### CLAUDE.md Updates

After each iteration, discovered patterns should be added to `CLAUDE.md` files. This helps future iterations understand:
- API conventions
- Non-obvious requirements
- File dependencies
- Testing approaches

## Debugging

Check current state:
```bash
# View story status
cat prd.json | jq '.userStories[] | {id, title, passes}'

# View progress log
cat progress.txt

# View recent commits
git log --oneline -10

# View session logs
ls -la logs/

# View specific iteration log
cat logs/iteration_*.log | less
```

## Resume After Interruption

If Claude Ralph is interrupted, use `--resume` to continue:

```bash
./claude-ralph.sh --resume
```

This restores:
- Token/cost counters from previous session
- Continues from next incomplete story

## Archive

When starting a new feature, Claude Ralph automatically archives the previous run:
```
archive/
└── 2024-01-15-previous-feature/
    ├── prd.json
    ├── progress.txt
    ├── logs/
    └── .ralph-state.json
```

## Differences from Original Ralph

| Original (Amp) | Claude Ralph |
|----------------|--------------|
| `amp --dangerously-allow-all` | `claude -p "..." --dangerously-skip-permissions` |
| `~/.config/amp/skills/` | `~/.claude/commands/` |
| `AGENTS.md` | `CLAUDE.md` |
| `<promise>COMPLETE</promise>` | `RALPH_COMPLETE` |
| No token tracking | Built-in token & cost tracking |
| No retry logic | Configurable retries with backoff |
| No notifications | Slack & webhook support |
| No hooks | Pre/post iteration hooks |

## License

MIT

## Credits

- Original Ralph pattern by [Geoffrey Huntley](https://ghuntley.com/ralph/)
- Amp implementation by [snarktank](https://github.com/snarktank/ralph)
- Claude CLI by [Anthropic](https://github.com/anthropics/claude-code)
