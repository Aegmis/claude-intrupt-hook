#!/usr/bin/env python3
"""
Claude Code PreToolUse hook — intrupt approval gate.

Reads a tool-call payload from stdin, POSTs to the intrupt API to create
a pending approval (which notifies the approver via Slack), then polls
until a human decides. Exits 0 (approved) or 1 (rejected / timeout).

Environment variables (required):
  INTRUPT_BASE_URL   Base URL of the intrupt approval API (e.g. https://api.aegmis.com)
  INTRUPT_API_KEY    API key from Account → API Keys (org ID is extracted automatically)

Optional:
  INTRUPT_GATED_TOOLS     Comma-separated tool names to gate. Default: Bash,Write,Edit
  INTRUPT_TIMEOUT         Max seconds to wait for a decision. Default: 600 (10 min)
  INTRUPT_POLL_INTERVAL   Seconds between status polls. Default: 5
  INTRUPT_BYPASS_PATTERNS Comma-separated regex patterns for Bash commands that
                           skip approval (allow-list). Overrides BASH_GATE_PATTERNS.
"""

import json
import os
import re
import sys
import time
import uuid
import urllib.request
import urllib.error
from typing import Optional

# ── Configuration ─────────────────────────────────────────────────────────────

BASE_URL       = os.environ.get("INTRUPT_BASE_URL", "https://api.aegmis.com").rstrip("/")
API_KEY        = os.environ.get("INTRUPT_API_KEY", "")
TIMEOUT        = int(os.environ.get("INTRUPT_TIMEOUT", "600"))
POLL_INTERVAL  = int(os.environ.get("INTRUPT_POLL_INTERVAL", "5"))

GATED_TOOLS = {
    t.strip()
    for t in os.environ.get("INTRUPT_GATED_TOOLS", "Bash,Write,Edit").split(",")
    if t.strip()
}

# Bash commands matching ANY of these patterns require approval.
# Keep patterns specific to reduce interruption noise.
BASH_GATE_PATTERNS: list[str] = [
    r"\brm\s+.*-[a-z]*r",          # recursive delete: rm -rf, rm -r
    r"\brm\s+.*-[a-z]*f",          # force delete
    r"\bgit\s+push\b",             # any git push (including --force)
    r"\bgit\s+reset\s+--hard\b",
    r"\bgh\s+pr\s+merge\b",
    r"\bgh\s+release\b",
    r"\bnpm\s+publish\b",
    r"\bdeploy\b",
    r"\bkubectl\s+delete\b",
    r"\bkubectl\s+apply\b",
    r"\bterraform\s+apply\b",
    r"\bterraform\s+destroy\b",
    r"DROP\s+TABLE",
    r"TRUNCATE\s+TABLE",
    r"\bdd\s+if=",                 # disk operations
    r"\bmkfs\b",
    r"\bsudo\b",
    r"\bchmod\s+[0-7]*7[0-7][0-7]\b",  # world-writable
    r"\bchown\b.*root",
    r"\bcurl\b.*\|\s*(ba)?sh\b",   # pipe to shell
    r"\bwget\b.*-O\s*-\b.*\|\s*(ba)?sh\b",
]

# Compile once at startup
_COMPILED = [re.compile(p, re.IGNORECASE) for p in BASH_GATE_PATTERNS]

# Optional allow-list: patterns whose matching Bash commands bypass approval
_BYPASS_RAW = os.environ.get("INTRUPT_BYPASS_PATTERNS", "")
_BYPASS = [re.compile(p, re.IGNORECASE) for p in _BYPASS_RAW.split(",") if p.strip()]


# ── Helpers ────────────────────────────────────────────────────────────────────

def _extract_org_id(api_key: str) -> str:
    """Extract org_id from API key format: sk_org_{org_id}_{hash}."""
    if not api_key.startswith("sk_org_"):
        _die("Invalid INTRUPT_API_KEY format — expected 'sk_org_{org_id}_{hash}'")
    after_prefix = api_key[7:]  # strip "sk_org_"
    last_underscore = after_prefix.rfind("_")
    if last_underscore == -1:
        _die("Invalid INTRUPT_API_KEY format — expected 'sk_org_{org_id}_{hash}'")
    org_id = after_prefix[:last_underscore]
    if not org_id.startswith("org_"):
        _die(f"Could not extract org ID from API key — got '{org_id}'")
    return org_id


