#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "[PASS] $*"; }
fail() { FAIL=$((FAIL+1)); echo "[FAIL] $*"; }

required_files=(
  ".roo/rules.md"
  ".roo/rules-platforminit-orchestrator/rules.md"
  ".roo/rules-platforminit-deepseek-coder/rules.md"
  ".roo/rules-platforminit-openai-reviewer/rules.md"
  ".roo/rules-platforminit-owasp-reviewer/rules.md"
  ".roo/rules-platforminit-release-manager/rules.md"
  ".roo/commands/next-task.md"
  ".roo/commands/mcp-smoke.md"
  "tools/platforminit_mcp/validate_mode_access.py"
)

for file in "${required_files[@]}"; do
  if [[ -f "$file" ]]; then pass "$file exists"; else fail "$file missing"; fi
done

active_contracts=(
  ".roo/rules.md"
  ".roo/rules-platforminit-orchestrator/rules.md"
  ".roo/rules-platforminit-deepseek-coder/rules.md"
  ".roo/rules-platforminit-openai-reviewer/rules.md"
  ".roo/rules-platforminit-owasp-reviewer/rules.md"
  ".roo/rules-platforminit-release-manager/rules.md"
  ".roo/commands/next-task.md"
)

for file in "${active_contracts[@]}"; do
  [[ -f "$file" ]] || continue
  if grep -Fq "switch_mode" "$file"; then
    fail "$file still contains legacy switch_mode contract"
  else
    pass "$file has no legacy switch_mode contract"
  fi
done

if grep -Fq "fresh Zoo" .roo/rules.md && grep -Fq "new_task" .roo/commands/next-task.md; then
  pass "fresh-child Zoo contract is active"
else
  fail "fresh-child Zoo contract markers missing"
fi

if grep -Fq "attempt_completion" .roo/commands/next-task.md; then
  pass "child completion contract is explicit"
else
  fail "attempt_completion contract missing"
fi

if grep -Fiq "never merge" .roo/rules-platforminit-release-manager/rules.md; then
  pass "human-only merge boundary preserved"
else
  fail "human-only merge boundary missing"
fi

if grep -Fq "Reuse unchanged passing validator evidence" .roo/rules-platforminit-release-manager/rules.md; then
  pass "release evidence reuse is explicit"
else
  fail "release evidence reuse marker missing"
fi

if python3 tools/platforminit_mcp/validate_mode_access.py; then
  pass "all PlatformInit modes have MCP access"
else
  fail "MCP mode-access validation failed"
fi

if python3 -m py_compile tools/platforminit_mcp/context.py tools/platforminit_mcp/server.py tools/platforminit_mcp/validate_mode_access.py; then
  pass "PlatformInit MCP Python syntax"
else
  fail "PlatformInit MCP Python syntax"
fi

if bash -n "$0"; then pass "validator shell syntax"; else fail "validator shell syntax"; fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
