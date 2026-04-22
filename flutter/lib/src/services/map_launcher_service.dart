import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

class MapLauncherService {
  Future<bool> openCoordinates({
    required double latitude,
    required double longitude,
  }) async {
    final nativeUri = _nativeUri(latitude: latitude, longitude: longitude);
    if (await _tryLaunch(nativeUri)) {
      return true;
    }

    final fallbackUri = Uri.https(
      'www.google.com',
      '/maps/search/',
      {
        'api': '1',
        'query': '$latitude,$longitude',
      },
    );

    if (fallbackUri == nativeUri) {
      return false;
    }

    return _tryLaunch(fallbackUri);
  }

  Uri _nativeUri({
    required double latitude,
    required double longitude,
  }) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return Uri.parse('maps://?q=$latitude,$longitude');
      case TargetPlatform.android:
        return Uri.parse('geo:$latitude,$longitude?q=$latitude,$longitude');
      default:
        return Uri.https(
          'www.google.com',
          '/maps/search/',
          {
            'api': '1',
            'query': '$latitude,$longitude',
          },
        );
    }
  }

  Future<bool> _tryLaunch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
