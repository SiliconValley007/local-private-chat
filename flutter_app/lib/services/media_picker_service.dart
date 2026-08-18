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

/// What to say when the gallery would not hand over everything that was picked.
///
/// Resolving a pick can fail — a large video that has to be copied out of
/// scoped storage needs room in the cache to land in. Dropping it quietly is
/// indistinguishable from the app ignoring the send, so the count is named.
String? unreadableAssetsMessage({required int picked, required int resolved}) {
  final missing = picked - resolved;
  if (missing <= 0) return null;
  if (resolved == 0) {
    return picked == 1
        ? "Android wouldn't hand that file over. It may be too large for this "
              'phone to copy, or still syncing from the cloud.'
        : "Android wouldn't hand those $picked files over. They may be too "
              'large for this phone to copy, or still syncing from the cloud.';
  }
  return "$missing of $picked couldn't be read and were left out.";
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
    SpecialPickerType? specialPickerType,
  }) => AssetPickerConfig(
    maxAssets: maxAssets,
    requestType: requestType,
    specialPickerType: specialPickerType,
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
    if (!context.mounted) return assetsToFiles(assets);
    return _resolveSelection(context, assets);
  }

  /// Turns a selection into files, saying so while it takes time or falls short.
  ///
  /// A big clip has to be copied out of the gallery before it can be uploaded,
  /// which happens after the picker has already closed: without the barrier the
  /// chat just sits there for several seconds looking ignored.
  static Future<List<File>> _resolveSelection(
    BuildContext context,
    List<AssetEntity> assets,
  ) async {
    if (!context.mounted) return assetsToFiles(assets);
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const _PreparingAttachmentsDialog(),
    );
    List<File> files;
    try {
      files = await assetsToFiles(assets);
    } finally {
      if (navigator.canPop()) navigator.pop();
    }
    final complaint = unreadableAssetsMessage(
      picked: assets.length,
      resolved: files.length,
    );
    if (complaint != null) {
      messenger?.showSnackBar(SnackBar(content: Text(complaint)));
    }
    return files;
  }

  /// Grid setup for picking one photo (wallpaper, avatar).
  ///
  /// [RequestType.image] hides videos, and [SpecialPickerType.noPreview] drops
  /// the Preview/Send bar that belongs to sending an attachment: a tap picks the
  /// photo and returns, so the caller's own framing step is the next screen.
  @visibleForTesting
  static AssetPickerConfig singleImageConfig() => _config(
    maxAssets: 1,
    requestType: RequestType.image,
    specialPickerType: SpecialPickerType.noPreview,
  );

  /// One image from the on-device gallery (avatar, wallpaper, etc.).
  static Future<File?> pickSingleGalleryImage(BuildContext context) async {
    if (!await ensureGalleryAccess(context)) return null;
    if (!context.mounted) return null;

    final assets = await AssetPicker.pickAssets(
      context,
      permissionRequestOption: _requestOption,
      pickerConfig: singleImageConfig(),
    );
    if (assets == null || assets.isEmpty) return null;
    final files = context.mounted
        ? await _resolveSelection(context, assets)
        : await assetsToFiles(assets);
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

class _PreparingAttachmentsDialog extends StatelessWidget {
  const _PreparingAttachmentsDialog();

  @override
  Widget build(BuildContext context) => const AlertDialog(
    content: Row(
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 16),
        Expanded(child: Text('Preparing attachment…')),
      ],
    ),
  );
}
