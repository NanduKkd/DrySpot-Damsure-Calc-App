import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:app_client/src/models/client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockApiService extends ApiService {
  Map<String, dynamic>? lastSyncData;
  Map<String, dynamic> response = {
    'server_time': '2024-03-22T12:00:00Z',
    'updates': {
      'clients': [],
      'items': [],
      'rectangles': [],
    }
  };

  @override
  Future<Map<String, dynamic>> sync(Map<String, dynamic> data) async {
    lastSyncData = data;
    return response;
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DbService dbService;
  late Database database;
  late MockApiService apiService;
  late SyncService syncService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = await openDatabase(inMemoryDatabasePath, version: 1, onCreate: (db, version) async {
         await db.execute('''
          CREATE TABLE clients (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT UNIQUE,
            franchisee_id TEXT,
            name TEXT NOT NULL,
            address TEXT,
            email TEXT,
            phone TEXT,
            latitude REAL,
            longitude REAL,
            photos TEXT,
            discounted_price REAL,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE items (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT UNIQUE,
            client_id INTEGER,
            name TEXT NOT NULL,
            price REAL DEFAULT 0,
            enabled INTEGER DEFAULT 1,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE rectangles (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT UNIQUE,
            item_id INTEGER,
            length REAL NOT NULL,
            width REAL NOT NULL,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
          )
        ''');
    });
    dbService = DbService(database: database);
    apiService = MockApiService();
    syncService = SyncService(apiService: apiService, dbService: dbService);
  });

  tearDown(() async {
    await database.close();
  });

  test('Sync uploads dirty clients', () async {
    await dbService.insertClient(Client(
      remoteId: 'c1',
      name: 'John Doe',
      updatedAt: DateTime.now(),
      isDirty: true,
    ));

    await syncService.sync();

    expect(apiService.lastSyncData, isNotNull);
    final changes = apiService.lastSyncData!['changes'];
    expect(changes['clients'], hasLength(1));
    expect(changes['clients'][0]['remote_id'], 'c1');

    // Check if isDirty is cleared
    final dirtyClients = await dbService.getDirtyClients();
    expect(dirtyClients, isEmpty);
  });

  test('Sync downloads updates', () async {
    apiService.response = {
      'server_time': '2024-03-22T12:00:00Z',
      'updates': {
        'clients': [
          {
            'remote_id': 'c2',
            'name': 'Server Client',
            'updated_at': '2024-03-22T11:00:00Z',
          }
        ],
        'items': [],
        'rectangles': [],
      }
    };

    await syncService.sync();

    final clients = await dbService.getClients();
    expect(clients, hasLength(1));
    expect(clients[0].name, 'Server Client');
    expect(clients[0].remoteId, 'c2');
    expect(clients[0].isDirty, false);
  });
}
