import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'release_manifest.dart';

class UpdatePolicyStoreException implements Exception {
  const UpdatePolicyStoreException();
}

class UpdateAcceptedPolicy {
  const UpdateAcceptedPolicy({
    required this.policy,
    required this.highWater,
    required this.trustedResponseAt,
  });

  final ValidReleaseManifestResult policy;
  final ReleaseManifestHighWaterMark highWater;
  final DateTime trustedResponseAt;
}

enum UpdatePolicyLoadKind { empty, valid, corrupt, unavailable }

class UpdatePolicyLoad {
  const UpdatePolicyLoad._(this.kind, this.acceptedPolicy);
  const UpdatePolicyLoad.empty() : this._(UpdatePolicyLoadKind.empty, null);
  const UpdatePolicyLoad.corrupt() : this._(UpdatePolicyLoadKind.corrupt, null);
  const UpdatePolicyLoad.unavailable()
      : this._(UpdatePolicyLoadKind.unavailable, null);
  const UpdatePolicyLoad.valid(UpdateAcceptedPolicy policy)
      : this._(UpdatePolicyLoadKind.valid, policy);

  final UpdatePolicyLoadKind kind;
  final UpdateAcceptedPolicy? acceptedPolicy;
}

class OptionalUpdateDismissal {
  const OptionalUpdateDismissal({
    required this.targetVersionCode,
    required this.trustedDismissedAt,
  });

  final int targetVersionCode;
  final DateTime trustedDismissedAt;
}

