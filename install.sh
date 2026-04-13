#!/bin/bash
# ============================================================
# Claude Code Secure Practices — One-line Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ehudmelzer/claude-code-secure-practices/main/install.sh | bash
#
# What it does:
#   1. Downloads all config files from the repo
#   2. MERGES them with existing config (never overwrites your rules)
#   3. Installs gitleaks (secret scanner) if missing
#   4. Verifies the installation
#
# By Pluto Security — https://pluto.security/
# ============================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/ehudmelzer/claude-code-secure-practices/main"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ── Colors ──────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[34m'
MAGENTA='\033[35m'
RESET='\033[0m'

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║                                                          ║"
echo "  ║        🔒  Claude Code Secure Practices                  ║"
echo "  ║                                                          ║"
echo "  ║        Hardened configuration for Claude Code             ║"
echo "  ║        endpoints in enterprise environments               ║"
echo "  ║                                                          ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${BOLD}Powered by ${MAGENTA}Pluto Security${RESET}  ${DIM}https://pluto.security/${RESET}"
echo ""
echo -e "  ${DIM}Pluto protects modern creation workflows — across AI builders,"
echo -e "  developer tools, and business workspaces — with visibility,"
echo -e "  risk understanding, and real-time guardrails.${RESET}"
echo ""
echo -e "${DIM}  ──────────────────────────────────────────────────────────${RESET}"
echo ""

# ── What will be installed ──────────────────────────────────
echo -e "${BOLD}📦 This installer will set up:${RESET}"
echo ""
echo -e "  ${GREEN}•${RESET} ${BOLD}CLAUDE.md${RESET}                — Anti-prompt-injection rules, secrets protection,"
echo -e "                                cloud/infra guardrails, shell execution policy"
echo -e "  ${GREEN}•${RESET} ${BOLD}settings.json${RESET}            — Tool permission allow/deny list, OpenTelemetry"
echo -e "                                telemetry export"
echo -e "  ${GREEN}•${RESET} ${BOLD}mcp_servers.json${RESET}         — Empty MCP baseline (secure by default)"
echo -e "  ${GREEN}•${RESET} ${BOLD}pre-commit-secret-scan${RESET}   — Hook that blocks commits containing secrets"
echo -e "  ${GREEN}•${RESET} ${BOLD}gitleaks${RESET}                 — Secret scanner (if not already installed)"
echo ""
echo -e "  ${YELLOW}ℹ${RESET}  Existing configs will be ${BOLD}merged${RESET}, never overwritten."
echo -e "  ${YELLOW}ℹ${RESET}  Backups are created before any changes."
echo ""
echo -e "${DIM}  ──────────────────────────────────────────────────────────${RESET}"
echo ""

# ── 1. Check prerequisites ──────────────────────────────────
echo -e "${BOLD}🔧 Checking prerequisites...${RESET}"
echo ""

PREREQ_OK=true

if command -v node &>/dev/null; then
  echo -e "  ${GREEN}✅${RESET} node $(node --version)"
else
  echo -e "  ${RED}❌${RESET} node not found (required for JSONC parsing and config merge)"
  PREREQ_OK=false
fi

if command -v jq &>/dev/null; then
  echo -e "  ${GREEN}✅${RESET} jq $(jq --version)"
else
  echo -e "  ${RED}❌${RESET} jq not found (required for JSON merge and secret scan hook)"
  PREREQ_OK=false
fi

if command -v curl &>/dev/null; then
  echo -e "  ${GREEN}✅${RESET} curl available"
else
  echo -e "  ${RED}❌${RESET} curl not found"
  PREREQ_OK=false
fi

if [ "$PREREQ_OK" = false ]; then
  echo ""
  echo -e "  ${RED}Missing prerequisites. Please install them and re-run.${RESET}"
  exit 1
fi

echo ""

# ── 2. Create directories ───────────────────────────────────
echo -e "${BOLD}📁 Creating directories...${RESET}"
mkdir -p ~/.claude/hooks
echo -e "  ${GREEN}✅${RESET} ~/.claude/hooks"
echo ""

# ── 3. Download files to temp ────────────────────────────────
echo -e "${BOLD}📥 Downloading configuration files...${RESET}"
echo ""

