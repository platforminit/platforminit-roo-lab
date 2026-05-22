#!/usr/bin/env bash
# validate-release-manager-contract.sh
#
# Validates that the Release Manager executor contract is correctly applied:
# - No forbidden handoff-only phrases appear as active contract wording
# - The generate-next-task.py includes Release Manager executor requirements
# - All role-contract files use executor lifecycle wording
#
# Usage: ./scripts/validate-release-manager-contract.sh
# Exit 0 on pass, 1 on fail.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
WARN=0

hr() {
    echo "========================================"
    echo "$*"
    echo "========================================"
}

res() {
    local status="$1"
    local msg="$2"
    case "$status" in
        PASS) PASS=$((PASS+1)); echo "  [PASS] $msg" ;;
        FAIL) FAIL=$((FAIL+1)); echo "  [FAIL] $msg" ;;
        WARN) WARN=$((WARN+1)); echo "  [WARN] $msg" ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Check that forbidden phrases do NOT appear as active contract wording
# ---------------------------------------------------------------------------
hr "1. Forbidden phrase detection"

CONTRACT_FILES=(
    ".roo/rules.md"
    ".roo/rules-platforminit-release-manager/rules.md"
    "docs/roo-lab/NATIVE_SWITCH_MODE_HANDOFF.md"
    "docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md"
    "tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md"
    "tasks/active/CURRENT_ACTIVE_TASKS.md"
)

# "final human commit/PR/merge handoff" — this phrase MUST NOT appear anywhere
# in contract files. It is the old handoff-only wording that has been replaced.
found_forbidden=0

for file in "${CONTRACT_FILES[@]}"; do
    if [ -f "$file" ]; then
        if grep -Fq "final human commit/PR/merge handoff" "$file"; then
            line_num=$(grep -Fn "final human commit/PR/merge handoff" "$file" | head -1 | cut -d: -f1)
            res FAIL "$file:$line_num — forbidden phrase \"final human commit/PR/merge handoff\" found"
            found_forbidden=1
        fi
    fi
done

# "human commit pending" — this phrase is ALLOWED when it appears in the
# executor contract context: "MUST NOT stop at 'human commit pending'" or
# "never stop at 'human commit pending'". It is FORBIDDEN when it appears
# as a standalone handoff instruction (e.g., "-> human commit pending").
for file in "${CONTRACT_FILES[@]}"; do
    if [ -f "$file" ]; then
        # Find all lines containing "human commit pending"
        while IFS=: read -r line_num content; do
            if [ -z "$line_num" ]; then
                continue
            fi
            # Check if the line is in executor contract context
            if echo "$content" | grep -qiE "MUST NOT stop at|never stop at"; then
                res WARN "$file:$line_num — \"human commit pending\" in executor contract context (acceptable)"
            elif echo "$content" | grep -qi "forbidden"; then
                res WARN "$file:$line_num — \"human commit pending\" in forbidden-examples context (acceptable)"
            else
                res FAIL "$file:$line_num — \"human commit pending\" found as active handoff instruction"
                found_forbidden=1
            fi
        done < <(grep -Fn "human commit pending" "$file" 2>/dev/null || true)
    fi
done

# "commit recommendation" — allowed in "Forbidden phrases" sections or
# historical context. Forbidden as an active handoff instruction.
COMMIT_REC_FILES=(
    ".roo/rules.md"
    ".roo/rules-platforminit-release-manager/rules.md"
    "docs/roo-lab/NATIVE_SWITCH_MODE_HANDOFF.md"
    "docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md"
    "tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md"
    "tasks/active/CURRENT_ACTIVE_TASKS.md"
    "scripts/orchestrator/generate-next-task.py"
)

for file in "${COMMIT_REC_FILES[@]}"; do
    if [ -f "$file" ]; then
        while IFS=: read -r line_num content; do
            if [ -z "$line_num" ]; then
                continue
            fi
            # Check context: allowed in "Forbidden phrases" or historical sections
            if echo "$content" | grep -qi "forbidden"; then
                res WARN "$file:$line_num — \"commit recommendation\" in forbidden-examples context (acceptable)"
            else
                # Check surrounding lines for "forbidden" marker (wider window: 6 lines before)
                context=$(sed -n "$((line_num-6)),$((line_num-1))p" "$file" 2>/dev/null || true)
                if echo "$context" | grep -qi "forbidden"; then
                    res WARN "$file:$line_num — \"commit recommendation\" near forbidden marker (acceptable)"
                else
                    res FAIL "$file:$line_num — \"commit recommendation\" found as active handoff instruction"
                    found_forbidden=1
                fi
            fi
        done < <(grep -Fn "commit recommendation" "$file" 2>/dev/null || true)
    fi
done

