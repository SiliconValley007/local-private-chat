import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../app_state.dart';
import '../theme.dart';
import 'local_chat_picker_text_delegate.dart';

/// How much of the on-device gallery Local Chat may read.
enum GalleryAccessLevel { granted, limited, denied }

/// Maps [PermissionState] to a coarse UX level (unit-testable).
GalleryAccessLevel galleryAccessLevelFor(PermissionState state) {
  if (state == PermissionState.authorized) return GalleryAccessLevel.granted;
  if (state == PermissionState.limited) return GalleryAccessLevel.limited;
  return GalleryAccessLevel.denied;
}

/// Whether the camera shortcut belongs on the current album grid.
///
/// WhatsApp shows it only on the main Recents feed, not inside sub-albums.
bool showCameraShortcutInAlbum(AssetPathEntity? path) => path?.isAll ?? false;

/// User-facing copy when gallery access is blocked or partial.
String galleryPermissionMessage(GalleryAccessLevel level) {
  switch (level) {
    case GalleryAccessLevel.granted:
      return '';
    case GalleryAccessLevel.limited:
      return 'Local Chat can only see photos you allow. '
          'You can grant more access in Settings.';
    case GalleryAccessLevel.denied:
      return 'Local Chat needs photo access to show your recent gallery.';
  }
}

/// Label for the picker confirm action, with optional selection count.
String sendConfirmLabel({required int selected, required int max}) {
  if (selected <= 0) return 'Send';
  return 'Send ($selected/$max)';
}

/// WhatsApp-style recent gallery for chat attachments and single-image picks.
class MediaPickerService {
  const MediaPickerService._();

  static const _chatPickerColor = AppColors.brand;
  static const _textDelegate = LocalChatPickerTextDelegate();
  static final _imagePicker = ImagePicker();

  static PermissionRequestOption get _requestOption =>
      const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.common,
          mediaLocation: false,
        ),
      );

  static AssetPickerConfig _config({
    required int maxAssets,
    required RequestType requestType,
    bool includeCameraShortcut = false,
  }) => AssetPickerConfig(
    maxAssets: maxAssets,
    requestType: requestType,
    sortPathsByModifiedDate: true,
    pickerTheme: AssetPicker.themeData(_chatPickerColor),
    textDelegate: _textDelegate,
    gridCount: 4,
    pageSize: 80,
    specialItems: includeCameraShortcut
        ? [
            SpecialItem<AssetPathEntity>(
              position: SpecialItemPosition.prepend,
              builder: _cameraShortcutBuilder,
            ),
          ]
        : const [],
  );

  /// Requests gallery access and explains when the user has fully denied it.
  static Future<bool> ensureGalleryAccess(BuildContext context) async {
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: _requestOption,
    );
    final level = galleryAccessLevelFor(state);
    if (level == GalleryAccessLevel.denied) {
      if (!context.mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Photos access needed'),
          content: Text(galleryPermissionMessage(level)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                PhotoManager.openSetting();
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      return false;
    }
    if (level == GalleryAccessLevel.limited && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(galleryPermissionMessage(level))));
    }
    return true;
  }

  /// Mixed photos and videos, multi-select up to [AppState.maxAttachmentsPerSend].
  static Future<List<File>?> pickChatAttachments(BuildContext context) async {
    if (!await ensureGalleryAccess(context)) return null;
    if (!context.mounted) return null;

    final assets = await AssetPicker.pickAssets(
      context,
      permissionRequestOption: _requestOption,
      pickerConfig: _config(
        maxAssets: AppState.maxAttachmentsPerSend,
        requestType: RequestType.common,
        includeCameraShortcut: true,
      ),
    );
    if (assets == null || assets.isEmpty) return null;
    return assetsToFiles(assets);
  }

  /// One image from the on-device gallery (avatar, wallpaper, etc.).
  static Future<File?> pickSingleGalleryImage(BuildContext context) async {
    if (!await ensureGalleryAccess(context)) return null;
    if (!context.mounted) return null;

    final assets = await AssetPicker.pickAssets(
      context,
      permissionRequestOption: _requestOption,
      pickerConfig: _config(maxAssets: 1, requestType: RequestType.image),
    );
    if (assets == null || assets.isEmpty) return null;
    final files = await assetsToFiles(assets);
    return files.isEmpty ? null : files.first;
  }

  /// Resolves album items to local files in selection order.
  static Future<List<File>> assetsToFiles(List<AssetEntity> assets) async {
    final files = <File>[];
    for (final asset in assets) {
      final file = await asset.file ?? await asset.originFile;
      if (file != null) files.add(file);
    }
    return files;
  }

  /// First tile in the Recents grid — capture and add to the current selection.
  static Widget? _cameraShortcutBuilder(
    BuildContext context,
    AssetPathEntity? path,
    PermissionState permissionState,
  ) {
    if (!showCameraShortcutInAlbum(path)) return null;

    return Semantics(
      label: _textDelegate.sActionUseCameraHint,
      button: true,
      onTapHint: _textDelegate.sActionUseCameraHint,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _captureAndSelect(context),
        child: ColoredBox(
          color: Theme.of(context).dividerColor,
          child: const Center(
            child: Icon(Icons.photo_camera_rounded, size: 36),
          ),
        ),
      ),
    );
  }

  static Future<void> _captureAndSelect(BuildContext context) async {
    Feedback.forTap(context);
    final asset = await _captureFromCamera();
    if (asset == null || !context.mounted) return;

    // Same lookup the package's own cameraAndStay example uses: the picker
    // route is an ancestor of this special-item tile.
    final picker = context
        .findAncestorWidgetOfExactType<
          AssetPicker<
            AssetEntity,
            AssetPathEntity,
            DefaultAssetPickerBuilderDelegate
          >
        >();
    if (picker == null) return;

    final provider = picker.builder.provider;
    if (provider.selectedAssets.length >= provider.maxAssets) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('You can send up to ${provider.maxAssets} at a time.'),
        ),
      );
      return;
    }

    final current = provider.currentPath;
    if (current != null) {
      await provider.switchPath(
        PathWrapper<AssetPathEntity>(
          path: await current.path.obtainForNewProperties(),
        ),
      );
    }
    provider.selectAsset(asset);
  }

  /// Saves a camera capture into the gallery and returns the new asset.
  static Future<AssetEntity?> _captureFromCamera() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 2048,
    );
    if (picked == null) return null;
    try {
      return await PhotoManager.editor.saveImageWithPath(picked.path);
    } on PlatformException {
      return null;
    }
  }
}
