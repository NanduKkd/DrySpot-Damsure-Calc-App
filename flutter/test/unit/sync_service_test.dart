import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/warranty.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockApiService extends ApiService {
  Map<String, dynamic>? lastSyncData;
  Future<void> Function(Map<String, dynamic> data)? beforeResponse;
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
    await beforeResponse?.call(data);
    final changes = data['changes'] as Map<String, dynamic>;
    return {
      ...response,
      'outcomes': {
        for (final entry in changes.entries)
          entry.key: [
            for (final change in entry.value as List)
              {
                'remote_id': change['remote_id'],
                'status': 'applied',
              },
          ],
      },
    };
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
    database = await openDatabase(inMemoryDatabasePath, version: 1,
        onCreate: (db, version) async {
      await db.execute('''
          CREATE TABLE clients (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT UNIQUE,
            franchisee_id TEXT,
            name TEXT NOT NULL,
            address TEXT,
            site_address TEXT,
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
            image_data TEXT,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
          )
        ''');
      await db.execute('''
          CREATE TABLE warranties (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT UNIQUE,
            client_id INTEGER,
            warranty_card_number TEXT,
            start_date TEXT,
            duration_years INTEGER,
            pdf_url TEXT,
            server_version INTEGER NOT NULL DEFAULT 1,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
          )
        ''');
      await db.execute('''
          CREATE TABLE proposals (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT UNIQUE,
            client_id INTEGER,
            pdf_url TEXT,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
          )
        ''');
      await db.execute('''
          CREATE TABLE default_prices (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT,
            franchisee_id TEXT,
            category TEXT,
            item TEXT,
            price REAL,
            enabled INTEGER DEFAULT 1,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT
          )
        ''');
      await db.execute('''
          CREATE TABLE warranty_deletion_tombstones (
            warranty_id TEXT NOT NULL,
            franchisee_id TEXT NOT NULL,
            deletion_sequence TEXT NOT NULL,
            deleted_at TEXT NOT NULL,
            PRIMARY KEY (franchisee_id, warranty_id)
          )
        ''');
      await db.execute('''
          CREATE TABLE sync_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
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

  test('Sync uploads dirty rectangle image data', () async {
    final clientLocalId = await dbService.insertClient(Client(
      remoteId: 'c1',
      name: 'John Doe',
      updatedAt: DateTime.now(),
      isDirty: false,
    ));

    final itemLocalId = await dbService.insertItem(Item(
      remoteId: 'i1',
      clientId: clientLocalId,
      name: 'Roof',
      price: 10,
      updatedAt: DateTime.now(),
      isDirty: false,
    ));

    await dbService.insertRectangle(Rectangle(
      remoteId: 'r1',
      itemId: itemLocalId,
      length: 10,
      width: 20,
      imageData: 'data:image/png;base64,ZmFrZQ==',
      updatedAt: DateTime.now(),
      isDirty: true,
    ));

    await syncService.sync();

    final changes = apiService.lastSyncData!['changes'];
    expect(changes['rectangles'], hasLength(1));
    expect(
      changes['rectangles'][0]['image_data'],
      'data:image/png;base64,ZmFrZQ==',
    );

    final dirtyRectangles = await dbService.getDirtyRectangles();
    expect(dirtyRectangles, isEmpty);
  });

  test('Sync downloads rectangle image data', () async {
    apiService.response = {
      'server_time': '2024-03-22T12:00:00Z',
      'updates': {
        'clients': [
          {
            'remote_id': 'c2',
            'name': 'Server Client',
            'updated_at': '2024-03-22T11:00:00Z',
            'deleted_at': null,
          }
        ],
        'items': [
          {
            'remote_id': 'i2',
            'client_id': 'c2',
            'name': 'Roof',
            'price': 22.0,
            'enabled': true,
            'updated_at': '2024-03-22T11:00:00Z',
            'deleted_at': null,
          }
        ],
        'rectangles': [
          {
            'remote_id': 'r2',
            'item_id': 'i2',
            'length': 11.0,
            'width': 12.0,
            'image_data': 'data:image/png;base64,ZmFrZQ==',
            'updated_at': '2024-03-22T11:00:00Z',
            'deleted_at': null,
          }
        ],
      }
    };

    await syncService.sync();

    final clients = await dbService.getClients();
    expect(clients, hasLength(1));
    expect(clients[0].items, hasLength(1));
    expect(clients[0].items[0].rectangles, hasLength(1));
    expect(
      clients[0].items[0].rectangles[0].imageData,
      'data:image/png;base64,ZmFrZQ==',
    );
  });

  test(
      'Sync preserves a newer local warranty edit when the submitted server echo arrives',
      () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    const clientRemoteId = 'cas-client';
    const warrantyRemoteId = 'cas-warranty';
    final submittedAt = DateTime.utc(2026, 7, 30, 1);
    final newerAt = DateTime.utc(2026, 7, 30, 1, 0, 1);
    final clientLocalId = await dbService.insertClient(Client(
      remoteId: clientRemoteId,
      franchiseeId: 'tenant-a',
      name: 'CAS client',
      isDirty: false,
      updatedAt: submittedAt,
    ));
    await dbService.insertWarranty(Warranty(
      remoteId: warrantyRemoteId,
      clientId: clientLocalId,
      warrantyCardNumber: 'SUBMITTED',
      startDate: DateTime.utc(2026, 1, 1),
      durationYears: 5,
      pdfUrl: '/submitted.pdf',
      version: 4,
      isDirty: true,
      updatedAt: submittedAt,
    ));

    apiService.beforeResponse = (_) async {
      final captured =
          (await dbService.getWarrantyByRemoteId(warrantyRemoteId))!;
      await dbService.updateWarranty(captured.copyWith(
        warrantyCardNumber: 'NEWER-LOCAL',
        isDirty: true,
        updatedAt: newerAt,
      ));
    };
    apiService.response = {
      'server_time': '2026-07-30T01:00:02.000Z',
      'warranty_tombstone_cursor': '0',
      'updates': {
        'clients': [],
        'items': [],
        'rectangles': [],
        'default_prices': [],
        'warranties': [
          {
            'remote_id': warrantyRemoteId,
            'client_id': clientRemoteId,
            'warranty_card_number': 'SUBMITTED',
            'start_date': '2026-01-01T00:00:00.000Z',
            'duration_years': 5,
            'pdf_url': '/server.pdf',
            'version': 5,
            'updated_at': '2026-07-30T01:00:02.000Z',
            'deleted_at': null,
          },
        ],
        'proposals': [],
        'warranty_tombstones': [],
      },
    };

    await syncService.sync();

    final retained = (await dbService.getWarrantyByRemoteId(warrantyRemoteId))!;
    expect(retained.warrantyCardNumber, 'NEWER-LOCAL');
    expect(retained.updatedAt, newerAt);
    expect(retained.isDirty, isTrue);
  });

  test('Sync still applies an unrelated new remote warranty', () async {
    SharedPreferences.setMockInitialValues({'franchisee_id': 'tenant-a'});
    const clientRemoteId = 'remote-warranty-client';
    const warrantyRemoteId = 'unrelated-server-warranty';
    final clientLocalId = await dbService.insertClient(Client(
      remoteId: clientRemoteId,
      franchiseeId: 'tenant-a',
      name: 'Remote warranty client',
      isDirty: false,
      updatedAt: DateTime.utc(2026, 7, 30),
    ));
    apiService.response = {
      'server_time': '2026-07-30T02:00:00.000Z',
      'warranty_tombstone_cursor': '0',
      'updates': {
        'clients': [],
        'items': [],
        'rectangles': [],
        'default_prices': [],
        'warranties': [
          {
            'remote_id': warrantyRemoteId,
            'client_id': clientRemoteId,
            'warranty_card_number': 'REMOTE-ONLY',
            'start_date': '2026-01-01T00:00:00.000Z',
            'duration_years': 5,
            'pdf_url': '/remote.pdf',
            'version': 2,
            'updated_at': '2026-07-30T02:00:00.000Z',
            'deleted_at': null,
          },
        ],
        'proposals': [],
        'warranty_tombstones': [],
      },
    };

    await syncService.sync();

    final applied = (await dbService.getWarrantyByRemoteId(warrantyRemoteId))!;
    expect(applied.clientId, clientLocalId);
    expect(applied.warrantyCardNumber, 'REMOTE-ONLY');
    expect(applied.isDirty, isFalse);
  });
}
