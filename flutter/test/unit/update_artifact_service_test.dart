import 'dart:async';
import 'dart:io';

import 'package:app_client/src/updates/android_update_bridge.dart';
import 'package:app_client/src/updates/release_manifest.dart';
import 'package:app_client/src/updates/update_artifact_service.dart';
import 'package:app_client/src/updates/update_state.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements UpdatePlatformBridge {
  _Platform({
    this.freeBytes = 1024 * 1024 * 1024,
    this.verificationResult = const AndroidUpdateResult.success(),
  });

  final int freeBytes;
  final AndroidUpdateResult verificationResult;
  int verifyCalls = 0;

  @override
  Future<int> availableCacheBytes() async => freeBytes;
  @override
  Future<bool> canRequestPackageInstalls() async => true;
  @override
  Future<InstalledAndroidPackage> installedPackage() async =>
      const InstalledAndroidPackage(versionCode: 1, versionName: '1.0.0');
  @override
  Future<AndroidUpdateResult> launchInstaller(
    File file,
    AvailableReleaseManifest manifest,
  ) async =>
      const AndroidUpdateResult.success();
  @override
  Future<void> openUnknownSourcesSettings() async {}
  @override
  Future<AndroidUpdateResult> verifyArtifact(
    File file,
    AvailableReleaseManifest manifest,
  ) async {
    verifyCalls++;
    return verificationResult;
  }
}

class _Transport implements UpdateArtifactTransport {
  _Transport(this.response);
  final ArtifactDownloadResponse response;
  int calls = 0;

  @override
  Future<ArtifactDownloadResponse> open(Uri url) async {
    calls++;
    return response;
  }
}

AvailableReleaseManifest _manifest(List<int> bytes) => AvailableReleaseManifest(
      manifestRevision: 42,
      latestVersion: '1.4.0',
      latestVersionCode: 10400,
      minimumSupportedVersionCode: 10300,
      artifactUrl: Uri.parse(
        'https://damsure.nandakrishnan.in/releases/damsure-10400.apk',
      ),
      sha256: sha256.convert(bytes).toString(),
      sizeBytes: bytes.length,
      publishedAt: DateTime.utc(2026, 7, 30, 10),
      releaseNotes: 'Notes',
      requiredUpdateReason: 'Update now.',
    );

ArtifactDownloadResponse _response(
  List<int> bytes, {
  int? length,
  bool omitContentLength = false,
  String? contentType = 'application/vnd.android.package-archive',
}) =>
    ArtifactDownloadResponse(
      statusCode: HttpStatus.ok,
      redirected: false,
      contentType: contentType,
      contentLength: omitContentLength ? null : length ?? bytes.length,
      bytes: Stream<List<int>>.fromIterable(<List<int>>[bytes]),
      close: () async {},
    );

