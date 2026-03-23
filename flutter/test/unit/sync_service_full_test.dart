import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/models/client.dart';
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

    when(mockDb.getClientByRemoteId('c1')).thenAnswer((_) async => Client(localId: 1, remoteId: 'c1', name: 'c'));
    when(mockDb.getItemByRemoteId('i1')).thenAnswer((_) async => null);
    when(mockDb.getRectangleByRemoteId('r1')).thenAnswer((_) async => null);

    when(mockDb.insertClient(any)).thenAnswer((_) async => 1);
    when(mockDb.updateClient(any)).thenAnswer((_) async => 1);
    when(mockDb.insertItem(any)).thenAnswer((_) async => 1);
    when(mockDb.insertRectangle(any)).thenAnswer((_) async => 1);

    final syncService = SyncService(apiService: mockApi, dbService: mockDb);
    await syncService.sync();
  });
}
