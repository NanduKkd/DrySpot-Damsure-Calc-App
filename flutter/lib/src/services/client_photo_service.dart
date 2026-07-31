import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';
import 'session_manager.dart';

typedef PhotoFileCopier = Future<File> Function(
  File source,
  String destinationPath,
);
typedef PhotoFileDeleter = Future<void> Function(File file);

/// A network image whose bearer capability is checked at resolution, directly
/// before the HTTP request starts, and again before decoding/cache insertion.
/// The cache key carries the immutable session generation, so B can never
/// reuse an A image entry even when URLs look identical.
class SessionNetworkImage extends ImageProvider<SessionNetworkImage> {
  const SessionNetworkImage({
    required this.url,
    required this.headers,
    required this.session,
    required this.isSessionCurrent,
    this.scale = 1.0,
  });

  final String url;
  final Map<String, String> headers;
  final SessionSnapshot session;
  final bool Function() isSessionCurrent;
  final double scale;

  @override
  Future<SessionNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<SessionNetworkImage>(this);

  @override
  // ImageProvider still exposes loadBuffer on the supported Flutter channel;
  // keep the override so callers on either decoder path get the same fence.
  ImageStreamCompleter loadBuffer(
    SessionNetworkImage key,
    // ignore: deprecated_member_use
    DecoderBufferCallback decode,
  ) =>
      _load(key, decode);

  @override
  ImageStreamCompleter loadImage(
    SessionNetworkImage key,
    ImageDecoderCallback decode,
  ) =>
      _load(key, decode);

  ImageStreamCompleter _load(
    SessionNetworkImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunks, decode: decode),
      chunkEvents: chunks.stream,
      scale: scale,
      debugLabel: url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<SessionNetworkImage>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    SessionNetworkImage key,
    StreamController<ImageChunkEvent> chunks, {
    required Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  }) async {
    void requireCurrent() {
      if (!isSessionCurrent()) throw const StaleSessionException();
    }

    try {
      requireCurrent();
      final request = await HttpClient().getUrl(Uri.base.resolve(url));
      headers.forEach(request.headers.add);
      // This is the final guard before HttpClientRequest.close sends the
      // captured bearer to the network.
      requireCurrent();
      final response = await request.close();
      requireCurrent();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<List<int>>(<int>[]);
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: Uri.base.resolve(url),
        );
      }
      final bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: (loaded, total) {
          chunks.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: loaded,
              expectedTotalBytes: total,
            ),
          );
        },
      );
      requireCurrent();
      if (bytes.isEmpty) throw Exception('NetworkImage is an empty file: $url');
      final buffer =
          await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes));
      requireCurrent();
      return decode(buffer);
    } catch (_) {
      // A stale/deferred result must not survive in the global image cache.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      await chunks.close();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SessionNetworkImage &&
      other.url == url &&
      other.scale == scale &&
      other.session.generation == session.generation &&
      other.session.token == session.token &&
      other.session.franchiseeId == session.franchiseeId;

  @override
  int get hashCode => Object.hash(
        url,
        scale,
        session.generation,
        session.token,
        session.franchiseeId,
      );
}

class ClientPhotoService {
  ClientPhotoService({
    ImagePicker? imagePicker,
    Future<Directory> Function()? directoryProvider,
    PhotoFileCopier? fileCopier,
    PhotoFileDeleter? fileDeleter,
  })  : _imagePicker = imagePicker ?? ImagePicker(),
        _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory,
        _fileCopier =
            fileCopier ?? ((source, destination) => source.copy(destination)),
        _fileDeleter = fileDeleter ?? ((file) => file.delete());

  final ImagePicker _imagePicker;
  final Future<Directory> Function() _directoryProvider;
  final PhotoFileCopier _fileCopier;
  final PhotoFileDeleter _fileDeleter;

  Future<String?> addPhoto({
    required int clientLocalId,
    required ImageSource source,
  }) async {
    final pickedFile = await _imagePicker.pickImage(
      source: source,
      imageQuality: 85,
    );

    if (pickedFile == null) {
      return null;
    }

    return _persistPhoto(
      clientLocalId: clientLocalId,
      sourcePath: pickedFile.path,
    );
  }

  /// Picks and persists a photo under an immutable session capability.  The
  /// second validation happens after the awaited copy; a stale copy is
  /// deleted before this future completes, so it can neither leak into B's
  /// visible media nor be attached to a provider/SQLite client update.
  Future<String?> addPhotoForSession({
    required int clientLocalId,
    required ImageSource source,
    required SessionSnapshot session,
    required bool Function() isSessionCurrent,
  }) async {
    _requireCurrent(isSessionCurrent);
    final pickedFile = await _imagePicker.pickImage(
      source: source,
      imageQuality: 85,
    );
    _requireCurrent(isSessionCurrent);
    if (pickedFile == null) return null;
    return _persistPhoto(
      clientLocalId: clientLocalId,
      sourcePath: pickedFile.path,
      isSessionCurrent: isSessionCurrent,
    );
  }

  Future<String> persistExistingPhoto({
    required int clientLocalId,
    required String sourcePath,
  }) {
    return _persistPhoto(
      clientLocalId: clientLocalId,
      sourcePath: sourcePath,
    );
  }