void main() {
  late Directory cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cache = await Directory.systemTemp.createTemp('app113-artifact-test-');
  });
  tearDown(() => cache.delete(recursive: true));

  test('streams, hashes, atomically retains and revalidates a private APK',
      () async {
    final bytes = <int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3];
    final platform = _Platform();
    final transport = _Transport(_response(bytes));
    final service = UpdateArtifactService(
      platform: platform,
      transport: transport,
      cacheDirectory: () async => cache,
    );
    final manifest = _manifest(bytes);

    final first = await service.obtain(manifest, onPhase: (_) {});
    final second = await service.obtain(manifest, onPhase: (_) {});

    expect(await first.readAsBytes(), bytes);
    expect(second.path, first.path);
    expect(transport.calls, 1);
    expect(platform.verifyCalls, 2, reason: 'cached artifact is reverified');
    expect(first.path,
        contains('${Platform.pathSeparator}updates${Platform.pathSeparator}'));
  });

  test('removes a partial file when streamed bytes are short or mismatched',
      () async {
    final expected = <int>[1, 2, 3, 4];
    final platform = _Platform();
    final service = UpdateArtifactService(
      platform: platform,
      transport: _Transport(_response(<int>[1, 2, 3], length: 4)),
      cacheDirectory: () async => cache,
    );

    await expectLater(
      service.obtain(_manifest(expected), onPhase: (_) {}),
      throwsA(
        isA<UpdateArtifactException>().having(
          (error) => error.kind,
          'kind',
          UpdateFailureKind.sizeMismatch,
        ),
      ),
    );
    final root = Directory('${cache.path}${Platform.pathSeparator}updates');
    expect(await root.list().toList(), isEmpty);
  });

  test('requires an exact declared artifact Content-Length', () async {
    final bytes = <int>[1, 2, 3, 4];
    final service = UpdateArtifactService(
      platform: _Platform(),
      transport: _Transport(_response(bytes, omitContentLength: true)),
      cacheDirectory: () async => cache,
    );

    await expectLater(
      service.obtain(_manifest(bytes), onPhase: (_) {}),
      throwsA(
        isA<UpdateArtifactException>().having(
          (error) => error.kind,
          'kind',
          UpdateFailureKind.transport,
        ),
      ),
    );
    final root = Directory('${cache.path}${Platform.pathSeparator}updates');
    expect(await root.list().toList(), isEmpty);
    expect(await VerifiedArtifactStore().load(), isNull);
  });

  test('accepts exact APK MIME and rejects parameters without artifacts',
      () async {
    final bytes = <int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3];
    final manifest = _manifest(bytes);
    final exactService = UpdateArtifactService(
      platform: _Platform(),
      transport: _Transport(_response(bytes)),
      cacheDirectory: () async => cache,
    );
    await exactService.obtain(manifest, onPhase: (_) {});
    await exactService.discard(manifest);

    final parameterizedService = UpdateArtifactService(
      platform: _Platform(),
      transport: _Transport(
        _response(
          bytes,
          contentType:
              'application/vnd.android.package-archive; charset=binary',
        ),
      ),
      cacheDirectory: () async => cache,
    );
    await expectLater(
      parameterizedService.obtain(manifest, onPhase: (_) {}),
      throwsA(
        isA<UpdateArtifactException>().having(
          (error) => error.kind,
          'kind',
          UpdateFailureKind.transport,
        ),
      ),
    );

    final root = Directory('${cache.path}${Platform.pathSeparator}updates');
    expect(await root.list().toList(), isEmpty);
    expect(await VerifiedArtifactStore().load(), isNull);
  });

  test(
      'removes the renamed APK and ready record after native metadata or signer rejection',
      () async {
    final bytes = <int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3];
    final manifest = _manifest(bytes);
    final expectedFailures = <AndroidUpdateFailure, UpdateFailureKind>{
      AndroidUpdateFailure.packageMismatch: UpdateFailureKind.packageMismatch,
      AndroidUpdateFailure.versionMismatch: UpdateFailureKind.versionMismatch,
      AndroidUpdateFailure.certificateMismatch:
          UpdateFailureKind.certificateMismatch,
    };

    for (final entry in expectedFailures.entries) {
      final service = UpdateArtifactService(
        platform: _Platform(
          verificationResult: AndroidUpdateResult.failure(entry.key),
        ),
        transport: _Transport(_response(bytes)),
        cacheDirectory: () async => cache,
      );

      await expectLater(
        service.obtain(manifest, onPhase: (_) {}),
        throwsA(
          isA<UpdateArtifactException>().having(
            (error) => error.kind,
            'kind',
            entry.value,
          ),
        ),
      );
      final finalFile = File(
        '${cache.path}${Platform.pathSeparator}updates${Platform.pathSeparator}'
        'damsure-${manifest.latestVersionCode}.apk',
      );
      expect(await finalFile.exists(), isFalse, reason: '${entry.key} APK');
      expect(await VerifiedArtifactStore().load(), isNull,
          reason: '${entry.key} ready record');
    }
  });

  test('fails before download when free private cache space is insufficient',
      () async {
    final bytes = <int>[1, 2, 3, 4];
    final transport = _Transport(_response(bytes));
    final service = UpdateArtifactService(
      platform: _Platform(freeBytes: 1),
      transport: transport,
      cacheDirectory: () async => cache,
    );

    await expectLater(
      service.obtain(_manifest(bytes), onPhase: (_) {}),
      throwsA(isA<UpdateArtifactException>()),
    );
    expect(transport.calls, 0);
  });
}
