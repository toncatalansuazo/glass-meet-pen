# Glasspen wire protocol (version 2)

This is how **Glasspen Remote** (iPhone/iPad) talks to the desktop app. A desktop app on
any platform (the Mac app today, the Windows app later) that implements this document
works with the same phone app.

The source of truth is the Swift code in `apple/BrushKit/Sources/BrushKit/`:
`Protocol/Messages.swift`, `Net/SecureChannel.swift`, `Pairing/Pairing.swift` and
`Model/Model.swift`. If this document and the code disagree, the code wins. Please fix
the document.

## 1. Roles

- **Server:** the desktop app. It owns the drawing document and the screen.
- **Client:** the phone. It sends intents (start a stroke, undo, …) and shows what the server sends back.

## 2. Discovery and connection

- The server listens on **TCP port 7878**. If that port is busy, it lets the OS pick a free one.
- It announces itself with Bonjour/mDNS as service type **`_paintscreen._tcp`**. The service name is the computer's name.
- TCP_NODELAY is on, and keep-alive is set to 5 s idle.
- The phone opens **two TCP connections**, each with its own handshake:
  - **control:** messages (strokes, tools, undo, …)
  - **video:** the screen video and detail stills, so a big video frame never delays a stroke.

## 3. Pairing

The server has one long-term secret, the **token**: 16 random bytes, base64url
without padding (22 characters). "Reset Pairing" on the server makes a new one and
disconnects every phone.

A phone pairs in one of two ways:

| Mode | How | When |
| --- | --- | --- |
| `token` | The phone knows the token | After scanning the QR code, and every later reconnect |
| `confirm` | Both screens show the same 6-digit code; the user clicks **Allow** on the server | When the user taps a computer in the list instead of scanning |

The QR code holds this URL:

```
paintscreen://pair?svc=<service name>&t=<token>&h=<LAN IPv4, optional>&p=<port>
```

After a `confirm` pairing, the server sends `pairingToken(token)` (section 7), and the
phone saves it. From then on the phone connects in `token` mode, including its video connection.

## 4. Framing

Every frame in both directions, before and after the handshake:

```
[UInt32 length, big-endian][payload: length bytes]
```

`length` must be between 1 and 16 MiB (16 × 1024 × 1024). Otherwise the connection is closed.

## 5. Handshake

Every connection (control and video) starts with a handshake. The payloads are UTF-8
**JSON**. Binary fields (`nonce`, `pub`, `commit`, `mac`) are **standard base64 with padding**.
Fields that are not set are left out.

Each side makes a new **X25519** key pair for every connection (`pub` = 32-byte raw public key).

**`token` mode**

```
client → server   {"v":2, "mode":"token", "nonce":<32 random bytes>, "pub":<client pub>}   ClientHello
server → client   {"nonce":<32 random bytes>, "pub":<server pub>, "locked":false}         ServerChallenge
client → server   {"mac":<clientProof>}                                                  ClientProof
server → client   {"ok":true, "mac":<serverProof>}                                        ServerResult
               or {"ok":false, "reason":"auth"|"locked"}
```

**`confirm` mode.** The client first sends only a **commitment** to its key, and shows
the key after it has seen the server's. Neither side can then pick its key to force a
matching code: a fake server or client gets one blind try, with a 1 in 1,000,000 chance.
The user checks the code on **both** screens: the phone sends its proof only after the
user taps "Codes Match", and the server answers only after the user clicks Allow.

```
client → server   {"v":2, "mode":"confirm", "nonce":<32 bytes>,
                   "commit":<SHA256("glasspen-v2-commit" + client pub)>, "deviceName":"iPhone"}
server → client   {"nonce":<32 bytes>, "pub":<server pub>, "locked":false}
client → server   {"pub":<client pub>}                                                   ClientReveal
                  (both screens now show confirmCode)
client → server   {"mac":<clientProof>}          only after the user taps "Codes Match"
server → client   {"ok":true, "mac":<serverProof>}   only after a valid proof AND Allow
               or {"ok":false, "reason":"auth"|"denied"|"locked"}
```

