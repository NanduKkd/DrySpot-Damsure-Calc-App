import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/client_photo_service.dart';
import 'package:app_client/src/services/session_manager.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('relative client photo URLs resolve with authentication headers', () {
    final apiService = ApiService(serverUrl: 'https://photos.example.test');
    apiService.setToken('photo-token');
    final photoService = ClientPhotoService();

    expect(photoService.isRemotePhotoPath('/api/photos/client/c1/image.jpg'),
        isTrue);
    final image = photoService.buildImageProvider(
      '/api/photos/client/c1/image.jpg',
      apiService: apiService,
    ) as NetworkImage;

    expect(image.url,
        'https://photos.example.test/api/photos/client/c1/image.jpg');
    expect(image.headers, {'Authorization': 'Bearer photo-token'});
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
    ) as NetworkImage;

    expect(image.headers, {'Authorization': 'Bearer captured-a-token'});
  });
}
