# Tattletail

*It watches. It remembers. It tells.*

Tattletail is a macOS app that records your mouse movements, clicks, scrolls,
and keystrokes — then replays them on command. Hit **Record**, do your thing,
hit **Stop**, and it's on the record: replay it instantly, after a countdown, or
on a schedule.

This is the **free edition** — a genuinely useful record-and-replay tool, given
away and open source. The [paid edition](#tattletail-io) adds the power-user
features (see below).

## Features

- **Faithful recording** — full cursor paths with real timing, every click and
  drag, scrolling, and typing with modifiers
- **App-aware replay** — remembers which app you were using and brings it back
  to the front (launching it if needed) so replays land where they should
- **Window-relative positioning** — records where each click lands *inside its
  window*, so replays follow the window when it moves or resizes and adapt across
  different screen setups; falls back to screen coordinates when the window isn't
  found, and can be turned off in Settings to use plain absolute coordinates
- **Type & Paste Text steps** — drop in text that gets typed (or pasted) on
  replay, editable right in the timeline
- **A timeline you can shape** — name, duplicate, group, and multi-select steps;
  reorder and fine-tune every event, with full undo/redo
- **Flexible playback** — ¼× to 4× speed, repeat N times, or loop until stopped
- **Instant or countdown replay** — go now, or "run in 10 seconds" so you can
  get your hands off the keyboard first
- **Scheduling** — "run Tuesday at 9:15" with optional hourly/daily/weekly
  repeats, set from the *Schedule a Replay* window, a recording's detail view, or
  the menu bar; scheduled recordings are flagged with a badge in the library, and
  Tattletail fires them while it's running
- **Run counts** — every recording keeps its own tally of how many times it's
  been replayed, including a lifetime total that survives resets
- **Configurable hotkeys** — bind the actions you use most to keys that suit you
- **Unlimited recordings** — keep as many as you like
- **Panic stop** — ⌥⌘. instantly halts any replay, from anywhere
- **Universal** — native on both Apple Silicon and Intel Macs

## Requirements

macOS 26 or later. Tattletail needs two permissions to do its job —
**Accessibility** (to replay) and **Input Monitoring** (to record). It asks
nicely on first launch and never phones home; recordings live only in
`~/Library/Application Support/Tattletail/`.

<a id="tattletail-io"></a>
## Want more? Get the paid edition

The paid edition of Tattletail lives at **[tattletail.io](https://tattletail.io)**.
It's the same app — same recordings, same permissions — with the power-user
features added on. Buy it and it installs right over this one, keeping your
existing recordings and your Accessibility / Input Monitoring grants intact.

The paid edition adds:

- **Scheduled tab** — a central pane that lists every schedule across your
  library, soonest first, to edit, pause, or delete any of them at a glance
- **Run History** — a log of every replay: when it ran, how it started, how many
  passes it made, and whether it finished
- **Jump to clicks** — skip the cursor travel and snap straight from click to
  click
- **Natural timing** — humanize replays with subtle, lifelike variation
- **Import / Export** — move recordings between Macs or share them
- **Folders** — organize your library into groups

## Building

With Xcode:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Tattletail.xcodeproj -scheme TattletailFree build
```

With just Command Line Tools:

```sh
Scripts/dev-build.sh --free
open build/dev/Tattletail.app
```

## A note on secure fields

macOS blocks *all* apps from seeing keystrokes typed into password fields.
Tattletail detects this and warns you during recording — those keystrokes
simply can't be captured, by design of the OS.

## License

Tattletail is open source under the [MIT License](LICENSE).
