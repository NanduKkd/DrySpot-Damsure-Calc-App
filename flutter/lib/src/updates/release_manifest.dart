import 'dart:convert';

/// The release endpoint is deliberately independent from the configurable API
/// base URL. It is a release-policy trust boundary, not an API route.
const String releaseManifestEndpoint =
    'https://damsure.nandakrishnan.in/releases/manifest.json';

const String _releaseHost = 'damsure.nandakrishnan.in';
const int _schemaVersion = 1;
const int _maxSignedInt32 = 2147483647;
const int _maxReasonLength = 500;
const int _maxReleaseNotesLength = 4000;

enum ReleaseManifestParseFailure {
  invalidDocument,
  unknownOrMissingFields,
  invalidDisabledManifest,
  invalidAvailableManifest,
}

/// A strictly validated, actionable release policy.
///
/// This model contains only fields from a successful available manifest. A
/// malformed result never retains untrusted artifact URLs or release text.
class AvailableReleaseManifest {
  const AvailableReleaseManifest({
    required this.manifestRevision,
    required this.latestVersion,
    required this.latestVersionCode,
    required this.minimumSupportedVersionCode,
    required this.artifactUrl,
    required this.sha256,
    required this.sizeBytes,
    required this.publishedAt,
    required this.releaseNotes,
    required this.requiredUpdateReason,
  });

  final int manifestRevision;
  final String latestVersion;
  final int latestVersionCode;
  final int minimumSupportedVersionCode;
  final Uri artifactUrl;
  final String sha256;
  final int sizeBytes;
  final DateTime publishedAt;
  final String releaseNotes;
  final String requiredUpdateReason;

  /// A deterministic, unambiguous identity for APP-113 high-water persistence.
  ///
  /// This ordered canonical JSON payload is deliberately not a cryptographic
  /// signature. JSON escaping and fixed field order make every exact field
  /// boundary unambiguous without a hash dependency. APP-113 persists it after
  /// trusted transport, strict parsing, and anti-rollback validation so
  /// required policy survives restart/offline. Downloaded-APK verification is
  /// a separate install gate.
  String get canonicalFingerprint => jsonEncode(<String, Object?>{
        'schemaVersion': _schemaVersion,
        'updatesEnabled': true,
        'manifestRevision': manifestRevision,
        'latestVersion': latestVersion,
        'latestVersionCode': latestVersionCode,
        'minimumSupportedVersionCode': minimumSupportedVersionCode,
        'artifactUrl': artifactUrl.toString(),
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'publishedAt': _formatCanonicalUtc(publishedAt),
        'releaseNotes': releaseNotes,
        'requiredUpdateReason': requiredUpdateReason,
      });
}

class DisabledReleaseManifest {
  const DisabledReleaseManifest({
    required this.manifestRevision,
    required this.publishedAt,
    required this.reason,
  });

  final int manifestRevision;
  final DateTime publishedAt;
  final String reason;

  /// The canonical identity for a strict v1 disabled policy.
  String get canonicalFingerprint => jsonEncode(<String, Object?>{
        'schemaVersion': _schemaVersion,
        'updatesEnabled': false,
        'manifestRevision': manifestRevision,
        'publishedAt': _formatCanonicalUtc(publishedAt),
        'reason': reason,
      });
}

sealed class ReleaseManifestParseResult {
  const ReleaseManifestParseResult();

  bool get isMalformed => this is MalformedReleaseManifest;
}

/// A strictly parsed policy that is safe to offer to anti-rollback helpers.
/// Malformed input has no subtype here and cannot become a high-water value.
sealed class ValidReleaseManifestResult extends ReleaseManifestParseResult {
  const ValidReleaseManifestResult();

  int get manifestRevision;
  String get canonicalFingerprint;
  bool get isLegacyDisabled;
}

class AvailableReleaseManifestResult extends ValidReleaseManifestResult {
  const AvailableReleaseManifestResult(this.manifest);

  final AvailableReleaseManifest manifest;

  @override
  int get manifestRevision => manifest.manifestRevision;

  @override
  String get canonicalFingerprint => manifest.canonicalFingerprint;

  @override
  bool get isLegacyDisabled => false;
}

class DisabledReleaseManifestResult extends ValidReleaseManifestResult {
  const DisabledReleaseManifestResult(this.manifest, {this.isLegacy = false});

  final DisabledReleaseManifest manifest;
  final bool isLegacy;

