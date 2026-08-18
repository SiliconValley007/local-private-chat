/// Recognising a sealed message body, without pulling in the crypto stack.
///
/// A DM body is stored sealed, so every screen that shows text — bubbles, inbox
/// subtitles, search hits, starred rows, quotes, notifications — is one missing
/// key away from printing a base64 token at the reader. That key can be missing
/// for good: a phone that has been reinstalled derives a new identity, and the
/// history sealed for the old one can never be opened again. It stays on the
/// server, and it stays sealed, so what the reader needs is a plain note saying
/// so rather than the token itself.
library;

/// Marks a body that was sealed for a single pair of devices.
const String e2eCipherPrefix = 'e2e1:';

/// True when [body] is still sealed, i.e. nothing here can read it.
bool isE2eCipherText(String? body) =>
    body != null && body.startsWith(e2eCipherPrefix);

/// [body] when it can be read, and nothing when it is still sealed.
///
/// For a caption, which is worth dropping rather than announcing: a photo with
/// no words under it reads better than a photo with a token under it.
String? readableBody(String? body) => isE2eCipherText(body) ? null : body;

/// One-line stand-in for a sealed body.
const String encryptedPreview = '\u{1F512} Encrypted message';

/// Bubble stand-in for a sealed body, where a lock is drawn beside it.
const String encryptedBodyStandIn = 'Encrypted message';
