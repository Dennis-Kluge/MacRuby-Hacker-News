# Changelog

## 1.1

**Saving and exporting.** ⌘D keeps the story you are reading, and a Saved
section sits beside Hacker News's own on ⌘7, answered from disk rather than
the API. What is kept is the whole story, not a reference to it. Export the
lot as Markdown, JSON, OPML or a bookmarks file Safari, Chrome and Firefox
all import — and read a JSON export back in, merging rather than replacing.

**Search.** ⌘F narrows whichever section is showing, with a sort and a date
range in a bar that appears only while you are searching. Sorting by date
asks precisely, because nothing downstream will rank a bad match down;
sorting by relevance stays forgiving.

**The linked page, in a third column.** ⌃⌘3 and the window becomes stories,
the page they link to, and the comments. Off by default. Three columns need
room for three, so below that the article gives way rather than the window
refusing to shrink.

**The title bar carries controls and nothing else.** In a unified toolbar
the title sits beside them and was the widest thing in the row; the status
line moved under the story list, where it is no longer truncated. The
toolbar is customisable and remembers its arrangement.

**Fixed**

- The status bar hairline was invisible in dark mode: a `CGColor` resolves a
  dynamic colour once and keeps that value.
- The preferences window clipped its last rows — it was laid out to fit, but
  only ever shrank.
- The reader treated a cancelled load as a failure, so following a link
  before the previous page arrived put an error in its subtitle.
- Story ages now read in years and months rather than "4,800 days ago".

**Under it**

- The reader window and the article column share one `WebView` instead of a
  web view and a navigation delegate each.
- Tests split into eight files by subject, none of which writes to the
  preferences the reader is actually using.
- Tests run on every push, on Apple Silicon.

## 1.0

A Hacker News reader for macOS written in Ruby: stories, comments, sections,
endless scrolling, site icons, a built-in reader, reading history, and a
`.app` bundle with an icon drawn rather than shipped.
