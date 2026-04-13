import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/default_price.dart';
import '../models/warranty.dart';
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
      version: 6,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
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
        is_dirty INTEGER DEFAULT 1,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        FOREIGN KEY (item_id) REFERENCES items (local_id) ON DELETE CASCADE
      )
    ''');

    await _createDefaultPricesTable(db);
    await _createWarrantiesTable(db);
    await _createProposalsTable(db);
  }

  Future _createDefaultPricesTable(Database db) async {
    await db.execute('''
      CREATE TABLE default_prices (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_id TEXT UNIQUE,
        price REAL NOT NULL,
        enabled INTEGER DEFAULT 1,
        is_dirty INTEGER DEFAULT 1,
        updated_at TEXT NOT NULL,
        deleted_at TEXT
      )
    ''');
  }

  Future _createWarrantiesTable(Database db) async {
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
        deleted_at TEXT,
        FOREIGN KEY (client_id) REFERENCES clients (local_id) ON DELETE CASCADE
      )
    ''');
  }

  Future _createProposalsTable(Database db) async {
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
    final List<Map<String, dynamic>> maps = await db.query('clients', where: 'deleted_at IS NULL');
    
    List<Client> clients = [];
    for (var map in maps) {
      final items = await getItemsByClientId(map['local_id']);
      clients.add(Client.fromMap(map, items: items));
    }
    return clients;
  }

  Future<Client?> getClientByRemoteId(String remoteId) async {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('clients', where: 'remote_id = ?', whereArgs: [remoteId]);
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
    final List<Map<String, dynamic>> maps = await db.query('items', where: 'client_id = ? AND deleted_at IS NULL', whereArgs: [clientId]);
    
    List<Item> items = [];
    for (var map in maps) {
      final rectangles = await getRectanglesByItemId(map['local_id']);
      items.add(Item.fromMap(map, rectangles: rectangles));
    }
    return items;
  }

  Future<Item?> getItemByRemoteId(String remoteId) async {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('items', where: 'remote_id = ?', whereArgs: [remoteId]);
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
    final List<Map<String, dynamic>> maps = await db.query('rectangles', where: 'item_id = ? AND deleted_at IS NULL', whereArgs: [itemId]);
    return List.generate(maps.length, (i) => Rectangle.fromMap(maps[i]));
  }

  Future<Rectangle?> getRectangleByRemoteId(String remoteId) async {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query('rectangles', where: 'remote_id = ?', whereArgs: [remoteId]);
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
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  // DefaultPrice CRUD
  Future<int> insertDefaultPrice(DefaultPrice defaultPrice) async {
    final db = await database;
    return await db.insert('default_prices', defaultPrice.toMap());
  }

  Future<List<DefaultPrice>> getDefaultPrices() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('default_prices',
        where: 'deleted_at IS NULL', orderBy: 'updated_at ASC');
    return List.generate(maps.length, (i) => DefaultPrice.fromMap(maps[i]));
  }

  Future<int> updateDefaultPrice(DefaultPrice defaultPrice) async {
    final db = await database;
    return await db.update(
      'default_prices',
      defaultPrice.toMap(),
      where: 'local_id = ?',
      whereArgs: [defaultPrice.localId],
    );
  }

  Future<int> deleteDefaultPrice(int localId) async {
    final db = await database;
    return await db.update(
      'default_prices',
      {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
      where: 'local_id = ?',
      whereArgs: [localId],
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

  Future<int> softDeleteWarranty(int localId) async {
    final db = await database;
    return await db.update(
      'warranties',
      {'deleted_at': DateTime.now().toIso8601String(), 'is_dirty': 1},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
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
    final List<Map<String, dynamic>> maps = await db.query('clients', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => Client.fromMap(maps[i]));
  }

  Future<List<Item>> getDirtyItems() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('items', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => Item.fromMap(maps[i]));
  }

  Future<List<Rectangle>> getDirtyRectangles() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('rectangles', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => Rectangle.fromMap(maps[i]));
  }

  Future<List<DefaultPrice>> getDirtyDefaultPrices() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('default_prices', where: 'is_dirty = 1');
    return List.generate(maps.length, (i) => DefaultPrice.fromMap(maps[i]));
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

  Future<void> markAsSynced(String table, String remoteId) async {
    final db = await database;
    await db.update(table, {'is_dirty': 0}, where: 'remote_id = ?', whereArgs: [remoteId]);
  }
}