/// Stores each security-relevant policy/high-water snapshot in a single
/// preference value. A crash can leave either the old complete record or the
/// new complete record, never a mixture of the two.
class UpdatePolicyStore {
  UpdatePolicyStore({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _policyKey = 'app113.accepted_policy.v1';
  static const _dismissalKey = 'app113.optional_dismissal.v1';
  final Future<SharedPreferences> Function() _preferences;

  Future<UpdatePolicyLoad> load() async {
    try {
      final value = (await _preferences()).getString(_policyKey);
      if (value == null) return const UpdatePolicyLoad.empty();
      return _decodePolicy(value);
    } catch (_) {
      return const UpdatePolicyLoad.unavailable();
    }
  }

  Future<UpdateAcceptedPolicy?> accept(
    ValidReleaseManifestResult candidate, {
    required DateTime trustedResponseAt,
  }) async {
    // Re-read the one atomic policy record at the commit boundary.  This keeps
    // high-water and trusted-time validation coupled even if a future caller
    // forgets to retain its own in-memory snapshot.
    final loaded = await load();
    if (loaded.kind == UpdatePolicyLoadKind.corrupt ||
        loaded.kind == UpdatePolicyLoadKind.unavailable) {
      throw const UpdatePolicyStoreException();
    }
    final previous = loaded.acceptedPolicy;
    if (!validateManifestHighWater(
      candidate,
      previous: previous?.highWater,
    ).isAccepted) {
      throw const UpdatePolicyStoreException();
    }
    final normalizedTrustedResponseAt = trustedResponseAt.toUtc();
    // A response Date is part of the policy's anti-rollback boundary.  The
    // same atomically accepted snapshot as its high-water mark. Accepting an
    // older Date would let a replayed response alter dismissal or policy
    // evaluation time.
    if (previous != null &&
        normalizedTrustedResponseAt.isBefore(
          previous.trustedResponseAt.toUtc(),
        )) {
      throw const UpdatePolicyStoreException();
    }
    // The exact legacy disabled response deliberately has no persisted state.
    if (candidate.isLegacyDisabled) return null;

    final highWater = ReleaseManifestHighWaterMark.fromAcceptedPolicy(
      candidate,
      previous: previous?.highWater,
    );
    final accepted = UpdateAcceptedPolicy(
      policy: candidate,
      highWater: highWater,
      trustedResponseAt: normalizedTrustedResponseAt,
    );
    final body = _policyRecordBody(accepted);
    final encoded = jsonEncode(<String, Object?>{
      ...body,
      'checksum': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    });
    try {
      final didWrite = await (await _preferences()).setString(
        _policyKey,
        encoded,
      );
      if (!didWrite) throw const UpdatePolicyStoreException();
    } catch (_) {
      throw const UpdatePolicyStoreException();
    }
    return accepted;
  }

  Future<OptionalUpdateDismissal?> loadDismissal() async {
    try {
      final value = (await _preferences()).getString(_dismissalKey);
      if (value == null) return null;
      final decoded = jsonDecode(value);
      if (decoded is! Map ||
          decoded.length != 3 ||
          decoded['recordVersion'] is! int ||
          decoded['recordVersion'] != 1 ||
          decoded['targetVersionCode'] is! int ||
          (decoded['targetVersionCode'] as int) <= 0 ||
          !_isCanonicalUtc(decoded['trustedDismissedAt'])) {
        return null;
      }
      return OptionalUpdateDismissal(
        targetVersionCode: decoded['targetVersionCode'] as int,
        trustedDismissedAt: DateTime.parse(
          decoded['trustedDismissedAt'] as String,
        ).toUtc(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> dismissOptional(
    int targetVersionCode,
    DateTime trustedDismissedAt,
  ) async {
    final payload = jsonEncode(<String, Object?>{
      'recordVersion': 1,
      'targetVersionCode': targetVersionCode,
      'trustedDismissedAt': _formatUtc(trustedDismissedAt),
    });
    try {
      if (!await (await _preferences()).setString(_dismissalKey, payload)) {
        throw const UpdatePolicyStoreException();
      }
    } catch (_) {
      throw const UpdatePolicyStoreException();
    }
  }

  UpdatePolicyLoad _decodePolicy(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map ||
          decoded.length != 5 ||
          decoded['recordVersion'] != 1 ||
          !_isCanonicalUtc(decoded['trustedResponseAt']) ||
          decoded['policy'] is! Map ||
          decoded['highWater'] is! Map ||
          decoded['checksum'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(decoded['checksum'] as String)) {
        return const UpdatePolicyLoad.corrupt();
      }
      final trustedTime = DateTime.parse(
        decoded['trustedResponseAt'] as String,
      ).toUtc();
      final policy = ReleaseManifestParser.parse(
        Map<Object?, Object?>.from(decoded['policy'] as Map),
        trustedNowUtc: trustedTime,
      );
      if (policy is! ValidReleaseManifestResult || policy.isLegacyDisabled) {
        return const UpdatePolicyLoad.corrupt();
      }
      final highWater = _decodeHighWater(decoded['highWater'] as Map);
      if (highWater == null || !_matchesPersistedPolicy(highWater, policy)) {
        return const UpdatePolicyLoad.corrupt();
      }
      final accepted = UpdateAcceptedPolicy(
        policy: policy,
        highWater: highWater,
        trustedResponseAt: trustedTime,
      );
      final expectedChecksum = sha256
          .convert(utf8.encode(jsonEncode(_policyRecordBody(accepted))))
          .toString();
      if (decoded['checksum'] != expectedChecksum) {
        return const UpdatePolicyLoad.corrupt();
      }
      return UpdatePolicyLoad.valid(
        accepted,
      );
    } catch (_) {
      return const UpdatePolicyLoad.corrupt();
    }
  }
}

Map<String, Object?> _policyRecordBody(UpdateAcceptedPolicy accepted) =>
    <String, Object?>{
      'recordVersion': 1,
      'trustedResponseAt': _formatUtc(accepted.trustedResponseAt),
      'policy': _policyPayload(accepted.policy),
      'highWater': _highWaterPayload(accepted.highWater),
    };

Map<String, Object?> _policyPayload(ValidReleaseManifestResult policy) {
  if (policy case AvailableReleaseManifestResult(:final manifest)) {
    return <String, Object?>{
      'schemaVersion': 1,
      'updatesEnabled': true,
      'manifestRevision': manifest.manifestRevision,
      'latestVersion': manifest.latestVersion,
      'latestVersionCode': manifest.latestVersionCode,
      'minimumSupportedVersionCode': manifest.minimumSupportedVersionCode,
      'artifactUrl': manifest.artifactUrl.toString(),
      'sha256': manifest.sha256,
      'sizeBytes': manifest.sizeBytes,
      'publishedAt': _formatUtc(manifest.publishedAt),
      'releaseNotes': manifest.releaseNotes,
      'requiredUpdateReason': manifest.requiredUpdateReason,
    };
  }
  final manifest = (policy as DisabledReleaseManifestResult).manifest;
  return <String, Object?>{
    'schemaVersion': 1,
    'updatesEnabled': false,
    'manifestRevision': manifest.manifestRevision,
    'publishedAt': _formatUtc(manifest.publishedAt),
    'reason': manifest.reason,
  };
}

Map<String, Object?> _highWaterPayload(ReleaseManifestHighWaterMark value) =>
    <String, Object?>{
      'manifestRevision': value.manifestRevision,
      'canonicalFingerprint': value.canonicalFingerprint,
      'latestVersionCode': value.latestVersionCode,
      'minimumSupportedVersionCode': value.minimumSupportedVersionCode,
    };

ReleaseManifestHighWaterMark? _decodeHighWater(Map<Object?, Object?> value) {
  if (value.length != 4 ||
      value['manifestRevision'] is! int ||
      (value['manifestRevision'] as int) <= 0 ||
      value['canonicalFingerprint'] is! String ||
      (value['latestVersionCode'] != null &&
          value['latestVersionCode'] is! int) ||
      (value['minimumSupportedVersionCode'] != null &&
          value['minimumSupportedVersionCode'] is! int)) {
    return null;
  }
  try {
    return ReleaseManifestHighWaterMark.restore(
      manifestRevision: value['manifestRevision'] as int,
      canonicalFingerprint: value['canonicalFingerprint'] as String,
      latestVersionCode: value['latestVersionCode'] as int?,
      minimumSupportedVersionCode: value['minimumSupportedVersionCode'] as int?,
    );
  } on ArgumentError {
    return null;
  }
}

bool _matchesPersistedPolicy(
  ReleaseManifestHighWaterMark highWater,
  ValidReleaseManifestResult policy,
) {
  if (highWater.manifestRevision != policy.manifestRevision ||
      highWater.canonicalFingerprint != policy.canonicalFingerprint) {
    return false;
  }
  if (policy case AvailableReleaseManifestResult(:final manifest)) {
    return highWater.latestVersionCode == manifest.latestVersionCode &&
        highWater.minimumSupportedVersionCode ==
            manifest.minimumSupportedVersionCode;
  }
  // A strict disabled policy retains any preceding available policy maxima;
  // their values cannot be derived from the disabled payload itself.
  return true;
}

bool _isCanonicalUtc(Object? value) =>
    value is String &&
    RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value) &&
    DateTime.tryParse(value)?.isUtc == true &&
    _formatUtc(DateTime.parse(value)) == value;

String _formatUtc(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}
