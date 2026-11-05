#!/usr/bin/env python3
"""Append one ticket row to <root>/.claude/metrics.csv (columns: docs/metrics.md).

  python3 -I hooks/metrics-row.py <repo root> <branch> <pr number> \\
      [--mutants RUN/SURVIVED] [--qa N] [--session-tokens N] [--note TEXT] [--dry-run]
  python3 -I hooks/metrics-row.py --refresh <repo root> [--dry-run]
  python3 -I hooks/metrics-row.py --outcomes <repo root> [--since YYYY-MM-DD] [--dump-dir DIR] [--dry-run]

The row is built from the judge packet (.claude/judge/<branch>.md: CHECKS_SHA, HEAD, ROUNDS,
SPEC_STARTED, INTERRUPTIONS), the verdict file sections (judge_fails, judge_tokens), git
(checks, correct_checks, round_date) and gh (PR state, times, approvals, comments). Mutants,
QA bounces and session tokens are typed, because nothing in the repo knows them.
--refresh re-reads gh for every row whose pr_state is OPEN and rewrites the file.
--outcomes fills the three defect-escape columns (qa_bounces from the Jira changelog,
human_review_comments from gh, prod_incidents from Sentry; rules in docs/metrics.md, "Outcomes") on
the rows dated --since or later (default: the config's outcomes.since, else every row) and adds the
prod_incidents column to a file that lacks it. Every other cell is written back as read. Jira needs
ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN (and ATLASSIAN_SITE or outcomes.jira.site) and Sentry needs
SENTRY_AUTH_TOKEN, read from the environment or the file outcomes.secrets_file names; --dump-dir
reads saved JSON answers instead (see docs/metrics.md). A source that cannot be reached is named at
the end and its cells are left as they were, never zeroed.
The site-specific values (tracker site and workflow statuses, Sentry org, environment and projects,
the release branch customers run) come from the `outcomes` block of .claude/harness.json.
Timestamps are UTC to the minute. Blank means not captured; 0 means counted and zero.
"""
import base64
import csv
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

COLUMNS = [
    "repo", "ticket", "branch", "pr", "pr_state", "round_date",
    "checks", "rounds", "correct_checks", "mutants_run", "mutants_survived",
    "judge_fails", "qa_bounces", "prod_incidents",
    "human_approvals", "human_review_comments", "changes_requested",
    "plan_approved_utc", "packet_utc", "pushed_utc", "pr_opened_utc", "pr_merged_utc",
    "plan_to_push_min", "open_to_merge_h",
    "spec_started_utc", "session_tokens", "judge_tokens", "interruptions",
    "note",
]
FMT = "%Y-%m-%dT%H:%MZ"
DEFAULT_KEY_REGEX = r"\b[A-Z]{2,}-\d+"

# The generic form of the bounce rule: out of review or done, back to development. A tracker whose
# workflow has more stations between review and done lists them in outcomes.jira.late_statuses.
DEFAULT_LATE_STATUSES = ["In Review", "Done"]
DEFAULT_EARLY_STATUSES = ["In Progress", "Reopened"]
DEFAULT_SENTRY_API = "https://sentry.io/api/0/"
DEFAULT_SENTRY_ENV = "production"


class Unreachable(Exception):
    """A source that did not answer: no token, no file in the dump, an HTTP error."""


def sh(args, cwd=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=False).stdout


def utc_of_file(path):
    if not os.path.exists(path):
        return ""
    return datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).strftime(FMT)


def gh_minute(s):
    if not s:
        return ""
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").strftime(FMT)


def parse_when(text):
    """Any of the timestamps the sources use, as an aware UTC datetime: '2026-10-29T23:21:06.772-0700'
    (Jira), '2026-11-02T15:49:04.805Z' (Sentry), '2026-10-30T11:44:11+05:30' (git %cI), '2026-10-27T15:17Z' (ours)."""
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?\s*(Z|[+-]\d{2}:?\d{2})?$", (text or "").strip())
    if not m:
        raise ValueError(f"not a timestamp: {text!r}")
    y, mo, d, h, mi = (int(m.group(i)) for i in range(1, 6))
    s = int(m.group(6) or 0)
    naive = datetime(y, mo, d, h, mi, s)
    off = m.group(8) or "Z"
    if off != "Z":
        sign = 1 if off[0] == "+" else -1
        digits = off[1:].replace(":", "")
        naive -= sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return naive.replace(tzinfo=timezone.utc)


