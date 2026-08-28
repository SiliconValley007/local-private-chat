# Linked-device and web architecture

Status: **postponed**. Still the next milestone — not in `1.11.0+48`.

A 1.11 request asked to implement this document in full (QR companion pairing,
a responsive Flutter web client, Termux hosting of that site on the same host as
the chat server, and mapping `localchat.com` onto the Tailscale address). That
work was explicitly parked: it is a separate auth/E2E/session migration, and
this release instead ships media auto-expiry and disconnect/block UX without
changing Tailscale.

Logged for when it is taken up:

- One primary device; companions pair only by QR from an unlocked primary.
- Web client must stay usable at any window size.
- `start_termux.sh` would start the API **and** serve the built website so anyone
  on the tailnet can open it.
- A memorable name (`localchat.com` or Tailscale MagicDNS) instead of a raw IP —
  that needs DNS/TLS the operator actually controls.

## Product contract

- Each account has exactly one **primary** device.
- Entering the username/password on another app or browser does not silently
  create another primary session.
- A companion displays a short-lived QR code. The unlocked primary scans and
  explicitly approves it.
- Every companion has its own independently revocable session and cryptographic
  identity.
- Admin-panel trust remains pinned to one explicitly trusted primary device.
  Linked devices never inherit it.
- Removing a companion closes its sockets and invalidates only that device.
  Password change and administrative force-logout still invalidate all devices.

## Why this is a separate migration

The current server issues stateless user JWTs. Its `X-Device-Id` identifies an
installation only for admin-device trust, and the current DM encryption keeps
one peer public key per user. A second installation therefore cannot safely
decrypt the first installation's history and cannot be revoked independently.
Pretending that another password login is a linked device would weaken both the
session model and E2E guarantees.

## Device and session model

Add `user_devices`:

- `id`, `user_id`, stable `device_uuid`
- `role`: `primary` or `linked`
- `platform`, user-visible label, created/last-used timestamps
- per-device authentication `token_version`
- device signing public key and device encryption public key
- `revoked_at` and reason
- `admin_trusted`, constrained to a primary and to one server-wide device

Add `device_pairing_sessions`:

- random pairing id and expiry (maximum five minutes)
- companion device UUID/platform/label
- companion ephemeral X25519 public key
- approving primary device id
- state: `pending`, `scanned`, `approved`, `completed`, `rejected`, `expired`
- encrypted history/key-transfer bundle; deleted after completion

Keep the user-wide token version for global logout. Extend JWTs with device id,
device role, and per-device token version. Every REST and WebSocket request must
match the JWT device id to `X-Device-Id` and a live `user_devices` row.

## Pairing flow

1. The unauthenticated companion creates an ephemeral X25519 key pair and calls
   `POST /api/devices/pairing/start`.
2. It displays a QR containing protocol version, server identity, pairing id,
   companion device id, expiry, and ephemeral public key.
3. The authenticated primary scans it, verifies the server and expiry, and
   shows the companion platform/label for explicit confirmation.
4. The primary calls `POST /api/devices/pairing/{id}/approve`, signed by its
   device signing key.
5. The primary encrypts the bootstrap/history bundle directly to the companion
   ephemeral key. The server stores only opaque ciphertext.
6. The companion decrypts the bundle and calls
   `POST /api/devices/pairing/{id}/complete`; the server creates its linked
   device row and returns a device-bound JWT.
7. Both clients erase pairing secrets. Replay, expired, previously completed,
   cross-account, or non-primary approval attempts fail.

The companion may poll pairing state initially. Realtime events
`device.pairing.requested`, `device.linked`, and `device.revoked` make the UI
immediate once authenticated.

## Multi-device E2E design

Do not copy one long-lived private identity seed to every companion. That is
simpler, but it is not WhatsApp-style device isolation: compromise of one
browser would compromise the shared account identity.

Each device owns:

- a signing identity key
- an X25519 device encryption key
- prekeys uploaded to the server as public material

