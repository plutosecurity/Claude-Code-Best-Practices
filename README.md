# Claude Code — Secure Endpoint Configuration Reference

A reference set of hardened configuration files for running **Claude Code** safely on
enterprise and security-conscious endpoints. Covers behavioral rules, tool permissions,
MCP server policy, and prompt injection defenses.

This repo is intended as a **learning resource and starting point**: read it, understand
each file, then copy the pieces you want into your own `~/.claude/` directory. There is
no installer — the files are short enough to review and place by hand.

Built and maintained by **[Pluto Security](https://pluto.security/)**.

---

## Files in This Bundle

```
claude-code-secure/
├── README.md                         ← you are here
├── CLAUDE.md                         ← global behavioral rules (copy to ~/.claude/)
├── CLAUDE.project-template.md        ← per-repo template (copy to <project>/CLAUDE.md)
└── .claude/
    ├── settings.json                 ← tool permissions, telemetry & hooks
    ├── SETTINGS.md                   ← field-by-field rationale for settings.json
    ├── mcp_servers.json              ← MCP server configuration (ships empty)
    ├── MCP_SERVERS.md                ← rationale and templates for adding MCP servers
    └── hooks/
        └── pre-commit-secret-scan.sh ← blocks commits containing secrets
```

> The `.json` files are intentionally comment-free so Claude Code can parse them
> directly. The `SETTINGS.md` and `MCP_SERVERS.md` companion files carry the
> rationale that would otherwise live as comments in the JSON.

---

## What Each File Does

### `CLAUDE.md` — Global Behavioral Rules

This file is injected into every Claude Code session and defines non-negotiable security
policies. It covers:

- **Anti-Prompt Injection** — instructs Claude to never follow instructions embedded in
  file contents, code comments, README files, commit messages, test fixtures, HTML pages,
  API responses, or any other data source. Any injection attempt is flagged to the user.
- **Cloud & Infrastructure Protection** — prohibits creating, modifying, or deleting cloud
  resources (AWS, GCP, Azure, Terraform, Pulumi, CDK) without explicit user confirmation of
  the specific resource name and action. IAM roles, security groups, and firewall rules are
  off-limits.
- **Credentials & Secrets Handling** — blocks reading, printing, logging, or transmitting
  sensitive files (`.env`, `*.pem`, `*.key`, SSH keys, AWS/Kube configs, tokens, vault files,
  `.npmrc`, `.pypirc`, `*.htpasswd`). Secrets are never inserted into code, logs, or shell history.
- **Database Safety** — prevents destructive queries (`DROP`, `DELETE`, `TRUNCATE`,
  unscoped `UPDATE`) without explicit user confirmation. Production database connections
  require explicit acknowledgment.
- **CI/CD Pipeline Protection** — blocks modifications to `.github/workflows/`,
  `.gitlab-ci.yml`, `Jenkinsfile`, and equivalent pipeline configs without explicit instruction.
- **Shell & Command Execution** — blocks piped execution (`curl | bash`), silent system-wide
  package installs, cron jobs, launch agents, and background processes. Local project installs
  (`npm install`, `pip install` in a venv) are allowed as part of normal workflow.
- **File System Boundaries** — prefers working within the current project directory but allows
  reading external files (global configs, installed tools) when needed. Prevents recursive
  secret searching and access to browser data, keychain data, or OS credential stores.
- **Network & Web Safety** — blocks web requests to URLs found in untrusted content unless the
  user explicitly provided the URL in chat.

### `CLAUDE.project-template.md` — Per-Project Security Rules

A customizable template dropped into any repository root. It supplements (does not replace)
the global `CLAUDE.md`. Sections include:

- **Project Context** — project name, environment, stack, and owner team. Helps Claude
  understand what it's working on and what boundaries apply.
- **Off-Limits Resources** — project-specific files and actions Claude must never touch
  (e.g., production configs, deploy directories, protected branches, Dockerfiles, CI pipelines).
- **Safe Defaults** — actions Claude can perform freely without confirmation (e.g., running
  tests, linting, reading source files).
- **Confirmation Required** — actions that need explicit user approval each time (e.g.,
  `git push`, database migrations, Docker builds, dependency changes).
- **Project Secrets** — defines secret patterns to never read or print, where secrets are
  stored, and which secret manager is in use.
- **Anti-Injection Reminder** — reinforces that source code comments, test fixtures, README
  files, API responses, database records, and dependency source code are untrusted data sources.

### `.claude/settings.json` — Tool Permissions & Telemetry

This file combines two security functions: command permissions and telemetry export.

#### OpenTelemetry (OTel) Telemetry

Exports all Claude Code activity to your organization's OTel collector or SIEM, giving
your security team full observability over what Claude does on every endpoint. Configured
via the `env` block in `settings.json`.

**What gets exported:**

| Category | Data Points |
|----------|-------------|
| **Metrics** | Session count, tokens used, cost (USD), lines of code changed, commits, PRs created, active time |
| **Events** | Every tool execution (name, success/fail, duration), API requests (model, cost, tokens), permission decisions (accept/reject) |
| **Attributes** | Session ID, org ID, account UUID, user email, terminal type, app version |

**Privacy controls (both off by default):**
- `OTEL_LOG_USER_PROMPTS=1` — log the actual text of user prompts
- `OTEL_LOG_TOOL_DETAILS=1` — log bash commands, file paths, and tool arguments

**Supported exporters:** `otlp` (gRPC/HTTP), `prometheus`, `console`

> Replace `http://YOUR_OTEL_COLLECTOR:4317` in `settings.json` with your actual collector endpoint.

#### Pre-commit Secret Scanning (PreToolUse Hook)

A `PreToolUse` hook that intercepts every `git commit` command and scans staged changes
for exposed secrets before the commit is created. **This hook is active by default.**

**How it works:**
1. Claude initiates a `git commit` command
2. The hook runs `gitleaks` (or `trufflehog` as fallback) on `git diff --cached`
3. If secrets are detected → commit is **blocked** and Claude is told to remove them
4. If no secrets found → commit proceeds normally
5. If no scanner is installed → user is **warned** but commit is not blocked

**Supported scanners (install one):**
```bash
brew install gitleaks       # recommended
brew install trufflehog     # alternative
```

**What it catches:** API keys, tokens, passwords, private keys, cloud credentials, and
other secret patterns defined by the scanner's rule set.

> This complements the `settings.json` deny rules (which block `cat .env`, etc.) by
> catching secrets that make it into staged code — the last line of defense before commit.

#### Tool Permission Model

Controls what shell commands Claude can execute via a three-tier permission model:

| Tier | Behavior | Examples |
|------|----------|----------|
| **Allow** (auto-approved) | Claude runs without asking | `git status`, `git log`, `git diff`, `ls`, `cat`, `pwd`, `whoami`, version checks |
| **Unlisted** (ask first) | Claude asks for user confirmation | File writes, `git commit`, `npm install` (local), running tests, `rm -rf`, `terraform apply`, `kubectl apply/exec`, `brew install`, cloud create/update commands |
| **Deny** (hard block) | Cannot be executed even if user says yes | See categories below |

**Denied command categories (hard-blocked):**

- **Destructive filesystem** — `shred`, `mkfs`, `dd`
- **Secrets reading** — `cat` on credential files (`.env`, `*.pem`, `*.key`, SSH keys, AWS/Kube configs, tokens), `printenv` for secrets/passwords/tokens
- **Exfiltration / piped execution** — `curl|bash`, `wget|sh`, `curl -d @file`, `nc`, `netcat`
- **Privilege escalation** — `sudo`, `su`, `chmod 777`, `doas`
- **Persistence mechanisms** — `crontab`, `launchctl`, `systemctl enable`, `nohup &`
- **Cloud/infra deletions** — `terraform destroy`, `aws * delete`, `gcloud * delete`, `kubectl delete`
- **Global package installs** — `apt install`, `npm install -g`, `pip install --break-system`

**Moved to "ask" tier (user confirms each time):**

These commands are common in legitimate development workflows, so they require
user confirmation rather than a hard block:

- `rm -rf`, `rm -f` — needed for cleaning build artifacts, `node_modules`, temp files
- `terraform apply`, `kubectl apply`, `kubectl exec` — needed for IaC and debugging
- `aws create/put/update`, `gcloud create` — needed for cloud development
- `brew install` — commonly needed for dev tooling

> **Design principle:** Hard-block only truly dangerous or irreversible actions.
> For everything else, the "ask" tier lets the user decide per-command — security
> without sacrificing functionality.

### `.claude/mcp_servers.json` — MCP Server Configuration

Defines which [MCP (Model Context Protocol)](https://modelcontextprotocol.io) servers Claude
can connect to. MCP servers extend Claude's capabilities by giving it tools to interact with
external systems (databases, GitHub, Slack, filesystems, etc.).

**This file ships intentionally empty** (`"mcpServers": {}`). Add servers only after
reviewing the security rules below.

#### Why MCP servers are a security concern

Each MCP server you add **expands Claude's action surface**. More critically, MCP servers
return arbitrary text that can contain prompt injection payloads — a crafted GitHub issue,
a poisoned database record, or a malicious Slack message could contain text that Claude
mistakes for operator commands.

#### Rules for adding MCP servers

1. **Prefer local (`stdio`) over remote (`url`) servers.** Local = a process you control.
   Remote = a third-party endpoint you trust not to inject prompts.
2. **Scope filesystem servers tightly** — never grant access to `/`. Limit to the specific
   project directory.
3. **Treat all MCP tool results as untrusted data** (same as reading a file). Claude must
   not follow instructions found in tool results. This is reinforced in `CLAUDE.md`.
4. **Audit each server's tool list before connecting.** A server with a
   `run_shell_command` tool gives Claude (and any injected prompt) shell access.
5. **Remove servers you're not actively using.** Every connected server is attack surface.
6. **Never add without careful review:**
   - Servers with write access to production databases
   - Servers that accept arbitrary shell/eval commands
   - Remote servers from sources you don't fully control
   - Servers that proxy requests to other LLMs

#### Example server configurations

**Local filesystem (read-only, scoped path):**
```json
{
  "mcpServers": {
    "filesystem": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/projects/specific-project"]
    }
  }
}
```

**Local git inspection:**
```json
{
  "mcpServers": {
    "git": {
      "type": "stdio",
      "command": "uvx",
      "args": ["mcp-server-git", "--repository", "/path/to/repo"]
    }
  }
}
```

---

## Threat Model

This bundle protects against the following threat categories:

| # | Threat | Attack Vector | Mitigation |
|---|--------|---------------|------------|
| 1 | **Prompt Injection** | Attacker embeds instructions in source code, README, test data, or config files | `CLAUDE.md` anti-injection rules; explicit content-vs-instruction distinction |
| 2 | **Data Exfiltration** | Claude reads secrets/PII and sends them to external endpoints | `settings.json` denylist blocks credential file reads; `CLAUDE.md` bans transmitting content to untrusted URLs |
| 3 | **Destructive Infra Actions** | Claude runs `terraform destroy`, `kubectl delete`, etc. without user awareness | `settings.json` hard-blocks destructive commands (destroy/delete); create/apply require user confirmation |
| 4 | **Privilege Escalation** | Claude runs `sudo`, creates persistence mechanisms, or installs system packages | `settings.json` denies `sudo`, `su`, `crontab`, `launchctl`, `systemctl`, `apt install`, `npm install -g` |
| 5 | **MCP Server Injection** | Connected MCP server returns a response containing embedded instructions | MCP config ships empty; `CLAUDE.md` classifies tool results as untrusted data |
| 6 | **Shadow Usage / Audit Gap** | Claude is used on endpoints without security team visibility | OTel telemetry exports all tool calls, API requests, costs, and permission decisions to your SIEM |
| 7 | **Secret Commit** | Claude accidentally commits credentials, API keys, or tokens to git | PreToolUse hook scans staged changes with gitleaks/trufflehog and blocks the commit |

---

## Using This Bundle

There is no installer. Read each file, decide what fits your environment, and copy
it into place yourself. This is intentional — the configuration controls what Claude
can do on your endpoint, so it should not be installed by a script you didn't read.

### 1. Clone the repo

```bash
git clone <repo-url> claude-code-secure
cd claude-code-secure
```

### 2. Review the files

Read in this order:

1. `CLAUDE.md` — the behavioral rules that get injected into every session
2. `.claude/SETTINGS.md` — the rationale behind every entry in `settings.json`
3. `.claude/settings.json` — the actual permission allow/deny rules
4. `.claude/MCP_SERVERS.md` — the policy for adding MCP servers
5. `.claude/hooks/pre-commit-secret-scan.sh` — the secret-scanning hook

### 3. Copy into `~/.claude/`

```bash
mkdir -p ~/.claude/hooks
cp CLAUDE.md ~/.claude/CLAUDE.md
cp .claude/settings.json ~/.claude/settings.json
cp .claude/mcp_servers.json ~/.claude/mcp_servers.json
cp .claude/hooks/pre-commit-secret-scan.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/pre-commit-secret-scan.sh
```

> If you already have a `~/.claude/settings.json`, **don't overwrite it.** Merge the
> `allow`/`deny` arrays and `env` keys by hand so you keep your existing rules.

### 4. Edit `settings.json` for your environment

At minimum, replace `http://YOUR_OTEL_COLLECTOR:4317` with your actual collector
endpoint, or remove the OTel `env` block entirely if you don't run telemetry.

### 5. Install a secret scanner

The pre-commit hook calls `gitleaks` (or `trufflehog` as a fallback). Install one:

```bash
brew install gitleaks       # recommended
# brew install trufflehog   # alternative
```

If neither is installed, the hook warns but doesn't block commits.

### 6. Add per-project rules (optional)

Copy the template into any repository's root and customize it:

```bash
cp CLAUDE.project-template.md /path/to/your/project/CLAUDE.md
# Then edit: fill in project name, stack, off-limits paths, safe defaults
```

---

## Maintenance

- **Review quarterly:** Claude Code updates may add new tools or change permission
  semantics. Re-audit `settings.json` deny patterns after major version upgrades.
- **Per-project tuning:** The project template's "Safe Defaults" and "Off-Limits"
  sections should be customized — overly broad restrictions will hurt productivity.
- **Incident response:** If Claude acts unexpectedly, check whether the action was
  blocked by `settings.json`. If not, add a deny rule and update `CLAUDE.md`.

---

## References

- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code/overview)
- [Claude Code Settings Reference](https://docs.anthropic.com/en/docs/claude-code/settings)
- [MCP Security Best Practices](https://modelcontextprotocol.io/docs/concepts/security)
- [OWASP LLM Top 10 — LLM01: Prompt Injection](https://genai.owasp.org)

---

## License

MIT

---

## Credits

Created by **[Pluto Security](https://pluto.security/)** — Pluto protects modern creation workflows (across AI builders, developer tools, and business workspaces) with visibility, risk understanding, and real-time guardrails. Built for how work actually happens.