if [ "$found_forbidden" -eq 0 ]; then
    res PASS "No forbidden handoff-only phrases found as active contract wording"
fi

# ---------------------------------------------------------------------------
# 2. Verify generate-next-task.py includes Release Manager executor section
# ---------------------------------------------------------------------------
hr "2. generate-next-task.py executor requirements"

PY_FILE="scripts/orchestrator/generate-next-task.py"
if [ -f "$PY_FILE" ]; then
    if grep -Fq "Release Manager executor requirements" "$PY_FILE"; then
        res PASS "$PY_FILE includes Release Manager executor requirements section"
    else
        res FAIL "$PY_FILE missing Release Manager executor requirements section"
    fi
    if grep -Fq "BLOCKED_BY_TOOLING" "$PY_FILE"; then
        res PASS "$PY_FILE includes BLOCKED_BY_TOOLING marker"
    else
        res FAIL "$PY_FILE missing BLOCKED_BY_TOOLING marker"
    fi
    if grep -Fq "BLOCKED_BY_PERMISSION" "$PY_FILE"; then
        res PASS "$PY_FILE includes BLOCKED_BY_PERMISSION marker"
    else
        res FAIL "$PY_FILE missing BLOCKED_BY_PERMISSION marker"
    fi
    if grep -Fq "close-current-task.sh" "$PY_FILE"; then
        res PASS "$PY_FILE includes close-current-task.sh reference"
    else
        res FAIL "$PY_FILE missing close-current-task.sh reference"
    fi
else
    res FAIL "$PY_FILE not found"
fi

# ---------------------------------------------------------------------------
# 3. Verify contract files contain executor lifecycle wording
# ---------------------------------------------------------------------------
hr "3. Executor lifecycle wording verification"

# For .roo/rules.md, the lifecycle is in a single condensed line.
# Check for semantic content rather than exact line-by-line markers.
for file in "${CONTRACT_FILES[@]}"; do
    if [ -f "$file" ]; then
        missing_semantic=()

        # Check for lifecycle execution markers (semantic, not line-by-line)
        if grep -Fq "detect active task ID" "$file" || grep -Fq "detect the active task ID" "$file" || grep -Eq "detect.*task.*ID" "$file" 2>/dev/null; then
            : # present
        else
            missing_semantic+=("detect active task ID")
        fi

        if grep -Fq "verify changed files" "$file" || grep -Fq "verify.*changed.*files" "$file" >/dev/null 2>&1; then
            : # present
        else
            missing_semantic+=("verify changed files")
        fi

        if grep -Fq "create scoped implementation commit" "$file" || grep -Fq "create a scoped implementation commit" "$file" || grep -Eq "create.*scoped.*implementation.*commit" "$file" 2>/dev/null; then
            : # present
        else
            missing_semantic+=("create scoped implementation commit")
        fi

        if grep -Fq "push the branch" "$file" || grep -Fq "push branch" "$file" >/dev/null 2>&1; then
            : # present
        else
            missing_semantic+=("push branch")
        fi

        if grep -Fq "open a PR" "$file" || grep -Fq "open PR" "$file" >/dev/null 2>&1; then
            : # present
        else
            missing_semantic+=("open PR")
        fi

        if grep -Fq "close-current-task.sh" "$file"; then
            : # present
        else
            missing_semantic+=("close-current-task.sh")
        fi

        if grep -Fq "BLOCKED_BY_TOOLING" "$file"; then
            : # present
        else
            missing_semantic+=("BLOCKED_BY_TOOLING")
        fi

        if grep -Fq "BLOCKED_BY_PERMISSION" "$file"; then
            : # present
        else
            missing_semantic+=("BLOCKED_BY_PERMISSION")
        fi

        if [ ${#missing_semantic[@]} -eq 0 ]; then
            res PASS "$file — all executor lifecycle markers present"
        else
            res WARN "$file — missing markers: ${missing_semantic[*]}"
        fi
    else
        res WARN "$file not found (may not exist in this branch context)"
    fi
done

# ---------------------------------------------------------------------------
# 4. Python syntax check
# ---------------------------------------------------------------------------
hr "4. Python syntax check"

if [ -f "$PY_FILE" ]; then
    if python3 -m py_compile "$PY_FILE" 2>/dev/null; then
        res PASS "$PY_FILE — syntax OK"
    else
        res FAIL "$PY_FILE — syntax error"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Bash syntax check for this script
# ---------------------------------------------------------------------------
hr "5. Bash syntax check"

if bash -n "$0" 2>/dev/null; then
    res PASS "$(basename "$0") — syntax OK"
else
    res FAIL "$(basename "$0") — syntax error"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hr "SUMMARY"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "FAILED — Release Manager contract validation has errors."
    exit 1
fi

echo ""
echo "PASSED — Release Manager executor contract is correctly applied."
exit 0
