# Glasspen Meet

Draw on your screen while you share it in a call, with the mouse or with your iPhone/iPad as a remote.
On the phone, zoom into the exact spot first, then draw.

| Folder | What's inside | Status |
| --- | --- | --- |
| [`apple/`](apple/) | **Glasspen Meet** for macOS, **Glasspen Remote** for iPhone/iPad, and the shared Swift package **BrushKit** | Working |
| [`windows/`](windows/) | Glasspen Meet for Windows (C#/WPF), with the same phone remote | Builds; not yet run on Windows |
| [`docs/protocol.md`](docs/protocol.md) | How the phone talks to the desktop app. Any desktop app that implements it works with Glasspen Remote. | |

## Download

**Mac** (macOS 14 or later), with [Homebrew](https://brew.sh):

```bash
brew install --cask toncatalansuazo/tap/glasspen-meet
```

Or download the zip from [Releases](../../releases) and drag the app into Applications.
The app is not notarized by Apple yet: the first time you open it, go to
**System Settings → Privacy & Security** and click **Open Anyway**.

**iPhone/iPad** (Glasspen Remote) and **Windows**: build from source, see [apple/README.md](apple/README.md)
and [windows/README.md](windows/README.md).

## Support

Glasspen Meet is free and open source. If it helps you, you can
[buy me a coffee ☕](https://buymeacoffee.com/toncatalan).

## License

[MIT](LICENSE)
