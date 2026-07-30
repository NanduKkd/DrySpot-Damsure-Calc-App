import 'dart:convert';

import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class V2ApiService extends ApiService {
  V2ApiService();

  Map<String, dynamic>? lastV1;
  Map<String, dynamic>? lastV2;
  final List<List<String>> photoUploads = [];
  final List<String> proposalDeletes = [];
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? v1Handler;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? v2Handler;
  Future<String> Function(String clientId, String path)? photoHandler;
  Future<void> Function(String id)? proposalDeleteHandler;

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

  @override
  Future<String> uploadClientPhoto(String clientId, String filePath) async {
    photoUploads.add([clientId, filePath]);
    return photoHandler!(clientId, filePath);
  }

  @override
  Future<void> deleteProposal(String id) async {
    proposalDeletes.add(id);
    await proposalDeleteHandler!(id);
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
      requestCursor: '0',
      responseCursor: cursor,
      requestWarrantyTombstoneCursor: '0',
      warrantyTombstoneCursor: '0',
      records: {
        'clients': [],
        'items': [],
        'rectangles': [],
        'default_prices': [],
      },
      warranties: const [],
      proposals: const [],
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
    List<String> photos = const [],
    int branch = 1,
    String writerId = serverWriter,
  }) {
    final payload = operation == 'delete'
        ? <String, dynamic>{}
        : <String, dynamic>{
            'address': null,
            'discounted_price': null,
            'email': null,
            'latitude': null,
            'longitude': null,
            'name': name,
            'phone': null,
            'site_address': null,
          };
    return {
      'remote_id': remoteId,
      'generation': generation,
      'branch_seq': branch,
      'operation': operation,
      'writer_id': writerId,
      'change_id': changeId,
      'payload_hash':
          sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
      'row_cursor': cursor,
      'server_timestamp': now,
      'deleted_at': operation == 'delete' ? now : null,
      'franchisee_id': tenant,
      'payload': payload,
      'media': {'photos': photos},
    };
  }

  Map<String, dynamic> responseFor(
    Map<String, dynamic> request, {
    required String cursor,
    List<Map<String, dynamic>> clientOutcomes = const [],
    List<Map<String, dynamic>> defaultPriceOutcomes = const [],
    List<Map<String, dynamic>> clients = const [],
    List<Map<String, dynamic>> items = const [],
    List<Map<String, dynamic>> rectangles = const [],
    List<Map<String, dynamic>> defaultPrices = const [],
    List<Map<String, dynamic>> warranties = const [],
    List<Map<String, dynamic>> proposals = const [],
    List<Map<String, dynamic>> warrantyTombstones = const [],
    String? warrantyTombstoneCursor,
  }) =>
      {
        'protocol_version': 2,
        'request_id': request['request_id'],
        'response_cursor': cursor,
        'warranty_tombstone_cursor':
            warrantyTombstoneCursor ?? request['warranty_tombstone_cursor'],
        'outcomes': {
          'clients': clientOutcomes,
          'items': [],
          'rectangles': [],
          'default_prices': defaultPriceOutcomes,
        },
        'warnings': [],
        'updates': {
          'clients': clients,
          'items': items,
          'rectangles': rectangles,
          'default_prices': defaultPrices,
          'warranties': warranties,
          'proposals': proposals,
          'warranty_tombstones': warrantyTombstones,
        },
      };

  dynamic stableValue(dynamic value) {
    if (value is List) return value.map(stableValue).toList();
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: stableValue(value[key])};
    }
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt();
    }
    return value;
  }

  String payloadHash(Map<String, dynamic> payload) =>
      sha256.convert(utf8.encode(jsonEncode(stableValue(payload)))).toString();

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

  test('creates the client before uploading its offline photo and converges',
      () async {
    await activate();
    const localPhoto = '/offline/new-client.jpg';
    const canonicalPhoto =
        '/api/photos/client/$remoteId/40000000-0000-4000-8000-000000000010.jpg';
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Offline client',
      photos: const [localPhoto],
      updatedAt: DateTime.parse(now),
    ));
    var round = 0;
    var coreApplied = false;
    apiService.v2Handler = (request) async {
      round += 1;
      if (round == 1) {
        final submitted = request['changes']['clients'].single;
        coreApplied = true;
        final record = serverClient(
          changeId: submitted['change_id'],
          cursor: '1',
          name: 'Offline client',
        );
        return responseFor(
          request,
          cursor: '1',
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
      }
      expect(request['request_cursor'], '1');
      expect(request['changes']['clients'], isEmpty);
      return responseFor(
        request,
        cursor: '2',
        clients: [
          serverClient(
            changeId: apiService.lastV2!['changes']['clients'].isEmpty
                ? (await database.query('clients')).single['server_change_id']
                    as String
                : serverChange,
            cursor: '2',
            name: 'Offline client',
            photos: const [canonicalPhoto],
          ),
        ],
      );
    };
    apiService.photoHandler = (clientId, path) async {
      expect(coreApplied, isTrue);
      expect(clientId, remoteId);
      expect(path, localPhoto);
      return canonicalPhoto;
    };

    await SyncService(apiService: apiService, dbService: dbService).sync();

    final row = (await database.query('clients')).single;
    expect(jsonDecode(row['photos'] as String), [canonicalPhoto]);
    expect(row['is_dirty'], 0);
    expect(row['pending_change_id'], isNull);
    expect(await dbService.getSyncV2Cursor(tenant), '2');
    expect(apiService.photoUploads, [
      [remoteId, localPhoto]
    ]);

    apiService.v2Handler = (request) async => responseFor(request, cursor: '2');
    await SyncService(apiService: apiService, dbService: dbService).sync();
    expect(apiService.photoUploads, hasLength(1));
  });

  test('applies rectangle media and live/replaced/deleted PDF resources',
      () async {
    await activate();
    const itemId = '40000000-0000-4000-8000-000000000011';
    const rectangleId = '40000000-0000-4000-8000-000000000012';
    const itemChange = '40000000-0000-4000-8000-000000000013';
    const rectangleChange = '40000000-0000-4000-8000-000000000014';
    const oldWarranty = '40000000-0000-4000-8000-000000000015';
    const newWarranty = '40000000-0000-4000-8000-000000000016';
    const proposalId = '40000000-0000-4000-8000-000000000017';
    const imageData = 'data:image/png;base64,iVBORw0KGgo=';
    final itemPayload = <String, dynamic>{
      'enabled': true,
      'name': 'Item',
      'price': 10,
    };
    final rectanglePayload = <String, dynamic>{'length': 2, 'width': 3};
    final itemRecord = {
      'remote_id': itemId,
      'generation': '1',
      'branch_seq': 1,
      'operation': 'upsert',
      'writer_id': serverWriter,
      'change_id': itemChange,
      'payload_hash': payloadHash(itemPayload),
      'row_cursor': '1',
      'server_timestamp': now,
      'deleted_at': null,
      'parent_id': remoteId,
      'payload': itemPayload,
    };
    final rectangleRecord = {
      'remote_id': rectangleId,
      'generation': '1',
      'branch_seq': 1,
      'operation': 'upsert',
      'writer_id': serverWriter,
      'change_id': rectangleChange,
      'payload_hash': payloadHash(rectanglePayload),
      'row_cursor': '1',
      'server_timestamp': now,
      'deleted_at': null,
      'parent_id': itemId,
      'payload': rectanglePayload,
      'media': {'image_data': imageData},
    };
    Map<String, dynamic> warrantyRecord(
            String id, String cursor, String card) =>
        {
          'remote_id': id,
          'client_id': remoteId,
          'version': 1,
          'start_date': now,
          'duration_years': 5,
          'pdf_url': '/api/warranty/$id/download',
          'warranty_card_number': card,
          'row_cursor': cursor,
          'server_timestamp': now,
          'deleted_at': null,
        };
    Map<String, dynamic> proposalRecord(String cursor,
            {bool deleted = false}) =>
        {
          'remote_id': proposalId,
          'client_id': remoteId,
          'pdf_url': '/api/proposal/$proposalId/download',
          'row_cursor': cursor,
          'server_timestamp': now,
          'deleted_at': deleted ? now : null,
        };

    apiService.v2Handler = (request) async => responseFor(
          request,
          cursor: '1',
          clients: [serverClient(changeId: serverChange, cursor: '1')],
          items: [itemRecord],
          rectangles: [rectangleRecord],
          warranties: [warrantyRecord(oldWarranty, '1', 'OLD')],
          proposals: [proposalRecord('1')],
        );
    await SyncService(apiService: apiService, dbService: dbService).sync();
    expect(
        (await database.query('rectangles')).single['image_data'], imageData);
    expect(
      (await database.query('warranties')).single['remote_id'],
      oldWarranty,
    );
    expect((await database.query('proposals')).single['deleted_at'], isNull);

    apiService.v2Handler = (request) async => responseFor(
          request,
          cursor: '2',
          warrantyTombstoneCursor: '1',
          warrantyTombstones: [
            {
              'warranty_id': oldWarranty,
              'deletion_sequence': '1',
              'deleted_at': now,
            }
          ],
          warranties: [warrantyRecord(newWarranty, '2', 'NEW')],
          proposals: [proposalRecord('2', deleted: true)],
        );
    await SyncService(apiService: apiService, dbService: dbService).sync();
    expect(
      (await database.query('warranties')).map((row) => row['remote_id']),
      [newWarranty],
    );
    expect((await database.query('proposals')).single['deleted_at'], now);
    expect(await dbService.getWarrantyTombstoneCursor(tenant), '1');

    apiService.v2Handler = (request) async => responseFor(
          request,
          cursor: '3',
          warrantyTombstoneCursor: '1',
          warranties: [warrantyRecord(oldWarranty, '3', 'RESURRECT')],
        );
    await SyncService(apiService: apiService, dbService: dbService).sync();
    expect(
      (await database.query('warranties')).map((row) => row['remote_id']),
      [newWarranty],
    );
  });

  test('reconciles legacy dirty warranty state and drains proposal deletion',
      () async {
    await activate();
    const warrantyId = '40000000-0000-4000-8000-000000000018';
    const proposalId = '40000000-0000-4000-8000-000000000019';
    Map<String, dynamic> warrantyRecord(String cursor) => {
          'remote_id': warrantyId,
          'client_id': remoteId,
          'version': 1,
          'start_date': now,
          'duration_years': 5,
          'pdf_url': '/api/warranty/$warrantyId/download',
          'warranty_card_number': 'LEGACY',
          'row_cursor': cursor,
          'server_timestamp': now,
          'deleted_at': null,
        };
    Map<String, dynamic> proposalRecord(
      String cursor, {
      bool deleted = false,
    }) =>
        {
          'remote_id': proposalId,
          'client_id': remoteId,
          'pdf_url': '/api/proposal/$proposalId/download',
          'row_cursor': cursor,
          'server_timestamp': now,
          'deleted_at': deleted ? now : null,
        };
    apiService.v2Handler = (request) async => responseFor(
          request,
          cursor: '1',
          clients: [serverClient(changeId: serverChange, cursor: '1')],
          warranties: [warrantyRecord('1')],
          proposals: [proposalRecord('1')],
        );
    await SyncService(apiService: apiService, dbService: dbService).sync();
    await database.update(
      'warranties',
      {'is_dirty': 1},
      where: 'remote_id = ?',
      whereArgs: [warrantyId],
    );
    await database.update(
      'proposals',
      {'is_dirty': 1, 'deleted_at': now},
      where: 'remote_id = ?',
      whereArgs: [proposalId],
    );

    var round = 0;
    apiService.v2Handler = (request) async {
      round += 1;
      if (round == 1) {
        return responseFor(
          request,
          cursor: '2',
          warranties: [warrantyRecord('2')],
          proposals: [proposalRecord('2')],
        );
      }
      expect(apiService.proposalDeletes, [proposalId]);
      return responseFor(
        request,
        cursor: '3',
        proposals: [proposalRecord('3', deleted: true)],
      );
    };
    apiService.proposalDeleteHandler = (id) async {
      expect(id, proposalId);
    };
    await SyncService(apiService: apiService, dbService: dbService).sync();

    expect((await database.query('warranties')).single['is_dirty'], 0);
    final proposal = (await database.query('proposals')).single;
    expect(proposal['is_dirty'], 0);
    expect(proposal['deleted_at'], now);
    expect(await dbService.getSyncV2Cursor(tenant), '3');
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
      'payload_hash': sha256
          .convert(
            utf8.encode(
              jsonEncode({'enabled': true, 'name': 'Orphan', 'price': 1}),
            ),
          )
          .toString(),
      'row_cursor': '6',
      'server_timestamp': now,
      'deleted_at': null,
      'parent_id': '40000000-0000-4000-8000-000000000099',
      'payload': {'name': 'Orphan', 'price': 1.0, 'enabled': true},
    };
    await expectLater(
      dbService.applySyncV2Response(
        franchiseeId: tenant,
        requestCursor: '5',
        responseCursor: '6',
        requestWarrantyTombstoneCursor: '0',
        warrantyTombstoneCursor: '0',
        records: {
          'clients': [clientRecord],
          'items': [itemRecord],
          'rectangles': [],
          'default_prices': [],
        },
        warranties: const [],
        proposals: const [],
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

  test('SQLite compares the complete logical tuple including delete rank',
      () async {
    await activate();
    Future<void> apply(
      Map<String, dynamic> record,
      String requestCursor,
      String responseCursor,
    ) =>
        dbService.applySyncV2Response(
          franchiseeId: tenant,
          requestCursor: requestCursor,
          responseCursor: responseCursor,
          requestWarrantyTombstoneCursor: '0',
          warrantyTombstoneCursor: '0',
          records: {
            'clients': [record],
            'items': [],
            'rectangles': [],
            'default_prices': [],
          },
          warranties: const [],
          proposals: const [],
          warrantyTombstones: const [],
          submittedChangeIds: const {
            'clients': {},
            'items': {},
            'rectangles': {},
            'default_prices': {},
          },
          outcomeStatuses: const {},
          activateProtocol: false,
        );

    await apply(
      serverClient(
        changeId: '40000000-0000-4000-8000-000000000041',
        cursor: '1',
        name: 'Generation one',
        writerId: '40000000-0000-4000-8000-000000000099',
      ),
      '0',
      '1',
    );
    await apply(
      serverClient(
        changeId: '40000000-0000-4000-8000-000000000042',
        cursor: '2',
        operation: 'delete',
        writerId: '40000000-0000-4000-8000-000000000001',
      ),
      '1',
      '2',
    );
    expect((await database.query('clients')).single['deleted_at'], now);

    await apply(
      serverClient(
        changeId: '40000000-0000-4000-8000-000000000043',
        cursor: '3',
        generation: '2',
        name: 'Restored',
        writerId: '40000000-0000-4000-8000-000000000010',
      ),
      '2',
      '3',
    );
    await apply(
      serverClient(
        changeId: '40000000-0000-4000-8000-000000000044',
        cursor: '4',
        generation: '2',
        name: 'Writer winner',
        writerId: '40000000-0000-4000-8000-000000000020',
      ),
      '3',
      '4',
    );
    await apply(
      serverClient(
        changeId: '40000000-0000-4000-8000-000000000045',
        cursor: '5',
        generation: '2',
        name: 'Writer loser',
        writerId: '40000000-0000-4000-8000-000000000019',
      ),
      '4',
      '5',
    );
    var row = (await database.query('clients')).single;
    expect(row['name'], 'Writer winner');
    expect(row['server_change_id'], '40000000-0000-4000-8000-000000000044');

    await apply(
      serverClient(
        changeId: '40000000-0000-4000-8000-000000000046',
        cursor: '6',
        generation: '2',
        name: 'Change ID winner',
        writerId: '40000000-0000-4000-8000-000000000020',
      ),
      '5',
      '6',
    );
    row = (await database.query('clients')).single;
    expect(row['name'], 'Change ID winner');
    expect(row['deleted_at'], isNull);
  });

  test('concurrent delayed responses use same-transaction cursor CAS',
      () async {
    await activate();
    Map<String, dynamic> record(String id, String changeId, String cursor) {
      final original = serverClient(changeId: changeId, cursor: cursor);
      return {...original, 'remote_id': id};
    }

    Future<Object?> apply(
      String id,
      String changeId,
      String responseCursor,
    ) async {
      try {
        await dbService.applySyncV2Response(
          franchiseeId: tenant,
          requestCursor: '0',
          responseCursor: responseCursor,
          requestWarrantyTombstoneCursor: '0',
          warrantyTombstoneCursor: '0',
          records: {
            'clients': [record(id, changeId, responseCursor)],
            'items': [],
            'rectangles': [],
            'default_prices': [],
          },
          warranties: const [],
          proposals: const [],
          warrantyTombstones: const [],
          submittedChangeIds: const {
            'clients': {},
            'items': {},
            'rectangles': {},
            'default_prices': {},
          },
          outcomeStatuses: const {},
          activateProtocol: false,
        );
        return null;
      } catch (error) {
        return error;
      }
    }

    final results = await Future.wait([
      apply(
        '40000000-0000-4000-8000-000000000051',
        '40000000-0000-4000-8000-000000000052',
        '1',
      ),
      apply(
        '40000000-0000-4000-8000-000000000053',
        '40000000-0000-4000-8000-000000000054',
        '2',
      ),
    ]);
    expect(results.where((result) => result == null), hasLength(1));
    expect(results.whereType<StateError>(), hasLength(1));
    final rows = await database.query('clients');
    expect(rows, hasLength(1));
    expect(
      await dbService.getSyncV2Cursor(tenant),
      rows.single['server_cursor'],
    );
  });

  test('bulk price changes on clean items create a pending logical change',
      () async {
    await activate();
    final clientId = await database.insert('clients', {
      'remote_id': remoteId,
      'franchisee_id': tenant,
      'name': 'Clean client',
      'photos': '[]',
      'is_dirty': 0,
      'updated_at': now,
    });
    await database.insert('items', {
      'remote_id': '40000000-0000-4000-8000-000000000061',
      'client_id': clientId,
      'name': 'Clean item',
      'price': 10,
      'enabled': 1,
      'is_dirty': 0,
      'updated_at': now,
    });
    final provider = ClientProvider();
    await provider.loadClients();

    await provider.applyBulkPrice(clientId, 42.5);

    final item = (await database.query('items')).single;
    expect(item['price'], 42.5);
    expect(item['is_dirty'], 1);
    expect(item['pending_generation'], '1');
    expect(item['pending_branch_seq'], 1);
    expect(item['pending_change_id'], isNotNull);
    expect(
      (await dbService.getPendingLwwChanges(tenant))['items'],
      hasLength(1),
    );
  });

  test('v1 drains before bootstrap and malformed v2 fails without activation',
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

    await expectLater(
      SyncService(apiService: apiService, dbService: dbService).sync(),
      throwsA(isA<ApiException>()),
    );

    expect(apiService.lastV1!['changes']['clients'], hasLength(1));
    expect(await dbService.getDirtyClients(), isEmpty);
    expect(await dbService.isSyncV2Enabled(tenant), isFalse);

    apiService.v2Handler = (request) async => responseFor(request, cursor: '1');
    await SyncService(apiService: apiService, dbService: dbService).sync();
    expect(await dbService.isSyncV2Enabled(tenant), isTrue);
    expect(await dbService.getSyncV2Cursor(tenant), '1');
  });

  test('a missing old-server v2 endpoint leaves the successful v1 drain safe',
      () async {
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Legacy dirty',
      updatedAt: DateTime.parse(now),
    ));
    apiService.v1Handler = (request) async => {
          'server_time': now,
          'warranty_tombstone_cursor': '0',
          'outcomes': {
            'clients': [
              {
                'remote_id': remoteId,
                'status': 'applied',
              }
            ],
            'items': [],
            'rectangles': [],
            'default_prices': [],
            'warranties': [],
            'proposals': [],
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
    apiService.v2Handler = (_) async => throw const ApiException(
          'Not found',
          statusCode: 404,
          endpointMissing: true,
        );

    await SyncService(apiService: apiService, dbService: dbService).sync();

    expect(await dbService.getDirtyClients(), isEmpty);
    expect(await dbService.isSyncV2Enabled(tenant), isFalse);
    expect(await dbService.getSyncV2Cursor(tenant), '0');
  });

  test(
      'bootstrap propagates network and application failures without activation',
      () async {
    apiService.v1Handler = (_) async => {
          'server_time': now,
          'warranty_tombstone_cursor': '0',
          'outcomes': {
            'clients': [],
            'items': [],
            'rectangles': [],
            'default_prices': [],
            'warranties': [],
            'proposals': [],
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

    for (final failure in <Object>[
      const ApiException('Server failed', statusCode: 500),
      const ApiException(
        'Application resource missing',
        statusCode: 404,
        code: 'application_not_found',
      ),
      StateError('network unavailable'),
    ]) {
      apiService.v2Handler = (_) async => throw failure;
      await expectLater(
        SyncService(apiService: apiService, dbService: dbService).sync(),
        throwsA(same(failure)),
      );
      expect(await dbService.isSyncV2Enabled(tenant), isFalse);
      expect(await dbService.getSyncV2Cursor(tenant), '0');
    }
  });

  test('HTTP 426 claims and drains every migrated legacy LWW row through v2',
      () async {
    const itemId = '40000000-0000-4000-8000-000000000021';
    const rectangleId = '40000000-0000-4000-8000-000000000022';
    const priceId = '40000000-0000-4000-8000-000000000023';
    final clientLocalId = await database.insert('clients', {
      'remote_id': remoteId,
      'franchisee_id': tenant,
      'name': 'Legacy client',
      'photos': '[]',
      'is_dirty': 1,
      'updated_at': now,
    });
    final itemLocalId = await database.insert('items', {
      'remote_id': itemId,
      'client_id': clientLocalId,
      'name': 'Legacy item',
      'price': 10,
      'enabled': 1,
      'is_dirty': 1,
      'updated_at': now,
    });
    await database.insert('rectangles', {
      'remote_id': rectangleId,
      'item_id': itemLocalId,
      'length': 2,
      'width': 3,
      'image_data': null,
      'is_dirty': 1,
      'updated_at': now,
    });
    await database.insert('default_prices', {
      'remote_id': priceId,
      'franchisee_id': tenant,
      'price': 12,
      'enabled': 1,
      'is_dirty': 1,
      'updated_at': now,
    });
    apiService.v1Handler = (_) async => throw const ApiException(
          'Upgrade required',
          statusCode: 426,
          code: 'sync_protocol_upgrade_required',
        );
    apiService.v2Handler = (request) async {
      expect(request['request_cursor'], '0');
      for (final collection in [
        'clients',
        'items',
        'rectangles',
        'default_prices',
      ]) {
        expect(request['changes'][collection], hasLength(1));
      }
      final clientChange = request['changes']['clients'].single;
      final itemChange = request['changes']['items'].single;
      final rectangleChange = request['changes']['rectangles'].single;
      final priceChange = request['changes']['default_prices'].single;
      Map<String, dynamic> record(
        Map<String, dynamic> change,
        Map<String, dynamic> payload, {
        String? parentId,
        bool client = false,
        bool price = false,
        Map<String, dynamic>? media,
      }) =>
          {
            'remote_id': change['remote_id'],
            'generation': change['generation'],
            'branch_seq': change['branch_seq'],
            'operation': change['operation'],
            'writer_id': change['writer_id'],
            'change_id': change['change_id'],
            'payload_hash': payloadHash(payload),
            'row_cursor': '1',
            'server_timestamp': now,
            'deleted_at': null,
            if (parentId != null) 'parent_id': parentId,
            if (client || price) 'franchisee_id': tenant,
            'payload': payload,
            if (media != null) 'media': media,
          };
      final records = <String, Map<String, dynamic>>{
        'clients': record(
          clientChange,
          Map<String, dynamic>.from(clientChange['payload'] as Map),
          client: true,
          media: {'photos': <String>[]},
        ),
        'items': record(
          itemChange,
          Map<String, dynamic>.from(itemChange['payload'] as Map),
          parentId: remoteId,
        ),
        'rectangles': record(
          rectangleChange,
          Map<String, dynamic>.from(rectangleChange['payload'] as Map),
          parentId: itemId,
          media: {'image_data': null},
        ),
        'default_prices': record(
          priceChange,
          Map<String, dynamic>.from(priceChange['payload'] as Map),
          price: true,
        ),
      };
      return {
        'protocol_version': 2,
        'request_id': request['request_id'],
        'response_cursor': '1',
        'warranty_tombstone_cursor': '0',
        'outcomes': {
          for (final collection in records.keys)
            collection: [
              {
                'change_id': records[collection]!['change_id'],
                'remote_id': records[collection]!['remote_id'],
                'status': 'applied',
                'reason_code': 'upsert_applied',
                'authoritative': records[collection],
              }
            ],
        },
        'warnings': [],
        'updates': {
          for (final collection in records.keys)
            collection: [records[collection]],
          'warranties': [],
          'proposals': [],
          'warranty_tombstones': [],
        },
      };
    };

    await SyncService(apiService: apiService, dbService: dbService).sync();

    for (final table in [
      'clients',
      'items',
      'rectangles',
      'default_prices',
    ]) {
      expect((await database.query(table)).single['is_dirty'], 0);
      expect((await database.query(table)).single['pending_change_id'], isNull);
    }
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

  test('rejects semantically invalid v2 records before the SQLite transaction',
      () async {
    await activate();
    const itemId = '40000000-0000-4000-8000-000000000031';
    const rectangleId = '40000000-0000-4000-8000-000000000032';
    const priceId = '40000000-0000-4000-8000-000000000033';
    const warrantyId = '40000000-0000-4000-8000-000000000034';
    const proposalId = '40000000-0000-4000-8000-000000000035';
    Map<String, dynamic> itemRecord(Map<String, dynamic> payload) => {
          'remote_id': itemId,
          'generation': '1',
          'branch_seq': 1,
          'operation': 'upsert',
          'writer_id': serverWriter,
          'change_id': serverChange,
          'payload_hash': payloadHash(payload),
          'row_cursor': '1',
          'server_timestamp': now,
          'deleted_at': null,
          'parent_id': remoteId,
          'payload': payload,
        };
    Map<String, dynamic> rectangleRecord(
      Map<String, dynamic> payload, {
      dynamic imageData,
    }) =>
        {
          'remote_id': rectangleId,
          'generation': '1',
          'branch_seq': 1,
          'operation': 'upsert',
          'writer_id': serverWriter,
          'change_id': serverChange,
          'payload_hash': payloadHash(payload),
          'row_cursor': '1',
          'server_timestamp': now,
          'deleted_at': null,
          'parent_id': itemId,
          'payload': payload,
          'media': {'image_data': imageData},
        };
    Map<String, dynamic> priceRecord(Map<String, dynamic> payload) => {
          'remote_id': priceId,
          'generation': '1',
          'branch_seq': 1,
          'operation': 'upsert',
          'writer_id': serverWriter,
          'change_id': serverChange,
          'payload_hash': payloadHash(payload),
          'row_cursor': '1',
          'server_timestamp': now,
          'deleted_at': null,
          'franchisee_id': tenant,
          'payload': payload,
        };
    Map<String, dynamic> warrantyRecord() => {
          'remote_id': warrantyId,
          'client_id': remoteId,
          'version': 1,
          'start_date': now,
          'duration_years': 5,
          'pdf_url': '/api/warranty/$warrantyId/download',
          'warranty_card_number': 'VALID',
          'row_cursor': '1',
          'server_timestamp': now,
          'deleted_at': null,
        };
    Map<String, dynamic> proposalRecord() => {
          'remote_id': proposalId,
          'client_id': remoteId,
          'pdf_url': '/api/proposal/$proposalId/download',
          'row_cursor': '1',
          'server_timestamp': now,
          'deleted_at': null,
        };
    Map<String, dynamic> copy(Map<String, dynamic> value) =>
        Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

    final builders =
        <Map<String, dynamic> Function(Map<String, dynamic> request)>[
      (request) {
        final record = serverClient(changeId: serverChange, cursor: '1');
        record['payload_hash'] = List.filled(64, 'f').join();
        return responseFor(request, cursor: '1', clients: [record]);
      },
      (request) {
        final record = serverClient(changeId: serverChange, cursor: '1');
        final payload = Map<String, dynamic>.from(record['payload'] as Map);
        payload['email'] = 'not-an-email';
        record['payload'] = payload;
        record['payload_hash'] = payloadHash(payload);
        return responseFor(request, cursor: '1', clients: [record]);
      },
      (request) {
        final record = serverClient(changeId: serverChange, cursor: '1');
        final payload = Map<String, dynamic>.from(record['payload'] as Map);
        payload['site_address'] = List.filled(256, 'x').join();
        record['payload'] = payload;
        record['payload_hash'] = payloadHash(payload);
        return responseFor(request, cursor: '1', clients: [record]);
      },
      (request) {
        final record = serverClient(changeId: serverChange, cursor: '1');
        final payload = Map<String, dynamic>.from(record['payload'] as Map);
        payload['latitude'] = 91;
        record['payload'] = payload;
        record['payload_hash'] = payloadHash(payload);
        return responseFor(request, cursor: '1', clients: [record]);
      },
      (request) {
        final record = serverClient(changeId: serverChange, cursor: '1');
        record['media'] = {
          'photos': List.filled(
            101,
            '/api/photos/client/$remoteId/'
            '40000000-0000-4000-8000-000000000036.jpg',
          ),
        };
        return responseFor(request, cursor: '1', clients: [record]);
      },
      (request) => responseFor(
            request,
            cursor: '1',
            items: [
              itemRecord({'enabled': true, 'name': 'Bad price', 'price': 1.001})
            ],
          ),
      (request) => responseFor(
            request,
            cursor: '1',
            rectangles: [
              rectangleRecord({'length': 0, 'width': 3}),
            ],
          ),
      (request) => responseFor(
            request,
            cursor: '1',
            rectangles: [
              rectangleRecord(
                {'length': 2, 'width': 3},
                imageData: 'data:image/png;base64,invalid***',
              ),
            ],
          ),
      (request) => responseFor(
            request,
            cursor: '1',
            defaultPrices: [
              priceRecord({'enabled': true, 'price': 100000000})
            ],
          ),
      (request) {
        final record = warrantyRecord();
        record['duration_years'] = 0;
        return responseFor(request, cursor: '1', warranties: [record]);
      },
      (request) {
        final record = proposalRecord();
        record['pdf_url'] = 'https://foreign.invalid/proposal.pdf';
        return responseFor(request, cursor: '1', proposals: [record]);
      },
      (request) {
        final record = serverClient(changeId: serverChange, cursor: '1');
        record['server_timestamp'] = '2026-07-30T00:00:00';
        return responseFor(request, cursor: '1', clients: [record]);
      },
      (request) {
        final record = serverClient(changeId: serverChange, cursor: '1');
        record['unexpected'] = true;
        return responseFor(request, cursor: '1', clients: [record]);
      },
      (request) => responseFor(
            request,
            cursor: '1',
            clients: List.generate(
              1001,
              (_) => copy(
                serverClient(changeId: serverChange, cursor: '1'),
              ),
            ),
          ),
    ];

    for (final builder in builders) {
      apiService.v2Handler = (request) async => builder(request);
      await expectLater(
        SyncService(apiService: apiService, dbService: dbService).sync(),
        throwsA(isA<ApiException>()),
      );
      expect(await dbService.getSyncV2Cursor(tenant), '0');
      expect(await database.query('clients'), isEmpty);
      expect(await database.query('items'), isEmpty);
      expect(await database.query('rectangles'), isEmpty);
      expect(await database.query('default_prices'), isEmpty);
      expect(await database.query('warranties'), isEmpty);
      expect(await database.query('proposals'), isEmpty);
    }
  });

  test('rejects invalid outcome/reason/authoritative combinations', () async {
    await activate();
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Pending',
      updatedAt: DateTime.parse(now),
    ));
    final corruptions = <void Function(Map<String, dynamic>, dynamic)>[
      (outcome, submitted) => outcome['reason_code'] = 'invalid_payload',
      (outcome, submitted) {
        outcome['status'] = 'rejected';
        outcome['reason_code'] = 'invalid_payload';
      },
      (outcome, submitted) {
        final authoritative =
            Map<String, dynamic>.from(outcome['authoritative'] as Map);
        authoritative['change_id'] = serverChange;
        outcome['authoritative'] = authoritative;
      },
    ];
    for (final corrupt in corruptions) {
      apiService.v2Handler = (request) async {
        final submitted = request['changes']['clients'].single;
        final record = serverClient(
          changeId: submitted['change_id'],
          cursor: '1',
          name: 'Pending',
        );
        final outcome = <String, dynamic>{
          'change_id': submitted['change_id'],
          'remote_id': remoteId,
          'status': 'applied',
          'reason_code': 'upsert_applied',
          'authoritative': record,
        };
        corrupt(outcome, submitted);
        return responseFor(
          request,
          cursor: '1',
          clientOutcomes: [outcome],
          clients: [record],
        );
      };
      await expectLater(
        SyncService(apiService: apiService, dbService: dbService).sync(),
        throwsA(isA<ApiException>()),
      );
      expect(await dbService.getSyncV2Cursor(tenant), '0');
      expect((await database.query('clients')).single['is_dirty'], 1);
    }
  });
}