download() {
  if curl -fsSL "$REPO_RAW/$1" -o "$TMPDIR/$2" 2>/dev/null; then
    echo -e "  ${GREEN}✅${RESET} $1"
  else
    echo -e "  ${RED}❌${RESET} Failed to download $1"
    return 1
  fi
}

download "CLAUDE.md"                                "CLAUDE.md"
download ".claude/settings.json"                    "settings.json"
download ".claude/mcp_servers.json"                 "mcp_servers.json"
download ".claude/hooks/pre-commit-secret-scan.sh"  "pre-commit-secret-scan.sh"

echo ""

# ── 4. Merge CLAUDE.md (append if exists) ────────────────────
echo -e "${BOLD}📝 Installing CLAUDE.md...${RESET}"

if [ -f ~/.claude/CLAUDE.md ]; then
  if grep -q "Anti-Prompt Injection — HIGHEST PRIORITY" ~/.claude/CLAUDE.md 2>/dev/null; then
    echo -e "  ${YELLOW}⏭️${RESET}  Already contains Pluto security rules — skipping"
  else
    cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.backup.$(date +%s)
    echo -e "  ${DIM}💾 Backed up existing file${RESET}"
    echo "" >> ~/.claude/CLAUDE.md
    echo "# ── Pluto Security Rules (added by installer) ──────────────" >> ~/.claude/CLAUDE.md
    echo "" >> ~/.claude/CLAUDE.md
    cat "$TMPDIR/CLAUDE.md" >> ~/.claude/CLAUDE.md
    echo -e "  ${GREEN}✅${RESET} Appended security rules to existing CLAUDE.md"
  fi
else
  cp "$TMPDIR/CLAUDE.md" ~/.claude/CLAUDE.md
  echo -e "  ${GREEN}✅${RESET} Installed (new file)"
fi

echo ""

# ── 5. Merge settings.json (merge arrays & objects) ──────────
echo -e "${BOLD}⚙️  Installing settings.json...${RESET}"

# Helper: strip JSONC comments to valid JSON
strip_jsonc() {
  node -e '
    const fs = require("fs");
    const raw = fs.readFileSync(process.env.JSONC_FILE, "utf8");
    let result = "", inString = false, esc = false;
    for (let i = 0; i < raw.length; i++) {
      const c = raw[i];
      if (esc) { result += c; esc = false; continue; }
      if (inString) { if (c === "\\") { result += c; esc = true; continue; } if (c === "\"") inString = false; result += c; continue; }
      if (c === "\"") { inString = true; result += c; continue; }
      if (c === "/" && raw[i+1] === "/") { while (i < raw.length && raw[i] !== "\n") i++; result += "\n"; continue; }
      result += c;
    }
    process.stdout.write(result.replace(/,(\s*[}\]])/g, "$1"));
  '
}

