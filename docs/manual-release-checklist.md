# Target-device release checklist

Run this against the exact APK and archives uploaded to GitHub. Record device,
Android/Windows version, time, and pass/fail. A local test suite cannot certify
these OEM, network, hardware, or credential-dependent paths.

## Android phone 1: primary/admin

- Install as an update without clearing data; confirm chats, aliases, app-lock
  preference, streaks, anniversary, and Saved Messages survive.
- Cold-launch with fingerprint selected. Fingerprint opens automatically once;
  cancel stays cancelled; successful unlock does not prompt again.
- Open Settings, chats, profiles, and Activity Log, then press Back repeatedly.
  App Lock must not appear during internal navigation.
- In Activity Log, expand sent, edited, deleted, checklist, media, and call rows.
  Text is readable when this phone owns the chat key. `Sent`, `Sender`, `With`,
  and technical details are left-aligned; filter chips are not clipped.
- Send online text, checklist, image, video, voice note, reply, reaction, edit,
  and delete. No queued banner flashes for an ordinary successful send.
- Confirm delivered ticks are grey and read ticks are blue.
- Open a long chat from inbox, notification, search result, and starred result.
  The target is visible and highlighted without jumps.
- Replay a voice note twice and change speed. Progress remains correct.
- Open a shared image, video, and doodle full-screen. Tap the picture: chrome
  (caption, Save, back) hides and returns on a second tap; pinch/pan/zoom still
  work while chrome is hidden.
- Zoom a photo; inspect video thumbnail; send a file near the configured limit.
  Oversized media produces an actionable error rather than doing nothing.

## Android phone 2: peer/background behavior

- With Local Chat foregrounded, backgrounded, and killed, send one message from
  phone 1. Exactly one private notification appears; no plaintext is exposed.
- Read it and confirm the notification clears and phone 1 receives a blue read
  receipt.
- Verify locally renamed contacts appear in message and call notifications.
- Place audio and video calls both directions. Check ringback from the moment the
  caller taps Call (not only after the callee acks), vibration,
  Bluetooth/earpiece/speaker routing, overlay hide/show, hang-up, Android Back,
  and one call-log entry only. While the callee's phone is still ringing, press
  Home on the caller: the VPN icon must stay up until the call ends or fails.
  Connected calls must carry two-way audio and video; if media fails, the error
  should mention Tailscale direct (not relay-only) or ICE apply count — not a
  silent black screen. After the callee answers, video should leave
  “Connecting…” promptly; a failed media negotiation must end within the
  dedicated 18-second media window rather than inheriting the ringing timer.
- Set a mood on phone 2. The chat app bar must show only typing, online, or
  last-seen; open the contact profile and confirm the mood is still displayed.
- Chat with phone 2, then let it go offline for about a minute (still a tailnet
  member, still receiving push). Inbox must show the last message, not
  “Can't reach them”. Leave them offline for several days: still last message
  plus last-seen in the chat header — never “Can't reach them” while they remain
  authorized.
- With Tailscale membership enabled on the server, open a DM to a bound member
  whose phone is off but still listed in the tailnet admin console. Inbox must
  not say “Not on this tailnet”; `tailnet_pending` may show “Waiting for them
  to connect”. Only after the device is actually removed from the tailnet should
  sever copy appear.
- Disconnect phone 2 from the mesh and reconnect. No messages disappear; active
  chat and inbox converge without restarting the app.

## Tailscale ownership

Capture:

```text
adb logcat -s TailscaleExit TailscaleGuard TailscaleIdleExit
```

- Start with Tailscale off. Open Local Chat and let it connect. Server settings
  must not say the tunnel is "not Local Chat's to switch off"; the log must show
  `connect intent persisted` followed by `ownership claimed`, and must show no
  DISCONNECT_VPN during launch. Press Home: the VPN icon must clear within a
  couple of seconds, not half a minute. Do this on a deliberately slow link too —
  a tunnel that takes a minute or two to route must still be claimed.
- Reopen as the Local Chat admin and check More → Settings → Connection and
  server → Server and Tailscale → Recent tunnel activity. It must name the
  connect, claim, and disconnect with "left the app", with times matching the
  status bar. Sign out or use a non-admin account and verify that the Recent
  tunnel activity section is absent.
