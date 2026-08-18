import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// English picker copy aligned with Local Chat (Send instead of Confirm).
class LocalChatPickerTextDelegate extends EnglishAssetPickerTextDelegate {
  const LocalChatPickerTextDelegate();

  @override
  String get confirm => 'Send';

  @override
  String get select => 'Select';

  @override
  String get unableToAccessAll =>
      'Local Chat cannot see all photos on this device';

  @override
  String get viewingLimitedAssetsTip =>
      'Local Chat can only see photos you chose to share';

  @override
  String get changeAccessibleLimitedAssets => 'Choose more photos';

  @override
  String get accessAllTip =>
      'Allow Local Chat to access your photos in system Settings '
      'to browse your full gallery.';

  @override
  String get goToSystemSettings => 'Open Settings';

  @override
  String get accessLimitedAssets => 'Continue with selected photos';

  @override
  String get sActionUseCameraHint => 'Take a photo';
}
