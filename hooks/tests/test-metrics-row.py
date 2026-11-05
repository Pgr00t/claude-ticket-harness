#!/usr/bin/env python3
"""Tests for hooks/metrics-row.py, the --outcomes pass in particular: the three outcome rules (QA bounces
from a tracker changelog, production incidents from Sentry, human review comments from GitHub), the
fetchers that stand in for Jira and Sentry, the `outcomes` config block, and the CSV rewrite that fills
only the three outcome columns. Nothing here reaches the network: every source is a fake handed in as a
fetcher or a runner.

  python3 -I hooks/tests/test-metrics-row.py                  # exit 0 when every case passes
  SCRIPT=/path/to/metrics-row.py python3 -I .../test-metrics-row.py
"""
import csv
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("SCRIPT") or os.path.join(HERE, "..", "metrics-row.py")
spec = importlib.util.spec_from_file_location("metrics_row", SCRIPT)
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

# A tracker workflow with stations between review and done, as the config would list them.
LATE = ["In Review (code review)", "In QA", "Ready for release on Prod", "Done"]
EARLY = ["Scoping - PRD", "Ready for Dev", "In Progress", "Reopened"]
ORG = "acme"
CFG = mr.OutcomesConfig({
    "since": "2026-10-27",
    "release_branch": "release/live",
    "jira": {"site": "acme.atlassian.net", "late_statuses": LATE, "early_statuses": EARLY},
    "sentry": {"org": ORG, "environment": "live", "projects": ["widgets-api", "widgets-api-worker"]},
})

HEADER_OLD = ("repo,ticket,branch,pr,pr_state,round_date,checks,rounds,correct_checks,mutants_run,mutants_survived,"
              "judge_fails,qa_bounces,human_approvals,human_review_comments,changes_requested,plan_approved_utc,"
              "packet_utc,pushed_utc,pr_opened_utc,pr_merged_utc,plan_to_push_min,open_to_merge_h,spec_started_utc,"
              "session_tokens,judge_tokens,interruptions,note")
ROW_OLD = ("widgets-api,KEY-2254 (readiness),KEY-2254-readiness,1453,MERGED,2026-10-21,24,1,1,8,2,0,1,1,0,0,,"
           "2026-10-21T15:39Z,2026-10-21T15:43Z,2026-10-21T15:43Z,2026-10-22T12:22Z,,20.6,,,,,"
           "\"no plan file; qa_bounces is ticket-level, typed\"")
ROW_NEW = ("widgets-api,KEY-2263/KEY-2264,KEY-2263-KEY-2264-scoping,1462,MERGED,2026-10-27,10,1,1,14,1,0,,1,0,0,"
           "2026-10-27T15:00Z,2026-10-27T15:12Z,2026-10-27T15:16Z,2026-10-27T15:17Z,2026-10-28T19:45Z,16,28.5,,,,,"
           "\"two tickets, one PR\"")
ROW_NOKEY = ("widgets-api,zero-red-unit-suite,zero-red-unit-suite,1464,MERGED,2026-10-27,5,1,0,11,1,0,,1,0,0,"
             "2026-10-27T17:46Z,2026-10-27T18:07Z,2026-10-27T18:05Z,2026-10-27T18:06Z,2026-10-28T19:46Z,19,25.7,"
             "2026-10-27T17:44Z,286196,336144,0,Move 2")


def history(when, frm, to, field="status"):
    return {"created": when, "items": [{"field": field, "fromString": frm, "toString": to}]}


