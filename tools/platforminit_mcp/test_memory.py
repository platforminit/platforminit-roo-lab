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

    def _record(
        self,
        record_id: str,
        *,
        scope: str,
        summary: str,
        component: str = "",
        task: str = "",
        tags: tuple[str, ...] = (),
        status: str = "active",
        record_type: str = "lesson",
    ) -> dict:
        return {
            "id": record_id,
            "scope": scope,
            "type": record_type,
            "component": component,
            "task": task,
            "summary": summary,
            "tags": list(tags),
            "status": status,
            "sources": ["docs/reviews/P-WF-T11.md"],
        }

    def _write_memory(self, *, framework_records=(), project_records=()) -> None:
        for path, records in ((self.framework, framework_records), (self.project, project_records)):
            path.write_text(
                "".join(json.dumps(record, separators=(",", ":")) + "\n" for record in records),
                encoding="utf-8",
            )

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


    def test_irrelevant_project_record_is_not_eligible_for_non_empty_query(self):
        self._write_memory(
            framework_records=[
                self._record(
                    "framework.test.release",
                    scope="framework",
                    component="release",
                    summary="Human merge remains mandatory after the release stage.",
                    tags=("release", "human-approval"),
                )
            ],
            project_records=[
                self._record(
                    "project.test.unrelated",
                    scope="project",
                    component="kitchen",
                    summary="Banana inventory notes for the office kitchen.",
                    tags=("banana",),
                ),
                self._record(
                    "project.test.related",
                    scope="project",
                    component="release",
                    summary="Release evidence stays attached to every merge request",
                    tags=("release",),
                ),
            ],
        )
        result = memory.get_relevant_memory(query="release merge", max_items=memory.HARD_MAX_ITEMS)
        ids = [item["id"] for item in result["items"]]
        # The zero-overlap project record only carries the project-scope bonus, so it must stay
        # ineligible even at the hard cap.
        self.assertNotIn("project.test.unrelated", ids)
        self.assertEqual(set(ids), {"framework.test.release", "project.test.related"})
        # Equal lexical overlap: the project scope bonus now acts as the bounded tie-break.
        self.assertEqual(ids, ["project.test.related", "framework.test.release"])

    def test_equal_relevance_records_are_tie_broken_deterministically(self):
        self._write_memory(
            framework_records=[
                self._record(
                    "framework.tie.framework",
                    scope="framework",
                    summary="Shared tiebreak token sample.",
                )
            ],
            project_records=[
                self._record("project.tie.b", scope="project", summary="Shared tiebreak token sample."),
                self._record("project.tie.a", scope="project", summary="Shared tiebreak token sample."),
            ],
        )
        first = memory.get_relevant_memory(query="tiebreak", max_items=memory.HARD_MAX_ITEMS)
        second = memory.get_relevant_memory(query="tiebreak", max_items=memory.HARD_MAX_ITEMS)
        ids = [item["id"] for item in first["items"]]
        self.assertEqual(ids, [item["id"] for item in second["items"]])
        # Equal overlap: the project-scope bonus wins the tie-break, then record id stabilizes order.
        self.assertEqual(ids, ["project.tie.a", "project.tie.b", "framework.tie.framework"])

    def test_exact_task_and_component_matches_stay_lexical_independent(self):
        self._write_memory(
            framework_records=[
                self._record("framework.test.other", scope="framework", summary="Unrelated framework note.")
            ],
            project_records=[
                self._record(
                    "project.test.tasked",
                    scope="project",
                    component="memory",
                    task="P-WF-T10",
                    summary="No shared words with the requested component here.",
                ),
                self._record(
                    "project.test.unrelated",
                    scope="project",
                    component="kitchen",
                    task="P-WF-T99",
                    summary="No shared words with the requested component here.",
                ),
            ],
        )
        by_task = memory.get_relevant_memory(task_id="P-WF-T10", max_items=memory.HARD_MAX_ITEMS)
        self.assertEqual([item["id"] for item in by_task["items"]], ["project.test.tasked"])

        by_component = memory.get_relevant_memory(component="memory", max_items=memory.HARD_MAX_ITEMS)
        self.assertEqual([item["id"] for item in by_component["items"]], ["project.test.tasked"])

    def test_empty_query_baseline_is_bounded_and_active_only(self):
        self._write_memory(
            framework_records=[
                self._record(
                    f"framework.baseline.{index:02d}",
                    scope="framework",
                    summary=f"Baseline note {index}.",
                )
                for index in range(4)
            ],
            project_records=[
                self._record("project.baseline.active", scope="project", summary="Active project baseline note."),
                self._record(
                    "project.baseline.deprecated",
                    scope="project",
                    summary="Deprecated project note.",
                    status="deprecated",
                ),
                self._record(
                    "project.baseline.historical",
                    scope="project",
                    summary="Historical project note.",
                    status="historical",
                ),
            ],
        )
        result = memory.get_relevant_memory(max_items=3)
        self.assertEqual(result["itemCount"], 3)
        self.assertEqual(len(result["items"]), 3)
        self.assertTrue(all(item["status"] == "active" for item in result["items"]))
        self.assertFalse(
            {"project.baseline.deprecated", "project.baseline.historical"}
            & {item["id"] for item in result["items"]}
        )
        self.assertEqual(
            [item["id"] for item in result["items"]],
            ["project.baseline.active", "framework.baseline.00", "framework.baseline.01"],
        )

    def test_max_items_limit_and_hard_cap_are_enforced(self):
        self._write_memory(
            framework_records=[
                self._record(
                    f"framework.bulk.{index:02d}",
                    scope="framework",
                    summary=f"Bulk retrieval note {index}.",
                )
                for index in range(memory.HARD_MAX_ITEMS + 5)
            ],
        )
        default_result = memory.get_relevant_memory(query="bulk")
        self.assertEqual(default_result["itemCount"], memory.DEFAULT_MAX_ITEMS)
        self.assertEqual(len(default_result["items"]), memory.DEFAULT_MAX_ITEMS)

        capped = memory.get_relevant_memory(query="bulk", max_items=memory.HARD_MAX_ITEMS + 50)
        self.assertEqual(capped["itemCount"], memory.HARD_MAX_ITEMS)
        self.assertEqual(
            [item["id"] for item in capped["items"]],
            [f"framework.bulk.{index:02d}" for index in range(memory.HARD_MAX_ITEMS)],
        )

        single = memory.get_relevant_memory(query="bulk", max_items=1)
        self.assertEqual(single["itemCount"], 1)
        self.assertEqual([item["id"] for item in single["items"]], ["framework.bulk.00"])


if __name__ == "__main__":
    unittest.main()
