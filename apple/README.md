# Glasspen Meet + Glasspen Remote

Draw on your Mac screen while you share it, using the mouse **or** your iPhone/iPad.
On the phone, zoom into the exact spot first, then paint.

| App | Platform | What it does |
| --- | --- | --- |
| **Glasspen Meet** | macOS 14+ | Transparent overlay above every app. Screen-sharing tools (Zoom, Meet, Teams, OBS) capture it. Menu-bar icon plus an optional Dock icon. |
| **Glasspen Remote** | iOS/iPadOS 17+ | Live view of the Mac screen. Pinch to zoom/pan, then paint with a finger or Apple Pencil. |
| **BrushKit** | Swift package | Shared stroke model, undo/redo, renderer, wire protocol, and pairing crypto. Has unit tests. |

## Build & install

Requirements: Xcode 16+ (tested with 26.6) with the **iOS platform** installed (Xcode → Settings → Components),
`brew install xcodegen`, and your Apple ID added in Xcode → Settings → Accounts.
The signing team is set in `project.yml` (`DEVELOPMENT_TEAM`). If you build your own copy, change it to your
own team ID (Xcode → Settings → Accounts → your team), and change the bundle IDs too.

Run these from the `apple/` folder:

```sh
cd apple
make test      # BrushKit unit tests
make install   # builds Release "Glasspen Meet.app" → /Applications and opens it
make phone     # builds Glasspen Remote and installs it on the connected iPhone/iPad
```

`make phone` needs the device connected by cable (or Wi‑Fi-paired in Xcode → Devices) and unlocked.
On first install, trust the developer on the device: Settings → General → VPN & Device Management.
With a free Apple account, the phone app expires after 7 days; run `make phone` again.

The first build asks for keychain access for `codesign`. Click **Always Allow**.

## Using it

1. Open **Glasspen Meet** (Spotlight, Launchpad, or `/Applications`). A brush icon appears in the menu bar.
2. Press **⌥⌘D** to start drawing; press it again (or Esc) to click through to your apps. Drawings stay visible in both modes.
3. **Connect a phone:** choose menu bar → *Connect iPhone/iPad…*, then in Glasspen Remote either
   - tap **Scan QR Code** (the iOS Camera app works too), or
   - tap your Mac in the list. Both screens show a 6-digit code; if they are the same, tap **Codes Match** on the phone and click **Allow** on the Mac.

   The phone remembers the pairing while Glasspen Meet keeps running.
4. On the phone:
   - **Move mode** (hand icon): pinch to zoom up to 8×, drag to pan, double-tap to zoom in or fit.
   - **Paint mode** (brush icon): one finger draws; two fingers still zoom and pan. A second finger cancels the stroke in progress.
   - **Apple Pencil** always draws, in either mode, and is pressure-sensitive.
   - **Mac: draw/click** switches the Mac between draw and click-through.
   - When you stop zooming at 2× or more, the Mac sends a sharp still of that area, so small text is readable.

### Mac shortcuts (while drawing)

| Keys | Action |
| --- | --- |
| ⌥⌘D | Toggle drawing (global, configurable) |
| ⌥⌘K | Clear all (global, configurable) |
| ⌘Z / ⇧⌘Z | Undo / redo (mouse strokes; the phone has its own undo) |
| P H L A R O I F E | Pen, highlighter, line, arrow, rectangle, ellipse, phone, person, eraser |
| 1–8 | Colors |
| [ / ] | Thinner / thicker |
| Shift | Constrain shapes to square/circle, lines to 45°, figures to their natural proportions |
| Esc | Stop drawing |

Toolbar extras:

- **Position:** keep the toolbar as a bar at the bottom or as a sidebar on the left or right (toolbar position button, or menu bar → *Toolbar Position*). It is remembered between launches.

- **Phone / person figures:** drag to size them, or click to drop one at a default size.
- **Tool, color and width buttons** show the current choice; hover over one (or click it) to see all the options.
  To show every option in the toolbar instead, turn off *Compact toolbar* in Settings.
- **Toolbar background:** Settings → Toolbar → *Background* makes it see-through (0% leaves only the buttons).
- **Moving the toolbar:** drag the grip at its start, or any empty space between the buttons.
- **Ink opacity:** the slider under the colors makes new strokes more see-through (10%–100%).
- **Timer** (opens upward): new strokes fade after 1 s (the default), 3 s or 5 s. *Permanent* keeps them until cleared.
  Ink opacity and the timer choice are remembered between launches.
- **Whiteboard:** hides the apps under the overlay. The slider next to it sets how see-through it is (remembered between launches).
  The phone preview still shows the Mac screen without the board.

Settings (menu bar → Settings…): Show in Dock, hotkeys, default display.

## Permissions

- **Mac – Screen Recording:** needed only for the phone preview. Grant it in System Settings → Privacy & Security →
  Screen & System Audio Recording → Glasspen Meet. Drawing from the phone works without it.
- **Mac – Local Network / firewall:** allow incoming connections if macOS asks.
- **iPhone/iPad – Local Network:** to find the Mac. **Camera:** to scan the QR code.

## How it works

- **Single source of truth.** The Mac holds the drawing document. The overlay and the phone send intents (begin/append/end stroke, undo, …) and receive events.
- **Undo is per device.** Each device has its own undo history.
- **Coordinates.** Strokes are stored in display-normalized coordinates, with width as a fraction of display width. A stroke drawn at 6× on the phone lands exactly where you drew it, with the width you picked.
- **Phone video.** The phone gets hardware H.264 video from ScreenCaptureKit, which excludes Glasspen Meet's own windows. The phone then draws the annotations itself as vectors, so they stay sharp at any zoom.
- **Network.** Bonjour (`_paintscreen._tcp`) for discovery, with two TCP connections: control and video, so video never delays strokes.
- **Protocol.** The full wire format is in [docs/protocol.md](../docs/protocol.md).
- **Pairing.** Every connection does a fresh X25519 key exchange. A phone proves it knows the 128-bit token (from the QR code), or the user compares a 6-digit code on both screens and clicks Allow on the Mac. Every frame is then encrypted with ChaChaPoly using per-connection keys. A device gets at most 5 attempts (counted when they start) before a 30-second lockout.
