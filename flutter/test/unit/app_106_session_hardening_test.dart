import 'dart:async';

import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/default_price.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/proposal.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/warranty.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/providers/sync_provider.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/session_manager.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _tenantA = 'tenant-a';
const _tenantB = 'tenant-b';
final _now = DateTime.utc(2026, 7, 31);

class _AuthApi extends ApiService {
  _AuthApi(this.responses) : super(serverUrl: 'http://localhost:3000');

  final List<Map<String, dynamic>> responses;

  @override
  Future<Map<String, dynamic>> login(String email, String password) async {
    return responses.removeAt(0);
  }
}

class _CapturingApi extends ApiService {
  _CapturingApi() : super(serverUrl: 'http://localhost:3000');

  final requests = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> syncForSession(
    Map<String, dynamic> data,
    SessionSnapshot session,
  ) async {
    requests.add(data);
    return _emptyV1Response;
  }
}

class _DelayedApi extends ApiService {
  _DelayedApi() : super(serverUrl: 'http://localhost:3000');

  final started = Completer<void>();
  final response = Completer<Map<String, dynamic>>();
  Map<String, dynamic>? capturedRequest;
  SessionSnapshot? capturedSession;

  @override
  Future<Map<String, dynamic>> syncForSession(
    Map<String, dynamic> data,
    SessionSnapshot session,
  ) {
    capturedRequest = data;
    capturedSession = session;
    started.complete();
    return response.future;
  }
}

final _emptyV1Response = <String, dynamic>{
  'server_time': '2026-07-31T00:00:00.000Z',
  'warranty_tombstone_cursor': '0',
  'updates': {
    'clients': <Map<String, dynamic>>[],
    'items': <Map<String, dynamic>>[],
    'rectangles': <Map<String, dynamic>>[],
    'default_prices': <Map<String, dynamic>>[],
    'warranties': <Map<String, dynamic>>[],
    'proposals': <Map<String, dynamic>>[],
    'warranty_tombstones': <Map<String, dynamic>>[],
  },
  'outcomes': {
    'clients': <Map<String, dynamic>>[],
    'items': <Map<String, dynamic>>[],
    'rectangles': <Map<String, dynamic>>[],
    'default_prices': <Map<String, dynamic>>[],
    'warranties': <Map<String, dynamic>>[],
    'proposals': <Map<String, dynamic>>[],
  },
};

