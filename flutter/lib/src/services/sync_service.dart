import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'api_service.dart';
import 'db_service.dart';
import 'lww_protocol.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/default_price.dart';
import '../models/warranty.dart';
import '../models/warranty_deletion_tombstone.dart';
import '../models/proposal.dart';
import 'session_manager.dart';

enum SyncPhase {
  preparing,
  uploadingPhotos,
  sendingChanges,
  applyingUpdates,
  finalising,
}

enum SyncOutcomeStatus {
  applied,
  alreadyApplied,
  superseded,
  rejected,
  permanentlyDeleted,
  unauthorized,
}

extension SyncOutcomeStatusWire on SyncOutcomeStatus {
  String get wireName => switch (this) {
        SyncOutcomeStatus.applied => 'applied',
        SyncOutcomeStatus.alreadyApplied => 'already_applied',
        SyncOutcomeStatus.superseded => 'superseded',
        SyncOutcomeStatus.rejected => 'rejected',
        SyncOutcomeStatus.permanentlyDeleted => 'permanently_deleted',
        SyncOutcomeStatus.unauthorized => 'unauthorized',
      };
}

SyncOutcomeStatus _syncOutcomeStatusFromWire(String value) => switch (value) {
      'applied' => SyncOutcomeStatus.applied,
      'already_applied' => SyncOutcomeStatus.alreadyApplied,
      'superseded' => SyncOutcomeStatus.superseded,
      'rejected' => SyncOutcomeStatus.rejected,
      'permanently_deleted' => SyncOutcomeStatus.permanentlyDeleted,
      'unauthorized' => SyncOutcomeStatus.unauthorized,
      _ => throw ArgumentError.value(value, 'value', 'Unknown APP-111 outcome'),
    };

class SyncOutcome {
  const SyncOutcome({
    required this.collection,
    required this.status,
  });

  final String collection;
  final SyncOutcomeStatus status;
}

/// A narrow APP-112 projection of APP-111's already-validated outcomes.
/// It deliberately contains no competing ordering, cursor, payload, or raw
/// server error data.
class SyncRunResult {
  const SyncRunResult({this.outcomes = const []});

  final List<SyncOutcome> outcomes;
}

