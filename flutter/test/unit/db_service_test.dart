import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DbService dbService;
  late Database database;

  setUp(() async {
    database = await openDatabase(inMemoryDatabasePath, version: 1, onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE clients (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            remote_id TEXT UNIQUE,
            franchisee_id TEXT,
            name TEXT NOT NULL,
            address TEXT,
            email TEXT,
            phone TEXT,
            latitude REAL,
            longitude REAL,
            photos TEXT,
            discounted_price REAL,
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
            price REAL DEFAULT 0,
            enabled INTEGER DEFAULT 1,
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
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
            is_dirty INTEGER DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            FOREIGN KEY (item_id) REFERENCES items (local_id) ON DELETE CASCADE
          )
        ''');
    });
    dbService = DbService(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  group('DbService', () {
    test('Client CRUD', () async {
      final client = Client(
        remoteId: 'c1',
        name: 'John Doe',
        address: '123 Main St',
        updatedAt: DateTime.now(),
      );

      final localId = await dbService.insertClient(client);
      expect(localId, 1);

      final clients = await dbService.getClients();
      expect(clients.length, 1);
      expect(clients[0].name, 'John Doe');
      expect(clients[0].localId, localId);

      await dbService.updateClient(clients[0].copyWith(name: 'Jane Doe'));
      final updatedClients = await dbService.getClients();
      expect(updatedClients[0].name, 'Jane Doe');

      await dbService.softDeleteClient(localId);
      final remainingClients = await dbService.getClients();
      expect(remainingClients.length, 0);

      final dirtyClients = await dbService.getDirtyClients();
      expect(dirtyClients.length, 1); // Soft deleted is still dirty
      expect(dirtyClients[0].deletedAt, isNotNull);
    });

    test('Item and Rectangle CRUD', () async {
      final clientId = await dbService.insertClient(Client(
        remoteId: 'c1',
        name: 'John Doe',
        updatedAt: DateTime.now(),
      ));

      final item = Item(
        remoteId: 'i1',
        clientId: clientId,
        name: 'Roof',
        price: 10.0,
        updatedAt: DateTime.now(),
      );

      final itemLocalId = await dbService.insertItem(item);
      expect(itemLocalId, 1);

      final rect = Rectangle(
        remoteId: 'r1',
        itemId: itemLocalId,
        length: 10,
        width: 20,
        updatedAt: DateTime.now(),
      );

      final rectLocalId = await dbService.insertRectangle(rect);
      expect(rectLocalId, 1);

      final clients = await dbService.getClients();
      expect(clients[0].items.length, 1);
      expect(clients[0].items[0].rectangles.length, 1);
      expect(clients[0].items[0].rectangles[0].area, 200.0);
    });
  });
}
