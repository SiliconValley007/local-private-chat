import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../errors.dart';
import '../services/media_picker_service.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/avatar_viewer.dart';

/// WhatsApp-style profile for the signed-in user: avatar, display name,
/// username, and mood.
class SelfProfileScreen extends StatefulWidget {
  const SelfProfileScreen({super.key});

  @override
  State<SelfProfileScreen> createState() => _SelfProfileScreenState();
}

class _SelfProfileScreenState extends State<SelfProfileScreen> {
  bool _savingName = false;
  bool _savingMood = false;

  Future<void> _editAvatar(AppState state) async {
    final hasPhoto = state.avatarUrlFor(state.me?.id) != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheetContext, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheetContext, 'camera'),
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Remove photo'),
                onTap: () => Navigator.pop(sheetContext, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice == 'remove') {
        await state.removeMyAvatar();
      } else if (choice == 'gallery') {
        final picked = await MediaPickerService.pickSingleGalleryImage(context);
        if (picked != null) await state.setMyAvatar(picked);
      } else {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 88,
          maxWidth: 1024,
          maxHeight: 1024,
        );
        if (picked != null) {
          await state.setMyAvatar(File(picked.path));
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update your photo: $e')),
      );
    }
  }

  Future<void> _editDisplayName(AppState state) async {
    final me = state.me;
    if (me == null) return;
    final controller = TextEditingController(text: me.displayName);
    final saved = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Name shown to everyone'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = saved?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == me.displayName) return;
    setState(() => _savingName = true);
    try {
      await state.setMyDisplayName(trimmed);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _editMood(AppState state) async {
    final controller = TextEditingController(text: state.me?.mood ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Set your mood'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. Missing you \u{1F49B}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, '__clear__'),
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final mood = result == '__clear__' ? null : result.trim();
    setState(() => _savingMood = true);
    try {
      await state.setMyMood(mood == null || mood.isEmpty ? null : mood);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update your mood: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingMood = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final me = state.me;
    if (me == null) {
      return const Scaffold(body: Center(child: Text('Not signed in')));
    }
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          Center(
            child: GestureDetector(
              onTap: () async {
                final wantsEdit = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (viewerContext) => AvatarViewerScreen(
                      name: me.displayName,
                      seed: me.id,
                      imageUrl: state.avatarUrlFor(me.id),
                      imageHeaders: state.api.imageAuthHeaders,
                      onEdit: () => Navigator.of(viewerContext).pop(true),
                    ),
                  ),
                );
                if (wantsEdit == true && mounted) {
                  await _editAvatar(state);
                }
              },
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Avatar(
                    name: me.displayName,
                    seed: me.id,
                    radius: 56,
                    imageUrl: state.avatarUrlFor(me.id),
                    imageHeaders: state.api.imageAuthHeaders,
                  ),
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: scheme.primary,
                    child: Icon(
                      Icons.camera_alt_rounded,
                      size: 18,
                      color: scheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          _ProfileField(
            label: 'Display name',
            value: me.displayName,
            trailing: _savingName
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.edit_outlined, size: 20),
            onTap: _savingName ? null : () => _editDisplayName(state),
          ),
          const Divider(height: 28),
          _ProfileField(
            label: 'Username',
            value: '@${me.username}',
            subtitle: 'Cannot be changed',
          ),
          const Divider(height: 28),
          _ProfileField(
            label: 'Mood',
            value: (me.mood?.isNotEmpty ?? false) ? me.mood! : 'Not set',
            muted: me.mood == null || me.mood!.isEmpty,
            trailing: _savingMood
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mood_rounded, size: 20),
            onTap: _savingMood ? null : () => _editMood(state),
            subtitle: 'Shown only to your chat partners',
          ),
        ],
      ),
    );
  }
}

class _ProfileField extends StatelessWidget {
  const _ProfileField({
    required this.label,
    required this.value,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.muted = false,
  });

  final String label;
  final String value;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: muted ? scheme.onSurfaceVariant : null,
                        fontStyle: muted ? FontStyle.italic : FontStyle.normal,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
