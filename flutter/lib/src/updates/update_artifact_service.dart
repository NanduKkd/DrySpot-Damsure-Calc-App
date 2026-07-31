import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_update_bridge.dart';
import 'release_manifest.dart';
import 'update_state.dart';

class UpdateArtifactException implements Exception {
  const UpdateArtifactException(this.kind);

  final UpdateFailureKind kind;
}

class ArtifactDownloadResponse {
  const ArtifactDownloadResponse({
    required this.statusCode,
    required this.redirected,
    required this.contentType,
    required this.contentLength,
    required this.bytes,
    required this.close,
  });

  final int statusCode;
  final bool redirected;
  final String? contentType;
  final int? contentLength;
  final Stream<List<int>> bytes;
  final Future<void> Function() close;
}

abstract class UpdateArtifactTransport {
  Future<ArtifactDownloadResponse> open(Uri url);
}

class NetworkUpdateArtifactTransport implements UpdateArtifactTransport {
  NetworkUpdateArtifactTransport({
    HttpClient Function()? clientFactory,
    this.connectionTimeout = const Duration(seconds: 10),
    this.bodyTimeout = const Duration(seconds: 60),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final Duration connectionTimeout;
  final Duration bodyTimeout;

  @override
  Future<ArtifactDownloadResponse> open(Uri url) async {
    final client = _clientFactory()
      ..connectionTimeout = connectionTimeout
      ..autoUncompress = false;
    try {
      final request = await client.getUrl(url).timeout(connectionTimeout);
      request
        ..followRedirects = false
        ..maxRedirects = 0
        ..persistentConnection = false;
      request.headers
        ..removeAll(HttpHeaders.authorizationHeader)
        ..removeAll(HttpHeaders.cookieHeader)
        ..set(
          HttpHeaders.acceptHeader,
          'application/vnd.android.package-archive',
        )
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(bodyTimeout);
      return ArtifactDownloadResponse(
        statusCode: response.statusCode,
        redirected: response.redirects.isNotEmpty,
        contentType: response.headers.value(HttpHeaders.contentTypeHeader),
        contentLength:
            response.contentLength < 0 ? null : response.contentLength,
        bytes: response.timeout(bodyTimeout),
        close: () async => client.close(force: true),
      );
    } on TimeoutException {
      client.close(force: true);
      throw const UpdateArtifactException(UpdateFailureKind.timeout);
    } on UpdateArtifactException {
      client.close(force: true);
      rethrow;
    } on Object {
      client.close(force: true);
      throw const UpdateArtifactException(UpdateFailureKind.network);
    }
  }
}

class VerifiedArtifactRecord {
  const VerifiedArtifactRecord({
    required this.manifestRevision,
    required this.versionCode,
    required this.versionName,
    required this.sha256,
    required this.sizeBytes,
  });

  final int manifestRevision;
  final int versionCode;
  final String versionName;
  final String sha256;
  final int sizeBytes;

  bool matches(AvailableReleaseManifest manifest) =>
      manifestRevision == manifest.manifestRevision &&
      versionCode == manifest.latestVersionCode &&
      versionName == manifest.latestVersion &&
      sha256 == manifest.sha256 &&
      sizeBytes == manifest.sizeBytes;
}

/// Artifact bookkeeping intentionally has its own key. It can never modify or
/// relax the accepted policy/high-water snapshot in [UpdatePolicyStore].
class VerifiedArtifactStore {
  VerifiedArtifactStore({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _key = 'app113.verified_artifact.v1';
  final Future<SharedPreferences> Function() _preferences;

  Future<VerifiedArtifactRecord?> load() async {
    try {
      final value = (await _preferences()).getString(_key);
      if (value == null) return null;
      final json = jsonDecode(value);
      if (json is! Map ||
          json.length != 6 ||
          json['recordVersion'] != 1 ||
          json['manifestRevision'] is! int ||
          json['versionCode'] is! int ||
          json['versionName'] is! String ||
          json['sha256'] is! String ||
          json['sizeBytes'] is! int) {
        return null;
      }
      return VerifiedArtifactRecord(
        manifestRevision: json['manifestRevision'] as int,
        versionCode: json['versionCode'] as int,
        versionName: json['versionName'] as String,
        sha256: json['sha256'] as String,
        sizeBytes: json['sizeBytes'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(AvailableReleaseManifest manifest) async {
    final value = jsonEncode(<String, Object?>{
      'recordVersion': 1,
      'manifestRevision': manifest.manifestRevision,
      'versionCode': manifest.latestVersionCode,
      'versionName': manifest.latestVersion,
      'sha256': manifest.sha256,
      'sizeBytes': manifest.sizeBytes,
    });
    try {
      if (!await (await _preferences()).setString(_key, value)) {
        throw const UpdateArtifactException(UpdateFailureKind.storage);
      }
    } catch (_) {
      throw const UpdateArtifactException(UpdateFailureKind.storage);
    }
  }

  Future<void> clear() async {
    try {
      await (await _preferences()).remove(_key);
    } catch (_) {
      // The cache is still discarded; stale bookkeeping is never trusted.
    }
  }
}

class UpdateArtifactService {
  UpdateArtifactService({
    required UpdatePlatformBridge platform,
    UpdateArtifactTransport? transport,
    VerifiedArtifactStore? artifactStore,
    Future<Directory> Function()? cacheDirectory,
  })  : _platform = platform,
        _transport = transport ?? NetworkUpdateArtifactTransport(),
        _artifactStore = artifactStore ?? VerifiedArtifactStore(),
        _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  static const maximumArtifactBytes = 250 * 1024 * 1024;
  static const _reserveBytes = 64 * 1024 * 1024;

  final UpdatePlatformBridge _platform;
  final UpdateArtifactTransport _transport;
  final VerifiedArtifactStore _artifactStore;
  final Future<Directory> Function() _cacheDirectory;

  Future<void> recover(AvailableReleaseManifest? activeManifest) async {
    final root = await _root();
    await _deleteParts(root);
    final record = await _artifactStore.load();
    if (activeManifest == null ||
        record == null ||
        !record.matches(activeManifest)) {
      await _deleteAllFinalArtifacts(root);
      await _artifactStore.clear();
      return;
    }
    await _deleteOtherFinalArtifacts(root, activeManifest.latestVersionCode);
  }

  Future<File> obtain(
    AvailableReleaseManifest manifest, {
    required void Function(UpdateOperationPhase phase) onPhase,
  }) async {
    if (manifest.sizeBytes > maximumArtifactBytes) {
      throw const UpdateArtifactException(UpdateFailureKind.artifactTooLarge);
    }
    final root = await _root();
    await _deleteParts(root);
    await _deleteOtherFinalArtifacts(root, manifest.latestVersionCode);
    final finalFile = _finalFile(root, manifest.latestVersionCode);
    final record = await _artifactStore.load();
    if (record != null &&
        record.matches(manifest) &&
        await _isRegularFile(finalFile)) {
      try {
        onPhase(UpdateOperationPhase.verifying);
        await _verify(finalFile, manifest);
        return finalFile;
      } on UpdateArtifactException {
        await _deleteIfExists(finalFile);
        await _artifactStore.clear();
        rethrow;
      }
    }
    await _deleteIfExists(finalFile);
    await _artifactStore.clear();
    return _download(root, manifest, onPhase);
  }

  Future<void> discard(AvailableReleaseManifest manifest) async {
    final root = await _root();
    await _deleteIfExists(_finalFile(root, manifest.latestVersionCode));
    await _artifactStore.clear();
  }

  Future<File> _download(
    Directory root,
    AvailableReleaseManifest manifest,
    void Function(UpdateOperationPhase phase) onPhase,
  ) async {
    final requiredSpace = (manifest.sizeBytes * 2) + _reserveBytes;
    final freeBytes = await _platform.availableCacheBytes();
    if (freeBytes < requiredSpace) {
      throw const UpdateArtifactException(UpdateFailureKind.insufficientSpace);
    }
    final part = _partFile(root, manifest.latestVersionCode);
    final destination = _finalFile(root, manifest.latestVersionCode);
    await _deleteIfExists(part);
    await _deleteIfExists(destination);
    ArtifactDownloadResponse? response;
    IOSink? sink;
    try {
      onPhase(UpdateOperationPhase.downloading);
      response = await _transport.open(manifest.artifactUrl);
      if (response.statusCode != HttpStatus.ok ||
          response.redirected ||
          !_isApkContentType(response.contentType) ||
          (response.contentLength != null &&
              response.contentLength != manifest.sizeBytes)) {
        throw const UpdateArtifactException(UpdateFailureKind.transport);
      }
      sink = part.openWrite(mode: FileMode.writeOnly);
      var received = 0;
      final digests = _DigestSink();
      final hash = sha256.startChunkedConversion(digests);
      await for (final chunk in response.bytes) {
        received += chunk.length;
        if (received > manifest.sizeBytes || received > maximumArtifactBytes) {
          throw const UpdateArtifactException(UpdateFailureKind.sizeMismatch);
        }
        hash.add(chunk);
        sink.add(chunk);
      }
      hash.close();
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != manifest.sizeBytes) {
        throw const UpdateArtifactException(UpdateFailureKind.sizeMismatch);
      }
      if (digests.digest?.toString() != manifest.sha256) {
        throw const UpdateArtifactException(UpdateFailureKind.hashMismatch);
      }
      await part.rename(destination.path);
      onPhase(UpdateOperationPhase.verifying);
      await _verify(destination, manifest);
      await _artifactStore.save(manifest);
      return destination;
    } on TimeoutException {
      throw const UpdateArtifactException(UpdateFailureKind.timeout);
    } on UpdateArtifactException {
      rethrow;
    } on FileSystemException {
      throw const UpdateArtifactException(UpdateFailureKind.storage);
    } on Object {
      throw const UpdateArtifactException(UpdateFailureKind.network);
    } finally {
      await sink?.close();
      await response?.close();
      if (!await _isRegularFile(destination)) {
        await _deleteIfExists(part);
      }
    }
  }

  Future<void> _verify(File file, AvailableReleaseManifest manifest) async {
    if (!await _isRegularFile(file)) {
      throw const UpdateArtifactException(UpdateFailureKind.storage);
    }
    var bytes = 0;
    final digests = _DigestSink();
    final hash = sha256.startChunkedConversion(digests);
    await for (final chunk in file.openRead()) {
      bytes += chunk.length;
      if (bytes > manifest.sizeBytes || bytes > maximumArtifactBytes) {
        throw const UpdateArtifactException(UpdateFailureKind.sizeMismatch);
      }
      hash.add(chunk);
    }
    hash.close();
    if (bytes != manifest.sizeBytes) {
      throw const UpdateArtifactException(UpdateFailureKind.sizeMismatch);
    }
    if (digests.digest?.toString() != manifest.sha256) {
      throw const UpdateArtifactException(UpdateFailureKind.hashMismatch);
    }
    final result = await _platform.verifyArtifact(file, manifest);
    if (!result.isSuccess) throw _platformFailure(result.failure);
  }

  UpdateArtifactException _platformFailure(
    AndroidUpdateFailure? failure,
  ) =>
      UpdateArtifactException(switch (failure) {
        AndroidUpdateFailure.packageMismatch =>
          UpdateFailureKind.packageMismatch,
        AndroidUpdateFailure.versionMismatch =>
          UpdateFailureKind.versionMismatch,
        AndroidUpdateFailure.certificateMismatch =>
          UpdateFailureKind.certificateMismatch,
        AndroidUpdateFailure.installerUnavailable =>
          UpdateFailureKind.installerUnavailable,
        AndroidUpdateFailure.permissionDenied =>
          UpdateFailureKind.permissionDenied,
        _ => UpdateFailureKind.unexpected,
      });

  Future<Directory> _root() async {
    final root = Directory(
      path.join((await _cacheDirectory()).path, 'updates'),
    );
    await root.create(recursive: true);
    return root;
  }

  File _partFile(Directory root, int versionCode) =>
      File(path.join(root.path, 'damsure-$versionCode.apk.part'));
  File _finalFile(Directory root, int versionCode) =>
      File(path.join(root.path, 'damsure-$versionCode.apk'));

  Future<void> _deleteParts(Directory root) async {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.apk.part')) {
        await _deleteIfExists(entity);
      }
    }
  }

  Future<void> _deleteAllFinalArtifacts(Directory root) async {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.apk')) {
        await _deleteIfExists(entity);
      }
    }
  }

  Future<void> _deleteOtherFinalArtifacts(Directory root, int keepCode) async {
    final keepName = 'damsure-$keepCode.apk';
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File &&
          entity.path.endsWith('.apk') &&
          path.basename(entity.path) != keepName) {
        await _deleteIfExists(entity);
      }
    }
  }

  Future<bool> _isRegularFile(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) ==
      FileSystemEntityType.file;

  Future<void> _deleteIfExists(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await file.delete();
    }
  }
}

bool _isApkContentType(String? value) =>
    value != null &&
    value.split(';').first.trim().toLowerCase() ==
        'application/vnd.android.package-archive';

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
