import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The sending notification, and the Cancel button that lives on it.
///
/// Android will freeze the app moments after it leaves the screen unless there is
/// visible work to point at. This is that work: while the notice is up a send
/// keeps running with the app minimised, which is the only way a few hundred
/// megabytes ever finishes on a phone.
class UploadNotice {
  UploadNotice({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('local_chat/upload_notice');

  final MethodChannel _channel;

  bool _supported = true;
  int _lastPercent = -1;
  DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);

  /// Show or refresh the notice. Safe to call for every chunk: repeats that would
  /// say the same thing are dropped here rather than crossing the channel.
  Future<void> show({
    String? title,
    required int sent,
    required int total,
    int count = 1,
    bool force = false,
  }) async {
    if (!_supported || !Platform.isAndroid) return;
    final percent = total <= 0 ? 0 : ((sent / total) * 100).clamp(0, 100).round();
    final now = DateTime.now();
    final quiet = now.difference(_lastShown) < const Duration(milliseconds: 400);
    if (!force && percent == _lastPercent && quiet) return;
    _lastPercent = percent;
    _lastShown = now;
    await _invoke('show', {
      'title': title,
      'sent': sent,
      'total': total,
      'count': count,
    });
  }

  /// Take the notice down; the send is finished, failed, or cancelled.
  Future<void> stop() async {
    if (!_supported || !Platform.isAndroid) return;
    _lastPercent = -1;
    _lastShown = DateTime.fromMillisecondsSinceEpoch(0);
    await _invoke('stop', null);
  }

  /// True once the user has tapped Cancel on the notification.
  Future<bool> cancelRequested() async {
    if (!_supported || !Platform.isAndroid) return false;
    final answer = await _invoke('cancelRequested', null);
    return answer == true;
  }

  Future<void> clearCancel() async {
    if (!_supported || !Platform.isAndroid) return;
    await _invoke('clearCancel', null);
  }

  Future<Object?> _invoke(String method, Map<String, Object?>? arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      // An older host build, or a platform with no such notion. Uploads still
      // work; they just have no notice to protect them.
      _supported = false;
      return null;
    } catch (e) {
      debugPrint('Upload notice ($method) failed: $e');
      return null;
    }
  }
}