For each outgoing DM message:

1. Generate a random content key.
2. Encrypt the body once with AES-GCM.
3. Encrypt the content key separately for every active recipient device and
   every active sender device, including the device sending the message.
4. Store the common ciphertext plus device-key envelopes. The server can route
   envelopes but cannot open them.

This lets all sender devices retain readable sent history and all recipient
devices decrypt independently. Revocation stops future envelopes to that device
without changing other sessions. A device-list version and signature prevent a
malicious/stale server response from silently omitting or adding devices.

Existing `e2e1:` messages remain readable on the primary. During pairing, the
primary transfers a bounded recent-history bundle re-encrypted for the new
device; older history can be fetched progressively from the primary while it is
online. No plaintext or private key is persisted by the server.

Group encryption and attachment-key fan-out use the same active-device list in
later web phases. The first web milestone must not claim full parity until
those message types are covered.

## API surface

Companion:

- `POST /api/devices/pairing/start`
- `GET /api/devices/pairing/{id}`
- `POST /api/devices/pairing/{id}/complete`

Primary-only:

- `GET /api/devices`
- `POST /api/devices/pairing/{id}/approve`
- `POST /api/devices/pairing/{id}/reject`
- `DELETE /api/devices/{device_uuid}`
- `POST /api/devices/logout-others`
- `POST /api/devices/primary/transfer`

Messaging:

- fetch signed active-device lists/prekeys
- upload/fetch per-device message-key envelopes
- device-targeted WebSocket delivery

## Primary loss and recovery

- A linked device cannot promote itself silently.
- A deliberate primary transfer requires both devices online and confirmation
  on the old primary.
- If the primary is lost, password recovery creates a replacement primary,
  globally revokes old sessions, and requires companions to pair again.
- Restoring old encrypted history requires the user's encrypted backup or an
  online approved device. The server cannot recover missing private keys.
- Moving admin trust is a separate explicit action; primary replacement alone
  never grants audit access.

## Web implementation

Use Flutter Web for maximum reuse of models, message merge logic, receipts,
WebSocket handling, and Dart crypto. Add platform abstractions for:

- device-bound keys in WebCrypto/IndexedDB
- persistent device id
- QR display/pairing state
- no biometric/Tailscale assumptions in web entry routing

Initial web scope:

1. QR link/revoke, inbox, text DMs, receipts, typing, presence.
2. Replies, reactions, edits/deletes, search, stars, checklists.
3. Media and groups with per-device key envelopes.
4. Calls and optional Web Push only after browser-specific integration tests.

The web build can be served as static files behind the same private server, but
must use HTTPS/WSS for browser crypto and media permissions.

## Security and regression gates

Server integration tests must cover:

- first-device migration to primary
- pairing success, rejection, expiry, replay, and concurrent attempts
- non-primary and cross-account approval rejection
- per-device and global revocation, including WebSocket closure
- linked device denied admin audit access
- primary transfer/recovery
- signed device-list rollback/addition detection

Client crypto tests must cover:

- independent device keys
- content-key envelope fan-out to sender and recipient devices
- removed devices receive no future envelope
- primary-to-companion recent-history transfer
- old `e2e1:` migration

Manual release requires one primary Android phone, one linked Android phone, one
linked browser, and an unrelated peer account. Message/read/revoke behavior must
be tested with devices alternately offline before describing it as WhatsApp-like.

## Expected code areas

Server:

- `app/models.py`, `schemas.py`, `auth.py`, `deps.py`, `ws.py`
- new `routers/linked_devices.py`
- realtime hub device routing and database migration
- admin trust checks and audit actions

Flutter:

- `api_client.dart`, `app_state.dart`, `realtime_service.dart`
- `services/e2e_service.dart` migration to device envelopes
- new link-device crypto/storage service
- Linked devices list, QR display, scanner, approval, and revocation screens
- `web/` bootstrap and platform adapters

This document is the implementation backlog. It is not a claim that linked
devices or the website exist in the current release.