  @override
  int get manifestRevision => manifest.manifestRevision;

  @override
  String get canonicalFingerprint => manifest.canonicalFingerprint;

  @override
  bool get isLegacyDisabled => isLegacy;
}

/// Does not carry any values from the rejected document.
class MalformedReleaseManifest extends ReleaseManifestParseResult {
  const MalformedReleaseManifest(this.failure);

  final ReleaseManifestParseFailure failure;
}

/// Parses decoded JSON with an explicit trusted UTC reference time.
///
/// A device clock must not be passed as [trustedNowUtc]. APP-113 will obtain a
/// trusted reference from the release response and persist accepted policy.
class ReleaseManifestParser {
  const ReleaseManifestParser._();

  static ReleaseManifestParseResult parse(
    Object? document, {
    required DateTime trustedNowUtc,
  }) {
    if (document is! Map<Object?, Object?> ||
        document.keys.any((key) => key is! String)) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidDocument,
      );
    }

    final json = Map<String, Object?>.from(document);
    if (_hasExactKeys(json, _availableFields)) {
      return _parseAvailable(json, trustedNowUtc.toUtc());
    }
    if (_hasExactKeys(json, _disabledFields)) {
      return _parseDisabled(json, trustedNowUtc.toUtc());
    }
    if (_hasExactKeys(json, _legacyDisabledFields)) {
      return _parseLegacyDisabled(json);
    }
    return const MalformedReleaseManifest(
      ReleaseManifestParseFailure.unknownOrMissingFields,
    );
  }

  static ReleaseManifestParseResult _parseAvailable(
    Map<String, Object?> json,
    DateTime trustedNowUtc,
  ) {
    if (!_isExactInt(json['schemaVersion'], _schemaVersion) ||
        json['updatesEnabled'] != true ||
        !_isPositiveSignedInt32(json['manifestRevision']) ||
        !_isFinalVersion(json['latestVersion']) ||
        !_isPositiveSignedInt32(json['latestVersionCode']) ||
        !_isPositiveSignedInt32(json['minimumSupportedVersionCode']) ||
        !_isPositiveSignedInt32(json['sizeBytes']) ||
        !_isBoundedTrimmedString(
          json['releaseNotes'],
          _maxReleaseNotesLength,
        ) ||
        !_isBoundedTrimmedString(
          json['requiredUpdateReason'],
          _maxReasonLength,
        ) ||
        !_isSha256(json['sha256'])) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidAvailableManifest,
      );
    }

    final latestCode = json['latestVersionCode'] as int;
    final minimumCode = json['minimumSupportedVersionCode'] as int;
    if (minimumCode > latestCode) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidAvailableManifest,
      );
    }

    final publishedAt = _parseCanonicalUtc(json['publishedAt']);
    if (publishedAt == null ||
        publishedAt.isAfter(trustedNowUtc.add(const Duration(minutes: 5)))) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidAvailableManifest,
      );
    }

    final artifactUrl = _parseArtifactUrl(json['artifactUrl'], latestCode);
    if (artifactUrl == null) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidAvailableManifest,
      );
    }

    return AvailableReleaseManifestResult(
      AvailableReleaseManifest(
        manifestRevision: json['manifestRevision'] as int,
        latestVersion: json['latestVersion'] as String,
        latestVersionCode: latestCode,
        minimumSupportedVersionCode: minimumCode,
        artifactUrl: artifactUrl,
        sha256: json['sha256'] as String,
        sizeBytes: json['sizeBytes'] as int,
        publishedAt: publishedAt,
        releaseNotes: json['releaseNotes'] as String,
        requiredUpdateReason: json['requiredUpdateReason'] as String,
      ),
    );
  }

  static ReleaseManifestParseResult _parseDisabled(
    Map<String, Object?> json,
    DateTime trustedNowUtc,
  ) {
    if (!_isExactInt(json['schemaVersion'], _schemaVersion) ||
        json['updatesEnabled'] != false ||
        !_isPositiveSignedInt32(json['manifestRevision']) ||
        !_isBoundedTrimmedString(json['reason'], _maxReasonLength)) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidDisabledManifest,
      );
    }
    final publishedAt = _parseCanonicalUtc(json['publishedAt']);
    if (publishedAt == null ||
        publishedAt.isAfter(trustedNowUtc.add(const Duration(minutes: 5)))) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidDisabledManifest,
      );
    }
    return DisabledReleaseManifestResult(
      DisabledReleaseManifest(
        manifestRevision: json['manifestRevision'] as int,
        publishedAt: publishedAt,
        reason: json['reason'] as String,
      ),
    );
  }

  static ReleaseManifestParseResult _parseLegacyDisabled(
    Map<String, Object?> json,
  ) {
    if (json['status'] != 'unavailable' ||
        json['updatesEnabled'] != false ||
        json['message'] != 'No Android release has been published.' ||
        json['publishedAt'] != null) {
      return const MalformedReleaseManifest(
        ReleaseManifestParseFailure.invalidDisabledManifest,
      );
    }
    return DisabledReleaseManifestResult(
      DisabledReleaseManifest(
        manifestRevision: 0,
        publishedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        reason: json['message'] as String,
      ),
      isLegacy: true,
    );
  }
}

