import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../api_client.dart';
import '../models.dart';
import 'contacts_store.dart';

/// Client-side AES-GCM backup. Server/Firestore only ever see ciphertext.
class BackupService {
  BackupService(this.api);

  final ApiClient api;
  final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  );
  final _aes = AesGcm.with256bits();

  Future<Map<String, dynamic>> buildPlaintextExport({
    required ChatUser me,
    required List<Conversation> conversations,
    required Map<int, List<ChatMessage>> messagesByConv,
    required List<LocalContact> localContacts,
    required Map<String, String> contactAliases,
  }) async {
    return {
      // 2 added contact_aliases; restores of version 1 backups still work.
      'version': 2,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'user': {
        'id': me.id,
        'username': me.username,
        'display_name': me.displayName,
      },
      'conversations': conversations
          .map(
            (c) => {
              'id': c.id,
              'type': c.type,
              'title': c.title,
              'peer': c.peer == null
                  ? null
                  : {
                      'id': c.peer!.id,
                      'username': c.peer!.username,
                      'display_name': c.peer!.displayName,
                    },
            },
          )
          .toList(),
      'messages': [
        for (final entry in messagesByConv.entries)
          for (final m in entry.value)
            {
              'id': m.id,
              'conversation_id': m.conversationId,
              'sender_id': m.senderId,
              'type': m.type,
              'body': m.body,
              'media_name': m.mediaName,
              'created_at': m.createdAt.toUtc().toIso8601String(),
            },
      ],
      'local_contacts': localContacts.map((c) => c.toJson()).toList(),
      // The names you gave people, so a restored phone shows them too.
      'contact_aliases': contactAliases,
    };
  }

  Future<({String ciphertextB64, String saltB64, String nonceB64})> encrypt({
    required String password,
    required Map<String, dynamic> plaintext,
  }) async {
    final salt = _randomBytes(16);
    final secretKey = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final nonce = _aes.newNonce();
    final clear = utf8.encode(jsonEncode(plaintext));
    final box = await _aes.encrypt(clear, secretKey: secretKey, nonce: nonce);
    final combined = <int>[...box.cipherText, ...box.mac.bytes];
    return (
      ciphertextB64: base64Encode(combined),
      saltB64: base64Encode(salt),
      nonceB64: base64Encode(nonce),
    );
  }

  Future<Map<String, dynamic>> decrypt({
    required String password,
    required String ciphertextB64,
    required String saltB64,
    required String nonceB64,
  }) async {
    final salt = base64Decode(saltB64);
    final nonce = base64Decode(nonceB64);
    final combined = base64Decode(ciphertextB64);
    if (combined.length < 17) {
      throw ApiException('This backup file is damaged and cannot be restored.');
    }
    final cipherText = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);
    final secretKey = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    try {
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
        secretKey: secretKey,
      );
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } catch (_) {
      // AES-GCM cannot tell a wrong key from damaged data; both look the same.
      throw ApiException(
        'That backup password is incorrect, or the backup is damaged. '
        'Check the password and try again.',
      );
    }
  }

  Future<void> uploadToServer({
    required String ciphertextB64,
    required String saltB64,
    required String nonceB64,
  }) {
    return api.putBackup(
      ciphertextB64: ciphertextB64,
      saltB64: saltB64,
      nonceB64: nonceB64,
    );
  }

  Future<Map<String, String>> downloadFromServer() => api.getBackup();

  /// Optional cloud copy of the *same ciphertext* (never plaintext).
  Future<bool> uploadCiphertextToFirestore({
    required String username,
    required String ciphertextB64,
    required String saltB64,
    required String nonceB64,
  }) async {
    try {
      await _ensureFirebase();
      final auth = FirebaseAuth.instance;
      if (auth.currentUser == null) {
        await auth.signInAnonymously();
      }
      final uid = auth.currentUser!.uid;
      await FirebaseFirestore.instance
          .collection('encrypted_backups')
          .doc(username)
          .set({
            'owner_firebase_uid': uid,
            'ciphertext_b64': ciphertextB64,
            'salt_b64': saltB64,
            'nonce_b64': nonceB64,
            'updated_at': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      return true;
    } catch (e) {
      debugPrint('Firestore backup skipped: $e');
      return false;
    }
  }

  Future<Map<String, String>?> downloadCiphertextFromFirestore(
    String username,
  ) async {
    try {
      await _ensureFirebase();
      final auth = FirebaseAuth.instance;
      if (auth.currentUser == null) {
        await auth.signInAnonymously();
      }
      final doc = await FirebaseFirestore.instance
          .collection('encrypted_backups')
          .doc(username)
          .get();
      if (!doc.exists) return null;
      final data = doc.data()!;
      return {
        'ciphertext_b64': data['ciphertext_b64'] as String,
        'salt_b64': data['salt_b64'] as String,
        'nonce_b64': data['nonce_b64'] as String,
      };
    } catch (e) {
      debugPrint('Firestore restore skipped: $e');
      return null;
    }
  }

  Future<void> _ensureFirebase() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  }

  Uint8List _randomBytes(int n) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
  }
}
