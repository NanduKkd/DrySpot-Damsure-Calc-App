import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class V2ApiService extends ApiService {
  V2ApiService();

  Map<String, dynamic>? lastV1;
  Map<String, dynamic>? lastV2;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? v1Handler;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? v2Handler;

  @override
  Future<Map<String, dynamic>> sync(Map<String, dynamic> data) async {
    lastV1 = data;
    return v1Handler!(data);
  }

  @override
  Future<Map<String, dynamic>> syncV2(Map<String, dynamic> data) async {
    lastV2 = data;
    return v2Handler!(data);
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const tenant = '40000000-0000-4000-8000-000000000001';
  const remoteId = '40000000-0000-4000-8000-000000000002';
  const serverWriter = '40000000-0000-4000-8000-000000000003';
  const serverChange = '40000000-0000-4000-8000-000000000004';
  final now = DateTime.utc(2026, 7, 30).toIso8601String();

  late Database database;
  late DbService dbService;
  late V2ApiService apiService;

  Future<void> createSchema(Database db) async {
    const lww = '''
      server_generation TEXT NOT NULL DEFAULT '0',
      server_branch_seq INTEGER NOT NULL DEFAULT 0,
      server_operation_rank INTEGER NOT NULL DEFAULT 0,
      server_writer_id TEXT,
      server_change_id TEXT,
      server_payload_hash TEXT,
      server_cursor TEXT NOT NULL DEFAULT '0',
      pending_base_generation TEXT,
      pending_generation TEXT,
      pending_branch_seq INTEGER,
      pending_writer_id TEXT,
      pending_change_id TEXT
    ''';
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
        deleted_at TEXT,
        $lww
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
        deleted_at TEXT,
        $lww
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
        deleted_at TEXT,
        $lww
      )
    ''');
    await db.execute('''
      CREATE TABLE default_prices (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_id TEXT UNIQUE,
        franchisee_id TEXT,
        price REAL NOT NULL,
        enabled INTEGER DEFAULT 1,
        is_dirty INTEGER DEFAULT 1,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        $lww
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
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'franchisee_id': tenant});
    database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, _) => createSchema(db),
    );
    dbService = DbService(database: database);
    apiService = V2ApiService();
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> activate({String cursor = '0'}) async {
    await dbService.applySyncV2Response(
      franchiseeId: tenant,
      responseCursor: cursor,
      warrantyTombstoneCursor: '0',
      records: {
        'clients': [],
        'items': [],
        'rectangles': [],
        'default_prices': [],
      },
      warrantyTombstones: const [],
      submittedChangeIds: {
        'clients': {},
        'items': {},
        'rectangles': {},
        'default_prices': {},
      },
      outcomeStatuses: const {},
      activateProtocol: true,
    );
  }

  Map<String, dynamic> serverClient({
    required String changeId,
    required String cursor,
    String name = 'Server',
    String operation = 'upsert',
    String generation = '1',
  }) =>
      {
        'remote_id': remoteId,
        'generation': generation,
        'branch_seq': 1,
        'operation': operation,
        'writer_id': serverWriter,
        'change_id': changeId,
        'payload_hash': List.filled(64, 'a').join(),
        'row_cursor': cursor,
        'server_timestamp': now,
        'deleted_at': operation == 'delete' ? now : null,
        'franchisee_id': tenant,
        'payload': {
          'name': name,
          'address': null,
          'site_address': null,
          'email': null,
          'phone': null,
          'latitude': null,
          'longitude': null,
          'discounted_price': null,
        },
      };

  Map<String, dynamic> responseFor(
    Map<String, dynamic> request, {
    required String cursor,
    List<Map<String, dynamic>> clientOutcomes = const [],
    List<Map<String, dynamic>> clients = const [],
  }) =>
      {
        'protocol_version': 2,
        'request_id': request['request_id'],
        'response_cursor': cursor,
        'warranty_tombstone_cursor': request['warranty_tombstone_cursor'],
        'outcomes': {
          'clients': clientOutcomes,
          'items': [],
          'rectangles': [],
          'default_prices': [],
        },
        'warnings': [],
        'updates': {
          'clients': clients,
          'items': [],
          'rectangles': [],
          'default_prices': [],
          'warranty_tombstones': [],
        },
      };

  test('applies exact outcome and cursor atomically above 2^53', () async {
    await activate(cursor: '9007199254740993');
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Local',
      updatedAt: DateTime.parse(now),
    ));
    apiService.v2Handler = (request) async {
      final submitted = request['changes']['clients'].single;
      final record = serverClient(
        changeId: submitted['change_id'],
        cursor: '9007199254740994',
      );
      return responseFor(
        request,
        cursor: '9007199254740994',
        clientOutcomes: [
          {
            'change_id': submitted['change_id'],
            'remote_id': remoteId,
            'status': 'applied',
            'reason_code': 'upsert_applied',
            'authoritative': record,
          }
        ],
        clients: [record],
      );
    };

    await SyncService(apiService: apiService, dbService: dbService).sync();

    final row = (await database.query(
      'clients',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    ))
        .single;
    expect(row['name'], 'Server');
    expect(row['is_dirty'], 0);
    expect(row['pending_change_id'], isNull);
    expect(row['server_generation'], '1');
    expect(
      await dbService.getSyncV2Cursor(tenant),
      '9007199254740994',
    );
  });

  test('an in-flight N+1 edit survives the outcome and snapshot for N',
      () async {
    await activate();
    final localId = await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'N',
      updatedAt: DateTime.parse(now),
    ));
    String? submittedChange;
    apiService.v2Handler = (request) async {
      final submitted = request['changes']['clients'].single;
      submittedChange = submitted['change_id'];
      final existing = await dbService.getClientByRemoteId(remoteId);
      await dbService.updateClient(
        existing!.copyWith(
          localId: localId,
          name: 'N+1',
          isDirty: true,
          updatedAt: DateTime.utc(2026, 7, 30, 0, 1),
        ),
      );
      final record = serverClient(
        changeId: submittedChange!,
        cursor: '1',
        name: 'N on server',
      );
      return responseFor(
        request,
        cursor: '1',
        clientOutcomes: [
          {
            'change_id': submittedChange,
            'remote_id': remoteId,
            'status': 'applied',
            'reason_code': 'upsert_applied',
            'authoritative': record,
          }
        ],
        clients: [record],
      );
    };

    await SyncService(apiService: apiService, dbService: dbService).sync();

    final row = (await database.query(
      'clients',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    ))
        .single;
    expect(row['name'], 'N+1');
    expect(row['is_dirty'], 1);
    expect(row['pending_change_id'], isNot(submittedChange));
    expect(row['pending_branch_seq'], 2);
    expect(row['server_generation'], '1');
    final pending = await dbService.getPendingLwwChanges(tenant);
    expect(pending['clients']!.single['branch_seq'], 2);
  });

  test('superseded clears exact dirty state while rejected preserves it',
      () async {
    await activate(cursor: '2');
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Losing local',
      updatedAt: DateTime.parse(now),
    ));
    apiService.v2Handler = (request) async {
      final submitted = request['changes']['clients'].single;
      final record = serverClient(
        changeId: serverChange,
        cursor: '1',
        name: 'Winner',
      );
      return responseFor(
        request,
        cursor: '2',
        clientOutcomes: [
          {
            'change_id': submitted['change_id'],
            'remote_id': remoteId,
            'status': 'superseded',
            'reason_code': 'version_superseded',
            'authoritative': record,
          }
        ],
      );
    };
    await SyncService(apiService: apiService, dbService: dbService).sync();
    var row = (await database.query('clients')).single;
    expect(row['name'], 'Winner');
    expect(row['is_dirty'], 0);

    await dbService.updateClient(
      (await dbService.getClientByRemoteId(remoteId))!.copyWith(
        name: 'Invalid local',
        isDirty: true,
        updatedAt: DateTime.utc(2026, 7, 30, 0, 2),
      ),
    );
    apiService.v2Handler = (request) async {
      final submitted = request['changes']['clients'].single;
      return responseFor(
        request,
        cursor: '2',
        clientOutcomes: [
          {
            'change_id': submitted['change_id'],
            'remote_id': remoteId,
            'status': 'rejected',
            'reason_code': 'invalid_payload',
          }
        ],
      );
    };
    await SyncService(apiService: apiService, dbService: dbService).sync();
    row = (await database.query('clients')).single;
    expect(row['name'], 'Invalid local');
    expect(row['is_dirty'], 1);
  });

  test('remote updates and deletes never become dirty', () async {
    await activate();
    apiService.v2Handler = (request) async => responseFor(
          request,
          cursor: '1',
          clients: [
            serverClient(changeId: serverChange, cursor: '1'),
          ],
        );
    await SyncService(apiService: apiService, dbService: dbService).sync();
    var row = (await database.query('clients')).single;
    expect(row['is_dirty'], 0);

    final deleteRecord = serverClient(
      changeId: '40000000-0000-4000-8000-000000000005',
      cursor: '2',
      operation: 'delete',
      generation: '2',
    );
    apiService.v2Handler = (request) async => responseFor(
          request,
          cursor: '2',
          clients: [deleteRecord],
        );
    await SyncService(apiService: apiService, dbService: dbService).sync();
    row = (await database.query('clients')).single;
    expect(row['deleted_at'], now);
    expect(row['is_dirty'], 0);
  });

  test('atomic local apply rolls back records and cursor on an invalid parent',
      () async {
    await activate(cursor: '5');
    final clientRecord = serverClient(changeId: serverChange, cursor: '6');
    final itemRecord = {
      'remote_id': '40000000-0000-4000-8000-000000000006',
      'generation': '1',
      'branch_seq': 1,
      'operation': 'upsert',
      'writer_id': serverWriter,
      'change_id': '40000000-0000-4000-8000-000000000007',
      'payload_hash': List.filled(64, 'b').join(),
      'row_cursor': '6',
      'server_timestamp': now,
      'deleted_at': null,
      'parent_id': '40000000-0000-4000-8000-000000000099',
      'payload': {'name': 'Orphan', 'price': 1.0, 'enabled': true},
    };
    await expectLater(
      dbService.applySyncV2Response(
        franchiseeId: tenant,
        responseCursor: '6',
        warrantyTombstoneCursor: '0',
        records: {
          'clients': [clientRecord],
          'items': [itemRecord],
          'rectangles': [],
          'default_prices': [],
        },
        warrantyTombstones: const [],
        submittedChangeIds: {
          'clients': {},
          'items': {},
          'rectangles': {},
          'default_prices': {},
        },
        outcomeStatuses: const {},
        activateProtocol: false,
      ),
      throwsFormatException,
    );
    expect(await database.query('clients'), isEmpty);
    expect(await dbService.getSyncV2Cursor(tenant), '5');
  });

  test(
      'v1 drains before bootstrap and malformed old-server v2 is not persisted',
      () async {
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Legacy dirty',
      updatedAt: DateTime.parse(now),
    ));
    apiService.v1Handler = (request) async {
      final changes = request['changes'] as Map<String, dynamic>;
      return {
        'server_time': now,
        'warranty_tombstone_cursor': '0',
        'outcomes': {
          for (final entry in changes.entries)
            entry.key: [
              for (final change in entry.value as List)
                {
                  'remote_id': change['remote_id'],
                  'status': 'applied',
                }
            ],
        },
        'updates': {
          'clients': [],
          'items': [],
          'rectangles': [],
          'default_prices': [],
          'warranties': [],
          'warranty_tombstones': [],
          'proposals': [],
        },
      };
    };
    apiService.v2Handler = (_) async => {'server_time': now};

    await SyncService(apiService: apiService, dbService: dbService).sync();

    expect(apiService.lastV1!['changes']['clients'], hasLength(1));
    expect(await dbService.getDirtyClients(), isEmpty);
    expect(await dbService.isSyncV2Enabled(tenant), isFalse);

    apiService.v2Handler = (request) async => responseFor(request, cursor: '1');
    await SyncService(apiService: apiService, dbService: dbService).sync();
    expect(await dbService.isSyncV2Enabled(tenant), isTrue);
    expect(await dbService.getSyncV2Cursor(tenant), '1');
  });

  test('active v2 rejects an old or malformed response without cursor advance',
      () async {
    await activate(cursor: '8');
    apiService.v2Handler = (_) async => {
          'server_time': now,
          'updates': {
            'clients': [],
            'items': [],
            'rectangles': [],
          },
        };
    await expectLater(
      SyncService(apiService: apiService, dbService: dbService).sync(),
      throwsA(isA<ApiException>()),
    );
    expect(await dbService.getSyncV2Cursor(tenant), '8');
  });
}
