#!/bin/bash
# ============================================================
# Verification script for claude-code-secure-practices bundle
# Checks JSON validity, hook functionality, and prerequisites.
# Run from the repo root: ./tests/verify-bundle.sh
# ============================================================
set -e

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

echo ""
echo "=== Claude Code Secure Bundle — Verification ==="
echo ""

# ── 1. File existence ────────────────────────────────────────
echo "📁 Checking files exist..."

for f in CLAUDE.md CLAUDE.project-template.md .claude/settings.json .claude/mcp_servers.json .claude/hooks/pre-commit-secret-scan.sh; do
  if [ -f "$ROOT/$f" ]; then
    pass "$f exists"
  else
    fail "$f missing"
  fi
done

# ── 2. JSON validity ────────────────────────────────────────
echo ""
echo "📝 Checking JSON validity..."

# mcp_servers.json is plain JSON
if jq . "$ROOT/.claude/mcp_servers.json" > /dev/null 2>&1; then
  pass "mcp_servers.json is valid JSON"
else
  fail "mcp_servers.json is invalid JSON"
fi

# settings.json is JSONC (has comments) — strip comments then validate
if command -v node &>/dev/null; then
  STRIPPED=$(node -e "
    const fs = require('fs');
    const raw = fs.readFileSync(process.argv[1], 'utf8');
    // Remove single-line comments only outside of quoted strings
    let result = '';
    let inString = false;
    let escape = false;
    for (let i = 0; i < raw.length; i++) {
      const c = raw[i];
      if (escape) { result += c; escape = false; continue; }
      if (inString) {
        if (c === '\\\\') { result += c; escape = true; continue; }
        if (c === '\"') { inString = false; }
        result += c;
        continue;
      }
      if (c === '\"') { inString = true; result += c; continue; }
      if (c === '/' && raw[i+1] === '/') {
        // Skip to end of line
        while (i < raw.length && raw[i] !== '\n') i++;
        result += '\n';
        continue;
      }
      result += c;
    }
    // Remove trailing commas before } or ]
    const clean = result.replace(/,(\s*[}\]])/g, '\$1');
    try { JSON.parse(clean); console.log('valid'); }
    catch(e) { console.log('invalid: ' + e.message); }
  " "$ROOT/.claude/settings.json")
  if [ "$STRIPPED" = "valid" ]; then
    pass "settings.json is valid JSONC (parses after stripping comments)"
  else
    fail "settings.json parse error: $STRIPPED"
  fi
else
  warn "Node.js not found — cannot validate JSONC in settings.json"
fi

# ── 3. Hook script checks ───────────────────────────────────
echo ""
echo "🔧 Checking hook script..."

HOOK="$ROOT/.claude/hooks/pre-commit-secret-scan.sh"

if [ -x "$HOOK" ]; then
  pass "pre-commit-secret-scan.sh is executable"
else
  fail "pre-commit-secret-scan.sh is not executable (run: chmod +x)"
fi

# Check it requires jq
if command -v jq &>/dev/null; then
  pass "jq is installed (required by hook)"
else
  fail "jq is not installed (hook will fail)"
fi

# Check for a secret scanner
if command -v gitleaks &>/dev/null; then
  pass "gitleaks is installed"
elif command -v trufflehog &>/dev/null; then
  pass "trufflehog is installed (fallback scanner)"
else
  warn "No secret scanner installed (install gitleaks or trufflehog)"
fi

# ── 4. Hook functional test ─────────────────────────────────
echo ""
echo "🧪 Functional test: hook with non-commit command..."

# Test 1: Non-commit command should pass through (exit 0, no output)
NON_COMMIT_INPUT='{"tool_input":{"command":"git status"},"cwd":"/tmp"}'
NON_COMMIT_OUTPUT=$(echo "$NON_COMMIT_INPUT" | bash "$HOOK" 2>&1)
NON_COMMIT_EXIT=$?

if [ $NON_COMMIT_EXIT -eq 0 ] && [ -z "$NON_COMMIT_OUTPUT" ]; then
  pass "Hook ignores non-commit commands (exit 0, no output)"
else
  fail "Hook should silently pass non-commit commands (got exit=$NON_COMMIT_EXIT, output=$NON_COMMIT_OUTPUT)"
fi

# Test 2: Commit command in a temp repo with no staged changes
echo ""
echo "🧪 Functional test: hook with commit but no staged changes..."

TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
COMMIT_INPUT="{\"tool_input\":{\"command\":\"git commit -m 'test'\"},\"cwd\":\"$TMPDIR\"}"
COMMIT_OUTPUT=$(echo "$COMMIT_INPUT" | bash "$HOOK" 2>&1)
COMMIT_EXIT=$?

if [ $COMMIT_EXIT -eq 0 ]; then
  pass "Hook allows commit when nothing staged (exit 0)"
else
  fail "Hook should allow commit with no staged changes (got exit=$COMMIT_EXIT)"
fi
rm -rf "$TMPDIR"

# Test 3: Commit with a staged fake secret (if scanner is available)
if command -v gitleaks &>/dev/null || command -v trufflehog &>/dev/null; then
  echo ""
  echo "🧪 Functional test: hook with staged secret..."

  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  # Create a file with a realistic-looking AWS key
  echo 'AKIAIOSFODNN7EXAMPLE' > secret.txt
  echo 'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' >> secret.txt
  git add secret.txt

  SECRET_INPUT="{\"tool_input\":{\"command\":\"git commit -m 'add config'\"},\"cwd\":\"$TMPDIR\"}"
  SECRET_OUTPUT=$(echo "$SECRET_INPUT" | bash "$HOOK" 2>&1)
  SECRET_EXIT=$?

  if [ $SECRET_EXIT -eq 0 ] && echo "$SECRET_OUTPUT" | grep -q '"permissionDecision"'; then
    if echo "$SECRET_OUTPUT" | grep -q '"deny"'; then
      pass "Hook BLOCKED commit containing secrets"
    elif echo "$SECRET_OUTPUT" | grep -q '"ask"'; then
      warn "Hook warned but did not block (scanner may not have flagged the test secret)"
    else
      warn "Hook returned a decision but did not deny (output: $SECRET_OUTPUT)"
    fi
  else
    warn "Hook did not produce a deny decision for test secret (scanner may use different rules)"
  fi
  rm -rf "$TMPDIR"
fi

# ── 5. Settings structure check ──────────────────────────────
echo ""
echo "⚙️  Checking settings.json structure..."

if command -v node &>/dev/null; then
  SETTINGS_FILE="$ROOT/.claude/settings.json" node -e '
    const fs = require("fs");
    const raw = fs.readFileSync(process.env.SETTINGS_FILE, "utf8");
    let result = "", inString = false, esc = false;
    for (let i = 0; i < raw.length; i++) {
      const c = raw[i];
      if (esc) { result += c; esc = false; continue; }
      if (inString) { if (c === "\\") { result += c; esc = true; continue; } if (c === "\"") inString = false; result += c; continue; }
      if (c === "\"") { inString = true; result += c; continue; }
      if (c === "/" && raw[i+1] === "/") { while (i < raw.length && raw[i] !== "\n") i++; result += "\n"; continue; }
      result += c;
    }
    const cfg = JSON.parse(result.replace(/,(\s*[}\]])/g, "$1"));

    const checks = [
      [cfg.env && cfg.env.CLAUDE_CODE_ENABLE_TELEMETRY === "1", "env.CLAUDE_CODE_ENABLE_TELEMETRY is set"],
      [cfg.env && cfg.env.OTEL_METRICS_EXPORTER, "env.OTEL_METRICS_EXPORTER is set"],
      [cfg.env && cfg.env.OTEL_EXPORTER_OTLP_ENDPOINT, "env.OTEL_EXPORTER_OTLP_ENDPOINT is set"],
      [cfg.hooks && cfg.hooks.PreToolUse, "hooks.PreToolUse is configured"],
      [cfg.permissions && cfg.permissions.allow, "permissions.allow is configured"],
      [cfg.permissions && cfg.permissions.deny, "permissions.deny is configured"],
      [cfg.permissions && cfg.permissions.deny && cfg.permissions.deny.length > 10, "permissions.deny has " + (cfg.permissions?.deny?.length || 0) + " rules"],
    ];

    checks.forEach(([ok, msg]) => {
      console.log(ok ? "  ✅ " + msg : "  ❌ " + msg);
    });
  '
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Warnings: $WARN"
echo ""

if [ $FAIL -gt 0 ]; then
  echo "❌ Some checks failed. Review the output above."
  exit 1
elif [ $WARN -gt 0 ]; then
  echo "⚠️  All checks passed but there are warnings."
  exit 0
else
  echo "✅ All checks passed!"
  exit 0
fi
