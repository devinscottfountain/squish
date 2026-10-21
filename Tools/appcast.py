#!/usr/bin/env python3
"""Adds one release to Squish's Sparkle appcast (appcast.xml), newest first.

Called by release.sh after the DMG is built and signed:
    appcast.py appcast.xml --version 0.3.0 --build 4 --notes notes.md \
        --signature 'sparkle:edSignature="…" length="…"' --url https://…/Squish-0.3.0.dmg

The notes file is a little Markdown: "- " bullets, **bold**, `code` and plain paragraphs.
"""
import argparse
import html
import re
from email.utils import formatdate
from pathlib import Path

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Squish</title>
    <link>https://github.com/devinscottfountain/squish</link>
    <description>Updates for Squish</description>
    <language>en</language>
<!-- items -->
  </channel>
</rss>
"""
MARKER = "<!-- items -->"


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)


def notes_html(markdown: str) -> str:
    out, bullets = [], []

    def flush():
        if bullets:
            out.append("<ul>" + "".join(f"<li>{b}</li>" for b in bullets) + "</ul>")
            bullets.clear()

    for line in markdown.splitlines():
        line = line.strip()
        if line.startswith(("- ", "* ")):
            bullets.append(inline(line[2:]))
            continue
        flush()
        if line.startswith("#"):
            out.append(f"<h3>{inline(line.lstrip('#').strip())}</h3>")
        elif line:
            out.append(f"<p>{inline(line)}</p>")
    flush()
    return "\n".join(out)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--signature", required=True, help="sign_update's output")
    parser.add_argument("--url", required=True)
    args = parser.parse_args()

    feed = args.appcast.read_text() if args.appcast.exists() else HEADER
    if f"<sparkle:version>{args.build}</sparkle:version>" in feed:
        raise SystemExit(f"appcast.xml already has build {args.build}. Bump CURRENT_PROJECT_VERSION.")

    item = f"""    <item>
      <title>Version {args.version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/devinscottfountain/squish/releases/tag/v{args.version}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
{notes_html(args.notes.read_text())}
      ]]></description>
      <enclosure url="{args.url}" type="application/octet-stream" {args.signature.strip()} />
    </item>
"""
    args.appcast.write_text(feed.replace(MARKER + "\n", MARKER + "\n" + item, 1))
    print(f"  Added {args.version} ({args.build}) to {args.appcast.name}")


if __name__ == "__main__":
    main()