const Set<String> _availableFields = {
  'schemaVersion',
  'updatesEnabled',
  'manifestRevision',
  'latestVersion',
  'latestVersionCode',
  'minimumSupportedVersionCode',
  'artifactUrl',
  'sha256',
  'sizeBytes',
  'publishedAt',
  'releaseNotes',
  'requiredUpdateReason',
};

const Set<String> _disabledFields = {
  'schemaVersion',
  'updatesEnabled',
  'manifestRevision',
  'publishedAt',
  'reason',
};

const Set<String> _legacyDisabledFields = {
  'status',
  'updatesEnabled',
  'message',
  'publishedAt',
};

bool _hasExactKeys(Map<String, Object?> json, Set<String> expected) =>
    json.length == expected.length && json.keys.toSet().containsAll(expected);

bool _isExactInt(Object? value, int expected) =>
    value is int && value == expected;

bool _isPositiveSignedInt32(Object? value) =>
    value is int && value > 0 && value <= _maxSignedInt32;

bool _isBoundedTrimmedString(Object? value, int maxLength) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maxLength &&
    value.trim() == value;

bool _isFinalVersion(Object? value) =>
    value is String &&
    RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
    ).hasMatch(value);

bool _isSha256(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

DateTime? _parseCanonicalUtc(Object? value) {
  if (value is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value)) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc || _formatCanonicalUtc(parsed) != value) {
    return null;
  }
  return parsed;
}

String _formatCanonicalUtc(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

Uri? _parseArtifactUrl(Object? value, int versionCode) {
  if (value is! String) {
    return null;
  }
  final expected = 'https://$_releaseHost/releases/damsure-$versionCode.apk';
  if (value != expected) {
    return null;
  }
  final parsed = Uri.tryParse(value);
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.host != _releaseHost ||
      parsed.hasPort ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      parsed.path != '/releases/damsure-$versionCode.apk') {
    return null;
  }
  return parsed;
}

enum ReleaseUpdateState { current, optional, required, disabled, malformed }

/// Safe state supplied to a future updater/UI. Only valid available manifests
/// can expose an artifact or release notes.
class ReleaseUpdateClassification {
  const ReleaseUpdateClassification._({required this.state, this.manifest});

  final ReleaseUpdateState state;
  final AvailableReleaseManifest? manifest;

  Uri? get artifactUrl => manifest?.artifactUrl;
  String? get releaseNotes => manifest?.releaseNotes;
  String? get requiredUpdateReason => manifest?.requiredUpdateReason;
}

ReleaseUpdateClassification classifyReleaseUpdate(
  ReleaseManifestParseResult result, {
  required int installedVersionCode,
}) {
  if (installedVersionCode <= 0) {
    throw ArgumentError.value(
      installedVersionCode,
      'installedVersionCode',
      'must be positive',
    );
  }
  if (result is MalformedReleaseManifest) {
    return const ReleaseUpdateClassification._(
      state: ReleaseUpdateState.malformed,
    );
  }
  if (result is DisabledReleaseManifestResult) {
    return const ReleaseUpdateClassification._(
      state: ReleaseUpdateState.disabled,
    );
  }
  final manifest = (result as AvailableReleaseManifestResult).manifest;
  final state = installedVersionCode < manifest.minimumSupportedVersionCode
      ? ReleaseUpdateState.required
      : installedVersionCode < manifest.latestVersionCode
          ? ReleaseUpdateState.optional
          : ReleaseUpdateState.current;
  return ReleaseUpdateClassification._(state: state, manifest: manifest);
}

