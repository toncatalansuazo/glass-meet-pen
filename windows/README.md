# Glasspen Meet for Windows

Draw on your Windows screen while you share it in a call, with the mouse, a pen, or the iPhone/iPad
app **Glasspen Remote** (the same phone app as the Mac version).

> **Status:** the code compiles (0 warnings) and the shared core passes its tests, including messages
> made by the Swift app and a live pairing with the real Swift client. The app itself has **not been
> run on Windows yet**: please try the checklist at the end on your PC.

## Build the `.exe` (on Windows 10 1809 or later / Windows 11)

1. Install the **.NET 8 SDK** and **Git**, for example in PowerShell:

   ```powershell
   winget install Microsoft.DotNet.SDK.8
   winget install Git.Git
   ```

2. Get the code and run the tests:

   ```powershell
   git clone https://github.com/toncatalansuazo/glass-meet-pen.git
   cd glass-meet-pen\windows
   dotnet test tests\Glasspen.Core.Tests
   ```

3. Build the app:

   ```powershell
   dotnet publish src\Glasspen.Windows -c Release -o publish
   ```

   The result is **`publish\GlasspenMeet.exe`**: one file (about 80 MB) that includes .NET, so the
   people you share it with don't need to install anything.

You can also open `Glasspen.sln` in **Visual Studio 2022** (".NET desktop development" workload),
set **Glasspen.Windows** as the startup project and press F5.

**First run:**
- Windows asks whether to let it use the network: allow **Private networks**, so the phone can connect.
- Until the `.exe` is code-signed, SmartScreen says "Windows protected your PC": click **More info → Run anyway**.

## Using it

The app lives in the **tray icon** next to the clock (right-click it for the menu, left-click shows the toolbar).

| Keys | Action |
| --- | --- |
| Alt + ` | Start or stop drawing (from any app). It's the key left of 1, whatever it shows on your keyboard (º on Spanish, ^ on German, ² on French) |
| Alt+Delete | Clear all (just Delete while drawing) |
| Alt+1 … 0 | Pick a tool and start drawing: pen, highlighter, line, arrow, rectangle, ellipse, phone, person, text, eraser (on/off in Settings) |
| P H L A R O I F T E | Same tools while drawing |
| 1–8 | Colors (while drawing) |
| [ ] | Thinner / thicker |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo |
| Shift | Squares, circles, 45° lines, figures in proportion |
| Esc | Stop drawing |

Global shortcuts use plain **Alt**, not Ctrl+Alt, because Ctrl+Alt is **AltGr** on Spanish, Italian,
German and many other keyboards, where it types @, # and brackets. If Alt+1 … 0 clash with an app you
use (for example IntelliJ or Windows Terminal), turn them off in Settings.

You can change the drawing and clear-all shortcuts in **Settings → Shortcuts**: click the shortcut and
press the new keys. Settings also has the toolbar's **background opacity**.

- **Toolbar:** at the bottom or on the left/right side (⇔ button). Drag it by the ⋮⋮ grip. Tools,
  colors (with ink opacity) and widths open in pop-ups.
- **Timer** (⏱): strokes fade after 1 s (default), 3 s or 5 s, or stay ("Permanent").
- **Whiteboard** (⬜ and the slider): covers your apps, also while you click through them. Hiding the
  toolbar (✕) removes it, so the screen can't get stuck white.
- **Text:** pick T, click, type, press Enter (Esc cancels).
- **Phone:** tray menu → *Connect iPhone/iPad…*. Scan the QR code, or tap the PC in Glasspen Remote and
  click **Allow** when both screens show the same code.
  The phone needs a Glasspen Remote build from the same release as this Windows version or later: older
  builds pair and draw, but never show the PC's screen (they only know the Mac's H.264 video, and this
  version sends JPEG stills, docs/protocol.md §8). Install it again with `make phone` from `apple/`.

## How it is built

| Project | What it is |
| --- | --- |
| `src/Glasspen.Core` | Platform-neutral C# (.NET 8): strokes, undo/redo, geometry, the phone protocol and pairing. Port of the Swift BrushKit. |
| `src/Glasspen.Windows` | The WPF app, written in C# only (no XAML): overlay, toolbar, tray, shortcuts, phone server. |
| `tests/Glasspen.Core.Tests` | xUnit tests: Swift-made messages (`SwiftFixtures.txt`), the protocol test values, live handshakes over TCP. |

The phone protocol is in [docs/protocol.md](../docs/protocol.md). Differences from the Mac app:
- The phone gets **JPEG stills about 4 times a second** instead of H.264 video. Drawing is still instant,
  because strokes travel separately and the phone draws them itself.
- Only the **primary display** is used.
- No "show all options" toolbar mode yet; the toolbar always uses pop-ups.

## Checklist for the first run on Windows

1. The tray icon appears, and the toolbar shows at the bottom.
2. Alt + ` (key left of 1): the pointer becomes a pen and you can draw; Esc stops and clicks reach your apps again.
3. Alt+5 picks the rectangle; Shift makes a square.
4. Text tool: click, type, Enter; the text stays where you typed it.
5. Timer: with 1 s, strokes fade; with Permanent, they stay.
6. Whiteboard at 100%: still visible after Esc; ✕ on the toolbar removes it.
7. Share the screen in Zoom/Meet/Teams: the others see the drawings.
8. Phone: scan the QR code; the phone shows the PC screen and its strokes appear on the PC.
9. Phone: tap the PC in the list; both screens show the same code; **Codes Match** + **Allow** connects.
