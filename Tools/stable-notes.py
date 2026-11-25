#!/usr/bin/env python3
"""Draft the stable changelog for promoting a beta, from the betas' own entries.

    python3 Tools/stable-notes.py                  # print the draft notes
    python3 Tools/stable-notes.py --out notes.md   # write them for promote-beta.sh
    python3 Tools/stable-notes.py --apply          # also add the stable section to CHANGELOG.md
    python3 Tools/stable-notes.py --self-test

How it finds "everything since the last stable": CHANGELOG.md lists releases
newest first. Every "## X.Y.Z (beta)" section above the first section without
"(beta)" (the last stable release) is included. The newest beta's version is
the version being promoted (promotion re-labels the same package).

What it does with them:
- merges the subsections of all those betas under one heading each, in a
  fixed order ("Changes that may affect your setup" first), newest beta first;
- folds similar headings together ("New" into "What's new", "Fixed" into
  "What's fixed", "For testers" into "Release notes");
- drops lines that only make sense in a beta ("It contains everything in
  0.9.1", "Betas may have bugs", "if you rely on your setup, stay on Stable");
- says "This release" where a beta said "This beta";
- keeps each beta's opening paragraph in an HTML comment at the top, to help
  write the stable introduction by hand.

It also prints, to stderr, the commits on main since the last stable tag
that are not feed-only ("Appcast:"), because a stable fix that landed on main
while the betas ran has no beta section. Check each one is covered.

The output is a draft: read it, edit it, then pass it to
Tools/promote-beta.sh --notes. --apply puts the same text into CHANGELOG.md as
"## <version>" above the beta sections, which stay below as history.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ORDER = [
    "Changes that may affect your setup",
    "What's new",
    "What's fixed",
    "What's better",
    "Release notes",
]
ALIASES = {
    "new": "What's new",
    "what's new": "What's new",
    "fixed": "What's fixed",
    "what's fixed": "What's fixed",
    "what's better": "What's better",
    "release notes": "Release notes",
    "for testers": "Release notes",
    "changes that may affect your setup": "Changes that may affect your setup",
}
BETA_ONLY = [
    re.compile(r"\bIt contains everything in \d+\.\d+\.\d+\.?"),
    re.compile(r"\bBetas may have bugs[^.]*\.?"),
    re.compile(r"[;,]?\s*if you rely on your setup, stay on Stable\.?", re.I),
]
HEADING = re.compile(r"^## (\d+\.\d+\.\d+)(.*)$")


def parse(text):
    """Return [(version, is_beta, intro_lines, [(subheading, lines)])], newest first."""
    releases = []
    cur = None
    sub = None
    for line in text.splitlines():
        m = HEADING.match(line)
        if m:
            cur = {"version": m.group(1), "beta": "(beta)" in m.group(2),
                   "intro": [], "subs": []}
            releases.append(cur)
            sub = None
            continue
        if cur is None:
            continue
        if line.startswith("### "):
            sub = (line[4:].strip(), [])
            cur["subs"].append(sub)
        elif sub is not None:
            sub[1].append(line)
        else:
            cur["intro"].append(line)
    return releases


def clean(line):
    for pat in BETA_ONLY:
        line = pat.sub("", line)
    line = line.replace("This beta ", "This release ")
    return line.rstrip()


def blocks(lines):
    """Split a subsection into items: bullets (with their continuation lines) or paragraphs."""
    items, cur = [], []
    for line in lines:
        if line.startswith("- ") or not line.strip():
            if cur:
                items.append(cur)
            cur = [line] if line.strip() else []
        else:
            cur.append(line)
    if cur:
        items.append(cur)
    return ["\n".join(clean(l) for l in item).strip() for item in items if any(l.strip() for l in item)]


def draft(text):
    releases = parse(text)
    betas = []
    for r in releases:
        if not r["beta"]:
            stable = r["version"]
            break
        betas.append(r)
    else:
        raise SystemExit("no stable section found in the changelog")
    if not betas:
        raise SystemExit(f"no beta sections above the last stable ({stable}); nothing to promote")

    merged, extra = {}, []
    for r in betas:
        for name, lines in r["subs"]:
            key = ALIASES.get(name.lower(), name)
            if key not in merged:
                merged[key] = []
                if key not in ORDER:
                    extra.append(key)
            for item in blocks(lines):
                if item and item not in merged[key]:
                    merged[key].append(item)

    out = ["<!-- Draft from the beta sections " + ", ".join(r["version"] for r in betas)
           + f" (since stable {stable}). Write the introduction from these, then delete this comment:"]
    for r in betas:
        intro = " ".join(clean(l) for l in r["intro"] if l.strip()).strip()
        if intro:
            out.append(f"{r['version']}: {intro}")
    out.append("-->")
    out.append("")
    for key in ORDER + extra:
        if merged.get(key):
            out.append(f"### {key}")
            out.append("")
            out.extend(merged[key])
            out.append("")
    return betas[0]["version"], stable, "\n".join(out).rstrip() + "\n"


def main_only_commits(stable, main_ref):
    try:
        log = subprocess.run(
            ["git", "log", "--no-merges", "--format=%h %s", f"v{stable}..{main_ref}"],
            capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        return None, str(e)
    return [l for l in log.splitlines() if l and not l.split(" ", 1)[1].startswith("Appcast:")], None


def apply(changelog, version, notes):
    text = changelog.read_text()
    if re.search(rf"^## {re.escape(version)}\s*$", text, re.M):
        raise SystemExit(f"CHANGELOG.md already has a stable ## {version} section")
    body = re.sub(r"<!--.*?-->\n*", "", notes, flags=re.S)
    section = f"## {version}\n\nINTRODUCTION: write one or two sentences.\n\n{body}\n"
    first = re.search(r"^## ", text, re.M)
    changelog.write_text(text[:first.start()] + section + text[first.start():])


SAMPLE = """# Changelog