Future<Database> _openDb() {
  return openDatabase(
    inMemoryDatabasePath,
    version: 1,
    onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE clients (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          remote_id TEXT UNIQUE,
          franchisee_id TEXT,
          name TEXT NOT NULL,
          address TEXT, site_address TEXT, email TEXT, phone TEXT,
          latitude REAL, longitude REAL, photos TEXT, discounted_price REAL,
          is_dirty INTEGER DEFAULT 1, updated_at TEXT NOT NULL, deleted_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE items (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          remote_id TEXT UNIQUE, client_id INTEGER, name TEXT NOT NULL,
          price REAL DEFAULT 0, enabled INTEGER DEFAULT 1,
          is_dirty INTEGER DEFAULT 1, updated_at TEXT NOT NULL, deleted_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE rectangles (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          remote_id TEXT UNIQUE, item_id INTEGER, length REAL NOT NULL,
          width REAL NOT NULL, image_data TEXT, is_dirty INTEGER DEFAULT 1,
          updated_at TEXT NOT NULL, deleted_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE default_prices (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          remote_id TEXT UNIQUE, franchisee_id TEXT NOT NULL, price REAL NOT NULL,
          enabled INTEGER DEFAULT 1, is_dirty INTEGER DEFAULT 1,
          updated_at TEXT NOT NULL, deleted_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE warranties (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          remote_id TEXT UNIQUE, client_id INTEGER, warranty_card_number TEXT,
          start_date TEXT, duration_years INTEGER, pdf_url TEXT,
          server_version INTEGER NOT NULL DEFAULT 1, is_dirty INTEGER DEFAULT 1,
          updated_at TEXT NOT NULL, deleted_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE proposals (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          remote_id TEXT UNIQUE, client_id INTEGER, pdf_url TEXT,
          is_dirty INTEGER DEFAULT 1, updated_at TEXT NOT NULL, deleted_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE warranty_deletion_tombstones (
          warranty_id TEXT NOT NULL, franchisee_id TEXT NOT NULL,
          deletion_sequence TEXT NOT NULL, deleted_at TEXT NOT NULL,
          PRIMARY KEY (franchisee_id, warranty_id)
        )
      ''');
      await db.execute('''
        CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)
      ''');
      await db.execute('''
        CREATE TABLE pending_client_photos (
          franchisee_id TEXT NOT NULL, client_remote_id TEXT NOT NULL,
          local_path TEXT NOT NULL,
          PRIMARY KEY (franchisee_id, client_remote_id, local_path)
        )
      ''');
    },
  );
}

Future<Map<String, int>> _seedTwoTenants(DbService db) async {
  final aClient = await db.insertClient(
    Client(
      remoteId: 'a-client',
      franchiseeId: _tenantA,
      name: 'A client',
      photos: const [
        '/api/photos/client/a-client/00000000-0000-4000-8000-000000000001.jpg',
      ],
      isDirty: true,
      updatedAt: _now,
    ),
  );
  final bClient = await db.insertClient(
    Client(
      remoteId: 'b-client',
      franchiseeId: _tenantB,
      name: 'B client',
      photos: const [
        '/api/photos/client/b-client/00000000-0000-4000-8000-000000000002.jpg',
      ],
      isDirty: true,
      updatedAt: _now,
    ),
  );
  final aItem = await db.insertItem(
    Item(
      remoteId: 'a-item',
      clientId: aClient,
      name: 'A item',
      price: 1,
      isDirty: true,
      updatedAt: _now,
    ),
  );
  final bItem = await db.insertItem(
    Item(
      remoteId: 'b-item',
      clientId: bClient,
      name: 'B item',
      price: 2,
      isDirty: true,
      updatedAt: _now,
    ),
  );
  await db.insertRectangle(
    Rectangle(
      remoteId: 'a-rectangle',
      itemId: aItem,
      length: 1,
      width: 1,
      imageData: 'a-image',
      isDirty: true,
      updatedAt: _now,
    ),
  );
  await db.insertRectangle(
    Rectangle(
      remoteId: 'b-rectangle',
      itemId: bItem,
      length: 2,
      width: 2,
      imageData: 'b-image',
      isDirty: true,
      updatedAt: _now,
    ),
  );
  await db.insertDefaultPrice(
    DefaultPrice(
      remoteId: 'a-price',
      franchiseeId: _tenantA,
      price: 10,
      isDirty: true,
      updatedAt: _now,
    ),
    franchiseeId: _tenantA,
  );
  await db.insertDefaultPrice(
    DefaultPrice(
      remoteId: 'b-price',
      franchiseeId: _tenantB,
      price: 20,
      isDirty: true,
      updatedAt: _now,
    ),
    franchiseeId: _tenantB,
  );
  await db.insertWarranty(
    Warranty(
      remoteId: 'a-warranty',
      clientId: aClient,
      warrantyCardNumber: 'A-W',
      startDate: _now,
      durationYears: 5,
      pdfUrl: '/a.pdf',
      isDirty: true,
      updatedAt: _now,
    ),
  );
  await db.insertWarranty(
    Warranty(
      remoteId: 'b-warranty',
      clientId: bClient,
      warrantyCardNumber: 'B-W',
      startDate: _now,
      durationYears: 5,
      pdfUrl: '/b.pdf',
      isDirty: true,
      updatedAt: _now,
    ),
  );
  await db.insertProposal(
    Proposal(
      remoteId: 'a-proposal',
      clientId: aClient,
      pdfUrl: '/a-proposal.pdf',
      isDirty: true,
      updatedAt: _now,
    ),
  );
  await db.insertProposal(
    Proposal(
      remoteId: 'b-proposal',
      clientId: bClient,
      pdfUrl: '/b-proposal.pdf',
      isDirty: true,
      updatedAt: _now,
    ),
  );
  final database = await db.database;
  await database.insert('pending_client_photos', {
    'franchisee_id': _tenantA,
    'client_remote_id': 'a-client',
    'local_path': '/private/a-photo.jpg',
  });
  await database.insert('pending_client_photos', {
    'franchisee_id': _tenantB,
    'client_remote_id': 'b-client',
    'local_path': '/private/b-photo.jpg',
  });
  return {'aClient': aClient, 'bClient': bClient};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('A → logout → B → logout → A clears caches and retains tenant data',
      () async {
    final database = await _openDb();
    final db = DbService(database: database);
    await _seedTwoTenants(db);
    final sessions = SessionManager();
    sessions.activate(token: 'token-a', franchiseeId: _tenantA);
    final clientProvider = ClientProvider(sessionManager: sessions);
    final settingsProvider = SettingsProvider(
      dbService: db,
      sessionManager: sessions,
    );

    clientProvider.updateSession(
      isAuthenticated: true,
      franchiseeId: _tenantA,
    );
    settingsProvider.updateSession(
      isAuthenticated: true,
      franchiseeId: _tenantA,
    );
    await clientProvider.loadClients();
    await settingsProvider.loadSettings();
    await clientProvider.loadWarranties(clientProvider.clients.single.localId!);
    await clientProvider.loadProposals(clientProvider.clients.single.localId!);
    expect(clientProvider.clients.single.name, 'A client');
    expect(
        clientProvider.currentClientWarranties.single.remoteId, 'a-warranty');
    expect(clientProvider.currentClientProposals.single.remoteId, 'a-proposal');
    expect(settingsProvider.defaultPrices.single.remoteId, 'a-price');

    sessions.invalidate();
    clientProvider.updateSession(isAuthenticated: false);
    settingsProvider.updateSession(isAuthenticated: false);
    expect(clientProvider.clients, isEmpty);
    expect(clientProvider.currentClientWarranties, isEmpty);
    expect(clientProvider.currentClientProposals, isEmpty);
    expect(settingsProvider.defaultPrices, isEmpty);

    sessions.activate(token: 'token-b', franchiseeId: _tenantB);
    clientProvider.updateSession(
      isAuthenticated: true,
      franchiseeId: _tenantB,
    );
    settingsProvider.updateSession(
      isAuthenticated: true,
      franchiseeId: _tenantB,
    );
    await clientProvider.loadClients();
    await settingsProvider.loadSettings();
    expect(clientProvider.clients.single.name, 'B client');
    expect(settingsProvider.defaultPrices.single.remoteId, 'b-price');

    sessions.invalidate();
    clientProvider.updateSession(isAuthenticated: false);
    settingsProvider.updateSession(isAuthenticated: false);
    sessions.activate(token: 'token-a-2', franchiseeId: _tenantA);
    clientProvider.updateSession(
      isAuthenticated: true,
      franchiseeId: _tenantA,
    );
    settingsProvider.updateSession(
      isAuthenticated: true,
      franchiseeId: _tenantA,
    );
    await clientProvider.loadClients();
    await settingsProvider.loadSettings();
    expect(clientProvider.clients.single.name, 'A client');
    expect(settingsProvider.defaultPrices.single.remoteId, 'a-price');
    expect((await db.getDirtyClientsForFranchisee(_tenantA)).single.remoteId,
        'a-client');
    expect((await db.getPendingClientPhotos(_tenantA)).single['local_path'],
        '/private/a-photo.jpg');
    await database.close();
  });

  test('tenant-scoped data access and B sync payload exclude A descendants',
      () async {
    final database = await _openDb();
    final db = DbService(database: database);
    await _seedTwoTenants(db);
    final api = _CapturingApi();
    final sessions = SessionManager();
    final b = sessions.activate(token: 'token-b', franchiseeId: _tenantB);

    expect((await db.getClientsForFranchisee(_tenantB)).single.remoteId,
        'b-client');
    expect((await db.getDirtyItemsForFranchisee(_tenantB)).single.remoteId,
        'b-item');
    expect(
      (await db.getDirtyRectanglesForFranchisee(_tenantB)).single.remoteId,
      'b-rectangle',
    );
    expect(
      (await db.getDirtyWarrantiesForFranchisee(_tenantB)).single.remoteId,
      'b-warranty',
    );
    expect(
      (await db.getDirtyProposalsForFranchisee(_tenantB)).single.remoteId,
      'b-proposal',
    );
    expect((await db.getPendingClientPhotos(_tenantB)).single['local_path'],
        '/private/b-photo.jpg');

    await SyncService(apiService: api, dbService: db, sessionManager: sessions)
        .sync(b);
    final changes = api.requests.single['changes'] as Map<String, dynamic>;
    final encoded = changes.toString();
    expect(encoded, contains('b-client'));
    expect(encoded, contains('b-item'));
    expect(encoded, contains('b-rectangle'));
    expect(encoded, contains('b-price'));
    expect(encoded, contains('b-warranty'));
    expect(encoded, contains('b-proposal'));
    expect(encoded, isNot(contains('a-client')));
    expect(encoded, isNot(contains('a-item')));
    expect(encoded, isNot(contains('a-rectangle')));
    expect(encoded, isNot(contains('a-price')));
    expect(encoded, isNot(contains('a-warranty')));
    expect(encoded, isNot(contains('a-proposal')));
    expect(encoded, isNot(contains('/private/a-photo.jpg')));
    await database.close();
  });

  test('a stale sync response cannot clear A data or advance its cursor',
      () async {
    final database = await _openDb();
    final db = DbService(database: database);
    await db.insertClient(
      Client(
        remoteId: 'a-stale-client',
        franchiseeId: _tenantA,
        name: 'A client',
        isDirty: true,
        updatedAt: _now,
      ),
    );
    final api = _DelayedApi();
    final sessions = SessionManager();
    final a = sessions.activate(token: 'token-a', franchiseeId: _tenantA);
    final service = SyncService(
      apiService: api,
      dbService: db,
      sessionManager: sessions,
    );

    final running = service.sync(a);
    await api.started.future;
    expect(api.capturedSession, same(a));
    expect(api.capturedRequest.toString(), contains('a-stale-client'));

    sessions.invalidate();
    sessions.activate(token: 'token-b', franchiseeId: _tenantB);
    api.response.complete(_emptyV1Response);

    await expectLater(running, throwsA(isA<StaleSessionException>()));
    expect((await db.getDirtyClientsForFranchisee(_tenantA)).single.remoteId,
        'a-stale-client');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('last_sync_time_$_tenantA'), isFalse);
    await database.close();
  });

  test(
      'logout invalidates session, rejects a second login, and discards cursor',
      () async {
    SharedPreferences.setMockInitialValues({
      'last_sync_time': 'legacy-global-cursor',
      'last_sync_time_$_tenantA': 'retained-a-v1-cursor',
    });
    final sessions = SessionManager();
    final auth = AuthProvider(
      sessionManager: sessions,
      apiService: _AuthApi([
        {
          'token': 'a-token',
          'user': {'name': 'A', 'franchisee_id': _tenantA},
        },
      ]),
    );
    await auth.login('a@example.test', 'password');
    final active = auth.sessionSnapshot;
    expect(active, isNotNull);
    await expectLater(
      auth.login('b@example.test', 'password'),
      throwsA(isA<StateError>()),
    );

    await auth.logout();
    final prefs = await SharedPreferences.getInstance();
    expect(auth.isAuthenticated, isFalse);
    expect(sessions.isCurrent(active!), isFalse);
    expect(prefs.containsKey('last_sync_time'), isFalse);
    expect(prefs.getString('last_sync_time_$_tenantA'), 'retained-a-v1-cursor');
  });

  test('sync UI state is cleared on a session transition', () async {
    final database = await _openDb();
    final sessions = SessionManager();
    final a = sessions.activate(token: 'token-a', franchiseeId: _tenantA);
    final b = sessions.activate(token: 'token-b', franchiseeId: _tenantB);
    final provider = SyncProvider(
      syncService: SyncService(
        apiService: _CapturingApi(),
        dbService: DbService(database: database),
        sessionManager: sessions,
      ),
    );
    provider.updateSession(a);
    provider.updateSession(b);
    expect(provider.isSyncing, isFalse);
    expect(provider.lastSyncTime, isNull);
    expect(provider.error, isNull);
    await database.close();
  });
}