typedef SyncPhaseListener = void Function(SyncPhase phase);

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
  final SessionManager? sessionManager;

  SyncService({
    required this.apiService,
    DbService? dbService,
    this.sessionManager,
  }) : dbService = dbService ?? DbService();

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

  bool _isCurrent(SessionSnapshot? session) =>
      session == null ||
      sessionManager == null ||
      sessionManager!.isCurrent(session);

  void _requireCurrent(SessionSnapshot? session) {
    if (!_isCurrent(session)) throw const StaleSessionException();
  }

  Future<T> _writeForCurrent<T>(
    SessionSnapshot? session,
    Future<T> Function() write,
  ) async {
    _requireCurrent(session);
    final result = await write();
    _requireCurrent(session);
    return result;
  }

  Future<Map<String, dynamic>> _requestV1(
    Map<String, dynamic> data,
    SessionSnapshot? session,
  ) {
    _requireCurrent(session);
    return session == null
        ? apiService.sync(data)
        : apiService.syncForSession(
            data,
            session,
            isSessionCurrent: () => _isCurrent(session),
          );
  }

  Future<Map<String, dynamic>> _requestV2(
    Map<String, dynamic> data,
    SessionSnapshot? session,
  ) {
    _requireCurrent(session);
    return session == null
        ? apiService.syncV2(data)
        : apiService.syncV2ForSession(
            data,
            session,
            isSessionCurrent: () => _isCurrent(session),
          );
  }

  Future<String> _uploadPhoto(
    String clientId,
    String path,
    SessionSnapshot? session,
    String? idempotencyKey,
    String? fileSha256,
  ) {
    _requireCurrent(session);
    // The unbound branch only exists for legacy isolated V1 tests. The app
    // always supplies an APP-106 session, so every production photo request
    // uses its durable operation ID and digest.
    if (session == null && idempotencyKey == null) {
      return apiService.uploadClientPhoto(clientId, path);
    }
    return session == null
        ? apiService.uploadClientPhotoWithIdempotency(
            clientId,
            path,
            idempotencyKey,
            fileSha256,
          )
        : apiService.uploadClientPhotoForSession(
            clientId,
            path,
            session,
            idempotencyKey: idempotencyKey,
            fileSha256: fileSha256,
            isSessionCurrent: () => _isCurrent(session),
          );
  }

  Future<void> _deleteProposal(String id, SessionSnapshot? session) {
    _requireCurrent(session);
    return session == null
        ? apiService.deleteProposal(id)
        : apiService.deleteProposalForSession(
            id,
            session,
            isSessionCurrent: () => _isCurrent(session),
          );
  }

  Future<SyncRunResult> sync([
    SessionSnapshot? requestedSession,
    SyncPhaseListener? onPhase,
  ]) async {
    final session = requestedSession ?? sessionManager?.current;
    if (sessionManager != null && session == null) {
      throw const StaleSessionException();
    }
    _requireCurrent(session);
    onPhase?.call(SyncPhase.preparing);
    final prefs = await SharedPreferences.getInstance();
    _requireCurrent(session);
    final franchiseeId =
        session?.franchiseeId ?? prefs.getString('franchisee_id')?.trim();
    final hasTenant = franchiseeId != null && franchiseeId.isNotEmpty;
    final supportsV2 = hasTenant && await dbService.supportsSyncV2();
    _requireCurrent(session);
    if (supportsV2 && await dbService.isSyncV2Enabled(franchiseeId)) {
      _requireCurrent(session);
      return await _syncV2(
        franchiseeId,
        session,
        activateProtocol: false,
        onPhase: onPhase,
      );
    }
    if (supportsV2) {
      _requireCurrent(session);
      if (sessionManager != null) {
        await dbService.claimLegacyDefaultPricesForSession(
          franchiseeId,
          isSessionCurrent: () => _isCurrent(session),
        );
      } else {
        await dbService.claimLegacyDefaultPrices(franchiseeId);
      }
      _requireCurrent(session);
    }

    // The legacy writer drains first. A v2 state bit is persisted only in the
    // same SQLite transaction that applies a successful cursor-zero snapshot.
    try {
      onPhase?.call(SyncPhase.sendingChanges);
      await _syncV1(
        session,
        drainDurablePhotoUploads: supportsV2,
        onPhase: onPhase,
      );
    } on ApiException catch (error) {
      if (supportsV2 &&
          error.statusCode == 426 &&
          error.code == 'sync_protocol_upgrade_required') {
        // The cutoff server may already own generation 1. Pull its cursor-zero
        // baseline without submitting local candidates, preserve dirty values,
        // then move every dirty candidate strictly above that baseline.
        await _syncV2Round(
          franchiseeId,
          session,
          activateProtocol: false,
          includePending: false,
          onPhase: onPhase,
        );
        _requireCurrent(session);
        await dbService.rebasePendingLwwChangesForBootstrapForSession(
          franchiseeId,
          isSessionCurrent: () => _isCurrent(session),
        );
        return await _syncV2(
          franchiseeId,
          session,
          activateProtocol: true,
          requireSubmittedAccepted: true,
          onPhase: onPhase,
        );
      }
      rethrow;
    }
    if (!supportsV2) return const SyncRunResult();
    try {
      return await _syncV2(
        franchiseeId,
        session,
        activateProtocol: true,
        onPhase: onPhase,
      );
    } on ApiException catch (error) {
      // During the compatibility window an old server may not expose /sync/v2.
      // The successful v1 drain remains durable, while no v2 cursor/state is
      // persisted and the next explicit sync retries the bootstrap safely.
      if (!error.endpointMissing) rethrow;
    }
    return const SyncRunResult();
  }

  Future<void> _syncV1(
    SessionSnapshot? session, {
    required bool drainDurablePhotoUploads,
    SyncPhaseListener? onPhase,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final activeFranchiseeId =
        session?.franchiseeId ?? prefs.getString('franchisee_id')?.trim();
    final shouldFilterByFranchise =
        activeFranchiseeId != null && activeFranchiseeId.isNotEmpty;
    // AppService construction always supplies the session manager. The
    // unbound branch remains solely for historical isolated service tests;
    // it preserves their old mock surface and is never used by the app.
    final enforceSessionBoundary = sessionManager != null;
    // Never read or write a device-wide preference cursor. The v1 fallback
    // shares APP-111's tenant-owned SQLite sync state with v2.
    final lastSyncTime = shouldFilterByFranchise && enforceSessionBoundary
        ? await dbService.getSyncV1Cursor(activeFranchiseeId)
        : null;
    final warrantyTombstoneCursor = shouldFilterByFranchise
        ? await dbService.getWarrantyTombstoneCursor(activeFranchiseeId)
        : '0';

    if (drainDurablePhotoUploads) {
      // An upgraded client must drain V1 media through the APP-112 durable
      // operation queue before it can send a legacy client payload or activate
      // V2. A failure is deliberately terminal for this run: silently omitting
      // the photo would make bootstrap appear complete while losing its change.
      onPhase?.call(SyncPhase.uploadingPhotos);
      final photoResult = await _uploadPendingV2ClientPhotos(
        activeFranchiseeId!,
        session,
        requireDurableReceipt: true,
      );
      if (photoResult.error != null) {
        Error.throwWithStackTrace(photoResult.error!, photoResult.stackTrace!);
      }
      _requireCurrent(session);
      onPhase?.call(SyncPhase.sendingChanges);
    }

    // Build active-session maps once so all payloads resolve IDs consistently.
    final activeClients = shouldFilterByFranchise && enforceSessionBoundary
        ? await dbService.getClientsForFranchisee(activeFranchiseeId)
        : (await dbService.getClients())
            .where(
              (client) =>
                  !shouldFilterByFranchise ||
                  client.franchiseeId == activeFranchiseeId,
            )
            .toList();
    final clientsByLocalId = <int, Client>{
      for (final client in activeClients)
        if (client.localId != null) client.localId!: client,
    };
    final itemsByLocalId = <int, Item>{
      for (final client in activeClients)
        for (final item in client.items)
          if (item.localId != null) item.localId!: item,
    };

    // 1. Gather local changes
    final dirtyClients = shouldFilterByFranchise && enforceSessionBoundary
        ? await dbService.getDirtyClientsForFranchisee(activeFranchiseeId)
        : (await dbService.getDirtyClients())
            .where(
              (client) =>
                  !shouldFilterByFranchise ||
                  client.franchiseeId == activeFranchiseeId,
            )
            .toList();
    final dirtyItems = shouldFilterByFranchise && enforceSessionBoundary
        ? await dbService.getDirtyItemsForFranchisee(activeFranchiseeId)
        : (await dbService.getDirtyItems())
            .where(
              (item) =>
                  !shouldFilterByFranchise ||
                  (item.clientId != null &&
                      clientsByLocalId.containsKey(item.clientId)),
            )
            .toList();
    final dirtyRectangles = shouldFilterByFranchise && enforceSessionBoundary
        ? await dbService.getDirtyRectanglesForFranchisee(activeFranchiseeId)
        : (await dbService.getDirtyRectangles())
            .where(
              (rectangle) =>
                  !shouldFilterByFranchise ||
                  (rectangle.itemId != null &&
                      itemsByLocalId.containsKey(rectangle.itemId)),
            )
            .toList();
    final dirtyDefaultPrices = shouldFilterByFranchise
        ? await dbService.getDirtyDefaultPrices(activeFranchiseeId)
        : <DefaultPrice>[];
    final dirtyWarranties = shouldFilterByFranchise && enforceSessionBoundary
        ? await dbService.getDirtyWarrantiesForFranchisee(activeFranchiseeId)
        : (await dbService.getDirtyWarranties())
            .where(
              (warranty) =>
                  !shouldFilterByFranchise ||
                  clientsByLocalId.containsKey(warranty.clientId),
            )
            .toList();
    final dirtyProposals = shouldFilterByFranchise && enforceSessionBoundary
        ? await dbService.getDirtyProposalsForFranchisee(activeFranchiseeId)
        : (await dbService.getDirtyProposals())
            .where(
              (proposal) =>
                  !shouldFilterByFranchise ||
                  clientsByLocalId.containsKey(proposal.clientId),
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

        if (drainDurablePhotoUploads) {
          // Queue acknowledgement rewrites the local path before this V1
          // payload is assembled. Seeing one here means the durable drain did
          // not converge, so do not submit or activate a partial bootstrap.
          throw StateError('A V1 photo upload did not drain safely.');
        }
        try {
          canonicalPhotos.add(
            await _uploadPhoto(client.remoteId, photo, session, null, null),
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
          await _writeForCurrent(
            session,
            () => sessionManager == null
                ? dbService.updateClient(clientForPayload)
                : dbService.updateClientForSession(
                    clientForPayload,
                    isSessionCurrent: () => _isCurrent(session),
                  ),
          );
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
    final response = await _requestV1(syncData, session);
    _requireCurrent(session);
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
    final submittedClientsByRemoteId = {
      for (final client in clientsToMarkSynced) client.remoteId: client,
    };
    final submittedItemsByRemoteId = {
      for (final item in itemsToSync) item.remoteId: item,
    };
    final submittedRectanglesByRemoteId = {
      for (final rectangle in rectanglesToSync) rectangle.remoteId: rectangle,
    };
    final submittedDefaultPricesByRemoteId = {
      for (final price in dirtyDefaultPrices) price.remoteId: price,
    };
    final submittedProposalsByRemoteId = {
      for (final proposal in proposalsToSync) proposal.remoteId: proposal,
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
      _requireCurrent(session);
      if (sessionManager != null) {
        await _writeForCurrent(
          session,
          () => dbService.applyWarrantyTombstonesAndCursorForSession(
            tombstones,
            franchiseeId: activeFranchiseeId,
            cursor: parsedCursor.toString(),
            isSessionCurrent: () => _isCurrent(session),
          ),
        );
      } else {
        await _writeForCurrent(
          session,
          () => dbService.applyWarrantyTombstonesAndCursor(
            tombstones,
            franchiseeId: activeFranchiseeId,
            cursor: parsedCursor.toString(),
          ),
        );
      }
    }

    // 3. Apply updates to local DB
    if (updates != null) {
      // Clients
      for (var clientMap in updates['clients']) {
        final remoteId = clientMap['remote_id'];
        final submittedClient = submittedClientsByRemoteId[remoteId];
        final existingClient = shouldFilterByFranchise && enforceSessionBoundary
            ? await dbService.getClientByRemoteIdForFranchisee(
                remoteId,
                activeFranchiseeId,
              )
            : await dbService.getClientByRemoteId(remoteId);

        if (clientMap['deleted_at'] != null) {
          if (existingClient != null && !existingClient.isDirty) {
            await _writeForCurrent(
              session,
              () => sessionManager == null
                  ? dbService.softDeleteClient(existingClient.localId!)
                  : dbService.writeForSession(
                      table: 'clients',
                      values: {
                        'deleted_at': clientMap['deleted_at'],
                        'is_dirty': 0,
                      },
                      where: 'local_id = ? AND franchisee_id = ?',
                      whereArgs: [
                        existingClient.localId,
                        activeFranchiseeId,
                      ],
                      isSessionCurrent: () => _isCurrent(session),
                    ),
            );
          }
        } else {
          if (shouldFilterByFranchise) {
            clientMap['franchisee_id'] = activeFranchiseeId;
          }
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
            if (submittedClient != null && appliedClients.contains(remoteId)) {
              // The response can acknowledge only the exact revision sent.
              // A local N+1 edit must survive an in-flight N response.
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.applyClientFromServerIfUnchanged(
                        clientFromServer.copyWith(
                          localId: existingClient.localId,
                        ),
                        franchiseeId: activeFranchiseeId!,
                        submittedUpdatedAt:
                            submittedClient.updatedAt.toIso8601String(),
                      )
                    : dbService.applyClientFromServerIfUnchangedForSession(
                        clientFromServer.copyWith(
                          localId: existingClient.localId,
                        ),
                        franchiseeId: activeFranchiseeId!,
                        submittedUpdatedAt:
                            submittedClient.updatedAt.toIso8601String(),
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            } else if (!existingClient.isDirty || submittedClient == null) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.updateClient(
                        clientFromServer.copyWith(
                          localId: existingClient.localId,
                        ),
                      )
                    : dbService.updateClientForSession(
                        clientFromServer.copyWith(
                          localId: existingClient.localId,
                        ),
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          } else {
            await _writeForCurrent(
              session,
              () => sessionManager == null
                  ? dbService.insertClient(clientFromServer)
                  : dbService.insertClientForSession(
                      clientFromServer,
                      isSessionCurrent: () => _isCurrent(session),
                    ),
            );
          }
        }
      }

      // Items
      for (var itemMap in updates['items']) {
        final remoteId = itemMap['remote_id'];
        final submittedItem = submittedItemsByRemoteId[remoteId];
        final existingItem = shouldFilterByFranchise && enforceSessionBoundary
            ? await dbService.getItemByRemoteIdForFranchisee(
                remoteId,
                activeFranchiseeId,
              )
            : await dbService.getItemByRemoteId(remoteId);
        final client = shouldFilterByFranchise && enforceSessionBoundary
            ? await dbService.getClientByRemoteIdForFranchisee(
                itemMap['client_id'],
                activeFranchiseeId,
              )
            : await dbService.getClientByRemoteId(itemMap['client_id']);

        if (client != null) {
          if (itemMap['deleted_at'] != null) {
            if (existingItem != null &&
                submittedItem != null &&
                appliedItems.contains(remoteId)) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.softDeleteItem(existingItem.localId!)
                    : dbService.writeForSession(
                        table: 'items',
                        values: {
                          'deleted_at': itemMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: '''
                          local_id = ? AND updated_at = ? AND is_dirty = 1
                        ''',
                        whereArgs: [
                          existingItem.localId,
                          submittedItem.updatedAt.toIso8601String(),
                        ],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            } else if (existingItem != null &&
                submittedItem == null &&
                !existingItem.isDirty) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.softDeleteItem(existingItem.localId!)
                    : dbService.writeForSession(
                        table: 'items',
                        values: {
                          'deleted_at': itemMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: 'local_id = ?',
                        whereArgs: [existingItem.localId],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          } else {
            final item = Item.fromMap(
              itemMap,
            ).copyWith(clientId: client.localId, isDirty: false);
            if (existingItem != null) {
              if (submittedItem != null && appliedItems.contains(remoteId)) {
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.updateItem(
                          item.copyWith(localId: existingItem.localId),
                        )
                      : dbService.writeForSession(
                          table: 'items',
                          values: item
                              .copyWith(localId: existingItem.localId)
                              .toMap(),
                          where: '''
                            local_id = ? AND updated_at = ? AND is_dirty = 1
                          ''',
                          whereArgs: [
                            existingItem.localId,
                            submittedItem.updatedAt.toIso8601String(),
                          ],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              } else if (submittedItem == null && !existingItem.isDirty) {
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.updateItem(
                          item.copyWith(localId: existingItem.localId),
                        )
                      : dbService.writeForSession(
                          table: 'items',
                          values: item
                              .copyWith(localId: existingItem.localId)
                              .toMap(),
                          where: 'local_id = ?',
                          whereArgs: [existingItem.localId],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              }
            } else {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.insertItem(item)
                    : dbService.writeForSession(
                        table: 'items',
                        values: item.toMap(),
                        insert: true,
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          }
        }
      }

      // Rectangles
      for (var rectMap in updates['rectangles']) {
        final remoteId = rectMap['remote_id'];
        final submittedRectangle = submittedRectanglesByRemoteId[remoteId];
        final existingRect = shouldFilterByFranchise && enforceSessionBoundary
            ? await dbService.getRectangleByRemoteIdForFranchisee(
                remoteId,
                activeFranchiseeId,
              )
            : await dbService.getRectangleByRemoteId(remoteId);
        final item = shouldFilterByFranchise && enforceSessionBoundary
            ? await dbService.getItemByRemoteIdForFranchisee(
                rectMap['item_id'],
                activeFranchiseeId,
              )
            : await dbService.getItemByRemoteId(rectMap['item_id']);

        if (item != null) {
          if (rectMap['deleted_at'] != null) {
            if (existingRect != null &&
                submittedRectangle != null &&
                appliedRectangles.contains(remoteId)) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.softDeleteRectangle(existingRect.localId!)
                    : dbService.writeForSession(
                        table: 'rectangles',
                        values: {
                          'deleted_at': rectMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: '''
                          local_id = ? AND updated_at = ? AND is_dirty = 1
                        ''',
                        whereArgs: [
                          existingRect.localId,
                          submittedRectangle.updatedAt.toIso8601String(),
                        ],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            } else if (existingRect != null &&
                submittedRectangle == null &&
                !existingRect.isDirty) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.softDeleteRectangle(existingRect.localId!)
                    : dbService.writeForSession(
                        table: 'rectangles',
                        values: {
                          'deleted_at': rectMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: 'local_id = ?',
                        whereArgs: [existingRect.localId],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          } else {
            final rect = Rectangle.fromMap(
              rectMap,
            ).copyWith(itemId: item.localId, isDirty: false);
            if (existingRect != null) {
              if (submittedRectangle != null &&
                  appliedRectangles.contains(remoteId)) {
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.updateRectangle(
                          rect.copyWith(localId: existingRect.localId),
                        )
                      : dbService.writeForSession(
                          table: 'rectangles',
                          values: rect
                              .copyWith(localId: existingRect.localId)
                              .toMap(),
                          where: '''
                            local_id = ? AND updated_at = ? AND is_dirty = 1
                          ''',
                          whereArgs: [
                            existingRect.localId,
                            submittedRectangle.updatedAt.toIso8601String(),
                          ],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              } else if (submittedRectangle == null && !existingRect.isDirty) {
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.updateRectangle(
                          rect.copyWith(localId: existingRect.localId),
                        )
                      : dbService.writeForSession(
                          table: 'rectangles',
                          values: rect
                              .copyWith(localId: existingRect.localId)
                              .toMap(),
                          where: 'local_id = ?',
                          whereArgs: [existingRect.localId],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              }
            } else {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.insertRectangle(rect)
                    : dbService.writeForSession(
                        table: 'rectangles',
                        values: rect.toMap(),
                        insert: true,
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          }
        }
      }

      // Warranties
      if (shouldFilterByFranchise) {
        for (final priceMap in updates['default_prices'] ?? []) {
          final remoteId = priceMap['remote_id']?.toString();
          if (remoteId == null || remoteId.isEmpty) continue;
          final submittedPrice = submittedDefaultPricesByRemoteId[remoteId];

          final existing = await dbService.getDefaultPriceByRemoteId(
            remoteId,
            activeFranchiseeId,
          );
          if (priceMap['deleted_at'] != null) {
            if (sessionManager == null &&
                existing != null &&
                existing.localId != null) {
              // Historical unbound service tests retain their mock-only V1
              // surface. The app always supplies SessionManager and takes the
              // CAS branch below.
              await _writeForCurrent(
                session,
                () => dbService.deleteDefaultPrice(
                  existing.localId!,
                  franchiseeId: activeFranchiseeId,
                ),
              );
            } else if (existing != null &&
                existing.localId != null &&
                submittedPrice != null &&
                appliedDefaultPrices.contains(remoteId)) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.deleteDefaultPrice(
                        existing.localId!,
                        franchiseeId: activeFranchiseeId,
                      )
                    : dbService.writeForSession(
                        table: 'default_prices',
                        values: {
                          'deleted_at': priceMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: '''
                          local_id = ? AND franchisee_id = ?
                          AND updated_at = ? AND is_dirty = 1
                        ''',
                        whereArgs: [
                          existing.localId,
                          activeFranchiseeId,
                          submittedPrice.updatedAt.toIso8601String(),
                        ],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            } else if (existing != null &&
                existing.localId != null &&
                submittedPrice == null &&
                !existing.isDirty) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.deleteDefaultPrice(
                        existing.localId!,
                        franchiseeId: activeFranchiseeId,
                      )
                    : dbService.writeForSession(
                        table: 'default_prices',
                        values: {
                          'deleted_at': priceMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: 'local_id = ? AND franchisee_id = ?',
                        whereArgs: [existing.localId, activeFranchiseeId],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
            continue;
          }

          final price = DefaultPrice.fromJson(
            priceMap,
          ).copyWith(franchiseeId: activeFranchiseeId, isDirty: false);
          if (existing == null) {
            await _writeForCurrent(
              session,
              () => sessionManager == null
                  ? dbService.insertDefaultPrice(
                      price,
                      franchiseeId: activeFranchiseeId,
                    )
                  : dbService.writeForSession(
                      table: 'default_prices',
                      values: price.toMap(),
                      insert: true,
                      isSessionCurrent: () => _isCurrent(session),
                    ),
            );
          } else if (submittedPrice != null &&
              appliedDefaultPrices.contains(remoteId)) {
            await _writeForCurrent(
              session,
              () => sessionManager == null
                  ? dbService.updateDefaultPrice(
                      price.copyWith(localId: existing.localId),
                      franchiseeId: activeFranchiseeId,
                    )
                  : dbService.writeForSession(
                      table: 'default_prices',
                      values: price.copyWith(localId: existing.localId).toMap(),
                      where: '''
                        local_id = ? AND franchisee_id = ?
                        AND updated_at = ? AND is_dirty = 1
                      ''',
                      whereArgs: [
                        existing.localId,
                        activeFranchiseeId,
                        submittedPrice.updatedAt.toIso8601String(),
                      ],
                      isSessionCurrent: () => _isCurrent(session),
                    ),
            );
          } else if (submittedPrice == null && !existing.isDirty) {
            await _writeForCurrent(
              session,
              () => sessionManager == null
                  ? dbService.updateDefaultPrice(
                      price.copyWith(localId: existing.localId),
                      franchiseeId: activeFranchiseeId,
                    )
                  : dbService.writeForSession(
                      table: 'default_prices',
                      values: price.copyWith(localId: existing.localId).toMap(),
                      where: 'local_id = ? AND franchisee_id = ?',
                      whereArgs: [existing.localId, activeFranchiseeId],
                      isSessionCurrent: () => _isCurrent(session),
                    ),
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
        final existingWarranty =
            shouldFilterByFranchise && enforceSessionBoundary
                ? await dbService.getWarrantyByRemoteIdForFranchisee(
                    remoteId,
                    activeFranchiseeId,
                  )
                : await dbService.getWarrantyByRemoteId(remoteId);
        final client = shouldFilterByFranchise && enforceSessionBoundary
            ? await dbService.getClientByRemoteIdForFranchisee(
                warrantyMap['client_id'],
                activeFranchiseeId,
              )
            : await dbService.getClientByRemoteId(warrantyMap['client_id']);

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
              if (submitted == null && !existingWarranty.isDirty) {
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.updateWarranty(
                          warranty.copyWith(localId: existingWarranty.localId),
                        )
                      : dbService.writeForSession(
                          table: 'warranties',
                          values: warranty
                              .copyWith(localId: existingWarranty.localId)
                              .toMap(),
                          where: 'local_id = ?',
                          whereArgs: [existingWarranty.localId],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              } else if (submitted != null &&
                  appliedWarranties.contains(remoteId)) {
                // Applying the server echo is itself compare-and-set. A local
                // edit made after request capture must survive both response
                // application and the later dirty-clear acknowledgement.
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.applyWarrantyFromServerIfUnchanged(
                          warranty.copyWith(localId: existingWarranty.localId),
                          submittedUpdatedAt:
                              submitted.updatedAt.toIso8601String(),
                        )
                      : dbService.writeForSession(
                          table: 'warranties',
                          values: warranty
                              .copyWith(localId: existingWarranty.localId)
                              .toMap(),
                          where: '''
                            local_id = ? AND updated_at = ? AND is_dirty = 1
                          ''',
                          whereArgs: [
                            existingWarranty.localId,
                            submitted.updatedAt.toIso8601String(),
                          ],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              }
            } else if (submitted == null) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.insertWarranty(warranty)
                    : dbService.writeForSession(
                        table: 'warranties',
                        values: warranty.toMap(),
                        insert: true,
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          }
        }
      }

      // Proposals
      for (var proposalMap in updates['proposals'] ?? []) {
        final remoteId = proposalMap['remote_id'];
        final submittedProposal = submittedProposalsByRemoteId[remoteId];
        final existingProposal =
            shouldFilterByFranchise && enforceSessionBoundary
                ? await dbService.getProposalByRemoteIdForFranchisee(
                    remoteId,
                    activeFranchiseeId,
                  )
                : await dbService.getProposalByRemoteId(remoteId);
        final client = shouldFilterByFranchise && enforceSessionBoundary
            ? await dbService.getClientByRemoteIdForFranchisee(
                proposalMap['client_id'],
                activeFranchiseeId,
              )
            : await dbService.getClientByRemoteId(proposalMap['client_id']);

        if (client != null) {
          if (proposalMap['deleted_at'] != null) {
            if (existingProposal != null &&
                submittedProposal != null &&
                appliedProposals.contains(remoteId)) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.softDeleteProposal(existingProposal.localId!)
                    : dbService.writeForSession(
                        table: 'proposals',
                        values: {
                          'deleted_at': proposalMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: '''
                          local_id = ? AND updated_at = ? AND is_dirty = 1
                        ''',
                        whereArgs: [
                          existingProposal.localId,
                          submittedProposal.updatedAt.toIso8601String(),
                        ],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            } else if (existingProposal != null &&
                submittedProposal == null &&
                !existingProposal.isDirty) {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.softDeleteProposal(existingProposal.localId!)
                    : dbService.writeForSession(
                        table: 'proposals',
                        values: {
                          'deleted_at': proposalMap['deleted_at'],
                          'is_dirty': 0,
                        },
                        where: 'local_id = ?',
                        whereArgs: [existingProposal.localId],
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          } else {
            final proposal = Proposal.fromMap(
              proposalMap,
            ).copyWith(clientId: client.localId!, isDirty: false);
            if (existingProposal != null) {
              if (submittedProposal != null &&
                  appliedProposals.contains(remoteId)) {
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.updateProposal(
                          proposal.copyWith(localId: existingProposal.localId),
                        )
                      : dbService.writeForSession(
                          table: 'proposals',
                          values: proposal
                              .copyWith(localId: existingProposal.localId)
                              .toMap(),
                          where: '''
                            local_id = ? AND updated_at = ? AND is_dirty = 1
                          ''',
                          whereArgs: [
                            existingProposal.localId,
                            submittedProposal.updatedAt.toIso8601String(),
                          ],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              } else if (submittedProposal == null &&
                  !existingProposal.isDirty) {
                await _writeForCurrent(
                  session,
                  () => sessionManager == null
                      ? dbService.updateProposal(
                          proposal.copyWith(localId: existingProposal.localId),
                        )
                      : dbService.writeForSession(
                          table: 'proposals',
                          values: proposal
                              .copyWith(localId: existingProposal.localId)
                              .toMap(),
                          where: 'local_id = ?',
                          whereArgs: [existingProposal.localId],
                          isSessionCurrent: () => _isCurrent(session),
                        ),
                );
              }
            } else {
              await _writeForCurrent(
                session,
                () => sessionManager == null
                    ? dbService.insertProposal(proposal)
                    : dbService.writeForSession(
                        table: 'proposals',
                        values: proposal.toMap(),
                        insert: true,
                        isSessionCurrent: () => _isCurrent(session),
                      ),
              );
            }
          }
        }
      }
    }

    Future<int> markAsSynced(
      String table,
      String remoteId, {
      required String submittedUpdatedAt,
    }) =>
        sessionManager == null
            ? dbService.markAsSynced(
                table,
                remoteId,
                franchiseeId: activeFranchiseeId,
                submittedUpdatedAt: submittedUpdatedAt,
              )
            : dbService.markAsSyncedForSession(
                table,
                remoteId,
                franchiseeId: activeFranchiseeId,
                submittedUpdatedAt: submittedUpdatedAt,
                isSessionCurrent: () => _isCurrent(session),
              );

    // 4. Clear dirty flags for records we just sent
    for (var c in clientsToMarkSynced) {
      if (appliedClients.contains(c.remoteId)) {
        await _writeForCurrent(
          session,
          () => markAsSynced(
            'clients',
            c.remoteId,
            submittedUpdatedAt: c.updatedAt.toIso8601String(),
          ),
        );
      }
    }
    for (var i in itemsToSync) {
      if (appliedItems.contains(i.remoteId)) {
        await _writeForCurrent(
          session,
          () => markAsSynced(
            'items',
            i.remoteId,
            submittedUpdatedAt: i.updatedAt.toIso8601String(),
          ),
        );
      }
    }
    for (var r in rectanglesToSync) {
      if (appliedRectangles.contains(r.remoteId)) {
        await _writeForCurrent(
          session,
          () => markAsSynced(
            'rectangles',
            r.remoteId,
            submittedUpdatedAt: r.updatedAt.toIso8601String(),
          ),
        );
      }
    }
    for (final price in dirtyDefaultPrices) {
      if (appliedDefaultPrices.contains(price.remoteId)) {
        await _writeForCurrent(
          session,
          () => markAsSynced(
            'default_prices',
            price.remoteId,
            submittedUpdatedAt: price.updatedAt.toIso8601String(),
          ),
        );
      }
    }
    for (var w in warrantiesToSync) {
      if (tombstonedWarranties.contains(w.remoteId)) {
        await _writeForCurrent(
          session,
          () => sessionManager == null
              ? dbService.hardDeleteWarrantyByRemoteId(w.remoteId)
              : dbService.writeForSession(
                  table: 'warranties',
                  values: const {},
                  delete: true,
                  where: '''
                    remote_id = ?
                    AND client_id IN (
                      SELECT local_id FROM clients WHERE franchisee_id = ?
                    )
                  ''',
                  whereArgs: [w.remoteId, activeFranchiseeId],
                  isSessionCurrent: () => _isCurrent(session),
                ),
        );
      } else if (appliedWarranties.contains(w.remoteId)) {
        await _writeForCurrent(
          session,
          () => markAsSynced(
            'warranties',
            w.remoteId,
            submittedUpdatedAt: w.updatedAt.toIso8601String(),
          ),
        );
      }
    }
    for (var p in proposalsToSync) {
      if (appliedProposals.contains(p.remoteId)) {
        await _writeForCurrent(
          session,
          () => markAsSynced(
            'proposals',
            p.remoteId,
            submittedUpdatedAt: p.updatedAt.toIso8601String(),
          ),
        );
      }
    }

    // 5. Save the v1 compatibility cursor in the tenant-owned APP-111 state.
    _requireCurrent(session);
    if (shouldFilterByFranchise && sessionManager != null) {
      await _writeForCurrent(
        session,
        () => dbService.setSyncV1CursorForSession(
          activeFranchiseeId,
          serverTime,
          expectedCursor: lastSyncTime,
          isSessionCurrent: () => _isCurrent(session),
        ),
      );
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

  String _payloadHash(String collection, Map<String, dynamic> payload) =>
      canonicalLwwMutablePayloadHash(collection, payload);

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
    final canonicalPayload = canonicalLwwMutablePayload(collection, payload);
    if (canonicalLwwJson(payload) != canonicalLwwJson(canonicalPayload)) {
      throw _protocolError('$collection.payload is not canonical.');
    }
    if (_payloadHash(collection, canonicalPayload) != record['payload_hash']) {
      throw _protocolError('$collection.payload_hash does not match payload.');
    }
    record['payload'] = canonicalPayload;
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
    SessionSnapshot? session, {
    bool requireDurableReceipt = false,
  }) async {
    var authoritativeChanged = false;
    for (final pending in await dbService.getPendingClientPhotoUploads(
      franchiseeId,
    )) {
      final remoteId = pending['client_remote_id']!;
      final photo = pending['local_path']!;
      final uploadId = pending['upload_id'];
      try {
        if (photo.startsWith('/api/photos/client/')) {
          _requireCurrent(session);
          await dbService.acknowledgeClientPhotoUploadForSession(
            franchiseeId: franchiseeId,
            remoteId: remoteId,
            localPath: photo,
            canonicalPath: photo,
            uploadId: uploadId,
            isSessionCurrent: () => _isCurrent(session),
          );
          continue;
        }
        final uri = Uri.tryParse(photo);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.path.startsWith('/api/photos/client/')) {
          if (apiService.resolveProtectedClientPhotoUrl(photo) == null ||
              uri.hasQuery ||
              uri.hasFragment ||
              uri.userInfo.isNotEmpty) {
            throw const FormatException(
              'Photo acknowledgement is not on the configured server.',
            );
          }
          await dbService.acknowledgeClientPhotoUploadForSession(
            franchiseeId: franchiseeId,
            remoteId: remoteId,
            localPath: photo,
            canonicalPath: uri.path,
            uploadId: uploadId,
            isSessionCurrent: () => _isCurrent(session),
          );
          continue;
        }
        String? digest;
        if (session != null || requireDurableReceipt) {
          final bytes = await File(photo).readAsBytes();
          _requireCurrent(session);
          digest = sha256.convert(bytes).toString();
          final persistedDigest = pending['file_sha256'];
          if (persistedDigest != null && persistedDigest != digest) {
            throw const FormatException(
              'The selected photo changed. Remove and add it again before retrying.',
            );
          }
          if (uploadId == null) {
            throw StateError(
                'A durable photo upload is missing its upload ID.');
          }
          if (session == null) {
            await dbService.persistPendingPhotoUploadDigest(
              franchiseeId: franchiseeId,
              remoteId: remoteId,
              uploadId: uploadId,
              localPath: photo,
              fileSha256: digest,
            );
          } else {
            await dbService.persistPendingPhotoUploadDigestForSession(
              franchiseeId: franchiseeId,
              remoteId: remoteId,
              uploadId: uploadId,
              localPath: photo,
              fileSha256: digest,
              isSessionCurrent: () => _isCurrent(session),
            );
          }
          _requireCurrent(session);
        }
        final canonical = await _uploadPhoto(
          remoteId,
          photo,
          session,
          uploadId,
          digest,
        );
        _requireCurrent(session);
        authoritativeChanged = true;
        await dbService.acknowledgeClientPhotoUploadForSession(
          franchiseeId: franchiseeId,
          remoteId: remoteId,
          localPath: photo,
          canonicalPath: canonical,
          uploadId: uploadId,
          isSessionCurrent: () => _isCurrent(session),
        );
      } on Object catch (error, stackTrace) {
        return _PhotoUploadResult(
          authoritativeChanged: authoritativeChanged,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return _PhotoUploadResult(authoritativeChanged: authoritativeChanged);
  }

  Future<bool> _deletePendingV2Proposals(
    String franchiseeId,
    SessionSnapshot? session,
  ) async {
    final activeClientIds = (await dbService.getClientsForFranchisee(
      franchiseeId,
    ))
        .map((client) => client.localId)
        .whereType<int>()
        .toSet();
    var deleted = false;
    for (final proposal in await dbService.getDirtyProposalsForFranchisee(
      franchiseeId,
    )) {
      if (proposal.deletedAt == null ||
          !activeClientIds.contains(proposal.clientId)) {
        continue;
      }
      await _deleteProposal(proposal.remoteId, session);
      _requireCurrent(session);
      deleted = true;
    }
    return deleted;
  }

  Future<SyncRunResult> _syncV2(
    String franchiseeId,
    SessionSnapshot? session, {
    required bool activateProtocol,
    bool requireSubmittedAccepted = false,
    SyncPhaseListener? onPhase,
  }) async {
    final outcomes = <SyncOutcome>[
      ...await _syncV2Round(
        franchiseeId,
        session,
        activateProtocol: activateProtocol,
        requireSubmittedAccepted: requireSubmittedAccepted,
        onPhase: onPhase,
      ),
    ];
    onPhase?.call(SyncPhase.uploadingPhotos);
    final photoResult = await _uploadPendingV2ClientPhotos(
      franchiseeId,
      session,
    );
    Object? proposalError;
    StackTrace? proposalStackTrace;
    var proposalChanged = false;
    try {
      proposalChanged = await _deletePendingV2Proposals(franchiseeId, session);
    } on Object catch (error, stackTrace) {
      proposalError = error;
      proposalStackTrace = stackTrace;
    }
    if (photoResult.authoritativeChanged || proposalChanged) {
      // The dedicated endpoints advance/stamp the tenant cursor. Pull once
      // more so exact authoritative media/PDF state and cursor land atomically.
      outcomes.addAll(
        await _syncV2Round(
          franchiseeId,
          session,
          activateProtocol: false,
          onPhase: onPhase,
        ),
      );
    }
    if (photoResult.error != null) {
      Error.throwWithStackTrace(photoResult.error!, photoResult.stackTrace!);
    }
    if (proposalError != null) {
      Error.throwWithStackTrace(proposalError, proposalStackTrace!);
    }
    onPhase?.call(SyncPhase.finalising);
    return SyncRunResult(outcomes: outcomes);
  }

  Future<List<SyncOutcome>> _syncV2Round(
    String franchiseeId,
    SessionSnapshot? session, {
    required bool activateProtocol,
    bool includePending = true,
    bool requireSubmittedAccepted = false,
    SyncPhaseListener? onPhase,
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
    onPhase?.call(SyncPhase.sendingChanges);
    final response = await _requestV2({
      'protocol_version': 2,
      'request_id': requestId,
      'request_cursor': requestCursor,
      'warranty_tombstone_cursor': warrantyCursor,
      'changes': {
        for (final collection in _v2Collections)
          collection: changes[collection] ?? const [],
      },
    }, session);
    _requireCurrent(session);

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
      final warningChangeId = _v2Uuid(
        warning['change_id'],
        'warning.change_id',
      );
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
      {..._v2Collections, 'warranties', 'proposals', 'warranty_tombstones'},
      {..._v2Collections, 'warranties', 'proposals', 'warranty_tombstones'},
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

    _requireCurrent(session);
    onPhase?.call(SyncPhase.applyingUpdates);
    await dbService.applySyncV2ResponseForSession(
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
      isSessionCurrent: () => _isCurrent(session),
    );
    return [
      for (final entry in submittedByChangeId.entries)
        if (outcomeStatuses[entry.key] != null)
          SyncOutcome(
            collection: entry.value['collection']!,
            status: _syncOutcomeStatusFromWire(outcomeStatuses[entry.key]!),
          ),
    ];
  }
}
