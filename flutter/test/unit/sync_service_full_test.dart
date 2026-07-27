import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/default_price.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_service_full_test.mocks.dart';

@GenerateMocks([ApiService, DbService])
void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('sync service with mock server response', () async {
    final mockApi = MockApiService();
    final mockDb = MockDbService();

    when(mockDb.getDirtyClients()).thenAnswer((_) async => []);
    when(mockDb.getDirtyItems()).thenAnswer((_) async => []);
    when(mockDb.getDirtyRectangles()).thenAnswer((_) async => []);
    when(mockDb.getDirtyWarranties()).thenAnswer((_) async => []);
    when(mockDb.getDirtyProposals()).thenAnswer((_) async => []);
    when(mockDb.getClients()).thenAnswer((_) async => []);

    final response = {
      'server_time': DateTime.now().toIso8601String(),
      'updates': {
        'clients': [
          {
            'remote_id': 'c1',
            'name': 'Client 1',
            'updated_at': DateTime.now().toIso8601String(),
            'deleted_at': null,
          }
        ],
        'items': [
          {
            'remote_id': 'i1',
            'client_id': 'c1', // STRING
            'name': 'Item 1',
            'price': 100.0,
            'enabled': true,
            'updated_at': DateTime.now().toIso8601String(),
            'deleted_at': null,
          }
        ],
        'rectangles': [
          {
            'remote_id': 'r1',
            'item_id': 'i1', // STRING
            'length': 10.0,
            'width': 10.0,
            'updated_at': DateTime.now().toIso8601String(),
            'deleted_at': null,
          }
        ]
      }
    };

    when(mockApi.sync(any)).thenAnswer((_) async => response);

    when(mockDb.getClientByRemoteId('c1'))
        .thenAnswer((_) async => Client(localId: 1, remoteId: 'c1', name: 'c'));
    when(mockDb.getItemByRemoteId('i1')).thenAnswer((_) async => null);
    when(mockDb.getRectangleByRemoteId('r1')).thenAnswer((_) async => null);

    when(mockDb.insertClient(any)).thenAnswer((_) async => 1);
    when(mockDb.updateClient(any)).thenAnswer((_) async => 1);
    when(mockDb.insertItem(any)).thenAnswer((_) async => 1);
    when(mockDb.insertRectangle(any)).thenAnswer((_) async => 1);

    final syncService = SyncService(apiService: mockApi, dbService: mockDb);
    await syncService.sync();
  });

  test('uploads local photos and never includes device paths in sync payload',
      () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    final now = DateTime.utc(2026, 7, 25).toIso8601String();
    final client = Client(
      localId: 1,
      remoteId: 'client-remote-id',
      franchiseeId: 'tenant-a',
      name: 'Acme',
      photos: const ['/documents/client_photos/offline.jpg'],
      updatedAt: DateTime.parse(now),
    );
    when(mockDb.getClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyItems()).thenAnswer((_) async => []);
    when(mockDb.getDirtyRectangles()).thenAnswer((_) async => []);
    when(mockDb.getDirtyDefaultPrices('tenant-a')).thenAnswer((_) async => []);
    when(mockDb.getDirtyWarranties()).thenAnswer((_) async => []);
    when(mockDb.getDirtyProposals()).thenAnswer((_) async => []);
    when(mockApi.uploadClientPhoto(
      'client-remote-id',
      '/documents/client_photos/offline.jpg',
    )).thenAnswer(
        (_) async => '/api/photos/client/client-remote-id/server.jpg');
    when(mockDb.updateClient(any)).thenAnswer((_) async => 1);
    when(mockDb.markAsSynced(any, any, franchiseeId: anyNamed('franchiseeId')))
        .thenAnswer((_) async {});
    Map<String, dynamic>? syncPayload;
    when(mockApi.sync(any)).thenAnswer((invocation) async {
      syncPayload =
          invocation.positionalArguments.single as Map<String, dynamic>;
      return {
        'server_time': now,
        'updates': {'clients': [], 'items': [], 'rectangles': []},
      };
    });

    await SyncService(apiService: mockApi, dbService: mockDb).sync();

    final photos =
        syncPayload!['changes']['clients'].single['photos'] as String;
    expect(photos, contains('/api/photos/client/client-remote-id/server.jpg'));
    expect(photos, isNot(contains('/documents/client_photos/offline.jpg')));
    verify(mockDb.updateClient(argThat(isA<Client>().having(
      (updated) => updated.photos.single,
      'photo',
      '/api/photos/client/client-remote-id/server.jpg',
    )))).called(1);
    verify(mockDb.markAsSynced('clients', 'client-remote-id')).called(1);
  });

  test('failed photo upload survives the server client update and stays dirty',
      () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    final now = DateTime.utc(2026, 7, 25).toIso8601String();
    final client = Client(
      localId: 1,
      remoteId: 'client-remote-id',
      franchiseeId: 'tenant-a',
      name: 'Acme',
      photos: const ['/documents/client_photos/offline.jpg'],
      updatedAt: DateTime.parse(now),
    );
    when(mockDb.getClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyItems()).thenAnswer((_) async => []);
    when(mockDb.getDirtyRectangles()).thenAnswer((_) async => []);
    when(mockDb.getDirtyDefaultPrices('tenant-a')).thenAnswer((_) async => []);
    when(mockDb.getDirtyWarranties()).thenAnswer((_) async => []);
    when(mockDb.getDirtyProposals()).thenAnswer((_) async => []);
    when(mockApi.uploadClientPhoto(any, any))
        .thenThrow(const ApiException('offline'));
    when(mockDb.getClientByRemoteId('client-remote-id'))
        .thenAnswer((_) async => client);
    when(mockDb.updateClient(any)).thenAnswer((_) async => 1);
    when(mockApi.sync(any)).thenAnswer((_) async => {
          'server_time': now,
          'updates': {
            'clients': [
              {
                'remote_id': 'client-remote-id',
                'franchisee_id': 'tenant-a',
                'name': 'Acme from server',
                'photos': '["/api/photos/client/client-remote-id/server.jpg"]',
                'updated_at': now,
                'deleted_at': null,
              },
            ],
            'items': [],
            'rectangles': [],
          },
        });

    await SyncService(apiService: mockApi, dbService: mockDb).sync();

    verify(mockDb.updateClient(argThat(isA<Client>()
        .having((updated) => updated.isDirty, 'isDirty', isTrue)
        .having((updated) => updated.photos, 'photos', [
      '/api/photos/client/client-remote-id/server.jpg',
      '/documents/client_photos/offline.jpg',
    ])))).called(1);
    verifyNever(mockDb.markAsSynced('clients', 'client-remote-id'));
  });

  test('syncs default prices only for the active franchisee', () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    final now = DateTime.utc(2026, 7, 25).toIso8601String();
    final pushed = DefaultPrice(
      franchiseeId: 'tenant-a',
      remoteId: 'pushed-price',
      price: 12.5,
      updatedAt: DateTime.parse(now),
    );
    final deleted = DefaultPrice(
      localId: 7,
      franchiseeId: 'tenant-a',
      remoteId: 'deleted-price',
      price: 9,
      updatedAt: DateTime.parse(now),
    );

    when(mockDb.getClients()).thenAnswer((_) async => []);
    when(mockDb.getDirtyClients()).thenAnswer((_) async => []);
    when(mockDb.getDirtyItems()).thenAnswer((_) async => []);
    when(mockDb.getDirtyRectangles()).thenAnswer((_) async => []);
    when(mockDb.getDirtyDefaultPrices('tenant-a'))
        .thenAnswer((_) async => [pushed]);
    when(mockDb.getDirtyWarranties()).thenAnswer((_) async => []);
    when(mockDb.getDirtyProposals()).thenAnswer((_) async => []);
    when(mockDb.getDefaultPriceByRemoteId('downloaded-price', 'tenant-a'))
        .thenAnswer((_) async => null);
    when(mockDb.getDefaultPriceByRemoteId('deleted-price', 'tenant-a'))
        .thenAnswer((_) async => deleted);
    when(mockDb.insertDefaultPrice(any, franchiseeId: anyNamed('franchiseeId')))
        .thenAnswer((_) async => 1);
    when(mockDb.deleteDefaultPrice(any, franchiseeId: anyNamed('franchiseeId')))
        .thenAnswer((_) async => 1);
    when(mockDb.markAsSynced(any, any, franchiseeId: anyNamed('franchiseeId')))
        .thenAnswer((_) async {});

    Map<String, dynamic>? syncPayload;
    when(mockApi.sync(any)).thenAnswer((invocation) async {
      syncPayload =
          invocation.positionalArguments.single as Map<String, dynamic>;
      return {
        'server_time': now,
        'updates': {
          'clients': [],
          'items': [],
          'rectangles': [],
          'default_prices': [
            {
              'remote_id': 'downloaded-price',
              'price': 20.0,
              'enabled': true,
              'updated_at': now,
              'deleted_at': null,
            },
            {
              'remote_id': 'deleted-price',
              'price': 9.0,
              'enabled': true,
              'updated_at': now,
              'deleted_at': now,
            },
          ],
        },
      };
    });

    await SyncService(apiService: mockApi, dbService: mockDb).sync();

    expect(syncPayload!['changes']['default_prices'], [pushed.toJson()]);
    verify(mockDb.insertDefaultPrice(
      argThat(isA<DefaultPrice>().having(
        (price) => price.franchiseeId,
        'franchiseeId',
        'tenant-a',
      )),
      franchiseeId: 'tenant-a',
    )).called(1);
    verify(mockDb.deleteDefaultPrice(7, franchiseeId: 'tenant-a')).called(1);
    verify(mockDb.markAsSynced('default_prices', 'deleted-price',
            franchiseeId: 'tenant-a'))
        .called(1);
    verify(mockDb.markAsSynced('default_prices', 'pushed-price',
            franchiseeId: 'tenant-a'))
        .called(1);
  });
}
