# Local Chat

Private WhatsApp-style chat over **Tailscale** (and optionally the same Wi‑Fi LAN).

- **Python server** (FastAPI + WebSockets + SQLite) — e.g. on a phone via Termux, or a PC
- **Flutter Android app** — other phones connect using the server’s Tailscale `100.x.x.x` IP
- No public cloud for chat traffic; credentials are local username + password

Inspired by the deployment model of [local-drive](https://github.com/SiliconValley007/local-drive).

## Features

- Register / login (username + password), persistent sessions
- 1:1 DMs and group chats
- Text, images, files, and voice notes
- **Reply / quote**, **edit**, and **delete** (tombstone) for messages
- Delivery and read receipts, typing, online presence
- **Search** people, last-message text in the inbox, and messages inside a chat
- **Pin** chats and **mute** notifications per conversation (device-local)
- **Export chat** as a shareable plain-text file
- **Clickable links** in messages (opens in the browser; no silent preview fetch)
- **Unread badge** on the app icon (where the launcher supports it)
- **Reconnecting** banner in the inbox when the WebSocket drops
- **Tailscale gate** — app waits if the private server is unreachable
- **Add people** — username search, local contacts (device-only), QR invite (`localchat://user/...`)
- **Rename people** — give anyone a name only you see; saved on the phone and inside the encrypted backup
- **Notifications** — local alerts when a chat is not open; optional FCM data-only wake-ups (no message body)
- **Encrypted backup / restore** — AES-GCM on-device, ciphertext on private server + optional Firestore mirror
- **Appearance** — system / light / dark, remembered on the phone

## What this is / is not

**Ready for:** private chat across different networks via Tailscale (or same LAN), with the server device online and Tailscale Connected.

**Not a full WhatsApp replacement:** no voice/video calls, no Status/stories; live messages are stored in plaintext on your private server device. Traffic is plain HTTP inside your Tailscale/LAN mesh. **Do not expose port 8000 to the public internet.** Backups are client-encrypted so cloud storage never sees chat plaintext.

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
```

Either way, restart the server so the new code loads: attach with
`tmux attach -t localchat`, press `Ctrl+C`, run `python run.py`, then detach with
`Ctrl+b` `d`. New database columns are added automatically on startup.

**App-only updates need none of this.** When a release changes only the Flutter
app, install the new APK and leave the server running.

#### Termux troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `.venv/bin/activate: No such file or directory` | venv was created on Windows (`Scripts/`) | `rm -rf .venv` and recreate on the phone |
| `bad interpreter: .../python3.13` | Termux upgrade left a stale `pip` script | `pkg reinstall python`, then use `python -m pip …` |
| `cryptography` stuck on *Installing build dependencies* | pip is compiling Rust from source | `pkg install python-cryptography`, use `--system-site-packages`, or use `requirements-termux.txt` |
| `maturin failed: Failed to determine Android API level` | Rust build backend cannot detect the SDK level | `export ANDROID_API_LEVEL=24` before installing (24 is Termux's minimum, valid on every device) |
| `pydantic-core` wants to compile | No Android wheel on PyPI for this Python version | Set `ANDROID_API_LEVEL=24` and let it build (slow, one time). There is no `python-pydantic-core` package in Termux's main repo |
| `Failed building wheel for grpcio` | `grpcio` does not build cleanly on Android; needed by `firebase-admin` | `pkg install python-grpcio c-ares` and use `--system-site-packages`. If unavailable, use `requirements-termux.txt` (FCM push off) |
| `client_loop: send disconnect` kills the server | SSH session dropped | Run inside `tmux`; add `ServerAliveInterval 30` to your SSH config |

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

### Run tests and lint

```powershell
cd server
.\.venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt
pytest -v
pylint app run.py tests
```

Install `requirements.txt` **inside the venv** — `firebase-admin` lives there, and the IDE reports
import errors in `app/fcm.py` if you install it against a different interpreter. Lint rules live in
`server/.pylintrc`.

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

Release builds use the debug signing key (fine for private / GitHub Releases sideloading, not Play Store).

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
| No `100.64.0.0/10` address, server is a Tailscale IP | **Tailscale is not connected** — open Tailscale, connect |
| Tailscale address present, health check fails | **Chat server is not running** — start `python run.py` on the server phone |
| Saved URL isn't a valid address | **Server address looks wrong** — with a shortcut to change it |

Each state lists numbered steps and shows the address it tried, so "connect to Tailscale" never appears while Tailscale is already up.

### Notifications (privacy mode 1a)

- **Foreground:** the WebSocket delivers the message, and the app draws a local notification with the sender name and a preview. That preview is built on-device and never leaves the phone.
- **Background / killed:** the app drops its WebSocket when Android backgrounds it, so the server sees the device as away and sends a high-priority FCM data push with a 12-hour TTL. The background entry point is registered before `runApp`, allowing Android to start it when the UI isolate is gone.
- **Locally renamed senders:** the data push includes both `sender_username` and the server display name. The background isolate reads `contact_aliases_v1` and posts the notification under the private name saved on that phone, falling back to the server name.
- **Content is never pushed.** The push holds only sender identity plus conversation and message ids. The body is fetched over Tailscale when the chat is opened.

A server-rendered FCM `notification` block cannot read private storage on the receiving phone, so it cannot show a local nickname. Notifications are therefore rendered by the app's background isolate. Android will still suppress all app notifications after the user explicitly **Force stops** the app; reopening it clears that OS restriction.

**Server FCM setup (optional):** place `server/firebase-service-account.json` (or set `LOCALCHAT_FIREBASE_CREDENTIALS`). Without it, WS + local notifications still work when the app is open/online on the mesh. Tokens that FCM reports as dead are deleted from `device_tokens` automatically, and the app re-registers whenever FCM rotates its token.

**ColorOS / MIUI / One UI:** these skins kill background apps aggressively. On each client: Settings → Apps → Local Chat → **Allow background activity** / **Auto-launch**, and set battery usage to **Unrestricted**. Also leave notifications enabled for the *Messages* channel.

### Attachments

- Photos show an inline preview in the bubble; tap to open full screen (pinch to zoom), with **save** and **share** in the app bar.
- Files show a coloured type badge, name and size; tap downloads once and opens with the phone's own app for that type.
- Voice notes play inline with a scrubbable progress bar; only one plays at a time.
- **Long-press any attachment** for Open / Save to phone / Share. Saving uses the Android system save dialog, so no storage permission is ever requested.
- Downloads are cached under the app's support directory, so a photo is fetched from the server only once.

### Appearance and chat position

- Inbox ⋮ → **Appearance** → System / Light / Dark (saved on the phone until uninstall)
- Chat surfaces, cards, fields, sheets, dialogs, bubbles, and the composer use theme-aware colours
- Opening a conversation waits for its messages, then pins the transcript to the newest message
- Swipe a bubble right (or long-press → Reply) to quote and reply, WhatsApp-style; tap a quote to jump back

### Renaming people

Usernames and self-chosen display names are often useless ("Faye" tells you nothing), so any person can be renamed on your own phone:

- **Chat screen** → ⋮ → **Rename this person** (or tap the name in the app bar)
- **Chat list** → long-press a direct chat
- **New chat** → the rename button beside a saved contact
- **Group** → open the member list and tap a member

The name you pick replaces theirs everywhere on that phone — chat list, chat header, group bubbles and notification titles — while their real name stays visible as `@username · really Faye` so you can still tell who they are. Clearing the field, or **Use real name**, restores what they chose.

Names live in `SharedPreferences` (`contact_aliases_v1`) next to your local contacts, are never sent to the server as plaintext, and travel inside the encrypted backup (`contact_aliases`, backup format v2), so restoring on a new phone brings them back. Restores of older v1 backups still work — they simply carry no names.

### Times and "last seen"

Timestamps are stored in UTC and shown in the phone's own time zone and clock format:

- The server tags every timestamp as UTC (`2026-08-11T05:53:12Z`). SQLite drops the time zone, so a naive value used to be sent instead, and Dart reads a zone-less string as *local* time — an 11:23 IST message was shown as 05:53.
- The app parses anything without a zone marker as UTC (`parseServerTime`), so it also corrects an older server.
- Clock times follow the phone's 12/24-hour setting, so 12-hour phones now show `5:53 PM` rather than a bare `05:53`.
- "last seen" spells out the day: *just now*, *5 minutes ago*, *today at 5:53 PM*, *yesterday at 5:53 PM*, then a weekday or date.

### App and notification icons

Both come from `flutter_app/assets/branding/chat.png`. After changing that file:

```powershell
python tools\generate_icons.py
```

This writes the legacy launcher icons, the adaptive icon layers (foreground + Android 13 monochrome), and the status-bar icon. The status-bar icon has to be a silhouette — Android masks the small icon, so the colourful logo would appear as a white blob — so the script rebuilds the bubbles from the logo's alpha channel and punches the three dots back out.

**App FCM setup (optional):** create a Firebase project → download `google-services.json` into `flutter_app/android/app/`. The Gradle plugin applies only when that file exists.

### Encrypted backup / restore

1. Inbox ⋮ → **Backup & restore**
2. Choose a strong backup password (used only on-device for AES-GCM)
3. Ciphertext is stored on your private server (`PUT /api/backup`) and optionally mirrored to Firestore (`encrypted_backups/{username}`)
4. Restore decrypts on-device, restores local contacts **and the names you gave people**, reopens DMs, and hydrates cached history

Firestore never receives plaintext. You can also share the encrypted `.json` file from the backup screen.

### Cleartext HTTP

`usesCleartextTraffic="true"` so `http://100.x.x.x` and `http://192.168.x.x` work without HTTPS.

### Flutter checks

```powershell
cd flutter_app
flutter analyze
flutter test
```

---

## API overview

| Method | Path | Notes |
|--------|------|--------|
| POST | `/api/auth/register` | `{username, password, display_name?}` |
| POST | `/api/auth/login` | `{username, password}` |
| GET | `/api/auth/me` | Current user |
| GET | `/api/users?q=` | Search users |
| GET | `/api/users/by-username/{username}` | Lookup |
| GET | `/api/conversations` | Inbox |
| POST | `/api/conversations/dm` | `{user_id}` |
| POST | `/api/conversations/groups` | `{title, member_ids}` |
| GET | `/api/conversations/{id}/messages` | History |
| POST | `/api/conversations/{id}/messages` | Send text |
| POST | `/api/conversations/{id}/media` | Multipart upload |
| GET | `/api/media/{message_id}` | Download media |
| POST | `/api/conversations/{id}/read` | Mark read |
| POST | `/api/devices` | Register FCM token |
| PUT/GET | `/api/backup` | Ciphertext only |
| WS | `/ws?token=<jwt>` | Realtime events |

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

---

## GitHub Releases (APK + Windows server)

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

The script builds the split APKs and the Windows zip. Add the universal one with
`flutter build apk --release` when you want a single file that fits every phone.

Then publish:

```powershell
gh release create v1.1.0 `
  releases/LocalChat-android-arm64.apk `
  releases/LocalChat-android-arm32.apk `
  releases/LocalChat-android-universal.apk `
  releases/LocalChatServer-windows-x64.zip `
  --title "v1.1.0" `
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
    run.py                       Banner + Tailscale/LAN IP discovery
    start_termux.sh              Termux helper
    start.bat                    Windows helper
  flutter_app/                   Flutter Android client
    android/app/google-services.json.example
  tools/
    generate_icons.py
    build_release.ps1            APK + Windows server zip
  releases/                      Local build output (gitignored except .gitkeep)
  README.md
```

## Out of scope (later)

Voice/video calls, Status/stories, full E2E for live server storage, Play Store signing.

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
