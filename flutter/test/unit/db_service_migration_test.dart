import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/lww_protocol.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('DbService Migration', () {
    test('Database includes phone column in clients table after upgrade',
        () async {
      final dbService = DbService();
      final db = await dbService.database;

      final columns = await db.rawQuery('PRAGMA table_info(clients)');
      final hasPhone = columns.any((column) => column['name'] == 'phone');

      expect(hasPhone, isTrue,
          reason: 'clients table should have phone column');
    });

    test('Database includes image_data column in rectangles table', () async {
      final dbService = DbService();
      final db = await dbService.database;

      final columns = await db.rawQuery('PRAGMA table_info(rectangles)');
      final hasImageData =
          columns.any((column) => column['name'] == 'image_data');

      expect(
        hasImageData,
        isTrue,
        reason: 'rectangles table should have image_data column',
      );
    });

    test(
        'v10 adds warranty deletion state idempotently while discarding legacy offline deletes',
        () async {
      final database = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE warranties (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              remote_id TEXT UNIQUE,
              client_id INTEGER,
              warranty_card_number TEXT,
              start_date TEXT,
              duration_years INTEGER,
              pdf_url TEXT,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT NOT NULL,
              deleted_at TEXT
            )
          ''');
          await db.insert('warranties', {
            'remote_id': 'legacy-deleted',
            'client_id': 1,
            'warranty_card_number': 'OLD',
            'start_date': '2026-01-01T00:00:00.000Z',
            'duration_years': 5,
            'pdf_url': '/old.pdf',
            'is_dirty': 1,
            'updated_at': '2026-01-01T00:00:00.000Z',
            'deleted_at': '2026-07-01T00:00:00.000Z',
          });
          await db.insert('warranties', {
            'remote_id': 'active',
            'client_id': 1,
            'warranty_card_number': 'ACTIVE',
            'start_date': '2026-01-01T00:00:00.000Z',
            'duration_years': 5,
            'pdf_url': '/active.pdf',
            'is_dirty': 0,
            'updated_at': '2026-01-01T00:00:00.000Z',
            'deleted_at': null,
          });
        },
      );
      addTearDown(database.close);

      await DbService.migrateSchema(database, 8, 10);
      await DbService.migrateSchema(database, 9, 10);

      final columns = await database.rawQuery('PRAGMA table_info(warranties)');
      expect(
        columns.any((column) => column['name'] == 'server_version'),
        isTrue,
      );
      expect(
        await database.query('warranties', columns: ['remote_id']),
        [
          {'remote_id': 'active'}
        ],
      );
      expect(
        await database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'warranty_deletion_tombstones'",
        ),
        isNotEmpty,
      );
      expect(
        await database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_state'",
        ),
        isNotEmpty,
      );
    });

    test(
        'v11 adds tenant cursor and LWW state without rewriting legacy dirty data',
        () async {
      final database = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE clients (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              remote_id TEXT UNIQUE,
              franchisee_id TEXT,
              name TEXT NOT NULL,
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
              price REAL,
              enabled INTEGER,
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
              length REAL,
              width REAL,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT NOT NULL,
              deleted_at TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE default_prices (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              remote_id TEXT UNIQUE,
              franchisee_id TEXT,
              price REAL,
              enabled INTEGER,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT NOT NULL,
              deleted_at TEXT
            )
          ''');
          await db.insert('clients', {
            'remote_id': 'legacy-dirty',
            'franchisee_id': 'tenant-a',
            'name': 'Unsynced',
            'is_dirty': 1,
            'updated_at': '2026-07-30T00:00:00.000Z',
          });
        },
      );
      addTearDown(database.close);

      await DbService.migrateSchema(database, 10, 11);
      await DbService.migrateSchema(database, 10, 11);

      for (final table in [
        'clients',
        'items',
        'rectangles',
        'default_prices',
      ]) {
        final columns = await database.rawQuery('PRAGMA table_info($table)');
        final names = columns.map((column) => column['name']).toSet();
        expect(
          names,
          containsAll([
            'server_generation',
            'server_cursor',
            'pending_base_generation',
            'pending_generation',
            'pending_branch_seq',
            'pending_writer_id',
            'pending_change_id',
          ]),
        );
      }
      expect(
        (await database.query('clients')).single,
        containsPair('name', 'Unsynced'),
      );
      expect(
        (await database.query('clients')).single,
        containsPair('is_dirty', 1),
      );
      expect(
        (await database.query('clients')).single['pending_change_id'],
        isNull,
        reason: 'legacy v1 dirty work must drain before v2 bootstrap',
      );
      expect(
        await database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_state'",
        ),
        isNotEmpty,
      );
    });

    test(
        'v12 durably backfills only unacknowledged client photo paths and reapplies',
        () async {
      final database = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE clients (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              remote_id TEXT UNIQUE,
              franchisee_id TEXT,
              name TEXT NOT NULL,
              photos TEXT,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT NOT NULL,
              deleted_at TEXT
            )
          ''');
          await db.insert('clients', {
            'remote_id': '40000000-0000-4000-8000-000000000001',
            'franchisee_id': '40000000-0000-4000-8000-000000000002',
            'name': 'Photo client',
            'photos':
                '["/api/photos/client/40000000-0000-4000-8000-000000000001/40000000-0000-4000-8000-000000000010.jpg","/offline/one.jpg","/offline/two.jpg"]',
            'is_dirty': 0,
            'updated_at': '2026-07-30T00:00:00.000Z',
          });
          await db.insert('clients', {
            'remote_id': '40000000-0000-4000-8000-000000000003',
            'franchisee_id': '40000000-0000-4000-8000-000000000002',
            'name': 'Deleted client',
            'photos': '["/offline/deleted.jpg"]',
            'is_dirty': 0,
            'updated_at': '2026-07-30T00:00:00.000Z',
            'deleted_at': '2026-07-30T01:00:00.000Z',
          });
        },
      );
      addTearDown(database.close);

      await DbService.migrateSchema(database, 11, 12);
      await DbService.migrateSchema(database, 11, 12);

      expect(
        await database.query(
          'pending_client_photos',
          columns: ['client_remote_id', 'local_path'],
          orderBy: 'local_path',
        ),
        [
          {
            'client_remote_id': '40000000-0000-4000-8000-000000000001',
            'local_path': '/offline/one.jpg',
          },
          {
            'client_remote_id': '40000000-0000-4000-8000-000000000001',
            'local_path': '/offline/two.jpg',
          },
        ],
      );
    });

    test(
        'v12 rolls back malformed legacy photo state and reapplies after repair',
        () async {
      final path =
          '${Directory.systemTemp.path}/damsure-v12-${DateTime.now().microsecondsSinceEpoch}.db';
      addTearDown(() => deleteDatabase(path));
      final legacy = await openDatabase(
        path,
        version: 11,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE clients (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              remote_id TEXT UNIQUE,
              franchisee_id TEXT,
              name TEXT NOT NULL,
              photos TEXT,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT NOT NULL,
              deleted_at TEXT
            )
          ''');
          await db.insert('clients', {
            'remote_id': '40000000-0000-4000-8000-000000000011',
            'franchisee_id': '40000000-0000-4000-8000-000000000012',
            'name': 'Malformed photos',
            'photos': '{"not":"a list"}',
            'is_dirty': 0,
            'updated_at': '2026-07-30T00:00:00.000Z',
          });
        },
      );
      await legacy.close();

      await expectLater(
        openDatabase(
          path,
          version: 12,
          singleInstance: false,
          onUpgrade: DbService.migrateSchema,
        ),
        throwsA(isA<FormatException>()),
      );

      final repaired = await openDatabase(
        path,
        version: 11,
        singleInstance: false,
      );
      expect(
        await repaired.rawQuery(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name = 'pending_client_photos'",
        ),
        isEmpty,
        reason: 'the failed schema and backfill must roll back together',
      );
      await repaired.update(
        'clients',
        {'photos': '["/offline/repaired.jpg"]'},
      );
      await repaired.close();

      final upgraded = await openDatabase(
        path,
        version: 12,
        singleInstance: false,
        onUpgrade: DbService.migrateSchema,
      );
      expect(
        await upgraded.query(
          'pending_client_photos',
          columns: ['local_path'],
        ),
        [
          {'local_path': '/offline/repaired.jpg'},
        ],
      );
      await upgraded.close();
    });

    test(
        'v13 snapshots pending payload identity and rejects inconsistent reapply state',
        () async {
      final database = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: (db, _) async {
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
              name TEXT,
              price REAL,
              enabled INTEGER,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT,
              deleted_at TEXT,
              $lww
            )
          ''');
          await db.execute('''
            CREATE TABLE rectangles (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              remote_id TEXT UNIQUE,
              length REAL,
              width REAL,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT,
              deleted_at TEXT,
              $lww
            )
          ''');
          await db.execute('''
            CREATE TABLE default_prices (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              remote_id TEXT UNIQUE,
              price REAL,
              enabled INTEGER,
              is_dirty INTEGER DEFAULT 1,
              updated_at TEXT,
              deleted_at TEXT,
              $lww
            )
          ''');
          await db.insert('clients', {
            'remote_id': '40000000-0000-4000-8000-000000000021',
            'franchisee_id': '40000000-0000-4000-8000-000000000022',
            'name': 'Pending payload',
            'address': '',
            'site_address': '',
            'email': '',
            'phone': '',
            'latitude': 11.123456789,
            'longitude': -0.0,
            'discounted_price': 44.44,
            'is_dirty': 1,
            'updated_at': '2026-07-30T00:00:00.000Z',
            'pending_base_generation': '1',
            'pending_generation': '2',
            'pending_branch_seq': 1000001,
            'pending_writer_id': '40000000-0000-4000-8000-000000000023',
            'pending_change_id': '40000000-0000-4000-8000-000000000024',
          });
        },
      );
      addTearDown(database.close);

      await expectLater(
        DbService.migrateSchema(database, 12, 13),
        throwsA(isA<StateError>()),
      );
      expect(
        (await database.rawQuery('PRAGMA table_info(clients)'))
            .map((column) => column['name']),
        isNot(contains('pending_payload_hash')),
        reason: 'failed validation must roll back the schema additions',
      );

      await database.update(
        'clients',
        {'pending_branch_seq': 1},
      );
      await DbService.migrateSchema(database, 12, 13);
      await DbService.migrateSchema(database, 12, 13);

      final expectedPayload = {
        'address': '',
        'discounted_price': 44.44,
        'email': null,
        'latitude': 11.123456954956055,
        'longitude': 0,
        'name': 'Pending payload',
        'phone': '',
        'site_address': '',
      };
      final expectedHash =
          canonicalLwwMutablePayloadHash('clients', expectedPayload);
      var row = (await database.query('clients')).single;
      expect(row['email'], '');
      expect(row['pending_operation_rank'], 0);
      expect(row['pending_payload_hash'], expectedHash);

      final corruptHash = List.filled(64, 'f').join();
      await database.update(
        'clients',
        {'pending_payload_hash': corruptHash},
      );
      await expectLater(
        DbService.migrateSchema(database, 12, 13),
        throwsA(isA<StateError>()),
      );
      row = (await database.query('clients')).single;
      expect(row['pending_payload_hash'], corruptHash);

      await database.update(
        'clients',
        {'pending_payload_hash': expectedHash},
      );
      await DbService.migrateSchema(database, 12, 13);
    });
  });
}
