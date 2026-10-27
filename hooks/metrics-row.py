#!/usr/bin/env python3
"""Append one ticket row to <root>/.claude/metrics.csv (columns: .claude/metrics.md).

  python3 -I hooks/metrics-row.py <repo root> <branch> <pr number> \
      [--mutants RUN/SURVIVED] [--qa N] [--session-tokens N] [--note TEXT] [--dry-run]
  python3 -I hooks/metrics-row.py --refresh <repo root> [--dry-run]

The row is built from the judge packet (.claude/judge/<branch>.md: CHECKS_SHA, HEAD, ROUNDS,
SPEC_STARTED, INTERRUPTIONS), the verdict file sections (judge_fails, judge_tokens), git
(checks, correct_checks, round_date) and gh (PR state, times, approvals, comments). Mutants,
QA bounces and session tokens are typed, because nothing in the repo knows them.
--refresh re-reads gh for every row whose pr_state is OPEN and rewrites the file.
Timestamps are UTC to the minute. Blank means not captured; 0 means counted and zero.
"""
import csv
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

COLUMNS = [
    "repo", "ticket", "branch", "pr", "pr_state", "round_date",
    "checks", "rounds", "correct_checks", "mutants_run", "mutants_survived",
    "judge_fails", "qa_bounces",
    "human_approvals", "human_review_comments", "changes_requested",
    "plan_approved_utc", "packet_utc", "pushed_utc", "pr_opened_utc", "pr_merged_utc",
    "plan_to_push_min", "open_to_merge_h",
    "spec_started_utc", "session_tokens", "judge_tokens", "interruptions",
    "note",
]
FMT = "%Y-%m-%dT%H:%MZ"


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


def gh_fields(slug, pr):
    if not slug or not pr:
        return {}
    view = sh(["gh", "pr", "view", str(pr), "--repo", slug, "--json", "state,createdAt,mergedAt,author"])
    if not view.strip():
        return {}
    v = json.loads(view)
    author = v.get("author", {}).get("login", "")

    def humans(endpoint, extra=""):
        raw = sh(["gh", "api", f"repos/{slug}/{endpoint}", "--paginate"])
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


def first_token(text):
    """packet lines may carry prose after the sha: 'BASE: d9787a5a (origin/main, rebased ...)'."""
    return (text or "").split()[0] if (text or "").split() else ""


def leading_int(text):
    m = re.match(r"\s*(\d+)", text or "")
    return m.group(1) if m else ""


DEFAULT_KEY_REGEX = r"\b[A-Z]{2,}-\d+"


def key_regex(root):
    path = os.path.join(root, ".claude", "harness.json")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f).get("ticket_key_regex") or DEFAULT_KEY_REGEX
    except (OSError, ValueError):
        return DEFAULT_KEY_REGEX


def ticket_of(branch, regex=DEFAULT_KEY_REGEX):
    keys = re.findall(regex, branch)
    return "/".join(dict.fromkeys(keys)) if keys else branch


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
        "judge_fails": judge_fails, "qa_bounces": opts.get("qa", ""),
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


def append(root, row, dry):
    line = csv_line(row)
    if dry:
        print(line, end="")
        return
    path = csv_path(root)
    new = not os.path.exists(path) or os.path.getsize(path) == 0
    with open(path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        if new:
            w.writeheader()
        w.writerow(row)
    print(f"appended {row['ticket']} to {path}")


def csv_line(row):
    import io
    buf = io.StringIO()
    csv.DictWriter(buf, fieldnames=COLUMNS).writerow(row)
    return buf.getvalue()


def refresh(root, dry):
    path = csv_path(root)
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
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
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)
    print(f"rewrote {path}: {changed} row(s) refreshed")


def main(argv):
    dry = "--dry-run" in argv
    argv = [a for a in argv if a != "--dry-run"]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--refresh":
        refresh(os.path.abspath(argv[1]), dry)
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
