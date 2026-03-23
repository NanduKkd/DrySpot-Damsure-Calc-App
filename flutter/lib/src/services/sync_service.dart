import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'db_service.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';

class SyncService {
  final ApiService apiService;
  final DbService dbService;

  SyncService({required this.apiService, DbService? dbService}) : dbService = dbService ?? DbService();

  Future<void> sync() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncTime = prefs.getString('last_sync_time');

    // 1. Gather local changes
    final dirtyClients = await dbService.getDirtyClients();
    final dirtyItems = await dbService.getDirtyItems();
    final dirtyRectangles = await dbService.getDirtyRectangles();

    // Wait for mapping if they were async
    final resolvedItems = await Future.wait(dirtyItems.map((i) async {
        final client = (await dbService.getClients()).firstWhere((c) => c.localId == i.clientId);
        var map = i.toMap();
        map['remote_id'] = i.remoteId;
        map['client_id'] = client.remoteId;
        return map;
    }));

    final resolvedRectangles = await Future.wait(dirtyRectangles.map((r) async {
        // Find item
        final db = await dbService.database;
        final List<Map<String, dynamic>> maps = await db.query('items', where: 'local_id = ?', whereArgs: [r.itemId]);
        final itemRemoteId = maps.first['remote_id'];
        var map = r.toMap();
        map['remote_id'] = r.remoteId;
        map['item_id'] = itemRemoteId;
        return map;
    }));

    final syncData = {
      'last_sync_time': lastSyncTime,
      'changes': {
        'clients': dirtyClients.map((c) {
            var map = c.toMap();
            map['remote_id'] = c.remoteId;
            return map;
        }).toList(),
        'items': resolvedItems,
        'rectangles': resolvedRectangles,
      }
    };

    // 2. Send to server and get updates
    final response = await apiService.sync(syncData);
    final serverTime = response['server_time'];
    final updates = response['updates'];

    // 3. Apply updates to local DB
    if (updates != null) {
      // Clients
      for (var clientMap in updates['clients']) {
        final remoteId = clientMap['remote_id'];
        final existingClient = await dbService.getClientByRemoteId(remoteId);
        
        if (clientMap['deleted_at'] != null) {
            if (existingClient != null) {
                // In a real app, we might want to hard delete if it's already soft deleted on server
                // For now, just mark it.
                await dbService.softDeleteClient(existingClient.localId!);
            }
        } else {
            final client = Client.fromMap(clientMap);
            if (existingClient != null) {
                await dbService.updateClient(client.copyWith(localId: existingClient.localId, isDirty: false));
            } else {
                await dbService.insertClient(client.copyWith(isDirty: false));
            }
        }
      }

      // Items
      for (var itemMap in updates['items']) {
          final remoteId = itemMap['remote_id'];
          final existingItem = await dbService.getItemByRemoteId(remoteId);
          final client = await dbService.getClientByRemoteId(itemMap['client_id']);
          
          if (client != null) {
              if (itemMap['deleted_at'] != null) {
                  if (existingItem != null) {
                      await dbService.softDeleteItem(existingItem.localId!);
                  }
              } else {
                  final item = Item.fromMap(itemMap).copyWith(clientId: client.localId, isDirty: false);
                  if (existingItem != null) {
                      await dbService.updateItem(item.copyWith(localId: existingItem.localId));
                  } else {
                      await dbService.insertItem(item);
                  }
              }
          }
      }

      // Rectangles
      for (var rectMap in updates['rectangles']) {
          final remoteId = rectMap['remote_id'];
          final existingRect = await dbService.getRectangleByRemoteId(remoteId);
          final item = await dbService.getItemByRemoteId(rectMap['item_id']);

          if (item != null) {
              if (rectMap['deleted_at'] != null) {
                  if (existingRect != null) {
                      await dbService.softDeleteRectangle(existingRect.localId!);
                  }
              } else {
                  final rect = Rectangle.fromMap(rectMap).copyWith(itemId: item.localId, isDirty: false);
                  if (existingRect != null) {
                      await dbService.updateRectangle(rect.copyWith(localId: existingRect.localId));
                  } else {
                      await dbService.insertRectangle(rect);
                  }
              }
          }
      }
    }

    // 4. Clear dirty flags for records we just sent
    for (var c in dirtyClients) {
        await dbService.markAsSynced('clients', c.remoteId);
    }
    for (var i in dirtyItems) {
        await dbService.markAsSynced('items', i.remoteId);
    }
    for (var r in dirtyRectangles) {
        await dbService.markAsSynced('rectangles', r.remoteId);
    }

    // 5. Save sync time
    await prefs.setString('last_sync_time', serverTime);
  }
}
