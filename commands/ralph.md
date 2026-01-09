# Ralph - Autonomous Development Assistant

Start and manage Claude Ralph autonomous development workflows.

## Usage

This command helps you:
1. **Set up** Claude Ralph in a new or existing project
2. **Create PRDs** for new features
3. **Convert PRDs** to the ralph JSON format
4. **Run** the autonomous loop

## Actions

When invoked, ask the user what they'd like to do:

### 1. Setup Ralph in Project

If user wants to set up Ralph:

1. Check if this is a git repository (required)
2. Create the directory structure:
   ```
   scripts/ralph/
   ├── claude-ralph.sh
   ├── prompt.md
   └── hooks/ (optional)
   ```
3. Download or copy files from https://github.com/CalebWinston/claude-ralph
4. Make claude-ralph.sh executable
5. Create a basic `claude-ralph.config.json` if they want custom settings
6. Add to .gitignore:
   ```
   prd.json
   progress.txt
   .last-branch
   .ralph-state.json
   scripts/ralph/logs/
   scripts/ralph/archive/
   ```

Provide these commands to set up:
```bash
# Clone and copy Ralph files
git clone https://github.com/CalebWinston/claude-ralph.git /tmp/claude-ralph
mkdir -p scripts/ralph/hooks
cp /tmp/claude-ralph/claude-ralph.sh scripts/ralph/
cp /tmp/claude-ralph/prompt.md scripts/ralph/
cp /tmp/claude-ralph/claude-ralph.config.example.json scripts/ralph/
cp /tmp/claude-ralph/hooks/*.example scripts/ralph/hooks/
chmod +x scripts/ralph/claude-ralph.sh
rm -rf /tmp/claude-ralph
```

### 2. Create a PRD

If user wants to create a PRD for a new feature:

**Step 1: Ask clarifying questions**

Ask 3-5 essential questions with lettered options (A, B, C, D) to understand:
- Problem/Goal: What problem does this solve?
- Core functionality: What are the must-have features?
- Scope boundaries: What's explicitly out of scope?
- Target users: Who will use this?
- Success criteria: How do we know it's done?

Example:
```
1. What is the primary goal?
   A) New feature for users
   B) Internal tooling improvement
   C) Bug fix / tech debt
   D) Performance optimization

2. What's the scope?
   A) Small (1-2 stories, ~1 day)
   B) Medium (3-5 stories, ~1 week)
   C) Large (6+ stories, needs breakdown)
```

**Step 2: Generate the PRD**

Create a markdown PRD with:
- Overview (2-3 sentences)
- Goals (bulleted)
- User Stories (US-001 format with acceptance criteria)
- Non-Goals (out of scope)
- Technical Considerations (if relevant)

Save to: `tasks/prd-[feature-name].md`

**Critical rules for stories:**
- Each story must be completable in ONE Claude iteration
- Include "Typecheck passes" in every story's criteria
- UI stories need "Verify in browser: [specific check]"
- Order by dependency (schema before UI that uses it)

### 3. Convert PRD to JSON

If user has an existing PRD to convert:

1. Read the PRD file
2. Extract project name, description, user stories
3. Generate `prd.json` with this structure:

```json
{
  "project": "ProjectName",
  "branchName": "claude-ralph/feature-name",
  "description": "Brief description",
  "userStories": [
    {
      "id": "US-001",
      "title": "Story title",
      "description": "As a [role], I want [feature] so that [benefit].",
      "acceptanceCriteria": [
        "Specific criterion",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

4. Validate:
   - Stories are small enough (single iteration)
   - Criteria are specific and testable
   - Dependencies are ordered correctly
   - All `passes` are `false`

5. Save to project root as `prd.json`

### 4. Quick Start / Run Ralph

If user wants to run Ralph:

1. Check prerequisites:
   - `prd.json` exists
   - `scripts/ralph/claude-ralph.sh` exists
   - `jq` is installed

2. Show current status:
   ```bash
   cat prd.json | jq '.userStories[] | {id, title, passes}'
   ```

3. Suggest the run command:
   ```bash
   ./scripts/ralph/claude-ralph.sh [options]
   ```

4. Remind about useful options:
   - `--dry-run` - Preview first
   - `-n 5` - Limit iterations
   - `--skip US-003` - Skip problematic stories
   - `--resume` - Continue after interruption

## Response Format

When invoked, respond with:

```
**Ralph - Autonomous Development**

What would you like to do?

1. **Setup** - Install Claude Ralph in this project
2. **Create PRD** - Generate a new Product Requirements Document
3. **Convert PRD** - Turn an existing PRD into prd.json
4. **Run** - Start the autonomous loop

Just tell me what you need, or describe the feature you want to build!
```

Then proceed based on user's response.
