import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/default_price.dart';
import 'package:app_client/src/models/warranty.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_service_full_test.mocks.dart';

@GenerateMocks([ApiService, DbService])
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('sync service with mock server response', () async {
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    when(mockDb.supportsSyncV2()).thenAnswer((_) async => false);

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
    when(mockDb.supportsSyncV2()).thenAnswer((_) async => false);
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
    when(mockDb.getWarrantyTombstoneCursor('tenant-a'))
        .thenAnswer((_) async => '0');
    when(mockDb.applyWarrantyTombstonesAndCursor(
      any,
      franchiseeId: anyNamed('franchiseeId'),
      cursor: anyNamed('cursor'),
    )).thenAnswer((_) async {});
    when(mockApi.uploadClientPhoto(
      'client-remote-id',
      '/documents/client_photos/offline.jpg',
    )).thenAnswer(
        (_) async => '/api/photos/client/client-remote-id/server.jpg');
    when(mockDb.updateClient(any)).thenAnswer((_) async => 1);
    when(mockDb.markAsSynced(
      any,
      any,
      franchiseeId: anyNamed('franchiseeId'),
      submittedUpdatedAt: anyNamed('submittedUpdatedAt'),
    )).thenAnswer((_) async => 1);
    Map<String, dynamic>? syncPayload;
    when(mockApi.sync(any)).thenAnswer((invocation) async {
      syncPayload =
          invocation.positionalArguments.single as Map<String, dynamic>;
      return {
        'server_time': now,
        'warranty_tombstone_cursor': '0',
        'outcomes': {
          'clients': [
            {'remote_id': 'client-remote-id', 'status': 'applied'}
          ],
        },
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
    verify(mockDb.markAsSynced(
      'clients',
      'client-remote-id',
      franchiseeId: anyNamed('franchiseeId'),
      submittedUpdatedAt: anyNamed('submittedUpdatedAt'),
    )).called(1);
  });

  test(
      'failed photo upload omits the client mutation and preserves server photos',
      () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    when(mockDb.supportsSyncV2()).thenAnswer((_) async => false);
    final now = DateTime.utc(2026, 7, 25).toIso8601String();
    final client = Client(
      localId: 1,
      remoteId: 'client-remote-id',
      franchiseeId: 'tenant-a',
      name: 'Acme',
      photos: const [
        '/api/photos/client/client-remote-id/before.jpg',
        '/documents/client_photos/offline.jpg',
        '/api/photos/client/client-remote-id/after.jpg',
      ],
      updatedAt: DateTime.parse(now),
    );
    when(mockDb.getClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyItems()).thenAnswer((_) async => []);
    when(mockDb.getDirtyRectangles()).thenAnswer((_) async => []);
    when(mockDb.getDirtyDefaultPrices('tenant-a')).thenAnswer((_) async => []);
    when(mockDb.getDirtyWarranties()).thenAnswer((_) async => []);
    when(mockDb.getDirtyProposals()).thenAnswer((_) async => []);
    when(mockDb.getWarrantyTombstoneCursor('tenant-a'))
        .thenAnswer((_) async => '0');
    when(mockDb.applyWarrantyTombstonesAndCursor(
      any,
      franchiseeId: anyNamed('franchiseeId'),
      cursor: anyNamed('cursor'),
    )).thenAnswer((_) async {});
    when(mockApi.uploadClientPhoto(any, any))
        .thenThrow(const ApiException('offline'));
    when(mockDb.getClientByRemoteId('client-remote-id'))
        .thenAnswer((_) async => client);
    when(mockDb.updateClient(any)).thenAnswer((_) async => 1);
    Map<String, dynamic>? syncPayload;
    when(mockApi.sync(any)).thenAnswer((invocation) async {
      syncPayload =
          invocation.positionalArguments.single as Map<String, dynamic>;
      return {
        'server_time': now,
        'warranty_tombstone_cursor': '0',
        'outcomes': {
          'clients': [],
        },
        'updates': {
          'clients': [
            {
              'remote_id': 'client-remote-id',
              'franchisee_id': 'tenant-a',
              'name': 'Acme from server',
              'photos':
                  '["/api/photos/client/client-remote-id/before.jpg","/api/photos/client/client-remote-id/after.jpg"]',
              'updated_at': now,
              'deleted_at': null,
            },
          ],
          'items': [],
          'rectangles': [],
        },
      };
    });

    await SyncService(apiService: mockApi, dbService: mockDb).sync();

    expect(syncPayload!['changes']['clients'], isEmpty);
    verify(mockDb.updateClient(argThat(isA<Client>()
        .having((updated) => updated.isDirty, 'isDirty', isTrue)
        .having((updated) => updated.photos, 'photos', [
      '/api/photos/client/client-remote-id/before.jpg',
      '/api/photos/client/client-remote-id/after.jpg',
      '/documents/client_photos/offline.jpg',
    ])))).called(1);
    verifyNever(mockDb.markAsSynced(
      'clients',
      'client-remote-id',
      submittedUpdatedAt: anyNamed('submittedUpdatedAt'),
    ));
  });

  test('syncs default prices only for the active franchisee', () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    when(mockDb.supportsSyncV2()).thenAnswer((_) async => false);
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
    when(mockDb.getWarrantyTombstoneCursor('tenant-a'))
        .thenAnswer((_) async => '0');
    when(mockDb.applyWarrantyTombstonesAndCursor(
      any,
      franchiseeId: anyNamed('franchiseeId'),
      cursor: anyNamed('cursor'),
    )).thenAnswer((_) async {});
    when(mockDb.getDefaultPriceByRemoteId('downloaded-price', 'tenant-a'))
        .thenAnswer((_) async => null);
    when(mockDb.getDefaultPriceByRemoteId('deleted-price', 'tenant-a'))
        .thenAnswer((_) async => deleted);
    when(mockDb.insertDefaultPrice(any, franchiseeId: anyNamed('franchiseeId')))
        .thenAnswer((_) async => 1);
    when(mockDb.deleteDefaultPrice(any, franchiseeId: anyNamed('franchiseeId')))
        .thenAnswer((_) async => 1);
    when(mockDb.markAsSynced(
      any,
      any,
      franchiseeId: anyNamed('franchiseeId'),
      submittedUpdatedAt: anyNamed('submittedUpdatedAt'),
    )).thenAnswer((_) async => 1);

    Map<String, dynamic>? syncPayload;
    when(mockApi.sync(any)).thenAnswer((invocation) async {
      syncPayload =
          invocation.positionalArguments.single as Map<String, dynamic>;
      return {
        'server_time': now,
        'warranty_tombstone_cursor': '0',
        'outcomes': {
          'default_prices': [
            {'remote_id': 'pushed-price', 'status': 'applied'}
          ],
        },
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
    verifyNever(mockDb.markAsSynced(
      'default_prices',
      'deleted-price',
      franchiseeId: 'tenant-a',
      submittedUpdatedAt: anyNamed('submittedUpdatedAt'),
    ));
    verify(mockDb.markAsSynced('default_prices', 'pushed-price',
            franchiseeId: 'tenant-a', submittedUpdatedAt: now))
        .called(1);
  });

  test('applies a permanent tombstone before live warranty data', () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    when(mockDb.supportsSyncV2()).thenAnswer((_) async => false);
    final now = DateTime.utc(2026, 7, 30).toIso8601String();
    final client = Client(
      localId: 1,
      remoteId: 'client-1',
      franchiseeId: 'tenant-a',
      name: 'Client',
    );
    final dirty = Warranty(
      localId: 2,
      remoteId: 'deleted-warranty',
      clientId: 1,
      warrantyCardNumber: 'CARD-1',
      startDate: DateTime.utc(2026),
      durationYears: 5,
      pdfUrl: '/api/warranty/deleted-warranty/download',
    );
    when(mockDb.getClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyClients()).thenAnswer((_) async => []);
    when(mockDb.getDirtyItems()).thenAnswer((_) async => []);
    when(mockDb.getDirtyRectangles()).thenAnswer((_) async => []);
    when(mockDb.getDirtyDefaultPrices('tenant-a')).thenAnswer((_) async => []);
    when(mockDb.getDirtyWarranties()).thenAnswer((_) async => [dirty]);
    when(mockDb.getDirtyProposals()).thenAnswer((_) async => []);
    when(mockDb.getWarrantyTombstoneCursor('tenant-a'))
        .thenAnswer((_) async => '0');
    when(mockDb.applyWarrantyTombstonesAndCursor(
      any,
      franchiseeId: anyNamed('franchiseeId'),
      cursor: anyNamed('cursor'),
    )).thenAnswer((_) async {});
    when(mockDb.hasWarrantyTombstone(
      'deleted-warranty',
      franchiseeId: 'tenant-a',
    )).thenAnswer((_) async => true);
    when(mockDb.hardDeleteWarrantyByRemoteId('deleted-warranty'))
        .thenAnswer((_) async => 1);
    when(mockApi.sync(any)).thenAnswer((_) async => {
          'server_time': now,
          'warranty_tombstone_cursor': '7',
          'outcomes': {
            'warranties': [
              {'remote_id': 'deleted-warranty', 'status': 'tombstoned'}
            ],
          },
          'updates': {
            'clients': [],
            'items': [],
            'rectangles': [],
            'default_prices': [],
            'warranty_tombstones': [
              {
                'warranty_id': 'deleted-warranty',
                'deletion_sequence': '7',
                'deleted_at': now,
              },
            ],
            // A stale/malformed response containing both must still converge to
            // the tombstone rather than recreating the warranty.
            'warranties': [
              {
                'remote_id': 'deleted-warranty',
                'client_id': 'client-1',
                'version': 1,
                'warranty_card_number': 'CARD-1',
                'start_date': now,
                'duration_years': 5,
                'pdf_url': '/api/warranty/deleted-warranty/download',
                'updated_at': now,
                'deleted_at': null,
              },
            ],
            'proposals': [],
          },
        });

    await SyncService(apiService: mockApi, dbService: mockDb).sync();

    verifyInOrder([
      mockDb.applyWarrantyTombstonesAndCursor(
        any,
        franchiseeId: 'tenant-a',
        cursor: '7',
      ),
      mockDb.hasWarrantyTombstone(
        'deleted-warranty',
        franchiseeId: 'tenant-a',
      ),
      mockDb.hardDeleteWarrantyByRemoteId('deleted-warranty'),
    ]);
    verifyNever(mockDb.insertWarranty(any));
  });

  test('a foreign-reservation conflict retains the local dirty warranty',
      () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    final mockApi = MockApiService();
    final mockDb = MockDbService();
    when(mockDb.supportsSyncV2()).thenAnswer((_) async => false);
    final now = DateTime.utc(2026, 7, 30).toIso8601String();
    final client = Client(
      localId: 1,
      remoteId: 'client-1',
      franchiseeId: 'tenant-a',
      name: 'Client',
    );
    final dirty = Warranty(
      localId: 2,
      remoteId: 'rejected-warranty',
      clientId: 1,
      warrantyCardNumber: 'CARD-2',
      startDate: DateTime.utc(2026),
      durationYears: 5,
      pdfUrl: '/api/warranty/rejected-warranty/download',
    );
    when(mockDb.getClients()).thenAnswer((_) async => [client]);
    when(mockDb.getDirtyClients()).thenAnswer((_) async => []);
    when(mockDb.getDirtyItems()).thenAnswer((_) async => []);
    when(mockDb.getDirtyRectangles()).thenAnswer((_) async => []);
    when(mockDb.getDirtyDefaultPrices('tenant-a')).thenAnswer((_) async => []);
    when(mockDb.getDirtyWarranties()).thenAnswer((_) async => [dirty]);
    when(mockDb.getDirtyProposals()).thenAnswer((_) async => []);
    when(mockDb.getWarrantyTombstoneCursor('tenant-a'))
        .thenAnswer((_) async => '0');
    when(mockDb.applyWarrantyTombstonesAndCursor(
      any,
      franchiseeId: anyNamed('franchiseeId'),
      cursor: anyNamed('cursor'),
    )).thenAnswer((_) async {});
    when(mockApi.sync(any)).thenAnswer((_) async => {
          'server_time': now,
          'warranty_tombstone_cursor': '0',
          'outcomes': {
            'warranties': [
              {
                'remote_id': 'rejected-warranty',
                'status': 'rejected',
                'code': 'warranty_conflict',
              }
            ],
          },
          'updates': {
            'clients': [],
            'items': [],
            'rectangles': [],
            'default_prices': [],
            'warranty_tombstones': [],
            'warranties': [],
            'proposals': [],
          },
        });

    await SyncService(apiService: mockApi, dbService: mockDb).sync();

    verifyNever(mockDb.markAsSynced(
      'warranties',
      'rejected-warranty',
      submittedUpdatedAt: anyNamed('submittedUpdatedAt'),
    ));
    verifyNever(mockDb.hardDeleteWarrantyByRemoteId('rejected-warranty'));
  });
}
