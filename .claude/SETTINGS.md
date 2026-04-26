# Claude Code — Endpoint Security Settings

Companion documentation for `.claude/settings.json`. The JSON file itself can't carry comments, so the rationale lives here.

Place `settings.json` at:
- `~/.claude/settings.json` — global, all projects
- `<project>/.claude/settings.json` — project-scoped

## How permissions work — three tiers

| Tier      | Behavior                                                                    |
| --------- | --------------------------------------------------------------------------- |
| `allow`   | Auto-approved. Claude proceeds without asking.                              |
| (absent)  | Claude asks for confirmation before proceeding.                             |
| `deny`    | Hard block. Claude cannot perform this action even if the user says "yes." |

**Strategy used here:**
- Low-risk read/inspect commands → `allow` (no friction)
- Medium-risk commands (file writes, git commits, etc.) → not listed = Claude asks first
- Irreversible / high-impact / exfiltration-risk commands → `deny` (no exceptions)

Deny is intentionally strict. If you find a legitimate use for a denied command, grant it explicitly at the task level rather than removing the deny rule.

## Telemetry — OpenTelemetry (OTel)

Exports all Claude Code activity (tool calls, API requests, permission decisions, costs, token usage) to your OTel collector / SIEM. Gives your security team full observability.

**Required:** `CLAUDE_CODE_ENABLE_TELEMETRY=1`.

Replace the endpoint with your organization's OTel collector. For authentication, set `OTEL_EXPORTER_OTLP_HEADERS` or use the `otelHeadersHelper` for dynamic token refresh.

**Privacy notes:**
- User prompts are **not** logged by default. Set `OTEL_LOG_USER_PROMPTS=1` to enable (privacy trade-off).
- Tool arguments (bash commands, file paths) are **not** logged by default. Set `OTEL_LOG_TOOL_DETAILS=1` to enable.

**Optional env vars** (not currently set in `settings.json`):
```
OTEL_LOG_USER_PROMPTS=1
OTEL_LOG_TOOL_DETAILS=1
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer YOUR_TOKEN
OTEL_RESOURCE_ATTRIBUTES=department=engineering,team.id=platform
```

## Optional — dynamic OTel auth token refresh

Add an `otelHeadersHelper` field at the top level pointing to a script that outputs JSON with auth headers. Claude Code calls it periodically (default: every 29 min).

```json
"otelHeadersHelper": "/path/to/generate_otel_headers.sh"
```

## Secret scanning — pre-commit hook

The `PreToolUse` hook runs a secret scanner (gitleaks or trufflehog) on staged changes before every `git commit`. If secrets are detected, the commit is blocked and Claude is told to remove them.

If no scanner is installed, the user is warned but the commit is not blocked.

Install a scanner:
```
brew install gitleaks       # recommended
brew install trufflehog     # alternative
```

## Permissions — `allow` rationale

Auto-approved commands are limited to read-only inspection: status checks, log/diff viewing, listing files, printing strings, version checks, package listings. Anything that mutates state is intentionally absent.

## Permissions — middle tier (the absent ones)

Anything not in `allow` and not in `deny` falls into the middle tier: Claude asks for confirmation before running it. This covers file writes, git commits, `npm install` (local), running tests, starting servers, etc. Medium-risk = ask, don't block.

## Permissions — `deny` rationale

These cannot be unlocked by user confirmation in the chat. To legitimately use one, run it yourself in the terminal.

### Destructive filesystem ops
`shred`, `mkfs*`, `dd`. Note: `rm -rf` and `rm -f` are intentionally **not** denied — they fall into the "ask" tier so Claude can clean build artifacts and temp files with confirmation.

### Secrets reading
Prevents Claude from reading or printing credential files. Because `cat *` is in `allow`, the deny rules must be more specific to override (deny takes precedence). Covers SSH keys, PEM/key files, `.env*`, AWS/Kube credentials, token files, and `printenv` for any var matching `*SECRET*`, `*API_KEY*`, `*PRIVATE_KEY*`, `*ACCESS_KEY*`, `*TOKEN*`, `*PASSWORD*`.

### Exfiltration / piped execution
Prevents downloading-and-executing scripts (`curl|bash`, `wget|sh`) and sending file contents to external endpoints (`curl -d @file`, `nc`, `netcat`).

### Privilege escalation
`sudo`, `su`, `doas`, `chmod 777 *`.

### Persistence mechanisms
`crontab`, `launchctl`, `systemctl enable`, `nohup *`.

### Cloud / infra mutations
Destructive-only commands are hard-blocked: `terraform destroy`, `aws * delete*`, `gcloud * delete*`, `kubectl delete *`. Create/apply/exec commands are in the "ask" tier so Claude can still do IaC and debugging work with confirmation.

### Silent global package installation
`apt-get install`, `apt install`, `npm install -g`, `pip install --break-system*`. Note: `brew install` is in the "ask" tier (not denied) since it's commonly needed for dev tooling.
