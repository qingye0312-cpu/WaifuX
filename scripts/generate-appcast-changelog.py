#!/usr/bin/env python3
"""Generate release notes from git commits (subject + body → list items).

Used by:
  - scripts/bump-version-patch.sh
  - scripts/githooks/pre-commit
  - .github/workflows/release.yml

Usage:
  python3 scripts/generate-appcast-changelog.py [--since TAG] [--format html|markdown] [--limit N]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from html import escape
from typing import Iterable, List, Optional, Tuple


# Version-bump / meta commits that shouldn't appear in user-facing notes.
SKIP_SUBJECT_RE = re.compile(
    r"^(?:"
    r"(?:feat|chore)\s*:\s*更新版本至\b"
    r"|chore\s*:\s*bump version\b"
    r"|chore\s*:\s*update appcast\b"
    r"|githooks?\s*:"
    r")",
    re.IGNORECASE,
)

# Trailers / noise in commit bodies.
SKIP_BODY_LINE_RE = re.compile(
    r"^(?:"
    r"co-authored-by:"
    r"|signed-off-by:"
    r"|made-with:"
    r"|change-id:"
    r"|reviewed-by:"
    r"|#\s*----+"
    r"|---+$"
    r")",
    re.IGNORECASE,
)

# Leading list / section markers in body lines.
BODY_MARKER_RE = re.compile(
    r"^\s*(?:"
    r"[-*•]\s+"
    r"|\d+[\.、)]\s+"
    r"|[①-⑳]\s*"
    r"|⚙️\s*"
    r")+"
)


def run_git(args: List[str]) -> str:
    result = subprocess.run(
        ["git", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    return result.stdout


def resolve_since(explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    # Prefer parent of HEAD so the range is previous-tag..HEAD (matches CI).
    tag = run_git(["describe", "--tags", "--abbrev=0", "HEAD^"]).strip()
    if tag:
        return tag
    return run_git(["describe", "--tags", "--abbrev=0", "HEAD"]).strip()


def fetch_commits(since: str, limit: int) -> List[Tuple[str, str, str]]:
    """Return list of (short_hash, subject, body)."""
    range_spec = f"{since}..HEAD" if since else "HEAD"
    # Record separator = \x1e, field separator = \x1f
    pretty = "%h%x1f%s%x1f%b%x1e"
    raw = run_git(
        [
            "log",
            range_spec,
            f"--pretty=format:{pretty}",
            "--no-merges",
            f"-n{limit}",
        ]
    )
    commits: List[Tuple[str, str, str]] = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record.strip():
            continue
        parts = record.split("\x1f", 2)
        if len(parts) < 2:
            continue
        short = parts[0].strip()
        subject = parts[1].strip()
        body = parts[2] if len(parts) > 2 else ""
        commits.append((short, subject, body))
    return commits


def body_lines(body: str) -> List[str]:
    lines: List[str] = []
    for raw in body.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if SKIP_BODY_LINE_RE.match(line.strip()):
            continue
        cleaned = BODY_MARKER_RE.sub("", line).strip()
        if not cleaned:
            continue
        # Drop ultra-short decorative lines
        if cleaned in {"⚙️", "•", "-", "*"}:
            continue
        lines.append(cleaned)
    return lines


def should_skip_subject(subject: str) -> bool:
    return bool(SKIP_SUBJECT_RE.match(subject.strip()))


def collect_entries(commits: Iterable[Tuple[str, str, str]]) -> List[Tuple[str, List[str]]]:
    """Each entry: (title, detail_lines). Title already includes hash suffix when useful."""
    entries: List[Tuple[str, List[str]]] = []
    for short, subject, body in commits:
        if not subject or should_skip_subject(subject):
            continue
        details = body_lines(body)
        # Keep hash only on the title row for traceability
        title = f"{subject} ({short})" if short else subject
        entries.append((title, details))
    return entries


def to_markdown(entries: List[Tuple[str, List[str]]]) -> str:
    if not entries:
        return "- Initial release"
    out: List[str] = []
    for title, details in entries:
        out.append(f"- {title}")
        for d in details:
            out.append(f"  - {d}")
    return "\n".join(out)


def to_html(entries: List[Tuple[str, List[str]]], version: Optional[str] = None) -> str:
    if not entries:
        body = "<p>Initial release</p>"
    else:
        items: List[str] = []
        for title, details in entries:
            title_html = escape(title)
            if details:
                nested = "".join(f"<li>{escape(d)}</li>" for d in details)
                items.append(
                    f"<li><strong>{title_html}</strong><ul>{nested}</ul></li>"
                )
            else:
                items.append(f"<li>{title_html}</li>")
        body = f"<ul>{''.join(items)}</ul>"

    if version:
        return f"<h3>WaifuX {escape(version)}</h3>{body}"
    return body


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", default="", help="Git ref for lower bound (exclusive)")
    parser.add_argument(
        "--format",
        choices=("html", "markdown", "md"),
        default="markdown",
        help="Output format",
    )
    parser.add_argument("--limit", type=int, default=30, help="Max commits to include")
    parser.add_argument(
        "--version",
        default="",
        help="When format=html, wrap with <h3>WaifuX VERSION</h3>",
    )
    parser.add_argument(
        "--items-only",
        action="store_true",
        help="With format=html, emit only <li>…</li> rows (no outer ul/h3)",
    )
    args = parser.parse_args()

    since = resolve_since(args.since or None)
    commits = fetch_commits(since, args.limit)
    entries = collect_entries(commits)

    fmt = "markdown" if args.format == "md" else args.format
    if fmt == "markdown":
        sys.stdout.write(to_markdown(entries))
    else:
        if args.items_only:
            # Flat <li> stream for callers that already wrap <ul>
            chunks: List[str] = []
            for title, details in entries:
                title_html = escape(title)
                if details:
                    nested = "".join(f"<li>{escape(d)}</li>" for d in details)
                    chunks.append(
                        f"<li><strong>{title_html}</strong><ul>{nested}</ul></li>"
                    )
                else:
                    chunks.append(f"<li>{title_html}</li>")
            if not chunks:
                chunks.append("<li>Initial release</li>")
            sys.stdout.write("\n".join(chunks))
        else:
            sys.stdout.write(to_html(entries, args.version or None))
    if sys.stdout.isatty():
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
