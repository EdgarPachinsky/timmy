import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a web or mail link in the default browser or mail app. Returns false
/// for anything else, or when nothing could open it.
Future<bool> openExternal(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !const {'http', 'https', 'mailto'}.contains(uri.scheme)) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on PlatformException {
    return false;
  }
}
