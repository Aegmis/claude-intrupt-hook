#!/usr/bin/env bash
#
# Example Aegmis policies for the Claude Code PreToolUse hook.
#
# These route the hook's gated tool calls (Bash / Write / Edit) to the right
# Slack approver based on how dangerous the action is. Policies are evaluated
# in ASCENDING priority order — the first match wins — so the most specific /
# most dangerous rules use the LOWEST numbers.
#
# The hook POSTs an approval with:
#   tool_name  = "Bash" | "Write" | "Edit"
#   action     = "bash_command" | "write_file" | "edit_file"
#   tool_kwargs = { "command": ... }         for Bash
#                 { "file_path": ..., ... }  for Write / Edit
# Conditions below match against those tool_kwargs keys.
#
# Conditions use the engine's nested schema:
#   "conditions": { "logic": "AND", "rules": { "<key>": { "<op>": <val> } } }
# Operators: >, <, ==, regex, in.  Keys are matched against tool_kwargs.
#
# NOTE on trigger_actions: the hook sends action = "bash_command"/"write_file"/
# "edit_file" (NOT the tool name). We intentionally OMIT trigger_actions and
# filter on trigger_tool_names only — setting trigger_actions to ["Bash"] would
# never match and silently disable the policy.
#
# Group approvers dispatch to Slack channel  #approvals-{approver_id}
# e.g. approver_id "sre-team"  ->  #approvals-sre-team
#
# Usage:
#   export INTRUPT_BASE_URL=https://api.aegmis.com
#   export INTRUPT_API_KEY=sk_org_xxxx_yyyy
#   export ORG_ID=org_xxxx
#   ./policies.example.sh

set -euo pipefail

: "${INTRUPT_BASE_URL:?set INTRUPT_BASE_URL}"
: "${INTRUPT_API_KEY:?set INTRUPT_API_KEY}"
: "${ORG_ID:?set ORG_ID}"

create_policy() {
  curl -sS -X POST "$INTRUPT_BASE_URL/org/$ORG_ID/policies" \
    -H "Authorization: Bearer $INTRUPT_API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: intrupt-hook/1.0" \
    -d "$1"
  echo
}

# ── Priority 5 — hard cases that need a senior approver ──────────────────────
# Recursive/forced deletes, disk wipes: route to SRE.
create_policy '{
  "name": "claude-destructive-shell",
  "description": "Any rm — rm -rf and plain rm <file> — plus dd, mkfs",
  "trigger_tool_names": ["Bash"],
  "conditions": {
    "logic": "AND",
    "rules": {
      "command": { "regex": "\\brm\\s+.*-[a-z]*[rf]|\\brm\\s+|\\bmkfs\\b|\\bdd\\s+if=" }
    }
  },
  "approver_type": "group",
  "approver_id": "sre-team",
  "priority": 5
}'

# ── Priority 10 — production deploys & infrastructure changes ─────────────────
create_policy '{
  "name": "claude-deploy-and-infra",
  "description": "git push, terraform apply/destroy, kubectl apply/delete, deploy",
  "trigger_tool_names": ["Bash"],
  "conditions": {
    "logic": "AND",
    "rules": {
      "command": { "regex": "\\bgit\\s+push\\b|\\bterraform\\s+(apply|destroy)\\b|\\bkubectl\\s+(apply|delete)\\b|\\bdeploy\\b|\\bnpm\\s+publish\\b" }
    }
  },
  "approver_type": "group",
  "approver_id": "platform-team",
  "priority": 10
}'

# ── Priority 15 — edits to secrets / prod config ─────────────────────────────
# Matches Write AND Edit; file_path is present in tool_kwargs for both.
create_policy '{
  "name": "claude-protect-secrets",
  "description": "Writes/edits to .env, secrets, or prod config",
  "trigger_tool_names": ["Write", "Edit"],
  "conditions": {
    "logic": "AND",
    "rules": {
      "file_path": { "regex": "(^|/)\\.env($|\\.)|/secrets?/|/prod/" }
    }
  },
  "approver_type": "user",
  "approver_id": "U_AMIT_SLACK_ID",
  "priority": 15
}'

# NOTE: With the hook in forward-all mode (INTRUPT_FORWARD_ALL=true), EVERY
# Bash/Write/Edit call reaches the policy engine. Do NOT add a catch-all policy
# that matches everything — anything no policy matches is auto-approved, which
# is exactly what keeps routine commands (ls, cat, git status) friction-free.
# Add narrowly-scoped high-risk policies (like those above) and let the rest
# fall through to auto-approve.
