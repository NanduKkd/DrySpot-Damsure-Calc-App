import 'dart:convert';

import 'package:crypto/crypto.dart';
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

class _PhotoUploadResult {
  const _PhotoUploadResult({
    required this.authoritativeChanged,
    this.error,
    this.stackTrace,
  });

  final bool authoritativeChanged;
  final Object? error;
  final StackTrace? stackTrace;
}

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
    try {
      await _syncV1();
    } on ApiException catch (error) {
      if (supportsV2 &&
          error.statusCode == 426 &&
          error.code == 'sync_protocol_upgrade_required') {
        // The cutoff server may already own generation 1. Pull its cursor-zero
        // baseline without submitting local candidates, preserve dirty values,
        // then move every dirty candidate strictly above that baseline.
        await _syncV2Round(
          franchiseeId,
          activateProtocol: false,
          includePending: false,
        );
        await dbService.rebasePendingLwwChangesForBootstrap(franchiseeId);
        await _syncV2(
          franchiseeId,
          activateProtocol: true,
          requireSubmittedAccepted: true,
        );
        return;
      }
      rethrow;
    }
    if (!supportsV2) return;
    try {
      await _syncV2(franchiseeId, activateProtocol: true);
    } on ApiException catch (error) {
      // During the compatibility window an old server may not expose /sync/v2.
      // The successful v1 drain remains durable, while no v2 cursor/state is
      // persisted and the next explicit sync retries the bootstrap safely.
      if (!error.endpointMissing) rethrow;
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
  static const _maxBigint = '9223372036854775807';
  static const _maxPrice = 99999999.99;
  static const _maxImageDataBytes = 15 * 1024 * 1024;
  static const _maxResponseRecords = 1000;

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
        parsed > BigInt.parse(_maxBigint)) {
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

  dynamic _stableJsonValue(dynamic value) {
    if (value is List) return value.map(_stableJsonValue).toList();
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {
        for (final key in keys) key: _stableJsonValue(value[key]),
      };
    }
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt();
    }
    return value;
  }

  String _payloadHash(Map<String, dynamic> payload) => sha256
      .convert(utf8.encode(jsonEncode(_stableJsonValue(payload))))
      .toString();

  bool _boundedString(dynamic value, {required int max, bool nullable = true}) {
    if (value == null) return nullable;
    return value is String && value.length <= max;
  }

  bool _currency(dynamic value, {bool nullable = false}) {
    if (value == null) return nullable;
    if (value is! num || !value.isFinite || value < 0 || value > _maxPrice) {
      return false;
    }
    final doubleValue = value.toDouble();
    return (doubleValue * 100).round() / 100 == doubleValue;
  }

  DateTime _serverDate(dynamic value, String label) {
    if (value is! String ||
        !RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
      throw _protocolError('$label is not an offset-aware timestamp.');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw _protocolError('$label is invalid.');
    return parsed;
  }

  bool _canonicalDataImage(dynamic value) {
    if (value == null) return true;
    return value is String &&
        utf8.encode(value).length <= _maxImageDataBytes &&
        RegExp(
          r'^data:image/(?:jpeg|png|webp|gif);base64,[A-Za-z0-9+/]+={0,2}$',
        ).hasMatch(value);
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
    final extra = switch (collection) {
      'clients' => {'franchisee_id', 'media'},
      'items' => {'parent_id'},
      'rectangles' => {'parent_id', 'media'},
      'default_prices' => {'franchisee_id'},
      _ => throw _protocolError('unknown authoritative collection.'),
    };
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
    _serverDate(record['server_timestamp'], '$collection.server_timestamp');
    final deletedAt = record['deleted_at'];
    if (deletedAt != null) _serverDate(deletedAt, '$collection.deleted_at');
    if ((record['operation'] == 'delete') != (deletedAt != null)) {
      throw _protocolError('$collection deletion state is inconsistent.');
    }
    if (record['payload'] is! Map) {
      throw _protocolError('$collection.payload is invalid.');
    }
    final payload = Map<String, dynamic>.from(record['payload'] as Map);
    final deleting = record['operation'] == 'delete';
    if (deleting && payload.isNotEmpty) {
      throw _protocolError('$collection delete payload must be empty.');
    }
    switch (collection) {
      case 'clients':
        if (!deleting) {
          const keys = {
            'name',
            'address',
            'site_address',
            'email',
            'phone',
            'latitude',
            'longitude',
            'discounted_price',
          };
          _exactKeys(payload, keys, keys, 'clients.payload');
          final name = payload['name'];
          final email = payload['email'];
          final latitude = payload['latitude'];
          final longitude = payload['longitude'];
          if (name is! String ||
              name.trim().isEmpty ||
              name.length > 255 ||
              !_boundedString(payload['address'], max: 255) ||
              !_boundedString(payload['site_address'], max: 255) ||
              !_boundedString(email, max: 255) ||
              !_boundedString(payload['phone'], max: 255) ||
              (email is String &&
                  email.isNotEmpty &&
                  !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) ||
              (latitude != null &&
                  (latitude is! num ||
                      !latitude.isFinite ||
                      latitude < -90 ||
                      latitude > 90)) ||
              (longitude != null &&
                  (longitude is! num ||
                      !longitude.isFinite ||
                      longitude < -180 ||
                      longitude > 180)) ||
              !_currency(payload['discounted_price'], nullable: true)) {
            throw _protocolError('clients.payload contains invalid values.');
          }
        }
        final media = _v2Object(record['media'], 'clients.media');
        _exactKeys(media, {'photos'}, {'photos'}, 'clients.media');
        final photos = media['photos'];
        final photoPattern = RegExp(
          '^/api/photos/client/${RegExp.escape(record['remote_id'] as String)}/'
          r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-'
          r'[0-9a-f]{12}\.(?:jpg|png|webp)$',
          caseSensitive: false,
        );
        if (photos is! List ||
            photos.length > 100 ||
            photos.any(
              (photo) => photo is! String || !photoPattern.hasMatch(photo),
            ) ||
            photos.toSet().length != photos.length ||
            (deleting && photos.isNotEmpty)) {
          throw _protocolError('clients.media contains invalid photos.');
        }
      case 'items':
        if (!deleting) {
          _exactKeys(
            payload,
            {'name', 'price', 'enabled'},
            {'name', 'price', 'enabled'},
            'items.payload',
          );
          final name = payload['name'];
          if (name is! String ||
              name.trim().isEmpty ||
              name.length > 255 ||
              !_currency(payload['price']) ||
              payload['enabled'] is! bool) {
            throw _protocolError('items.payload contains invalid values.');
          }
        }
      case 'rectangles':
        if (!deleting) {
          _exactKeys(
            payload,
            {'length', 'width'},
            {'length', 'width'},
            'rectangles.payload',
          );
          if ([payload['length'], payload['width']].any(
            (value) =>
                value is! num || !value.isFinite || value <= 0 || value > 10000,
          )) {
            throw _protocolError('rectangles.payload contains invalid values.');
          }
        }
        final media = _v2Object(record['media'], 'rectangles.media');
        _exactKeys(media, {'image_data'}, {'image_data'}, 'rectangles.media');
        if (!_canonicalDataImage(media['image_data']) ||
            (deleting && media['image_data'] != null)) {
          throw _protocolError('rectangles.media is invalid.');
        }
      case 'default_prices':
        if (!deleting) {
          _exactKeys(
            payload,
            {'price', 'enabled'},
            {'price', 'enabled'},
            'default_prices.payload',
          );
          if (!_currency(payload['price']) || payload['enabled'] is! bool) {
            throw _protocolError(
              'default_prices.payload contains invalid values.',
            );
          }
        }
    }
    if (collection == 'items' || collection == 'rectangles') {
      _v2Uuid(record['parent_id'], '$collection.parent_id');
    } else if (record['franchisee_id'] != franchiseeId) {
      throw _protocolError('$collection crossed tenant ownership.');
    }
    if (_payloadHash(payload) != record['payload_hash']) {
      throw _protocolError('$collection.payload_hash does not match payload.');
    }
    return record;
  }

  Map<String, dynamic> _validateV2Resource(
    dynamic raw,
    String collection, {
    required BigInt requestCursor,
    required BigInt responseCursor,
  }) {
    final record = _v2Object(raw, '$collection record');
    final common = {
      'remote_id',
      'client_id',
      'pdf_url',
      'row_cursor',
      'server_timestamp',
      'deleted_at',
    };
    final keys = collection == 'warranties'
        ? {
            ...common,
            'version',
            'start_date',
            'duration_years',
            'warranty_card_number',
          }
        : common;
    _exactKeys(record, keys, keys, '$collection record');
    final remoteId = _v2Uuid(record['remote_id'], '$collection.remote_id');
    _v2Uuid(record['client_id'], '$collection.client_id');
    final rowCursor = _v2Decimal(
      record['row_cursor'],
      '$collection.row_cursor',
      allowZero: false,
    );
    if (rowCursor <= requestCursor || rowCursor > responseCursor) {
      throw _protocolError('$collection.row_cursor is outside the snapshot.');
    }
    _serverDate(record['server_timestamp'], '$collection.server_timestamp');
    final deletedAt = record['deleted_at'];
    if (deletedAt != null) _serverDate(deletedAt, '$collection.deleted_at');
    final expectedPdfUrl = collection == 'warranties'
        ? '/api/warranty/$remoteId/download'
        : '/api/proposal/$remoteId/download';
    if (record['pdf_url'] != expectedPdfUrl ||
        (record['pdf_url'] as String).length > 255) {
      throw _protocolError('$collection.pdf_url is invalid.');
    }
    if (collection == 'warranties') {
      final version = record['version'];
      final duration = record['duration_years'];
      final card = record['warranty_card_number'];
      if (deletedAt != null ||
          version is! int ||
          version < 1 ||
          version > 2147483647 ||
          duration is! int ||
          duration < 1 ||
          duration > 2147483647 ||
          card is! String ||
          card.trim().isEmpty ||
          card.length > 255) {
        throw _protocolError('warranties contains invalid values.');
      }
      _serverDate(record['start_date'], 'warranties.start_date');
    }
    return record;
  }

  Future<_PhotoUploadResult> _uploadPendingV2ClientPhotos(
    String franchiseeId,
  ) async {
    var authoritativeChanged = false;
    for (final pending
        in await dbService.getPendingClientPhotos(franchiseeId)) {
      final remoteId = pending['client_remote_id']!;
      final photo = pending['local_path']!;
      try {
        if (photo.startsWith('/api/photos/client/')) continue;
        final uri = Uri.tryParse(photo);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.path.startsWith('/api/photos/client/')) {
          await dbService.acknowledgeClientPhotoUpload(
            franchiseeId: franchiseeId,
            remoteId: remoteId,
            localPath: photo,
            canonicalPath: uri.path,
          );
          continue;
        }
        final canonical = await apiService.uploadClientPhoto(
          remoteId,
          photo,
        );
        authoritativeChanged = true;
        await dbService.acknowledgeClientPhotoUpload(
          franchiseeId: franchiseeId,
          remoteId: remoteId,
          localPath: photo,
          canonicalPath: canonical,
        );
      } on Object catch (error, stackTrace) {
        return _PhotoUploadResult(
          authoritativeChanged: authoritativeChanged,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return _PhotoUploadResult(
      authoritativeChanged: authoritativeChanged,
    );
  }

  Future<bool> _deletePendingV2Proposals(String franchiseeId) async {
    final activeClientIds = (await dbService.getClients())
        .where((client) => client.franchiseeId == franchiseeId)
        .map((client) => client.localId)
        .whereType<int>()
        .toSet();
    var deleted = false;
    for (final proposal in await dbService.getDirtyProposals()) {
      if (proposal.deletedAt == null ||
          !activeClientIds.contains(proposal.clientId)) {
        continue;
      }
      await apiService.deleteProposal(proposal.remoteId);
      deleted = true;
    }
    return deleted;
  }

  Future<void> _syncV2(
    String franchiseeId, {
    required bool activateProtocol,
    bool requireSubmittedAccepted = false,
  }) async {
    await _syncV2Round(
      franchiseeId,
      activateProtocol: activateProtocol,
      requireSubmittedAccepted: requireSubmittedAccepted,
    );
    final photoResult = await _uploadPendingV2ClientPhotos(franchiseeId);
    Object? proposalError;
    StackTrace? proposalStackTrace;
    var proposalChanged = false;
    try {
      proposalChanged = await _deletePendingV2Proposals(franchiseeId);
    } on Object catch (error, stackTrace) {
      proposalError = error;
      proposalStackTrace = stackTrace;
    }
    if (photoResult.authoritativeChanged || proposalChanged) {
      // The dedicated endpoints advance/stamp the tenant cursor. Pull once
      // more so exact authoritative media/PDF state and cursor land atomically.
      await _syncV2Round(franchiseeId, activateProtocol: false);
    }
    if (photoResult.error != null) {
      Error.throwWithStackTrace(
        photoResult.error!,
        photoResult.stackTrace!,
      );
    }
    if (proposalError != null) {
      Error.throwWithStackTrace(proposalError, proposalStackTrace!);
    }
  }

  Future<void> _syncV2Round(
    String franchiseeId, {
    required bool activateProtocol,
    bool includePending = true,
    bool requireSubmittedAccepted = false,
  }) async {
    final requestCursor = await dbService.getSyncV2Cursor(franchiseeId);
    final parsedRequestCursor = _v2Decimal(requestCursor, 'request_cursor');
    final warrantyCursor = await dbService.getWarrantyTombstoneCursor(
      franchiseeId,
    );
    _v2Decimal(warrantyCursor, 'warranty_tombstone_cursor');
    final changes = includePending
        ? await dbService.getPendingLwwChanges(franchiseeId)
        : {
            for (final collection in _v2Collections)
              collection: <Map<String, dynamic>>[],
          };
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
            'operation': change['operation'].toString(),
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
    if (response['warnings'] is! List ||
        (response['warnings'] as List).length > submittedByChangeId.length) {
      throw _protocolError('warnings must be a list.');
    }
    final warningChangeIds = <String>{};
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
      if (!submittedByChangeId.containsKey(warningChangeId) ||
          !warningChangeIds.add(warningChangeId)) {
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
      'permanently_deleted',
    };
    const statusReasons = <String, Set<String>>{
      'applied': {'upsert_applied', 'delete_applied'},
      'already_applied': {'already_applied'},
      'superseded': {'delete_wins', 'version_superseded'},
      'rejected': {
        'future_base_version',
        'change_id_reused',
        'parent_required',
        'parent_unavailable',
        'immutable_parent',
        'invalid_payload',
        'server_field_forbidden',
        'unknown_field',
      },
      'permanently_deleted': {'permanently_deleted'},
      'unauthorized': {'not_authorized'},
    };
    for (final collection in _v2Collections) {
      final collectionOutcomes = outcomes[collection];
      if (collectionOutcomes is! List ||
          collectionOutcomes.length > (changes[collection]?.length ?? 0)) {
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
        final status = result['status'];
        final reason = result['reason_code'];
        if (!statuses.contains(status) ||
            result['reason_code'] is! String ||
            !reasonCodes.contains(reason) ||
            !statusReasons[status]!.contains(reason)) {
          throw _protocolError('$collection outcome status is invalid.');
        }
        final requiresAuthoritative = {
          'applied',
          'already_applied',
          'superseded',
        }.contains(status);
        if (requiresAuthoritative != result.containsKey('authoritative')) {
          throw _protocolError('$collection omitted authoritative state.');
        }
        outcomeStatuses[changeId] = status as String;
        if (result['authoritative'] != null) {
          final authoritativeRecord = _validateV2Record(
            result['authoritative'],
            collection,
            responseCursor: responseCursor,
            requestCursor: parsedRequestCursor,
            franchiseeId: franchiseeId,
            snapshot: false,
          );
          if ((status == 'applied' || status == 'already_applied') &&
              (authoritativeRecord['change_id'] != changeId ||
                  authoritativeRecord['operation'] != submitted['operation'])) {
            throw _protocolError(
              '$collection outcome acknowledged the wrong logical change.',
            );
          }
          if (status == 'applied' &&
              reason !=
                  (submitted['operation'] == 'delete'
                      ? 'delete_applied'
                      : 'upsert_applied')) {
            throw _protocolError(
              '$collection applied reason does not match the operation.',
            );
          }
          authoritative[collection]!.add(authoritativeRecord);
        }
      }
    }
    if (seenOutcomes.length != submittedByChangeId.length) {
      throw _protocolError('the server omitted one or more change outcomes.');
    }

    final updates = _v2Object(response['updates'], 'updates');
    _exactKeys(
      updates,
      {
        ..._v2Collections,
        'warranties',
        'proposals',
        'warranty_tombstones',
      },
      {
        ..._v2Collections,
        'warranties',
        'proposals',
        'warranty_tombstones',
      },
      'updates',
    );
    final records = <String, List<Map<String, dynamic>>>{
      for (final collection in _v2Collections) collection: [],
    };
    for (final collection in _v2Collections) {
      final rawRecords = updates[collection];
      if (rawRecords is! List || rawRecords.length > _maxResponseRecords) {
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

    final resources = <String, List<Map<String, dynamic>>>{
      'warranties': [],
      'proposals': [],
    };
    for (final collection in resources.keys) {
      final rawRecords = updates[collection];
      if (rawRecords is! List || rawRecords.length > _maxResponseRecords) {
        throw _protocolError('$collection updates must be a bounded list.');
      }
      final seenRemoteIds = <String>{};
      for (final rawRecord in rawRecords) {
        final record = _validateV2Resource(
          rawRecord,
          collection,
          requestCursor: parsedRequestCursor,
          responseCursor: responseCursor,
        );
        if (!seenRemoteIds.add(record['remote_id'] as String)) {
          throw _protocolError('$collection contains a duplicate update.');
        }
        resources[collection]!.add(record);
      }
    }

    final rawTombstones = updates['warranty_tombstones'];
    if (rawTombstones is! List || rawTombstones.length > _maxResponseRecords) {
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
      _serverDate(map['deleted_at'], 'warranty tombstone.deleted_at');
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
    if (requireSubmittedAccepted &&
        outcomeStatuses.values.any(
          (status) => status != 'applied' && status != 'already_applied',
        )) {
      throw const ApiException(
        'The v2 bootstrap did not accept every rebased legacy change.',
        code: 'sync_v2_bootstrap_not_accepted',
      );
    }

    await dbService.applySyncV2Response(
      franchiseeId: franchiseeId,
      requestCursor: requestCursor,
      responseCursor: responseCursor.toString(),
      requestWarrantyTombstoneCursor: warrantyCursor,
      warrantyTombstoneCursor: parsedWarrantyCursor.toString(),
      records: records,
      warranties: resources['warranties']!,
      proposals: resources['proposals']!,
      warrantyTombstones: warrantyTombstones,
      submittedChangeIds: submittedChangeIds,
      outcomeStatuses: outcomeStatuses,
      activateProtocol: activateProtocol,
    );
  }
}
