import 'dart:typed_data';

import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/screens/clients/client_photo_gallery_screen.dart';
import 'package:app_client/src/screens/clients/client_photo_preview_screen.dart';
import 'package:app_client/src/services/client_photo_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class MockClientProvider extends ClientProvider {
  MockClientProvider(this._client);

  Client _client;
  Client? updatedClient;

  @override
  List<Client> get clients => [updatedClient ?? _client];

  @override
  Future<void> updateClient(Client client) async {
    updatedClient = client;
    _client = client;
    notifyListeners();
  }
}

class FakeClientPhotoService extends ClientPhotoService {
  FakeClientPhotoService({this.returnedPhotoPath = '/tmp/client_photo.jpg'});

  final String returnedPhotoPath;
  final List<String> deletedPhotoPaths = [];
  ImageSource? lastSource;
  int addPhotoCallCount = 0;

  static final Uint8List _transparentImage = Uint8List.fromList(<int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  @override
  Future<String?> addPhoto({
    required int clientLocalId,
    required ImageSource source,
  }) async {
    addPhotoCallCount++;
    lastSource = source;
    return returnedPhotoPath;
  }

  @override
  Future<void> deletePhoto(String photoPath) async {
    deletedPhotoPaths.add(photoPath);
  }

  @override
  ImageProvider<Object> buildImageProvider(String photoPath) {
    return MemoryImage(_transparentImage);
  }
}

void main() {
  Widget buildTestApp({
    required Client client,
    required MockClientProvider provider,
    required FakeClientPhotoService photoService,
  }) {
    return ChangeNotifierProvider<ClientProvider>.value(
      value: provider,
      child: MaterialApp(
        home: ClientPhotoGalleryScreen(
          client: client,
          photoService: photoService,
        ),
      ),
    );
  }

  testWidgets('ClientPhotoGalleryScreen adds uploaded photo to client',
      (tester) async {
    final client = Client(name: 'Acme', localId: 1, photos: const []);
    final provider = MockClientProvider(client);
    final photoService = FakeClientPhotoService();

    await tester.pumpWidget(
      buildTestApp(
        client: client,
        provider: provider,
        photoService: photoService,
      ),
    );

    expect(find.text('No photos added for this client yet.'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Upload Photo'));
    await tester.pumpAndSettle();

    expect(photoService.addPhotoCallCount, 1);
    expect(photoService.lastSource, ImageSource.gallery);
    expect(provider.updatedClient?.photos, contains('/tmp/client_photo.jpg'));
    expect(find.text('Photo added to this client.'), findsOneWidget);
  });

  testWidgets('ClientPhotoGalleryScreen deletes photo from client',
      (tester) async {
    final client = Client(
      name: 'Acme',
      localId: 1,
      photos: const ['/tmp/existing_photo.jpg'],
    );
    final provider = MockClientProvider(client);
    final photoService = FakeClientPhotoService();

    await tester.pumpWidget(
      buildTestApp(
        client: client,
        provider: provider,
        photoService: photoService,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('clientPhotoDelete_0')));
    await tester.pumpAndSettle();

    expect(find.text('Delete Photo'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(provider.updatedClient?.photos, isEmpty);
    expect(photoService.deletedPhotoPaths, contains('/tmp/existing_photo.jpg'));
    expect(find.text('Photo deleted.'), findsOneWidget);
  });

  testWidgets('ClientPhotoGalleryScreen opens preview screen on tap',
      (tester) async {
    final client = Client(
      name: 'Acme',
      localId: 1,
      photos: const ['/tmp/existing_photo.jpg'],
    );
    final provider = MockClientProvider(client);
    final photoService = FakeClientPhotoService();

    await tester.pumpWidget(
      buildTestApp(
        client: client,
        provider: provider,
        photoService: photoService,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('clientPhotoTile_0')));
    await tester.pumpAndSettle();

    expect(find.byType(ClientPhotoPreviewScreen), findsOneWidget);
  });
}
