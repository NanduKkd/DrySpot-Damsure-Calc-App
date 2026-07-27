import 'package:app_client/src/models/default_price.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database database;
  late DbService dbService;

  setUp(() async {
    database = await openDatabase(inMemoryDatabasePath, version: 1,
        onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE default_prices (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          remote_id TEXT UNIQUE,
          franchisee_id TEXT NOT NULL,
          price REAL NOT NULL,
          enabled INTEGER DEFAULT 1,
          is_dirty INTEGER DEFAULT 1,
          updated_at TEXT NOT NULL,
          deleted_at TEXT
        )
      ''');
    });
    dbService = DbService(database: database);
  });

  tearDown(() async => database.close());

  DefaultPrice price(String franchiseeId, String remoteId, double value) {
    return DefaultPrice(
      franchiseeId: franchiseeId,
      remoteId: remoteId,
      price: value,
      updatedAt: DateTime.utc(2026),
    );
  }

  test('default prices are isolated by franchisee for reads and dirty records',
      () async {
    await dbService.insertDefaultPrice(price('tenant-a', 'a-price', 10),
        franchiseeId: 'tenant-a');
    await dbService.insertDefaultPrice(price('tenant-b', 'b-price', 20),
        franchiseeId: 'tenant-b');

    expect(await dbService.getDefaultPrices('tenant-a'), hasLength(1));
    expect((await dbService.getDefaultPrices('tenant-a')).single.remoteId,
        'a-price');
    expect((await dbService.getDirtyDefaultPrices('tenant-b')).single.remoteId,
        'b-price');
  });

  test('default-price mutation cannot cross a franchisee boundary', () async {
    final localId = await dbService.insertDefaultPrice(
      price('tenant-a', 'a-price', 10),
      franchiseeId: 'tenant-a',
    );

    expect(
      await dbService.deleteDefaultPrice(localId, franchiseeId: 'tenant-b'),
      0,
    );
    expect(await dbService.getDefaultPrices('tenant-a'), hasLength(1));
  });

  test(
      'settings session switch clears old tenant prices before loading new ones',
      () async {
    await dbService.insertDefaultPrice(price('tenant-a', 'a-price', 10),
        franchiseeId: 'tenant-a');
    await dbService.insertDefaultPrice(price('tenant-b', 'b-price', 20),
        franchiseeId: 'tenant-b');
    final provider = SettingsProvider(dbService: dbService);

    provider.updateSession(isAuthenticated: true, franchiseeId: 'tenant-a');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(provider.defaultPrices.single.remoteId, 'a-price');

    provider.updateSession(isAuthenticated: true, franchiseeId: 'tenant-b');
    expect(provider.defaultPrices, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(provider.defaultPrices.single.remoteId, 'b-price');

    provider.updateSession(isAuthenticated: false);
    expect(provider.defaultPrices, isEmpty);
  });
}
