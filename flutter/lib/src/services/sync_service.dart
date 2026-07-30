import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'api_service.dart';
import 'db_service.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/default_price.dart';
import '../models/warranty.dart';
import '../models/warranty_deletion_tombstone.dart';
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

  Set<String> _outcomeIds(dynamic outcomes, String collection, String status) {
    final values = outcomes is Map ? outcomes[collection] : null;
    if (values is! List) return {};
    return values
        .whereType<Map>()
        .where((outcome) => outcome['status'] == status)
        .map((outcome) => outcome['remote_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<void> sync() async {
    final prefs = await SharedPreferences.getInstance();
    final franchiseeId = prefs.getString('franchisee_id')?.trim();
    final hasTenant = franchiseeId != null && franchiseeId.isNotEmpty;
    final supportsV2 = hasTenant && await dbService.supportsSyncV2();
    if (supportsV2 && await dbService.isSyncV2Enabled(franchiseeId)) {
      await _syncV2(franchiseeId, activateProtocol: false);
      return;
    }
    if (supportsV2) {
      await dbService.claimLegacyDefaultPrices(franchiseeId);
    }

    // The legacy writer drains first. A v2 state bit is persisted only in the
    // same SQLite transaction that applies a successful cursor-zero snapshot.
    await _syncV1();
    if (!supportsV2) return;
    try {
      await _syncV2(franchiseeId, activateProtocol: true);
    } catch (_) {
      // During the compatibility window an old server may not expose /sync/v2.
      // The successful v1 drain remains durable, while no v2 cursor/state is
      // persisted and the next explicit sync retries the bootstrap safely.
    }
  }

  Future<void> _syncV1() async {
    final prefs = await SharedPreferences.getInstance();
    final activeFranchiseeId = prefs.getString('franchisee_id')?.trim();
    final shouldFilterByFranchise =
        activeFranchiseeId != null && activeFranchiseeId.isNotEmpty;
    final syncTimeKey = _syncKeyForFranchisee(activeFranchiseeId);
    final lastSyncTime =
        prefs.getString(syncTimeKey) ?? prefs.getString('last_sync_time');
    final warrantyTombstoneCursor = shouldFilterByFranchise
        ? await dbService.getWarrantyTombstoneCursor(activeFranchiseeId)
        : '0';

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
        .where(
          (client) =>
              !shouldFilterByFranchise ||
              client.franchiseeId == activeFranchiseeId,
        )
        .toList();
    final dirtyItems = (await dbService.getDirtyItems())
        .where(
          (item) =>
              !shouldFilterByFranchise ||
              (item.clientId != null &&
                  activeClientLocalIds.contains(item.clientId)),
        )
        .toList();
    final dirtyRectangles = (await dbService.getDirtyRectangles())
        .where(
          (rect) =>
              !shouldFilterByFranchise ||
              (rect.itemId != null && activeItemLocalIds.contains(rect.itemId)),
        )
        .toList();
    final dirtyDefaultPrices = shouldFilterByFranchise
        ? await dbService.getDirtyDefaultPrices(activeFranchiseeId)
        : <DefaultPrice>[];
    final dirtyWarranties = (await dbService.getDirtyWarranties())
        .where(
          (warranty) =>
              !shouldFilterByFranchise ||
              activeClientLocalIds.contains(warranty.clientId),
        )
        .toList();
    final dirtyProposals = (await dbService.getDirtyProposals())
        .where(
          (proposal) =>
              !shouldFilterByFranchise ||
              activeClientLocalIds.contains(proposal.clientId),
        )
        .toList();

    final itemsToSync = <Item>[];
    final resolvedItems = <Map<String, dynamic>>[];
    for (final item in dirtyItems) {
      final client =
          item.clientId == null ? null : clientsByLocalId[item.clientId!];
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
      map['version'] = warranty.version;
      map.remove('server_version');
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

    final clientsToMarkSynced = <Client>[];
    final resolvedClients = <Map<String, dynamic>>[];
    final pendingLocalPhotosByClientRemoteId = <String, List<String>>{};
    for (final client in dirtyClients) {
      final canonicalPhotos = <String>[];
      var uploadFailed = false;
      for (var photoIndex = 0;
          photoIndex < client.photos.length;
          photoIndex++) {
        final photo = client.photos[photoIndex];
        if (photo.startsWith('/api/photos/client/')) {
          canonicalPhotos.add(photo);
          continue;
        }
        if (photo.startsWith('http://') || photo.startsWith('https://')) {
          final relativePath = Uri.tryParse(photo)?.path;
          if (relativePath != null &&
              relativePath.startsWith('/api/photos/client/')) {
            canonicalPhotos.add(relativePath);
          }
          continue;
        }

        try {
          canonicalPhotos.add(
            await apiService.uploadClientPhoto(client.remoteId, photo),
          );
        } catch (_) {
          uploadFailed = true;
          pendingLocalPhotosByClientRemoteId[client.remoteId] = [
            for (final pendingPhoto in client.photos.skip(photoIndex))
              if (!pendingPhoto.startsWith('/api/photos/client/') &&
                  !pendingPhoto.startsWith('http://') &&
                  !pendingPhoto.startsWith('https://'))
                pendingPhoto,
          ];
          break;
        }
      }

      // A partial canonical list is not an authoritative photo replacement.
      // Omitting the client mutation keeps every server photo intact while the
      // local client remains dirty and retries its pending uploads later.
      if (uploadFailed) {
        continue;
      }

      final photosChanged =
          canonicalPhotos.join('|') != client.photos.join('|');
      final clientForPayload = client.copyWith(
        photos: canonicalPhotos,
        isDirty: true,
        updatedAt: photosChanged ? DateTime.now() : client.updatedAt,
      );
      if (canonicalPhotos.length == client.photos.length) {
        if (photosChanged) {
          await dbService.updateClient(clientForPayload);
        }
        clientsToMarkSynced.add(clientForPayload);
      }
      final map = clientForPayload.toMap();
      map['remote_id'] = clientForPayload.remoteId;
      resolvedClients.add(map);
    }

    final syncData = {
      'last_sync_time': lastSyncTime,
      'warranty_tombstone_cursor': warrantyTombstoneCursor,
      'changes': {
        'clients': resolvedClients,
        'items': resolvedItems,
        'rectangles': resolvedRectangles,
        'default_prices':
            dirtyDefaultPrices.map((price) => price.toJson()).toList(),
        'warranties': resolvedWarranties,
        'proposals': resolvedProposals,
      },
    };

    // 2. Send to server and get updates
    final response = await apiService.sync(syncData);
    final serverTime = response['server_time'];
    final updates = response['updates'];
    final outcomes = response['outcomes'];
    final appliedClients = _outcomeIds(outcomes, 'clients', 'applied');
    final appliedItems = _outcomeIds(outcomes, 'items', 'applied');
    final appliedRectangles = _outcomeIds(outcomes, 'rectangles', 'applied');
    final appliedDefaultPrices = _outcomeIds(
      outcomes,
      'default_prices',
      'applied',
    );
    final appliedWarranties = _outcomeIds(outcomes, 'warranties', 'applied');
    final tombstonedWarranties = _outcomeIds(
      outcomes,
      'warranties',
      'tombstoned',
    );
    final appliedProposals = _outcomeIds(outcomes, 'proposals', 'applied');
    final submittedWarrantiesByRemoteId = {
      for (final warranty in warrantiesToSync) warranty.remoteId: warranty,
    };

    if (shouldFilterByFranchise) {
      final nextCursor = response['warranty_tombstone_cursor']?.toString();
      final parsedCursor =
          nextCursor == null ? null : BigInt.tryParse(nextCursor);
      if (parsedCursor == null ||
          parsedCursor.isNegative ||
          parsedCursor > BigInt.parse('9223372036854775807')) {
        throw const ApiException(
          'Sync returned an invalid warranty tombstone cursor.',
        );
      }
      final tombstones = <WarrantyDeletionTombstone>[];
      if (updates is Map) {
        for (final rawTombstone in updates['warranty_tombstones'] ?? const []) {
          tombstones.add(
            WarrantyDeletionTombstone.fromServer(
              Map<String, dynamic>.from(rawTombstone as Map),
              franchiseeId: activeFranchiseeId,
            ),
          );
        }
      }
      // Deletions and their acknowledgement cursor are one durable SQLite
      // commit, so a crash cannot advance past an unapplied tombstone.
      await dbService.applyWarrantyTombstonesAndCursor(
        tombstones,
        franchiseeId: activeFranchiseeId,
        cursor: parsedCursor.toString(),
      );
    }

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
          final pendingLocalPhotos =
              pendingLocalPhotosByClientRemoteId[remoteId] ?? const <String>[];
          final clientFromServer = pendingLocalPhotos.isEmpty
              ? client.copyWith(isDirty: false)
              : client.copyWith(
                  photos: [
                    ...client.photos,
                    for (final localPhoto in pendingLocalPhotos)
                      if (!client.photos.contains(localPhoto)) localPhoto,
                  ],
                  isDirty: true,
                );
          if (existingClient != null) {
            await dbService.updateClient(
              clientFromServer.copyWith(localId: existingClient.localId),
            );
          } else {
            await dbService.insertClient(clientFromServer);
          }
        }
      }

      // Items
      for (var itemMap in updates['items']) {
        final remoteId = itemMap['remote_id'];
        final existingItem = await dbService.getItemByRemoteId(remoteId);
        final client = await dbService.getClientByRemoteId(
          itemMap['client_id'],
        );

        if (client != null) {
          if (itemMap['deleted_at'] != null) {
            if (existingItem != null) {
              await dbService.softDeleteItem(existingItem.localId!);
            }
          } else {
            final item = Item.fromMap(
              itemMap,
            ).copyWith(clientId: client.localId, isDirty: false);
            if (existingItem != null) {
              await dbService.updateItem(
                item.copyWith(localId: existingItem.localId),
              );
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
            final rect = Rectangle.fromMap(
              rectMap,
            ).copyWith(itemId: item.localId, isDirty: false);
            if (existingRect != null) {
              await dbService.updateRectangle(
                rect.copyWith(localId: existingRect.localId),
              );
            } else {
              await dbService.insertRectangle(rect);
            }
          }
        }
      }

      // Warranties
      if (shouldFilterByFranchise) {
        for (final priceMap in updates['default_prices'] ?? []) {
          final remoteId = priceMap['remote_id']?.toString();
          if (remoteId == null || remoteId.isEmpty) continue;

          final existing = await dbService.getDefaultPriceByRemoteId(
            remoteId,
            activeFranchiseeId,
          );
          if (priceMap['deleted_at'] != null) {
            if (existing != null && existing.localId != null) {
              await dbService.deleteDefaultPrice(
                existing.localId!,
                franchiseeId: activeFranchiseeId,
              );
            }
            continue;
          }

          final price = DefaultPrice.fromJson(
            priceMap,
          ).copyWith(franchiseeId: activeFranchiseeId, isDirty: false);
          if (existing == null) {
            await dbService.insertDefaultPrice(
              price,
              franchiseeId: activeFranchiseeId,
            );
          } else {
            await dbService.updateDefaultPrice(
              price.copyWith(localId: existing.localId),
              franchiseeId: activeFranchiseeId,
            );
          }
        }
      }

      // Warranties
      for (var warrantyMap in updates['warranties'] ?? []) {
        final remoteId = warrantyMap['remote_id'];
        if (shouldFilterByFranchise &&
            await dbService.hasWarrantyTombstone(
              remoteId,
              franchiseeId: activeFranchiseeId,
            )) {
          continue;
        }
        final existingWarranty = await dbService.getWarrantyByRemoteId(
          remoteId,
        );
        final client = await dbService.getClientByRemoteId(
          warrantyMap['client_id'],
        );

        if (client != null) {
          if (warrantyMap['deleted_at'] != null) {
            // APP-110 never treats a soft-deleted warranty row as permanent
            // deletion. Only the sequenced tombstone stream can remove it.
            continue;
          } else {
            final warranty = Warranty.fromMap(
              warrantyMap,
            ).copyWith(clientId: client.localId!, isDirty: false);
            final submitted = submittedWarrantiesByRemoteId[remoteId];
            if (existingWarranty != null) {
              if (submitted == null) {
                await dbService.updateWarranty(
                  warranty.copyWith(localId: existingWarranty.localId),
                );
              } else if (appliedWarranties.contains(remoteId)) {
                // Applying the server echo is itself compare-and-set. A local
                // edit made after request capture must survive both response
                // application and the later dirty-clear acknowledgement.
                await dbService.applyWarrantyFromServerIfUnchanged(
                  warranty.copyWith(localId: existingWarranty.localId),
                  submittedUpdatedAt: submitted.updatedAt.toIso8601String(),
                );
              }
            } else if (submitted == null) {
              await dbService.insertWarranty(warranty);
            }
          }
        }
      }

      // Proposals
      for (var proposalMap in updates['proposals'] ?? []) {
        final remoteId = proposalMap['remote_id'];
        final existingProposal = await dbService.getProposalByRemoteId(
          remoteId,
        );
        final client = await dbService.getClientByRemoteId(
          proposalMap['client_id'],
        );

        if (client != null) {
          if (proposalMap['deleted_at'] != null) {
            if (existingProposal != null) {
              await dbService.softDeleteProposal(existingProposal.localId!);
            }
          } else {
            final proposal = Proposal.fromMap(
              proposalMap,
            ).copyWith(clientId: client.localId!, isDirty: false);
            if (existingProposal != null) {
              await dbService.updateProposal(
                proposal.copyWith(localId: existingProposal.localId),
              );
            } else {
              await dbService.insertProposal(proposal);
            }
          }
        }
      }
    }

    // 4. Clear dirty flags for records we just sent
    for (var c in clientsToMarkSynced) {
      if (appliedClients.contains(c.remoteId)) {
        await dbService.markAsSynced(
          'clients',
          c.remoteId,
          submittedUpdatedAt: c.updatedAt.toIso8601String(),
        );
      }
    }
    for (var i in itemsToSync) {
      if (appliedItems.contains(i.remoteId)) {
        await dbService.markAsSynced(
          'items',
          i.remoteId,
          submittedUpdatedAt: i.updatedAt.toIso8601String(),
        );
      }
    }
    for (var r in rectanglesToSync) {
      if (appliedRectangles.contains(r.remoteId)) {
        await dbService.markAsSynced(
          'rectangles',
          r.remoteId,
          submittedUpdatedAt: r.updatedAt.toIso8601String(),
        );
      }
    }
    for (final price in dirtyDefaultPrices) {
      if (appliedDefaultPrices.contains(price.remoteId)) {
        await dbService.markAsSynced(
          'default_prices',
          price.remoteId,
          franchiseeId: activeFranchiseeId,
          submittedUpdatedAt: price.updatedAt.toIso8601String(),
        );
      }
    }
    for (var w in warrantiesToSync) {
      if (tombstonedWarranties.contains(w.remoteId)) {
        await dbService.hardDeleteWarrantyByRemoteId(w.remoteId);
      } else if (appliedWarranties.contains(w.remoteId)) {
        await dbService.markAsSynced(
          'warranties',
          w.remoteId,
          submittedUpdatedAt: w.updatedAt.toIso8601String(),
        );
      }
    }
    for (var p in proposalsToSync) {
      if (appliedProposals.contains(p.remoteId)) {
        await dbService.markAsSynced(
          'proposals',
          p.remoteId,
          submittedUpdatedAt: p.updatedAt.toIso8601String(),
        );
      }
    }

    // 5. Save sync time
    await prefs.setString(syncTimeKey, serverTime);
    if (syncTimeKey != 'last_sync_time') {
      await prefs.remove('last_sync_time');
    }
  }

  static const _v2Collections = <String>[
    'clients',
    'items',
    'rectangles',
    'default_prices',
  ];
  static final _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  ApiException _protocolError(String message) =>
      ApiException('Sync protocol error: $message');

  Map<String, dynamic> _v2Object(dynamic value, String label) {
    if (value is! Map) throw _protocolError('$label must be an object.');
    return Map<String, dynamic>.from(value);
  }

  BigInt _v2Decimal(dynamic value, String label, {bool allowZero = true}) {
    if (value is! String || !RegExp(r'^(0|[1-9]\d*)$').hasMatch(value)) {
      throw _protocolError('$label is not a canonical decimal string.');
    }
    final parsed = BigInt.parse(value);
    if ((!allowZero && parsed == BigInt.zero) ||
        parsed > BigInt.parse('9223372036854775807')) {
      throw _protocolError('$label is outside the supported range.');
    }
    return parsed;
  }

  String _v2Uuid(dynamic value, String label) {
    if (value is! String || !_uuidV4.hasMatch(value)) {
      throw _protocolError('$label is not a UUIDv4.');
    }
    return value.toLowerCase();
  }

  void _exactKeys(
    Map<String, dynamic> value,
    Set<String> allowed,
    Set<String> required,
    String label,
  ) {
    if (value.keys.any((key) => !allowed.contains(key)) ||
        required.any((key) => !value.containsKey(key))) {
      throw _protocolError('$label has an unexpected shape.');
    }
  }

  Map<String, dynamic> _validateV2Record(
    dynamic raw,
    String collection, {
    required BigInt responseCursor,
    required BigInt requestCursor,
    required String franchiseeId,
    required bool snapshot,
  }) {
    final record = _v2Object(raw, '$collection record');
    final common = <String>{
      'remote_id',
      'generation',
      'branch_seq',
      'operation',
      'writer_id',
      'change_id',
      'payload_hash',
      'row_cursor',
      'server_timestamp',
      'deleted_at',
      'payload',
    };
    final extra = collection == 'items' || collection == 'rectangles'
        ? {'parent_id'}
        : {'franchisee_id'};
    _exactKeys(
      record,
      {...common, ...extra},
      {...common, ...extra},
      '$collection record',
    );
    _v2Uuid(record['remote_id'], '$collection.remote_id');
    _v2Decimal(
      record['generation'],
      '$collection.generation',
      allowZero: false,
    );
    final branch = record['branch_seq'];
    if (branch is! int || branch < 1 || branch > 1000000) {
      throw _protocolError('$collection.branch_seq is invalid.');
    }
    if (record['operation'] != 'upsert' && record['operation'] != 'delete') {
      throw _protocolError('$collection.operation is invalid.');
    }
    _v2Uuid(record['writer_id'], '$collection.writer_id');
    _v2Uuid(record['change_id'], '$collection.change_id');
    if (record['payload_hash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(record['payload_hash'])) {
      throw _protocolError('$collection.payload_hash is invalid.');
    }
    final rowCursor = _v2Decimal(
      record['row_cursor'],
      '$collection.row_cursor',
      allowZero: false,
    );
    if (rowCursor > responseCursor ||
        (snapshot && rowCursor <= requestCursor)) {
      throw _protocolError('$collection.row_cursor is outside the snapshot.');
    }
    if (DateTime.tryParse(record['server_timestamp'].toString()) == null) {
      throw _protocolError('$collection.server_timestamp is invalid.');
    }
    final deletedAt = record['deleted_at'];
    if (deletedAt != null && DateTime.tryParse(deletedAt.toString()) == null) {
      throw _protocolError('$collection.deleted_at is invalid.');
    }
    if ((record['operation'] == 'delete') != (deletedAt != null)) {
      throw _protocolError('$collection deletion state is inconsistent.');
    }
    if (record['payload'] is! Map) {
      throw _protocolError('$collection.payload is invalid.');
    }
    final payload = Map<String, dynamic>.from(record['payload'] as Map);
    bool finiteNumber(dynamic value) => value is num && value.isFinite;
    switch (collection) {
      case 'clients':
        _exactKeys(
          payload,
          {
            'name',
            'address',
            'site_address',
            'email',
            'phone',
            'latitude',
            'longitude',
            'discounted_price',
          },
          {
            'name',
            'address',
            'site_address',
            'email',
            'phone',
            'latitude',
            'longitude',
            'discounted_price',
          },
          'clients.payload',
        );
        if (payload['name'] is! String ||
            (record['operation'] == 'upsert' &&
                (payload['name'] as String).trim().isEmpty) ||
            [
              payload['address'],
              payload['site_address'],
              payload['email'],
              payload['phone']
            ].any((value) => value != null && value is! String) ||
            [
              payload['latitude'],
              payload['longitude'],
              payload['discounted_price']
            ].any((value) => value != null && !finiteNumber(value))) {
          throw _protocolError('clients.payload contains invalid values.');
        }
      case 'items':
        _exactKeys(
          payload,
          {'name', 'price', 'enabled'},
          {'name', 'price', 'enabled'},
          'items.payload',
        );
        if (payload['name'] is! String ||
            !finiteNumber(payload['price']) ||
            payload['enabled'] is! bool) {
          throw _protocolError('items.payload contains invalid values.');
        }
      case 'rectangles':
        _exactKeys(
          payload,
          {'length', 'width'},
          {'length', 'width'},
          'rectangles.payload',
        );
        if (!finiteNumber(payload['length']) ||
            !finiteNumber(payload['width'])) {
          throw _protocolError('rectangles.payload contains invalid values.');
        }
      case 'default_prices':
        _exactKeys(
          payload,
          {'price', 'enabled'},
          {'price', 'enabled'},
          'default_prices.payload',
        );
        if (!finiteNumber(payload['price']) || payload['enabled'] is! bool) {
          throw _protocolError(
              'default_prices.payload contains invalid values.');
        }
    }
    if (collection == 'items' || collection == 'rectangles') {
      _v2Uuid(record['parent_id'], '$collection.parent_id');
    } else if (record['franchisee_id'] != franchiseeId) {
      throw _protocolError('$collection crossed tenant ownership.');
    }
    return record;
  }

  Future<Set<String>> _prepareV2ClientPhotos(String franchiseeId) async {
    final blocked = <String>{};
    final clients = (await dbService.getDirtyClients())
        .where((client) =>
            client.franchiseeId == franchiseeId && client.deletedAt == null)
        .toList();
    for (final client in clients) {
      final canonical = <String>[];
      var failed = false;
      for (final photo in client.photos) {
        if (photo.startsWith('/api/photos/client/')) {
          canonical.add(photo);
          continue;
        }
        final uri = Uri.tryParse(photo);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.path.startsWith('/api/photos/client/')) {
          canonical.add(uri.path);
          continue;
        }
        try {
          canonical.add(
            await apiService.uploadClientPhoto(client.remoteId, photo),
          );
        } catch (_) {
          failed = true;
          blocked.add(client.remoteId);
          break;
        }
      }
      if (!failed &&
          canonical.length == client.photos.length &&
          canonical.join('|') != client.photos.join('|')) {
        // Photos stay outside the LWW payload. Canonicalizing the local paths
        // creates a new exact pending change so an older in-flight outcome
        // cannot clear this row.
        await dbService.updateClient(
          client.copyWith(
            photos: canonical,
            isDirty: true,
            updatedAt: DateTime.now(),
          ),
        );
      }
    }
    return blocked;
  }

  Future<void> _syncV2(
    String franchiseeId, {
    required bool activateProtocol,
  }) async {
    final requestCursor = await dbService.getSyncV2Cursor(franchiseeId);
    final parsedRequestCursor = _v2Decimal(requestCursor, 'request_cursor');
    final warrantyCursor = await dbService.getWarrantyTombstoneCursor(
      franchiseeId,
    );
    _v2Decimal(warrantyCursor, 'warranty_tombstone_cursor');
    final blockedPhotoClients = await _prepareV2ClientPhotos(franchiseeId);
    final changes = await dbService.getPendingLwwChanges(franchiseeId);
    changes['clients']?.removeWhere(
      (change) => blockedPhotoClients.contains(change['remote_id']),
    );
    final requestId = const Uuid().v4();
    final submittedChangeIds = <String, Map<String, String>>{
      for (final collection in _v2Collections)
        collection: {
          for (final change in changes[collection] ?? const [])
            change['remote_id'].toString(): change['change_id'].toString(),
        },
    };
    final submittedByChangeId = <String, Map<String, dynamic>>{
      for (final collection in _v2Collections)
        for (final change in changes[collection] ?? const [])
          change['change_id'].toString(): {
            'collection': collection,
            'remote_id': change['remote_id'].toString(),
          },
    };
    final response = await apiService.syncV2({
      'protocol_version': 2,
      'request_id': requestId,
      'request_cursor': requestCursor,
      'warranty_tombstone_cursor': warrantyCursor,
      'changes': {
        for (final collection in _v2Collections)
          collection: changes[collection] ?? const [],
      },
    });

    _exactKeys(
      response,
      {
        'protocol_version',
        'request_id',
        'response_cursor',
        'warranty_tombstone_cursor',
        'outcomes',
        'warnings',
        'updates',
      },
      {
        'protocol_version',
        'request_id',
        'response_cursor',
        'warranty_tombstone_cursor',
        'outcomes',
        'warnings',
        'updates',
      },
      'response',
    );
    if (response['protocol_version'] != 2 ||
        response['request_id'] != requestId) {
      throw _protocolError('response identity does not match the request.');
    }
    final responseCursor = _v2Decimal(
      response['response_cursor'],
      'response_cursor',
    );
    if (responseCursor < parsedRequestCursor) {
      throw _protocolError('response_cursor moved backwards.');
    }
    final parsedWarrantyCursor = _v2Decimal(
      response['warranty_tombstone_cursor'],
      'warranty_tombstone_cursor',
    );
    final outcomes = _v2Object(response['outcomes'], 'outcomes');
    _exactKeys(
      outcomes,
      _v2Collections.toSet(),
      _v2Collections.toSet(),
      'outcomes',
    );
    if (response['warnings'] is! List) {
      throw _protocolError('warnings must be a list.');
    }
    for (final rawWarning in response['warnings'] as List) {
      final warning = _v2Object(rawWarning, 'warning');
      _exactKeys(
        warning,
        {'code', 'change_id', 'reason'},
        {'code', 'change_id', 'reason'},
        'warning',
      );
      if (warning['code'] != 'device_timestamp_discarded' ||
          (warning['reason'] != 'invalid' && warning['reason'] != 'future')) {
        throw _protocolError('warning is invalid.');
      }
      final warningChangeId =
          _v2Uuid(warning['change_id'], 'warning.change_id');
      if (!submittedByChangeId.containsKey(warningChangeId)) {
        throw _protocolError('warning references an unrelated change.');
      }
    }
    final outcomeStatuses = <String, String>{};
    final authoritative = <String, List<Map<String, dynamic>>>{
      for (final collection in _v2Collections) collection: [],
    };
    final seenOutcomes = <String>{};
    const statuses = {
      'applied',
      'already_applied',
      'superseded',
      'rejected',
      'permanently_deleted',
      'unauthorized',
    };
    const reasonCodes = {
      'upsert_applied',
      'delete_applied',
      'already_applied',
      'delete_wins',
      'version_superseded',
      'future_base_version',
      'change_id_reused',
      'parent_required',
      'parent_unavailable',
      'immutable_parent',
      'invalid_payload',
      'server_field_forbidden',
      'unknown_field',
      'not_authorized',
    };
    for (final collection in _v2Collections) {
      final collectionOutcomes = outcomes[collection];
      if (collectionOutcomes is! List) {
        throw _protocolError('$collection outcomes must be a list.');
      }
      for (final rawOutcome in collectionOutcomes) {
        final result = _v2Object(rawOutcome, '$collection outcome');
        _exactKeys(
          result,
          {'change_id', 'remote_id', 'status', 'reason_code', 'authoritative'},
          {'change_id', 'remote_id', 'status', 'reason_code'},
          '$collection outcome',
        );
        final changeId = _v2Uuid(
          result['change_id'],
          '$collection outcome change_id',
        );
        final remoteId = _v2Uuid(
          result['remote_id'],
          '$collection outcome remote_id',
        );
        final submitted = submittedByChangeId[changeId];
        if (submitted == null ||
            submitted['collection'] != collection ||
            submitted['remote_id'] != remoteId ||
            !seenOutcomes.add(changeId)) {
          throw _protocolError('$collection returned an unrelated outcome.');
        }
        if (!statuses.contains(result['status']) ||
            result['reason_code'] is! String ||
            !reasonCodes.contains(result['reason_code'])) {
          throw _protocolError('$collection outcome status is invalid.');
        }
        if ({
              'applied',
              'already_applied',
              'superseded',
            }.contains(result['status']) &&
            result['authoritative'] == null) {
          throw _protocolError('$collection omitted authoritative state.');
        }
        outcomeStatuses[changeId] = result['status'] as String;
        if (result['authoritative'] != null) {
          authoritative[collection]!.add(
            _validateV2Record(
              result['authoritative'],
              collection,
              responseCursor: responseCursor,
              requestCursor: parsedRequestCursor,
              franchiseeId: franchiseeId,
              snapshot: false,
            ),
          );
        }
      }
    }
    if (seenOutcomes.length != submittedByChangeId.length) {
      throw _protocolError('the server omitted one or more change outcomes.');
    }

    final updates = _v2Object(response['updates'], 'updates');
    _exactKeys(
      updates,
      {..._v2Collections, 'warranty_tombstones'},
      {..._v2Collections, 'warranty_tombstones'},
      'updates',
    );
    final records = <String, List<Map<String, dynamic>>>{
      for (final collection in _v2Collections) collection: [],
    };
    for (final collection in _v2Collections) {
      final rawRecords = updates[collection];
      if (rawRecords is! List) {
        throw _protocolError('$collection updates must be a list.');
      }
      final byRemoteId = <String, Map<String, dynamic>>{};
      for (final rawRecord in rawRecords) {
        final record = _validateV2Record(
          rawRecord,
          collection,
          responseCursor: responseCursor,
          requestCursor: parsedRequestCursor,
          franchiseeId: franchiseeId,
          snapshot: true,
        );
        final remoteId = record['remote_id'] as String;
        if (byRemoteId.containsKey(remoteId)) {
          throw _protocolError('$collection contains a duplicate update.');
        }
        byRemoteId[remoteId] = record;
      }
      // A superseded or already-applied change may reference an authoritative
      // row older than the pull interval. Use it only when the interval did not
      // already contain the final record.
      for (final record in authoritative[collection]!) {
        byRemoteId.putIfAbsent(record['remote_id'] as String, () => record);
      }
      records[collection] = byRemoteId.values.toList();
    }

    final rawTombstones = updates['warranty_tombstones'];
    if (rawTombstones is! List) {
      throw _protocolError('warranty_tombstones must be a list.');
    }
    final warrantyTombstones = <WarrantyDeletionTombstone>[];
    var lastWarrantySequence = _v2Decimal(
      warrantyCursor,
      'warranty_tombstone_cursor',
    );
    for (final raw in rawTombstones) {
      final map = _v2Object(raw, 'warranty tombstone');
      _exactKeys(
        map,
        {'warranty_id', 'deletion_sequence', 'deleted_at'},
        {'warranty_id', 'deletion_sequence', 'deleted_at'},
        'warranty tombstone',
      );
      _v2Uuid(map['warranty_id'], 'warranty_id');
      final sequence = _v2Decimal(
        map['deletion_sequence'],
        'deletion_sequence',
        allowZero: false,
      );
      if (sequence <= lastWarrantySequence || sequence > parsedWarrantyCursor) {
        throw _protocolError('warranty tombstone ordering is invalid.');
      }
      lastWarrantySequence = sequence;
      warrantyTombstones.add(
        WarrantyDeletionTombstone.fromServer(map, franchiseeId: franchiseeId),
      );
    }
    if (lastWarrantySequence != parsedWarrantyCursor) {
      throw _protocolError('warranty tombstone cursor is inconsistent.');
    }

    await dbService.applySyncV2Response(
      franchiseeId: franchiseeId,
      responseCursor: responseCursor.toString(),
      warrantyTombstoneCursor: parsedWarrantyCursor.toString(),
      records: records,
      warrantyTombstones: warrantyTombstones,
      submittedChangeIds: submittedChangeIds,
      outcomeStatuses: outcomeStatuses,
      activateProtocol: activateProtocol,
    );
  }
}
