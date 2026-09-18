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
        self.ledger_dir = Path(tempfile.mkdtemp(prefix="taskctl-validator-ledger-"))
        (self.root / "tools/task_controller").mkdir(parents=True)
        shutil.copy2(Path(__file__).with_name("taskctl.py"), self.root / "tools/task_controller/taskctl.py")
        (self.root / "tasks/active/platform").mkdir(parents=True)
        (self.root / "docs/reviews").mkdir(parents=True)
        (self.root / "docs/security-reviews").mkdir(parents=True)
        self.tracker = {
            "schemaVersion": 1,
            "project": "fixture",
            "tracks": [{"id": "platform", "title": "Platform", "order": 1}],
            "tasks": [
                self.task("P-001", 1, "done", "done/p-001"),
                self.task("P-002", 2, "pending", "feature/p-002", ["P-001"]),
            ],
        }
        self.write_tracker()
        subprocess.run(["git", "init", "-b", "dev"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "fixture baseline"], cwd=self.root, check=True, capture_output=True)
        self.invoke("next")

    def tearDown(self):
        self.tmp.cleanup()
        shutil.rmtree(self.ledger_dir, ignore_errors=True)

    def task(self, tid, order, status, branch, depends=None):
        return {
            "id": tid,
            "track": "platform",
            "order": order,
            "status": status,
            "title": tid,
            "description": "fixture",
            "scope": "platform",
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

    def commit_all(self, message="fixture change"):
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", message], cwd=self.root, check=True, capture_output=True)

    def state_task(self, task_id="P-002"):
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        return next(item for item in state["tasks"] if item["id"] == task_id)

    def store_task(self, task):
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        state["tasks"] = [task if item["id"] == task["id"] else item for item in state["tasks"]]
        (self.root / "tasks/tracker.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")

    def current_fingerprint(self):
        result = self.invoke("fingerprint")
        for line in result.stdout.splitlines():
            if line.startswith("fingerprint="):
                return line.split("=", 1)[1]
        self.fail(f"no fingerprint in output: {result.stdout}")

    def current_scope(self):
        """Fingerprint and changed-file scope exactly as the controller computes them."""
        result = self.invoke("fingerprint")
        fingerprint, files = None, []
        for line in result.stdout.splitlines():
            if line.startswith("fingerprint="):
                fingerprint = line.split("=", 1)[1]
            elif line.startswith("file="):
                files.append(line.split("=", 1)[1])
        if fingerprint is None:
            self.fail(f"no fingerprint in output: {result.stdout}")
        return fingerprint, files

    def arm_recording_validator(self):
        """Swap the focused validator for one that appends a line per execution.

        The ledger lives outside the repository, so recording a run cannot change the source
        fingerprint or the changed-file scope under test.
        """
        ledger = self.ledger_dir / "validators.log"
        task = self.state_task()
        task["requiredValidators"] = [[
            sys.executable,
            "-c",
            "import pathlib, sys; pathlib.Path(sys.argv[1]).open('a', encoding='utf-8').write('run\\n')",
            str(ledger),
        ]]
        self.store_task(task)
        return ledger

    def run_count(self, ledger):
        return len(ledger.read_text(encoding="utf-8").splitlines()) if ledger.exists() else 0

    def invoke_complete_with_persistence_drift(self, drift_relative, *args):
        """Run taskctl so a fingerprinted source file changes exactly at the persistence boundary.

        The driver wraps `pathlib.Path.replace`, which `save()` uses for the atomic `tracker.json`
        write, and mutates the target source file once, immediately before that replacement. That is
        the smallest observable window between the final fingerprint confirmation and persisted
        controller state, i.e. the interleaving described by review finding P-WF-T04-REV-001. No
        production test hook is required: the monkeypatch lives only in this taskctl subprocess.
        """
        drift_target = str(self.root / drift_relative)
        driver = "\n".join([
            "import pathlib, runpy, sys",
            "sys.argv = ['taskctl.py', " + ", ".join(repr(arg) for arg in args) + "]",
            "drift_target = pathlib.Path(" + repr(drift_target) + ")",
            "original_replace = pathlib.Path.replace",
            "state = {'armed': False}",
            "def replace_with_drift(self, target):",
            "    if not state['armed'] and self.name == 'tracker.json.tmp':",
            "        state['armed'] = True",
            "        drift_target.write_text(drift_target.read_text(encoding='utf-8') + 'drift\\n', encoding='utf-8')",
            "    return original_replace(self, target)",
            "pathlib.Path.replace = replace_with_drift",
            "runpy.run_path('tools/task_controller/taskctl.py', run_name='__main__')",
        ])
        env = {**os.environ, "PLATFORMINIT_REPO_ROOT": str(self.root)}
        return subprocess.run(
            [sys.executable, "-c", driver],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
        )

    def invoke_submit_with_scope_growth_during_validators(self, count):
        """Run submit so extra non-state files appear after the size count and before the snapshot.

        The driver loads `taskctl` as a module and wraps `run_validators`, so the changed-file scope
        grows right after the size gate counted the smaller snapshot and before the controller
        fingerprints and persists the scope it acted on. That is exactly the interleaving of review
        finding P-WF-T05-D1: an oversized scope trying to pass the gate by being added after the
        count. No production test hook is required; the wrapper lives only in this taskctl process.
        """
        driver = "\n".join([
            "import importlib.util, sys",
            # Loading taskctl as a module must not add a `__pycache__` entry to the very scope this
            # driver measures, so bytecode caching is disabled for the subprocess.
            "sys.dont_write_bytecode = True",
            "spec = importlib.util.spec_from_file_location('taskctl_under_test', 'tools/task_controller/taskctl.py')",
            "module = importlib.util.module_from_spec(spec)",
            "spec.loader.exec_module(module)",
            "original_run_validators = module.run_validators",
            "def run_validators_then_grow(task):",
            "    records = original_run_validators(task)",
            "    for index in range(" + str(count) + "):",
            "        (module.ROOT / ('late-%d.txt' % index)).write_text('%d\\n' % index, encoding='utf-8')",
            "    return records",
            "module.run_validators = run_validators_then_grow",
            "sys.argv = ['taskctl.py', 'submit', 'P-002', '--actor', '" + CODER + "']",
            "raise SystemExit(module.main())",
        ])
        env = {**os.environ, "PLATFORMINIT_REPO_ROOT": str(self.root)}
        return subprocess.run(
            [sys.executable, "-c", driver],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
        )

    def tamper_submit_evidence(self, mutate):
        """Run the submit-to-release path with a single tampered submit-evidence field.

        One focused-validator execution happens during submit. Any accepted tampering must force a
        second, real execution instead of a silent pass.
        """
        ledger = self.arm_recording_validator()
        self.approve_to_close()
        self.assertEqual(self.run_count(ledger), 1, "submit must run the focused validator exactly once")
        task = self.state_task()
        mutate(task["workflow"]["submit"])
        self.store_task(task)
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertFalse(complete["reusedSubmitEvidence"])
        self.assertEqual(self.run_count(ledger), 2, "tampered evidence must rerun validators, never pass silently")
        return complete

    def start_and_submit(self):
        self.switch("feature/p-002")
        self.invoke("start", "P-002", "--actor", ORCHESTRATOR)
        self.invoke("submit", "P-002", "--actor", CODER)

    def stage_non_state_files(self, count):
        """Start P-002 with a changed non-state scope of exactly `count` files."""
        self.switch("feature/p-002")
        self.invoke("start", "P-002", "--actor", ORCHESTRATOR)
        for index in range(count):
            (self.root / f"change-{index}.txt").write_text(f"{index}\n", encoding="utf-8")

    def write_review(self, text="APPROVE: scope and acceptance criteria verified."):
        (self.root / "docs/reviews/P-002.md").write_text(f"# Review\n\n{text}\n")

    def write_security(self, text="CLEAR: no unresolved security blocker remains."):
        (self.root / "docs/security-reviews/P-002.md").write_text(f"# Security\n\n{text}\n")

    def approve_to_close(self):
        self.start_and_submit()
        self.write_review()
        self.invoke("review", "P-002", "--actor", REVIEWER, "--verdict", "approve", "--report", "docs/reviews/P-002.md")
        self.write_security()
        self.invoke("security", "P-002", "--actor", OWASP, "--verdict", "clear", "--report", "docs/security-reviews/P-002.md")

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

    def test_non_platform_track_is_rejected(self):
        self.tracker["tracks"].append({"id": "n8n", "title": "n8n", "order": 2})
        bad = self.task("N-001", 3, "pending", "feature/n-001")
        bad["track"] = "n8n"
        self.tracker["tasks"].append(bad)
        self.write_tracker()
        result = self.invoke("validate", "--ignore-branch", ok=False)
        self.assertIn("exactly one track: platform", result.stderr)
        self.assertIn("non-platform task", result.stderr)

    def test_workflow_state_mismatch_is_detected(self):
        task = self.tracker["tasks"][1]
        task["status"] = "ready_to_close"
        task["workflow"] = {"startedAt": "2026-01-01T00:00:00+00:00", "submit": {"actor": CODER}}
        self.write_tracker()
        result = self.invoke("validate", "--ignore-branch", ok=False)
        self.assertIn("requires approving workflow.review", result.stderr)
        self.assertIn("requires clear workflow.security", result.stderr)

    def test_review_block_unblock_restores_review_state(self):
        self.start_and_submit()
        self.write_review("BLOCK: a concrete correctness blocker remains unresolved.")
        self.invoke("review", "P-002", "--actor", REVIEWER, "--verdict", "block", "--report", "docs/reviews/P-002.md")
        self.invoke("unblock", "P-002", "--actor", ORCHESTRATOR)
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        task = next(item for item in state["tasks"] if item["id"] == "P-002")
        self.assertEqual(task["status"], "needs_review")

    def test_security_block_unblock_restores_security_state(self):
        self.start_and_submit()
        self.write_review()
        self.invoke("review", "P-002", "--actor", REVIEWER, "--verdict", "approve", "--report", "docs/reviews/P-002.md")
        self.write_security("BLOCK: an unresolved security boundary violation remains.")
        self.invoke("security", "P-002", "--actor", OWASP, "--verdict", "block", "--report", "docs/security-reviews/P-002.md")
        self.invoke("unblock", "P-002", "--actor", ORCHESTRATOR)
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        task = next(item for item in state["tasks"] if item["id"] == "P-002")
        self.assertEqual(task["status"], "needs_security_review")

    def test_full_review_security_close_path_reuses_submit_evidence(self):
        self.approve_to_close()
        self.invoke("complete", "P-002", "--actor", RELEASE)
        state = json.loads((self.root / "tasks/tracker.json").read_text())
        task = next(item for item in state["tasks"] if item["id"] == "P-002")
        self.assertEqual(task["status"], "done")
        self.assertTrue(task["workflow"]["complete"]["reusedSubmitEvidence"])
        self.assertEqual(task["workflow"]["submit"]["sourceFingerprint"], task["workflow"]["complete"]["sourceFingerprint"])

    def test_source_change_invalidates_submit_evidence(self):
        self.approve_to_close()
        (self.root / "changed.txt").write_text("changed after review\n", encoding="utf-8")
        self.invoke("complete", "P-002", "--actor", RELEASE)
        self.assertFalse(self.state_task()["workflow"]["complete"]["reusedSubmitEvidence"])

    def test_submit_records_versioned_fingerprint_and_validator_plan(self):
        self.start_and_submit()
        submit = self.state_task()["workflow"]["submit"]
        self.assertEqual(submit["evidenceVersion"], 1)
        self.assertRegex(submit["sourceFingerprint"], r"^[0-9a-f]{64}$")
        self.assertEqual([item["exitCode"] for item in submit["validators"]], [0])
        self.assertEqual(submit["changedFiles"], [])
        self.assertEqual(submit["sourceFingerprint"], self.current_fingerprint())

    def test_fingerprint_ignores_controller_state_and_generated_views(self):
        before = self.current_fingerprint()
        self.tracker["tasks"][1]["title"] = "controller state renamed"
        self.write_tracker()
        self.invoke("next")
        self.assertEqual(before, self.current_fingerprint())

    def test_release_reuses_passing_evidence_across_identical_commit(self):
        self.approve_to_close()
        self.commit_all("commit the reviewed source unchanged")
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertTrue(complete["reusedSubmitEvidence"])
        self.assertEqual(complete["sourceFingerprint"], self.state_task()["workflow"]["submit"]["sourceFingerprint"])

    def test_committed_source_change_invalidates_reuse(self):
        self.approve_to_close()
        (self.root / "src-change.txt").write_text("new source after review\n", encoding="utf-8")
        self.commit_all("change source after review")
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertFalse(complete["reusedSubmitEvidence"])
        self.assertEqual(len(complete["validators"]), 1)
        self.assertNotEqual(complete["sourceFingerprint"], self.state_task()["workflow"]["submit"]["sourceFingerprint"])

    def test_source_drift_during_persistence_fails_loud_and_never_records_done(self):
        """Residual TOCTOU window between the final confirmation and `save()` (P-WF-T04-REV-001).

        `complete` confirms the fingerprint immediately before building the completion record and then
        persists it, but the confirmation and the atomic state write are not one atomic step. The hook
        in `invoke_complete_with_persistence_drift` mutates a fingerprinted file exactly when
        `tasks/tracker.json` is replaced, which is the smallest window this design can observe. True
        atomicity would need source locking or filesystem snapshots, which are explicitly out of scope,
        so the strongest achievable in-process property is asserted: the transition fails loudly, the
        `done` state and its reused-evidence record are reverted, and a follow-up `complete` reruns the
        focused validators for the drifted source.
        """
        ledger = self.arm_recording_validator()
        (self.root / "drift-source.txt").write_text("validated source\n", encoding="utf-8")
        self.approve_to_close()
        self.assertEqual(self.run_count(ledger), 1, "submit must run the focused validator exactly once")

        drifted = self.invoke_complete_with_persistence_drift(
            "drift-source.txt", "complete", "P-002", "--actor", RELEASE,
        )
        self.assertNotEqual(drifted.returncode, 0, "source drift during persistence must fail loudly")
        self.assertIn("source changed after the completion record was confirmed", drifted.stderr)
        repaired = self.state_task()
        self.assertEqual(repaired["status"], "ready_to_close", "reverted state must not stay done")
        self.assertNotIn("complete", repaired["workflow"], "stale completion record must be removed")
        self.assertEqual(self.run_count(ledger), 1, "the reuse path must not have run validators")

        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertFalse(complete["reusedSubmitEvidence"])
        self.assertEqual(self.run_count(ledger), 2, "drifted source must rerun the focused validators")
        self.assertEqual(complete["confirmedFingerprint"], complete["sourceFingerprint"])

    def test_legacy_evidence_without_version_reruns_focused_validators(self):
        self.approve_to_close()
        task = self.state_task()
        del task["workflow"]["submit"]["evidenceVersion"]
        self.store_task(task)
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertFalse(complete["reusedSubmitEvidence"])
        self.assertIn("evidence version", complete["evidenceDecision"])
        self.assertEqual([item["command"] for item in complete["validators"]], [[sys.executable, "-c", "raise SystemExit(0)"]])

    def test_empty_validator_evidence_reruns_validators(self):
        self.approve_to_close()
        task = self.state_task()
        task["workflow"]["submit"]["validators"] = []
        self.store_task(task)
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertFalse(complete["reusedSubmitEvidence"])
        self.assertIn("no complete passing validator record", complete["evidenceDecision"])

    def test_validator_plan_change_invalidates_reuse(self):
        self.approve_to_close()
        task = self.state_task()
        task["requiredValidators"] = [[sys.executable, "-c", "print('focused-alt')"]]
        self.store_task(task)
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertFalse(complete["reusedSubmitEvidence"])
        self.assertEqual([item["command"] for item in complete["validators"]], [[sys.executable, "-c", "print('focused-alt')"]])

    def test_tampered_fingerprint_reruns_validators(self):
        complete = self.tamper_submit_evidence(lambda submit: submit.update(sourceFingerprint="0" * 64))
        self.assertIn("source fingerprint changed since submit", complete["evidenceDecision"])

    def test_tampered_changed_file_scope_reruns_validators(self):
        def mutate(submit):
            submit["changedFiles"] = [*submit["changedFiles"], "smuggled.txt"]
        complete = self.tamper_submit_evidence(mutate)
        self.assertIn("changed-file scope drifted since submit", complete["evidenceDecision"])

    def test_tampered_validator_exit_code_reruns_validators(self):
        def mutate(submit):
            submit["validators"][0]["exitCode"] = 1
        complete = self.tamper_submit_evidence(mutate)
        self.assertIn("no complete passing validator record", complete["evidenceDecision"])

    def test_tampered_validator_command_reruns_validators(self):
        def mutate(submit):
            submit["validators"][0]["command"] = [sys.executable, "-c", "print('forged')"]
        complete = self.tamper_submit_evidence(mutate)
        self.assertIn("required validator plan changed since submit", complete["evidenceDecision"])

    def test_tampered_validator_extra_field_reruns_validators(self):
        def mutate(submit):
            submit["validators"][0]["skipped"] = True
        complete = self.tamper_submit_evidence(mutate)
        self.assertIn("no complete passing validator record", complete["evidenceDecision"])

    def test_tampered_validator_boolean_exit_code_reruns_validators(self):
        def mutate(submit):
            submit["validators"][0]["exitCode"] = True
        complete = self.tamper_submit_evidence(mutate)
        self.assertIn("no complete passing validator record", complete["evidenceDecision"])

    def test_tampered_evidence_version_reruns_validators(self):
        complete = self.tamper_submit_evidence(lambda submit: submit.update(evidenceVersion=2))
        self.assertIn("evidence version", complete["evidenceDecision"])

    def test_unknown_evidence_field_reruns_validators(self):
        complete = self.tamper_submit_evidence(lambda submit: submit.update(authenticated=True))
        self.assertIn("unknown fields: authenticated", complete["evidenceDecision"])

    def test_missing_evidence_field_reruns_validators(self):
        def mutate(submit):
            del submit["actor"]
        complete = self.tamper_submit_evidence(mutate)
        self.assertIn("incomplete: actor", complete["evidenceDecision"])

    def test_tampered_evidence_actor_reruns_validators(self):
        complete = self.tamper_submit_evidence(lambda submit: submit.update(actor=RELEASE))
        self.assertIn("actor does not match the task implementation mode", complete["evidenceDecision"])

    def test_tampered_evidence_timestamp_reruns_validators(self):
        def mutate(submit):
            submit["at"] = None
        complete = self.tamper_submit_evidence(mutate)
        self.assertIn("timestamp is missing", complete["evidenceDecision"])

    def test_completion_records_evidence_trust_boundary(self):
        self.approve_to_close()
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertTrue(complete["reusedSubmitEvidence"])
        self.assertIn("controller-owned", complete["trustBoundary"])
        self.assertIn("tasks/tracker.json", complete["trustBoundary"])

    def test_fully_consistent_forged_evidence_is_a_documented_limitation(self):
        """Documented trust-boundary limitation, not a guarantee.

        Without authenticated or append-only evidence the controller cannot distinguish a fully
        consistent forged record from genuine evidence, so the focused validator is intentionally not
        rerun. Every single-field tamper is still detected and forces a rerun; see the tamper tests
        above and the trust-boundary section of docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md.
        """
        ledger = self.arm_recording_validator()
        self.approve_to_close()
        self.assertEqual(self.run_count(ledger), 1)
        fingerprint, files = self.current_scope()
        task = self.state_task()
        task["workflow"]["submit"] = {
            "evidenceVersion": 1,
            "at": task["workflow"]["submit"]["at"],
            "actor": CODER,
            "validators": [{"command": list(command), "exitCode": 0} for command in task["requiredValidators"]],
            "sourceFingerprint": fingerprint,
            "changedFiles": files,
        }
        self.store_task(task)
        self.invoke("complete", "P-002", "--actor", RELEASE)
        complete = self.state_task()["workflow"]["complete"]
        self.assertTrue(complete["reusedSubmitEvidence"])
        self.assertEqual(self.run_count(ledger), 1, "a fully consistent forged record is undetectable by design")
        self.assertIn("reused submit evidence", complete["evidenceDecision"])

    def test_more_than_five_non_state_files_requires_split(self):
        self.switch("feature/p-002")
        self.invoke("start", "P-002", "--actor", ORCHESTRATOR)
        for index in range(6):
            (self.root / f"change-{index}.txt").write_text(f"{index}\n", encoding="utf-8")
        result = self.invoke("submit", "P-002", "--actor", CODER, ok=False)
        self.assertIn("TASK_TOO_LARGE_SPLIT_REQUIRED", result.stderr)

    def test_three_non_state_files_submit_without_size_warning(self):
        """Target band (1-3 files): the expected size submits silently."""
        self.stage_non_state_files(3)
        result = self.invoke("submit", "P-002", "--actor", CODER)
        self.assertNotIn("TASK_SIZE_WARNING", result.stderr)
        self.assertNotIn("TASK_TOO_LARGE_SPLIT_REQUIRED", result.stderr)
        self.assertEqual(self.state_task()["status"], "needs_review")

    def test_four_non_state_files_warn_without_blocking_submit(self):
        """Lower warning band (4-5 files): warns on stderr exactly once and still submits."""
        self.stage_non_state_files(4)
        result = self.invoke("submit", "P-002", "--actor", CODER)
        self.assertIn("TASK_SIZE_WARNING", result.stderr)
        self.assertIn("4 non-state files", result.stderr)
        self.assertEqual(result.stderr.count("TASK_SIZE_WARNING"), 1, "one command warns exactly once")
        self.assertNotIn("TASK_TOO_LARGE_SPLIT_REQUIRED", result.stderr)
        self.assertEqual(self.state_task()["status"], "needs_review")

    def test_five_non_state_files_warn_at_warning_boundary(self):
        """Upper warning boundary: 5 files is the last non-blocking size."""
        self.stage_non_state_files(5)
        result = self.invoke("submit", "P-002", "--actor", CODER)
        self.assertIn("TASK_SIZE_WARNING", result.stderr)
        self.assertIn("5 non-state files", result.stderr)
        self.assertNotIn("TASK_TOO_LARGE_SPLIT_REQUIRED", result.stderr)
        self.assertEqual(self.state_task()["status"], "needs_review")

    def test_hard_split_blocks_submit_only_above_five_files(self):
        """Above the warning band the gate is validate-neutral and submit blocks before any write."""
        self.stage_non_state_files(6)
        validate = self.invoke("validate")
        self.assertNotIn("TASK_TOO_LARGE_SPLIT_REQUIRED", validate.stdout + validate.stderr)
        result = self.invoke("submit", "P-002", "--actor", CODER, ok=False)
        self.assertIn("TASK_TOO_LARGE_SPLIT_REQUIRED", result.stderr)
        self.assertIn("hard split threshold is 5", result.stderr)
        task = self.state_task()
        self.assertEqual(task["status"], "in_progress")
        self.assertNotIn("submit", task.get("workflow", {}))

    def test_size_gate_ignores_controller_state_and_generated_views(self):
        """Controller-owned state and review reports never count toward the size verdict."""
        self.stage_non_state_files(3)
        (self.root / "tasks/active/NEXT_TASK.md").write_text("regenerated\n", encoding="utf-8")
        (self.root / "docs/reviews/P-002.md").write_text("scope note\n", encoding="utf-8")
        result = self.invoke("submit", "P-002", "--actor", CODER)
        self.assertNotIn("TASK_SIZE_WARNING", result.stderr)
        self.assertEqual(self.state_task()["status"], "needs_review")

    def test_size_gate_is_bound_to_the_scope_it_fingerprints_and_persists(self):
        """Regression test for P-WF-T05-D1: the size verdict must bind to a single snapshot.

        Six non-state files appear after the size gate counted the scope and before the controller
        fingerprints and persists it. The gate must be decided on the scope that is actually recorded,
        so the oversized scope is rejected with `TASK_TOO_LARGE_SPLIT_REQUIRED`, no submit evidence is
        written, and the task stays `in_progress`. Before the fix the gate judged the smaller snapshot
        while a later gather fingerprinted and persisted the oversized one, so this submission passed.
        """
        self.switch("feature/p-002")
        self.invoke("start", "P-002", "--actor", ORCHESTRATOR)
        result = self.invoke_submit_with_scope_growth_during_validators(6)
        self.assertNotEqual(result.returncode, 0, "an oversized late scope must not pass the size gate")
        self.assertIn("TASK_TOO_LARGE_SPLIT_REQUIRED", result.stderr)
        self.assertEqual(sorted(path.name for path in self.root.glob("late-*.txt")), [f"late-{index}.txt" for index in range(6)])
        task = self.state_task()
        self.assertEqual(task["status"], "in_progress")
        self.assertNotIn("submit", task.get("workflow", {}))

    def test_counted_scope_fingerprint_and_persisted_evidence_are_one_snapshot(self):
        """The warning count, the fingerprint, and `workflow.submit.changedFiles` are one list."""
        self.stage_non_state_files(4)
        result = self.invoke("submit", "P-002", "--actor", CODER)
        submit = self.state_task()["workflow"]["submit"]
        self.assertIn("4 non-state files", result.stderr)
        self.assertEqual(len(submit["changedFiles"]), 4, "the gate must count the scope it persists")
        fingerprint, files = self.current_scope()
        self.assertEqual(submit["changedFiles"], files)
        self.assertEqual(submit["sourceFingerprint"], fingerprint)

    def test_warning_band_growth_during_validators_warns_once_and_submits(self):
        """Regression test for P-WF-T05-D2: a re-gathered scope warns once, never twice.

        The scope starts in the warning band (4 non-state files) and grows to 5 while the required
        validators run, so `submit` decides the size twice over two different snapshots: the silent
        pre-validator gate and the authoritative post-validator gate. The command must emit the warning
        exactly once, describe the scope it actually persists (5 files), and still succeed, with the
        counted scope, the fingerprint, and the recorded evidence all describing that one list.
        """
        self.stage_non_state_files(4)
        result = self.invoke_submit_with_scope_growth_during_validators(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("TASK_SIZE_WARNING"), 1, "submit must warn exactly once")
        self.assertIn("5 non-state files", result.stderr)
        self.assertNotIn("TASK_TOO_LARGE_SPLIT_REQUIRED", result.stderr)
        task = self.state_task()
        self.assertEqual(task["status"], "needs_review")
        submit = task["workflow"]["submit"]
        self.assertEqual(len(submit["changedFiles"]), 5, "the warning count and the persisted scope are one list")
        self.assertIn("late-0.txt", submit["changedFiles"])
        fingerprint, files = self.current_scope()
        self.assertEqual(submit["changedFiles"], files)
        self.assertEqual(submit["sourceFingerprint"], fingerprint)

    def test_warning_band_scope_warns_once_per_complete_command(self):
        """D2 for `complete`: the provisional gate and the rerun gate emit one warning together.

        The submitted evidence is unusable (tampered validator exit code), so `complete` gates the
        warning-band scope before the reuse decision and again over the freshly gathered rerun
        snapshot. Those two gate calls must still produce a single `TASK_SIZE_WARNING` for the command,
        and the task must still close.
        """
        self.stage_non_state_files(4)
        self.invoke("submit", "P-002", "--actor", CODER)
        self.write_review()
        self.invoke("review", "P-002", "--actor", REVIEWER, "--verdict", "approve", "--report", "docs/reviews/P-002.md")
        self.write_security()
        self.invoke("security", "P-002", "--actor", OWASP, "--verdict", "clear", "--report", "docs/security-reviews/P-002.md")
        task = self.state_task()
        task["workflow"]["submit"]["validators"] = [
            {"command": list(record["command"]), "exitCode": 1}
            for record in task["workflow"]["submit"]["validators"]
        ]
        self.store_task(task)
        result = self.invoke("complete", "P-002", "--actor", RELEASE)
        self.assertEqual(result.stderr.count("TASK_SIZE_WARNING"), 1, "complete must warn exactly once")
        self.assertIn("4 non-state files", result.stderr)
        self.assertEqual(self.state_task()["status"], "done")


if __name__ == "__main__":
    unittest.main()
