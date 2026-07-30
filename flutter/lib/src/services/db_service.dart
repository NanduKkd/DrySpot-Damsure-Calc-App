import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/default_price.dart';
import '../models/warranty.dart';
import '../models/warranty_deletion_tombstone.dart';
import '../models/proposal.dart';

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
      version: 9,
      onCreate: _onCreate,
      onUpgrade: migrateSchema,
    );
  }

  static Future<void> migrateSchema(
      Database db, int oldVersion, int newVersion) async {
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
      await db
          .execute('ALTER TABLE default_prices ADD COLUMN franchisee_id TEXT');
    }
    if (oldVersion < 9 && newVersion >= 9) {
      final warrantyColumns =
          await db.rawQuery('PRAGMA table_info(warranties)');
      if (!warrantyColumns
          .any((column) => column['name'] == 'server_version')) {
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
        image_data TEXT,
        is_dirty INTEGER DEFAULT 1,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        FOREIGN KEY (item_id) REFERENCES items (local_id) ON DELETE CASCADE
      )
    ''');

    await _createDefaultPricesTable(db);
    await _createWarrantiesTable(db);
    await _createWarrantyDeletionTombstonesTable(db);
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
        deleted_at TEXT
      )
    ''');
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
      Database db) async {
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

  // Client CRUD
  Future<int> insertClient(Client client) async {
    final db = await database;
    return await db.insert('clients', client.toMap());
  }

  Future<List<Client>> getClients() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('clients', where: 'deleted_at IS NULL');

    List<Client> clients = [];
    for (var map in maps) {
      final items = await getItemsByClientId(map['local_id']);
      clients.add(Client.fromMap(map, items: items));
    }
    return clients;
  }

  Future<Client?> getClientByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db
        .query('clients', where: 'remote_id = ?', whereArgs: [remoteId]);
    if (maps.isEmpty) return null;
    final items = await getItemsByClientId(maps.first['local_id']);
    return Client.fromMap(maps.first, items: items);
  }

  Future<int> updateClient(Client client) async {
    final db = await database;
    return await db.update(
      'clients',
      client.toMap(),
      where: 'local_id = ?',
      whereArgs: [client.localId],
    );
  }

  Future<int> softDeleteClient(int localId) async {
    final db = await database;
    return await db.update(
      'clients',
      {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // Item CRUD
  Future<int> insertItem(Item item) async {
    final db = await database;
    return await db.insert('items', item.toMap());
  }

  Future<List<Item>> getItemsByClientId(int clientId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('items',
        where: 'client_id = ? AND deleted_at IS NULL', whereArgs: [clientId]);

    List<Item> items = [];
    for (var map in maps) {
      final rectangles = await getRectanglesByItemId(map['local_id']);
      items.add(Item.fromMap(map, rectangles: rectangles));
    }
    return items;
  }

  Future<Item?> getItemByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('items', where: 'remote_id = ?', whereArgs: [remoteId]);
    if (maps.isEmpty) return null;
    final rectangles = await getRectanglesByItemId(maps.first['local_id']);
    return Item.fromMap(maps.first, rectangles: rectangles);
  }

  Future<Item?> getItemByLocalId(int localId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('items', where: 'local_id = ?', whereArgs: [localId]);
    if (maps.isEmpty) return null;
    final rectangles = await getRectanglesByItemId(localId);
    return Item.fromMap(maps.first, rectangles: rectangles);
  }

  Future<int> updateItem(Item item) async {
    final db = await database;
    return await db.update(
      'items',
      item.toMap(),
      where: 'local_id = ?',
      whereArgs: [item.localId],
    );
  }

  Future<int> softDeleteItem(int localId) async {
    final db = await database;
    return await db.update(
      'items',
      {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // Rectangle CRUD
  Future<int> insertRectangle(Rectangle rectangle) async {
    final db = await database;
    return await db.insert('rectangles', rectangle.toMap());
  }

  Future<List<Rectangle>> getRectanglesByItemId(int itemId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('rectangles',
        where: 'item_id = ? AND deleted_at IS NULL', whereArgs: [itemId]);
    return List.generate(maps.length, (i) => Rectangle.fromMap(maps[i]));
  }

  Future<Rectangle?> getRectangleByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db
        .query('rectangles', where: 'remote_id = ?', whereArgs: [remoteId]);
    if (maps.isEmpty) return null;
    return Rectangle.fromMap(maps.first);
  }

  Future<int> updateRectangle(Rectangle rectangle) async {
    final db = await database;
    return await db.update(
      'rectangles',
      rectangle.toMap(),
      where: 'local_id = ?',
      whereArgs: [rectangle.localId],
    );
  }

  Future<int> softDeleteRectangle(int localId) async {
    final db = await database;
    return await db.update(
      'rectangles',
      {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
      where: 'local_id = ? AND deleted_at IS NULL',
      whereArgs: [localId],
    );
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
      {'franchisee_id': normalizedFranchiseeId, 'is_dirty': 1},
      where: "franchisee_id IS NULL OR TRIM(franchisee_id) = ''",
    );
  }

  Future<int> insertDefaultPrice(DefaultPrice defaultPrice,
      {required String franchiseeId}) async {
    if (franchiseeId.isEmpty || defaultPrice.franchiseeId != franchiseeId) {
      throw ArgumentError(
          'Default prices must belong to the active franchisee');
    }
    final db = await database;
    return await db.insert('default_prices', defaultPrice.toMap());
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

  Future<int> updateDefaultPrice(DefaultPrice defaultPrice,
      {required String franchiseeId}) async {
    if (franchiseeId.isEmpty || defaultPrice.franchiseeId != franchiseeId) {
      throw ArgumentError(
          'Default prices must belong to the active franchisee');
    }
    final db = await database;
    return await db.update(
      'default_prices',
      defaultPrice.toMap(),
      where: 'local_id = ? AND franchisee_id = ?',
      whereArgs: [defaultPrice.localId, franchiseeId],
    );
  }

  Future<int> deleteDefaultPrice(int localId,
      {required String franchiseeId}) async {
    final db = await database;
    return await db.update(
      'default_prices',
      {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
      where: 'local_id = ? AND franchisee_id = ?',
      whereArgs: [localId, franchiseeId],
    );
  }

  // Warranty CRUD
  Future<int> insertWarranty(Warranty warranty) async {
    final db = await database;
    return await db.insert('warranties', warranty.toMap());
  }

  Future<List<Warranty>> getWarrantiesByClientId(int clientId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('warranties',
        where: 'client_id = ? AND deleted_at IS NULL', whereArgs: [clientId]);
    return List.generate(maps.length, (i) => Warranty.fromMap(maps[i]));
  }

  Future<Warranty?> getWarrantyByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db
        .query('warranties', where: 'remote_id = ?', whereArgs: [remoteId]);
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
    return db.delete(
      'warranties',
      where: 'local_id = ?',
      whereArgs: [localId],
    );
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
    final List<Map<String, dynamic>> maps = await db.query('proposals',
        where: 'client_id = ? AND deleted_at IS NULL', whereArgs: [clientId]);
    return List.generate(maps.length, (i) => Proposal.fromMap(maps[i]));
  }

  Future<Proposal?> getProposalByRemoteId(String remoteId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db
        .query('proposals', where: 'remote_id = ?', whereArgs: [remoteId]);
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
  Future<List<Client>> getDirtyClients() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('clients', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => Client.fromMap(maps[i]));
  }

  Future<List<Item>> getDirtyItems() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('items', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => Item.fromMap(maps[i]));
  }

  Future<List<Rectangle>> getDirtyRectangles() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('rectangles', where: 'is_dirty = 1');
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
      String remoteId, String franchiseeId) async {
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
    final List<Map<String, dynamic>> maps =
        await db.query('warranties', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => Warranty.fromMap(maps[i]));
  }

  Future<List<Proposal>> getDirtyProposals() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('proposals', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => Proposal.fromMap(maps[i]));
  }

  Future<void> markAsSynced(String table, String remoteId,
      {String? franchiseeId}) async {
    final db = await database;
    final tenantScoped = table == 'default_prices';
    if (tenantScoped && (franchiseeId == null || franchiseeId.isEmpty)) {
      throw ArgumentError('A franchisee is required for default-price sync');
    }
    await db.update(
      table,
      {'is_dirty': 0},
      where: tenantScoped
          ? 'remote_id = ? AND franchisee_id = ?'
          : 'remote_id = ?',
      whereArgs: tenantScoped ? [remoteId, franchiseeId] : [remoteId],
    );
  }
}
