import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'db_service.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/warranty.dart';
import '../models/proposal.dart';

class SyncService {
  final ApiService apiService;
  final DbService dbService;

  SyncService({required this.apiService, DbService? dbService})
      : dbService = dbService ?? DbService();

  String _syncKeyForFranchisee(String? franchiseeId) {
    if (franchiseeId == null || franchiseeId.isEmpty) {
      return 'last_sync_time';
    }
    return 'last_sync_time_$franchiseeId';
  }

  Future<void> sync() async {
    final prefs = await SharedPreferences.getInstance();
    final activeFranchiseeId = prefs.getString('franchisee_id')?.trim();
    final shouldFilterByFranchise =
        activeFranchiseeId != null && activeFranchiseeId.isNotEmpty;
    final syncTimeKey = _syncKeyForFranchisee(activeFranchiseeId);
    final lastSyncTime =
        prefs.getString(syncTimeKey) ?? prefs.getString('last_sync_time');

    // Build active-session maps once so all payloads resolve IDs consistently.
    final allClients = await dbService.getClients();
    final activeClients = shouldFilterByFranchise
        ? allClients
            .where((client) => client.franchiseeId == activeFranchiseeId)
            .toList()
        : allClients;
    final clientsByLocalId = <int, Client>{
      for (final client in activeClients)
        if (client.localId != null) client.localId!: client,
    };
    final itemsByLocalId = <int, Item>{
      for (final client in activeClients)
        for (final item in client.items)
          if (item.localId != null) item.localId!: item,
    };
    final activeClientLocalIds = clientsByLocalId.keys.toSet();
    final activeItemLocalIds = itemsByLocalId.keys.toSet();

    // 1. Gather local changes
    final dirtyClients = (await dbService.getDirtyClients())
        .where((client) =>
            !shouldFilterByFranchise ||
            client.franchiseeId == activeFranchiseeId)
        .toList();
    final dirtyItems = (await dbService.getDirtyItems())
        .where((item) =>
            !shouldFilterByFranchise ||
            (item.clientId != null && activeClientLocalIds.contains(item.clientId)))
        .toList();
    final dirtyRectangles = (await dbService.getDirtyRectangles())
        .where((rect) =>
            !shouldFilterByFranchise ||
            (rect.itemId != null && activeItemLocalIds.contains(rect.itemId)))
        .toList();
    final dirtyWarranties = (await dbService.getDirtyWarranties())
        .where((warranty) =>
            !shouldFilterByFranchise ||
            activeClientLocalIds.contains(warranty.clientId))
        .toList();
    final dirtyProposals = (await dbService.getDirtyProposals())
        .where((proposal) =>
            !shouldFilterByFranchise ||
            activeClientLocalIds.contains(proposal.clientId))
        .toList();

    final itemsToSync = <Item>[];
    final resolvedItems = <Map<String, dynamic>>[];
    for (final item in dirtyItems) {
      final client = item.clientId == null ? null : clientsByLocalId[item.clientId!];
      if (client == null || client.remoteId.isEmpty) {
        continue;
      }

      final map = item.toMap();
      map['remote_id'] = item.remoteId;
      map['client_id'] = client.remoteId;
      resolvedItems.add(map);
      itemsToSync.add(item);
    }

    final rectanglesToSync = <Rectangle>[];
    final resolvedRectangles = <Map<String, dynamic>>[];
    for (final rect in dirtyRectangles) {
      final item = rect.itemId == null ? null : itemsByLocalId[rect.itemId!];
      if (item == null || item.remoteId.isEmpty) {
        continue;
      }

      final map = rect.toMap();
      map['remote_id'] = rect.remoteId;
      map['item_id'] = item.remoteId;
      resolvedRectangles.add(map);
      rectanglesToSync.add(rect);
    }

    final warrantiesToSync = <Warranty>[];
    final resolvedWarranties = <Map<String, dynamic>>[];
    for (final warranty in dirtyWarranties) {
      final client = clientsByLocalId[warranty.clientId];
      if (client == null || client.remoteId.isEmpty) {
        continue;
      }

      final map = warranty.toMap();
      map['remote_id'] = warranty.remoteId;
      map['client_id'] = client.remoteId;
      resolvedWarranties.add(map);
      warrantiesToSync.add(warranty);
    }

    final proposalsToSync = <Proposal>[];
    final resolvedProposals = <Map<String, dynamic>>[];
    for (final proposal in dirtyProposals) {
      final client = clientsByLocalId[proposal.clientId];
      if (client == null || client.remoteId.isEmpty) {
        continue;
      }

      final map = proposal.toMap();
      map['remote_id'] = proposal.remoteId;
      map['client_id'] = client.remoteId;
      resolvedProposals.add(map);
      proposalsToSync.add(proposal);
    }

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
        'warranties': resolvedWarranties,
        'proposals': resolvedProposals,
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
            await dbService.softDeleteClient(existingClient.localId!);
          }
        } else {
          final client = Client.fromMap(clientMap);
          if (existingClient != null) {
            await dbService.updateClient(
                client.copyWith(localId: existingClient.localId, isDirty: false));
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
            final item = Item.fromMap(itemMap)
                .copyWith(clientId: client.localId, isDirty: false);
            if (existingItem != null) {
              await dbService
                  .updateItem(item.copyWith(localId: existingItem.localId));
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
            final rect = Rectangle.fromMap(rectMap)
                .copyWith(itemId: item.localId, isDirty: false);
            if (existingRect != null) {
              await dbService
                  .updateRectangle(rect.copyWith(localId: existingRect.localId));
            } else {
              await dbService.insertRectangle(rect);
            }
          }
        }
      }

      // Warranties
      for (var warrantyMap in updates['warranties'] ?? []) {
        final remoteId = warrantyMap['remote_id'];
        final existingWarranty = await dbService.getWarrantyByRemoteId(remoteId);
        final client =
            await dbService.getClientByRemoteId(warrantyMap['client_id']);

        if (client != null) {
          if (warrantyMap['deleted_at'] != null) {
            if (existingWarranty != null) {
              await dbService.softDeleteWarranty(existingWarranty.localId!);
            }
          } else {
            final warranty = Warranty.fromMap(warrantyMap)
                .copyWith(clientId: client.localId!, isDirty: false);
            if (existingWarranty != null) {
              await dbService.updateWarranty(
                  warranty.copyWith(localId: existingWarranty.localId));
            } else {
              await dbService.insertWarranty(warranty);
            }
          }
        }
      }

      // Proposals
      for (var proposalMap in updates['proposals'] ?? []) {
        final remoteId = proposalMap['remote_id'];
        final existingProposal = await dbService.getProposalByRemoteId(remoteId);
        final client =
            await dbService.getClientByRemoteId(proposalMap['client_id']);

        if (client != null) {
          if (proposalMap['deleted_at'] != null) {
            if (existingProposal != null) {
              await dbService.softDeleteProposal(existingProposal.localId!);
            }
          } else {
            final proposal = Proposal.fromMap(proposalMap)
                .copyWith(clientId: client.localId!, isDirty: false);
            if (existingProposal != null) {
              await dbService.updateProposal(
                  proposal.copyWith(localId: existingProposal.localId));
            } else {
              await dbService.insertProposal(proposal);
            }
          }
        }
      }
    }

    // 4. Clear dirty flags for records we just sent
    for (var c in dirtyClients) {
      await dbService.markAsSynced('clients', c.remoteId);
    }
    for (var i in itemsToSync) {
      await dbService.markAsSynced('items', i.remoteId);
    }
    for (var r in rectanglesToSync) {
      await dbService.markAsSynced('rectangles', r.remoteId);
    }
    for (var w in warrantiesToSync) {
      await dbService.markAsSynced('warranties', w.remoteId);
    }
    for (var p in proposalsToSync) {
      await dbService.markAsSynced('proposals', p.remoteId);
    }

    // 5. Save sync time
    await prefs.setString(syncTimeKey, serverTime);
    if (syncTimeKey != 'last_sync_time') {
      await prefs.remove('last_sync_time');
    }
  }
}
