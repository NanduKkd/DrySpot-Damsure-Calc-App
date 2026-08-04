import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'release_manifest.dart';

class InstalledAndroidPackage {
  const InstalledAndroidPackage({
    required this.versionCode,
    required this.versionName,
  });

  final int versionCode;
  final String versionName;
}

enum AndroidUpdateFailure {
  invalidRequest,
  packageMismatch,
  versionMismatch,
  certificateMismatch,
  artifactUnavailable,
  installerUnavailable,
  permissionDenied,
  unexpected,
}

class AndroidUpdateResult {
  const AndroidUpdateResult.success() : failure = null;
  const AndroidUpdateResult.failure(this.failure);

  final AndroidUpdateFailure? failure;
  bool get isSuccess => failure == null;
}

/// Keeps all APK/package parsing and installer handoff behind the Android
/// boundary. Dart never grants a URI or starts an installation intent itself.
abstract class UpdatePlatformBridge {
  Future<InstalledAndroidPackage> installedPackage();
  Future<int> availableCacheBytes();
  Future<bool> canRequestPackageInstalls();
  Future<void> openUnknownSourcesSettings();
  Future<AndroidUpdateResult> verifyArtifact(
    File file,
    AvailableReleaseManifest manifest,
  );
  Future<AndroidUpdateResult> launchInstaller(
    File file,
    AvailableReleaseManifest manifest,
  );
}

class MethodChannelUpdatePlatformBridge implements UpdatePlatformBridge {
  MethodChannelUpdatePlatformBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.dryspotuppala/update_installer';
  final MethodChannel _channel;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  Future<InstalledAndroidPackage> installedPackage() async {
    // Non-Android updater support is intentionally excluded. This fallback is
    // only for desktop/widget development and never starts an installer.
    if (!_isAndroid) {
      return const InstalledAndroidPackage(
        versionCode: 1,
        versionName: '1.0.0',
      );
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'installedPackage',
    );
    final versionCode = result?['versionCode'];
    final versionName = result?['versionName'];
    if (versionCode is! int ||
        versionCode <= 0 ||
        versionName is! String ||
        versionName.isEmpty) {
      throw const FormatException('Android package metadata is unavailable.');
    }
    return InstalledAndroidPackage(
      versionCode: versionCode,
      versionName: versionName,
    );
  }

  @override
  Future<int> availableCacheBytes() async {
    if (!_isAndroid) return 1 << 62;
    final result = await _channel.invokeMethod<int>('availableCacheBytes');
    if (result == null || result < 0) {
      throw const FormatException('Android cache space is unavailable.');
    }
    return result;
  }

  @override
  Future<bool> canRequestPackageInstalls() async {
    if (!_isAndroid) return false;
    return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ??
        false;
  }

  @override
  Future<void> openUnknownSourcesSettings() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod<void>('openUnknownSourcesSettings');
  }

  @override
  Future<AndroidUpdateResult> verifyArtifact(
    File file,
    AvailableReleaseManifest manifest,
  ) => _verify('verifyArtifact', file, manifest);

  @override
  Future<AndroidUpdateResult> launchInstaller(
    File file,
    AvailableReleaseManifest manifest,
  ) => _verify('launchInstaller', file, manifest);

  Future<AndroidUpdateResult> _verify(
    String method,
    File file,
    AvailableReleaseManifest manifest,
  ) async {
    if (!_isAndroid) {
      return const AndroidUpdateResult.failure(
        AndroidUpdateFailure.installerUnavailable,
      );
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(method, {
      'path': file.path,
      'versionCode': manifest.latestVersionCode,
      'versionName': manifest.latestVersion,
    });
    if (result?['ok'] == true) return const AndroidUpdateResult.success();
    return AndroidUpdateResult.failure(_failureFromWire(result?['failure']));
  }

  AndroidUpdateFailure _failureFromWire(Object? value) => switch (value) {
    'invalidRequest' => AndroidUpdateFailure.invalidRequest,
    'packageMismatch' => AndroidUpdateFailure.packageMismatch,
    'versionMismatch' => AndroidUpdateFailure.versionMismatch,
    'certificateMismatch' => AndroidUpdateFailure.certificateMismatch,
    'artifactUnavailable' => AndroidUpdateFailure.artifactUnavailable,
    'installerUnavailable' => AndroidUpdateFailure.installerUnavailable,
    'permissionDenied' => AndroidUpdateFailure.permissionDenied,
    _ => AndroidUpdateFailure.unexpected,
  };
}