def _api(method: str, path: str, body: Optional[dict] = None) -> dict:
    """Minimal HTTP client using only stdlib — no dependencies required."""
    url  = f"{BASE_URL}{path}"
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Content-Type":  "application/json",
            "Authorization": f"Bearer {API_KEY}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode(errors="replace")
        _die(f"intrupt API {method} {path} → HTTP {exc.code}: {body_text}")
    except urllib.error.URLError as exc:
        _die(f"intrupt API unreachable ({exc.reason}). Is INTRUPT_BASE_URL correct?")


def _block(reason: str) -> None:
    """Print a block decision and exit non-zero."""
    print(json.dumps({"decision": "block", "reason": reason}), flush=True)
    sys.exit(1)


def _die(msg: str) -> None:
    """Fatal error — block the tool call and report why."""
    _block(f"[intrupt hook error] {msg}")


def _should_gate_bash(command: str) -> tuple[bool, str]:
    """
    Returns (gate, matched_pattern).
    Gate if command matches any BASH_GATE_PATTERNS and no BYPASS pattern.
    """
    # Check bypass first — allow-list wins
    for bypass in _BYPASS:
        if bypass.search(command):
            return False, ""
    for pattern in _COMPILED:
        if pattern.search(command):
            return True, pattern.pattern
    return False, ""


def _human_description(tool_name: str, tool_input: dict) -> tuple[str, str]:
    """Return (action_slug, human_message) for the approval notification."""
    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        short = cmd.split("\n")[0][:120]
        return "bash_command", f"Run: `{short}`"
    if tool_name == "Write":
        path = tool_input.get("file_path", "unknown")
        return "write_file", f"Write file: `{path}`"
    if tool_name == "Edit":
        path = tool_input.get("file_path", "unknown")
        return "edit_file", f"Edit file: `{path}`"
    return tool_name.lower(), f"Claude Code wants to call `{tool_name}`"


# ── Main ────────────────────────────────────────────────────────────────────────

def main() -> None:
    # 1. Parse stdin payload from Claude Code
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        _die("Could not parse hook payload from stdin")

    tool_name  = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {})

    # 2. Decide whether to gate this call
    if tool_name not in GATED_TOOLS:
        sys.exit(0)  # not gated — allow immediately

    if tool_name == "Bash":
        command = tool_input.get("command", "")
        gate, matched = _should_gate_bash(command)
        if not gate:
            sys.exit(0)  # low-risk command — allow

    # 3. Validate config before making any API calls
    if not API_KEY:
        _die("INTRUPT_API_KEY is not set")
    org_id = _extract_org_id(API_KEY)

    action, message = _human_description(tool_name, tool_input)
    thread_id = str(uuid.uuid4())  # unique per hook invocation

    # 4. Create the approval request
    resp = _api("POST", f"/org/{org_id}/approval", {
        "thread_id":   thread_id,
        "action":      action,
        "message":     message,
        "channel":     "slack",
        "tool_name":   tool_name,
        "tool_kwargs": tool_input,
    })

    approval_id = resp.get("approval_id")
    if not approval_id:
        _die(f"API did not return approval_id: {resp}")

    # 5. Poll until decided or timeout
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        time.sleep(POLL_INTERVAL)
        status_resp = _api("GET", f"/org/{ORG_ID}/approval/{approval_id}")
        status = status_resp.get("status", "pending")

        if status == "approved":
            # Exit 0 — Claude Code proceeds with the tool call
            sys.exit(0)

        if status in ("rejected", "denied"):
            _block(f"Approval rejected by approver (approval_id={approval_id})")

        # status == "pending" → keep polling

    # Timeout — fail closed
    _block(
        f"Approval timed out after {TIMEOUT}s — tool call blocked "
        f"(approval_id={approval_id}). Approve or reject it in the dashboard."
    )


if __name__ == "__main__":
    main()
