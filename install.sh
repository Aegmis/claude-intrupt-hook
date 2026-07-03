#!/usr/bin/env bash
# Installs the intrupt PreToolUse hook into Claude Code.
# Run once after cloning: bash install.sh

set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_SRC="$(cd "$(dirname "$0")" && pwd)/hook.py"
HOOK_DEST="$HOOKS_DIR/intrupt_hook.py"

echo "→ Creating hooks directory: $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"

echo "→ Copying hook script"
cp "$HOOK_SRC" "$HOOK_DEST"
chmod +x "$HOOK_DEST"

# ── Merge settings.json ──────────────────────────────────────────────────────

merge_settings() {
  local new_hook
  new_hook=$(cat "$(dirname "$0")/settings.json")

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "→ Creating $SETTINGS_FILE"
    cp "$(dirname "$0")/settings.json" "$SETTINGS_FILE"
    return
  fi

  # If jq is available, merge properly; otherwise print manual instructions
  if command -v jq &>/dev/null; then
    echo "→ Merging hooks into existing $SETTINGS_FILE"
    tmp=$(mktemp)
    jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(echo "$new_hook") > "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
    echo "   Merged."
  else
    echo ""
    echo "⚠  jq not found — please manually add the following to $SETTINGS_FILE:"
    echo ""
    cat "$(dirname "$0")/settings.json"
    echo ""
  fi
}

merge_settings

# ── Environment variables ────────────────────────────────────────────────────

ENV_FILE="$HOME/.claude/.env.intrupt"

if [ ! -f "$ENV_FILE" ]; then
  echo "→ Creating env file at $ENV_FILE"
  cat > "$ENV_FILE" <<'EOF'
# intrupt hook configuration — sourced by the hook script via direnv or shell profile
export INTRUPT_BASE_URL=https://api.aegmis.com
export INTRUPT_API_KEY=sk_org_xxxx_yyyy      # replace with your API key
export INTRUPT_ORG_ID=org_xxxx              # replace with your org ID
export INTRUPT_GATED_TOOLS=Bash,Write,Edit
export INTRUPT_TIMEOUT=600
export INTRUPT_POLL_INTERVAL=5
EOF
  echo ""
  echo "   Edit $ENV_FILE and fill in your INTRUPT_API_KEY and INTRUPT_ORG_ID."
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
echo "  1. Edit $ENV_FILE with your API key and org ID"
echo "  2. Add  source $ENV_FILE  to ~/.zshrc (or ~/.bashrc)"
echo "  3. Restart your shell or run:  source $ENV_FILE"
echo "  4. Open Claude Code and try a gated command (e.g. git push)"
echo ""
