import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_config.dart';
import '../errors.dart';
import '../invite_flow.dart';
import '../models.dart';
import '../widgets/error_banner.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;
  String? _error;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    if (capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;
    final invite = AppConfig.parseInvite(raw);
    if (invite == null) {
      setState(() => _error = "That QR code isn't a Local Chat invite.");
      return;
    }
    _handled = true;
    try {
      final Conversation? conv = await acceptInvite(context, invite);
      if (mounted && conv != null) Navigator.of(context).pop(conv);
    } catch (e) {
      _handled = false;
      setState(() => _error = friendlyMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan invite')),
      body: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(24),
              ),
              child: MobileScanner(onDetect: _onDetect),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(
                  'Point at a friend’s Local Chat QR',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  ErrorBanner(message: _error!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