class Config(unittest.TestCase):
    def test_defaults_when_the_block_is_absent(self):
        c = mr.OutcomesConfig()
        self.assertEqual((c.since, c.release_branch, c.jira_site, c.sentry_org), ("", "", "", ""))
        self.assertEqual(c.late_statuses, {"In Review", "Done"})
        self.assertEqual(c.early_statuses, {"In Progress", "Reopened"})
        self.assertEqual((c.sentry_api, c.sentry_env), ("https://sentry.io/api/0/", "production"))
        self.assertEqual(c.projects_for("Acme/widgets-api"), ["widgets-api"])

    def test_values_come_from_the_block_and_the_secrets_file_is_expanded(self):
        c = mr.OutcomesConfig({"secrets_file": "~/x/.env", "sentry": {"projects": ["a", "b"]}}, key_regex=r"T\d+")
        self.assertEqual(c.secrets_file, os.path.expanduser("~/x/.env"))
        self.assertEqual(c.projects_for("o/r"), ["a", "b"])
        self.assertEqual(c.key_regex, r"T\d+")
        self.assertEqual(CFG.projects_for("Acme/widgets-api"), ["widgets-api", "widgets-api-worker"])
        self.assertEqual(CFG.late_statuses, set(LATE))

    def test_from_root_reads_harness_json_and_tolerates_its_absence(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(mr.OutcomesConfig.from_root(d).release_branch, "")
            os.makedirs(os.path.join(d, ".claude"))
            with open(os.path.join(d, ".claude", "harness.json"), "w") as f:
                json.dump({"ticket_key_regex": r"\bT-\d+", "outcomes": {"release_branch": "release/live", "sentry": {"org": ORG}}}, f)
            c = mr.OutcomesConfig.from_root(d)
            self.assertEqual((c.release_branch, c.sentry_org, c.key_regex), ("release/live", ORG, r"\bT-\d+"))
            with open(os.path.join(d, ".claude", "harness.json"), "w") as f:
                f.write("{not json")
            self.assertEqual(mr.OutcomesConfig.from_root(d).release_branch, "")


class Bounces(unittest.TestCase):
    AFTER = "2026-10-27T15:17Z"  # the PR opened

    def test_review_or_later_back_to_an_earlier_status_after_the_pr_opened_is_one_bounce(self):
        hs = [history("2026-10-29T23:21:06.772-0700", "In Review (code review)", "In QA"),
              history("2026-10-30T02:00:00.000-0700", "In QA", "Ready for Dev")]
        self.assertEqual(mr.count_bounces(hs, self.AFTER, LATE, EARLY), 1)

    def test_every_late_to_early_pair_counts_including_done_to_reopened(self):
        hs = [history("2026-10-30T02:00:00.000-0700", "Done", "Reopened"),
              history("2026-10-31T02:00:00.000-0700", "Ready for release on Prod", "In Progress"),
              history("2026-11-01T02:00:00.000-0700", "In Review (code review)", "Scoping - PRD")]
        self.assertEqual(mr.count_bounces(hs, self.AFTER, LATE, EARLY), 3)

    def test_the_default_statuses_are_the_generic_rule(self):
        hs = [history("2026-10-30T02:00:00.000-0700", "Done", "Reopened"),
              history("2026-10-31T02:00:00.000-0700", "In Review", "In Progress"),
              history("2026-11-01T02:00:00.000-0700", "In QA", "Ready for Dev")]  # not in the default lists
        self.assertEqual(mr.count_bounces(hs, self.AFTER), 2)

    def test_forward_moves_and_non_status_items_do_not_count(self):
        hs = [history("2026-10-27T10:04:49.957-0700", "Ready for Dev", "In Progress"),
              history("2026-10-27T10:05:15.298-0700", "In Progress", "In Review (code review)"),
              history("2026-10-29T23:21:06.490-0700", "", "Ranked higher", field="Rank"),
              history("2026-10-29T23:21:06.772-0700", "In Review (code review)", "In QA")]
        self.assertEqual(mr.count_bounces(hs, self.AFTER, LATE, EARLY), 0)

    def test_a_bounce_before_the_pr_opened_is_churn_not_an_escape(self):
        hs = [history("2026-10-27T07:00:00.000-0700", "In Review (code review)", "In Progress")]  # 14:00Z < 15:17Z
        self.assertEqual(mr.count_bounces(hs, self.AFTER, LATE, EARLY), 0)
        hs = [history("2026-10-27T08:30:00.000-0700", "In Review (code review)", "In Progress")]  # 15:30Z > 15:17Z
        self.assertEqual(mr.count_bounces(hs, self.AFTER, LATE, EARLY), 1)

    def test_jira_changelog_reads_the_issue_and_pages_when_the_embedded_log_is_short(self):
        calls = []

        def fetch(path, params=None):
            calls.append((path, dict(params or {})))
            if path == "issue/KEY-2263":
                return {"key": "KEY-2263", "changelog": {"total": 3, "histories": [history("a", "x", "y")]}}
            if path == "issue/KEY-2263/changelog":
                start = int(params.get("startAt", 0))
                if start == 0:
                    return {"values": [history("a", "x", "y"), history("b", "x", "y")], "isLast": False}
                return {"values": [history("c", "x", "y")], "isLast": True}
            raise AssertionError(path)

        hs = mr.jira_changelog("KEY-2263", fetch)
        self.assertEqual([h["created"] for h in hs], ["a", "b", "c"])
        self.assertEqual(calls[0][0], "issue/KEY-2263")
        self.assertEqual(calls[0][1].get("expand"), "changelog")

    def test_jira_changelog_uses_the_embedded_log_when_it_is_complete(self):
        def fetch(path, params=None):
            self.assertEqual(path, "issue/KEY-2264")
            return {"key": "KEY-2264", "changelog": {"total": 2, "histories": [history("a", "x", "y"), history("b", "x", "y")]}}

        self.assertEqual(len(mr.jira_changelog("KEY-2264", fetch)), 2)


def issue(id_, short, first_seen, project="widgets-api", annotations=None):
    return {"id": str(id_), "shortId": short, "firstSeen": first_seen, "project": {"slug": project},
            "annotations": annotations or []}


def event(*filenames):
    frames = [{"filename": f, "function": "fn", "lineNo": 1, "inApp": not f.startswith("celery/")} for f in filenames]
    return {"eventID": "e", "entries": [{"type": "exception", "data": {"values": [{"type": "KeyError", "stacktrace": {"frames": frames}}]}}]}


class Incidents(unittest.TestCase):
    SINCE = "2026-10-30T06:14Z"
    CHANGED = ["app/queue/celery.py", "app/queue/task/_sync_calendar_events.py", "tests/unit/x.py"]

    def fetch_for(self, issues, events, external=None, calls=None):
        def fetch(path, params=None):
            if calls is not None:
                calls.append((path, dict(params or {})))
            if path.startswith(f"projects/{ORG}/") and path.endswith("/issues/"):
                slug = path.split("/")[2]
                return [i for i in issues if i["project"]["slug"] == slug]
            if path.startswith("issues/") and path.endswith("/events/latest/"):
                return events[path.split("/")[1]]
            if path.startswith(f"organizations/{ORG}/issues/") and path.endswith("/external-issues/"):
                return (external or {}).get(path.split("/")[3], [])
            raise AssertionError(path)
        return fetch

    def test_frame_in_a_changed_file_after_release_counts_once(self):
        issues = [issue(1, "WIDGETS-API-WORKER-TQ", "2026-11-02T15:49:04.805Z", "widgets-api-worker")]
        events = {"1": event("celery/worker/consumer/consumer.py", "/opt/app/app/queue/celery.py")}
        n, ids = mr.sentry_incidents(self.CHANGED, [], self.SINCE, ["widgets-api", "widgets-api-worker"],
                                     self.fetch_for(issues, events), ORG, "live")
        self.assertEqual((n, ids), (1, ["WIDGETS-API-WORKER-TQ"]))

    def test_first_seen_before_release_or_frames_elsewhere_do_not_count(self):
        issues = [issue(1, "A-1", "2026-10-30T06:13:59Z"), issue(2, "A-2", "2026-10-31T00:00:00Z")]
        events = {"1": event("app/queue/celery.py"), "2": event("app/services/other.py", "celery/app.py")}
        n, ids = mr.sentry_incidents(self.CHANGED, ["KEY-2263"], self.SINCE, ["widgets-api"], self.fetch_for(issues, events), ORG, "live")
        self.assertEqual((n, ids), (0, []))

    def test_a_tracker_link_naming_the_ticket_counts_without_a_frame_match(self):
        issues = [issue(3, "A-3", "2026-10-31T00:00:00Z"), issue(4, "A-4", "2026-10-31T00:00:00Z", annotations=[{"displayName": "KEY-2264"}])]
        events = {"3": event("app/services/other.py"), "4": event("app/services/other.py")}
        external = {"3": [{"key": "KEY-2263", "displayName": "KEY-2263"}]}
        n, ids = mr.sentry_incidents(self.CHANGED, ["KEY-2263", "KEY-2264"], self.SINCE, ["widgets-api"],
                                     self.fetch_for(issues, events, external), ORG, "live")
        self.assertEqual((n, ids), (2, ["A-3", "A-4"]))

    def test_the_listing_asks_for_the_configured_environment_of_each_project(self):
        calls = []
        mr.sentry_incidents(self.CHANGED, [], self.SINCE, ["widgets-api", "widgets-api-worker"], self.fetch_for([], {}, calls=calls), ORG, "live")
        listing = [(p, q) for p, q in calls if p.endswith("/issues/")]
        self.assertEqual([p for p, _ in listing], [f"projects/{ORG}/widgets-api/issues/", f"projects/{ORG}/widgets-api-worker/issues/"])
        for _, q in listing:
            self.assertEqual(q.get("environment"), "live")
            self.assertIn("firstSeen:>2026-10-30", q.get("query", ""))

    def test_frames_match_by_path_suffix_either_way_but_not_by_basename(self):
        self.assertTrue(mr.frame_hits("/app/app/queue/celery.py", ["app/queue/celery.py"]))
        self.assertTrue(mr.frame_hits("queue/celery.py", ["app/queue/celery.py"]))
        self.assertFalse(mr.frame_hits("celery.py", ["app/queue/celery.py"]))
        self.assertFalse(mr.frame_hits("app/queue/celery.py", ["other/app/queue/celery.pyc"]))


class ReleaseReached(unittest.TestCase):
    def test_first_release_merge_that_contains_the_merge_commit_gives_the_time(self):
        seen = []

        def run(args, cwd=None):
            seen.append(args)
            if args[:3] == ["git", "-C", "/r"] and args[3] == "log":
                return "aaa 2026-10-28T10:00:00+05:30\nbbb 2026-10-30T11:44:11+05:30\nccc 2026-11-05T09:00:00+05:30\n"
            if args[3] == "merge-base":
                return "m1\n" if args[5] in ("bbb", "ccc") else "zzz\n"
            if args[3] == "rev-parse":
                return "m1\n"
            if args[3] == "fetch":
                return ""
            raise AssertionError(args)
        self.assertEqual(mr.release_reached_utc("/r", "m1", "release/live", run), "2026-10-30T06:14Z")
        self.assertIn(["git", "-C", "/r", "fetch", "-q", "origin", "release/live"], seen)
        self.assertTrue(any(a[3] == "log" and a[-1] == "origin/release/live" for a in seen))

    def test_blank_when_no_release_merge_contains_it_yet(self):
        def run(args, cwd=None):
            if args[3] == "log":
                return "aaa 2026-10-28T10:00:00+05:30\n"
            return ""
        self.assertEqual(mr.release_reached_utc("/r", "m1", "release/live", run), "")


class ReviewComments(unittest.TestCase):
    def test_threads_conversation_and_review_text_count_approvals_and_the_author_do_not(self):
        def run(args, cwd=None):
            if args[:3] == ["gh", "pr", "view"]:
                return json.dumps({"state": "MERGED", "createdAt": "2026-11-01T14:41:00Z", "mergedAt": "2026-11-02T15:29:37Z", "author": {"login": "author"}})
            endpoint = args[2]
            if endpoint.endswith("/reviews"):
                return json.dumps([{"user": {"login": "rev1", "type": "User"}, "state": "APPROVED", "body": ""},
                                   {"user": {"login": "rev2", "type": "User"}, "state": "COMMENTED", "body": "one thought"},
                                   {"user": {"login": "author", "type": "User"}, "state": "COMMENTED", "body": "self"}])
            if endpoint.endswith("/pulls/1473/comments"):
                return json.dumps([{"user": {"login": "rev1", "type": "User"}, "body": "inline a"},
                                   {"user": {"login": "rev1", "type": "User"}, "body": "inline b"},
                                   {"user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "bot"}])
            if endpoint.endswith("/issues/1473/comments"):
                return json.dumps([{"user": {"login": "rev2", "type": "User"}, "body": "conversation"}])
            raise AssertionError(args)
        got = mr.gh_fields("Acme/widgets-api", "1473", run)
        self.assertEqual(got["human_review_comments"], "4")
        self.assertEqual(got["human_approvals"], "1")


class Fetchers(unittest.TestCase):
    def test_no_token_or_no_site_means_no_fetcher(self):
        self.assertIsNone(mr.jira_fetcher({"ATLASSIAN_SITE": "x.atlassian.net"}))
        self.assertIsNone(mr.jira_fetcher({"ATLASSIAN_EMAIL": "a@b", "ATLASSIAN_API_TOKEN": "t"}))  # no site anywhere
        self.assertIsNotNone(mr.jira_fetcher({"ATLASSIAN_EMAIL": "a@b", "ATLASSIAN_API_TOKEN": "t"}, site="acme.atlassian.net"))
        self.assertIsNotNone(mr.jira_fetcher({"ATLASSIAN_EMAIL": "a@b", "ATLASSIAN_API_TOKEN": "t", "ATLASSIAN_SITE": "x.atlassian.net"}))
        self.assertIsNone(mr.sentry_fetcher({}))
        self.assertIsNotNone(mr.sentry_fetcher({"SENTRY_AUTH_TOKEN": "t"}))

    def test_load_env_reads_the_named_file_and_the_environment_wins(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, ".env")
            with open(p, "w") as f:
                f.write("# secrets\nATLASSIAN_EMAIL='a@b'\nSENTRY_AUTH_TOKEN=\"file-token\"\nOTHER=1\n")
            old = os.environ.get("SENTRY_AUTH_TOKEN")
            os.environ["SENTRY_AUTH_TOKEN"] = "env-token"
            try:
                env = mr.load_env(p)
            finally:
                if old is None:
                    del os.environ["SENTRY_AUTH_TOKEN"]
                else:
                    os.environ["SENTRY_AUTH_TOKEN"] = old
            self.assertEqual((env["ATLASSIAN_EMAIL"], env["SENTRY_AUTH_TOKEN"], env["OTHER"]), ("a@b", "env-token", "1"))
            self.assertNotIn("ATLASSIAN_EMAIL", mr.load_env(""))  # no file: environment only

    def test_dump_fetcher_maps_a_path_to_a_file_and_a_missing_file_is_unreachable(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "jira"))
            with open(os.path.join(d, "jira", "issue__KEY-2263.json"), "w") as f:
                json.dump({"key": "KEY-2263"}, f)
            fetch = mr.dump_fetcher(d, "jira")
            self.assertEqual(fetch("issue/KEY-2263", {"expand": "changelog"}), {"key": "KEY-2263"})
            with self.assertRaises(mr.Unreachable):
                fetch("issue/KEY-2264", {"expand": "changelog"})
            self.assertEqual(mr.dump_name(f"projects/{ORG}/widgets-api/issues/"), f"projects__{ORG}__widgets-api__issues.json")
            self.assertEqual(mr.dump_name("issues/123/events/latest/"), "issues__123__events__latest.json")


class FakeSources:
    """Stands in for mr.Sources: answers per row from dicts, None meaning unreachable or not applicable."""

    def __init__(self, review=None, bounces=None, incidents=None, unreachable=None):
        self._review, self._bounces, self._incidents = review or {}, bounces or {}, incidents or {}
        self.unreachable = dict(unreachable or {})
        self.asked = []

    def review(self, row):
        self.asked.append(("review", row["pr"]))
        return self._review.get(row["pr"])

    def bounces(self, row):
        self.asked.append(("bounces", row["ticket"]))
        return self._bounces.get(row["ticket"])

    def incidents(self, row):
        self.asked.append(("incidents", row["pr"]))
        return self._incidents.get(row["pr"])


class OutcomesPass(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.d, ".claude"))
        self.path = os.path.join(self.d, ".claude", "metrics.csv")
        with open(self.path, "w") as f:
            f.write("\n".join([HEADER_OLD, ROW_OLD, ROW_NEW, ROW_NOKEY]) + "\n")

    def run_pass(self, sources, since="2026-10-27", dry=False):
        buf = io.StringIO()
        with redirect_stdout(buf):
            mr.outcomes(self.d, since, sources, dry)
        with open(self.path) as f:
            return buf.getvalue(), list(csv.DictReader(f))

    def test_adds_the_column_fills_the_three_cells_and_leaves_every_other_cell_as_read(self):
        with open(self.path) as f:
            before = list(csv.DictReader(f))
        out, rows = self.run_pass(FakeSources(review={"1462": "0", "1464": "0"}, bounces={"KEY-2263/KEY-2264": "0"}, incidents={"1462": "0", "1464": "0"}))
        with open(self.path) as f:
            self.assertEqual(f.readline().strip(), HEADER_OLD.replace("qa_bounces,", "qa_bounces,prod_incidents,"))
        new = rows[1]
        self.assertEqual((new["qa_bounces"], new["human_review_comments"], new["prod_incidents"]), ("0", "0", "0"))
        for col in before[1]:
            if col not in ("qa_bounces", "human_review_comments", "prod_incidents"):
                self.assertEqual(new[col], before[1][col], col)
        self.assertEqual(rows[2]["qa_bounces"], "")  # no key: not asked, stays blank
        self.assertEqual(rows[2]["prod_incidents"], "0")

    def test_rows_before_since_are_written_back_untouched_with_a_blank_new_cell(self):
        self.run_pass(FakeSources(review={"1453": "9"}, bounces={"KEY-2254 (readiness)": "9"}, incidents={"1453": "9"}))
        with open(self.path) as f:
            text = f.read().splitlines()
        self.assertEqual(text[1], ROW_OLD.replace(",0,1,1,0,0,,", ",0,1,,1,0,0,,", 1))
        self.assertEqual(next(csv.DictReader(text))["qa_bounces"], "1")

    def test_an_empty_since_means_every_row(self):
        out, rows = self.run_pass(FakeSources(review={"1453": "7", "1462": "0", "1464": "0"}), since="")
        self.assertEqual(rows[0]["human_review_comments"], "7")
        self.assertIn("3 row(s) since the first", out)

    def test_an_unreachable_source_leaves_the_cell_as_it_was_and_is_named_in_the_summary(self):
        with open(self.path, "w") as f:
            f.write("\n".join([HEADER_OLD, ROW_NEW.replace(",0,,1,0,0,", ",0,2,1,7,0,", 1)]) + "\n")
        src = FakeSources(review={"1462": "0"}, unreachable={"Jira": "no ATLASSIAN_API_TOKEN", "Sentry": "no SENTRY_AUTH_TOKEN"})
        out, rows = self.run_pass(src)
        self.assertEqual(rows[0]["qa_bounces"], "2")
        self.assertEqual(rows[0]["prod_incidents"], "")
        self.assertEqual(rows[0]["human_review_comments"], "0")
        self.assertIn("Jira unreachable (no ATLASSIAN_API_TOKEN)", out)
        self.assertIn("Sentry unreachable (no SENTRY_AUTH_TOKEN)", out)
        self.assertNotIn("qa_bounces=0", out)

    def test_dry_run_prints_the_cells_and_writes_nothing(self):
        with open(self.path) as f:
            before = f.read()
        out, _ = self.run_pass(FakeSources(review={"1462": "0"}, bounces={"KEY-2263/KEY-2264": "1"}, incidents={"1462": "0"}), dry=True)
        with open(self.path) as f:
            self.assertEqual(f.read(), before)
        self.assertIn("KEY-2263/KEY-2264", out)
        self.assertIn("qa_bounces=1", out)

    def test_a_row_without_a_pr_asks_nothing_of_github_or_sentry(self):
        with open(self.path, "w") as f:
            f.write("\n".join([HEADER_OLD, ROW_NEW.replace(",1462,MERGED,", ",,,", 1)]) + "\n")
        src = FakeSources()
        self.run_pass(src)
        self.assertNotIn(("review", ""), src.asked)
        self.assertNotIn(("incidents", ""), src.asked)

    def test_build_row_carries_the_new_column(self):
        self.assertIn("prod_incidents", mr.COLUMNS)
        self.assertEqual(mr.COLUMNS.index("prod_incidents"), mr.COLUMNS.index("qa_bounces") + 1)
        self.assertEqual(mr.COLUMNS[-1], "note")

    def test_append_to_a_file_that_predates_the_column_rewrites_it_with_the_column(self):
        row = {c: "" for c in mr.COLUMNS}
        row.update(repo="widgets-api", ticket="KEY-9", branch="KEY-9-x", prod_incidents="")
        with redirect_stdout(io.StringIO()):
            mr.append(self.d, row, False)
        with open(self.path) as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0], ",".join(mr.COLUMNS))
        rows = list(csv.DictReader(lines))
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["qa_bounces"], "1")  # the old row's cells kept their place
        self.assertEqual(rows[3]["ticket"], "KEY-9")


