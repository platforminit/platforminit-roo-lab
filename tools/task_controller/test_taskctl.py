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
            "tracks": [{"id":"platform","title":"Platform","order":1},{"id":"n8n","title":"n8n","order":2}],
            "tasks": [
                self.task("P-001", 1, "done", "done/p-001"),
                self.task("P-002", 2, "pending", "feature/p-002", ["P-001"]),
                self.task("N-001", 1, "pending", "feature/n-001", ["P-001"], "n8n"),
            ],
        }
        self.write_tracker()
        subprocess.run(["git","init","-b","dev"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git","config","user.name","Test"], cwd=self.root, check=True)
        subprocess.run(["git","config","user.email","test@example.invalid"], cwd=self.root, check=True)
        self.invoke("next")

    def tearDown(self):
        self.tmp.cleanup()

    def task(self, tid, order, status, branch, depends=None, track="platform"):
        return {
            "id":tid,"track":track,"order":order,"status":status,"title":tid,
            "description":"fixture","scope":track,"branch":branch,"dependsOn":depends or [],
            "acceptanceCriteria":["deterministic"],"allowedFiles":["**"],
            "requiredValidators":[[sys.executable,"-c","raise SystemExit(0)"]],
            "forbiddenActions":[],"implementationMode":CODER,"reviewMode":REVIEWER,
            "securityMode":OWASP,"releaseMode":RELEASE,
        }

    def write_tracker(self):
        (self.root / "tasks").mkdir(exist_ok=True)
        (self.root / "tasks/tracker.json").write_text(json.dumps(self.tracker, indent=2)+"\n", encoding="utf-8")

    def invoke(self, *args, ok=True):
        env = {**os.environ, "PLATFORMINIT_REPO_ROOT": str(self.root)}
        p = subprocess.run([sys.executable,"tools/task_controller/taskctl.py",*args], cwd=self.root, env=env, text=True, capture_output=True)
        if ok and p.returncode != 0:
            self.fail(p.stderr)
        return p

    def switch(self, branch):
        subprocess.run(["git","switch","-C",branch], cwd=self.root, check=True, capture_output=True)

    def test_invalid_transition(self):
        p = self.invoke("submit","P-002","--actor",CODER,ok=False)
        self.assertIn("not in_progress", p.stderr)

    def test_dependency_enforcement(self):
        self.tracker["tasks"][0]["status"] = "pending"
        self.write_tracker(); self.invoke("next"); self.switch("feature/p-002")
        p = self.invoke("start","P-002","--actor",ORCHESTRATOR,ok=False)
        self.assertIn("incomplete dependencies", p.stderr)

    def test_illegal_direct_completion(self):
        self.switch("feature/p-002"); self.invoke("start","P-002","--actor",ORCHESTRATOR)
        p = self.invoke("complete","P-002","--actor",RELEASE,ok=False)
        self.assertIn("not ready_to_close", p.stderr)

    def test_generated_drift(self):
        (self.root / "tasks/active/NEXT_TASK.md").write_text("stale\n", encoding="utf-8")
        p = self.invoke("validate","--ignore-branch",ok=False)
        self.assertIn("generated view stale", p.stderr)

    def test_duplicate_and_missing_dependency(self):
        duplicate = dict(self.tracker["tasks"][1]); duplicate["dependsOn"] = ["MISSING"]
        self.tracker["tasks"].append(duplicate); self.write_tracker()
        p = self.invoke("validate","--ignore-branch",ok=False)
        self.assertIn("duplicate task id P-002", p.stderr)
        self.assertIn("missing dependency MISSING", p.stderr)

    def test_obsolete_legacy_artifact(self):
        path = self.root / "tasks/status/platform.json"; path.parent.mkdir(parents=True); path.write_text("{}\n")
        p = self.invoke("validate","--ignore-branch",ok=False)
        self.assertIn("obsolete authoritative artifact", p.stderr)

    def test_branch_task_mismatch(self):
        p = self.invoke("start","P-002","--actor",ORCHESTRATOR,ok=False)
        self.assertIn("branch-task mismatch", p.stderr)

    def test_full_review_security_close_path(self):
        self.switch("feature/p-002")
        self.invoke("start","P-002","--actor",ORCHESTRATOR)
        self.invoke("submit","P-002","--actor",CODER)
        (self.root / "docs/reviews/P-002.md").write_text("# Review\n\nAPPROVE: scope and acceptance criteria verified.\n")
        self.invoke("review","P-002","--actor",REVIEWER,"--verdict","approve","--report","docs/reviews/P-002.md")
        (self.root / "docs/security-reviews/P-002.md").write_text("# Security\n\nCLEAR: no unresolved security blocker remains.\n")
        self.invoke("security","P-002","--actor",OWASP,"--verdict","clear","--report","docs/security-reviews/P-002.md")
        self.invoke("complete","P-002","--actor",RELEASE)
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        task = next(t for t in state["tasks"] if t["id"] == "P-002")
        self.assertEqual(task["status"], "done")

if __name__ == "__main__":
    unittest.main()