def minutes(a, b):
    if not a or not b:
        return ""
    return str(int((datetime.strptime(b, FMT) - datetime.strptime(a, FMT)).total_seconds() // 60))


def hours(a, b):
    if not a or not b:
        return ""
    return f"{(datetime.strptime(b, FMT) - datetime.strptime(a, FMT)).total_seconds() / 3600:.1f}"


def repo_slug(root):
    url = sh(["git", "-C", root, "remote", "get-url", "origin"]).strip()
    m = re.search(r"[:/]([^/:]+)/([^/]+?)(\.git)?$", url)
    return (m.group(1) + "/" + m.group(2)) if m else ""


def packet_fields(root, branch):
    path = os.path.join(root, ".claude", "judge", branch + ".md")
    out = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            m = re.match(r"^([A-Z_]+):\s*(.*?)\s*$", line)
            if m:
                out.setdefault(m.group(1), m.group(2))
    return out


def verdict_fields(root, branch):
    """judge_fails = FAIL sections; judge_tokens = sum of the four counts over every Usage line."""
    path = os.path.join(root, ".claude", "judge", branch + ".verdict.md")
    if not os.path.exists(path):
        return "", ""
    text = open(path, encoding="utf-8").read()
    fails = len(re.findall(r"^VERDICT: FAIL\s*$", text, re.M))
    tokens = 0
    seen = False
    for m in re.finditer(r"^Usage: input=(\d+) cache_create=(\d+) cache_read=(\d+) output=(\d+)", text, re.M):
        seen = True
        tokens += sum(int(g) for g in m.groups())
    return str(fails), (str(tokens) if seen else "")


def git_fields(root, checks_sha, head, base):
    """checks = test functions the whole branch adds (BASE..HEAD, so Correct checks count too);
    correct_checks = commits on the branch titled 'Correct check'; round_date = the checks commit's date.
    Without a BASE line the range starts at the checks commit's parent."""
    checks_sha, head, base = (first_token(x) for x in (checks_sha, head, base))
    if not checks_sha:
        return "", "", ""
    head = head or "HEAD"
    start = base or (checks_sha + "^")
    round_date = sh(["git", "-C", root, "show", "-s", "--format=%cs", checks_sha]).strip()
    diff = sh(["git", "-C", root, "diff", start, head])
    if not diff:  # a sha the checkout does not have: say nothing rather than 0
        return round_date, "", ""
    checks = len(re.findall(r"^\+.*\bdef test_\w+", diff, re.M))
    if checks == 0:  # web repo: it('...') / test('...') blocks
        checks = len(re.findall(r"^\+\s*(?:it|test)(?:\.(?:each|skip|only)(?:\([^\n]*\))?)?\(", diff, re.M))
    titles = sh(["git", "-C", root, "log", "--format=%s", f"{start}..{head}"])
    correct = sum(1 for t in titles.splitlines() if "Correct check" in t)
    return round_date, str(checks), str(correct)


def gh_fields(slug, pr, run=sh):
    """PR state and times, plus the three human-review counts (rule: docs/metrics.md, Outcomes).
    human_review_comments = every inline review comment + every conversation comment + every review
    whose summary carries text, by anyone but the PR author or a bot; an approval with no text adds nothing."""
    if not slug or not pr:
        return {}
    view = run(["gh", "pr", "view", str(pr), "--repo", slug, "--json", "state,createdAt,mergedAt,author"])
    if not view.strip():
        return {}
    v = json.loads(view)
    author = v.get("author", {}).get("login", "")

    def humans(endpoint):
        raw = run(["gh", "api", f"repos/{slug}/{endpoint}", "--paginate"])
        try:
            items = json.loads(raw) if raw.strip().startswith("[") else []
        except json.JSONDecodeError:
            items = []
        return [i for i in items if i.get("user", {}).get("login") != author and i.get("user", {}).get("type") != "Bot"]

    reviews = humans(f"pulls/{pr}/reviews")
    inline = humans(f"pulls/{pr}/comments")
    issue = humans(f"issues/{pr}/comments")
    return {
        "pr_state": v.get("state", ""),
        "pr_opened_utc": gh_minute(v.get("createdAt") or ""),
        "pr_merged_utc": gh_minute(v.get("mergedAt") or ""),
        "human_approvals": str(sum(1 for r in reviews if r.get("state") == "APPROVED")),
        "human_review_comments": str(len(inline) + len(issue) + sum(1 for r in reviews if (r.get("body") or "").strip())),
        "changes_requested": str(sum(1 for r in reviews if r.get("state") == "CHANGES_REQUESTED")),
    }


def gh_merge(slug, pr, run=sh):
    """The PR's merge commit, merge time and changed paths, for the Sentry rule."""
    view = run(["gh", "pr", "view", str(pr), "--repo", slug, "--json", "state,mergeCommit,mergedAt,files"])
    if not view.strip():
        return {}
    v = json.loads(view)
    return {
        "state": v.get("state", ""),
        "merge_sha": (v.get("mergeCommit") or {}).get("oid", ""),
        "merged_at": v.get("mergedAt") or "",
        "files": [f.get("path", "") for f in v.get("files") or [] if f.get("path")],
    }


def first_token(text):
    """packet lines may carry prose after the sha: 'BASE: d9787a5a (origin/main, rebased ...)'."""
    return (text or "").split()[0] if (text or "").split() else ""


def leading_int(text):
    m = re.match(r"\s*(\d+)", text or "")
    return m.group(1) if m else ""


# --- configuration -----------------------------------------------------------------------------

def harness_config(root):
    """The target repo's .claude/harness.json as a dict; {} when absent or unreadable."""
    path = os.path.join(root, ".claude", "harness.json")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f) or {}
    except (OSError, ValueError):
        return {}


def key_regex(root):
    return harness_config(root).get("ticket_key_regex") or DEFAULT_KEY_REGEX


def ticket_of(branch, regex=DEFAULT_KEY_REGEX):
    keys = re.findall(regex, branch)
    return "/".join(dict.fromkeys(keys)) if keys else branch


class OutcomesConfig:
    """The `outcomes` block of .claude/harness.json (docs/how-it-works.md, Configuration). Every key is
    optional; a source whose site, org or branch is not configured is reported unreachable, never zeroed."""

    def __init__(self, data=None, key_regex=DEFAULT_KEY_REGEX):
        d = data or {}
        jira = d.get("jira") or {}
        sentry = d.get("sentry") or {}
        self.since = d.get("since") or ""
        self.secrets_file = os.path.expanduser(d.get("secrets_file") or "")
        self.release_branch = d.get("release_branch") or ""
        self.jira_site = jira.get("site") or ""
        self.late_statuses = set(jira.get("late_statuses") or DEFAULT_LATE_STATUSES)
        self.early_statuses = set(jira.get("early_statuses") or DEFAULT_EARLY_STATUSES)
        self.sentry_api = sentry.get("api") or DEFAULT_SENTRY_API
        self.sentry_org = sentry.get("org") or ""
        self.sentry_env = sentry.get("environment") or DEFAULT_SENTRY_ENV
        self.sentry_projects = list(sentry.get("projects") or [])
        self.key_regex = key_regex

    @classmethod
    def from_root(cls, root):
        cfg = harness_config(root)
        return cls(cfg.get("outcomes"), cfg.get("ticket_key_regex") or DEFAULT_KEY_REGEX)

    def projects_for(self, slug):
        """outcomes.sentry.projects, else the repo's own name."""
        return self.sentry_projects or [slug.split("/")[-1]]


# --- outcome rules ----------------------------------------------------------------------------

def count_bounces(histories, after_utc, late=DEFAULT_LATE_STATUSES, early=DEFAULT_EARLY_STATUSES):
    """Jira changelog histories -> the number of status transitions after `after_utc` that leave a
    review-or-later status (`late`) for a pre-review one (`early`). Rank changes, forward moves and
    anything before the PR opened do not count."""
    after = parse_when(after_utc)
    late, early = set(late), set(early)
    n = 0
    for h in histories:
        try:
            when = parse_when(h.get("created", ""))
        except ValueError:
            continue
        if when <= after:
            continue
        for item in h.get("items") or []:
            if item.get("field") == "status" and item.get("fromString") in late and item.get("toString") in early:
                n += 1
    return n


def jira_changelog(key, fetch):
    """Every changelog history of the issue: the embedded log when it is complete, the paged
    /changelog endpoint when Jira truncated it."""
    data = fetch(f"issue/{key}", {"expand": "changelog", "fields": "status"}) or {}
    log = data.get("changelog") or {}
    histories = log.get("histories") or []
    total = int(log.get("total") or len(histories))
    if total <= len(histories):
        return histories
    out = []
    start = 0
    while True:
        page = fetch(f"issue/{key}/changelog", {"startAt": start, "maxResults": 100}) or {}
        values = page.get("values") or []
        out.extend(values)
        if page.get("isLast", True) or not values:
            return out
        start += len(values)


def frame_hits(filename, changed):
    """A frame's filename names a changed path when the two match on whole path components from the
    right: 'app/x.py' against '/srv/app/app/x.py' either way round. A bare basename never matches."""
    f = (filename or "").strip()
    if not f:
        return False
    for p in changed:
        if f == p or f.endswith("/" + p) or ("/" in f and p.endswith("/" + f)):
            return True
    return False


def event_files(event):
    out = []
    for entry in (event or {}).get("entries") or []:
        if entry.get("type") != "exception":
            continue
        for value in (entry.get("data") or {}).get("values") or []:
            for frame in (value.get("stacktrace") or {}).get("frames") or []:
                name = frame.get("filename") or frame.get("absPath") or ""
                if name:
                    out.append(name)
    return out


def linked_keys(issue, fetch, org, regex=DEFAULT_KEY_REGEX):
    """Ticket keys Sentry links to the issue: its annotations and its external-issues list."""
    texts = [json.dumps(issue.get("annotations") or [])]
    try:
        texts.append(json.dumps(fetch(f"organizations/{org}/issues/{issue['id']}/external-issues/") or []))
    except Unreachable:
        pass
    return set(k for t in texts for k in re.findall(regex, t))


def sentry_incidents(changed, keys, since_utc, projects, fetch, org, environment=DEFAULT_SENTRY_ENV, regex=DEFAULT_KEY_REGEX):
    """(count, short ids) of issues in `environment` first seen after since_utc whose latest event has a
    frame in a changed file, or which Sentry links to one of the row's tickets."""
    since = parse_when(since_utc)
    hits = []
    for project in projects:
        issues = fetch(f"projects/{org}/{project}/issues/",
                       {"query": f"firstSeen:>{since_utc[:10]}", "environment": environment, "statsPeriod": "90d", "limit": 100}) or []
        if len(issues) >= 100:
            print(f"warning: {project} returned 100 issues; the listing may be cut")
        for issue in issues:
            try:
                if parse_when(issue.get("firstSeen", "")) <= since:
                    continue
            except ValueError:
                continue
            event = fetch(f"issues/{issue['id']}/events/latest/", {"environment": environment})
            hit = any(frame_hits(f, changed) for f in event_files(event))
            if not hit and keys:
                hit = bool(set(keys) & linked_keys(issue, fetch, org, regex))
            if hit:
                hits.append(issue.get("shortId") or str(issue["id"]))
    return len(hits), hits


def release_reached_utc(root, merge_sha, branch, run=sh, after_utc=""):
    """The committer time of the first first-parent commit on origin/<branch> (the branch customers
    run) that contains the merge commit, or '' while none does. after_utc narrows the walk to commits
    after the PR merged."""
    run(["git", "-C", root, "fetch", "-q", "origin", branch])
    args = ["git", "-C", root, "log", "--first-parent", "--reverse", "--format=%H %cI", f"origin/{branch}"]
    if after_utc:
        args.append(f"--since={after_utc}")
    full = run(["git", "-C", root, "rev-parse", merge_sha]).strip() or merge_sha
    for line in run(args).splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        sha, when = parts
        if run(["git", "-C", root, "merge-base", full, sha]).strip() == full:
            return parse_when(when).strftime(FMT)
    return ""


# --- fetchers --------------------------------------------------------------------------------

def load_env(path=""):
    """KEY=VALUE lines of the secrets file (outcomes.secrets_file), the process environment winning.
    Never printed."""
    values = {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                values[key.strip()] = value
    for key, value in os.environ.items():
        if value and (key.startswith("SENTRY_") or key.startswith("ATLASSIAN_")):
            values[key] = value
    return values


def rest_fetcher(base, headers):
    def fetch(path, params=None):
        url = base + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
        req = urllib.request.Request(url, headers=dict(headers, Accept="application/json"))
        req.add_header("User-Agent", "metrics-row/1 (stdlib urllib)")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raise Unreachable(f"{path}: HTTP {e.code}")
        except urllib.error.URLError as e:
            raise Unreachable(f"{path}: {e.reason}")
        return json.loads(raw.decode("utf-8")) if raw else None
    return fetch


def jira_fetcher(env, site=""):
    """A REST fetcher for the Jira site (ATLASSIAN_SITE in env, else outcomes.jira.site), or None
    without credentials or a site."""
    email, token = env.get("ATLASSIAN_EMAIL", ""), env.get("ATLASSIAN_API_TOKEN", "")
    site = env.get("ATLASSIAN_SITE") or site
    if not email or not token or not site:
        return None
    auth = base64.b64encode(f"{email}:{token}".encode()).decode()
    return rest_fetcher(f"https://{site}/rest/api/3/", {"Authorization": "Basic " + auth})


def sentry_fetcher(env, api=DEFAULT_SENTRY_API):
    token = env.get("SENTRY_AUTH_TOKEN", "")
    if not token:
        return None
    return rest_fetcher(api, {"Authorization": "Bearer " + token})


def dump_name(path):
    return path.strip("/").replace("/", "__") + ".json"


def dump_fetcher(directory, source):
    """Reads <directory>/<source>/<path with / as __>.json, written by a session that has the connector."""
    def fetch(path, params=None):
        file = os.path.join(directory, source, dump_name(path))
        if not os.path.exists(file):
            raise Unreachable(f"no {source}/{dump_name(path)} in {directory}")
        with open(file, encoding="utf-8") as f:
            return json.load(f)
    return fetch


class Sources:
    """The three outcome lookups for one repo. Each returns the cell as a string, or None when the source
    is unreachable (then named in .unreachable) or the row has nothing to look up yet."""

    def __init__(self, root, slug, jira_fetch, sentry_fetch, run=sh, cfg=None):
        self.root, self.slug, self.run = root, slug, run
        self.cfg = cfg or OutcomesConfig()
        self.jira_fetch, self.sentry_fetch = jira_fetch, sentry_fetch
        self.unreachable = {}
        self.incident_ids = {}
        self.not_on_release = []
        where = f"in {self.cfg.secrets_file} or the environment" if self.cfg.secrets_file else "in the environment"
        if jira_fetch is None:
            self.unreachable["Jira"] = f"no ATLASSIAN_EMAIL/ATLASSIAN_API_TOKEN {where} (or no Jira site), no --dump-dir"
        if sentry_fetch is None:
            self.unreachable["Sentry"] = f"no SENTRY_AUTH_TOKEN {where}, no --dump-dir"
        elif not self.cfg.release_branch:
            self.unreachable["Sentry"] = "no outcomes.release_branch in the config, so when a PR reached customers is unknown"
        elif not self.cfg.sentry_org:
            self.unreachable["Sentry"] = "no outcomes.sentry.org in the config"
        self.sentry_ready = "Sentry" not in self.unreachable

    def review(self, row):
        if not row.get("pr"):
            return None
        gh = gh_fields(self.slug, row["pr"], self.run)
        if not gh:
            self.unreachable["GitHub"] = f"gh pr view {row['pr']} answered nothing"
            return None
        return gh["human_review_comments"]

    def bounces(self, row):
        keys = re.findall(self.cfg.key_regex, row.get("ticket") or "")
        if not keys:
            return ""  # no ticket to bounce: blank, whatever was typed before
        if not row.get("pr_opened_utc") or self.jira_fetch is None:
            return None
        total = 0
        for key in keys:
            try:
                total += count_bounces(jira_changelog(key, self.jira_fetch), row["pr_opened_utc"],
                                       self.cfg.late_statuses, self.cfg.early_statuses)
            except Unreachable as e:
                self.unreachable["Jira"] = str(e)
                return None
        return str(total)

    def incidents(self, row):
        if not row.get("pr") or not self.sentry_ready:
            return None
        merge = gh_merge(self.slug, row["pr"], self.run)
        if merge.get("state") != "MERGED" or not merge.get("merge_sha"):
            return None
        reached = release_reached_utc(self.root, merge["merge_sha"], self.cfg.release_branch, self.run, merge.get("merged_at", ""))
        if not reached:
            self.not_on_release.append(row["pr"])
            return None
        keys = re.findall(self.cfg.key_regex, row.get("ticket") or "")
        try:
            n, ids = sentry_incidents(merge["files"], keys, reached, self.cfg.projects_for(self.slug), self.sentry_fetch,
                                      self.cfg.sentry_org, self.cfg.sentry_env, self.cfg.key_regex)
        except Unreachable as e:
            self.unreachable["Sentry"] = str(e)
            return None
        self.incident_ids[row["pr"]] = ids
        return str(n)


# --- rows -----------------------------------------------------------------------------------

def build_row(root, branch, pr, opts):
    slug = repo_slug(root)
    pk = packet_fields(root, branch)
    judge_fails, judge_tokens = verdict_fields(root, branch)
    round_date, checks, correct = git_fields(root, pk.get("CHECKS_SHA", ""), pk.get("HEAD", ""), pk.get("BASE", ""))
    gh = gh_fields(slug, pr)
    jd = os.path.join(root, ".claude", "judge")
    plan = utc_of_file(os.path.join(jd, branch + ".plan.md"))
    packet = utc_of_file(os.path.join(jd, branch + ".md"))
    pushed = utc_of_file(os.path.join(jd, branch + ".verdict.md"))
    mut_run, mut_surv = "", ""
    if opts.get("mutants"):
        mut_run, mut_surv = opts["mutants"].split("/", 1)
    row = {
        "repo": slug.split("/")[-1] if slug else os.path.basename(root),
        "ticket": ticket_of(branch, key_regex(root)), "branch": branch, "pr": str(pr) if pr else "",
        "pr_state": gh.get("pr_state", ""), "round_date": round_date,
        "checks": checks, "rounds": leading_int(pk.get("ROUNDS", "")), "correct_checks": correct,
        "mutants_run": mut_run, "mutants_survived": mut_surv,
        "judge_fails": judge_fails, "qa_bounces": opts.get("qa", ""), "prod_incidents": "",
        "human_approvals": gh.get("human_approvals", ""),
        "human_review_comments": gh.get("human_review_comments", ""),
        "changes_requested": gh.get("changes_requested", ""),
        "plan_approved_utc": plan, "packet_utc": packet, "pushed_utc": pushed,
        "pr_opened_utc": gh.get("pr_opened_utc", ""), "pr_merged_utc": gh.get("pr_merged_utc", ""),
        "plan_to_push_min": minutes(plan, pushed),
        "open_to_merge_h": hours(gh.get("pr_opened_utc", ""), gh.get("pr_merged_utc", "")),
        "spec_started_utc": pk.get("SPEC_STARTED", ""),
        "session_tokens": opts.get("session_tokens", ""),
        "judge_tokens": judge_tokens,
        "interruptions": pk.get("INTERRUPTIONS", ""),
        "note": opts.get("note", ""),
    }
    return row


def csv_path(root):
    return os.path.join(root, ".claude", "metrics.csv")


def read_rows(root):
    """Every row, with columns the file predates (prod_incidents) present and blank."""
    with open(csv_path(root), encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for col in COLUMNS:
            r.setdefault(col, "")
    return rows


def write_rows(root, rows):
    with open(csv_path(root), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)


def append(root, row, dry):
    line = csv_line(row)
    if dry:
        print(line, end="")
        return
    path = csv_path(root)
    new = not os.path.exists(path) or os.path.getsize(path) == 0
    if new:
        with open(path, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=COLUMNS)
            w.writeheader()
            w.writerow(row)
    else:
        rows = read_rows(root)
        rows.append(row)
        write_rows(root, rows)
    print(f"appended {row['ticket']} to {path}")


def csv_line(row):
    import io
    buf = io.StringIO()
    csv.DictWriter(buf, fieldnames=COLUMNS).writerow(row)
    return buf.getvalue()


def refresh(root, dry):
    path = csv_path(root)
    rows = read_rows(root)
    slug = repo_slug(root)
    changed = 0
    for r in rows:
        if r.get("pr_state") != "OPEN" or not r.get("pr"):
            continue
        gh = gh_fields(slug, r["pr"])
        if not gh:
            continue
        before = dict(r)
        r.update(gh)
        r["open_to_merge_h"] = hours(r["pr_opened_utc"], r["pr_merged_utc"])
        if r != before:
            changed += 1
            print(f"refreshed {r['ticket']} (PR {r['pr']}): {r['pr_state']}")
    if dry or not changed:
        print(f"{changed} row(s) would change" if dry else "nothing to refresh")
        return
    write_rows(root, rows)
    print(f"rewrote {path}: {changed} row(s) refreshed")


OUTCOME_CELLS = (("qa_bounces", "bounces"), ("human_review_comments", "review"), ("prod_incidents", "incidents"))


def outcomes(root, since, sources, dry):
    """Fill the three outcome columns on rows dated `since` or later; leave every other cell as read."""
    path = csv_path(root)
    rows = read_rows(root)
    touched = 0
    for r in rows:
        if (r.get("round_date") or "") < since:
            continue
        touched += 1
        filled = []
        for col, method in OUTCOME_CELLS:
            if method != "bounces" and not r.get("pr"):
                continue  # nothing on GitHub or Sentry to look up
            value = getattr(sources, method)(r)
            if value is not None:
                r[col] = value
                filled.append(col)
        shown = " ".join(f"{col}={r.get(col) or 'blank'}" for col, _ in OUTCOME_CELLS)
        ids = getattr(sources, "incident_ids", {}).get(r.get("pr"), [])
        tail = f" [{', '.join(ids)}]" if ids else ""
        kept = [col for col, _ in OUTCOME_CELLS if col not in filled]
        print(f"{r.get('ticket')} (PR {r.get('pr') or '-'}): {shown}{tail}" + (f"  (kept: {', '.join(kept)})" if kept else ""))
    for name, reason in getattr(sources, "unreachable", {}).items():
        print(f"{name} unreachable ({reason}): its cells were left as they were")
    not_on_release = getattr(sources, "not_on_release", [])
    if not_on_release:
        branch = getattr(getattr(sources, "cfg", None), "release_branch", "") or "the release branch"
        print(f"not on {branch} yet, prod_incidents left blank: PR {', '.join(not_on_release)}")
    if dry:
        print(f"dry run: {touched} row(s) since {since or 'the first'} would be written to {path}")
        return
    write_rows(root, rows)
    print(f"rewrote {path}: {touched} row(s) since {since or 'the first'}")


def main(argv):
    dry = "--dry-run" in argv
    argv = [a for a in argv if a != "--dry-run"]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--refresh":
        refresh(os.path.abspath(argv[1]), dry)
        return 0
    if argv[0] == "--outcomes":
        root = os.path.abspath(argv[1])
        opts = dict(zip([a.lstrip("-").replace("-", "_") for a in argv[2::2]], argv[3::2]))
        cfg = OutcomesConfig.from_root(root)
        env = load_env(cfg.secrets_file)
        if opts.get("dump_dir"):
            jira, sentry = dump_fetcher(opts["dump_dir"], "jira"), dump_fetcher(opts["dump_dir"], "sentry")
        else:
            jira, sentry = jira_fetcher(env, cfg.jira_site), sentry_fetcher(env, cfg.sentry_api)
        outcomes(root, opts.get("since", cfg.since), Sources(root, repo_slug(root), jira, sentry, cfg=cfg), dry)
        return 0
    if len(argv) < 2:
        print(__doc__)
        return 2
    root = os.path.abspath(argv[0])
    branch = argv[1]
    pr = argv[2] if len(argv) > 2 and not argv[2].startswith("--") else ""
    rest = argv[3:] if pr else argv[2:]
    opts = {}
    i = 0
    while i < len(rest):
        key = rest[i].lstrip("-").replace("-", "_")
        val = rest[i + 1] if i + 1 < len(rest) else ""
        opts[key] = val
        i += 2
    append(root, build_row(root, branch, pr, opts), dry)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