**Keys** (HKDF-SHA256 as in RFC 5869, and HMAC-SHA256; `+` means concatenation; strings are UTF-8):

```
shared     = X25519(own private key, peer pub)               32 bytes
transcript = SHA256("glasspen-v2-" + mode + clientNonce + serverNonce + clientPub + serverPub)
ikm        = shared + token        (token mode)
           = shared                (confirm mode)
key        = HKDF(ikm, salt = transcript, info = "glasspen-v2-key", length = 32)

clientProof = HMAC(key, "client" + transcript)
serverProof = HMAC(key, "server" + transcript)
c2sKey      = HKDF(key, salt = transcript, info = "c2s", length = 32)
s2cKey      = HKDF(key, salt = transcript, info = "s2c", length = 32)
confirmCode = UInt32 big-endian of HKDF(key, salt = transcript, info = "sas", length = 4)
              modulo 1,000,000, written as 6 digits with leading zeros
```

**Test values.** Use these to check an implementation (they are also checked in
`apple/BrushKit/Tests/BrushKitTests/ProtocolTests.swift`):

```
client private key  11 × 32 bytes        server private key  22 × 32 bytes
clientNonce         aa × 32 bytes        serverNonce         bb × 32 bytes
clientPub   7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13
serverPub   0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20
commit      602f73ae9dc4c13584eebb256cf73ef47436761db53b5bb222b7e2f57c7f44eb

token mode, token = "token-123"
  transcript   2a333338b0308a156ed90448711b4c8368ed3130c4b0fb526b9f727da7152115
  clientProof  d33f3fde4a92f91d304b4920dbe50a40cf40968ffd936a804a4826594b944fa3
  serverProof  e973accf70c73a43ae6cbb93308a37bd7bcd117037758eb84c8f8bd32ea78ba7
  c2sKey       6af86210ef328c7cf670e0c07539dbf5c3b5c69c7425c21fa3bbdd6593d6ce83
  s2cKey       11714f39986989e72499a16b7463eafd78ffb0d34fa6cf248c4b1e84884d5f6d
  confirmCode  346892

confirm mode
  transcript   a8608049eda7e265d38e0cd3dfaf5655e5fe11672f47518d6d3a26af90798c21
  clientProof  49a1a4f4692b05fd0cdeb7f0d41701b6bc92fa3186186ee4e7d11e8004c409fe
  serverProof  ef4e8db42ee07992d8fff6c3a34ebe5e2f43e243663f1eca41986a997bccde91
  c2sKey       077fbaaab24be29dcdf973312f630d4ae5358ce1c607dbf93c385c8ab0c5f486
  s2cKey       b33276bdc30edf08758bbf1988b372217d2107369faacbff3cef03c1be68bc0a
  confirmCode  015112
```

Rules for both sides:

- Handshake messages are at most **4 KiB**. A longer length closes the connection.
- Compare every MAC and the commitment in **constant time**.
- Close any connection whose handshake hasn't finished after **90 s**.

Rules for the server:

- If `v` is not 2, close the connection.
- In `confirm` mode, check that `SHA256("glasspen-v2-commit" + pub)` equals `commit` before anything else.
- Show the prompt as soon as the reveal checks out: `confirmCode` and the device name.
  The device name is untrusted: remove control characters and line breaks, and cut it to
  40 characters. Show it as plain text.
- Decline when the user clicks Deny or closes the prompt, after 60 seconds, or when another
  prompt is already open. **Close the prompt** when its connection closes before the user answers.
- **Attempt limit per remote IP:** an attempt counts **when the hello arrives**, not when it fails.
  Open attempts plus recent failures must stay under 5. Otherwise the server answers
  `"locked":true` and closes. A failure is a wrong proof, a wrong commitment, Deny, or a handshake
  abandoned halfway. Failures are forgotten 30 s after the last one. The 5th failure locks the IP
  for 30 s. A success clears its failures.
- Accept at most 16 connections in the handshake at once.

Rules for the client:

