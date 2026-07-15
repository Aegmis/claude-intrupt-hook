# claude-intrupt-hook

A Claude Code `PreToolUse` hook that gates high-risk tool calls behind a human approval. Before Claude executes a destructive command, it pauses, notifies your approver via Slack (or any intrupt channel), and waits. The tool only runs if a human clicks **Approve**.

```
Claude Code
  │
  ├─ rm -rf /home/user          (matches AEGMIS_BLOCKED_PATHS)
  │     ⇒  ⛔ denied locally — no API call, no Slack
  │
  └─ kubectl delete pod nginx   (matches a risk pattern)
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
  exit 2  →  Claude is blocked (reason on stderr, shown to the model)
```

> **Block contract:** Claude Code blocks a tool call on hook **exit code 2**
> (never exit 1 — that's a non-blocking hook error and the tool would still run).
> Every deny path here exits 2, and any crash is converted to a blocking exit 2,
> so the gate fails **closed**.

---

## Quick start

```bash
# 1. Install
curl -fsSL https://raw.githubusercontent.com/Aegmis/claude-intrupt-hook/main/install.sh | bash

# 2. Set your API key, then load the env
nano ~/.claude/.env.intrupt          # set AEGMIS_API_KEY=sk_org_...
source ~/.claude/.env.intrupt        # also add this line to ~/.zshrc or ~/.bashrc

# 3. Restart Claude Code — done. High-risk actions now pause for Slack approval.
```

Installer defaults: **local mode**, **shell-only** gating, and deleting the home
dir itself routes to approval (`AEGMIS_PROTECTED_PATHS=re:^$HOME$`). To make a path
**impossible to delete** — denied instantly, never sent to a human — add it to
`AEGMIS_BLOCKED_PATHS` (e.g. `export AEGMIS_BLOCKED_PATHS=re:^$HOME$` in your env file).

---

## Prerequisites

- Claude Code ≥ 1.0 (CLI, desktop, or IDE extension)
- Python 3.10+
- An [Aegmis](https://aegmis.com) account with an API key
- Slack workspace connected to your Aegmis org (for the default channel)

---

## Installation

Install with a single command — no clone required:

```bash
curl -fsSL https://raw.githubusercontent.com/Aegmis/claude-intrupt-hook/main/install.sh | bash
```

<details>
<summary>Prefer to clone first?</summary>

```bash
git clone https://github.com/Aegmis/claude-intrupt-hook.git
cd claude-intrupt-hook
bash install.sh
```

</details>

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
export AEGMIS_BASE_URL=https://api.aegmis.com
export AEGMIS_API_KEY=sk_org_xxxx_yyyy    # Account → API Keys
export AEGMIS_APPROVAL=true               # set false to disable the gate entirely (allow all)
```

---

## How it works

### 1. Claude Code fires the hook

Whenever Claude attempts a `Bash`, `Write`, or `Edit` tool call, Claude Code passes a JSON payload to `hook.py` on stdin before executing anything:

```json
{
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf /home/user" },
  "session_id": "sess_abc123",
  "transcript_path": "/tmp/claude/transcript.jsonl"
}
```

### 2. The hook decides whether to gate

Not every Bash command is dangerous. The hook checks the command against a list of patterns before asking for approval. Low-risk commands (`ls`, `git status`, `cat`, `grep`, etc.) pass through immediately.

Commands that **always require approval**:

| Pattern | Example |
|---|---|
| **catastrophic delete** (home / root / system dir, or bare `*` `.` `..`) | `rm -rf ~`, `rm -rf /`, `rm -rf /Users/you`, `rm *` — **not** `rm file` or `rm -rf node_modules` |
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
  "message":     "Run: `rm -rf /home/user`",
  "channel":     "slack",
  "tool_name":   "Bash",
  "tool_kwargs": { "command": "rm -rf /home/user" }
}
```

Your Slack channel receives an interactive message:

```
Claude Code wants to run:
  rm -rf /home/user

[ ✅ Approve ]  [ ❌ Reject ]
```

### 4. The hook polls for a decision

The hook polls `GET /org/{org_id}/approval/{approval_id}` every 5 seconds until:

| Outcome | Exit code | Claude Code |
|---|---|---|
| Human clicks **Approve** | `0` | Tool runs normally |
| Human clicks **Reject** | `2` | Tool is blocked, reason shown to Claude |
| Timeout (default 10 min) | `2` | Tool is blocked with timeout message |
| API unreachable | `2` | Tool is blocked (fail closed) |
| Hook crashes | `2` | Tool is blocked (fail closed) |

---

## What gets gated

Two tiers, evaluated in **local mode** (`AEGMIS_FORWARD_ALL=false`, the installer default):

**Hard-blocked — denied instantly, never sent to a human** (`AEGMIS_BLOCKED_PATHS`)

Only an `rm` whose target (resolved against the command's cwd, so relative paths
count) matches a `AEGMIS_BLOCKED_PATHS` entry. Denied locally with no approval
round-trip. Opt-in — nothing is hard-blocked unless you list it.

**Gated — paused for Slack approval**

The hook ships **20 built-in risk patterns**, identical across all 9 hooks. Several are families (one pattern, many commands), so they cover **30+ distinct dangerous commands**:

| Category | Matches | Passes through |
|---|---|---|
| Catastrophic `rm` | `rm -rf ~`, `rm -rf /`, `rm -rf /Users/you`, `rm *`, `rm -rf .` | `rm file.txt`, `rm -rf node_modules`, `rm -rf build` |
| Protected paths | `rm` of any dir in `AEGMIS_PROTECTED_PATHS` (default `re:^$HOME$`) + its subtree | anything not listed |
| Git | `git push` (incl. `--force`), `git reset --hard` | `git status`, `git commit`, `git pull` |
| Publish / release | `gh pr merge`, `gh release`, `npm publish`, `deploy` | builds, tests |
| Infra | `kubectl delete`/`apply`, `terraform apply`/`destroy` | `kubectl get`, `terraform plan` |
| Database | `DROP TABLE`, `TRUNCATE TABLE` | `SELECT`, `INSERT` |
| Disk | `dd if=`, `mkfs` | — |
| Privilege / perms | `sudo`, `chmod 777`, `chown … root` | `chmod 644` |
| Remote-to-shell | `curl … \| sh`, `wget -O- … \| sh` | plain `curl`/`wget` downloads |

Plus any **file write/edit** tool call is gated whenever that tool is in
`AEGMIS_GATED_TOOLS` — the installer default gates the **shell only**, so file
writes run free out of the box until you add them.

Everything else — reads, listings, `ls`, routine deletes — runs untouched. In
**forward-all mode** (`AEGMIS_FORWARD_ALL=true`) these local patterns are bypassed
and every gated tool call is sent to the **server-side policy engine** instead,
where your Aegmis policies decide — any command you write a policy for. The
`policies.example.sh` reference ships **~23 more** ready-to-use destructive-action
regexes (`find -delete`, `shred`, `docker push`, `crontab -r`, cloud-CLI deletes,
`kill`/`shutdown`, and more).

---

## Guarding your paths (approval vs hard-block)

Two env vars control what happens when the agent tries to `rm` a path you care
about. Both take a comma-separated list of **literal dirs** or **`re:`-prefixed
regexes**, resolved against the command's cwd (so relative targets like `./work`
are caught too).

| Variable | A matching `rm`… | Reach for it when |
|---|---|---|
| `AEGMIS_PROTECTED_PATHS` | pauses for **Slack approval** — a human can still allow it | the path matters but is *sometimes* legitimately deleted |
| `AEGMIS_BLOCKED_PATHS` | is **denied locally, instantly** — no Slack, nothing to approve | the path must **never** be deleted by the agent |

If a path matches **both**, the hard block wins — it's checked first, before any
approval round-trip. Both are **local-mode** features (`AEGMIS_FORWARD_ALL=false`,
the installer default).

### Minimal steps

1. Open your env file: `~/.claude/.env.intrupt`
2. Add either variable — one path or many, comma-separated:

   ```bash
   # Ask a human before deleting these  →  approval
   export AEGMIS_PROTECTED_PATHS="$HOME/work,$HOME/important"

   # Never let the agent delete these   →  hard block (no approval)
   export AEGMIS_BLOCKED_PATHS="re:^$HOME$,$HOME/.ssh"
   ```
3. Reload it: `source ~/.claude/.env.intrupt` (or restart Claude Code).

### Examples

| Goal | Entry |
|---|---|
| Approve before wiping the home dir itself | `AEGMIS_PROTECTED_PATHS=re:^$HOME$` |
| Approve deletes of `work` + `important` (and their subtrees) | `AEGMIS_PROTECTED_PATHS=re:^$HOME/(work\|important)(/\|$)` |
| Hard-block `~/.ssh` and everything under it | `AEGMIS_BLOCKED_PATHS=$HOME/.ssh` |
| Hard-block the home dir itself (its contents still run free) | `AEGMIS_BLOCKED_PATHS=re:^$HOME$` |
| Mix — approve `work`, hard-block `~/.ssh` | `AEGMIS_PROTECTED_PATHS=$HOME/work` · `AEGMIS_BLOCKED_PATHS=$HOME/.ssh` |

---

## Configuration

All configuration is via environment variables.

| Variable | Required | Default | Description |
|---|---|---|---|
| `AEGMIS_BASE_URL` | yes | — | intrupt API base URL |
| `AEGMIS_API_KEY` | yes | — | API key from Account → API Keys |
| `AEGMIS_APPROVAL` | no | `true` | Master kill switch — set `false` to disable the gate entirely (allow all) |
| `AEGMIS_GATED_TOOLS` | no | `Bash,Write,Edit` | Comma-separated tool names to gate |
| `AEGMIS_TIMEOUT` | no | `600` | Max seconds to wait for a decision |
| `AEGMIS_POLL_INTERVAL` | no | `5` | Seconds between status polls |
| `AEGMIS_CHANNEL` | no | `slack` | Where the approval request is delivered — `slack` or `email` |
| `AEGMIS_BYPASS_PATTERNS` | no | — | Comma-separated regex patterns; matching Bash commands skip approval |
| `AEGMIS_PROTECTED_PATHS` | no | `re:^$HOME$` (set by installer) | Comma-separated dir(s) to also gate `rm` on — each dir **and everything under it**, cwd-resolved. List **one or many** (e.g. `~/work,~/secrets`). Prefix an entry with **`re:`** for a regex tested against the resolved absolute path, e.g. `re:^$HOME$` (home dir only) or `re:^$HOME/(work\|important)(/\|$)` |
| `AEGMIS_BLOCKED_PATHS` | no | — | Same syntax as `AEGMIS_PROTECTED_PATHS`, but an `rm` hitting one is **denied locally with no approval round-trip** — never sent to a human. Use for paths that must *never* be deleted. **Local mode only** (`AEGMIS_FORWARD_ALL=false`). |

**Approval channel:** requests go to **Slack** by default. To deliver them over **email** instead, set `AEGMIS_CHANNEL=email` in your env file.

### Allow-listing specific commands

If you want to exclude certain commands from approval even when they match a gated pattern, use `AEGMIS_BYPASS_PATTERNS`:

```bash
# Allow git push to a specific remote only
export AEGMIS_BYPASS_PATTERNS="git push staging"

# Allow terraform apply only in a non-prod directory
export AEGMIS_BYPASS_PATTERNS="terraform apply.*-var-file=dev\.tfvars"
```

Bypass patterns are checked first — they take precedence over gate patterns.

### Gating only specific tools

```bash
# Only gate shell commands, not file edits
export AEGMIS_GATED_TOOLS=Bash

# Gate everything including sub-agent spawning
export AEGMIS_GATED_TOOLS=Bash,Write,Edit,Agent
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
            "command": "python3 ~/.claude/hooks/intrupt_hook.py",
            "timeout": 630
          }
        ]
      }
    ]
  }
}
```

To add it manually, merge this block into your existing `settings.json`.

> **Why `"timeout": 630`?** The hook blocks while it waits for a human (up to
> `AEGMIS_TIMEOUT`, default 600s). Claude Code's default per-hook timeout is far
> shorter (~60s), and a hook Claude Code kills is a **non-blocking** error — the
> tool would run. The `630` here must always exceed `AEGMIS_TIMEOUT`.

---

## Example: catastrophic-deletion gate + protecting your own paths

In **local mode** (`AEGMIS_FORWARD_ALL=false`) the hook gates only *catastrophic*
deletions and lets routine ones run untouched:

```bash
rm abc.txt                 # runs   — routine single-file delete
rm -rf node_modules        # runs   — project-local
rm -rf ~                   # ⛔ approval — wipes home
rm -rf /                   # ⛔ approval — wipes root
rm *                       # ⛔ approval — bare glob
```

To also require approval before deleting **specific dirs of yours**, list them:

```bash
export AEGMIS_PROTECTED_PATHS=/Users/you/work,/Users/you/important
```

### `AEGMIS_PROTECTED_PATHS` — literal paths and `re:` regexes

Comma-separated entries — each a **literal** dir or a **`re:`**-prefixed **regex** (the regex is tested against the resolved absolute `rm` target):

| Entry | Effect |
|---|---|
| `re:^$HOME$` | gate `rm` of the **home dir itself only** — `rm -rf ~` gates, but `rm -rf ~/project` and `rm ~/notes.txt` run free *(installer default)* |
| `re:^$HOME/(work\|important)(/\|$)` | gate the `work` + `important` **subtrees** |
| `~/work,re:^$HOME$` | **mixed** — literal `work` subtree *and* regex home-exact both gate; anything else runs free |
| `~/work` | plain **literal** — that dir and everything under it |

Anchor a regex with `^…$` to match a dir exactly (not its contents). Invalid regexes are skipped with a stderr warning.

**Worked examples** (write these as `AEGMIS_PROTECTED_PATHS` entries; `$HOME` expands when the env file is sourced):

| Intent | Entry |
|---|---|
| Protect **only the home dir itself**, not its contents | `re:^$HOME$` |
| Protect `work` + `important` (and their subtrees) | `re:^$HOME/(work\|important)(/\|$)` |
| Protect `project/demo` **except** `project/demo/scratch` | `re:^$HOME/project/demo/(?!scratch(/\|$)).*` |
| Protect any `.env` / secrets file anywhere under home | `re:^$HOME/.*(\.env(\|\.)\|/secrets?/)` |
| Multiple, mixed with literal | `$HOME/work,re:^$HOME$` |


Targets are resolved against the command's working directory, so relative refs are
caught too:

```bash
# with AEGMIS_PROTECTED_PATHS=/Users/you/work
cd /Users/you && rm -rf ./work     # ⛔ approval  (./work → /Users/you/work)
rm -rf /Users/you/work/build       # ⛔ approval  (under a protected dir)
rm -rf /Users/you/other            # runs        — not protected
```

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
[PASS] Bash — rm -rf ~ (catastrophic, gated)
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
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /home/user"}}' \
  | python3 hook.py
```

You should see a Slack message appear within a few seconds.

---

## Defense in depth — pair the hook with the sandbox

This hook is an **approval gate on the agent's declared tool calls**. It reasons
about a command string, so a determined agent can still evade a pattern denylist
(obfuscation, a written-then-executed script, a subprocess it never surfaces).
For real containment, run it **on top of Claude Code's native sandbox**, which
enforces limits at the OS level where the agent can't reach:

```json
{
  "sandbox": {
    "enabled": true,
    "network": { "allowedDomains": ["api.aegmis.com", "github.com"] },
    "filesystem": {
      "denyWrite": ["~/.ssh", "~/.claude", "~/.aws"],
      "denyRead":  ["~/.ssh", "~/.aws"]
    }
  }
}
```

Deny-by-default network stops the "push the codebase somewhere public" class
outright; filesystem `denyWrite` stops edits to your secrets and to this hook's
own config. Think of it as: **sandbox = the wall, `permissions.deny` = tripwires
that never ask, this hook = the doorbell for the ambiguous middle.**

## Security notes

- The hook **fails closed**: on reject, timeout, unreachable API, missing config,
  or a crash, the tool call is **blocked** (exit 2) — never allowed. The block is
  the process **exit code**, so it holds even under `--dangerously-skip-permissions`.
- **Workspace & self-protection always apply** (both modes): wiping the project
  dir or an ancestor (`rm -rf .`, `rm -rf "$HOME"`, `find . -delete`, `git clean -fdx`)
  is gated, and writes/edits to the hook's own config (`~/.claude/…`) are gated
  even when `AEGMIS_GATED_TOOLS` lists only `Bash`.
- Command **chains are split** (`&&`, `||`, `;`, `|`) and each segment is judged
  on its own, so a benign first command can't shield a risky one, and a bypass
  pattern only waives the segment it matches.
- `AEGMIS_API_KEY` is sent as a `Bearer` token. Keep it out of your shell history and `.bashrc` — use a secrets manager or the `.env.intrupt` file with `600` permissions.
- The hook never stores or logs the tool input beyond what is sent to the API.

---

## Project structure

```
claude-intrupt-hook/
├── hook.py          # PreToolUse hook script (zero runtime dependencies)
├── test_hook.py     # Smoke tests for gating logic
├── install.sh       # One-line installer (curl-pipe or from a clone)
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
