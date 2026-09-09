from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ORCHESTRATOR = "platforminit-orchestrator"
CODER = "platforminit-deepseek-coder"
REVIEWER = "platforminit-openai-reviewer"
OWASP = "platforminit-owasp-reviewer"
RELEASE = "platforminit-release-manager"


class TaskctlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tools/task_controller").mkdir(parents=True)
        shutil.copy2(Path(__file__).with_name("taskctl.py"), self.root / "tools/task_controller/taskctl.py")
        (self.root / "tasks/active/platform").mkdir(parents=True)
        (self.root / "tasks/active/n8n").mkdir(parents=True)
        (self.root / "docs/reviews").mkdir(parents=True)
        (self.root / "docs/security-reviews").mkdir(parents=True)
        self.tracker = {
            "schemaVersion": 1,
            "project": "fixture",
            "tracks": [
                {"id": "platform", "title": "Platform", "order": 1},
                {"id": "n8n", "title": "n8n", "order": 2},
            ],
            "tasks": [
                self.task("P-001", 1, "done", "done/p-001"),
                self.task("P-002", 2, "pending", "feature/p-002", ["P-001"]),
                self.task("N-001", 1, "pending", "feature/n-001", ["P-001"], "n8n"),
            ],
        }
        self.write_tracker()
        subprocess.run(["git", "init", "-b", "dev"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=self.root, check=True)
        self.invoke("next")

    def tearDown(self):
        self.tmp.cleanup()

    def task(self, tid, order, status, branch, depends=None, track="platform"):
        return {
            "id": tid,
            "track": track,
            "order": order,
            "status": status,
            "title": tid,
            "description": "fixture",
            "scope": track,
            "branch": branch,
            "dependsOn": depends or [],
            "acceptanceCriteria": ["deterministic"],
            "allowedFiles": ["**"],
            "requiredValidators": [[sys.executable, "-c", "raise SystemExit(0)"]],
            "forbiddenActions": [],
            "implementationMode": CODER,
            "reviewMode": REVIEWER,
            "securityMode": OWASP,
            "releaseMode": RELEASE,
        }

    def write_tracker(self):
        (self.root / "tasks").mkdir(exist_ok=True)
        (self.root / "tasks/tracker.json").write_text(json.dumps(self.tracker, indent=2) + "\n", encoding="utf-8")

    def invoke(self, *args, ok=True):
        env = {**os.environ, "PLATFORMINIT_REPO_ROOT": str(self.root)}
        result = subprocess.run(
            [sys.executable, "tools/task_controller/taskctl.py", *args],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
        )
        if ok and result.returncode != 0:
            self.fail(result.stderr)
        return result

    def switch(self, branch):
        subprocess.run(["git", "switch", "-C", branch], cwd=self.root, check=True, capture_output=True)

    def start_and_submit(self):
        self.switch("feature/p-002")
        self.invoke("start", "P-002", "--actor", ORCHESTRATOR)
        self.invoke("submit", "P-002", "--actor", CODER)

    def write_review(self, text="APPROVE: scope and acceptance criteria verified."):
        (self.root / "docs/reviews/P-002.md").write_text(f"# Review\n\n{text}\n")

    def write_security(self, text="CLEAR: no unresolved security blocker remains."):
        (self.root / "docs/security-reviews/P-002.md").write_text(f"# Security\n\n{text}\n")

    def test_invalid_transition(self):
        result = self.invoke("submit", "P-002", "--actor", CODER, ok=False)
        self.assertIn("not in_progress", result.stderr)

    def test_dependency_enforcement(self):
        self.tracker["tasks"][0]["status"] = "pending"
        self.write_tracker()
        self.invoke("next")
        self.switch("feature/p-002")
        result = self.invoke("start", "P-002", "--actor", ORCHESTRATOR, ok=False)
        self.assertIn("incomplete dependencies", result.stderr)

    def test_illegal_direct_completion(self):
        self.switch("feature/p-002")
        self.invoke("start", "P-002", "--actor", ORCHESTRATOR)
        result = self.invoke("complete", "P-002", "--actor", RELEASE, ok=False)
        self.assertIn("not ready_to_close", result.stderr)

    def test_generated_drift(self):
        (self.root / "tasks/active/NEXT_TASK.md").write_text("stale\n", encoding="utf-8")
        result = self.invoke("validate", "--ignore-branch", ok=False)
        self.assertIn("generated view stale", result.stderr)

    def test_duplicate_and_missing_dependency(self):
        duplicate = dict(self.tracker["tasks"][1])
        duplicate["dependsOn"] = ["MISSING"]
        self.tracker["tasks"].append(duplicate)
        self.write_tracker()
        result = self.invoke("validate", "--ignore-branch", ok=False)
        self.assertIn("duplicate task id P-002", result.stderr)
        self.assertIn("missing dependency MISSING", result.stderr)

    def test_obsolete_legacy_artifact(self):
        path = self.root / "tasks/status/platform.json"
        path.parent.mkdir(parents=True)
        path.write_text("{}\n")
        result = self.invoke("validate", "--ignore-branch", ok=False)
        self.assertIn("obsolete authoritative artifact", result.stderr)

    def test_branch_task_mismatch(self):
        result = self.invoke("start", "P-002", "--actor", ORCHESTRATOR, ok=False)
        self.assertIn("branch-task mismatch", result.stderr)

    def test_workflow_state_mismatch_is_detected(self):
        task = self.tracker["tasks"][1]
        task["status"] = "ready_to_close"
        task["workflow"] = {"startedAt": "2026-01-01T00:00:00+00:00", "submit": {"actor": CODER}}
        self.write_tracker()
        self.invoke("next")
        result = self.invoke("validate", "--ignore-branch", ok=False)
        self.assertIn("requires approving workflow.review", result.stderr)
        self.assertIn("requires clear workflow.security", result.stderr)

    def test_review_block_unblock_restores_review_state(self):
        self.start_and_submit()
        self.write_review("BLOCK: a concrete correctness blocker remains unresolved.")
        self.invoke(
            "review", "P-002", "--actor", REVIEWER, "--verdict", "block",
            "--report", "docs/reviews/P-002.md",
        )
        self.invoke("unblock", "P-002", "--actor", ORCHESTRATOR)
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        task = next(item for item in state["tasks"] if item["id"] == "P-002")
        self.assertEqual(task["status"], "needs_review")

    def test_security_block_unblock_restores_security_state(self):
        self.start_and_submit()
        self.write_review()
        self.invoke(
            "review", "P-002", "--actor", REVIEWER, "--verdict", "approve",
            "--report", "docs/reviews/P-002.md",
        )
        self.write_security("BLOCK: an unresolved security boundary violation remains.")
        self.invoke(
            "security", "P-002", "--actor", OWASP, "--verdict", "block",
            "--report", "docs/security-reviews/P-002.md",
        )
        self.invoke("unblock", "P-002", "--actor", ORCHESTRATOR)
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        task = next(item for item in state["tasks"] if item["id"] == "P-002")
        self.assertEqual(task["status"], "needs_security_review")

    def test_full_review_security_close_path(self):
        self.start_and_submit()
        self.write_review()
        self.invoke(
            "review", "P-002", "--actor", REVIEWER, "--verdict", "approve",
            "--report", "docs/reviews/P-002.md",
        )
        self.write_security()
        self.invoke(
            "security", "P-002", "--actor", OWASP, "--verdict", "clear",
            "--report", "docs/security-reviews/P-002.md",
        )
        self.invoke("complete", "P-002", "--actor", RELEASE)
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        task = next(item for item in state["tasks"] if item["id"] == "P-002")
        self.assertEqual(task["status"], "done")


if __name__ == "__main__":
    unittest.main()
