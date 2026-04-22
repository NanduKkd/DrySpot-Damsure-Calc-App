import 'package:app_client/src/services/map_launcher_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  FakeUrlLauncherPlatform(this.launchResults);

  final Map<String, bool> launchResults;
  final List<String> launchedUrls = [];
  int canLaunchCalls = 0;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async {
    canLaunchCalls++;
    throw StateError('canLaunch should not be called by MapLauncherService');
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launchedUrls.add(url);
    return launchResults[url] ?? false;
  }
}

void main() {
  late UrlLauncherPlatform originalPlatform;

  setUp(() {
    originalPlatform = UrlLauncherPlatform.instance;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalPlatform;
    debugDefaultTargetPlatformOverride = null;
  });

  test('tries the native iOS map URI without canLaunch gating first', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final platform = FakeUrlLauncherPlatform({
      'maps://?q=12.34,56.78': true,
    });
    UrlLauncherPlatform.instance = platform;

    final didOpen = await MapLauncherService().openCoordinates(
      latitude: 12.34,
      longitude: 56.78,
    );

    expect(didOpen, isTrue);
    expect(platform.canLaunchCalls, 0);
    expect(platform.launchedUrls, ['maps://?q=12.34,56.78']);
  });

  test('falls back to web map search when the native launch fails', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final platform = FakeUrlLauncherPlatform({
      'geo:12.34,56.78?q=12.34,56.78': false,
      'https://www.google.com/maps/search/?api=1&query=12.34%2C56.78': true,
    });
    UrlLauncherPlatform.instance = platform;

    final didOpen = await MapLauncherService().openCoordinates(
      latitude: 12.34,
      longitude: 56.78,
    );

    expect(didOpen, isTrue);
    expect(platform.canLaunchCalls, 0);
    expect(
      platform.launchedUrls,
      [
        'geo:12.34,56.78?q=12.34,56.78',
        'https://www.google.com/maps/search/?api=1&query=12.34%2C56.78',
      ],
    );
  });
}
