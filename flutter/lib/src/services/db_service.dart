import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/default_price.dart';
import '../models/warranty.dart';
import '../models/warranty_deletion_tombstone.dart';
import '../models/proposal.dart';
import 'lww_protocol.dart';

class DbService {
  static final DbService _instance = DbService._internal();
  Database? _database;

  factory DbService({Database? database}) {
    if (database != null) {
      _instance._database = database;
    }
    return _instance;
  }

  DbService._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'damsure.db');
    return await openDatabase(
      path,
      version: 13,
      onCreate: _onCreate,
      onUpgrade: migrateSchema,
    );
  }

  static Future<void> migrateSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createDefaultPricesTable(db);
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE clients ADD COLUMN phone TEXT');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE clients ADD COLUMN discounted_price REAL');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE clients ADD COLUMN site_address TEXT');
    }
    if (oldVersion < 6) {
      await _createWarrantiesTable(db);
      await _createProposalsTable(db);
    }
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE rectangles ADD COLUMN image_data TEXT');
    }
    if (oldVersion < 8) {
      await db.execute(
        'ALTER TABLE default_prices ADD COLUMN franchisee_id TEXT',
      );
    }
    if (oldVersion < 9 && newVersion >= 9) {
      final warrantyColumns = await db.rawQuery(
        'PRAGMA table_info(warranties)',
      );
      if (!warrantyColumns.any(
        (column) => column['name'] == 'server_version',
      )) {
        await db.execute(
          'ALTER TABLE warranties ADD COLUMN server_version INTEGER NOT NULL DEFAULT 1',
        );
      }
      await _createWarrantyDeletionTombstonesTable(db);
      // Pre-APP-110 local soft deletes are not authoritative deletion requests.
      // Removing them prevents an old device from initiating deletion through
      // sync; the server's live row or permanent tombstone will converge later.
      await db.delete('warranties', where: 'deleted_at IS NOT NULL');
    }
    if (oldVersion < 10 && newVersion >= 10) {
      await _createSyncStateTable(db);
    }
    if (oldVersion < 11 && newVersion >= 11) {
      await _addLwwSyncColumns(db);
      await _createSyncStateTable(db);
    }
    if (oldVersion < 12 && newVersion >= 12) {
      await _createPendingClientPhotosTable(db);
      await _backfillPendingClientPhotos(db);
    }
    if (oldVersion < 13 && newVersion >= 13) {
      await _addPendingLwwSnapshots(db);
    }
  }

  Future _onCreate(Database db, int version) async {
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
        pending_payload_hash TEXT,
        FOREIGN KEY (client_id) REFERENCES clients (local_id) ON DELETE CASCADE
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
        pending_payload_hash TEXT,
        FOREIGN KEY (item_id) REFERENCES items (local_id) ON DELETE CASCADE
      )
    ''');

    await _createDefaultPricesTable(db);
    await _createWarrantiesTable(db);
    await _createWarrantyDeletionTombstonesTable(db);
    await _createSyncStateTable(db);
    await _createPendingClientPhotosTable(db);
    await _createProposalsTable(db);
  }

  static Future<void> _createDefaultPricesTable(Database db) async {
    await db.execute('''
      CREATE TABLE default_prices (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_id TEXT UNIQUE,
        franchisee_id TEXT NOT NULL,
        price REAL NOT NULL,
        enabled INTEGER DEFAULT 1,
        is_dirty INTEGER DEFAULT 1,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
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
      )
    ''');
  }

  static const _lwwTables = <String>[
    'clients',
    'items',
    'rectangles',
    'default_prices',
  ];

  static const _lwwColumnDefinitions = <String, String>{
    'server_generation': "TEXT NOT NULL DEFAULT '0'",
    'server_branch_seq': 'INTEGER NOT NULL DEFAULT 0',
    'server_operation_rank': 'INTEGER NOT NULL DEFAULT 0',
    'server_writer_id': 'TEXT',
    'server_change_id': 'TEXT',
    'server_payload_hash': 'TEXT',
    'server_cursor': "TEXT NOT NULL DEFAULT '0'",
    'pending_base_generation': 'TEXT',
    'pending_generation': 'TEXT',
    'pending_branch_seq': 'INTEGER',
    'pending_writer_id': 'TEXT',
    'pending_change_id': 'TEXT',
  };

  static const _pendingLwwSnapshotColumnDefinitions = <String, String>{
    'pending_operation_rank': 'INTEGER',
    'pending_payload_hash': 'TEXT',
  };

  static final _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _payloadHashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _canonicalDecimal = RegExp(r'^(0|[1-9][0-9]*)$');
  static final _canonicalClientPhoto = RegExp(
    r'^/api/photos/client/([^/]+)/'
    r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    r'\.(jpg|png|webp)$',
  );
  static final _maxLogicalGeneration = BigInt.parse('9223372036854775807');

  static int _operationRankForRow(Map<String, Object?> row) =>
      row['deleted_at'] == null ? 0 : 1;

  static Map<String, dynamic> _lwwMutablePayload(
    String collection,
    Map<String, Object?> row,
    int operationRank,
  ) {
    if (operationRank == 1) return <String, dynamic>{};
    switch (collection) {
      case 'clients':
        return {
          'name': row['name'],
          'address': row['address'],
          'site_address': row['site_address'],
          'email': row['email'],
          'phone': row['phone'],
          'latitude': row['latitude'],
          'longitude': row['longitude'],
          'discounted_price': row['discounted_price'],
        };
      case 'items':
        return {
          'name': row['name'],
          'price': double.parse(row['price'].toString()),
          'enabled': row['enabled'] == 1 || row['enabled'] == true,
        };
      case 'rectangles':
        return {
          'length': double.parse(row['length'].toString()),
          'width': double.parse(row['width'].toString()),
        };
      case 'default_prices':
        return {
          'price': double.parse(row['price'].toString()),
          'enabled': row['enabled'] == 1 || row['enabled'] == true,
        };
    }
    throw StateError('Unsupported LWW collection: $collection');
  }

  static String _currentLwwPayloadHash(
    String collection,
    Map<String, Object?> row,
    int operationRank,
  ) =>
      canonicalLwwPayloadHash(
        _lwwMutablePayload(collection, row, operationRank),
      );

  static BigInt? _validLogicalGeneration(
    Object? value, {
    required bool allowZero,
  }) {
    final encoded = value?.toString();
    if (encoded == null || !_canonicalDecimal.hasMatch(encoded)) return null;
    final parsed = BigInt.parse(encoded);
    if ((!allowZero && parsed == BigInt.zero) ||
        parsed > _maxLogicalGeneration) {
      return null;
    }
    return parsed;
  }

  static Future<void> _addLwwSyncColumns(Database db) async {
    await db.transaction((transaction) async {
      for (final table in _lwwTables) {
        final tableExists = (await transaction.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [table],
        ))
            .isNotEmpty;
        if (!tableExists) {
          throw StateError('APP-111 requires the existing $table table.');
        }
        final columns = await transaction.rawQuery('PRAGMA table_info($table)');
        final names = columns.map((column) => column['name']).toSet();
        for (final definition in _lwwColumnDefinitions.entries) {
          if (!names.contains(definition.key)) {
            await transaction.execute(
              'ALTER TABLE $table ADD COLUMN ${definition.key} ${definition.value}',
            );
          }
        }
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS ${table}_pending_lww '
          'ON $table (is_dirty, pending_change_id)',
        );
      }
    });
  }

  static Future<void> _addPendingLwwSnapshots(Database db) async {
    await db.transaction((transaction) async {
      for (final table in _lwwTables) {
        final tableExists = (await transaction.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [table],
        ))
            .isNotEmpty;
        if (!tableExists) {
          throw StateError('APP-111 requires the existing $table table.');
        }
        final columns = await transaction.rawQuery('PRAGMA table_info($table)');
        final names = columns.map((column) => column['name']).toSet();
        for (final definition in _pendingLwwSnapshotColumnDefinitions.entries) {
          if (!names.contains(definition.key)) {
            await transaction.execute(
              'ALTER TABLE $table ADD COLUMN '
              '${definition.key} ${definition.value}',
            );
          }
        }

        final rows = await transaction.query(table);
        for (final row in rows) {
          const pendingCore = [
            'pending_base_generation',
            'pending_generation',
            'pending_branch_seq',
            'pending_writer_id',
            'pending_change_id',
          ];
          final presentCore =
              pendingCore.where((column) => row[column] != null).length;
          final snapshotRank = row['pending_operation_rank'];
          final snapshotHash = row['pending_payload_hash']?.toString();
          if (presentCore == 0) {
            if (snapshotRank != null || snapshotHash != null) {
              throw StateError(
                'APP-111 found orphaned pending state in $table.',
              );
            }
            continue;
          }
          final pendingBase = _validLogicalGeneration(
            row['pending_base_generation'],
            allowZero: true,
          );
          final pendingGeneration = _validLogicalGeneration(
            row['pending_generation'],
            allowZero: false,
          );
          if (presentCore != pendingCore.length ||
              row['is_dirty'] != 1 ||
              pendingBase == null ||
              pendingGeneration == null ||
              pendingGeneration <= pendingBase ||
              row['pending_branch_seq'] is! int ||
              (row['pending_branch_seq'] as int) < 1 ||
              (row['pending_branch_seq'] as int) > 1000000 ||
              !_uuidV4.hasMatch(row['pending_writer_id'].toString()) ||
              !_uuidV4.hasMatch(row['pending_change_id'].toString())) {
            throw StateError(
              'APP-111 found inconsistent pending state in $table.',
            );
          }
          final expectedRank = _operationRankForRow(row);
          final expectedHash = _currentLwwPayloadHash(table, row, expectedRank);
          if (snapshotRank == null && snapshotHash == null) {
            await transaction.update(
              table,
              {
                'pending_operation_rank': expectedRank,
                'pending_payload_hash': expectedHash,
              },
              where: 'local_id = ?',
              whereArgs: [row['local_id']],
            );
            continue;
          }
          if (snapshotRank != expectedRank ||
              snapshotHash == null ||
              !_payloadHashPattern.hasMatch(snapshotHash) ||
              snapshotHash != expectedHash) {
            throw StateError(
              'APP-111 found a changed pending payload in $table.',
            );
          }
        }
      }
    });
  }

  static Future<void> _createWarrantiesTable(Database db) async {
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
        deleted_at TEXT,
        FOREIGN KEY (client_id) REFERENCES clients (local_id) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _createWarrantyDeletionTombstonesTable(
    Database db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS warranty_deletion_tombstones (
        warranty_id TEXT NOT NULL,
        franchisee_id TEXT NOT NULL,
        deletion_sequence TEXT NOT NULL,
        deleted_at TEXT NOT NULL,
        PRIMARY KEY (franchisee_id, warranty_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS warranty_deletion_tombstones_tenant_cursor
      ON warranty_deletion_tombstones (franchisee_id, deletion_sequence)
    ''');
  }

  static Future<void> _createSyncStateTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createPendingClientPhotosTable(
    DatabaseExecutor db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_client_photos (
        franchisee_id TEXT NOT NULL,
        client_remote_id TEXT NOT NULL,
        local_path TEXT NOT NULL,
        PRIMARY KEY (franchisee_id, client_remote_id, local_path)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS pending_client_photos_client
      ON pending_client_photos (franchisee_id, client_remote_id)
    ''');
  }

  static bool _isCanonicalClientPhotoPath(
    String path, {
    String? remoteId,
  }) {
    final match = _canonicalClientPhoto.firstMatch(path);
    return match != null && (remoteId == null || match.group(1) == remoteId);
  }

  static List<String> _decodeClientPhotos(Object? value) {
    final decoded = jsonDecode(value?.toString() ?? '[]');
    if (decoded is! List || decoded.any((photo) => photo is! String)) {
      throw const FormatException('Local client photo metadata is invalid.');
    }
    return decoded.cast<String>();
  }

  static Future<void> _backfillPendingClientPhotos(
    DatabaseExecutor db,
  ) async {
    final rows = await db.query(
      'clients',
      columns: ['remote_id', 'franchisee_id', 'photos', 'deleted_at'],
    );
    for (final row in rows) {
      final remoteId = row['remote_id']?.toString();
      final franchiseeId = row['franchisee_id']?.toString();
      final photos = _decodeClientPhotos(row['photos']);
      if (row['deleted_at'] != null ||
          remoteId == null ||
          remoteId.isEmpty ||
          franchiseeId == null ||
          franchiseeId.isEmpty) {
        continue;
      }
      for (final path in photos.where(
        (photo) => !_isCanonicalClientPhotoPath(photo, remoteId: remoteId),
      )) {
        await db.insert(
          'pending_client_photos',
          {
            'franchisee_id': franchiseeId,
            'client_remote_id': remoteId,
            'local_path': path,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  static Future<void> _createProposalsTable(Database db) async {
    await db.execute('''
      CREATE TABLE proposals (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_id TEXT UNIQUE,
        client_id INTEGER,
        pdf_url TEXT,
        is_dirty INTEGER DEFAULT 1,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        FOREIGN KEY (client_id) REFERENCES clients (local_id) ON DELETE CASCADE
      )
    ''');
  }

  Future<bool> _supportsLww(DatabaseExecutor executor, String table) async {
    final columns = await executor.rawQuery('PRAGMA table_info($table)');
    return columns.any((column) => column['name'] == 'pending_change_id');
  }

  Future<String> _installationWriterId(DatabaseExecutor executor) async {
    const key = 'lww_installation_writer_id';
    final rows = await executor.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final writerId = const Uuid().v4();
    await executor.insert(
        'sync_state',
        {
          'key': key,
          'value': writerId,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    final stored = await executor.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return stored.first['value'] as String;
  }

  Future<void> _markLocalLwwMutation(
    DatabaseExecutor executor,
    String table,
    int localId,
  ) async {
    if (!await _supportsLww(executor, table)) return;
    final rows = await executor.query(
      table,
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final hasPending = row['pending_generation'] != null;
    final base = BigInt.parse(
      (hasPending
              ? row['pending_base_generation']
              : row['server_generation'] ?? '0')
          .toString(),
    );
    final generation = hasPending
        ? BigInt.parse(row['pending_generation'].toString())
        : base + BigInt.one;
    if (generation > BigInt.parse('9223372036854775807')) {
      throw StateError('The local logical generation is exhausted.');
    }
    final branch =
        hasPending ? (row['pending_branch_seq'] as int? ?? 0) + 1 : 1;
    if (branch > 1000000) {
      throw StateError('The local logical branch sequence is exhausted.');
    }
    final operationRank = _operationRankForRow(row);
    final payloadHash = _currentLwwPayloadHash(table, row, operationRank);
    await executor.update(
      table,
      {
        'is_dirty': 1,
        'pending_base_generation': base.toString(),
        'pending_generation': generation.toString(),
        'pending_branch_seq': branch,
        'pending_writer_id': await _installationWriterId(executor),
        'pending_change_id': const Uuid().v4(),
        'pending_operation_rank': operationRank,
        'pending_payload_hash': payloadHash,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  static const _clearPendingLww = <String, Object?>{
    'pending_base_generation': null,
    'pending_generation': null,
    'pending_branch_seq': null,
    'pending_writer_id': null,
    'pending_change_id': null,
    'pending_operation_rank': null,
    'pending_payload_hash': null,
  };

  Future<bool> _supportsPendingClientPhotos(
    DatabaseExecutor executor,
  ) async {
    final rows = await executor.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name = 'pending_client_photos'",
    );
    return rows.isNotEmpty;
  }

  Future<void> _syncPendingClientPhotos(
    DatabaseExecutor executor,
    int localId,
  ) async {
    if (!await _supportsPendingClientPhotos(executor)) return;
    final rows = await executor.query(
      'clients',
      columns: [
        'remote_id',
        'franchisee_id',
        'photos',
        'deleted_at',
      ],
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.single;
    final remoteId = row['remote_id']?.toString();
    final franchiseeId = row['franchisee_id']?.toString();
    if (remoteId == null ||
        remoteId.isEmpty ||
        franchiseeId == null ||
        franchiseeId.isEmpty) {
      return;
    }
    final pendingRows = await executor.query(
      'pending_client_photos',
      columns: ['local_path'],
      where: 'franchisee_id = ? AND client_remote_id = ?',
      whereArgs: [franchiseeId, remoteId],
    );
    final desired = row['deleted_at'] == null
        ? _decodeClientPhotos(row['photos'])
            .where(
              (photo) =>
                  !_isCanonicalClientPhotoPath(photo, remoteId: remoteId),
            )
            .toSet()
        : const <String>{};
    for (final pending in pendingRows) {
      final path = pending['local_path'] as String;
      if (!desired.contains(path)) {
        await executor.delete(
          'pending_client_photos',
          where:
              'franchisee_id = ? AND client_remote_id = ? AND local_path = ?',
          whereArgs: [franchiseeId, remoteId, path],
        );
      }
    }
    for (final path in desired) {
      await executor.insert(
        'pending_client_photos',
        {
          'franchisee_id': franchiseeId,
          'client_remote_id': remoteId,
          'local_path': path,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  // Client CRUD
  Future<int> insertClient(Client client) async {
    final db = await database;
    return db.transaction((transaction) async {
      final id = await transaction.insert('clients', client.toMap());
      await _syncPendingClientPhotos(transaction, id);
      if (client.isDirty) {
        await _markLocalLwwMutation(transaction, 'clients', id);
      }
      return id;
    });
  }

  Future<List<Client>> getClients() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'clients',
      where: 'deleted_at IS NULL',
    );

    List<Client> clients = [];
    for (var map in maps) {
      final items = await getItemsByClientId(map['local_id']);
      clients.add(Client.fromMap(map, items: items));
    }
    return clients;
  }

  Future<Client?> getClientByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'clients',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    );
    if (maps.isEmpty) return null;
    final items = await getItemsByClientId(maps.first['local_id']);
    return Client.fromMap(maps.first, items: items);
  }

  Future<int> updateClient(Client client) async {
    final db = await database;
    return db.transaction((transaction) async {
      final changed = await transaction.update(
        'clients',
        client.toMap(),
        where: 'local_id = ?',
        whereArgs: [client.localId],
      );
      if (changed == 1 && client.localId != null) {
        await _syncPendingClientPhotos(transaction, client.localId!);
      }
      if (changed == 1 && client.isDirty && client.localId != null) {
        await _markLocalLwwMutation(transaction, 'clients', client.localId!);
      }
      return changed;
    });
  }

  Future<List<Map<String, String>>> getPendingClientPhotos(
    String franchiseeId,
  ) async {
    final db = await database;
    if (!await _supportsPendingClientPhotos(db)) return const [];
    final rows = await db.rawQuery(
      '''
      SELECT p.client_remote_id, p.local_path
      FROM pending_client_photos p
      JOIN clients c
        ON c.remote_id = p.client_remote_id
       AND c.franchisee_id = p.franchisee_id
      WHERE p.franchisee_id = ?
        AND c.deleted_at IS NULL
      ORDER BY c.local_id, p.rowid
      ''',
      [franchiseeId],
    );
    return [
      for (final row in rows)
        {
          'client_remote_id': row['client_remote_id'] as String,
          'local_path': row['local_path'] as String,
        },
    ];
  }

  Future<bool> acknowledgeClientPhotoUpload({
    required String franchiseeId,
    required String remoteId,
    required String localPath,
    required String canonicalPath,
  }) async {
    if (!_isCanonicalClientPhotoPath(
      canonicalPath,
      remoteId: remoteId,
    )) {
      throw const FormatException(
        'Photo acknowledgement does not belong to the requested client.',
      );
    }
    final db = await database;
    return db.transaction((transaction) async {
      if (!await _supportsPendingClientPhotos(transaction)) return false;
      final pending = await transaction.query(
        'pending_client_photos',
        columns: ['local_path'],
        where: 'franchisee_id = ? AND client_remote_id = ? AND local_path = ?',
        whereArgs: [franchiseeId, remoteId, localPath],
        limit: 1,
      );
      if (pending.isEmpty) return false;
      final rows = await transaction.query(
        'clients',
        columns: ['local_id', 'photos', 'deleted_at'],
        where: 'remote_id = ? AND franchisee_id = ?',
        whereArgs: [remoteId, franchiseeId],
        limit: 1,
      );
      if (rows.isEmpty) {
        await transaction.delete(
          'pending_client_photos',
          where:
              'franchisee_id = ? AND client_remote_id = ? AND local_path = ?',
          whereArgs: [franchiseeId, remoteId, localPath],
        );
        return false;
      }
      final currentPhotos = _decodeClientPhotos(rows.first['photos']);
      if (rows.first['deleted_at'] != null ||
          !currentPhotos.contains(localPath)) {
        await transaction.delete(
          'pending_client_photos',
          where:
              'franchisee_id = ? AND client_remote_id = ? AND local_path = ?',
          whereArgs: [franchiseeId, remoteId, localPath],
        );
        return false;
      }
      final nextPhotos = currentPhotos
          .map((photo) => photo == localPath ? canonicalPath : photo)
          .toSet()
          .toList();
      final removed = await transaction.delete(
        'pending_client_photos',
        where: 'franchisee_id = ? AND client_remote_id = ? AND local_path = ?',
        whereArgs: [franchiseeId, remoteId, localPath],
      );
      if (removed != 1) return false;
      await transaction.update(
        'clients',
        {'photos': jsonEncode(nextPhotos)},
        where: 'local_id = ?',
        whereArgs: [rows.first['local_id']],
      );
      return true;
    });
  }

  Future<int> softDeleteClient(int localId) async {
    final db = await database;
    return db.transaction((transaction) async {
      final rows = await transaction.query(
        'clients',
        columns: ['remote_id', 'franchisee_id'],
        where: 'local_id = ?',
        whereArgs: [localId],
        limit: 1,
      );
      final changed = await transaction.update(
        'clients',
        {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      if (changed == 1) {
        if (rows.isNotEmpty &&
            await _supportsPendingClientPhotos(transaction)) {
          await transaction.delete(
            'pending_client_photos',
            where: 'franchisee_id = ? AND client_remote_id = ?',
            whereArgs: [
              rows.single['franchisee_id'],
              rows.single['remote_id'],
            ],
          );
        }
        await _markLocalLwwMutation(transaction, 'clients', localId);
      }
      return changed;
    });
  }

  // Item CRUD
  Future<int> insertItem(Item item) async {
    final db = await database;
    return db.transaction((transaction) async {
      final id = await transaction.insert('items', item.toMap());
      if (item.isDirty) await _markLocalLwwMutation(transaction, 'items', id);
      return id;
    });
  }

  Future<List<Item>> getItemsByClientId(int clientId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'items',
      where: 'client_id = ? AND deleted_at IS NULL',
      whereArgs: [clientId],
    );

    List<Item> items = [];
    for (var map in maps) {
      final rectangles = await getRectanglesByItemId(map['local_id']);
      items.add(Item.fromMap(map, rectangles: rectangles));
    }
    return items;
  }

  Future<Item?> getItemByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'items',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    );
    if (maps.isEmpty) return null;
    final rectangles = await getRectanglesByItemId(maps.first['local_id']);
    return Item.fromMap(maps.first, rectangles: rectangles);
  }

  Future<Item?> getItemByLocalId(int localId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'items',
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    if (maps.isEmpty) return null;
    final rectangles = await getRectanglesByItemId(localId);
    return Item.fromMap(maps.first, rectangles: rectangles);
  }

  Future<int> updateItem(Item item) async {
    final db = await database;
    return db.transaction((transaction) async {
      final changed = await transaction.update(
        'items',
        item.toMap(),
        where: 'local_id = ?',
        whereArgs: [item.localId],
      );
      if (changed == 1 && item.isDirty && item.localId != null) {
        await _markLocalLwwMutation(transaction, 'items', item.localId!);
      }
      return changed;
    });
  }

  Future<int> softDeleteItem(int localId) async {
    final db = await database;
    return db.transaction((transaction) async {
      final changed = await transaction.update(
        'items',
        {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      if (changed == 1) {
        await _markLocalLwwMutation(transaction, 'items', localId);
      }
      return changed;
    });
  }

  // Rectangle CRUD
  Future<int> insertRectangle(Rectangle rectangle) async {
    final db = await database;
    return db.transaction((transaction) async {
      final id = await transaction.insert('rectangles', rectangle.toMap());
      if (rectangle.isDirty) {
        await _markLocalLwwMutation(transaction, 'rectangles', id);
      }
      return id;
    });
  }

  Future<List<Rectangle>> getRectanglesByItemId(int itemId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'rectangles',
      where: 'item_id = ? AND deleted_at IS NULL',
      whereArgs: [itemId],
    );
    return List.generate(maps.length, (i) => Rectangle.fromMap(maps[i]));
  }

  Future<Rectangle?> getRectangleByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'rectangles',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    );
    if (maps.isEmpty) return null;
    return Rectangle.fromMap(maps.first);
  }

  Future<int> updateRectangle(Rectangle rectangle) async {
    final db = await database;
    return db.transaction((transaction) async {
      final changed = await transaction.update(
        'rectangles',
        rectangle.toMap(),
        where: 'local_id = ?',
        whereArgs: [rectangle.localId],
      );
      if (changed == 1 && rectangle.isDirty && rectangle.localId != null) {
        await _markLocalLwwMutation(
          transaction,
          'rectangles',
          rectangle.localId!,
        );
      }
      return changed;
    });
  }

  Future<int> softDeleteRectangle(int localId) async {
    final db = await database;
    return db.transaction((transaction) async {
      final changed = await transaction.update(
        'rectangles',
        {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
        where: 'local_id = ? AND deleted_at IS NULL',
        whereArgs: [localId],
      );
      if (changed == 1) {
        await _markLocalLwwMutation(transaction, 'rectangles', localId);
      }
      return changed;
    });
  }

  // DefaultPrice CRUD
  Future<int> claimLegacyDefaultPrices(String franchiseeId) async {
    final normalizedFranchiseeId = franchiseeId.trim();
    if (normalizedFranchiseeId.isEmpty) {
      throw ArgumentError('A franchisee is required to claim legacy prices');
    }
    final db = await database;
    return db.update(
        'default_prices',
        {
          'franchisee_id': normalizedFranchiseeId,
          'is_dirty': 1,
        },
        where: "franchisee_id IS NULL OR TRIM(franchisee_id) = ''");
  }

  Future<void> rebasePendingLwwChangesForBootstrap(
    String franchiseeId,
  ) async {
    final db = await database;
    await db.transaction((transaction) async {
      final tableQueries = <String, String>{
        'clients': '''
          SELECT c.*
          FROM clients c
          WHERE c.franchisee_id = ?
            AND c.is_dirty = 1
        ''',
        'items': '''
          SELECT i.*
          FROM items i
          JOIN clients c ON c.local_id = i.client_id
          WHERE c.franchisee_id = ?
            AND i.is_dirty = 1
        ''',
        'rectangles': '''
          SELECT r.*
          FROM rectangles r
          JOIN items i ON i.local_id = r.item_id
          JOIN clients c ON c.local_id = i.client_id
          WHERE c.franchisee_id = ?
            AND r.is_dirty = 1
        ''',
        'default_prices': '''
          SELECT d.*
          FROM default_prices d
          WHERE d.franchisee_id = ?
            AND d.is_dirty = 1
        ''',
      };
      final writerId = await _installationWriterId(transaction);
      for (final entry in tableQueries.entries) {
        final rows = await transaction.rawQuery(entry.value, [franchiseeId]);
        for (final row in rows) {
          final serverGeneration = _validLogicalGeneration(
            row['server_generation'],
            allowZero: true,
          );
          if (serverGeneration == null) {
            throw StateError(
              'The authoritative logical generation cannot be rebased.',
            );
          }
          final currentRank = _operationRankForRow(row);
          final currentHash =
              _currentLwwPayloadHash(entry.key, row, currentRank);
          final pendingRank = row['pending_operation_rank'] as int?;
          final pendingHash = row['pending_payload_hash']?.toString();
          final pendingWriter = row['pending_writer_id']?.toString();
          final pendingChange = row['pending_change_id']?.toString();
          final pendingSnapshotMatchesCurrent = pendingRank == currentRank &&
              pendingHash == currentHash &&
              pendingHash != null &&
              _payloadHashPattern.hasMatch(pendingHash);
          final pendingGeneration = _validLogicalGeneration(
            row['pending_generation'],
            allowZero: false,
          );
          final pendingBranch = row['pending_branch_seq'] as int?;
          final pendingIdentityIsValid = pendingWriter != null &&
              pendingChange != null &&
              _uuidV4.hasMatch(pendingWriter) &&
              _uuidV4.hasMatch(pendingChange);

          final exactCommitted = pendingGeneration == serverGeneration &&
              pendingBranch == row['server_branch_seq'] &&
              pendingRank == row['server_operation_rank'] &&
              pendingWriter == row['server_writer_id'] &&
              pendingChange == row['server_change_id'] &&
              pendingHash == row['server_payload_hash'] &&
              pendingIdentityIsValid &&
              pendingSnapshotMatchesCurrent;
          if (exactCommitted) {
            await transaction.update(
              entry.key,
              {
                'is_dirty': 0,
                ..._clearPendingLww,
              },
              where: '''
                local_id = ?
                AND is_dirty = 1
                AND pending_generation = ?
                AND pending_branch_seq = ?
                AND pending_operation_rank = ?
                AND pending_writer_id = ?
                AND pending_change_id = ?
                AND pending_payload_hash = ?
              ''',
              whereArgs: [
                row['local_id'],
                pendingGeneration.toString(),
                pendingBranch,
                pendingRank,
                pendingWriter,
                pendingChange,
                pendingHash,
              ],
            );
            continue;
          }

          if (serverGeneration >= _maxLogicalGeneration) {
            throw StateError(
              'The authoritative logical generation cannot be rebased.',
            );
          }
          final rebasedGeneration = serverGeneration + BigInt.one;
          final pendingBase = _validLogicalGeneration(
            row['pending_base_generation'],
            allowZero: true,
          );
          final alreadyRebased = pendingBase == serverGeneration &&
              pendingGeneration == rebasedGeneration &&
              pendingBranch != null &&
              pendingBranch >= 1 &&
              pendingBranch <= 1000000 &&
              pendingIdentityIsValid &&
              pendingSnapshotMatchesCurrent;
          if (alreadyRebased) continue;
          await transaction.update(
            entry.key,
            {
              'is_dirty': 1,
              'pending_base_generation': serverGeneration.toString(),
              'pending_generation': rebasedGeneration.toString(),
              'pending_branch_seq': 1,
              'pending_writer_id': writerId,
              'pending_change_id': const Uuid().v4(),
              'pending_operation_rank': currentRank,
              'pending_payload_hash': currentHash,
            },
            where: 'local_id = ?',
            whereArgs: [row['local_id']],
          );
        }
      }
    });
  }

  Future<int> insertDefaultPrice(
    DefaultPrice defaultPrice, {
    required String franchiseeId,
  }) async {
    if (franchiseeId.isEmpty || defaultPrice.franchiseeId != franchiseeId) {
      throw ArgumentError(
        'Default prices must belong to the active franchisee',
      );
    }
    final db = await database;
    return db.transaction((transaction) async {
      final id = await transaction.insert(
        'default_prices',
        defaultPrice.toMap(),
      );
      if (defaultPrice.isDirty) {
        await _markLocalLwwMutation(transaction, 'default_prices', id);
      }
      return id;
    });
  }

  Future<List<DefaultPrice>> getDefaultPrices(String franchiseeId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'default_prices',
      where: 'franchisee_id = ? AND deleted_at IS NULL',
      whereArgs: [franchiseeId],
      orderBy: 'updated_at ASC',
    );
    return List.generate(maps.length, (i) => DefaultPrice.fromMap(maps[i]));
  }

  Future<int> updateDefaultPrice(
    DefaultPrice defaultPrice, {
    required String franchiseeId,
  }) async {
    if (franchiseeId.isEmpty || defaultPrice.franchiseeId != franchiseeId) {
      throw ArgumentError(
        'Default prices must belong to the active franchisee',
      );
    }
    final db = await database;
    return db.transaction((transaction) async {
      final changed = await transaction.update(
        'default_prices',
        defaultPrice.toMap(),
        where: 'local_id = ? AND franchisee_id = ?',
        whereArgs: [defaultPrice.localId, franchiseeId],
      );
      if (changed == 1 &&
          defaultPrice.isDirty &&
          defaultPrice.localId != null) {
        await _markLocalLwwMutation(
          transaction,
          'default_prices',
          defaultPrice.localId!,
        );
      }
      return changed;
    });
  }

  Future<int> deleteDefaultPrice(
    int localId, {
    required String franchiseeId,
  }) async {
    final db = await database;
    return db.transaction((transaction) async {
      final changed = await transaction.update(
        'default_prices',
        {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
        where: 'local_id = ? AND franchisee_id = ?',
        whereArgs: [localId, franchiseeId],
      );
      if (changed == 1) {
        await _markLocalLwwMutation(transaction, 'default_prices', localId);
      }
      return changed;
    });
  }

  // Warranty CRUD
  Future<int> insertWarranty(Warranty warranty) async {
    final db = await database;
    return await db.insert('warranties', warranty.toMap());
  }

  Future<List<Warranty>> getWarrantiesByClientId(int clientId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'warranties',
      where: 'client_id = ? AND deleted_at IS NULL',
      whereArgs: [clientId],
    );
    return List.generate(maps.length, (i) => Warranty.fromMap(maps[i]));
  }

  Future<Warranty?> getWarrantyByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'warranties',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    );
    if (maps.isEmpty) return null;
    return Warranty.fromMap(maps.first);
  }

  Future<int> updateWarranty(Warranty warranty) async {
    final db = await database;
    return await db.update(
      'warranties',
      warranty.toMap(),
      where: 'local_id = ?',
      whereArgs: [warranty.localId],
    );
  }

  Future<int> hardDeleteWarranty(int localId) async {
    final db = await database;
    return db.delete('warranties', where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<int> hardDeleteWarrantyByRemoteId(String remoteId) async {
    final db = await database;
    return db.delete(
      'warranties',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    );
  }

  Future<void> replaceWarrantyFromServer(Warranty warranty) async {
    final db = await database;
    await db.transaction((transaction) async {
      await transaction.delete(
        'warranties',
        where: 'client_id = ? AND remote_id <> ?',
        whereArgs: [warranty.clientId, warranty.remoteId],
      );
      final existing = await transaction.query(
        'warranties',
        columns: ['local_id'],
        where: 'remote_id = ?',
        whereArgs: [warranty.remoteId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await transaction.insert('warranties', warranty.toMap());
      } else {
        await transaction.update(
          'warranties',
          warranty.copyWith(localId: existing.first['local_id'] as int).toMap(),
          where: 'remote_id = ?',
          whereArgs: [warranty.remoteId],
        );
      }
    });
  }

  Future<int> applyWarrantyFromServerIfUnchanged(
    Warranty warranty, {
    required String submittedUpdatedAt,
  }) async {
    final db = await database;
    return db.update(
      'warranties',
      warranty.toMap(),
      where: 'remote_id = ? AND updated_at = ? AND is_dirty = 1',
      whereArgs: [warranty.remoteId, submittedUpdatedAt],
    );
  }

  Future<void> applyWarrantyTombstone(
    WarrantyDeletionTombstone tombstone,
  ) async {
    final db = await database;
    await db.transaction((transaction) async {
      await transaction.insert(
        'warranty_deletion_tombstones',
        tombstone.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await transaction.delete(
        'warranties',
        where: 'remote_id = ?',
        whereArgs: [tombstone.warrantyId],
      );
    });
  }

  String _warrantyTombstoneCursorKey(String franchiseeId) =>
      'warranty_tombstone_cursor:$franchiseeId';

  Future<String> getWarrantyTombstoneCursor(String franchiseeId) async {
    final db = await database;
    final rows = await db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_warrantyTombstoneCursorKey(franchiseeId)],
      limit: 1,
    );
    return rows.isEmpty ? '0' : rows.first['value'] as String;
  }

  Future<void> applyWarrantyTombstonesAndCursor(
    List<WarrantyDeletionTombstone> tombstones, {
    required String franchiseeId,
    required String cursor,
  }) async {
    final db = await database;
    await db.transaction((transaction) async {
      for (final tombstone in tombstones) {
        if (tombstone.franchiseeId != franchiseeId) {
          throw ArgumentError('A tombstone cannot cross the active franchisee');
        }
        await transaction.insert(
          'warranty_deletion_tombstones',
          tombstone.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await transaction.delete(
          'warranties',
          where: 'remote_id = ?',
          whereArgs: [tombstone.warrantyId],
        );
      }
      await transaction.insert(
          'sync_state',
          {
            'key': _warrantyTombstoneCursorKey(franchiseeId),
            'value': cursor,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<bool> hasWarrantyTombstone(
    String warrantyId, {
    required String franchiseeId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'warranty_deletion_tombstones',
      columns: ['warranty_id'],
      where: 'franchisee_id = ? AND warranty_id = ?',
      whereArgs: [franchiseeId, warrantyId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // Proposal CRUD
  Future<int> insertProposal(Proposal proposal) async {
    final db = await database;
    return await db.insert('proposals', proposal.toMap());
  }

  Future<List<Proposal>> getProposalsByClientId(int clientId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'proposals',
      where: 'client_id = ? AND deleted_at IS NULL',
      whereArgs: [clientId],
    );
    return List.generate(maps.length, (i) => Proposal.fromMap(maps[i]));
  }

  Future<Proposal?> getProposalByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'proposals',
      where: 'remote_id = ?',
      whereArgs: [remoteId],
    );
    if (maps.isEmpty) return null;
    return Proposal.fromMap(maps.first);
  }

  Future<int> updateProposal(Proposal proposal) async {
    final db = await database;
    return await db.update(
      'proposals',
      proposal.toMap(),
      where: 'local_id = ?',
      whereArgs: [proposal.localId],
    );
  }

  Future<int> softDeleteProposal(int localId) async {
    final db = await database;
    return await db.update(
      'proposals',
      {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // Sync helpers
  String _syncV2CursorKey(String franchiseeId) =>
      'sync_v2_cursor:$franchiseeId';
  String _syncV2EnabledKey(String franchiseeId) =>
      'sync_v2_enabled:$franchiseeId';

  Future<bool> isSyncV2Enabled(String franchiseeId) async {
    final db = await database;
    if (!await _supportsLww(db, 'clients')) return false;
    final rows = await db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_syncV2EnabledKey(franchiseeId)],
      limit: 1,
    );
    return rows.isNotEmpty && rows.first['value'] == '1';
  }

  Future<bool> supportsSyncV2() async {
    final db = await database;
    return _supportsLww(db, 'clients');
  }

  Future<String> getSyncV2Cursor(String franchiseeId) async {
    final db = await database;
    final rows = await db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_syncV2CursorKey(franchiseeId)],
      limit: 1,
    );
    return rows.isEmpty ? '0' : rows.first['value'] as String;
  }

  Map<String, dynamic> _pendingEnvelopeRecord(
    String collection,
    Map<String, Object?> row,
  ) {
    final pendingRank = row['pending_operation_rank'];
    final currentRank = _operationRankForRow(row);
    final pendingHash = row['pending_payload_hash']?.toString();
    final payload = _lwwMutablePayload(collection, row, currentRank);
    final currentHash = canonicalLwwPayloadHash(payload);
    if ((pendingRank != 0 && pendingRank != 1) ||
        pendingRank != currentRank ||
        pendingHash == null ||
        !_payloadHashPattern.hasMatch(pendingHash) ||
        pendingHash != currentHash) {
      throw StateError(
        'The pending $collection payload changed without a logical mutation.',
      );
    }
    final operation = pendingRank == 1 ? 'delete' : 'upsert';
    return {
      'remote_id': row['remote_id'],
      'operation': operation,
      'base_generation': row['pending_base_generation'].toString(),
      'generation': row['pending_generation'].toString(),
      'branch_seq': row['pending_branch_seq'],
      'writer_id': row['pending_writer_id'],
      'change_id': row['pending_change_id'],
      if (row['parent_remote_id'] != null) 'parent_id': row['parent_remote_id'],
      'payload': payload,
      if (collection == 'rectangles' && operation == 'upsert')
        'media': {'image_data': row['image_data']},
      'device_timestamp': row['updated_at'],
    };
  }

  Future<Map<String, List<Map<String, dynamic>>>> getPendingLwwChanges(
    String franchiseeId,
  ) async {
    final db = await database;
    if (!await _supportsLww(db, 'clients')) {
      return {for (final table in _lwwTables) table: <Map<String, dynamic>>[]};
    }
    final clients = await db.rawQuery(
      '''
      SELECT c.*
      FROM clients c
      WHERE c.franchisee_id = ?
        AND c.is_dirty = 1
        AND c.pending_change_id IS NOT NULL
      ORDER BY c.local_id
      ''',
      [franchiseeId],
    );
    final items = await db.rawQuery(
      '''
      SELECT i.*, c.remote_id AS parent_remote_id
      FROM items i
      JOIN clients c ON c.local_id = i.client_id
      WHERE c.franchisee_id = ?
        AND i.is_dirty = 1
        AND i.pending_change_id IS NOT NULL
      ORDER BY i.local_id
      ''',
      [franchiseeId],
    );
    final rectangles = await db.rawQuery(
      '''
      SELECT r.*, i.remote_id AS parent_remote_id
      FROM rectangles r
      JOIN items i ON i.local_id = r.item_id
      JOIN clients c ON c.local_id = i.client_id
      WHERE c.franchisee_id = ?
        AND r.is_dirty = 1
        AND r.pending_change_id IS NOT NULL
      ORDER BY r.local_id
      ''',
      [franchiseeId],
    );
    final defaultPrices = await db.rawQuery(
      '''
      SELECT d.*
      FROM default_prices d
      WHERE d.franchisee_id = ?
        AND d.is_dirty = 1
        AND d.pending_change_id IS NOT NULL
      ORDER BY d.local_id
      ''',
      [franchiseeId],
    );
    return {
      'clients':
          clients.map((row) => _pendingEnvelopeRecord('clients', row)).toList(),
      'items':
          items.map((row) => _pendingEnvelopeRecord('items', row)).toList(),
      'rectangles': rectangles
          .map((row) => _pendingEnvelopeRecord('rectangles', row))
          .toList(),
      'default_prices': defaultPrices
          .map((row) => _pendingEnvelopeRecord('default_prices', row))
          .toList(),
    };
  }

  Map<String, Object?> _serverMetadata(Map<String, dynamic> record) => {
        'server_generation': record['generation'].toString(),
        'server_branch_seq': record['branch_seq'],
        'server_operation_rank': record['operation'] == 'delete' ? 1 : 0,
        'server_writer_id': record['writer_id'],
        'server_change_id': record['change_id'],
        'server_payload_hash': record['payload_hash'],
        'server_cursor': record['row_cursor'].toString(),
      };

  Future<Map<String, Object?>?> _existingRemoteRow(
    DatabaseExecutor executor,
    String table,
    String remoteId,
  ) async {
    final rows = await executor.query(
      table,
      where: 'remote_id = ?',
      whereArgs: [remoteId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> _ownedParentLocalId(
    DatabaseExecutor executor,
    String collection,
    String parentRemoteId,
    String franchiseeId,
  ) async {
    if (collection == 'items') {
      final parents = await executor.query(
        'clients',
        columns: ['local_id'],
        where: 'remote_id = ? AND franchisee_id = ? AND deleted_at IS NULL',
        whereArgs: [parentRemoteId, franchiseeId],
        limit: 1,
      );
      if (parents.isEmpty) {
        throw const FormatException('V2 item parent is unavailable.');
      }
      return parents.first['local_id'] as int;
    }
    final parents = await executor.rawQuery(
      '''
      SELECT i.local_id
      FROM items i
      JOIN clients c ON c.local_id = i.client_id
      WHERE i.remote_id = ? AND c.franchisee_id = ?
        AND i.deleted_at IS NULL AND c.deleted_at IS NULL
      LIMIT 1
      ''',
      [parentRemoteId, franchiseeId],
    );
    if (parents.isEmpty) {
      throw const FormatException('V2 rectangle parent is unavailable.');
    }
    return parents.first['local_id'] as int;
  }

  int _compareV2Tuple(
    Map<String, dynamic> incoming,
    Map<String, Object?> existing,
  ) {
    final incomingGeneration = BigInt.parse(incoming['generation'].toString());
    final currentGeneration =
        BigInt.tryParse(existing['server_generation']?.toString() ?? '0') ??
            BigInt.zero;
    if (incomingGeneration != currentGeneration) {
      return incomingGeneration < currentGeneration ? -1 : 1;
    }
    final incomingBranch = incoming['branch_seq'] as int;
    final currentBranch = existing['server_branch_seq'] as int? ?? 0;
    if (incomingBranch != currentBranch) {
      return incomingBranch < currentBranch ? -1 : 1;
    }
    final incomingRank = incoming['operation'] == 'delete' ? 1 : 0;
    final currentRank = existing['server_operation_rank'] as int? ?? 0;
    if (incomingRank != currentRank) {
      return incomingRank < currentRank ? -1 : 1;
    }
    for (final pair in [
      [
        incoming['writer_id'].toString(),
        existing['server_writer_id']?.toString() ?? ''
      ],
      [
        incoming['change_id'].toString(),
        existing['server_change_id']?.toString() ?? ''
      ],
    ]) {
      if (pair[0] != pair[1]) return pair[0].compareTo(pair[1]);
    }
    return 0;
  }

  List<String> _serverPhotos(Map<String, dynamic> record) {
    final media = Map<String, dynamic>.from(record['media'] as Map);
    return List<String>.from(media['photos'] as List);
  }

  Future<List<String>> _mergePendingClientPhotos(
    DatabaseExecutor executor, {
    required String franchiseeId,
    required String remoteId,
    required List<String> serverPhotos,
    required List<String> legacyFallback,
  }) async {
    final pendingPaths = <String>[];
    if (await _supportsPendingClientPhotos(executor)) {
      final rows = await executor.query(
        'pending_client_photos',
        columns: ['local_path'],
        where: 'franchisee_id = ? AND client_remote_id = ?',
        whereArgs: [franchiseeId, remoteId],
        orderBy: 'rowid',
      );
      pendingPaths.addAll(
        rows.map((row) => row['local_path'] as String),
      );
    } else {
      pendingPaths.addAll(
        legacyFallback.where(
          (photo) => !_isCanonicalClientPhotoPath(photo, remoteId: remoteId),
        ),
      );
    }
    return [
      ...serverPhotos,
      for (final photo in pendingPaths)
        if (!serverPhotos.contains(photo)) photo,
    ];
  }

  Future<void> _deletePendingClientPhotos(
    DatabaseExecutor executor, {
    required String franchiseeId,
    required String remoteId,
  }) async {
    if (!await _supportsPendingClientPhotos(executor)) return;
    await executor.delete(
      'pending_client_photos',
      where: 'franchisee_id = ? AND client_remote_id = ?',
      whereArgs: [franchiseeId, remoteId],
    );
  }

  Future<void> _applyV2Record(
    DatabaseExecutor executor,
    String collection,
    Map<String, dynamic> record, {
    required String franchiseeId,
    required Map<String, String> submittedChangeIds,
    required Map<String, String> outcomeStatuses,
  }) async {
    final table = collection;
    final remoteId = record['remote_id'] as String;
    final existing = await _existingRemoteRow(executor, table, remoteId);
    final submittedChangeId = submittedChangeIds[remoteId];
    final localPendingChangeId = existing?['pending_change_id']?.toString();
    final exactSubmitted =
        submittedChangeId != null && submittedChangeId == localPendingChangeId;
    const terminalStatuses = {
      'applied',
      'already_applied',
      'superseded',
      'permanently_deleted',
    };
    final terminal = submittedChangeId != null &&
        terminalStatuses.contains(outcomeStatuses[submittedChangeId]);
    final localDirty = existing?['is_dirty'] == 1;
    final replaceMutable =
        existing == null || !localDirty || (exactSubmitted && terminal);
    final tupleComparison =
        existing == null ? 1 : _compareV2Tuple(record, existing);
    if (tupleComparison < 0) return;
    final incomingCursor = BigInt.parse(record['row_cursor'].toString());
    final currentRowCursor =
        BigInt.tryParse(existing?['server_cursor']?.toString() ?? '0') ??
            BigInt.zero;
    if (existing != null &&
        tupleComparison > 0 &&
        incomingCursor < currentRowCursor) {
      throw const FormatException(
        'V2 response advanced a tuple behind the stored row cursor.',
      );
    }
    if (existing != null && tupleComparison == 0) {
      if (record['payload_hash'] != existing['server_payload_hash']) {
        throw const FormatException(
          'V2 response reused an authoritative tuple with another payload.',
        );
      }
      if (incomingCursor < currentRowCursor) return;
      final values = <String, Object?>{
        ..._serverMetadata(record),
        'updated_at': record['server_timestamp'],
      };
      if (collection == 'clients') {
        final serverPhotos = _serverPhotos(record);
        final localPhotos = _decodeClientPhotos(existing['photos']);
        if (record['operation'] == 'delete' && !localDirty) {
          await _deletePendingClientPhotos(
            executor,
            franchiseeId: franchiseeId,
            remoteId: remoteId,
          );
          values['photos'] = '[]';
        } else {
          values['photos'] = jsonEncode(
            await _mergePendingClientPhotos(
              executor,
              franchiseeId: franchiseeId,
              remoteId: remoteId,
              serverPhotos: serverPhotos,
              legacyFallback: localPhotos,
            ),
          );
        }
      } else if (collection == 'rectangles' && !localDirty) {
        final media = Map<String, dynamic>.from(record['media'] as Map);
        values['image_data'] = media['image_data'];
      }
      await executor.update(
        table,
        values,
        where: 'local_id = ?',
        whereArgs: [existing['local_id']],
      );
      return;
    }

    int? parentLocalId;
    if (collection == 'items' || collection == 'rectangles') {
      parentLocalId = await _ownedParentLocalId(
        executor,
        collection,
        record['parent_id'] as String,
        franchiseeId,
      );
      final existingParentColumn =
          collection == 'items' ? 'client_id' : 'item_id';
      if (existing != null && existing[existingParentColumn] != parentLocalId) {
        throw const FormatException('V2 response changed an immutable parent.');
      }
    }
    if ((collection == 'clients' || collection == 'default_prices') &&
        record['franchisee_id'] != franchiseeId) {
      throw const FormatException('V2 response crossed tenant ownership.');
    }

    final metadata = _serverMetadata(record);
    if (!replaceMutable) {
      final dirtyMetadata = <String, Object?>{...metadata};
      if (collection == 'clients') {
        final serverPhotos = _serverPhotos(record);
        final localPhotos = _decodeClientPhotos(existing['photos']);
        dirtyMetadata['photos'] = jsonEncode(
          await _mergePendingClientPhotos(
            executor,
            franchiseeId: franchiseeId,
            remoteId: remoteId,
            serverPhotos: serverPhotos,
            legacyFallback: localPhotos,
          ),
        );
      }
      await executor.update(
        table,
        dirtyMetadata,
        where: 'local_id = ?',
        whereArgs: [existing['local_id']],
      );
      return;
    }

    final payload = Map<String, dynamic>.from(
      record['payload'] as Map<dynamic, dynamic>,
    );
    final values = <String, Object?>{
      'remote_id': remoteId,
      'is_dirty': 0,
      'updated_at': record['server_timestamp'],
      'deleted_at': record['deleted_at'],
      ...metadata,
      ..._clearPendingLww,
    };
    switch (collection) {
      case 'clients':
        final serverPhotos = _serverPhotos(record);
        final localPhotos = existing == null
            ? const <String>[]
            : _decodeClientPhotos(existing['photos']);
        final deleting = record['operation'] == 'delete';
        if (deleting) {
          await _deletePendingClientPhotos(
            executor,
            franchiseeId: franchiseeId,
            remoteId: remoteId,
          );
        }
        values.addAll({
          'franchisee_id': franchiseeId,
          'name': payload['name'] ?? '',
          'address': payload['address'],
          'site_address': payload['site_address'],
          'email': payload['email'],
          'phone': payload['phone'],
          'latitude': payload['latitude'],
          'longitude': payload['longitude'],
          'discounted_price': payload['discounted_price'],
          'photos': jsonEncode(
            deleting
                ? const <String>[]
                : await _mergePendingClientPhotos(
                    executor,
                    franchiseeId: franchiseeId,
                    remoteId: remoteId,
                    serverPhotos: serverPhotos,
                    legacyFallback: localPhotos,
                  ),
          ),
        });
      case 'items':
        values.addAll({
          'client_id': parentLocalId,
          'name': payload['name'] ?? '',
          'price': payload['price'] ?? 0,
          'enabled': payload['enabled'] == true ? 1 : 0,
        });
      case 'rectangles':
        values.addAll({
          'item_id': parentLocalId,
          'length': payload['length'] ?? 1,
          'width': payload['width'] ?? 1,
          'image_data':
              (record['media'] as Map<dynamic, dynamic>)['image_data'],
        });
      case 'default_prices':
        values.addAll({
          'franchisee_id': franchiseeId,
          'price': payload['price'] ?? 0,
          'enabled': payload['enabled'] == true ? 1 : 0,
        });
    }
    if (existing == null) {
      await executor.insert(table, values);
    } else {
      await executor.update(
        table,
        values,
        where: 'local_id = ?',
        whereArgs: [existing['local_id']],
      );
    }
  }

  Future<void> _applyV2Warranty(
    DatabaseExecutor executor,
    Map<String, dynamic> record, {
    required String franchiseeId,
  }) async {
    final parentRows = await executor.query(
      'clients',
      columns: ['local_id'],
      where: 'remote_id = ? AND franchisee_id = ? AND deleted_at IS NULL',
      whereArgs: [record['client_id'], franchiseeId],
      limit: 1,
    );
    if (parentRows.isEmpty) {
      throw const FormatException('V2 warranty parent is unavailable.');
    }
    final tombstones = await executor.query(
      'warranty_deletion_tombstones',
      columns: ['warranty_id'],
      where: 'franchisee_id = ? AND warranty_id = ?',
      whereArgs: [franchiseeId, record['remote_id']],
      limit: 1,
    );
    if (tombstones.isNotEmpty) return;
    final existing = await _existingRemoteRow(
      executor,
      'warranties',
      record['remote_id'] as String,
    );
    if (existing != null &&
        existing['client_id'] != parentRows.first['local_id']) {
      throw const FormatException('V2 warranty changed an immutable parent.');
    }
    final values = <String, Object?>{
      'remote_id': record['remote_id'],
      'client_id': parentRows.first['local_id'],
      'warranty_card_number': record['warranty_card_number'],
      'start_date': record['start_date'],
      'duration_years': record['duration_years'],
      'pdf_url': record['pdf_url'],
      'server_version': record['version'],
      'is_dirty': 0,
      'updated_at': record['server_timestamp'],
      'deleted_at': null,
    };
    if (existing == null) {
      await executor.insert('warranties', values);
    } else {
      await executor.update(
        'warranties',
        values,
        where: 'local_id = ?',
        whereArgs: [existing['local_id']],
      );
    }
  }

  Future<void> _applyV2Proposal(
    DatabaseExecutor executor,
    Map<String, dynamic> record, {
    required String franchiseeId,
  }) async {
    final parentRows = await executor.query(
      'clients',
      columns: ['local_id'],
      where: record['deleted_at'] == null
          ? 'remote_id = ? AND franchisee_id = ? AND deleted_at IS NULL'
          : 'remote_id = ? AND franchisee_id = ?',
      whereArgs: [record['client_id'], franchiseeId],
      limit: 1,
    );
    if (parentRows.isEmpty) {
      throw const FormatException('V2 proposal parent is unavailable.');
    }
    final existing = await _existingRemoteRow(
      executor,
      'proposals',
      record['remote_id'] as String,
    );
    if (existing != null &&
        existing['client_id'] != parentRows.first['local_id']) {
      throw const FormatException('V2 proposal changed an immutable parent.');
    }
    if (existing != null &&
        existing['is_dirty'] == 1 &&
        existing['deleted_at'] != null &&
        record['deleted_at'] == null) {
      return;
    }
    final values = <String, Object?>{
      'remote_id': record['remote_id'],
      'client_id': parentRows.first['local_id'],
      'pdf_url': record['pdf_url'],
      'is_dirty': 0,
      'updated_at': record['server_timestamp'],
      'deleted_at': record['deleted_at'],
    };
    if (existing == null) {
      await executor.insert('proposals', values);
    } else {
      await executor.update(
        'proposals',
        values,
        where: 'local_id = ?',
        whereArgs: [existing['local_id']],
      );
    }
  }

  Future<void> _assertSyncStateCursor(
    DatabaseExecutor executor,
    String key,
    String expected,
  ) async {
    final rows = await executor.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    final current = rows.isEmpty ? '0' : rows.first['value'] as String;
    if (current != expected) {
      throw StateError(
          'A delayed sync response lost its cursor compare-and-set.');
    }
  }

  Future<void> _casSyncStateCursor(
    DatabaseExecutor executor,
    String key,
    String expected,
    String next,
  ) async {
    if (BigInt.parse(next) < BigInt.parse(expected)) {
      throw StateError('A sync response cursor cannot move backwards.');
    }
    if (expected == '0') {
      await executor.insert(
        'sync_state',
        {'key': key, 'value': '0'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    final changed = await executor.update(
      'sync_state',
      {'value': next},
      where: 'key = ? AND value = ?',
      whereArgs: [key, expected],
    );
    if (changed != 1) {
      throw StateError(
          'A delayed sync response lost its cursor compare-and-set.');
    }
  }

  Future<void> applySyncV2Response({
    required String franchiseeId,
    required String requestCursor,
    required String responseCursor,
    required String requestWarrantyTombstoneCursor,
    required String warrantyTombstoneCursor,
    required Map<String, List<Map<String, dynamic>>> records,
    required List<Map<String, dynamic>> warranties,
    required List<Map<String, dynamic>> proposals,
    required List<WarrantyDeletionTombstone> warrantyTombstones,
    required Map<String, Map<String, String>> submittedChangeIds,
    required Map<String, String> outcomeStatuses,
    required bool activateProtocol,
  }) async {
    final db = await database;
    await db.transaction((transaction) async {
      await _assertSyncStateCursor(
        transaction,
        _syncV2CursorKey(franchiseeId),
        requestCursor,
      );
      await _assertSyncStateCursor(
        transaction,
        _warrantyTombstoneCursorKey(franchiseeId),
        requestWarrantyTombstoneCursor,
      );
      for (final tombstone in warrantyTombstones) {
        if (tombstone.franchiseeId != franchiseeId) {
          throw ArgumentError('A tombstone cannot cross the active franchisee');
        }
        await transaction.insert(
          'warranty_deletion_tombstones',
          tombstone.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await transaction.delete(
          'warranties',
          where: 'remote_id = ?',
          whereArgs: [tombstone.warrantyId],
        );
      }
      for (final collection in _lwwTables) {
        for (final record in records[collection] ?? const []) {
          await _applyV2Record(
            transaction,
            collection,
            record,
            franchiseeId: franchiseeId,
            submittedChangeIds:
                submittedChangeIds[collection] ?? const <String, String>{},
            outcomeStatuses: outcomeStatuses,
          );
        }
      }
      for (final warranty in warranties) {
        await _applyV2Warranty(
          transaction,
          warranty,
          franchiseeId: franchiseeId,
        );
      }
      for (final proposal in proposals) {
        await _applyV2Proposal(
          transaction,
          proposal,
          franchiseeId: franchiseeId,
        );
      }
      await _casSyncStateCursor(
        transaction,
        _syncV2CursorKey(franchiseeId),
        requestCursor,
        responseCursor,
      );
      await _casSyncStateCursor(
        transaction,
        _warrantyTombstoneCursorKey(franchiseeId),
        requestWarrantyTombstoneCursor,
        warrantyTombstoneCursor,
      );
      if (activateProtocol) {
        await transaction.insert(
            'sync_state',
            {
              'key': _syncV2EnabledKey(franchiseeId),
              'value': '1',
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Client>> getDirtyClients() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'clients',
      where: 'is_dirty = 1',
    );
    return List.generate(maps.length, (i) => Client.fromMap(maps[i]));
  }

  Future<List<Item>> getDirtyItems() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'items',
      where: 'is_dirty = 1',
    );
    return List.generate(maps.length, (i) => Item.fromMap(maps[i]));
  }

  Future<List<Rectangle>> getDirtyRectangles() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'rectangles',
      where: 'is_dirty = 1',
    );
    return List.generate(maps.length, (i) => Rectangle.fromMap(maps[i]));
  }

  Future<List<DefaultPrice>> getDirtyDefaultPrices(String franchiseeId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'default_prices',
      where: 'is_dirty = 1 AND franchisee_id = ?',
      whereArgs: [franchiseeId],
    );
    return List.generate(maps.length, (i) => DefaultPrice.fromMap(maps[i]));
  }

  Future<DefaultPrice?> getDefaultPriceByRemoteId(
    String remoteId,
    String franchiseeId,
  ) async {
    final db = await database;
    final maps = await db.query(
      'default_prices',
      where: 'remote_id = ? AND franchisee_id = ?',
      whereArgs: [remoteId, franchiseeId],
      limit: 1,
    );
    return maps.isEmpty ? null : DefaultPrice.fromMap(maps.first);
  }

  Future<List<Warranty>> getDirtyWarranties() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'warranties',
      where: 'is_dirty = 1',
    );
    return List.generate(maps.length, (i) => Warranty.fromMap(maps[i]));
  }

  Future<List<Proposal>> getDirtyProposals() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'proposals',
      where: 'is_dirty = 1',
    );
    return List.generate(maps.length, (i) => Proposal.fromMap(maps[i]));
  }

  Future<int> markAsSynced(
    String table,
    String remoteId, {
    String? franchiseeId,
    required String submittedUpdatedAt,
  }) async {
    final db = await database;
    final tenantScoped = table == 'default_prices';
    if (tenantScoped && (franchiseeId == null || franchiseeId.isEmpty)) {
      throw ArgumentError('A franchisee is required for default-price sync');
    }
    final values = <String, Object?>{'is_dirty': 0};
    if (await _supportsLww(db, table)) {
      values.addAll(_clearPendingLww);
    }
    return db.update(
      table,
      values,
      where: tenantScoped
          ? 'remote_id = ? AND franchisee_id = ? AND updated_at = ? AND is_dirty = 1'
          : 'remote_id = ? AND updated_at = ? AND is_dirty = 1',
      whereArgs: tenantScoped
          ? [remoteId, franchiseeId, submittedUpdatedAt]
          : [remoteId, submittedUpdatedAt],
    );
  }
}