/// The persisted APP-113 high-water values needed to reject policy rollback.
///
/// This represents a strict v1 policy only. A legacy disabled response is
/// accepted solely before any v1 state exists and therefore cannot create,
/// replace, or clear one of these values. Persistence and lifecycle policy are
/// deliberately outside APP-104.
class ReleaseManifestHighWaterMark {
  const ReleaseManifestHighWaterMark._({
    required this.manifestRevision,
    required this.canonicalFingerprint,
    required this.latestVersionCode,
    required this.minimumSupportedVersionCode,
  });

  final int manifestRevision;
  final String canonicalFingerprint;

  /// Historical maximums survive a newer disabled policy so a later available
  /// policy cannot regress either version-code threshold.
  final int? latestVersionCode;
  final int? minimumSupportedVersionCode;

  /// Creates the next persisted high-water value from an accepted strict v1
  /// policy. Callers must validate it first with [validateManifestHighWater].
  /// A legacy response intentionally has no v1 high-water representation.
  factory ReleaseManifestHighWaterMark.fromAcceptedPolicy(
    ValidReleaseManifestResult policy, {
    ReleaseManifestHighWaterMark? previous,
  }) {
    if (policy.isLegacyDisabled) {
      throw ArgumentError.value(
        policy,
        'policy',
        'a legacy disabled response must not advance v1 policy state',
      );
    }
    final available = switch (policy) {
      AvailableReleaseManifestResult(:final manifest) => manifest,
      DisabledReleaseManifestResult() => null,
    };
    return ReleaseManifestHighWaterMark._(
      manifestRevision: policy.manifestRevision,
      canonicalFingerprint: policy.canonicalFingerprint,
      latestVersionCode:
          available?.latestVersionCode ?? previous?.latestVersionCode,
      minimumSupportedVersionCode: available?.minimumSupportedVersionCode ??
          previous?.minimumSupportedVersionCode,
    );
  }
}

enum ReleaseManifestRollbackFailure {
  revisionRegression,
  changedPayloadAtSameRevision,
  latestVersionCodeRegression,
  minimumSupportedVersionCodeRegression,
  legacyDisabledAfterV1Policy,
}

class ReleaseManifestRollbackValidation {
  const ReleaseManifestRollbackValidation._(this.failure);
  const ReleaseManifestRollbackValidation.accepted() : failure = null;

  final ReleaseManifestRollbackFailure? failure;
  bool get isAccepted => failure == null;
}

/// Validates a strictly parsed common policy against persisted v1 high-water.
///
/// It rejects lower revisions, a changed payload at the same revision, and
/// lower latest/minimum codes than any previously accepted available policy.
/// A newer strict disabled policy may relax an active required policy, but its
/// next high-water mark retains historical version-code maximums. An exact
/// legacy disabled response is only accepted before v1 state exists.
ReleaseManifestRollbackValidation validateManifestHighWater(
  ValidReleaseManifestResult candidate, {
  ReleaseManifestHighWaterMark? previous,
}) {
  if (candidate.isLegacyDisabled) {
    if (previous != null) {
      return const ReleaseManifestRollbackValidation._(
        ReleaseManifestRollbackFailure.legacyDisabledAfterV1Policy,
      );
    }
    return const ReleaseManifestRollbackValidation.accepted();
  }
  if (previous == null) {
    return const ReleaseManifestRollbackValidation.accepted();
  }
  if (candidate.manifestRevision < previous.manifestRevision) {
    return const ReleaseManifestRollbackValidation._(
      ReleaseManifestRollbackFailure.revisionRegression,
    );
  }
  if (candidate.manifestRevision == previous.manifestRevision &&
      candidate.canonicalFingerprint != previous.canonicalFingerprint) {
    return const ReleaseManifestRollbackValidation._(
      ReleaseManifestRollbackFailure.changedPayloadAtSameRevision,
    );
  }
  if (candidate case AvailableReleaseManifestResult(:final manifest)) {
    if (previous.latestVersionCode != null &&
        manifest.latestVersionCode < previous.latestVersionCode!) {
      return const ReleaseManifestRollbackValidation._(
        ReleaseManifestRollbackFailure.latestVersionCodeRegression,
      );
    }
    if (previous.minimumSupportedVersionCode != null &&
        manifest.minimumSupportedVersionCode <
            previous.minimumSupportedVersionCode!) {
      return const ReleaseManifestRollbackValidation._(
        ReleaseManifestRollbackFailure.minimumSupportedVersionCodeRegression,
      );
    }
  }
  return const ReleaseManifestRollbackValidation.accepted();
}