## 0.9.2 (beta)

Mixer fixes. It contains everything in 0.9.1.

### Changes that may affect your setup

- **This beta updates nothing.** Second line
  continues here.

### What's fixed

- Fix B.

## 0.9.1 (beta)

The first beta. Betas may have bugs; if you rely on your setup, stay on Stable.

### Changes that may affect your setup

- **This beta updates the driver.**

### New

- Feature A.

### For testers

- Tell us.

## 0.8.40

### What's fixed

- Old.
"""


def self_test():
    version, stable, notes = draft(SAMPLE)
    assert (version, stable) == ("0.9.2", "0.8.40"), (version, stable)
    body = notes.split("-->", 1)[1]
    assert body.index("### Changes that may affect your setup") < body.index("### What's new") \
        < body.index("### What's fixed") < body.index("### Release notes"), body
    assert "This release updates nothing.** Second line\n  continues here." in body, body
    assert "This release updates the driver." in body and "This beta" not in body, body
    assert "- Feature A." in body and "- Tell us." in body and "- Old." not in body, body
    assert "contains everything" not in notes and "Betas may have bugs" not in notes, notes
    assert "stay on Stable" not in notes, notes
    assert body.index("updates nothing") < body.index("updates the driver"), "newest beta first"
    print("stable-notes self-test: ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changelog", default="CHANGELOG.md")
    ap.add_argument("--out")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--main-ref", default="origin/main")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return
    changelog = Path(a.changelog)
    version, stable, notes = draft(changelog.read_text())
    if a.out:
        Path(a.out).write_text(notes)
        print(f"wrote {a.out}", file=sys.stderr)
    else:
        sys.stdout.write(notes)
    print(f"\nPromoting {version}: everything since stable {stable}.", file=sys.stderr)
    commits, err = main_only_commits(stable, a.main_ref)
    if commits is None:
        print(f"Could not list main's commits since v{stable}: {err}", file=sys.stderr)
    elif commits:
        print(f"Commits on {a.main_ref} since v{stable} (not feed-only); check each is in the notes:",
              file=sys.stderr)
        for c in commits:
            print("  " + c, file=sys.stderr)
    else:
        print(f"No commits on {a.main_ref} since v{stable} besides feed items.", file=sys.stderr)
    if a.apply:
        apply(changelog, version, notes)
        print(f"Added ## {version} to {changelog}; write its introduction.", file=sys.stderr)


if __name__ == "__main__":
    main()
