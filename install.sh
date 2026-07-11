#!/usr/bin/env bash
# Installs the intrupt PreToolUse hook into Claude Code.
#
# One-line install (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/Aegmis/claude-intrupt-hook/main/install.sh | bash
#
# Or, after cloning:
#   bash install.sh

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

REPO_RAW="${AEGMIS_REPO_RAW:-https://raw.githubusercontent.com/Aegmis/claude-intrupt-hook/main}"

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_DEST="$HOOKS_DIR/intrupt_hook.py"
ENV_FILE="$HOME/.claude/.env.intrupt"

# Directory of this script when run from a clone; empty when piped via curl.
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

# fetch <relative-path> <dest>
# Uses the local file if this script runs from a clone; otherwise downloads it.
fetch() {
  local rel="$1" dest="$2"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$rel" ]; then
    cp "$SCRIPT_DIR/$rel" "$dest"
  elif command -v curl &>/dev/null; then
    curl -fsSL "$REPO_RAW/$rel" -o "$dest"
  elif command -v wget &>/dev/null; then
    wget -qO "$dest" "$REPO_RAW/$rel"
  else
    echo "✗ Need curl or wget to download $rel" >&2
    exit 1
  fi
}

# ── Install hook script ──────────────────────────────────────────────────────

echo "→ Creating hooks directory: $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"

echo "→ Installing hook script"
fetch "hook.py" "$HOOK_DEST"
chmod +x "$HOOK_DEST"

# ── Merge settings.json ──────────────────────────────────────────────────────

SETTINGS_JSON='{
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
}'

merge_settings() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "→ Creating $SETTINGS_FILE"
    printf '%s\n' "$SETTINGS_JSON" > "$SETTINGS_FILE"
    return
  fi

  if command -v jq &>/dev/null; then
    echo "→ Merging hooks into existing $SETTINGS_FILE"
    tmp=$(mktemp)
    jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(printf '%s' "$SETTINGS_JSON") > "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
    echo "   Merged."
  else
    echo ""
    echo "⚠  jq not found — please manually add the following to $SETTINGS_FILE:"
    echo ""
    printf '%s\n' "$SETTINGS_JSON"
    echo ""
  fi
}

merge_settings

# ── Environment variables ────────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
  echo "→ Creating env file at $ENV_FILE"
  cat > "$ENV_FILE" <<'EOF'
# intrupt hook configuration — sourced by the hook script via direnv or shell profile
export AEGMIS_BASE_URL=https://api.aegmis.com
export AEGMIS_API_KEY=sk_org_xxxx_yyyy      # replace with your API key
export AEGMIS_APPROVAL=true          # set false to disable the gate entirely
export AEGMIS_GATED_TOOLS=Bash,Write,Edit
export AEGMIS_TIMEOUT=600
export AEGMIS_POLL_INTERVAL=5
# AEGMIS_PROTECTED_PATHS=/Users/you/work,/data   # extra dirs to gate rm on
EOF
  echo ""
  echo "   Edit $ENV_FILE and fill in your AEGMIS_API_KEY."
  echo "   Then add this to your ~/.zshrc or ~/.bashrc:"
  echo ""
  echo "     source $ENV_FILE"
  echo ""
fi

echo ""
echo "✓ Installation complete."
echo ""
echo "  Hook:     $HOOK_DEST"
echo "  Settings: $SETTINGS_FILE"
echo ""
echo "  Next steps:"
echo "  1. Edit $ENV_FILE with your API key"
echo "  2. Add  source $ENV_FILE  to ~/.zshrc (or ~/.bashrc)"
echo "  3. Restart your shell or run:  source $ENV_FILE"
echo "  4. Open Claude Code and try a gated command (e.g. git push)"
echo ""