- In `confirm` mode, show `confirmCode` with "Codes Match" and "Cancel". Send the proof only
  after "Codes Match". Cancel closes the connection.
- Accept `pairingToken` only on a connection that finished a `confirm` handshake.
- Treat a `paintscreen://pair` link opened from another app as untrusted: ask the user before it
  replaces the saved pairing.

## 6. Encrypted frames

After the handshake, every payload is encrypted with **ChaCha20-Poly1305**:

```
payload   = ciphertext + tag (16 bytes)
plaintext = [kind: UInt8] + body
nonce     = 4 zero bytes + UInt64 frame counter, big-endian (12 bytes)
```

- Each direction has its own key (`c2sKey` or `s2cKey`) and its own counter, starting at 0 and increasing by 1 per frame.
- A frame that fails to decrypt closes the connection. This also rejects frames that are replayed, reordered or dropped.

| kind | Name | Body |
| --- | --- | --- |
| 0 | message | a binary property list (section 7) |
| 1 | video | `VideoPacket` (section 8) |
| 2 | detail | `DetailPacket` (section 8) |

Any other `kind`, or an empty plaintext, closes the connection. Don't add new kinds
without changing the protocol version.

## 7. Messages (kind 0)

Messages are **Apple binary property lists** (`bplist00`), in the shape Swift's
`Codable` produces for enums:

- Every message is a dictionary with **one key**: the case name.
- Labeled associated values become a dictionary of those labels.
- One **unlabeled** value is stored under the key `"_0"`.
- A case with no values has an empty dictionary.
- A `nil` optional is **left out**.

```
undo                       → { "undo": {} }
strokeBegin(stroke)        → { "strokeBegin": { "_0": <Stroke> } }
viewport(rect: nil, …)     → { "viewport": { "pixelWidth": 10, "pixelHeight": 20 } }
```

### Value types

| Type | Encoding |
| --- | --- |
| `Stroke` | `{id: UUID string, sourceID: SourceID, tool: Tool, color: RGBAColor, width: real, points: [StrokePoint], seq: integer, createdAt: date}` |
| `StrokePoint` | `{x, y, p}` reals. `(0,0)` is the display's top-left and `(1,1)` its bottom-right. `p` is pressure from 0 to 1 (1 without pressure). |
| `SourceID` | `{rawValue: string}`. The mouse is `"mouse"`. |
| `Tool` | string: `pen`, `highlighter`, `line`, `arrow`, `rectangle`, `ellipse`, `phone`, `person`, `eraser` |
| `RGBAColor` | `{r, g, b, a}` reals from 0 to 1. `a` is the ink opacity. |
| `WidthPreset` | integer: 0 fine (3 pt), 1 medium (6 pt), 2 bold (11 pt), 3 heavy (18 pt) |
| `ToolState` | `{tool: Tool, color: RGBAColor, width: WidthPreset}` |
| `NormRect` | `{x, y, w, h}` reals, in normalized display coordinates |
| `DisplayInfo` | `{id: integer, name: string, width: real, height: real}`, in points |
| `ChannelRole` | string: `control` or `video` |
| `UUID` | uppercase string, e.g. `"11111111-2222-3333-4444-555555555555"` |
| `date` | a plist date |

More rules:

- **Stroke width** is a fraction of the display width (`points / displayWidth`).
- **Shapes and figures** (`line`, `arrow`, `rectangle`, `ellipse`, `phone`, `person`) have exactly two points: start and end.
- **Rendering:** highlighters are drawn 2.5× wider, with alpha × 0.35.

### Client → server (`ClientMessage`)

