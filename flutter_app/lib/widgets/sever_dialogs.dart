import 'package:flutter/material.dart';

import '../disconnect_copy.dart';

Future<String?> showDeleteChatDialog(BuildContext context, {required bool isDm}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete chat'),
      content: Text(isDm ? deleteChatEveryoneConfirm : deleteChatConfirm),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'me'),
          child: const Text('Just for me'),
        ),
        if (isDm)
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'everyone'),
            child: const Text('For both of us'),
          ),
      ],
    ),
  );
}

/// null = cancel, false = block only, true = block and delete for both.
Future<bool?> showRemoveContactDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Remove contact'),
      content: const Text(removeContactConfirm),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Remove'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove and delete chat'),
        ),
      ],
    ),
  );
}
