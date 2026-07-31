import 'dart:async';
import 'dart:io';

import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/client_photo_service.dart';
import 'package:app_client/src/services/session_manager.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('relative client photo URLs resolve with authentication headers', () {
    final apiService = ApiService(serverUrl: 'https://photos.example.test');
    final photoService = ClientPhotoService();

    expect(photoService.isRemotePhotoPath('/api/photos/client/c1/image.jpg'),
        isTrue);
    final image = photoService.buildImageProvider(
      '/api/photos/client/c1/image.jpg',
      apiService: apiService,
    ) as NetworkImage;

    expect(image.url,
        'https://photos.example.test/api/photos/client/c1/image.jpg');
    expect(image.headers, isEmpty);
  });

  test('rejects a protected legacy NetworkImage without a session snapshot',
      () {
    final apiService = ApiService(serverUrl: 'https://photos.example.test');
    apiService.setToken('photo-token');
    final photoService = ClientPhotoService();

    expect(
      () => photoService.buildImageProvider(
        '/api/photos/client/c1/image.jpg',
        apiService: apiService,
      ),
      throwsStateError,
    );
  });

  test('does not resolve photo URLs from arbitrary hosts', () {
    final apiService = ApiService(serverUrl: 'https://photos.example.test');
    final photoService = ClientPhotoService();

    expect(
      apiService.resolveProtectedClientPhotoUrl(
        'https://attacker.example/api/photos/client/c1/image.jpg',
      ),
      isNull,
    );
    expect(
      () => photoService.buildImageProvider(
        'https://attacker.example/api/photos/client/c1/image.jpg',
        apiService: apiService,
      ),
      throwsArgumentError,
    );
  });

  test('session-bound photo reads retain the captured bearer token', () {
    final apiService = ApiService(serverUrl: 'https://photos.example.test');
    apiService.setToken('new-session-token');
    final photoService = ClientPhotoService();
    const session = SessionSnapshot(
      token: 'captured-a-token',
      userName: null,
      franchiseeId: 'tenant-a',
      franchiseeName: null,
      generation: 7,
    );

    final image = photoService.buildImageProviderForSession(
      '/api/photos/client/c1/image.jpg',
      apiService: apiService,
      session: session,
      isSessionCurrent: () => true,
    ) as SessionNetworkImage;

    expect(image.headers, {'Authorization': 'Bearer captured-a-token'});
  });

  test('a deferred remote image cannot send its captured bearer after logout',
      () async {
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.idleTimeout = Duration.zero;
    server.listen((request) async {
      requestCount++;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });
    addTearDown(server.close);

    final sessions = SessionManager();
    final session = sessions.activate(token: 'captured-a', franchiseeId: 'a');
    final image = ClientPhotoService().buildImageProviderForSession(
      '/api/photos/client/c1/image.jpg',
      apiService:
          ApiService(serverUrl: 'http://${server.address.host}:${server.port}'),
      session: session,
      isSessionCurrent: () => sessions.isCurrent(session),
    ) as SessionNetworkImage;

    // Constructing an ImageProvider does not start a request. It becomes
    // stale before Flutter resolves it, so the load-time guard must reject it
    // before HttpClientRequest.close can send the captured bearer.
    sessions.invalidate();
    final error = Completer<Object>();
    image.resolve(const ImageConfiguration()).addListener(
          ImageStreamListener(
            (_, __) {},
            onError: (exception, stackTrace) {
              if (!error.isCompleted) error.complete(exception);
            },
          ),
        );
    expect(await error.future, isA<StaleSessionException>());
    expect(requestCount, 0);
  });

  test('a stale local photo copy is deleted before it can be attached',
      () async {
    final root = await Directory.systemTemp.createTemp('app106-photo-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source.jpg');
    await source.writeAsBytes([1, 2, 3]);
    final sessions = SessionManager();
    final session = sessions.activate(token: 'a', franchiseeId: 'tenant-a');
    final service = ClientPhotoService(
      directoryProvider: () async => root,
      fileCopier: (input, destination) async {
        final copied = await input.copy(destination);
        // This models logout while an awaited persistence copy completes.
        sessions.invalidate();
        return copied;
      },
    );

    await expectLater(
      service.persistExistingPhotoForSession(
        clientLocalId: 7,
        sourcePath: source.path,
        session: session,
        isSessionCurrent: () => sessions.isCurrent(session),
      ),
      throwsA(isA<StaleSessionException>()),
    );

    final photoDir = Directory('${root.path}/client_photos/client_7');
    expect(
      await photoDir.list().where((entry) => entry is File).toList(),
      isEmpty,
    );
  });

  test('a local photo deletion is rolled back when logout races it', () async {
    final root = await Directory.systemTemp.createTemp('app106-delete-');
    addTearDown(() => root.delete(recursive: true));
    final photo = File('${root.path}/retained.jpg');
    await photo.writeAsBytes([7, 8, 9]);
    final sessions = SessionManager();
    final session = sessions.activate(token: 'a', franchiseeId: 'tenant-a');
    final service = ClientPhotoService(
      fileDeleter: (file) async {
        await file.delete();
        // Invalidation happens while the deletion future is resolving.
        sessions.invalidate();
      },
    );

    await expectLater(
      service.deletePhotoForSession(
        photo.path,
        session: session,
        isSessionCurrent: () => sessions.isCurrent(session),
      ),
      throwsA(isA<StaleSessionException>()),
    );

    expect(await photo.exists(), isTrue);
    expect(await photo.readAsBytes(), [7, 8, 9]);
  });
}
