# Local Chat

Private WhatsApp-style chat over **Tailscale** (and optionally the same Wi‑Fi LAN).

- **Python server** (FastAPI + WebSockets + SQLite) — e.g. on a phone via Termux, or a PC
- **Flutter Android app** — other phones connect using the server’s Tailscale `100.x.x.x` IP
- No public cloud for chat traffic; credentials are local username + password

Inspired by the deployment model of [local-drive](https://github.com/SiliconValley007/local-drive).

## Features

- Register / login (username + password), persistent sessions
- 1:1 DMs and group chats
- Text, images, **videos**, files, and voice notes
- **Display pictures** — set your own photo; everyone on the server sees it. Tap any photo to open it full screen, pinch to zoom, and share it
- **Server storage at a glance** when attaching — free space on the Windows or
  Termux device hosting Local Chat, with early and critical low-space warnings
- **Send up to 50 photos or videos at once** from an in-app Recent media grid
  (camera shortcut included); review, reorder, remove, and caption the selection
  before sending. A batch caption belongs to its first item; documents stay on
  the separate file picker
- **Videos show a first-frame preview and play in the app** — tap to watch
  (streamed, with seeking), then save or share only if you want to keep it
- **Low-bandwidth by design** — gzipped JSON, kept-alive probes, coalesced inbox refreshes, persistent authenticated image/wallpaper caching, small upload-time photo/video previews, and no auto-downloading of video
- **Nudge** — double-tap the chat to buzz the other phone with a floating wave, no message logged
- **Bubbles hug their text**, so a two-word reply gets a two-word bubble, like WhatsApp
- **Big emoji** — an emoji-only message is drawn large and bubble-free, like WhatsApp,
  and a single emoji pops in when it lands (tap to replay)
- **Every emoji renders** — the app carries Noto Color Emoji, so the newest ones are
  not the empty boxes a phone's own font would draw
- **End-to-end encryption for direct chats** — X25519 key exchange, AES-GCM message bodies; the server only ever stores an opaque token. Auto-negotiated on open, transparent to search and previews (which stay on your phone). A stretch of history sealed for a phone that has since been replaced can never be opened again, so bubbles, inbox subtitles, starred rows and quotes say “🔒 Encrypted message” rather than printing the token
- **Message reactions** — long-press for a WhatsApp-style emoji bar or pick any emoji; tallies show under the bubble
- **Starred messages** — private, server-synced stars for text and every
  attachment type; the list updates immediately on star/unstar
- **Delete for everyone or for me**, and **edit** within 15 minutes of sending
- **Disappearing messages** per chat — off / 24 hours / 7 days / 90 days, with a timer in the chat header and on affected bubbles, and the exact local moment spelled out (“Disappears tomorrow at 7:41 AM”) when you long-press a message or open the timer sheet
- **Nudge flavours** — wave, poke, hug, or kiss, each with its own buzz and floating glyph; **per-chat nudge history** (Chat ⋮ → Nudge history) keeps every nudge off the transcript with explicit sent/received copy and local aliases
- **Live doodles** — draw ephemeral strokes over an open chat (color, brush, undo/redo, clear); peers see them live over the WebSocket; optional **Send** flattens the canvas to a transparent PNG `Drawing` message that stars, replies, and exports like any attachment
- **Realtime transcript sync** — incremental `after_id` fetch plus merge-based loading so WebSocket rows, reconnect/resume, and foreground FCM never lose messages to a stale HTTP page; optimistic sends dedupe by client id. Overlapping requests for the same chat (a push, a socket frame, and the chat being opened all at once) share one fetch and queue at most one pass behind it, so opening a chat always shows what arrived and always clears its badge
- **No flash of "nothing here"** — chats, the chat list, starred, nudge history, shared media and uploads show stand-in rows until the first load resolves, so an empty illustration is never painted over history that is a second away
- **Jump straight to a message** — starred, quoted/tagged replies, pins, search hits and “show in chat” fetch the history between here and there in a single request, then walk to the exact row, centre it, and light a highlight band behind it *as it arrives* (the same band for text, photos, files and drawings). The walk measures each step against the rows on screen instead of assuming every row is the same height, which is how it lands in a chat where one photo is worth a dozen lines of text; it never leaps past the end of the content, finds its way back if it ever ends up looking at nothing, holds history paging so the rows cannot renumber underneath it, and if it truly cannot land it says so and puts you back where you started
- **Previews keep the shape they were taken in** — a photo, screenshot or video keeps its own proportions in the bubble, standing tall for a portrait and lying flat for a panorama, cropped past those limits rather than squashed; the shape is remembered so a row never resizes twice
- **Couple details (DMs)** — every one-to-one chat carries an **Anniversary and streak** entry in its ⋮ menu, reading “Off” until you use it, so the one chat that wants a date is a tap away and a chat with a parent or a colleague shows nothing until you say so. Setting a date turns the display on by itself; the switch, the date, and the streak all live in the same sheet, and the contact's info page has the same switch. Everything stays on this phone
- **Shared chat wallpapers** — any member sets one image and everyone in the chat sees it; the gallery grid offers photos only and has no Send/Preview step (one tap goes straight to framing), the picked photo is framed with pinch to zoom and drag to position against a live preview of the chat bubbles, and the dim slider that keeps text legible is set in the same place
- **Activity log (admin)** — the server keeps its own append-only account of every action: who did it, when, from which address, and for an edit or a deletion **the text as it stood before**, so a message removed from a chat is still on record. One account holds the role, named by username (`DDas`), claimed from the app (self only while unclaimed) or pinned on the server with `LOCALCHAT_ADMIN_USERNAME` / `SetAdmin.exe`. The first phone that successfully opens the log is pinned as the trusted admin device; other installs of the same account are refused until the pin is cleared. The admin can force-sign-out any other user. The screen speaks in human sentences (timers as “24 hours”, chat names when known), opens sealed DM text **only on a member phone that holds the key**, folds machine ids under Technical details, and copies a readable report. Every person in an entry is named from what the server wrote down at the time — who sent the message, who else was in that chat, and whether a deletion was the sender's own or an admin's — so the reader is never presented as the other party, and a timer running out is not recorded as somebody deleting anything. Nothing in the app can edit or delete an entry
- **Server status** — the inbox overflow menu reports the host running the chat: Termux/Android or Windows, free RAM and what the server process itself holds, disk, battery with charging state, and uptime, plus plain advice when any of them turns risky. Read on open and on pull-to-refresh only, never polled, so watching the server costs no battery
- **Owner-safe server cleanup** — review “My uploads”, select what to remove,
  and reclaim server space without exposing or deleting another user’s files
- **Rich text in bubbles** — WhatsApp-style `*bold*`, `_italic_`, `~strike~`, `` `code` ``, fenced code blocks with copy, and `||spoilers||` (also `**bold**` / `~~strike~~`)
- **Pinned messages** in a chat — sticky banner with jump-to-message
- **Search all messages** from the inbox, with sender / media / date filters
- **Search reads the whole chat, every time** — a sealed DM can only be matched on your phone, and searching now pages that chat back to its first message (in full-size pages, with a spinner while it works) instead of matching whatever happened to be in memory. That is what made the same word findable one minute and missing the next; leaving a chat no longer marks its trimmed history as complete, and a slow answer can no longer overwrite a newer search
- **Per-chat drafts** restored when you reopen a conversation
- **Voice notes** with waveform, an always-visible 1× / 1.5× / 2× speed control, and background-friendly playback
- **Media viewers** with Hero transition plus conflict-free pinch, pan, and double-tap photo zoom; optional Wi‑Fi-only video saves
- **Voice and video calls** — WebRTC over Tailscale; incoming calls use a high-priority
  heads-up notification (not a lock-screen takeover), local aliases appear in
  call alerts, ring/ringback and vibration follow the call phase, and voice
  calls can switch between earpiece, speaker, and Bluetooth
- **One authoritative call log** — one row per call, with outcome, duration, and
  who ended an answered call; inbox previews never expose call JSON
- **Privacy onboarding** — short first-run tips about your server, Tailscale, and no cloud account
- **Reply / quote**, **edit**, and **delete** (tombstone) for messages
- Delivery and read receipts (monotonic — a read on a newer message ticks every
  older one, so a dropped socket frame cannot leave a stale single tick), with
  the latest outgoing status also shown in the Chats list; typing, online /
  last-seen presence, and partner mood as secondary text
- **Profile screens** — edit your photo, display name, and mood in one place;
  contact profiles keep private aliases, real identity, full last-seen, shared
  media, and call actions together
- **Search** people, last-message text in the inbox, and messages inside a chat
- **Pin** chats and **mute** notifications per conversation (device-local)
- **Export chat** as a shareable plain-text file
- **Clickable links** in messages (opens in the browser; no silent preview fetch)
- **Unread badge** on the app icon (where the launcher supports it)
- **Reconnecting** banner in the inbox when the WebSocket drops
- **Tailscale gate** — app waits if the private server is unreachable; asks Tailscale to connect on open (including from a notification), switches it back off when the app is closed, and offers Connect / Open buttons. Switching off no longer depends on the app being alive to hear about it: a guard service counts the app's time in the background and disconnects on its own, whether the app is swiped away from Recents, killed by Android while minimised, or simply forgotten there — with an alarm as a second backstop. A live call **or an in-flight media upload** keeps the tunnel up so switching apps mid-send does not kill a large transfer; if the path still drops, the send waits and retries from the start
- **Share into Local Chat from any app** — Local Chat appears in Android's share
  sheet for links, text, photos, videos, and documents; pick a chat (or a new
  one) and the share is sent as a message, captioned when it came with text
- **Add people** — username search, local contacts (device-only), QR invite, and
  invite links that carry the server address
  (`localchat://user/DDas?server=http://100.x.y.z:8000`) so a fresh phone is
  pointed at your server instead of having to be set up by hand. Scan it, paste
  it from the clipboard, or just tap the link. Tailscale access is still required
- **Rename people** — give anyone a name only you see; saved on the phone and inside the encrypted backup
- **Notifications** — exactly one alert per chat, showing only who wrote, never what they wrote (on the socket and over FCM alike); optional FCM data-only wake-ups. An alert also **clears itself once nothing is unread**: every inbox refresh compares the shade against the server's unread counts, so a chat read on another device, or read here and left, does not keep a notification alive
- **Encrypted backup / restore** — AES-GCM on-device, ciphertext on private server + optional Firestore mirror; verify without restoring (format v3 includes starred message ids)
- **Appearance** — system / light / dark, remembered on the phone
- **Change password** in the app; admin can reset forgotten logins with `reset_password.py`
- **Media, links, and docs** gallery per chat (WhatsApp-style) with jump back to the message

## What this is / is not

**Ready for:** private chat across different networks via Tailscale (or same LAN), with the server device online and Tailscale Connected.

**Not a full WhatsApp replacement:** no Status/stories; live messages are stored in plaintext on your private server device (DM bodies can be E2E). Traffic is plain HTTP inside your Tailscale/LAN mesh. **Do not expose port 8000 to the public internet.** Backups are client-encrypted so cloud storage never sees chat plaintext. Calls prefer a direct Tailscale path (no TURN server in this build).

---

## Recommended setup

| Role | Device |
|------|--------|
| **Server** | One always-on machine (Termux phone, Windows PC, or Linux box) running the Python server |
| **Clients** | Other phones with the Android APK |

1. Install **Tailscale** on the server and every client; join the **same** tailnet; leave it **Connected**.
2. Start the chat server (Termux / Windows steps below, or download the Windows build from [Releases](../../releases)).
3. Note the server’s Tailscale IPv4 (`100.x.x.x`) from the Tailscale app or the server banner.
4. Install the APK on each client → open the app → set the server URL to `http://100.x.x.x:8000` → **Register**.
5. Change the URL later from Inbox ⋮ → **Server settings** if the server IP changes.

If Tailscale shows a device **offline**, fix that first — the chat app cannot reach it.

---

## 1. Run the Python server

The server listens on **`0.0.0.0:8000`** (all interfaces), so it accepts connections on both Tailscale (`100.x`) and LAN (`192.168.x`) when those interfaces exist.

### A) Termux on realme-2 (Tailscale server)

The phone is memory-tight. Always start with `./start_termux.sh` (not a bare
`python run.py`) so `LOCALCHAT_LOW_MEMORY=1` keeps SQLite, uploads, and uvicorn
inside a few hundred MB. Do not copy `server/dist` or `server/build` from a
Windows machine onto the phone — those are PyInstaller leftovers (~160 MB).

1. Install **Termux** (and optionally Termux:API for `termux-wake-lock`).
2. Install **Tailscale** Android app; connect; leave it running.
3. Copy this repo’s `server/` folder onto the phone (git clone, USB, etc.).
4. In Termux:

```bash
pkg update
pkg install python tmux python-cryptography
cd /path/to/Chat/server
chmod +x start_termux.sh
./start_termux.sh
```

`start_termux.sh` recreates the venv if it came from Windows, reuses Termux's prebuilt
`python-cryptography`, falls back to `requirements-termux.txt` when a Rust build fails, and runs
the server inside `tmux` so an SSH drop does not kill it (`tmux attach -t localchat` to return).

### Keeping the server alive with tmux (recommended)

**What is tmux?** A tiny program that runs a "session" inside Termux. You can disconnect SSH
or close the Termux UI and the session (and your chat server) keeps running. Without it,
closing the SSH window stops `python run.py`.

Install once:

```bash
pkg install tmux
```

#### First time — create the session

```bash
cd ~/downloads/local-drive/uploads/Dev/server   # your real server path
source .venv/bin/activate
tmux new -s localchat
```

You are now *inside* a tmux window. Start the server:

```bash
python run.py
```

**Detach** (leave the server running, return to a normal shell):

- Press `Ctrl+b`, then release both keys, then press `d`

You should see something like `[detached (from session localchat)]`.
SSH can disconnect now; the server keeps running.

#### Later — come back to the same session

```bash
tmux attach -t localchat
```

You see the live server logs again. Detach with `Ctrl+b` then `d` whenever you want.

#### Useful tmux commands

| Goal | Command |
|------|---------|
| List sessions | `tmux ls` |
| Attach to `localchat` | `tmux attach -t localchat` |
| Create if missing | `tmux new -s localchat` |
| Stop the server | Attach, then `Ctrl+C` |
| Kill the whole session | `tmux kill-session -t localchat` |
| Scroll up in logs | `Ctrl+b` then `[`, arrow keys / PageUp, `q` to quit scroll |

#### Optional: wake lock so Android does not sleep the phone

```bash
pkg install termux-api
termux-wake-lock
```

Run that before starting tmux when you want the server phone to stay awake.

Or manually:

```bash
cd /path/to/Chat/server
rm -rf .venv                                  # if copied from Windows (has Scripts/, not bin/)
python -m venv --system-site-packages .venv
source .venv/bin/activate
python -m pip install --prefer-binary -r requirements.txt
python run.py
```

### Updating the server on Termux

The venv, the database, and your secrets all live outside the code, so an update
never means reinstalling dependencies. Only `app/`, `run.py`, and the
requirements files change.

**Option 1 — `git pull` (recommended once set up).** One command per update:

```bash
pkg install git                       # once
cd ~/localchat && git pull            # your clone of this repo
cd server && source .venv/bin/activate
python run.py
```

To move an existing hand-copied server onto git without losing anything:

```bash
cd ~
git clone https://github.com/SiliconValley007/local-private-chat.git localchat
OLD=~/downloads/local-drive/uploads/Dev/server   # your current server folder
cp -r $OLD/.venv        ~/localchat/server/      # keep the installed packages
cp    $OLD/jwt_secret.txt ~/localchat/server/ 2>/dev/null
cp    $OLD/firebase-service-account.json ~/localchat/server/ 2>/dev/null
cp -r $OLD/data         ~/localchat/server/      # chat.db — your history
cp -r $OLD/media        ~/localchat/server/      # uploaded photos / voice notes
```

Keep the old folder until the new one has served a full chat, then delete it.
Nothing you copied is tracked by git, so `git pull` will never overwrite it.

**Option 2 — update zip.** Unzip *into the server folder*, not next to it. A
`run.py` appearing beside `server/` means it landed one level too high:

```bash
cd ~/downloads/local-drive/uploads/Dev/server
unzip -o ~/storage/downloads/server-update.zip
find . -name __pycache__ -type d -prune -exec rm -rf {} +
sed -i 's/\r$//' start_termux.sh    # only needed if the zip came from Windows
chmod +x start_termux.sh            # unzip drops the executable bit
```

Either way, restart the server so the new code loads: attach with
`tmux attach -t localchat`, press `Ctrl+C`, run `./start_termux.sh` (or
`python run.py`), then detach with `Ctrl+b` `d`. New database columns are added
automatically on startup. `start_termux.sh` turns on
`LOCALCHAT_LOW_MEMORY=1` so SQLite, uploads, and uvicorn stay lean on a phone.

**App-only updates need none of this.** When a release changes only the Flutter
app, install the new APK and leave the server running.

#### Installing a new APK on a client phone

1. Copy `releases/LocalChat-android-arm64.apk` (most modern phones) or
   `LocalChat-android-arm32.apk` (older / budget) to the phone.
2. Open the file and install over the existing app — login and chats stay.
3. After install, force-stop once from Android settings if the previous version
   was still in Recents, then open Local Chat and confirm Tailscale connects.

#### What to test after this update

1. Open a chat that has unread messages — they must appear without restarting.
2. Place a short call and hang up — the call screen must close; Back must work.
3. Wallpaper → Choose from gallery: the grid must show photos only and have no
   Send or Preview bar. One tap opens Frame wallpaper; pinch/zoom/pan, then Set
   wallpaper — framing must match.
4. Cold-start from Recents cleared — no black splash; gate says connecting, not
   "Tailscale is not connected", for the first few seconds.
5. On the server phone: after update, `echo $LOCALCHAT_LOW_MEMORY` inside the
   Termux session should print `1` when started via `./start_termux.sh`.
6. Inbox menu → Server status: the host line must say Termux on Android (or
   Windows on a PC host), with RAM, disk, battery and uptime filled in. Pull to
   refresh updates the numbers; nothing should keep updating on its own.
7. Starred messages → tap several, including the oldest in the list: every one
   must land centred on that exact message and lit *as it arrives*, however far
   back it is. Repeat with a quoted reply, the pinned banner and a search hit.
   Nothing may end on a blank canvas, and no jump may leave you somewhere other
   than the message or back where you started. This one needs the server updated
   too, otherwise the app quietly falls back to paging.
8. Send a phone screenshot and a landscape photo: each preview must keep its own
   shape — a tall screenshot stands tall (cropped at the bottom, tap to see it
   all), a wide photo lies flat. Nothing may look squashed or stretched.
9. Scroll back through a long DM: any stretch that was sealed for a phone this
   one has since replaced reads “🔒 Encrypted message”, never an `e2e1:…` token.
10. Search a word you know is only in old history (Chat ⋮ → Search in chat): it
    must be found, with a spinner while the chat is read back. Leave the chat,
    come back, and search the same word again — the answer must not change.
11. Open the app, leave it in the background for at least one minute without
    closing it, then swipe it from Recents:
    `adb logcat -s TailscaleExit TailscaleGuard TailscaleIdleExit` must show the
    guard disconnect (around 30 seconds) and its alarm fallback (around 45
    seconds), and Tailscale must be off. Repeat coming back inside 30 seconds —
    the alarm is cancelled and the tunnel must stay up and work straight away.
12. Call someone who is offline: you must hear a ringback while it tries, see
    **Waking their phone…** or **Can't reach \<name\>** rather than a silent
    screen, and the call must end by itself.
13. On a chat with a mood set, the header's third line must be fully visible.
14. Tap **Search chats**, type, then tap the list or the empty space below it —
    the keyboard must close.
15. A parent's or colleague's chat menu must not mention couple details at all.
    Turn it on from their contact info page, and the menu row and banner appear;
    turn it off in either place and they go, in one tap, where you tapped.
16. Long-press a disappearing message: the sheet must name the exact local time
    it goes.

#### Termux troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `.venv/bin/activate: No such file or directory` | venv was created on Windows (`Scripts/`) | `rm -rf .venv` and recreate on the phone |
| `bad interpreter: .../bash^M` | The script was copied from Windows with CRLF line endings | `sed -i 's/\r$//' start_termux.sh` then `chmod +x start_termux.sh` |
| `./start_termux.sh: Permission denied` | Unzipping drops the executable bit | `chmod +x start_termux.sh` |
| `bad interpreter: .../python3.13` | Termux upgrade left a stale `pip` script | `pkg reinstall python`, then use `python -m pip …` |
| `cryptography` stuck on *Installing build dependencies* | pip is compiling Rust from source | `pkg install python-cryptography`, use `--system-site-packages`, or use `requirements-termux.txt` |
| `maturin failed: Failed to determine Android API level` | Rust build backend cannot detect the SDK level | `export ANDROID_API_LEVEL=24` before installing (24 is Termux's minimum, valid on every device) |
| `pydantic-core` wants to compile | No Android wheel on PyPI for this Python version | Set `ANDROID_API_LEVEL=24` and let it build (slow, one time). There is no `python-pydantic-core` package in Termux's main repo |
| `Failed building wheel for grpcio` | `grpcio` does not build cleanly on Android; needed by `firebase-admin` | `pkg install python-grpcio c-ares` and use `--system-site-packages`. If unavailable, use `requirements-termux.txt` (FCM push off) |
| `client_loop: send disconnect` kills the server | SSH session dropped | Run inside `tmux`; add `ServerAliveInterval 30` to your SSH config |
| `WARNING: Exceeded concurrency limit.` repeating | `limit_concurrency` is below what one screen opens, so uvicorn answers 503 instead of serving thumbnails and transcripts | Update the server (the phone default is now 64). To rule it out entirely: `LOCALCHAT_MAX_CONCURRENCY=0 ./start_termux.sh` |
| Need to see what the app requested | Low-memory mode turns the access log off | `LOCALCHAT_ACCESS_LOG=1 ./start_termux.sh` |

`requirements-termux.txt` omits `cryptography` and `firebase-admin`. Chat, media, receipts and
WebSockets all still work — only FCM push wake-ups are disabled, and `app/fcm.py` degrades
gracefully when `firebase_admin` is missing. JWTs use HS256 (HMAC), which needs no crypto backend.

The banner prints **Tailscale** URLs first when a `100.64.0.0/10` address is detected, for example:

```text
 Tailscale (use this when phones are not on the same Wi‑Fi):
   http://100.71.32.92:8000
 Flutter app → Set server URL to:
   http://100.71.32.92:8000
```

Keep Termux open (or use a wake lock) while chatting.

### B) Windows / PC server

```powershell
cd server
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
python run.py
```

Or `server\start.bat`.

If clients use **LAN** only, allow the firewall once:

```powershell
netsh advfirewall firewall add rule name="LocalChat" dir=in action=allow protocol=TCP localport=8000
```

For Tailscale-only clients, the Tailscale interface is enough; still keep `HOST=0.0.0.0` (default).

The startup banner is deliberately plain ASCII. A Windows console on a legacy
code page cannot encode a character such as an em dash, and the resulting
`UnicodeEncodeError` killed the server before uvicorn ever started — printing a
nicer dash is not worth a server that will not boot on someone else's PC.

`run.py` also checks the port itself before handing over to uvicorn, which
swallows the bind error and logs its own one-liner. That is why "Port 8000 is
already in use", with the commands to find the offender, now actually appears.

### Run tests and lint

```powershell
cd server
.\.venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt
pytest -v
pylint app run.py reset_password.py tests
```

Install `requirements.txt` **inside the venv** — `firebase-admin` lives there, and the IDE reports
import errors in `app/fcm.py` if you install it against a different interpreter. Lint rules live in
`server/.pylintrc`.

### Smoke-test a real running server

`pytest` calls the app in-process. This starts the actual server on a socket,
opens real websockets, and walks a day of use — sign up, chat, edit, delete,
upload and download, disappearing timers, admin claim, device trust, force
logout, password change — checking what the activity log says about each. It runs
against a throwaway database, so it never touches a server you are using.

```powershell
# From the repo root
server\.venv\Scripts\python tools\live_smoke.py
```

It prints one line per check and exits non-zero if any of them fail, which makes
it the last thing worth running before building a release.

### Data on disk

| Path | Purpose |
|------|---------|
| `server/data/chat.db` | SQLite database |
| `server/media/` | Uploaded images/files/voice notes |
| `server/jwt_secret.txt` | Auto-generated JWT secret (do not commit) |

---

## 2. Flutter Android app

### Build a shareable APK

```powershell
cd flutter_app
flutter pub get
flutter build apk --release
```

APK: `flutter_app\build\app\outputs\flutter-apk\app-release.apk`  
Or the smaller phone build: `app-arm64-v8a-release.apk`.

Release builds are signed with the keystore named in `android/key.properties` (never committed). Without that file — a fresh clone, someone else's machine — the build still succeeds using the debug key. Keep the keystore: an APK signed with a different key will not install over an existing one.

### First launch on each client phone

1. Tailscale app = **Connected**
2. Open Local Chat → set server URL if prompted → **Register** once
3. Next launches open the **chat list** directly while signed in
4. Inbox ⋮ → **Server settings** / **Appearance** / **Backup & restore** / **My invite QR**
5. **Logout** only if you want to switch accounts on that phone

### When the app can't reach the server

The gate screen names the actual problem instead of always blaming Tailscale. `ConnectivityService.check()` treats `GET /api/health` as the only proof of "working", then inspects this phone's own IPv4 addresses to explain a failure:

| What the app finds | What it shows |
|--------------------|---------------|
| Health check answers | Nothing — you go straight to your chats |
| No non-loopback address at all | **This phone is offline** — turn on Wi-Fi or data |
| No `100.64.0.0/10` address, server is a Tailscale IP | **Tailscale is not connected** — Connect Tailscale / Open Tailscale |
| Tailscale address present, health check fails | **Chat server is not running** — start `python run.py` on the server phone |
| Saved URL isn't a valid address | **Server address looks wrong** — with a shortcut to change it |

Each state lists numbered steps and shows the address it tried, so "connect to Tailscale" never appears while Tailscale is already up.

**Soft auto-connect (Android):** when the server URL is a Tailscale `100.x` address, Local Chat sends Tailscale's `CONNECT_VPN` broadcast on cold start, on resume, and when a notification opens the app (same path). That is the same intent Tasker uses — it asks Tailscale to connect; it cannot grant VPN permission or sign the user in. The gate also has **Connect Tailscale** (broadcast + short poll) and **Open Tailscale app** for the cases where the OEM killed Tailscale's process. Keep Tailscale's battery usage **Unrestricted** so the receiver stays alive.

The health check is the only proof of "working", and a fresh VPN interface can exist a second or two before it actually routes. So while the link is coming up the gate shows a neutral **Connecting privately…** screen rather than guessing — the old build briefly claimed "Chat server is not running" and then corrected itself on the next poll. Checks also run every 3s while the link is down (12s once it is up), so the app unlocks as soon as the tunnel is usable, and **Open Tailscale app** appears if it takes longer than 5s.

**Auto-disconnect on close.** Server settings has two switches (both on by default):

| Switch | What it does |
|--------|--------------|
| Connect when the app opens | The soft auto-connect described above |
| Disconnect when the app is closed | Sends `DISCONNECT_VPN` on a real close, or after about 30 seconds in the background; a process-death-safe fallback follows around 45 seconds |

The tunnel is only switched off when **Local Chat is what switched it on** — a tunnel you enabled yourself (or one another app needs) is left running. Server settings spells out which case you are in, and has **Disconnect Tailscale now** for a manual drop.

Ownership is an explicit native-backed state machine. Android records
`pendingConnect` atomically *before* broadcasting `CONNECT_VPN`; a later health
check promotes it to `owned` only when routing was down at the request and then
appears. Native preferences remain authoritative after the Dart isolate or
process dies, so a dead process cannot reclassify a tunnel the app opened as a
pre-existing one.

| What the check sees | Who owns the tunnel |
|---------------------|---------------------|
| Tunnel down | Nobody — a stale claim is released here |
| Came up after our pending `CONNECT_VPN`, having been unrouted when we asked | Ours |
| Up, and native state already records it as owned | Still ours, including after process loss |
| Up, and we never asked — or it was already up when we asked | Yours; it survives the app closing |

The connect and ownership predicates now use the same routing evidence. This
fixes the regression where Local Chat sent the connect request after a
`serverDown` result but never opened an ownership claim, so closing the app left
behind the tunnel it had actually raised. A tunnel already routing before the
request is never adopted.

**Disconnect Tailscale now** also pauses auto-connect for the rest of the session. Without that pause the health poll — which runs every 3s while the server is unreachable — asked Tailscale to reconnect a second later, so the button looked like it did nothing and the app silently re-claimed the tunnel. Tapping **Connect Tailscale**, or reopening the app, resumes automatic connecting.

Because swiping the app away kills the Dart isolate mid-broadcast, disconnect is
native. `TailscaleGuardService` starts while the activity is resumed, watches
the shared foreground clock, and sends `DISCONNECT_VPN` after about 30 seconds
out of sight — while the process is still likely alive, rather than waiting for
a later Recents swipe that may have nobody left to hear it. `onTaskRemoved` and
`MainActivity.onDestroy` are immediate paths for an earlier real close; neither
cuts a live call.

Android can still reap a cached process before the guard decides. Therefore
`onStop` also arms `TailscaleIdleExit` for about 45 seconds. Its manifest receiver
can restart the process, re-read the native ownership state, and send the
disconnect even if the activity and service are gone. The alarm stays armed
after the guard's best-effort broadcast, providing one later delivery retry
because Tailscale does not acknowledge the intent. Coming back cancels it; a
call in progress or a window on screen when it fires sets it again rather than
cutting the tunnel out from under either. Nothing is lost by the early
disconnect: the WebSocket is already dropped on background, and push wake-ups
travel over ordinary internet. Every decision is logged under the
`TailscaleExit`, `TailscaleGuard`, and `TailscaleIdleExit` tags:

```powershell
adb logcat -s TailscaleExit TailscaleGuard TailscaleIdleExit
```

FCM notifications are unaffected: pushes arrive over ordinary internet, not the tunnel, and tapping one reconnects Tailscale on the way in.

### Notifications (privacy mode 1a)

- **Foreground:** the WebSocket delivers the message, and the app draws a local notification with the sender name and a preview. That preview is built on-device and never leaves the phone.
- **Background / killed:** the app drops its WebSocket when Android backgrounds it, so the server sees the device as away and sends a high-priority FCM data push with a 12-hour TTL. The background entry point is registered before `runApp`, allowing Android to start it when the UI isolate is gone.
- **Locally renamed senders:** the data push includes both `sender_username` and the server display name. The background isolate reads `contact_aliases_v1` and posts the notification under the private name saved on that phone, falling back to the server name.
- **Content is never pushed.** The push holds only sender identity plus conversation and message ids. The body is fetched over Tailscale when the chat is opened.

A server-rendered FCM `notification` block cannot read private storage on the receiving phone, so it cannot show a local nickname. Notifications are therefore rendered by the app's background isolate. Android will still suppress all app notifications after the user explicitly **Force stops** the app; reopening it clears that OS restriction.

**Server FCM setup (optional):** place `server/firebase-service-account.json` (or set `LOCALCHAT_FIREBASE_CREDENTIALS`). Without it, WS + local notifications still work when the app is open/online on the mesh. Tokens that FCM reports as dead are deleted from `device_tokens` automatically, and the app re-registers whenever FCM rotates its token.

**ColorOS / MIUI / One UI:** these skins kill background apps aggressively. On each client: Settings → Apps → Local Chat → **Allow background activity** / **Auto-launch**, and set battery usage to **Unrestricted**. Also leave notifications enabled for the *Messages* channel.

### Attachments

- **Attach → Gallery** opens an in-app Recent grid (multi-select, camera shortcut).
  Documents still use the system file picker.
- Photos show an inline preview in the bubble; tap to open full screen (pinch to zoom), with **save** and **share** in the app bar.
- A preview keeps the picture's own proportions, between a wide 1:0.56 and a tall
  1:1.45. Anything more extreme — a full-length phone screenshot, say — is
  cropped to the top of the frame rather than squeezed into it, and is whole
  again full screen. Previews are decoded to the width of the bubble, so a 12 MP
  photo costs a thumbnail's worth of memory.
- A photo, video or drawing arrives with its **pixel size** already on the
  message, so the row is the right height from the first frame it is painted in.
  The server reads the size straight out of the file header — a few dozen bytes,
  no imaging dependency, Exif rotation accounted for — and caches it
  (`server/app/image_shape.py`). Without it a preview opened at a guessed shape
  and resized once the bytes landed, which shoved everything above it: a picture
  scrolling into view was enough to make the whole transcript jump. A size the
  server could not read is still measured on the phone as before, so nothing
  depends on it.
- Files show a coloured type badge, name and size; tap downloads once and opens with the phone's own app for that type.
- Voice notes play inline with a scrubbable progress bar; only one plays at a
  time. Lengths are remembered per clip: Android announces a duration when a
  file is *prepared* and says nothing when the same file is prepared again, so a
  replay used to read `0:01 / --:--` with a bar that never filled while the audio
  played on. The length is now asked for outright after playback starts, and an
  idle clip shows how long it is instead of a bare label.
- **Large files say what they are doing.** A single attachment now reports its
  own bytes while it uploads (`Sending 84 MB of 322 MB (26%)`), not just a file
  count — a two-minute phone video used to upload with nothing on screen at all,
  which is indistinguishable from a **Send** that never registered. A pick that
  has to be copied out of the gallery first shows a *Preparing attachment…*
  barrier, and a pick Android refuses to hand over says so instead of quietly
  disappearing.
- **The size limit is known before the upload, not after it.** The app asks
  `GET /api/system/limits` and refuses an oversized file on the phone, naming
  both numbers ("That video is 322 MB. This server accepts attachments up to 1
  GB"). The old build offered no limit and no explanation: it uploaded into a
  cap it could not see and dropped the answer.
- **The cap itself is sane for video.** Attachments are streamed to disk in
  small chunks and never held in memory, so RAM was never what the old 25 MB
  phone-server limit protected — free space is. That is now enforced directly:
  1 GB per file (512 MB in low-memory mode), and never within 1 GB of filling
  the host's disk, whichever is lower. Override with `LOCALCHAT_MAX_MEDIA_MB`
  and `LOCALCHAT_MEDIA_DISK_FLOOR_MB`.
- **An upload is timed by progress, not by the clock.** Anything over 8 MB has
  no wall-clock deadline; it is abandoned only after 45 seconds with no bytes
  moving. A three-minute ceiling used to cancel perfectly healthy sends of large
  video part way through.
- **Long-press any attachment** for Open / Save to phone / Share. Saving uses the Android system save dialog, so no storage permission is ever requested.
- Downloads are cached under the app's support directory, so a photo is fetched from the server only once.
- Chat ⋮ → **Media, links, and docs** opens a WhatsApp-style gallery (Media / Docs / Links tabs, grouped by month). Items load from the server index — whether or not you saved them locally. **Show in chat** (long-press, or the chat icon) jumps back to the exact bubble.

### Calls

- Voice and video calls run over WebRTC on the Tailscale mesh (no TURN in this build).
- Background / locked phone: a **Calls** notification channel heads-up alert — tap to open the in-app call UI (no full-screen lock-screen intent).
- The caller hears a ringback from the moment the call is placed, and the screen
  says where the invite got to: **Calling…**, then **Ringing their phone…** when
  the server delivered it live, **Waking their phone…** when it had to go by
  push, **Ringing…** once the other phone acknowledges, and **Can't reach
  \<name\>** when there is no socket and no push destination — where the tone
  stops, because that silence is the answer. Incoming calls use the system
  ringtone and vibration.
- Missed or interrupted invites are recovered from a short-lived pending-call store when the app returns online.
- Call notifications resolve the recipient's private saved alias, just like
  message notifications.
- Voice defaults to earpiece, video to speaker; the in-call route control offers
  earpiece, speaker, and Bluetooth when Android reports them.
- The server finalizes each call exactly once. Transcript rows include outcome,
  connected duration, and who ended an answered call; remote hangup closes the
  call screen instead of leaving a black spinner.

### Starred messages

- Long-press any text, photo, video, voice note, or file → **Star** /
  **Unstar**. Stars are private to you and stored on the server.
- Inbox ⋮ → **Starred messages** lists newest-starred-first; tap to open the chat and jump to the bubble.
- The starred screen is live: starring or unstarring in a chat updates it
  immediately without leaving and reopening the screen.
- Soft-deleted messages keep a tombstone in the starred list; hide-for-me removes the star.
- Encrypted backups (format **v3**) include `starred_message_ids` and re-apply them on restore.

### Appearance and chat position

- Inbox ⋮ → **Appearance** → System / Light / Dark (saved on the phone until uninstall)
- Chat surfaces, cards, fields, sheets, dialogs, bubbles, and the composer use theme-aware colours
- A conversation opens *anchored* on its newest message: the transcript is built bottom-up (a reversed list), so offset zero **is** the newest bubble and there is no catch-up scroll to watch. A late image decode, a restored draft or a loaded older page all grow the list away from that anchor instead of moving it.
- Swipe a bubble right (or long-press → Reply) to quote and reply, WhatsApp-style; tap a quote to jump back
- Starting a reply raises the keyboard straight away — swiping is already a decision to type, so there is no second tap on the field. Focus is asked for after the frame that inserts the draft bar (the reply fires mid-swipe, while the composer is still moving down a slot), and the keyboard is then requested from the platform outright: Android will happily hold focus in a field with the IME hidden, and `requestFocus` is a no-op when the field is focused already — after you dismissed the keyboard with the back button, say
- Opening the keyboard shifts the transcript up with it, so the newest bubbles never hide behind it — the bottom anchor does this on its own, with no offset arithmetic to get wrong. Replying to an older message keeps that message in view instead of jumping to the bottom
- A message arriving while you are reading history holds your place: the new bubble is added at the anchor, and the offset moves by exactly how much the list grew. The geometry lives in `flutter_app/lib/chat_scroll.dart` and is covered by `test/chat_scroll_test.dart`
- Scrolling stays smooth because rows settle *before* they are read: media
  reserves its height from the size sent with the message (above), and roughly a
  screen of rows beyond the viewport is kept laid out so a bubble is measured —
  and its picture already resolving — by the time it arrives. A tighter window
  saved a little memory and paid for it in stutter.
- Android Back from any chat always resets to the Chats list, including chats
  opened from search, stars, notifications, or shared media; notification taps
  cannot stack duplicate chat routes.

### Emoji-only messages

A message that is nothing but emoji reads as a picture, not as text, so it is
drawn the way WhatsApp draws it: **1–3 emoji lose the bubble entirely and grow to
60 / 52 / 48 px**, 4–6 stay in a bubble at 24 px, and anything longer falls back
to normal 15 px text. Mixing in a single letter (`ok 👍`) keeps it a text
message, and a reply quote keeps its bubble so the quote still reads clearly.

Skin tones, joined sequences (`👨‍👩‍👧‍👦`), flags, and keycaps count as **one**
emoji each — the same as what the eye sees. The detection lives in
`flutter_app/lib/emoji.dart` and is covered by `test/emoji_test.dart`.

A **single** emoji uses an expressive Google Messages/RCS-style motion system:
an 880 ms anticipation, spring, recoil, counter-wobble, settle and hold sequence
keeps alpha, scale, landing, drift and rotation synchronized. Three short ambient
cycles follow. Hearts use a double heartbeat; butterfly, balloon and dove emoji
follow a lifted flutter path; sad emoji stretch, droop, and tremble. Two or more
emoji read as a sentence rather than a reaction, so they stay still.
The entrance plays once per message — keyed by client id, so a sent
message does not bounce again when the server id lands, and scrolling back over
a chat does not set old emoji off — and a tap replays it. Phones set to reduce
motion get the emoji without the bounce. See
`flutter_app/lib/widgets/animated_emoji.dart` and
`test/emoji_rendering_test.dart`.

### Emoji that the phone's own font does not know

A phone only knows the emoji its Android version shipped with, so anything newer
arrived as an empty box — while the keyboard still offered it, because Gboard
draws its own glyphs and never asks the app's fonts. The app therefore carries
**Noto Color Emoji** (`flutter_app/assets/fonts/NotoColorEmoji.ttf`, a CBDT
colour-bitmap font Impeller renders on Android) and lists it as the fallback
behind every text style in the theme — so the composer, the bubbles, the chat
list previews and every dialog resolve the same glyph on every phone. It costs
about 10 MB in the APK, which is the price of an emoji looking like an emoji.

Notification text is drawn by Android, not by the app, so a very new emoji can
still show as a box there.

### Renaming people

Usernames and self-chosen display names are often useless ("Faye" tells you nothing), so any person can be renamed on your own phone:

- **Chat screen** → ⋮ → **Rename this person** (or tap the name in the app bar)
- **Chat list** → long-press a direct chat
- **New chat** → the rename button beside a saved contact
- **Group** → open the member list and tap a member

The name you pick replaces theirs everywhere on that phone — chat list, chat header, group bubbles and notification titles — while their real name stays visible as `@username · really Faye` so you can still tell who they are. Clearing the field, or **Use real name**, restores what they chose.

Names live in `SharedPreferences` (`contact_aliases_v1`) next to your local contacts, are never sent to the server as plaintext, and travel inside the encrypted backup (`contact_aliases`, backup format v2+), so restoring on a new phone brings them back. Restores of older v1 backups still work — they simply carry no names.

### Times and "last seen"

Timestamps are stored in UTC and shown in the phone's own time zone and clock format:

- The server tags every timestamp as UTC (`2026-08-11T05:53:12Z`). SQLite drops the time zone, so a naive value used to be sent instead, and Dart reads a zone-less string as *local* time — an 11:23 IST message was shown as 05:53.
- The app parses anything without a zone marker as UTC (`parseServerTime`), so it also corrects an older server.
- Clock times follow the phone's 12/24-hour setting, so 12-hour phones now show `5:53 PM` rather than a bare `05:53`.
- "last seen" spells out the day: *just now*, *5 minutes ago*, *today at 5:53 PM*, *yesterday at 5:53 PM*, then a weekday or date.
- A disappearing message's expiry is spelled out the same way — *Disappears today at 5:53 PM*, *tomorrow*, a weekday, then a date — in the reader's own zone, so the timer icon is never the only thing you have to go on.

### App and notification icons

Both come from `flutter_app/assets/branding/chat.png`. After changing that file:

```powershell
python tools\generate_icons.py
```

This writes the legacy launcher icons, the adaptive icon layers (foreground + Android 13 monochrome), and the status-bar icon. The status-bar icon has to be a silhouette — Android masks the small icon, so the colourful logo would appear as a white blob — so the script rebuilds the bubbles from the logo's alpha channel and punches the three dots back out.

**App FCM setup (optional):** create a Firebase project → download `google-services.json` into `flutter_app/android/app/`. The Gradle plugin applies only when that file exists.

### Forgotten login password

Login passwords are bcrypt hashes — they **cannot be recovered**, only replaced.

**If the user still knows their current password:** Inbox ⋮ → **Change password**.

**If they forgot it:** you (the server admin) reset it on the Termux/PC that
holds `data/chat.db`. From the `server/` folder with the venv active:

```bash
python reset_password.py              # list usernames
python reset_password.py alice        # type a new password privately
```

**On a Windows host using the release zip, no Python needed:**

```text
.\ResetPassword.exe
.\ResetPassword.exe THEIR_USERNAME
```

They can sign in with the new password immediately — no server restart needed.
Every previously signed-in device for that account is signed out (token version
bump). Chat history is unchanged.

### Admin break-glass (operator)

```bash
python set_admin.py                   # show admin + trusted device pin
python set_admin.py DDas              # appoint @DDas
python set_admin.py DDas --clear-device
python set_admin.py --bump-all        # sign everyone out everywhere
```

Windows release zip also ships `SetAdmin.exe`. Environment
`LOCALCHAT_ADMIN_USERNAME` still wins over the database when set.

### Encrypted backup / restore

1. Inbox ⋮ → **Backup & restore**
2. Choose a strong backup password (used only on-device for AES-GCM)
3. Ciphertext is stored on your private server (`PUT /api/backup`) and optionally mirrored to Firestore (`encrypted_backups/{username}`)
4. Restore decrypts on-device, restores local contacts **and the names you gave people**, re-stars messages from format v3 backups, reopens DMs, and hydrates cached history

Firestore never receives plaintext. You can also share the encrypted `.json` file from the backup screen.

### Cleartext HTTP

`usesCleartextTraffic="true"` so `http://100.x.x.x` and `http://192.168.x.x` work without HTTPS.

### Flutter checks

```powershell
cd flutter_app
flutter analyze
flutter test
```

### Manual device checklist (release)

On both client phones:

1. **Tailscale ownership** — test app-owned disconnected→connected→close and
   pre-existing-connected→open→close; only the first tunnel must disconnect.
   Repeat after swiping Local Chat from Recents and after a process restart.
2. **Calls** — place audio + video foreground/background/locked; verify local
   alias in the alert, ringtone/vibration, ringback only after Ringing, no black
   hangup screen, one transcript row, correct ended-by text, and
   earpiece/speaker/Bluetooth routing. Test reject/cancel/no-answer/offline.
3. **Gallery/captions** — review, reorder, remove, and caption single/multiple
   photos, videos, and documents; only the first batch item gets the caption.
4. **Bottom/navigation** — a photo-heavy chat opens on the newest bubble;
   keyboard, older pages, and late image loads do not move it; every chat Back
   path lands on Chats.
5. **Stars** — star/unstar text and every attachment type; the open starred
   screen updates immediately; backup restore re-applies stars (v3).
6. **Inbox/profile** — latest outgoing clock/single/double/read ticks match the
   chat; self and contact profiles edit/show the right identity; long last-seen
   text scrolls horizontally.
7. **Presence** — typing replaces inbox preview and chat subtitle; online /
   last-seen / mood priority; typing clears after ~4s or socket drop.
8. **Emoji** — send a brand-new emoji (for example 🫩): it renders in composer
   and bubble; one emoji plays its expressive entrance/idle motion and replays
   on tap, while two remain still.
9. **Nudge history** — send and receive each variant; Chat ⋮ → **Nudge history**
   shows `You …` vs `<alias> … you` (groups name the sender); foreground and
   background alerts use the exact verb (wave/poke/hug/kiss).
10. **Realtime sync** — with a chat open, send from the other phone while the
    WebSocket drops (airplane mode briefly) or after a stale load; the bubble
    appears without leaving/reopening. Repeat after resume from background and
    after a foreground FCM while the chat is open.
11. **Doodles** — start a live session: peer sees strokes in real time; undo,
    clear, and cancel end the overlay; **Send** posts a `Drawing` bubble that
    previews as Drawing in inbox/stars/quotes; star/reply/delete behave like
    photos. Doodle mode disables double-tap nudge; unavailable copy shows when
    the socket is down.
12. **No false empty states** — on a slow or throttled network, cold-start the
    app and open a chat with history: the chat list and transcript show stand-in
    rows and never flash "Say hello to …" or the start-your-first-chat prompt.
    Check starred, nudge history, shared media, and My uploads the same way.
13. **Jump and highlight** — from Starred, a tagged/quoted reply, the pin banner,
    global search, and **Show in chat**, confirm the transcript lands on the
    exact message (not merely nearby) and that it flashes a highlight for both
    text and attachment/drawing rows, including far back in a photo-heavy chat.
    A message hundreds of rows back should arrive in one hop rather than after
    seconds of visible paging, and the band must still be lit on arrival. Tapping
    a second starred row while one jump is walking must not start a tug of war.
14. **Unread hand-off** — with the app open on Chats and again with it in the
    background, receive two or three messages, then open the chat from its tile:
    every new message must be there on the first open and the badge must clear
    without restarting the app.
15. **Leaving a call** — after Accept/Decline, after the peer hangs up, and after
    ending the call yourself, the call screen closes on its own; Android back
    also leaves it. Mute/End labels stay visible while the system's
    screen-recording notice is on screen.
16. **Cold start** — from a full stop (swiped from Recents), launch on both light
    and dark themes: the window stays on the brand colour into the app, with no
    black frame and no lone spinner, and the gate says "Connecting privately…"
    rather than blaming Tailscale while the tunnel comes back.
17. **Wallpaper framing** — pick a wide photo and a tall one: pinch and drag to
    frame each against the bubble preview, adjust dim, then Set wallpaper. The
    chat shows exactly the framing that was on screen, for everyone in it. The
    gallery grid itself must offer no Send or Preview action and no videos —
    choosing a wallpaper is not sending an attachment.
18. **Server status** — open it from the inbox menu on both hosts you use. A
    Termux phone reports RAM, battery and both uptimes; a Windows host reports
    RAM, disk and server uptime and simply omits battery. Unplug the server
    phone and let it drop under 30% to see the warning, then plug it back in.
19. **Notification clears itself** — have the peer send while the app is closed,
    then read the chat on the other device (or open and leave it here). Pull the
    inbox down: the alert must disappear from the shade without opening the chat
    again, and the icon badge must go with it.
20. **Tunnel switches off on its own** — connect by opening the app, minimise it,
    then leave it alone for a good while (long enough for Android to trim it) and
    close it from Recents. Tailscale must end up disconnected within about a
    minute, whether the app was still alive or not. Repeat during a call: the
    call must never lose the tunnel.
21. **Anniversary and streak** — every DM's ⋮ menu shows the entry, reading
    "Off". Set a date: the countdown appears in that chat only. Open a chat with
    a parent and confirm nothing about couples shows there. Turn it off again and
    the banner and streak go, while the date stays for next time.
22. **Activity log (admin)** — sign in as the admin (`DDas`) and open Activity log
    from the inbox menu. Send, edit, then delete a message; each shows up newest
    first, with the edit holding both versions and the deletion holding what was
    removed. Filter by Deletions, search a word, scroll back for older pages, and
    copy an entry. Sign in as anybody else: the menu entry is absent, and the
    screen (if reached) says whom to ask. Nothing anywhere offers to delete an
    entry.
23. **A long video actually sends** — record two minutes or so on the phone
    camera (a few hundred megabytes) and send it. A *Preparing attachment…*
    barrier appears while the gallery hands the file over, then the composer
    counts real bytes and a percentage the whole way up, and the video arrives
    playable. Nothing may sit silent after **Send**. Then set
    `LOCALCHAT_MAX_MEDIA_MB=10`, restart the server and try the same clip: it is
    refused instantly, on the phone, naming its size and the limit — no upload
    is attempted. Fill the server's disk to within a gigabyte to see the
    out-of-room wording instead.

---

## API overview

| Method | Path | Notes |
|--------|------|--------|
| POST | `/api/auth/register` | `{username, password, display_name?}` |
| POST | `/api/auth/login` | `{username, password}` |
| POST | `/api/auth/change-password` | `{current_password, new_password}` (signed in) |
| GET | `/api/auth/me` | Current user |
| GET | `/api/users?q=` | Search users |
| GET | `/api/users/by-username/{username}` | Lookup |
| GET | `/api/conversations` | Inbox |
| POST | `/api/conversations/dm` | `{user_id}` |
| POST | `/api/conversations/groups` | `{title, member_ids}` |
| GET | `/api/conversations/{id}/messages` | History; optional `after_id` for incremental sync |
| GET | `/api/conversations/{id}/messages/window` | History reaching from `message_id` up to `up_to_id`, for jumping to a starred or quoted message in one request |
| GET | `/api/conversations/{id}/nudges` | Paginated nudge history (not in transcript) |
| GET | `/api/conversations/{id}/shared` | Media / Docs / Links index |
| POST | `/api/conversations/{id}/messages` | Send text |
| POST | `/api/conversations/{id}/media` | Multipart upload (`type=doodle` for PNG drawings) |
| GET | `/api/media/{message_id}` | Download media |
| POST | `/api/conversations/{id}/read` | Mark read |
| POST | `/api/devices` | Register FCM token |
| PUT/GET | `/api/backup` | Ciphertext only |
| GET | `/api/messages/starred` | Private starred messages (newest star first) |
| PUT/DELETE | `/api/messages/{id}/star` | Star / unstar |
| GET | `/api/system/storage` | Free/total space on the media volume |
| GET | `/api/system/limits` | Largest attachment acceptable right now (cap vs. free space), asked before an upload starts |
| GET | `/api/system/info` | Host health: platform (Termux/Windows/…), RAM, disk, battery, uptime |
| GET | `/api/admin/status` | Who the admin is; whether this account is one or may appoint one; trusted-device flags |
| PUT | `/api/admin/username` | `{username}` — claim (self only while unclaimed) or hand over the admin role |
| PUT | `/api/admin/device` | `{clear}` — trust this phone for the activity log, or clear the pin |
| GET | `/api/admin/online` | Users with a live websocket (admin + trusted device) |
| POST | `/api/admin/users/{id}/force-logout` | Invalidate every JWT for that account and close sockets |
| GET | `/api/admin/audit` | Activity log, newest first; `before_id`, `category`, `action`, `actor`, `conversation_id`, `message_id`, `q` (admin + trusted device) |
| GET | `/api/admin/audit/summary` | Totals, last 24 hours, edits, deletions, oldest entry (admin + trusted device) |
| WS | `/ws?token=<jwt>` | Realtime events (messages, nudges, live doodles, call signaling + `call.ringing`) |

### Error responses

Every error, including validation failures, returns a single readable sentence:

```json
{ "detail": "Username must be 3 to 40 characters, using only letters, numbers, underscores or hyphens." }
```

FastAPI's default 422 body is a list of machine-readable dicts, which is unusable
in a phone UI. `app/errors.py` rewrites all of them (validation, `HTTPException`,
and unexpected 500s) into that one shape, so the app can display `detail` as-is.
Unexpected errors are logged in full on the server and reduced to a calm sentence
for the client.

A rejected token on the WebSocket is a special case: the app signs the user out
on close code **4401** and would otherwise retry a dead token forever behind a
"Reconnecting…" banner. Refusing the connection before the handshake makes the
server answer plain HTTP 403 instead, which carries no close code at all, so
`/ws` accepts the socket and *then* closes it with 4401. Both halves of that
contract are tested (`tests/test_integration_ws.py`,
`flutter_app/test/realtime_auth_test.dart`).

---

## GitHub Releases (APK + Windows server)

**Current app version:** `1.8.3+36` (the activity log now names the people in an
entry from what the server recorded at the time — who sent the message, who else
was in that chat, and who removed it — so no entry can read as though you sent a
message to yourself; a sealed entry opens as soon as the key for that chat is
available instead of only after the chat has been visited; plus the 1.8.2
additions: the log reads as human sentences with local reveal for the admin's own
chats, admin access is account + trusted device + force-logout, and large uploads
hold Tailscale while sending and retry on drop;
plus the 1.8.1 additions: large video sends work and show their own
progress, the attachment limit is known before an upload rather than after it,
plus the 1.8.0 additions: a server-side activity log with an admin screen in the
app, notifications that clear themselves once nothing is unread, a tunnel that
switches off without the app's help, and the anniversary option back in every
one-to-one chat's menu).

Prebuilt downloads are meant for people who do not want to compile anything.

```powershell
# From the repo root, with Flutter + server\.venv already set up:
powershell -ExecutionPolicy Bypass -File tools\build_release.ps1
```

That writes:

| File | Who it's for |
|------|----------------|
| `releases/LocalChat-android-arm64.apk` | Almost all modern Android phones |
| `releases/LocalChat-android-arm32.apk` | Older / budget phones (armeabi-v7a) |
| `releases/LocalChat-android-universal.apk` | When you don't know the phone — bigger, runs anywhere |
| `releases/LocalChatServer-windows-x64.zip` | Windows PC host — unzip and run `LocalChatServer.exe` |
| `server-update.zip` (repo root) | Your own running Termux/Linux server — code only, no dependencies |

Skip parts of it with `-SkipApk`, `-SkipServer`, or `-SkipUpdateZip`. The Windows
zip needs `server\.venv` (PyInstaller runs inside it); everything else needs only
Flutter.

Between releases, drop the regenerable build output with:

```powershell
powershell -ExecutionPolicy Bypass -File tools\clean_workspace.ps1
```

It deletes `flutter_app\build`, `server\build`, `server\dist`, pytest caches and
`__pycache__` folders — never the venv, `server\data\chat.db`, `server\media`,
your secrets, or `releases\`. Close other builds first, or a Gradle daemon will
hold a jar and the script will say so.

Then publish:

```powershell
gh release create v1.2.0 `
  releases/LocalChat-android-arm64.apk `
  releases/LocalChat-android-arm32.apk `
  releases/LocalChat-android-universal.apk `
  releases/LocalChatServer-windows-x64.zip `
  --title "v1.2.0" `
  --notes "Install Tailscale on every device, run the server, point the APK at http://<tailscale-ip>:8000."
```

No `gh`? Open **Releases → Draft a new release** on GitHub, pick the tag you
pushed, and drag the files from `releases/` into the attachment box.

### Release signing

Release builds are signed with a real upload key, not the Android debug key.
`android/app/build.gradle.kts` reads `android/key.properties`; when that file is
absent (a fresh clone, a different machine) the build silently falls back to the
debug key so `flutter build apk --release` still works for anyone.

Create your own key once:

```powershell
keytool -genkeypair -v -keystore C:/Users/<you>/keys/localchat-release.jks `
  -keyalg RSA -keysize 2048 -validity 10000 -alias localchat
```

Then copy `android/key.properties.example` to `android/key.properties` and fill
it in. Keep the keystore **outside** the repo. Neither file is committed.

Verify which certificate an APK actually carries:

```powershell
& "$env:LOCALAPPDATA\Android\sdk\build-tools\36.0.0\apksigner.bat" verify --print-certs releases\LocalChat-android-arm64.apk
```

`CN=Local Chat` is the release key; `CN=Android Debug` means `key.properties` was
missing when you built.

**Back up the keystore and its password.** Android identifies an app by its
signature, so losing the key means every future build looks like a different app:
users would have to uninstall first, which wipes that phone's local nicknames and
cached media. For the same reason, the first build after switching from the debug
key needs a one-time uninstall on phones that already had the app.

**Important:** a Windows `.exe` does **not** run inside Termux. For an always-on Android server phone, keep using the Python sources + `start_termux.sh`. The zip is for a Windows (or later Linux) host on the same Tailscale network.

**Firebase is optional and per-deployer.** Do not commit your `google-services.json` or service-account JSON. Copy the `.example` files and fill them from your own Firebase console if you want background FCM. Chat over Tailscale still works without Firebase while the app is online.

### Secrets checklist before `git push`

| Keep local only | Commit the example instead |
|-----------------|----------------------------|
| `server/jwt_secret.txt` | (auto-created on first run) |
| `server/firebase-service-account.json` | `server/firebase-service-account.json.example` |
| `flutter_app/android/app/google-services.json` | `…/google-services.json.example` |
| `server/data/chat.db`, `server/media/*` | empty `.gitkeep` folders |
| `flutter_app/android/local.properties` | (machine SDK paths) |
| `*.apk`, `server-update*.zip` | GitHub **Releases**, not the git tree |

---

## Project layout

```text
Chat/
  server/                        FastAPI app + tests
    localchat.spec               PyInstaller build for Windows
    firebase-service-account.json.example
    app/host_info.py             Host RAM / battery / uptime, read from the kernel
    app/audit.py                 Append-only record of every action, with before/after text
    app/sessions.py              Token-version bump to force-sign-out a user
    app/audit_middleware.py      Catch-all entry for a write nothing else described
    app/admin.py                 Who the admin is, and the admin-only dependency
    app/routers/admin.py         Admin status, admin designation, activity log API
    run.py                       Banner + Tailscale/LAN IP discovery
    start_termux.sh              Termux helper
    start.bat                    Windows helper
    reset_password.py            Admin password reset (on the server host)
    set_admin.py                 Operator break-glass for admin username / device pin
  flutter_app/                   Flutter Android client
    android/app/google-services.json.example
    assets/fonts/NotoColorEmoji.ttf         Bundled emoji font, behind every style
    lib/emoji.dart               Emoji-only detection for big-emoji bubbles
    lib/chat_scroll.dart         Reversed-transcript geometry (bottom anchor)
    lib/widgets/animated_emoji.dart         Single-emoji entrance, once per message
    lib/nudge_log.dart               Nudge history formatting and variants
    lib/doodle_stroke.dart           Pure doodle stroke/session models
    lib/message_merge.dart           Merge-based transcript reconciliation
    lib/services/doodle_controller.dart   Live doodle relay batching
    lib/services/doodle_export.dart  Bounded PNG flatten for sent drawings
    lib/widgets/doodle_overlay.dart  Ephemeral live doodle UI
    lib/widgets/doodle_attachment.dart    Persistent drawing bubble
    lib/screens/nudge_history_screen.dart Per-chat nudge log
    lib/screens/shared_media_screen.dart   Media / Docs / Links gallery
    lib/screens/wallpaper_crop_screen.dart Zoom/pan/dim framing before upload
    lib/screens/server_info_screen.dart    Server status card (on-demand only)
    lib/audit.dart                         Activity-log models and wording
    lib/screens/activity_log_screen.dart   Admin activity log and admin setup
    lib/services/server_health.dart        Thresholds and advice for host readings
    lib/services/tailscale_assist.dart     CONNECT_VPN / DISCONNECT_VPN requests
    android/.../TailscaleExit.kt           Disconnects the tunnel on app exit
    android/.../TailscaleGuardService.kt   Counts background time and disconnects
    android/.../TailscaleIdleExit.kt       Alarm backstop when the process is gone
  tools/
    generate_icons.py
    build_release.ps1            APKs + Windows server zip + server-update.zip
    clean_workspace.ps1          Delete regenerable build output and caches
    live_smoke.py                Drives a real running server end to end before a release
  releases/                      Local build output (gitignored except .gitkeep)
  README.md
```

## Out of scope (later)

Status/stories, full E2E for live server storage, Play Store signing, lock-screen full-screen call UI.

### "Tailscale IP not detected on this device"

Only the banner is affected — the server always listens on `0.0.0.0`, so Tailscale
clients can reach it regardless of what the banner prints.

`run.py` looks for the address four ways: reading interface addresses over
`SIOCGIFADDR`, asking the routing table which source address reaches `100.100.100.100`,
resolving the hostname, and calling the `tailscale` CLI. On Android, Tailscale runs
as a VPN app with no CLI, and unprivileged apps like Termux may be blocked from
listing the `tun` interface, so all four can come up empty.

If that happens, open the Tailscale app, confirm it says **Connected**, and use the
`100.x.x.x` address shown there as the server URL in the app.
