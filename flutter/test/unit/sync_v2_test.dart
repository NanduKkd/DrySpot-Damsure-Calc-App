import 'dart:convert';

import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/lww_protocol.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class V2ApiService extends ApiService {
  V2ApiService();

  Map<String, dynamic>? lastV1;
  Map<String, dynamic>? lastV2;
  final List<Map<String, dynamic>> v2Requests = [];
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
    v2Requests.add(data);
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
      pending_change_id TEXT,
      pending_operation_rank INTEGER,
      pending_payload_hash TEXT
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
    await db.execute('''
      CREATE TABLE pending_client_photos (
        franchisee_id TEXT NOT NULL,
        client_remote_id TEXT NOT NULL,
        local_path TEXT NOT NULL,
        PRIMARY KEY (franchisee_id, client_remote_id, local_path)
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
    List<Map<String, dynamic>> itemOutcomes = const [],
    List<Map<String, dynamic>> rectangleOutcomes = const [],
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
          'items': itemOutcomes,
          'rectangles': rectangleOutcomes,
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

  Map<String, dynamic> lwwUpsertRecord({
    required String id,
    required String generation,
    required int branch,
    required String writer,
    required String change,
    required String cursor,
    required Map<String, dynamic> payload,
    String? parentId,
    bool tenantOwned = false,
    Map<String, dynamic>? media,
  }) =>
      {
        'remote_id': id,
        'generation': generation,
        'branch_seq': branch,
        'operation': 'upsert',
        'writer_id': writer,
        'change_id': change,
        'payload_hash': payloadHash(payload),
        'row_cursor': cursor,
        'server_timestamp': now,
        'deleted_at': null,
        if (parentId != null) 'parent_id': parentId,
        if (tenantOwned) 'franchisee_id': tenant,
        'payload': payload,
        if (media != null) 'media': media,
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

  test(
      'photo acknowledgement rejects foreign tenant/client and unsafe paths before CAS',
      () async {
    const localPhoto = '/offline/ownership.jpg';
    const otherTenant = '40000000-0000-4000-8000-000000000081';
    const otherClient = '40000000-0000-4000-8000-000000000082';
    const filename = '40000000-0000-4000-8000-000000000083.jpg';
    const validCanonical = '/api/photos/client/$remoteId/$filename';
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Owned photo',
      photos: const [localPhoto],
      updatedAt: DateTime.parse(now),
    ));

    Future<void> expectRetained() async {
      expect(await dbService.getPendingClientPhotos(tenant), [
        {
          'client_remote_id': remoteId,
          'local_path': localPhoto,
        },
      ]);
      expect(
        jsonDecode(
          (await database.query('clients')).single['photos'] as String,
        ),
        [localPhoto],
      );
    }

    await expectLater(
      dbService.acknowledgeClientPhotoUpload(
        franchiseeId: tenant,
        remoteId: remoteId,
        localPath: localPhoto,
        canonicalPath: '/api/photos/client/$otherClient/$filename',
      ),
      throwsA(isA<FormatException>()),
    );
    await expectRetained();

    expect(
      await dbService.acknowledgeClientPhotoUpload(
        franchiseeId: otherTenant,
        remoteId: remoteId,
        localPath: localPhoto,
        canonicalPath: validCanonical,
      ),
      isFalse,
    );
    await expectRetained();

    for (final unsafePath in const [
      '/api/photos/client/$remoteId/../$filename',
      '/api/photos/client/$remoteId/%2e%2e/$filename',
      '/api/photos/client/$remoteId/not-a-server-file.jpg',
      '$validCanonical?download=1',
    ]) {
      await expectLater(
        dbService.acknowledgeClientPhotoUpload(
          franchiseeId: tenant,
          remoteId: remoteId,
          localPath: localPhoto,
          canonicalPath: unsafePath,
        ),
        throwsA(isA<FormatException>()),
      );
      await expectRetained();
    }

    expect(
      await dbService.acknowledgeClientPhotoUpload(
        franchiseeId: tenant,
        remoteId: remoteId,
        localPath: localPhoto,
        canonicalPath: validCanonical,
      ),
      isTrue,
    );
    expect(await dbService.getPendingClientPhotos(tenant), isEmpty);
    expect(
      jsonDecode((await database.query('clients')).single['photos'] as String),
      [validCanonical],
    );
  });

  for (final failureCase in <String, Object>{
    'network': StateError('photo network failed'),
    'HTTP 500': const ApiException('photo failed', statusCode: 500),
  }.entries) {
    test(
        'partial two-photo ${failureCase.key} failure preserves the second path and retries',
        () async {
      await activate();
      const localOne = '/offline/one.jpg';
      const localTwo = '/offline/two.jpg';
      const canonicalOne =
          '/api/photos/client/$remoteId/40000000-0000-4000-8000-000000000041.jpg';
      const canonicalTwo =
          '/api/photos/client/$remoteId/40000000-0000-4000-8000-000000000042.jpg';
      await dbService.insertClient(Client(
        remoteId: remoteId,
        franchiseeId: tenant,
        name: 'Two photos',
        photos: const [localOne, localTwo],
        updatedAt: DateTime.parse(now),
      ));

      Map<String, dynamic>? authoritative;
      var v2Round = 0;
      apiService.v2Handler = (request) async {
        v2Round += 1;
        switch (v2Round) {
          case 1:
            final submitted = request['changes']['clients'].single;
            authoritative = serverClient(
              changeId: submitted['change_id'],
              cursor: '1',
              name: 'Two photos',
              generation: submitted['generation'],
              branch: submitted['branch_seq'],
              writerId: submitted['writer_id'],
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
                  'authoritative': authoritative!,
                },
              ],
              clients: [authoritative!],
            );
          case 2:
            expect(request['request_cursor'], '1');
            expect(request['changes']['clients'], isEmpty);
            final reconciled = {
              ...authoritative!,
              'row_cursor': '2',
              'media': {
                'photos': [canonicalOne],
              },
            };
            authoritative = reconciled;
            return responseFor(
              request,
              cursor: '2',
              clients: [reconciled],
            );
          case 3:
            expect(request['request_cursor'], '2');
            expect(request['changes']['clients'], isEmpty);
            return responseFor(request, cursor: '2');
          case 4:
            final reconciled = {
              ...authoritative!,
              'row_cursor': '3',
              'media': {
                'photos': [canonicalOne, canonicalTwo],
              },
            };
            authoritative = reconciled;
            return responseFor(
              request,
              cursor: '3',
              clients: [reconciled],
            );
          default:
            return responseFor(request, cursor: '3');
        }
      };
      var uploadAttempt = 0;
      apiService.photoHandler = (_, path) async {
        uploadAttempt += 1;
        if (uploadAttempt == 1) {
          expect(path, localOne);
          return canonicalOne;
        }
        if (uploadAttempt == 2) {
          expect(path, localTwo);
          throw failureCase.value;
        }
        expect(path, localTwo);
        return canonicalTwo;
      };

      await expectLater(
        SyncService(apiService: apiService, dbService: dbService).sync(),
        throwsA(same(failureCase.value)),
      );

      var row = (await database.query('clients')).single;
      expect(jsonDecode(row['photos'] as String), [canonicalOne, localTwo]);
      expect(row['is_dirty'], 0);
      expect(await dbService.getSyncV2Cursor(tenant), '2');
      expect(await dbService.getPendingClientPhotos(tenant), [
        {
          'client_remote_id': remoteId,
          'local_path': localTwo,
        },
      ]);

      await SyncService(apiService: apiService, dbService: dbService).sync();

      row = (await database.query('clients')).single;
      expect(
        jsonDecode(row['photos'] as String),
        [canonicalOne, canonicalTwo],
      );
      expect(await dbService.getPendingClientPhotos(tenant), isEmpty);
      expect(await dbService.getSyncV2Cursor(tenant), '3');
      expect(apiService.photoUploads, [
        [remoteId, localOne],
        [remoteId, localTwo],
        [remoteId, localTwo],
      ]);

      await SyncService(apiService: apiService, dbService: dbService).sync();
      expect(apiService.photoUploads, hasLength(3));
    });
  }

  test(
      'ambiguous committed photo response preserves local intent through pull and converges on retry',
      () async {
    await activate();
    const localPhoto = '/offline/ambiguous.jpg';
    const canonicalPhoto =
        '/api/photos/client/$remoteId/40000000-0000-4000-8000-000000000043.jpg';
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Ambiguous photo',
      photos: const [localPhoto],
      updatedAt: DateTime.parse(now),
    ));
    Map<String, dynamic>? authoritative;
    var v2Round = 0;
    apiService.v2Handler = (request) async {
      v2Round += 1;
      if (v2Round == 1) {
        final submitted = request['changes']['clients'].single;
        authoritative = serverClient(
          changeId: submitted['change_id'],
          cursor: '1',
          name: 'Ambiguous photo',
          generation: submitted['generation'],
          branch: submitted['branch_seq'],
          writerId: submitted['writer_id'],
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
              'authoritative': authoritative!,
            },
          ],
          clients: [authoritative!],
        );
      }
      if (v2Round == 2) {
        final committed = {
          ...authoritative!,
          'row_cursor': '2',
          'media': {
            'photos': [canonicalPhoto],
          },
        };
        authoritative = committed;
        return responseFor(request, cursor: '2', clients: [committed]);
      }
      final converged = {
        ...authoritative!,
        'row_cursor': '3',
        'media': {
          'photos': [canonicalPhoto],
        },
      };
      authoritative = converged;
      return responseFor(request, cursor: '3', clients: [converged]);
    };
    var attempts = 0;
    apiService.photoHandler = (_, path) async {
      attempts += 1;
      expect(path, localPhoto);
      if (attempts == 1) {
        throw StateError('response lost after server commit');
      }
      final row = (await database.query('clients')).single;
      expect(
        jsonDecode(row['photos'] as String),
        [canonicalPhoto, localPhoto],
        reason: 'the pull must not erase the unacknowledged local path',
      );
      return canonicalPhoto;
    };

    await expectLater(
      SyncService(apiService: apiService, dbService: dbService).sync(),
      throwsA(isA<StateError>()),
    );
    expect(await dbService.getPendingClientPhotos(tenant), hasLength(1));
    expect(
      jsonDecode((await database.query('clients')).single['photos'] as String),
      [localPhoto],
    );

    await SyncService(apiService: apiService, dbService: dbService).sync();

    expect(
      jsonDecode((await database.query('clients')).single['photos'] as String),
      [canonicalPhoto],
    );
    expect(await dbService.getPendingClientPhotos(tenant), isEmpty);
    expect(apiService.photoUploads, hasLength(2));
  });

  test('photo acknowledgement CAS preserves an in-flight local edit', () async {
    await activate();
    const localOne = '/offline/in-flight-one.jpg';
    const localTwo = '/offline/in-flight-two.jpg';
    const localThree = '/offline/in-flight-three.jpg';
    const canonicalOne =
        '/api/photos/client/$remoteId/40000000-0000-4000-8000-000000000044.jpg';
    await dbService.insertClient(Client(
      remoteId: remoteId,
      franchiseeId: tenant,
      name: 'Before upload',
      photos: const [localOne, localTwo],
      updatedAt: DateTime.parse(now),
    ));
    Map<String, dynamic>? authoritative;
    var v2Round = 0;
    apiService.v2Handler = (request) async {
      v2Round += 1;
      if (v2Round == 1) {
        final submitted = request['changes']['clients'].single;
        authoritative = serverClient(
          changeId: submitted['change_id'],
          cursor: '1',
          name: 'Before upload',
          generation: submitted['generation'],
          branch: submitted['branch_seq'],
          writerId: submitted['writer_id'],
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
              'authoritative': authoritative!,
            },
          ],
          clients: [authoritative!],
        );
      }
      final inFlight = request['changes']['clients'].single;
      final reconciled = {
        ...authoritative!,
        'row_cursor': '2',
        'media': {
          'photos': [canonicalOne],
        },
      };
      authoritative = reconciled;
      return responseFor(
        request,
        cursor: '2',
        clientOutcomes: [
          {
            'change_id': inFlight['change_id'],
            'remote_id': remoteId,
            'status': 'rejected',
            'reason_code': 'invalid_payload',
          },
        ],
        clients: [reconciled],
      );
    };
    var uploadAttempt = 0;
    apiService.photoHandler = (_, path) async {
      uploadAttempt += 1;
      if (uploadAttempt == 1) {
        final local = await dbService.getClientByRemoteId(remoteId);
        await dbService.updateClient(
          local!.copyWith(
            name: 'Edited while uploading',
            photos: const [localOne, localTwo, localThree],
            isDirty: true,
            updatedAt: DateTime.utc(2026, 7, 30, 0, 1),
          ),
        );
        return canonicalOne;
      }
      expect(path, localTwo);
      throw StateError('second upload failed');
    };

    await expectLater(
      SyncService(apiService: apiService, dbService: dbService).sync(),
      throwsA(isA<StateError>()),
    );

    final row = (await database.query('clients')).single;
    expect(row['name'], 'Edited while uploading');
    expect(row['is_dirty'], 1);
    expect(row['pending_change_id'], isNotNull);
    expect(
      jsonDecode(row['photos'] as String),
      [canonicalOne, localTwo, localThree],
    );
    expect(await dbService.getPendingClientPhotos(tenant), [
      {'client_remote_id': remoteId, 'local_path': localTwo},
      {'client_remote_id': remoteId, 'local_path': localThree},
    ]);
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

  for (final writerCase in <String, String>{
    'lexically lower': '10000000-0000-4000-8000-000000000001',
    'lexically higher': 'f0000000-0000-4000-8000-000000000001',
  }.entries) {
    test(
        'HTTP 426 baselines and rebases all four legacy entities with ${writerCase.key} writer',
        () async {
      const itemId = '40000000-0000-4000-8000-000000000021';
      const rectangleId = '40000000-0000-4000-8000-000000000022';
      const priceId = '40000000-0000-4000-8000-000000000023';
      const baselineChanges = {
        'clients': '40000000-0000-4000-8000-000000000051',
        'items': '40000000-0000-4000-8000-000000000052',
        'rectangles': '40000000-0000-4000-8000-000000000053',
        'default_prices': '40000000-0000-4000-8000-000000000054',
      };
      const preBaselineChanges = {
        'clients': '40000000-0000-4000-8000-000000000071',
        'items': '40000000-0000-4000-8000-000000000072',
        'rectangles': '40000000-0000-4000-8000-000000000073',
        'default_prices': '40000000-0000-4000-8000-000000000074',
      };
      const localClientPayload = <String, dynamic>{
        'address': 'Local address',
        'discounted_price': 99,
        'email': 'local@example.com',
        'latitude': 10,
        'longitude': 20,
        'name': 'Legacy client edit',
        'phone': '1234567890',
        'site_address': 'Local site',
      };
      const localItemPayload = <String, dynamic>{
        'enabled': true,
        'name': 'Legacy item edit',
        'price': 10,
      };
      const localRectanglePayload = <String, dynamic>{
        'length': 2,
        'width': 3,
      };
      const localPricePayload = <String, dynamic>{
        'enabled': true,
        'price': 12,
      };
      const serverClientPayload = <String, dynamic>{
        'address': null,
        'discounted_price': null,
        'email': null,
        'latitude': null,
        'longitude': null,
        'name': 'Server client baseline',
        'phone': null,
        'site_address': null,
      };
      const serverItemPayload = <String, dynamic>{
        'enabled': false,
        'name': 'Server item baseline',
        'price': 20,
      };
      const serverRectanglePayload = <String, dynamic>{
        'length': 8,
        'width': 9,
      };
      const serverPricePayload = <String, dynamic>{
        'enabled': false,
        'price': 30,
      };

      await database.insert('sync_state', {
        'key': 'lww_installation_writer_id',
        'value': writerCase.value,
      });
      final clientLocalId = await database.insert('clients', {
        'remote_id': remoteId,
        'franchisee_id': tenant,
        'name': localClientPayload['name'],
        'address': localClientPayload['address'],
        'site_address': localClientPayload['site_address'],
        'email': localClientPayload['email'],
        'phone': localClientPayload['phone'],
        'latitude': localClientPayload['latitude'],
        'longitude': localClientPayload['longitude'],
        'discounted_price': localClientPayload['discounted_price'],
        'photos': '[]',
        'is_dirty': 1,
        'updated_at': now,
        'pending_base_generation': '0',
        'pending_generation': '1',
        'pending_branch_seq': 1,
        'pending_writer_id': writerCase.value,
        'pending_change_id': preBaselineChanges['clients'],
      });
      final itemLocalId = await database.insert('items', {
        'remote_id': itemId,
        'client_id': clientLocalId,
        'name': localItemPayload['name'],
        'price': localItemPayload['price'],
        'enabled': 1,
        'is_dirty': 1,
        'updated_at': now,
        'pending_base_generation': '0',
        'pending_generation': '1',
        'pending_branch_seq': 1,
        'pending_writer_id': writerCase.value,
        'pending_change_id': preBaselineChanges['items'],
      });
      await database.insert('rectangles', {
        'remote_id': rectangleId,
        'item_id': itemLocalId,
        'length': localRectanglePayload['length'],
        'width': localRectanglePayload['width'],
        'image_data': 'data:image/png;base64,bG9jYWw=',
        'is_dirty': 1,
        'updated_at': now,
        'pending_base_generation': '0',
        'pending_generation': '1',
        'pending_branch_seq': 1,
        'pending_writer_id': writerCase.value,
        'pending_change_id': preBaselineChanges['rectangles'],
      });
      await database.insert('default_prices', {
        'remote_id': priceId,
        'franchisee_id': tenant,
        'price': localPricePayload['price'],
        'enabled': 1,
        'is_dirty': 1,
        'updated_at': now,
        'pending_base_generation': '0',
        'pending_generation': '1',
        'pending_branch_seq': 1,
        'pending_writer_id': writerCase.value,
        'pending_change_id': preBaselineChanges['default_prices'],
      });

      final baseline = <String, Map<String, dynamic>>{
        'clients': lwwUpsertRecord(
          id: remoteId,
          generation: '1',
          branch: 1,
          writer: serverWriter,
          change: baselineChanges['clients']!,
          cursor: '1',
          payload: serverClientPayload,
          tenantOwned: true,
          media: {'photos': <String>[]},
        ),
        'items': lwwUpsertRecord(
          id: itemId,
          generation: '1',
          branch: 1,
          writer: serverWriter,
          change: baselineChanges['items']!,
          cursor: '1',
          payload: serverItemPayload,
          parentId: remoteId,
        ),
        'rectangles': lwwUpsertRecord(
          id: rectangleId,
          generation: '1',
          branch: 1,
          writer: serverWriter,
          change: baselineChanges['rectangles']!,
          cursor: '1',
          payload: serverRectanglePayload,
          parentId: itemId,
          media: {'image_data': null},
        ),
        'default_prices': lwwUpsertRecord(
          id: priceId,
          generation: '1',
          branch: 1,
          writer: serverWriter,
          change: baselineChanges['default_prices']!,
          cursor: '1',
          payload: serverPricePayload,
          tenantOwned: true,
        ),
      };
      apiService.v1Handler = (_) async => throw const ApiException(
            'Upgrade required',
            statusCode: 426,
            code: 'sync_protocol_upgrade_required',
          );
      var round = 0;
      apiService.v2Handler = (request) async {
        round += 1;
        if (round == 1) {
          expect(request['request_cursor'], '0');
          for (final collection in baseline.keys) {
            expect(request['changes'][collection], isEmpty);
          }
          return responseFor(
            request,
            cursor: '1',
            clients: [baseline['clients']!],
            items: [baseline['items']!],
            rectangles: [baseline['rectangles']!],
            defaultPrices: [baseline['default_prices']!],
          );
        }
        expect(request['request_cursor'], '1');
        final submitted = <String, Map<String, dynamic>>{
          for (final collection in baseline.keys)
            collection: Map<String, dynamic>.from(
              request['changes'][collection].single as Map,
            ),
        };
        for (final change in submitted.values) {
          expect(change['base_generation'], '1');
          expect(change['generation'], '2');
          expect(change['branch_seq'], 1);
          expect(change['writer_id'], writerCase.value);
        }
        for (final entry in submitted.entries) {
          expect(
            entry.value['change_id'],
            isNot(preBaselineChanges[entry.key]),
          );
        }
        expect(submitted['clients']!['payload'], localClientPayload);
        expect(submitted['items']!['payload'], localItemPayload);
        expect(
          submitted['rectangles']!['payload'],
          localRectanglePayload,
        );
        expect(submitted['default_prices']!['payload'], localPricePayload);
        final accepted = <String, Map<String, dynamic>>{
          'clients': lwwUpsertRecord(
            id: remoteId,
            generation: '2',
            branch: 1,
            writer: writerCase.value,
            change: submitted['clients']!['change_id'],
            cursor: '2',
            payload: localClientPayload,
            tenantOwned: true,
            media: {'photos': <String>[]},
          ),
          'items': lwwUpsertRecord(
            id: itemId,
            generation: '2',
            branch: 1,
            writer: writerCase.value,
            change: submitted['items']!['change_id'],
            cursor: '2',
            payload: localItemPayload,
            parentId: remoteId,
          ),
          'rectangles': lwwUpsertRecord(
            id: rectangleId,
            generation: '2',
            branch: 1,
            writer: writerCase.value,
            change: submitted['rectangles']!['change_id'],
            cursor: '2',
            payload: localRectanglePayload,
            parentId: itemId,
            media: Map<String, dynamic>.from(
              submitted['rectangles']!['media'] as Map,
            ),
          ),
          'default_prices': lwwUpsertRecord(
            id: priceId,
            generation: '2',
            branch: 1,
            writer: writerCase.value,
            change: submitted['default_prices']!['change_id'],
            cursor: '2',
            payload: localPricePayload,
            tenantOwned: true,
          ),
        };
        List<Map<String, dynamic>> outcomes(String collection) => [
              {
                'change_id': submitted[collection]!['change_id'],
                'remote_id': submitted[collection]!['remote_id'],
                'status': 'applied',
                'reason_code': 'upsert_applied',
                'authoritative': accepted[collection],
              },
            ];
        return responseFor(
          request,
          cursor: '2',
          clientOutcomes: outcomes('clients'),
          itemOutcomes: outcomes('items'),
          rectangleOutcomes: outcomes('rectangles'),
          defaultPriceOutcomes: outcomes('default_prices'),
          clients: [accepted['clients']!],
          items: [accepted['items']!],
          rectangles: [accepted['rectangles']!],
          defaultPrices: [accepted['default_prices']!],
        );
      };

      await SyncService(apiService: apiService, dbService: dbService).sync();

      expect((await database.query('clients')).single['name'],
          localClientPayload['name']);
      expect((await database.query('items')).single['name'],
          localItemPayload['name']);
      expect((await database.query('rectangles')).single['length'],
          localRectanglePayload['length']);
      expect((await database.query('default_prices')).single['price'],
          localPricePayload['price']);
      for (final table in baseline.keys) {
        final row = (await database.query(table)).single;
        expect(row['server_generation'], '2');
        expect(row['is_dirty'], 0);
        expect(row['pending_change_id'], isNull);
      }
      expect(apiService.v2Requests, hasLength(2));
      expect(await dbService.isSyncV2Enabled(tenant), isTrue);
      expect(await dbService.getSyncV2Cursor(tenant), '2');
    });
  }

  for (final lostWriterCase in <String, String>{
    'lexically lower': '10000000-0000-4000-8000-000000000087',
    'lexically higher': 'f0000000-0000-4000-8000-000000000087',
  }.entries) {
    test(
        '426 retry finalizes exact committed identities with blank email and ${lostWriterCase.key} writer',
        () async {
      const itemId = '40000000-0000-4000-8000-000000000084';
      const rectangleId = '40000000-0000-4000-8000-000000000085';
      const priceId = '40000000-0000-4000-8000-000000000086';
      final localWriter = lostWriterCase.value;
      const ids = {
        'clients': remoteId,
        'items': itemId,
        'rectangles': rectangleId,
        'default_prices': priceId,
      };
      const localPayloads = <String, Map<String, dynamic>>{
        'clients': {
          'address': 'Preserved address',
          'discounted_price': 44.44,
          'email': '',
          'latitude': 11.123456789,
          'longitude': -0.0,
          'name': 'Committed client intent',
          'phone': '1234567890',
          'site_address': 'Preserved site',
        },
        'items': {
          'enabled': true,
          'name': 'Committed item intent',
          'price': 14.10,
        },
        'rectangles': {'length': 4.123456789, 'width': 0.0000001},
        'default_prices': {'enabled': true, 'price': 18.10},
      };
      final canonicalLocalPayloads = {
        for (final entry in localPayloads.entries)
          entry.key: canonicalLwwMutablePayload(entry.key, entry.value),
      };
      const baselinePayloads = <String, Map<String, dynamic>>{
        'clients': {
          'address': null,
          'discounted_price': null,
          'email': null,
          'latitude': null,
          'longitude': null,
          'name': 'Older server client',
          'phone': null,
          'site_address': null,
        },
        'items': {
          'enabled': false,
          'name': 'Older server item',
          'price': 24,
        },
        'rectangles': {'length': 8, 'width': 9},
        'default_prices': {'enabled': false, 'price': 28},
      };
      const baselineChanges = {
        'clients': '40000000-0000-4000-8000-000000000091',
        'items': '40000000-0000-4000-8000-000000000092',
        'rectangles': '40000000-0000-4000-8000-000000000093',
        'default_prices': '40000000-0000-4000-8000-000000000094',
      };

      await database.insert('sync_state', {
        'key': 'lww_installation_writer_id',
        'value': localWriter,
      });
      final clientLocalId = await database.insert('clients', {
        'remote_id': remoteId,
        'franchisee_id': tenant,
        'name': localPayloads['clients']!['name'],
        'address': localPayloads['clients']!['address'],
        'site_address': localPayloads['clients']!['site_address'],
        'email': localPayloads['clients']!['email'],
        'phone': localPayloads['clients']!['phone'],
        'latitude': localPayloads['clients']!['latitude'],
        'longitude': localPayloads['clients']!['longitude'],
        'discounted_price': localPayloads['clients']!['discounted_price'],
        'photos': '[]',
        'is_dirty': 1,
        'updated_at': now,
      });
      final itemLocalId = await database.insert('items', {
        'remote_id': itemId,
        'client_id': clientLocalId,
        'name': localPayloads['items']!['name'],
        'price': localPayloads['items']!['price'],
        'enabled': 1,
        'is_dirty': 1,
        'updated_at': now,
      });
      await database.insert('rectangles', {
        'remote_id': rectangleId,
        'item_id': itemLocalId,
        'length': localPayloads['rectangles']!['length'],
        'width': localPayloads['rectangles']!['width'],
        'image_data': null,
        'is_dirty': 1,
        'updated_at': now,
      });
      await database.insert('default_prices', {
        'remote_id': priceId,
        'franchisee_id': tenant,
        'price': localPayloads['default_prices']!['price'],
        'enabled': 1,
        'is_dirty': 1,
        'updated_at': now,
      });

      String? parentFor(String collection) => switch (collection) {
            'items' => remoteId,
            'rectangles' => itemId,
            _ => null,
          };
      Map<String, dynamic> recordFor(
        String collection, {
        required String generation,
        required String writer,
        required String change,
        required String cursor,
        required Map<String, dynamic> payload,
        Map<String, dynamic>? media,
      }) =>
          lwwUpsertRecord(
            id: ids[collection]!,
            generation: generation,
            branch: 1,
            writer: writer,
            change: change,
            cursor: cursor,
            payload: payload,
            parentId: parentFor(collection),
            tenantOwned:
                collection == 'clients' || collection == 'default_prices',
            media: media ??
                (collection == 'clients'
                    ? {'photos': <String>[]}
                    : collection == 'rectangles'
                        ? {'image_data': null}
                        : null),
          );
      final baseline = {
        for (final collection in ids.keys)
          collection: recordFor(
            collection,
            generation: '1',
            writer: serverWriter,
            change: baselineChanges[collection]!,
            cursor: '1',
            payload: baselinePayloads[collection]!,
          ),
      };

      apiService.v1Handler = (_) async => throw const ApiException(
            'Upgrade required',
            statusCode: 426,
            code: 'sync_protocol_upgrade_required',
          );
      var round = 0;
      Map<String, Map<String, dynamic>>? committedChanges;
      Map<String, Map<String, dynamic>>? committedRecords;
      apiService.v2Handler = (request) async {
        round += 1;
        if (round == 1) {
          expect(request['request_cursor'], '0');
          for (final collection in ids.keys) {
            expect(request['changes'][collection], isEmpty);
          }
          return responseFor(
            request,
            cursor: '1',
            clients: [baseline['clients']!],
            items: [baseline['items']!],
            rectangles: [baseline['rectangles']!],
            defaultPrices: [baseline['default_prices']!],
          );
        }
        if (round == 2) {
          committedChanges = {
            for (final collection in ids.keys)
              collection: Map<String, dynamic>.from(
                request['changes'][collection].single as Map,
              ),
          };
          for (final collection in ids.keys) {
            final submitted = committedChanges![collection]!;
            expect(submitted['base_generation'], '1');
            expect(submitted['generation'], '2');
            expect(submitted['branch_seq'], 1);
            expect(submitted['writer_id'], localWriter);
            expect(submitted['payload'], canonicalLocalPayloads[collection]);
          }
          committedRecords = {
            for (final collection in ids.keys)
              collection: recordFor(
                collection,
                generation: '2',
                writer: committedChanges![collection]!['writer_id'] as String,
                change: committedChanges![collection]!['change_id'] as String,
                cursor: '2',
                payload: Map<String, dynamic>.from(
                  committedChanges![collection]!['payload'] as Map,
                ),
                media: collection == 'rectangles'
                    ? Map<String, dynamic>.from(
                        committedChanges![collection]!['media'] as Map,
                      )
                    : null,
              ),
          };
          throw StateError('response lost after committed bootstrap batch');
        }
        if (round == 3) {
          expect(request['request_cursor'], '1');
          for (final collection in ids.keys) {
            expect(request['changes'][collection], isEmpty);
          }
          return responseFor(
            request,
            cursor: '2',
            clients: [committedRecords!['clients']!],
            items: [committedRecords!['items']!],
            rectangles: [committedRecords!['rectangles']!],
            defaultPrices: [committedRecords!['default_prices']!],
          );
        }
        expect(round, 4);
        expect(request['request_cursor'], '2');
        for (final collection in ids.keys) {
          expect(
            request['changes'][collection],
            isEmpty,
            reason: 'an exact committed candidate must not become generation 3',
          );
        }
        return responseFor(request, cursor: '2');
      };

      await expectLater(
        SyncService(apiService: apiService, dbService: dbService).sync(),
        throwsA(isA<StateError>()),
      );

      expect(await dbService.isSyncV2Enabled(tenant), isFalse);
      expect(await dbService.getSyncV2Cursor(tenant), '1');
      for (final collection in ids.keys) {
        final row = (await database.query(collection)).single;
        final submitted = committedChanges![collection]!;
        expect(row['is_dirty'], 1);
        expect(row['pending_base_generation'], '1');
        expect(row['pending_generation'], submitted['generation']);
        expect(row['pending_branch_seq'], submitted['branch_seq']);
        expect(row['pending_operation_rank'], 0);
        expect(row['pending_writer_id'], submitted['writer_id']);
        expect(row['pending_change_id'], submitted['change_id']);
        expect(
          row['pending_payload_hash'],
          payloadHash(canonicalLocalPayloads[collection]!),
        );
      }
      expect((await database.query('clients')).single['name'],
          localPayloads['clients']!['name']);
      expect((await database.query('items')).single['name'],
          localPayloads['items']!['name']);
      expect((await database.query('rectangles')).single['length'],
          localPayloads['rectangles']!['length']);
      expect((await database.query('default_prices')).single['price'],
          localPayloads['default_prices']!['price']);

      await SyncService(apiService: apiService, dbService: dbService).sync();

      expect(round, 4);
      expect(apiService.v2Requests, hasLength(4));
      expect(await dbService.isSyncV2Enabled(tenant), isTrue);
      expect(await dbService.getSyncV2Cursor(tenant), '2');
      for (final collection in ids.keys) {
        final row = (await database.query(collection)).single;
        final submitted = committedChanges![collection]!;
        expect(row['is_dirty'], 0);
        expect(row['server_generation'], submitted['generation']);
        expect(row['server_branch_seq'], submitted['branch_seq']);
        expect(row['server_operation_rank'], 0);
        expect(row['server_writer_id'], submitted['writer_id']);
        expect(row['server_change_id'], submitted['change_id']);
        expect(
          row['server_payload_hash'],
          payloadHash(canonicalLocalPayloads[collection]!),
        );
        expect(row['pending_change_id'], isNull);
        expect(row['pending_payload_hash'], isNull);
      }
      expect((await database.query('clients')).single['email'], '');
    });
  }

  test(
      '426 bootstrap rejection preserves all four dirty values and exact rebased identities for retry',
      () async {
    const itemId = '40000000-0000-4000-8000-000000000061';
    const rectangleId = '40000000-0000-4000-8000-000000000062';
    const priceId = '40000000-0000-4000-8000-000000000063';
    const localWriter = '10000000-0000-4000-8000-000000000002';
    const localPayloads = <String, Map<String, dynamic>>{
      'clients': {
        'address': null,
        'discounted_price': null,
        'email': null,
        'latitude': null,
        'longitude': null,
        'name': 'Preserved client',
        'phone': null,
        'site_address': null,
      },
      'items': {
        'enabled': true,
        'name': 'Preserved item',
        'price': 11,
      },
      'rectangles': {'length': 4, 'width': 5},
      'default_prices': {'enabled': true, 'price': 13},
    };
    await database.insert('sync_state', {
      'key': 'lww_installation_writer_id',
      'value': localWriter,
    });
    final clientLocalId = await database.insert('clients', {
      'remote_id': remoteId,
      'franchisee_id': tenant,
      'name': localPayloads['clients']!['name'],
      'photos': '[]',
      'is_dirty': 1,
      'updated_at': now,
    });
    final itemLocalId = await database.insert('items', {
      'remote_id': itemId,
      'client_id': clientLocalId,
      'name': localPayloads['items']!['name'],
      'price': localPayloads['items']!['price'],
      'enabled': 1,
      'is_dirty': 1,
      'updated_at': now,
    });
    await database.insert('rectangles', {
      'remote_id': rectangleId,
      'item_id': itemLocalId,
      'length': localPayloads['rectangles']!['length'],
      'width': localPayloads['rectangles']!['width'],
      'image_data': null,
      'is_dirty': 1,
      'updated_at': now,
    });
    await database.insert('default_prices', {
      'remote_id': priceId,
      'franchisee_id': tenant,
      'price': localPayloads['default_prices']!['price'],
      'enabled': 1,
      'is_dirty': 1,
      'updated_at': now,
    });
    const ids = {
      'clients': remoteId,
      'items': itemId,
      'rectangles': rectangleId,
      'default_prices': priceId,
    };
    const baselinePayloads = <String, Map<String, dynamic>>{
      'clients': {
        'address': null,
        'discounted_price': null,
        'email': null,
        'latitude': null,
        'longitude': null,
        'name': 'Server client',
        'phone': null,
        'site_address': null,
      },
      'items': {'enabled': false, 'name': 'Server item', 'price': 21},
      'rectangles': {'length': 8, 'width': 9},
      'default_prices': {'enabled': false, 'price': 31},
    };
    String? parent(String collection) => switch (collection) {
          'items' => remoteId,
          'rectangles' => itemId,
          _ => null,
        };
    Map<String, dynamic> recordFor(
      String collection, {
      required String generation,
      required String change,
      required String cursor,
      required Map<String, dynamic> payload,
      String writer = serverWriter,
    }) =>
        lwwUpsertRecord(
          id: ids[collection]!,
          generation: generation,
          branch: 1,
          writer: writer,
          change: change,
          cursor: cursor,
          payload: payload,
          parentId: parent(collection),
          tenantOwned:
              collection == 'clients' || collection == 'default_prices',
          media: collection == 'clients'
              ? {'photos': <String>[]}
              : collection == 'rectangles'
                  ? {'image_data': null}
                  : null,
        );
    final baseline = {
      for (final collection in ids.keys)
        collection: recordFor(
          collection,
          generation: '1',
          change:
              '40000000-0000-4000-8000-00000000006${ids.keys.toList().indexOf(collection) + 4}',
          cursor: '1',
          payload: baselinePayloads[collection]!,
        ),
    };
    apiService.v1Handler = (_) async => throw const ApiException(
          'Upgrade required',
          statusCode: 426,
          code: 'sync_protocol_upgrade_required',
        );
    var round = 0;
    Map<String, String>? failedIds;
    apiService.v2Handler = (request) async {
      round += 1;
      if (round == 1) {
        for (final collection in ids.keys) {
          expect(request['changes'][collection], isEmpty);
        }
        return responseFor(
          request,
          cursor: '1',
          clients: [baseline['clients']!],
          items: [baseline['items']!],
          rectangles: [baseline['rectangles']!],
          defaultPrices: [baseline['default_prices']!],
        );
      }
      if (round == 2) {
        failedIds = {
          for (final collection in ids.keys)
            collection:
                request['changes'][collection].single['change_id'] as String,
        };
        List<Map<String, dynamic>> rejected(String collection) => [
              {
                'change_id': failedIds![collection],
                'remote_id': ids[collection],
                'status': 'rejected',
                'reason_code': 'invalid_payload',
              },
            ];
        return responseFor(
          request,
          cursor: '1',
          clientOutcomes: rejected('clients'),
          itemOutcomes: rejected('items'),
          rectangleOutcomes: rejected('rectangles'),
          defaultPriceOutcomes: rejected('default_prices'),
        );
      }
      if (round == 3) {
        expect(request['request_cursor'], '1');
        for (final collection in ids.keys) {
          expect(request['changes'][collection], isEmpty);
        }
        return responseFor(request, cursor: '1');
      }
      final submitted = {
        for (final collection in ids.keys)
          collection: Map<String, dynamic>.from(
            request['changes'][collection].single as Map,
          ),
      };
      for (final collection in ids.keys) {
        expect(submitted[collection]!['change_id'], failedIds![collection]);
        expect(submitted[collection]!['base_generation'], '1');
        expect(submitted[collection]!['generation'], '2');
        expect(submitted[collection]!['payload'], localPayloads[collection]);
      }
      final accepted = {
        for (final collection in ids.keys)
          collection: recordFor(
            collection,
            generation: '2',
            change: submitted[collection]!['change_id'],
            cursor: '2',
            payload: localPayloads[collection]!,
            writer: localWriter,
          ),
      };
      List<Map<String, dynamic>> applied(String collection) => [
            {
              'change_id': submitted[collection]!['change_id'],
              'remote_id': ids[collection],
              'status': 'applied',
              'reason_code': 'upsert_applied',
              'authoritative': accepted[collection],
            },
          ];
      return responseFor(
        request,
        cursor: '2',
        clientOutcomes: applied('clients'),
        itemOutcomes: applied('items'),
        rectangleOutcomes: applied('rectangles'),
        defaultPriceOutcomes: applied('default_prices'),
        clients: [accepted['clients']!],
        items: [accepted['items']!],
        rectangles: [accepted['rectangles']!],
        defaultPrices: [accepted['default_prices']!],
      );
    };

    await expectLater(
      SyncService(apiService: apiService, dbService: dbService).sync(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'sync_v2_bootstrap_not_accepted',
        ),
      ),
    );

    expect(await dbService.isSyncV2Enabled(tenant), isFalse);
    expect(await dbService.getSyncV2Cursor(tenant), '1');
    expect((await database.query('clients')).single['name'],
        localPayloads['clients']!['name']);
    expect((await database.query('items')).single['name'],
        localPayloads['items']!['name']);
    expect((await database.query('rectangles')).single['length'],
        localPayloads['rectangles']!['length']);
    expect((await database.query('default_prices')).single['price'],
        localPayloads['default_prices']!['price']);
    for (final table in ids.keys) {
      final row = (await database.query(table)).single;
      expect(row['is_dirty'], 1);
      expect(row['pending_change_id'], failedIds![table]);
      expect(row['pending_base_generation'], '1');
      expect(row['pending_generation'], '2');
    }

    await SyncService(apiService: apiService, dbService: dbService).sync();

    expect(await dbService.isSyncV2Enabled(tenant), isTrue);
    expect(await dbService.getSyncV2Cursor(tenant), '2');
    for (final table in ids.keys) {
      final row = (await database.query(table)).single;
      expect(row['is_dirty'], 0);
      expect(row['pending_change_id'], isNull);
    }
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
        payload['email'] = '';
        record['payload'] = payload;
        record['payload_hash'] =
            canonicalLwwMutablePayloadHash('clients', payload);
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
