import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end encryption for one-to-one chats.
///
/// Every device owns a long-lived X25519 identity key. When two people open a
/// DM they swap public keys over a relay the server can see but not read; from
/// each pair we derive one AES-GCM key with HKDF. Message text is sealed with
/// that key before it leaves the phone, so the server only ever stores an
/// opaque `e2e1:...` token. Decryption happens on ingest, so the rest of the
/// app (bubbles, previews, search, quotes) keeps working on plaintext.
///
/// Only DMs are covered — group fan-out has no shared secret — and only message
/// bodies. Attachments already travel over the private Tailscale network.
class E2EService {
  E2EService({E2ESeedStore? seedStore})
    : _seeds = seedStore ?? const SecureSeedStore();

  static const _peerKeysKey = 'e2e_peer_pubkeys_v1';
  static const cipherPrefix = 'e2e1:';

  final E2ESeedStore _seeds;
  final _x25519 = X25519();
  final _aes = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  SimpleKeyPair? _myKeyPair;
  String? _myPublicKeyB64;

  /// peerUserId -> their base64 public key (public, so kept in plain prefs).
  final Map<int, String> _peerKeys = {};

  /// peerUserId -> derived AES key, cached so we hash the ECDH once per peer.
  final Map<int, SecretKey> _derived = {};

  bool _ready = false;

  /// Loads or creates this device's identity key and any known peer keys.
  Future<void> init() async {
    if (_ready) return;
    final seedB64 = await _seeds.read();
    if (seedB64 != null && seedB64.isNotEmpty) {
      try {
        _myKeyPair = await _x25519.newKeyPairFromSeed(base64Decode(seedB64));
      } catch (_) {
        _myKeyPair = null;
      }
    }
    if (_myKeyPair == null) {
      final kp = await _x25519.newKeyPair();
      final data = await kp.extract();
      await _seeds.write(base64Encode(data.bytes));
      _myKeyPair = kp;
    }
    final pub = await _myKeyPair!.extractPublicKey();
    _myPublicKeyB64 = base64Encode(pub.bytes);

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_peerKeysKey);
    if (stored != null && stored.isNotEmpty) {
      try {
        final map = jsonDecode(stored) as Map<String, dynamic>;
        map.forEach((k, v) {
          final id = int.tryParse(k);
          if (id != null && v is String) _peerKeys[id] = v;
        });
      } catch (_) {}
    }
    _ready = true;
  }

  /// This device's public key to advertise in a handshake, or null before init.
  String? get myPublicKeyB64 => _myPublicKeyB64;

  bool get isReady => _ready;

  bool hasPeerKey(int peerId) => _peerKeys.containsKey(peerId);

  /// Records a peer's public key from a handshake and persists it, so the DM
  /// stays encrypted even after the peer goes offline or the app restarts.
  Future<void> rememberPeerKey(int peerId, String publicKeyB64) async {
    final trimmed = publicKeyB64.trim();
    if (trimmed.isEmpty) return;
    if (_peerKeys[peerId] == trimmed) return;
    _peerKeys[peerId] = trimmed;
    _derived.remove(peerId); // Force a fresh ECDH with the new key.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _peerKeysKey,
      jsonEncode(_peerKeys.map((k, v) => MapEntry('$k', v))),
    );
  }

  Future<SecretKey?> _keyFor(int peerId) async {
    if (!_ready || _myKeyPair == null) return null;
    final cached = _derived[peerId];
    if (cached != null) return cached;
    final peerB64 = _peerKeys[peerId];
    if (peerB64 == null) return null;
    try {
      final peerPub = SimplePublicKey(
        base64Decode(peerB64),
        type: KeyPairType.x25519,
      );
      final shared = await _x25519.sharedSecretKey(
        keyPair: _myKeyPair!,
        remotePublicKey: peerPub,
      );
      final aesKey = await _hkdf.deriveKey(
        secretKey: shared,
        nonce: const [],
        info: utf8.encode('localchat-dm-e2e-v1'),
      );
      _derived[peerId] = aesKey;
      return aesKey;
    } catch (e) {
      debugPrint('E2E key derivation failed: $e');
      return null;
    }
  }

  /// True when [body] is an encrypted token this service produced.
  static bool isCipherText(String? body) =>
      body != null && body.startsWith(cipherPrefix);

  /// Seals [plaintext] for [peerId]. Returns null when no key is known yet, so
  /// the caller can fall back to sending plaintext rather than blocking a chat.
  Future<String?> encryptFor(int peerId, String plaintext) async {
    final key = await _keyFor(peerId);
    if (key == null) return null;
    try {
      final nonce = _aes.newNonce();
      final box = await _aes.encrypt(
        utf8.encode(plaintext),
        secretKey: key,
        nonce: nonce,
      );
      return '$cipherPrefix${base64Encode(nonce)}:'
          '${base64Encode(box.cipherText)}:${base64Encode(box.mac.bytes)}';
    } catch (e) {
      debugPrint('E2E encrypt failed: $e');
      return null;
    }
  }

  /// Opens an `e2e1:...` token from [peerId]. Returns null when it isn't a
  /// token, the key is missing, or the data doesn't authenticate.
  Future<String?> decryptFrom(int peerId, String? token) async {
    if (!isCipherText(token)) return null;
    final key = await _keyFor(peerId);
    if (key == null) return null;
    try {
      final parts = token!.substring(cipherPrefix.length).split(':');
      if (parts.length != 3) return null;
      final nonce = base64Decode(parts[0]);
      final cipherText = base64Decode(parts[1]);
      final mac = base64Decode(parts[2]);
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
      return utf8.decode(clear);
    } catch (e) {
      debugPrint('E2E decrypt failed: $e');
      return null;
    }
  }
}

/// Where a device's long-lived X25519 seed is kept. Abstracted so production
/// uses the OS keystore while tests can hand each instance its own store.
abstract class E2ESeedStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Default seed store, backed by the platform's encrypted secure storage.
class SecureSeedStore implements E2ESeedStore {
  const SecureSeedStore();

  static const _seedKey = 'e2e_x25519_seed_v1';

  FlutterSecureStorage get _storage => const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read() => _storage.read(key: _seedKey);

  @override
  Future<void> write(String value) =>
      _storage.write(key: _seedKey, value: value);
}
