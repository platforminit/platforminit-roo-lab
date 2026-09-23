from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tools.platforminit_mcp import memory


class MemoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.framework = root / "framework.jsonl"
        self.project = root / "project.jsonl"

        self.framework.write_text(
            json.dumps(
                {
                    "id": "framework.test.release",
                    "scope": "framework",
                    "type": "workflow-pattern",
                    "component": "release",
                    "task": "",
                    "summary": "Human merge remains mandatory after the release stage.",
                    "tags": ["release", "human-approval"],
                    "status": "active",
                    "sources": [".roo/rules-platforminit-release-manager/rules.md"],
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        self.project.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "id": "project.test.current",
                            "scope": "project",
                            "type": "current-state",
                            "component": "memory",
                            "task": "P-WF-T10",
                            "summary": "Project memory is advisory and taskctl remains authoritative.",
                            "tags": ["memory", "taskctl"],
                            "status": "active",
                            "sources": ["tasks/tracker.json"],
                        },
                        separators=(",", ":"),
                    ),
                    json.dumps(
                        {
                            "id": "project.test.historical",
                            "scope": "project",
                            "type": "lesson",
                            "component": "memory",
                            "task": "",
                            "summary": "Historical record must not be returned as active context.",
                            "tags": ["memory"],
                            "status": "historical",
                            "sources": ["docs/history.md"],
                        },
                        separators=(",", ":"),
                    ),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        self.patchers = [
            mock.patch.object(memory, "FRAMEWORK_MEMORY", self.framework),
            mock.patch.object(memory, "PROJECT_MEMORY", self.project),
        ]
        for patcher in self.patchers:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patchers):
            patcher.stop()
        self.tmp.cleanup()

    def test_retrieval_is_bounded_and_advisory(self):
        result = memory.get_relevant_memory(
            query="memory taskctl",
            task_id="P-WF-T10",
            component="memory",
            max_items=2,
        )
        self.assertTrue(result["advisoryOnly"])
        self.assertEqual(result["authoritativeTaskSource"], "tasks/tracker.json")
        self.assertLessEqual(result["itemCount"], 2)
        self.assertEqual(result["itemCount"], len(result["items"]))
        self.assertTrue(all(item["status"] == "active" for item in result["items"]))
        self.assertNotIn("project.test.historical", {item["id"] for item in result["items"]})

    def test_empty_query_returns_small_active_baseline(self):
        result = memory.get_relevant_memory(max_items=1)
        self.assertEqual(result["itemCount"], 1)
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["items"][0]["status"], "active")

    def test_input_bounds_fail_closed(self):
        with self.assertRaises(memory.MemoryError):
            memory.get_relevant_memory(query=7)
        with self.assertRaises(memory.MemoryError):
            memory.get_relevant_memory(query="x" * (memory.MAX_QUERY_LENGTH + 1))
        with self.assertRaises(memory.MemoryError):
            memory.validate_max_items(True)
        with self.assertRaises(memory.MemoryError):
            memory.validate_max_items("6")
        self.assertEqual(memory.validate_max_items(10**6), memory.HARD_MAX_ITEMS)
        self.assertEqual(memory.validate_max_items(0), 1)

    def test_invalid_and_duplicate_jsonl_records_fail_closed(self):
        bad = self.project.parent / "bad.jsonl"
        bad.write_text(
            json.dumps(
                {
                    "id": "project.bad.record",
                    "scope": "project",
                    "summary": "bad",
                    "unsupported": True,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        with self.assertRaises(memory.MemoryError):
            memory.load_jsonl(bad, expected_scope="project")

        duplicate = self.project.parent / "duplicate.jsonl"
        row = {
            "id": "project.duplicate",
            "scope": "project",
            "summary": "one",
            "status": "active",
        }
        duplicate.write_text(
            json.dumps(row) + "\n" + json.dumps({**row, "summary": "two"}) + "\n",
            encoding="utf-8",
        )
        with self.assertRaises(memory.MemoryError):
            memory.load_jsonl(duplicate, expected_scope="project")

    def test_append_project_record_is_explicit_and_duplicate_safe(self):
        record = {
            "id": "project.test.appended",
            "scope": "project",
            "type": "lesson",
            "component": "validation",
            "task": "P-WF-T10",
            "summary": "A reviewed project-memory record is repository-visible JSONL state.",
            "tags": ["memory", "validation"],
            "status": "active",
            "sources": ["docs/reviews/P-WF-T10.md"],
        }
        appended = memory.append_project_record(record)
        self.assertEqual(appended["id"], record["id"])
        stored = memory.load_jsonl(self.project, expected_scope="project")
        self.assertIn(record["id"], {item["id"] for item in stored})
        with self.assertRaises(memory.MemoryError):
            memory.append_project_record(record)


if __name__ == "__main__":
    unittest.main()