class SourcesRules(unittest.TestCase):
    """mr.Sources wires the rules to the fetchers: blank (None) when a source is missing or the row is not ready."""

    def test_bounces_sums_the_keys_is_blank_without_a_key_and_none_without_jira(self):
        def fetch(path, params=None):
            key = path.split("/")[1]
            when = "2026-10-30T02:00:00.000-0700"
            n = {"KEY-2263": 1, "KEY-2264": 2}[key]
            return {"changelog": {"total": n, "histories": [history(when, "In QA", "Ready for Dev")] * n}}
        s = mr.Sources("/r", "o/r", jira_fetch=fetch, sentry_fetch=None, run=lambda a, cwd=None: "", cfg=CFG)
        self.assertEqual(s.bounces({"ticket": "KEY-2263/KEY-2264", "pr_opened_utc": "2026-10-27T15:17Z"}), "3")
        self.assertEqual(s.bounces({"ticket": "zero-red-unit-suite", "pr_opened_utc": "2026-10-27T18:06Z"}), "")  # no key: blank, not kept
        s2 = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=None, run=lambda a, cwd=None: "", cfg=CFG)
        self.assertIsNone(s2.bounces({"ticket": "KEY-2263", "pr_opened_utc": "2026-10-27T15:17Z"}))
        self.assertEqual(s2.bounces({"ticket": "zero-red-unit-suite", "pr_opened_utc": "2026-10-27T18:06Z"}), "")
        self.assertIn("Jira", s2.unreachable)
        self.assertNotIn("Jira", s.unreachable)

    def test_bounces_use_the_configured_statuses(self):
        def fetch(path, params=None):
            return {"changelog": {"total": 1, "histories": [history("2026-10-30T02:00:00.000-0700", "In QA", "Ready for Dev")]}}
        generic = mr.Sources("/r", "o/r", jira_fetch=fetch, sentry_fetch=None, run=lambda a, cwd=None: "")
        self.assertEqual(generic.bounces({"ticket": "KEY-1", "pr_opened_utc": "2026-10-27T15:17Z"}), "0")
        configured = mr.Sources("/r", "o/r", jira_fetch=fetch, sentry_fetch=None, run=lambda a, cwd=None: "", cfg=CFG)
        self.assertEqual(configured.bounces({"ticket": "KEY-1", "pr_opened_utc": "2026-10-27T15:17Z"}), "1")

    def test_incidents_is_none_until_the_pr_is_on_the_release_branch_and_none_without_sentry(self):
        def run(args, cwd=None):
            if args[:3] == ["gh", "pr", "view"]:
                return json.dumps({"state": "MERGED", "mergeCommit": {"oid": "m1"}, "files": [{"path": "app/x.py"}], "mergedAt": "2026-11-02T15:29:37Z"})
            return ""
        s = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=lambda p, q=None: [], run=run, cfg=CFG)
        self.assertIsNone(s.incidents({"pr": "1473", "pr_state": "MERGED", "ticket": "x"}))
        self.assertEqual(s.not_on_release, ["1473"])
        self.assertNotIn("Sentry", s.unreachable)
        s2 = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=None, run=run, cfg=CFG)
        self.assertIsNone(s2.incidents({"pr": "1473", "pr_state": "MERGED", "ticket": "x"}))
        self.assertIn("Sentry", s2.unreachable)

    def test_incidents_need_a_release_branch_and_an_org_in_the_config(self):
        run = lambda a, cwd=None: ""
        no_branch = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=lambda p, q=None: [], run=run,
                               cfg=mr.OutcomesConfig({"sentry": {"org": ORG}}))
        self.assertIn("release_branch", no_branch.unreachable["Sentry"])
        self.assertIsNone(no_branch.incidents({"pr": "1", "ticket": "x"}))
        no_org = mr.Sources("/r", "o/r", jira_fetch=None, sentry_fetch=lambda p, q=None: [], run=run,
                            cfg=mr.OutcomesConfig({"release_branch": "release/live"}))
        self.assertIn("sentry.org", no_org.unreachable["Sentry"])

    def test_incidents_counts_once_the_pr_is_on_the_release_branch(self):
        seen = []

        def run(args, cwd=None):
            seen.append(args)
            if args[:3] == ["gh", "pr", "view"]:
                return json.dumps({"state": "MERGED", "mergeCommit": {"oid": "m1"}, "files": [{"path": "app/x.py"}], "mergedAt": "2026-10-28T19:45:46Z"})
            if args[3] == "log":
                return "bbb 2026-10-30T11:44:11+05:30\n"
            if args[3] in ("merge-base", "rev-parse"):
                return "m1\n"
            return ""

        def fetch(path, params=None):
            if path.endswith("/issues/"):
                self.assertEqual(params.get("environment"), "live")
                return [issue(9, "WIDGETS-API-ZZ", "2026-10-31T00:00:00Z")] if f"{ORG}/widgets-api/" in path else []
            if path.endswith("/events/latest/"):
                return event("/srv/app/x.py")
            return []
        s = mr.Sources("/r", "Acme/widgets-api", jira_fetch=None, sentry_fetch=fetch, run=run, cfg=CFG)
        self.assertEqual(s.incidents({"pr": "1462", "pr_state": "MERGED", "ticket": "KEY-2263"}), "1")
        self.assertEqual(s.incident_ids["1462"], ["WIDGETS-API-ZZ"])
        self.assertIn(["git", "-C", "/r", "fetch", "-q", "origin", "release/live"], seen)


if __name__ == "__main__":
    unittest.main(verbosity=1)
