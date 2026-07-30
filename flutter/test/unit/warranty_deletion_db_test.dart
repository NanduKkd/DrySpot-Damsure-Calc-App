import 'package:app_client/src/models/warranty.dart';
import 'package:app_client/src/models/warranty_deletion_tombstone.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('repeated replacement and tombstone application converge locally',
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
            server_version INTEGER NOT NULL DEFAULT 1,
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
      },
    );
    addTearDown(database.close);
    final service = DbService(database: database);
    final old = Warranty(
      remoteId: 'old-warranty',
      clientId: 1,
      warrantyCardNumber: 'OLD',
      startDate: DateTime.utc(2026),
      durationYears: 5,
      pdfUrl: '/old.pdf',
      isDirty: false,
    );
    final replacement = Warranty(
      remoteId: 'new-warranty',
      clientId: 1,
      warrantyCardNumber: 'NEW',
      startDate: DateTime.utc(2026),
      durationYears: 10,
      pdfUrl: '/new.pdf',
      version: 1,
      isDirty: false,
    );
    await service.insertWarranty(old);

    await service.replaceWarrantyFromServer(replacement);
    await service.replaceWarrantyFromServer(replacement);

    expect(
      await database.query(
        'warranties',
        columns: ['remote_id', 'warranty_card_number'],
      ),
      [
        {'remote_id': 'new-warranty', 'warranty_card_number': 'NEW'}
      ],
    );

    final tombstone = WarrantyDeletionTombstone(
      warrantyId: 'new-warranty',
      franchiseeId: 'tenant-a',
      deletionSequence: '9',
      deletedAt: DateTime.utc(2026, 7, 30),
    );
    await service.applyWarrantyTombstone(tombstone);
    await service.applyWarrantyTombstone(tombstone);

    expect(await database.query('warranties'), isEmpty);
    expect(await database.query('warranty_deletion_tombstones'), hasLength(1));
    expect(
      await service.hasWarrantyTombstone(
        'new-warranty',
        franchiseeId: 'tenant-a',
      ),
      isTrue,
    );
  });
}
