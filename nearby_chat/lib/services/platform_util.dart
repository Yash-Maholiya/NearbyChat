import 'package:flutter/foundation.dart';

/// Web-safe platform detection.
/// Avoids importing dart:io on web targets (which would crash).
bool get isAndroid {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android;
}

bool get isIOS {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.iOS;
}
