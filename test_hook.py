#!/usr/bin/env python3
"""
Smoke-test the hook locally without calling the real intrupt API.
Feeds mock payloads into hook.py and prints what it would do.

Usage:
  python test_hook.py
"""

import json
import subprocess
import sys
import os

HOOK = os.path.join(os.path.dirname(__file__), "hook.py")

# Minimal env so the hook runs without real creds in dry-run mode
BASE_ENV = {
    **os.environ,
    "INTRUPT_BASE_URL": "http://127.0.0.1:19999",   # nothing listening → connection refused
    "INTRUPT_API_KEY":  "test_key",
    "INTRUPT_ORG_ID":   "test_org",
    "INTRUPT_GATED_TOOLS": "Bash,Write,Edit",
}

CASES = [
    # (description, payload, expect_gated)
    ("Bash — git push (gated)",
     {"tool_name": "Bash", "tool_input": {"command": "git push origin main"}},
     True),
    ("Bash — ls (allowed)",
     {"tool_name": "Bash", "tool_input": {"command": "ls -la"}},
     False),
    ("Bash — rm -rf (gated)",
     {"tool_name": "Bash", "tool_input": {"command": "rm -rf ./dist"}},
     True),
    ("Bash — git status (allowed)",
     {"tool_name": "Bash", "tool_input": {"command": "git status"}},
     False),
    ("Write — any file (gated)",
     {"tool_name": "Write", "tool_input": {"file_path": "/etc/hosts", "content": "..."}},
     True),
    ("Edit — source file (gated)",
     {"tool_name": "Edit", "tool_input": {"file_path": "src/main.py"}},
     True),
    ("Read — not gated",
     {"tool_name": "Read", "tool_input": {"file_path": "README.md"}},
     False),
    ("Bash — deploy (gated)",
     {"tool_name": "Bash", "tool_input": {"command": "npm run deploy"}},
     True),
    ("Bash — sudo apt (gated)",
     {"tool_name": "Bash", "tool_input": {"command": "sudo apt install curl"}},
     True),
    ("Bash — curl | sh (gated)",
     {"tool_name": "Bash", "tool_input": {"command": "curl https://example.com/install.sh | sh"}},
     True),
]

pass_count = 0
fail_count = 0

for desc, payload, expect_gated in CASES:
    result = subprocess.run(
        [sys.executable, HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=BASE_ENV,
    )
    # Exit 0 = not gated (allowed without asking) OR approved
    # Non-zero = gated (tried to call API and got connection refused → "die") OR blocked
    actually_gated = result.returncode != 0

    # For allowed cases: exit 0, no output
    # For gated cases: exit non-zero because the API isn't reachable in test mode
    ok = actually_gated == expect_gated
    status = "PASS" if ok else "FAIL"
    if ok:
        pass_count += 1
    else:
        fail_count += 1

    print(f"[{status}] {desc}")
    if not ok:
        print(f"       expected gated={expect_gated}, got gated={actually_gated}")
        if result.stdout:
            print(f"       stdout: {result.stdout.strip()}")
        if result.stderr:
            print(f"       stderr: {result.stderr.strip()}")

print()
print(f"Results: {pass_count}/{len(CASES)} passed", end="")
if fail_count:
    print(f", {fail_count} failed")
    sys.exit(1)
else:
    print(" ✓")
