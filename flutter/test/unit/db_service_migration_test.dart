import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app_client/src/services/db_service.dart';

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
        'v9 adds warranty versions and tombstones while discarding legacy offline deletes',
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

      await DbService.migrateSchema(database, 8, 9);

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
    });
  });
}
