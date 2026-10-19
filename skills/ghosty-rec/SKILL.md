---
name: ghosty-rec
description: Record a single macOS window from the terminal with `rec` (never the full screen), mark what you are doing while it records, and render a Screen Studio–style video with spring zooms, smoothed cursor, background and captions that type themselves. Use when the user asks to record a demo, a screencast, a short, a bug repro or evidence of a change on macOS, or mentions rec, ghosty-rec or Screen Studio.
license: MIT
compatibility: macOS 15+, Homebrew and the Xcode Command Line Tools. The terminal running rec needs the Screen Recording permission.
metadata:
  author: blissito
  version: "0.6.4"
---

# Record one window with `rec`

`rec` records ONE window even if another window covers it, so nothing else on the screen leaks
into the video (chats, notifications, other apps). Piped or with `--json` it prints JSON; in a
terminal it prints one readable line.

## Install

```sh
brew install blissito/tap/ghosty-rec   # command: rec (conflicts with sox's rec)
rec --version
```

Exit code 3 means the terminal lacks **Screen Recording** permission: tell the user to turn it on
in System Settings → Privacy & Security → Screen & System Audio Recording for their terminal app,
then restart the terminal.

## Record

```sh
rec windows --json                         # pick the window: use its numeric id
rec start --id <ID> --out ~/footage/demo.mov
rec mark "types the command" --rect 0,40,520,60 --say "One command connects the repo"
rec mark "clicks Merge" --rect 300,400,120,40 --zoom 1.5 --hold 3 --at +1
rec stop
```

- Always use `--id`. Window titles change (browser tabs, running processes) and text matching can
  grab the wrong window.
- `--rect x,y,w,h` is in points, relative to the window's top-left corner. Each mark becomes a
  zoom to that box; the box is always kept fully visible.
- `--say` is the caption that types itself word by word under the box. Keep it short and concrete.
- `--at +1.5` shifts the mark in time (put it where the result is already on screen).
- Only ONE recording per Mac at a time. If another agent may be recording, check `rec status` first.

## Render

```sh
rec render ~/footage/demo.mov --aspect 16:9 --no-titlebar   # or 9:16, 1:1
```

- Look: `--bg macos:Sonoma|sunset|midnight|ocean|candy|mint|forest|grape|paper|ink|photo.jpg|#hex,#hex`
  (`macos:<name>` uses a wallpaper already installed on this Mac), `--cursor-size 3` (multiple of the
  macOS cursor), `--click ring`, `--shadow 0.75`, `--motion-blur` (cursor only, off by default).
- `--trim-idle 1.5` cuts waits (long installs, builds): stretches where neither the window nor the
  cursor changes are shortened to 1.5 s. `--shadow-style hard` gives a flat cartoon shadow.
- Without marks it zooms automatically on each group of clicks (`--no-auto-zoom` turns it off).
- Writes `demo.16x9.mp4` (1920×1080, 60 fps) and `demo.project.json`. To drop a zoom set its
  `"enabled": false` in the JSON and render again; `--reset` rebuilds it from the marks.
- Read the JSON output: `zoomLimits` says which zoom could not grow (content fills the width) and
  `warning` says when text would be upscaled and blurry. Never stretched beyond 1.5× (`--max-upscale`).
- For vertical videos record a narrow window with a large font (18–40 pt): wide lines cannot zoom.
- Verify the delivered file: `ffprobe -show_entries stream=start_time` must be 0 and frame 0 must
  show the window.