if [ -f ~/.claude/settings.json ]; then
  cp ~/.claude/settings.json ~/.claude/settings.json.backup.$(date +%s)
  echo -e "  ${DIM}💾 Backed up existing file${RESET}"

  # Parse both files
  EXISTING=$(JSONC_FILE=~/.claude/settings.json strip_jsonc)
  NEW=$(JSONC_FILE="$TMPDIR/settings.json" strip_jsonc)

  # Merge with jq: combine arrays (deduplicate), merge objects
  MERGED=$(jq -n \
    --argjson existing "$EXISTING" \
    --argjson new "$NEW" '
    # Merge env: new keys added, existing keys preserved
    ($existing.env // {}) + ($new.env // {}) as $merged_env |

    # Merge permissions.allow: union of both arrays
    (($existing.permissions.allow // []) + ($new.permissions.allow // []) | unique) as $merged_allow |

    # Merge permissions.deny: union of both arrays
    (($existing.permissions.deny // []) + ($new.permissions.deny // []) | unique) as $merged_deny |

    # Merge hooks.PreToolUse: concatenate arrays
    (($existing.hooks.PreToolUse // []) + ($new.hooks.PreToolUse // [])) as $merged_pre_tool |

    # Build merged config
    $existing * $new |
    .env = $merged_env |
    .permissions.allow = $merged_allow |
    .permissions.deny = $merged_deny |
    .hooks.PreToolUse = $merged_pre_tool
  ')

  echo "$MERGED" | jq '.' > ~/.claude/settings.json

  # Show what was added
  EXISTING_DENY_COUNT=$(echo "$EXISTING" | jq '.permissions.deny // [] | length')
  MERGED_DENY_COUNT=$(echo "$MERGED" | jq '.permissions.deny | length')
  ADDED_DENY=$((MERGED_DENY_COUNT - EXISTING_DENY_COUNT))

  EXISTING_ALLOW_COUNT=$(echo "$EXISTING" | jq '.permissions.allow // [] | length')
  MERGED_ALLOW_COUNT=$(echo "$MERGED" | jq '.permissions.allow | length')
  ADDED_ALLOW=$((MERGED_ALLOW_COUNT - EXISTING_ALLOW_COUNT))

  echo -e "  ${GREEN}✅${RESET} Merged with existing config"
  if [ "$ADDED_DENY" -gt 0 ]; then
    echo -e "     ${DIM}+${ADDED_DENY} deny rules added${RESET}"
  fi
  if [ "$ADDED_ALLOW" -gt 0 ]; then
    echo -e "     ${DIM}+${ADDED_ALLOW} allow rules added${RESET}"
  fi
  if [ "$ADDED_DENY" -eq 0 ] && [ "$ADDED_ALLOW" -eq 0 ]; then
    echo -e "     ${DIM}All rules already present${RESET}"
  fi
else
  JSONC_FILE="$TMPDIR/settings.json" strip_jsonc | jq '.' > ~/.claude/settings.json 2>/dev/null || cp "$TMPDIR/settings.json" ~/.claude/settings.json
  echo -e "  ${GREEN}✅${RESET} Installed (new file)"
fi

echo ""

# ── 6. Install mcp_servers.json (only if missing) ───────────
echo -e "${BOLD}🌐 Installing mcp_servers.json...${RESET}"

if [ -f ~/.claude/mcp_servers.json ]; then
  echo -e "  ${YELLOW}⏭️${RESET}  Already exists — skipping"
else
  cp "$TMPDIR/mcp_servers.json" ~/.claude/mcp_servers.json
  echo -e "  ${GREEN}✅${RESET} Installed (new file)"
fi

echo ""

# ── 7. Install hook script (always overwrite) ────────────────
echo -e "${BOLD}🪝 Installing secret scanning hook...${RESET}"
cp "$TMPDIR/pre-commit-secret-scan.sh" ~/.claude/hooks/pre-commit-secret-scan.sh
chmod +x ~/.claude/hooks/pre-commit-secret-scan.sh
echo -e "  ${GREEN}✅${RESET} Installed pre-commit-secret-scan.sh"

echo ""

# ── 8. Install gitleaks if missing ──────────────────────────
echo -e "${BOLD}🔍 Secret scanner...${RESET}"

if command -v gitleaks &>/dev/null; then
  echo -e "  ${GREEN}✅${RESET} gitleaks $(gitleaks version 2>/dev/null || echo 'installed')"
elif command -v trufflehog &>/dev/null; then
  echo -e "  ${GREEN}✅${RESET} trufflehog installed (fallback scanner)"
else
  echo -e "  ${YELLOW}⚠️${RESET}  No secret scanner found"
  if command -v brew &>/dev/null; then
    echo -e "  ${CYAN}📦 Installing gitleaks via Homebrew...${RESET}"
    brew install gitleaks
    echo -e "  ${GREEN}✅${RESET} gitleaks installed"
  else
    echo -e "  ${DIM}   Install manually: brew install gitleaks${RESET}"
    echo -e "  ${DIM}   Or: https://github.com/gitleaks/gitleaks#installing${RESET}"
  fi
fi

echo ""
echo -e "${DIM}  ──────────────────────────────────────────────────────────${RESET}"
echo ""

# ── 9. Verification ─────────────────────────────────────────
echo -e "${BOLD}🧪 Verifying installation...${RESET}"
echo ""

PASS=0
TOTAL=0

check() {
  TOTAL=$((TOTAL+1))
  if [ "$1" = "true" ]; then
    echo -e "  ${GREEN}✅${RESET} $2"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}❌${RESET} $2"
  fi
}

check "$([ -f ~/.claude/CLAUDE.md ] && echo true)" "CLAUDE.md installed"
check "$(grep -q 'Anti-Prompt Injection' ~/.claude/CLAUDE.md 2>/dev/null && echo true)" "CLAUDE.md contains security rules"
check "$([ -f ~/.claude/settings.json ] && echo true)" "settings.json installed"
check "$([ -f ~/.claude/mcp_servers.json ] && echo true)" "mcp_servers.json installed"
check "$([ -x ~/.claude/hooks/pre-commit-secret-scan.sh ] && echo true)" "Secret scan hook executable"
check "$(command -v jq &>/dev/null && echo true)" "jq available"
check "$( (command -v gitleaks &>/dev/null || command -v trufflehog &>/dev/null) && echo true)" "Secret scanner available"

echo ""

if [ "$PASS" -eq "$TOTAL" ]; then
  echo -e "  ${GREEN}${BOLD}$PASS/$TOTAL checks passed${RESET}"
else
  echo -e "  ${YELLOW}${BOLD}$PASS/$TOTAL checks passed${RESET}"
fi

echo ""
echo -e "${DIM}  ──────────────────────────────────────────────────────────${RESET}"
echo ""

# ── 10. What was installed & next steps ──────────────────────
echo -e "${BOLD}📋 What's now active on this endpoint:${RESET}"
echo ""
echo -e "  ${GREEN}✔${RESET}  Anti-prompt-injection rules in every Claude session"
echo -e "  ${GREEN}✔${RESET}  Secrets/credentials file access blocked"
echo -e "  ${GREEN}✔${RESET}  Exfiltration commands (curl|bash, nc, etc.) blocked"
echo -e "  ${GREEN}✔${RESET}  Privilege escalation (sudo, su, chmod 777) blocked"
echo -e "  ${GREEN}✔${RESET}  Persistence mechanisms (crontab, launchctl) blocked"
echo -e "  ${GREEN}✔${RESET}  Cloud deletion commands hard-blocked"
echo -e "  ${GREEN}✔${RESET}  Pre-commit secret scanning on every git commit"
echo -e "  ${GREEN}✔${RESET}  OpenTelemetry telemetry export configured"
echo ""
echo -e "${BOLD}📋 Optional — configure manually:${RESET}"
echo ""
echo -e "  ${YELLOW}○${RESET}  Set your OTel collector endpoint in ~/.claude/settings.json"
echo -e "     ${DIM}Replace: http://YOUR_OTEL_COLLECTOR:4317${RESET}"
echo ""
echo -e "  ${YELLOW}○${RESET}  Add per-project rules to any repo:"
echo -e "     ${DIM}curl -fsSL $REPO_RAW/CLAUDE.project-template.md -o ./CLAUDE.md${RESET}"
echo ""
echo -e "  ${YELLOW}○${RESET}  Restart Claude Code for changes to take effect"
echo ""
echo -e "${DIM}  ──────────────────────────────────────────────────────────${RESET}"
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║                                                          ║"
echo "  ║              ✅  Installation Complete                    ║"
echo "  ║                                                          ║"
echo "  ║     Your Claude Code endpoint is now hardened.            ║"
echo "  ║                                                          ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${BOLD}Powered by ${MAGENTA}██████╗ ██╗     ██╗   ██╗████████╗ ██████╗ ${RESET}"
echo -e "  ${BOLD}          ${MAGENTA}██╔══██╗██║     ██║   ██║╚══██╔══╝██╔═══██╗${RESET}"
echo -e "  ${BOLD}          ${MAGENTA}██████╔╝██║     ██║   ██║   ██║   ██║   ██║${RESET}"
echo -e "  ${BOLD}          ${MAGENTA}██╔═══╝ ██║     ██║   ██║   ██║   ██║   ██║${RESET}"
echo -e "  ${BOLD}          ${MAGENTA}██║     ███████╗╚██████╔╝   ██║   ╚██████╔╝${RESET}"
echo -e "  ${BOLD}          ${MAGENTA}╚═╝     ╚══════╝ ╚═════╝    ╚═╝    ╚═════╝ ${RESET}"
echo -e "  ${BOLD}          ${MAGENTA}         S E C U R I T Y${RESET}"
echo ""
echo -e "  ${DIM}Protecting modern creation workflows with visibility,"
echo -e "  risk understanding, and real-time guardrails.${RESET}"
echo ""
echo -e "  ${BLUE}🔗 https://pluto.security/${RESET}"
echo -e "  ${BLUE}📖 https://github.com/ehudmelzer/claude-code-secure-practices${RESET}"
echo ""