- Rotate the phone while a chat is open, and unlock with the fingerprint after
  App Lock engages: neither may disconnect the tunnel.
- Open Tailscale's own app from the connect gate: the tunnel it just brought up
  must survive the trip.
- Reproduce the 2026-08-27 23:59 recording exactly: with Server settings saying
  “Local Chat turned Tailscale on”, press Home, wait five seconds, and open
  Tailscale. It must already say Not connected, before any Recents swipe.
  Recent tunnel activity must say “Asked Tailscale to disconnect (user left the
  app)”. Then repeat by waiting 5–15 seconds and swiping Local Chat from Recents;
  Tailscale must remain disconnected.
- Repeat without swiping and wait past 45 seconds: the durable alarm must make
  the backstop disconnect attempt.
- Start with Tailscale manually connected before opening Local Chat. Leave and
  kill Local Chat after five minutes: the manual tunnel stays on.
- During a real call and a large upload, background Local Chat past 45 seconds:
  the tunnel stays up until the work ends, then disconnects.
- Disable “Disconnect when you leave”: no automatic path disconnects it.

## A large attachment while the app is not on screen

This is the case the automated tests cannot reach, because it is decided by this
phone's power management. Use a file of at least a few hundred megabytes.

- Send it, then press Home once the bar starts moving. A "Sending …" notification
  must appear with a progress figure that keeps climbing while the app is away,
  and the VPN icon must stay on for the duration.
- Come back after a few minutes: the message must be in the chat exactly once,
  and the tunnel must disconnect shortly after the send finishes and you leave.
- Repeat, and mid-send turn Wi-Fi off for around thirty seconds, then on. The
  send must continue from roughly where it stopped, not restart at 0%; the bar
  may pause and the notice may sit still while it waits.
- Repeat, and tap Cancel on the notification: sending stops within a second or
  two, no message appears, and the chat says the send was stopped. Check the
  server's `media/.partial` folder is empty afterwards.
- Repeat with the in-chat Stop button: same outcome.
- Send an album of several photos, press Home, then Cancel: files already sent
  stay in the chat, the rest do not arrive.
- Send something small (a photo under 8 MB): it must still go in one request,
  with no Stop button offered for a transfer too short to stop.

- Send a photo. The bubble shows when it will leave the server (default 30 days;
  pytest uses a minutes-scale TTL). Save it to the phone, then keep it on the
  server; after expiry the unsaved copy is a tombstone and the saved copy still
  plays from the phone.
- Long-press a DM: Delete chat (me / both) and Remove contact. Confirm copy must
  say Tailscale is unchanged. Inbox never shows "Can't reach them" for an
  authorized offline peer (last message + last-seen instead). "Removed" after a
  block.
- Revoke a share-only peer's Tailscale access (or remove their device from the
  tailnet) and wait for the server's next membership poll. They must receive no
  further message or call FCM; chat history on other phones stays, with server
  access revoked copy instead of “Removed”.

## Windows server archive

- Extract `LocalChatServer-windows-x64.zip`; do not run inside the archive.
- Double-click the EXE. A console remains visible and shows startup/access logs.
- Approve the firewall prompt or run `LocalChatServer.exe allow-firewall` as
  administrator.
- From a different Tailscale device, open `/api/system/health` and sign in from
  the APK.
- Restart the EXE and confirm accounts/messages/media persist beside it.

## Termux update archive

- Back up `data/`, `media/`, `jwt_secret.txt`, and Firebase credentials.
- Extract `server-update.zip` over the server folder. Confirm `firewall.py`,
  `run.py`, `app/`, and LF-only `start_termux.sh` are present.
- Run `chmod +x start_termux.sh && ./start_termux.sh`.
- Confirm no missing `firewall`, `uvicorn`, `aiofiles`, cryptography, pydantic,
  or grpcio import/install error.
- Confirm `/api/system/health`, WebSocket messaging, media upload/download, FCM,
  and restart persistence.

## Release sign-off

- Automated workflow passed on the exact source commit.
- APK version/build number matches README and release notes.
- SHA-256 checksums match locally built artifacts.
- All failures above are fixed or explicitly declared before publishing.
