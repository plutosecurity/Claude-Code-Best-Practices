#!/bin/bash
# ============================================================
# Pre-commit Secret Scanner Hook for Claude Code
# Runs before any git commit to detect exposed secrets in
# staged changes. Blocks the commit if secrets are found.
#
# Supports: gitleaks, trufflehog (install one before use)
# Install gitleaks:   brew install gitleaks
# Install trufflehog: brew install trufflehog
# ============================================================
set -e

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Only intercept git commit commands
if ! echo "$COMMAND" | grep -qE '^git commit'; then
  exit 0
fi

cd "$CWD"

# Check if there are staged changes to scan
if git diff --cached --quiet 2>/dev/null; then
  # Nothing staged — allow (could be --allow-empty or amend)
  exit 0
fi

# ── Try gitleaks first, fall back to trufflehog ──────────────

if command -v gitleaks &>/dev/null; then
  # gitleaks exits non-zero when leaks are found, zero when clean.
  # Capture both output and exit code without tripping `set -e`.
  if ! SCAN_OUTPUT=$(git diff --cached | gitleaks detect --pipe --no-banner 2>&1); then
    jq -n \
      --arg reason "🚨 Secret scanner (gitleaks) blocked this commit. Secrets detected in staged changes — remove them before committing." \
      --arg detail "$SCAN_OUTPUT" \
      '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ($reason + "\n\n" + $detail)
        }
      }'
    exit 0
  fi

elif command -v trufflehog &>/dev/null; then
  # --fail makes trufflehog exit non-zero on findings.
  if ! SCAN_OUTPUT=$(git diff --cached | trufflehog --stdin --fail 2>&1); then
    jq -n \
      --arg reason "🚨 Secret scanner (trufflehog) blocked this commit. Secrets detected in staged changes — remove them before committing." \
      --arg detail "$SCAN_OUTPUT" \
      '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ($reason + "\n\n" + $detail)
        }
      }'
    exit 0
  fi

else
  # No scanner installed — warn but don't block
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "⚠️ No secret scanner installed (gitleaks or trufflehog). Commit will proceed but staged changes were NOT scanned for secrets."
    }
  }'
  exit 0
fi

# No secrets found — allow commit
exit 0
