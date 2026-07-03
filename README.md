# claude-intrupt-hook

A Claude Code `PreToolUse` hook that gates high-risk tool calls behind a human approval. Before Claude executes a destructive command, it pauses, notifies your approver via Slack (or any intrupt channel), and waits. The tool only runs if a human clicks **Approve**.

```
Claude Code
  └─ wants to run: git push origin main
        │
        ▼
  PreToolUse hook fires
        │
        ▼
  POST /org/{id}/approval  ──►  intrupt API  ──►  Slack message
        │                                              │
        │  poll every 5s                     human clicks Approve / Reject
        │                                              │
        ▼                                              ▼
  GET /approval/{id}  ◄──────────────────────  status = "approved"
        │
        ▼
  exit 0  →  Claude continues
  exit 1  →  Claude is blocked
```

---

## Prerequisites

- Claude Code ≥ 1.0 (CLI, desktop, or IDE extension)
- Python 3.10+
- An [Aegmis](https://aegmis.com) account with an API key and org ID
- Slack workspace connected to your Aegmis org (for the default channel)

---

## Installation

```bash
git clone https://github.com/your-org/claude-intrupt-hook
cd claude-intrupt-hook
bash install.sh
```

`install.sh` does three things:

1. Copies `hook.py` to `~/.claude/hooks/intrupt_hook.py`
2. Merges the hook trigger into `~/.claude/settings.json`
3. Creates `~/.claude/.env.intrupt` with placeholder env vars

Then fill in your credentials:

```bash
# Edit the generated env file
nano ~/.claude/.env.intrupt

# Source it (add this line to ~/.zshrc or ~/.bashrc too)
source ~/.claude/.env.intrupt
```

`.env.intrupt`:
```bash
export INTRUPT_BASE_URL=https://api.aegmis.com
export INTRUPT_API_KEY=sk_org_xxxx_yyyy    # Account → API Keys
```

---

## How it works

### 1. Claude Code fires the hook

Whenever Claude attempts a `Bash`, `Write`, or `Edit` tool call, Claude Code passes a JSON payload to `hook.py` on stdin before executing anything:

```json
{
  "tool_name": "Bash",
  "tool_input": { "command": "git push origin main" },
  "session_id": "sess_abc123",
  "transcript_path": "/tmp/claude/transcript.jsonl"
}
```

### 2. The hook decides whether to gate

Not every Bash command is dangerous. The hook checks the command against a list of patterns before asking for approval. Low-risk commands (`ls`, `git status`, `cat`, `grep`, etc.) pass through immediately.

Commands that **always require approval**:

| Pattern | Example |
|---|---|
| `rm -rf` / `rm -r` | `rm -rf dist/` |
| `git push` | `git push origin main --force` |
| `git reset --hard` | `git reset --hard HEAD~3` |
| `gh pr merge` / `gh release` | `gh pr merge 42` |
| `npm publish` | `npm publish --access public` |
| `deploy` | `npm run deploy`, `./deploy.sh` |
| `kubectl delete` / `kubectl apply` | `kubectl delete pod my-pod` |
| `terraform apply` / `terraform destroy` | `terraform destroy -auto-approve` |
| `DROP TABLE` / `TRUNCATE TABLE` | SQL run via CLI |
| `sudo` | `sudo systemctl restart nginx` |
| `curl ... \| sh` | piped install scripts |
| `dd if=` / `mkfs` | disk operations |

`Write` and `Edit` always require approval regardless of the file path.

### 3. Approval is requested

The hook calls the intrupt API to create a pending approval:

```
POST /org/{org_id}/approval
{
  "thread_id":   "<uuid>",
  "action":      "bash_command",
  "message":     "Run: `git push origin main`",
  "channel":     "slack",
  "tool_name":   "Bash",
  "tool_kwargs": { "command": "git push origin main" }
}
```

Your Slack channel receives an interactive message:

```
Claude Code wants to run:
  git push origin main

[ ✅ Approve ]  [ ❌ Reject ]
```

### 4. The hook polls for a decision

The hook polls `GET /org/{org_id}/approval/{approval_id}` every 5 seconds until:

| Outcome | Exit code | Claude Code |
|---|---|---|
| Human clicks **Approve** | `0` | Tool runs normally |
| Human clicks **Reject** | `1` | Tool is blocked, reason shown to Claude |
| Timeout (default 10 min) | `1` | Tool is blocked with timeout message |
| API unreachable | `1` | Tool is blocked (fail closed) |

---

## Configuration

All configuration is via environment variables.

| Variable | Required | Default | Description |
|---|---|---|---|
| `INTRUPT_BASE_URL` | yes | — | intrupt API base URL |
| `INTRUPT_API_KEY` | yes | — | API key from Account → API Keys |
| `INTRUPT_GATED_TOOLS` | no | `Bash,Write,Edit` | Comma-separated tool names to gate |
| `INTRUPT_TIMEOUT` | no | `600` | Max seconds to wait for a decision |
| `INTRUPT_POLL_INTERVAL` | no | `5` | Seconds between status polls |
| `INTRUPT_BYPASS_PATTERNS` | no | — | Comma-separated regex patterns; matching Bash commands skip approval |

### Allow-listing specific commands

If you want to exclude certain commands from approval even when they match a gated pattern, use `INTRUPT_BYPASS_PATTERNS`:

```bash
# Allow git push to a specific remote only
export INTRUPT_BYPASS_PATTERNS="git push staging"

# Allow terraform apply only in a non-prod directory
export INTRUPT_BYPASS_PATTERNS="terraform apply.*-var-file=dev\.tfvars"
```

Bypass patterns are checked first — they take precedence over gate patterns.

### Gating only specific tools

```bash
# Only gate shell commands, not file edits
export INTRUPT_GATED_TOOLS=Bash

# Gate everything including sub-agent spawning
export INTRUPT_GATED_TOOLS=Bash,Write,Edit,Agent
```

---

## Claude Code settings

`install.sh` writes the following to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/hooks/intrupt_hook.py"
          }
        ]
      }
    ]
  }
}
```

To add it manually, merge this block into your existing `settings.json`.

---

## Testing

Run the included smoke tests — no real API credentials needed:

```bash
python3 test_hook.py
```

Expected output:

```
[PASS] Bash — git push (gated)
[PASS] Bash — ls (allowed)
[PASS] Bash — rm -rf (gated)
[PASS] Bash — git status (allowed)
[PASS] Write — any file (gated)
[PASS] Edit — source file (gated)
[PASS] Read — not gated
[PASS] Bash — deploy (gated)
[PASS] Bash — sudo apt (gated)
[PASS] Bash — curl | sh (gated)

Results: 10/10 passed ✓
```

To test with a real approval request, set your credentials and run:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' \
  | python3 hook.py
```

You should see a Slack message appear within a few seconds.

---

## Security notes

- The hook **fails closed**: if the API is unreachable, the env vars are missing, or the request times out, the tool call is blocked — not allowed.
- `INTRUPT_API_KEY` is sent as a `Bearer` token. Keep it out of your shell history and `.bashrc` — use a secrets manager or the `.env.intrupt` file with `600` permissions.
- The hook never stores or logs the tool input beyond what is sent to the API.

---

## Project structure

```
claude-intrupt-hook/
├── hook.py          # PreToolUse hook script (zero runtime dependencies)
├── test_hook.py     # Smoke tests for gating logic
├── install.sh       # One-command installer
├── settings.json    # Claude Code settings snippet
├── .env.example     # Environment variable template
└── README.md
```

---

## Uninstalling

```bash
rm ~/.claude/hooks/intrupt_hook.py
```

Then remove the `PreToolUse` block from `~/.claude/settings.json`.