  Future<String> persistExistingPhotoForSession({
    required int clientLocalId,
    required String sourcePath,
    required SessionSnapshot session,
    required bool Function() isSessionCurrent,
  }) {
    // Keep [session] in this API so callers must deliberately capture a
    // snapshot instead of providing a mutable global-token predicate.
    return _persistPhoto(
      clientLocalId: clientLocalId,
      sourcePath: sourcePath,
      isSessionCurrent: isSessionCurrent,
    );
  }

  Future<void> deletePhoto(String photoPath) async {
    if (isRemotePhotoPath(photoPath)) {
      return;
    }

    final localPath = _normalizeLocalPath(photoPath);
    final file = File(localPath);
    if (await file.exists()) {
      await _fileDeleter(file);
    }
  }

  /// Removes local media only while its captured session remains valid. If a
  /// logout wins while the awaited delete completes, restore the bytes before
  /// surfacing [StaleSessionException]; the provider/SQLite caller therefore
  /// cannot detach the photo from its retained tenant work.
  Future<void> deletePhotoForSession(
    String photoPath, {
    required SessionSnapshot session,
    required bool Function() isSessionCurrent,
  }) async {
    if (isRemotePhotoPath(photoPath)) return;
    _requireCurrent(isSessionCurrent);
    final file = File(_normalizeLocalPath(photoPath));
    if (!await file.exists()) return;
    _requireCurrent(isSessionCurrent);
    final bytes = await file.readAsBytes();
    _requireCurrent(isSessionCurrent);
    await _fileDeleter(file);
    if (isSessionCurrent()) return;
    // A delete is not transaction-capable, so write the retained tenant file
    // back before throwing when invalidation raced its asynchronous I/O.
    await file.writeAsBytes(bytes, flush: true);
    throw const StaleSessionException();
  }

  bool isRemotePhotoPath(String photoPath) {
    final uri = Uri.tryParse(photoPath);
    return (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) ||
        photoPath.startsWith('/api/photos/client/');
  }

  ImageProvider<Object> buildImageProvider(
    String photoPath, {
    ApiService? apiService,
  }) =>
      _buildImageProvider(
        photoPath,
        apiService: apiService,
        session: null,
      );

  /// Network image headers must come from the immutable session capability,
  /// rather than the API service's mutable bearer token.
  ImageProvider<Object> buildImageProviderForSession(
    String photoPath, {
    required ApiService apiService,
    required SessionSnapshot session,
    required bool Function() isSessionCurrent,
  }) =>
      _buildImageProvider(
        photoPath,
        apiService: apiService,
        session: session,
        isSessionCurrent: isSessionCurrent,
      );

  ImageProvider<Object> _buildImageProvider(
    String photoPath, {
    required ApiService? apiService,
    required SessionSnapshot? session,
    bool Function()? isSessionCurrent,
  }) {
    if (isRemotePhotoPath(photoPath)) {
      final resolvedUrl = apiService?.resolveProtectedClientPhotoUrl(photoPath);
      if (resolvedUrl == null) {
        throw ArgumentError('Photo URL is not on the configured server.');
      }
      final headers = apiService?.authenticatedHeadersFor(session) ?? const {};
      if (session != null && isSessionCurrent != null) {
        return SessionNetworkImage(
          url: resolvedUrl,
          headers: headers,
          session: session,
          isSessionCurrent: isSessionCurrent,
        );
      }
      if (headers.isNotEmpty) {
        throw StateError(
          'Protected client photos require an active session image provider.',
        );
      }
      return NetworkImage(resolvedUrl, headers: headers);
    }

    return FileImage(File(_normalizeLocalPath(photoPath)));
  }

  String _normalizeLocalPath(String photoPath) {
    final uri = Uri.tryParse(photoPath);
    if (uri != null && uri.scheme == 'file') {
      return uri.toFilePath();
    }

    return photoPath;
  }

  Future<String> _persistPhoto({
    required int clientLocalId,
    required String sourcePath,
    bool Function()? isSessionCurrent,
  }) async {
    _requireCurrent(isSessionCurrent);
    final documentsDir = await _directoryProvider();
    _requireCurrent(isSessionCurrent);
    final clientDir = Directory(
      path.join(documentsDir.path, 'client_photos', 'client_$clientLocalId'),
    );

    if (!await clientDir.exists()) {
      await clientDir.create(recursive: true);
    }
    _requireCurrent(isSessionCurrent);

    final extension = path.extension(sourcePath).trim().isNotEmpty
        ? path.extension(sourcePath)
        : '.jpg';
    final fileName = 'photo_${DateTime.now().microsecondsSinceEpoch}$extension';
    final destinationPath = path.join(clientDir.path, fileName);

    final sourceFile = File(sourcePath);
    final destinationFile = File(destinationPath);
    _requireCurrent(isSessionCurrent);
    File? copiedFile;
    try {
      copiedFile = await _fileCopier(sourceFile, destinationPath);
      _requireCurrent(isSessionCurrent);
      return copiedFile.path;
    } on StaleSessionException {
      final staleFile = copiedFile ?? destinationFile;
      if (await staleFile.exists()) await staleFile.delete();
      rethrow;
    } catch (_) {
      // A copier may fail after creating a destination. If logout won that
      // race, clean the partially persisted tenant file as well.
      if (isSessionCurrent?.call() == false && await destinationFile.exists()) {
        await destinationFile.delete();
      }
      rethrow;
    }
  }

  void _requireCurrent(bool Function()? isSessionCurrent) {
    if (isSessionCurrent?.call() == false) {
      throw const StaleSessionException();
    }
  }
}
