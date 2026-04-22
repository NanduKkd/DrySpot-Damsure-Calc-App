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
  });
}