| Case | Values |
| --- | --- |
| `hello` | `version: 2, role: ChannelRole, deviceName: string, sourceID: SourceID, isPad: bool`. The first message on **each** connection. See the rules below. |
| `strokeBegin` | `_0: Stroke` |
| `strokeAppend` | `id: UUID, points: [StrokePoint]` |
| `strokeEnd` | `id: UUID` |
| `strokeCancel` | `id: UUID` |
| `erase` | `points: [StrokePoint], radius: real`. `radius` is a fraction of the display width, like `Stroke.width`. |
| `undo`, `redo` | none. Undo or redo the **sender's own last action** (each `sourceID` has its own history). |
| `clear` | none. Removes every committed stroke and cancels every live stroke, from all sources. |
| `setTool` | `_0: ToolState` |
| `setMacDrawMode` | `_0: bool` |
| `viewport` | `rect: NormRect?, pixelWidth: int, pixelHeight: int`. The part of the display the phone shows. With no `rect`, the phone shows the whole screen. |
| `requestKeyframe` | none |
| `ping` | `sentAt: real` (seconds) |

**`hello` rules**

- A `version` other than 2 closes the connection.
- One phone at a time: a new `control` hello ends the current session. The old phone gets
  `sessionEnded("Another device connected")` and its connections are closed.
- A `video` hello is accepted only after the `control` hello, with the same `sourceID`.
  Otherwise the video connection is closed.
- Only the active control connection may send other messages. Anything else is ignored.

**Erasing.** A committed stroke is erased when any eraser point is within
`radius + effectiveWidth / 2` of the stroke. Distances are in display-width units, with y
scaled by `height / width` so the eraser stays round. A figure (`phone`, `person`) counts as
hit anywhere inside its box. Erasing can remove strokes from **any** source. The erase is
the sender's action, so the sender's `undo` brings them back. The same goes for `clear`.

### Server → client (`ServerMessage`)

| Case | Values |
| --- | --- |
| `welcome` | `_0: {macName, display: DisplayInfo, snapshot: [Stroke], toolState, macDrawMode: bool, screenPermission: bool}` |
| `liveBegan` | `_0: Stroke`, a stroke in progress |
| `liveUpdated` | `id: UUID, points: [StrokePoint], replace: bool`. `replace` true means the list replaces the stroke's points; false means append. |
| `liveCancelled` | `id: UUID` |
| `committedChanged` | `added: [Stroke], removed: [UUID]` |
| `toolChanged` | `source: SourceID, state: ToolState` |
| `drawModeChanged` | `_0: bool` |
| `displayChanged` | `_0: DisplayInfo` |
| `screenPermission` | `granted: bool` |
| `pairingToken` | `_0: string` |
| `sessionEnded` | `reason: string` |
| `pong` | `sentAt: real`, copied from the ping |

## 8. Binary payloads (video connection)

All integers and floats are **big-endian**.

**`VideoPacket`** (kind 1): one H.264 access unit.

```
u8   isKeyframe (1 = yes)
f64  timestamp (seconds)
u16  width, u16 height (pixels)
u8   n = number of parameter sets (2 on keyframes: SPS, PPS; 0 otherwise)
n × [u32 length][bytes]
rest AVCC data: NAL units, each with a 4-byte big-endian length prefix
```

**`DetailPacket`** (kind 2): a sharp JPEG still of the area the phone is zoomed into.

```
f32 x, f32 y, f32 w, f32 h   (NormRect)
u32 requestID
rest JPEG bytes
```

## 9. Notes for a new desktop implementation (e.g. Windows)

- **Messages:** .NET has no built-in reader for binary property lists. A library such as
  `plist-cil` (NuGet) reads and writes them.
- **Crypto:** HKDF, HMAC-SHA256, SHA-256 and ChaCha20-Poly1305 are in `System.Security.Cryptography`
  (.NET 8+). .NET has no X25519; use a library such as NSec (libsodium) or BouncyCastle.
- **Discovery:** Bonjour/mDNS can come from Windows' DNS-SD API or a library such as `Makaretu.Dns.Multicast`.
  If discovery fails, the phone can still connect with the `h` and `p` values in the QR code.
- **Video:** the phone expects H.264 in AVCC form. On Windows, Media Foundation produces Annex-B
  (start codes), so convert it: replace each start code with a 4-byte length.
- **Naming:** the protocol strings (`screenbrush`, `paintscreen`) are older internal names.
  They are part of the protocol, so keep them exactly as written.
