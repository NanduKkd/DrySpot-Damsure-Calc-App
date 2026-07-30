import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/updates/release_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

final _trustedNow = DateTime.utc(2026, 7, 30, 10);

void main() {
  Map<String, Object?> fixture(String name) => Map<String, Object?>.from(
        jsonDecode(
          File('test/fixtures/release_manifest/$name.json').readAsStringSync(),
        ) as Map,
      );

  ReleaseManifestParseResult parse(Map<String, Object?> payload) =>
      ReleaseManifestParser.parse(payload, trustedNowUtc: _trustedNow);

  AvailableReleaseManifestResult available(Map<String, Object?> payload) {
    final result = parse(payload);
    expect(result, isA<AvailableReleaseManifestResult>());
    return result as AvailableReleaseManifestResult;
  }

  DisabledReleaseManifestResult disabled(Map<String, Object?> payload) {
    final result = parse(payload);
    expect(result, isA<DisabledReleaseManifestResult>());
    return result as DisabledReleaseManifestResult;
  }

  test(
    'uses the immutable release endpoint instead of the API configuration',
    () {
      expect(
        releaseManifestEndpoint,
        'https://damsure.nandakrishnan.in/releases/manifest.json',
      );
    },
  );

  group('strict schema parsing and state classification', () {
    test(
      'classifies valid current, optional, required, and newer installs',
      () {
        final result = parse(fixture('available_current'));

        expect(
          classifyReleaseUpdate(result, installedVersionCode: 10400).state,
          ReleaseUpdateState.current,
        );
        expect(
          classifyReleaseUpdate(result, installedVersionCode: 10350).state,
          ReleaseUpdateState.optional,
        );
        expect(
          classifyReleaseUpdate(result, installedVersionCode: 10299).state,
          ReleaseUpdateState.required,
        );
        final newer = classifyReleaseUpdate(
          result,
          installedVersionCode: 10401,
        );
        expect(newer.state, ReleaseUpdateState.current);
        expect(newer.manifest!.artifactUrl.path, '/releases/damsure-10400.apk');
        expect(
          classifyReleaseUpdate(
            result,
            installedVersionCode: 10299,
          ).requiredUpdateReason,
          'Please update to continue using Damsure.',
        );
      },
    );

    test(
      'accepts only the v1 disabled shape and the exact legacy response',
      () {
        final v1 = parse(fixture('disabled_v1'));
        expect(v1, isA<DisabledReleaseManifestResult>());
        expect(
          classifyReleaseUpdate(v1, installedVersionCode: 1).state,
          ReleaseUpdateState.disabled,
        );

        final legacy = parse(fixture('disabled_legacy'));
        expect(legacy, isA<DisabledReleaseManifestResult>());
        expect((legacy as DisabledReleaseManifestResult).isLegacy, isTrue);
        expect(legacy.manifest.manifestRevision, 0);

        final legacyWithExtra = fixture('disabled_legacy')
          ..['artifactUrl'] = 'bad';
        expect(parse(legacyWithExtra), isA<MalformedReleaseManifest>());

        final arbitraryLegacyMessage = fixture('disabled_legacy')
          ..['message'] = 'A different unavailable message.';
        expect(parse(arbitraryLegacyMessage), isA<MalformedReleaseManifest>());

        final disabledWithRequiredUpdateReason = fixture('disabled_v1')
          ..['requiredUpdateReason'] = 'Not allowed for disabled manifests.';
        expect(
          parse(disabledWithRequiredUpdateReason),
          isA<MalformedReleaseManifest>(),
        );
      },
    );

    test('rejects unknown fields and does not expose malformed metadata', () {
      final payload = fixture('available_current')..['unexpected'] = true;
      final result = parse(payload);
      final classified = classifyReleaseUpdate(result, installedVersionCode: 1);

      expect(result, isA<MalformedReleaseManifest>());
      expect(classified.state, ReleaseUpdateState.malformed);
      expect(classified.manifest, isNull);
      expect(classified.artifactUrl, isNull);
      expect(classified.releaseNotes, isNull);
      expect(classified.requiredUpdateReason, isNull);
    });

    test(
      'rejects checksum, size, final version, and future timestamp errors',
      () {
        final badChecksum = fixture('available_current')
          ..['sha256'] =
              'A123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
        final badSize = fixture('available_current')..['sizeBytes'] = 0;
        final badVersion = fixture('available_current')
          ..['latestVersion'] = '1.4.0-rc.1';
        final leadingZeroVersion = fixture('available_current')
          ..['latestVersion'] = '01.4.0';
        final futureTimestamp = fixture('available_current')
          ..['publishedAt'] = '2026-07-30T10:05:01Z';

        for (final payload in [
          badChecksum,
          badSize,
          badVersion,
          leadingZeroVersion,
          futureTimestamp,
        ]) {
          expect(parse(payload), isA<MalformedReleaseManifest>());
        }
      },
    );

    test(
      'rejects noncanonical timestamps, revision zero, and invalid code ranges',
      () {
        final offsetTimestamp = fixture('available_current')
          ..['publishedAt'] = '2026-07-30T10:00:00+00:00';
        final zeroRevision = fixture('available_current')
          ..['manifestRevision'] = 0;
        final invalidRange = fixture('available_current')
          ..['minimumSupportedVersionCode'] = 10401;

        for (final payload in [offsetTimestamp, zeroRevision, invalidRange]) {
          expect(parse(payload), isA<MalformedReleaseManifest>());
        }
      },
    );

    test(
      'requires Dart ints for every numeric field, including schemaVersion',
      () {
        const numericFields = [
          'schemaVersion',
          'manifestRevision',
          'latestVersionCode',
          'minimumSupportedVersionCode',
          'sizeBytes',
        ];
        const wrongTypes = <Object?>[1.0, '1', true, null];

        for (final field in numericFields) {
          for (final wrongType in wrongTypes) {
            final payload = fixture('available_current')..[field] = wrongType;
            expect(
              parse(payload),
              isA<MalformedReleaseManifest>(),
              reason: '$field accepted ${wrongType.runtimeType}',
            );
          }
        }
      },
    );

    test('rejects oversized numeric fields', () {
      const numericFields = [
        'schemaVersion',
        'manifestRevision',
        'latestVersionCode',
        'minimumSupportedVersionCode',
        'sizeBytes',
      ];

      for (final field in numericFields) {
        final payload = fixture('available_current')..[field] = 2147483648;
        expect(
          parse(payload),
          isA<MalformedReleaseManifest>(),
          reason: '$field accepted a value above signed int32',
        );
      }
    });

    test('requires a bounded, trimmed required-update reason', () {
      final missing = fixture('available_current')
        ..remove('requiredUpdateReason');
      final blank = fixture('available_current')
        ..['requiredUpdateReason'] = ' ';
      final oversized = fixture('available_current')
        ..['requiredUpdateReason'] = List.filled(501, 'x').join();
      final extra = fixture('available_current')
        ..['unexpectedRequiredReason'] = 'not in schema';

      for (final payload in [missing, blank, oversized, extra]) {
        expect(parse(payload), isA<MalformedReleaseManifest>());
      }
    });
  });

  group('artifact URL boundary', () {
    test('production has no caller-controlled trusted-origin override', () {
      const stagingOrigin = 'https://staging.example.test';
      final staging = fixture('available_current')
        ..['artifactUrl'] = '$stagingOrigin/releases/damsure-10400.apk';
      expect(parse(staging), isA<MalformedReleaseManifest>());
    });

    test('rejects foreign-host, redirect-like, and code/path-mismatch URLs',
        () {
      final foreignHost = fixture('available_current')
        ..['artifactUrl'] = 'https://example.com/releases/damsure-10400.apk';
      final redirectLike = fixture('available_current')
        ..['artifactUrl'] =
            'https://damsure.nandakrishnan.in@evil.example/releases/damsure-10400.apk';
      final codeMismatch = fixture('available_current')
        ..['artifactUrl'] =
            'https://damsure.nandakrishnan.in/releases/damsure-10399.apk';

      for (final payload in [foreignHost, redirectLike, codeMismatch]) {
        expect(parse(payload), isA<MalformedReleaseManifest>());
      }
    });

    test('rejects credentials, query, fragment, and explicit port', () {
      final variants = [
        'https://user@damsure.nandakrishnan.in/releases/damsure-10400.apk',
        'https://damsure.nandakrishnan.in/releases/damsure-10400.apk?next=x',
        'https://damsure.nandakrishnan.in/releases/damsure-10400.apk#fragment',
        'https://damsure.nandakrishnan.in:443/releases/damsure-10400.apk',
      ];

      for (final url in variants) {
        final payload = fixture('available_current')..['artifactUrl'] = url;
        expect(parse(payload), isA<MalformedReleaseManifest>());
      }
    });
  });

  group('anti-rollback helpers', () {
    test(
      'accepts a matching high-water payload and rejects a revision regression',
      () {
        final baseline = available(fixture('available_current'));
        final highWater = ReleaseManifestHighWaterMark.fromAcceptedPolicy(
          baseline,
        );

        expect(
          validateManifestHighWater(baseline, previous: highWater).isAccepted,
          isTrue,
        );
        final regressionPayload = fixture('available_current')
          ..['manifestRevision'] = 41;
        final regression = validateManifestHighWater(
          available(regressionPayload),
          previous: highWater,
        );
        expect(
          regression.failure,
          ReleaseManifestRollbackFailure.revisionRegression,
        );
      },
    );

    test('includes required-update reason in the same-revision identity', () {
      final baseline = available(fixture('available_current'));
      final changedPayload = fixture('available_current')
        ..['requiredUpdateReason'] = 'A different required-update reason.';

      final result = validateManifestHighWater(
        available(changedPayload),
        previous: ReleaseManifestHighWaterMark.fromAcceptedPolicy(baseline),
      );
      expect(
        result.failure,
        ReleaseManifestRollbackFailure.changedPayloadAtSameRevision,
      );
    });

    test('rejects latest and minimum version-code regressions', () {
      final baseline = available(fixture('available_current'));
      final highWater = ReleaseManifestHighWaterMark.fromAcceptedPolicy(
        baseline,
      );
      final latestRegression = fixture('available_current')
        ..['manifestRevision'] = 43
        ..['latestVersionCode'] = 10399
        ..['minimumSupportedVersionCode'] = 10300
        ..['artifactUrl'] =
            'https://damsure.nandakrishnan.in/releases/damsure-10399.apk';
      final minimumRegression = fixture('available_current')
        ..['manifestRevision'] = 43
        ..['minimumSupportedVersionCode'] = 10299;

      expect(
        validateManifestHighWater(
          available(latestRegression),
          previous: highWater,
        ).failure,
        ReleaseManifestRollbackFailure.latestVersionCodeRegression,
      );
      expect(
        validateManifestHighWater(
          available(minimumRegression),
          previous: highWater,
        ).failure,
        ReleaseManifestRollbackFailure.minimumSupportedVersionCodeRegression,
      );
    });

    test(
      'uses canonical JSON so pipe-delimited field boundaries cannot collide',
      () {
        final first = fixture('available_current')
          ..['releaseNotes'] = 'First|second'
          ..['requiredUpdateReason'] = 'third';
        final second = fixture('available_current')
          ..['releaseNotes'] = 'First'
          ..['requiredUpdateReason'] = 'second|third';
        final firstPolicy = available(first);
        final secondPolicy = available(second);

        // This is the old delimiter representation that collided. Canonical JSON
        // keeps each string's boundary and type explicit.
        String oldDelimitedFingerprint(AvailableReleaseManifest manifest) => [
              1,
              true,
              manifest.manifestRevision,
              manifest.latestVersion,
              manifest.latestVersionCode,
              manifest.minimumSupportedVersionCode,
              manifest.artifactUrl.toString(),
              manifest.sha256,
              manifest.sizeBytes,
              manifest.publishedAt.toIso8601String(),
              manifest.releaseNotes,
              manifest.requiredUpdateReason,
            ].join('|');

        expect(
          oldDelimitedFingerprint(firstPolicy.manifest),
          oldDelimitedFingerprint(secondPolicy.manifest),
        );
        expect(
          firstPolicy.canonicalFingerprint,
          isNot(secondPolicy.canonicalFingerprint),
        );
        expect(
          validateManifestHighWater(
            secondPolicy,
            previous: ReleaseManifestHighWaterMark.fromAcceptedPolicy(
              firstPolicy,
            ),
          ).failure,
          ReleaseManifestRollbackFailure.changedPayloadAtSameRevision,
        );
      },
    );

    test(
      'validates strict disabled policies across common policy high-water',
      () {
        final availablePolicy = available(fixture('available_current'));
        final availableHighWater =
            ReleaseManifestHighWaterMark.fromAcceptedPolicy(availablePolicy);
        final disabledPolicy = disabled(fixture('disabled_v1'));

        expect(
          validateManifestHighWater(
            disabledPolicy,
            previous: availableHighWater,
          ).isAccepted,
          isTrue,
        );
        final disabledHighWater =
            ReleaseManifestHighWaterMark.fromAcceptedPolicy(
          disabledPolicy,
          previous: availableHighWater,
        );
        expect(disabledHighWater.latestVersionCode, 10400);
        expect(disabledHighWater.minimumSupportedVersionCode, 10300);

        expect(
          validateManifestHighWater(
            disabledPolicy,
            previous: disabledHighWater,
          ).isAccepted,
          isTrue,
        );

        final lowerRevision = fixture('disabled_v1')..['manifestRevision'] = 42;
        expect(
          validateManifestHighWater(
            disabled(lowerRevision),
            previous: disabledHighWater,
          ).failure,
          ReleaseManifestRollbackFailure.revisionRegression,
        );

        for (final changed in [
          fixture('disabled_v1')..['reason'] = 'A changed disabled reason.',
          fixture('disabled_v1')..['publishedAt'] = '2026-07-30T10:04:00Z',
        ]) {
          expect(
            validateManifestHighWater(
              disabled(changed),
              previous: disabledHighWater,
            ).failure,
            ReleaseManifestRollbackFailure.changedPayloadAtSameRevision,
          );
        }

        final laterVersionRegression = fixture('available_current')
          ..['manifestRevision'] = 44
          ..['latestVersionCode'] = 10399
          ..['artifactUrl'] =
              'https://damsure.nandakrishnan.in/releases/damsure-10399.apk';
        expect(
          validateManifestHighWater(
            available(laterVersionRegression),
            previous: disabledHighWater,
          ).failure,
          ReleaseManifestRollbackFailure.latestVersionCodeRegression,
        );

        final newerAvailable = fixture('available_current')
          ..['manifestRevision'] = 44;
        expect(
          validateManifestHighWater(
            available(newerAvailable),
            previous: disabledHighWater,
          ).isAccepted,
          isTrue,
        );
      },
    );

    test(
      'only accepts legacy disabled before v1 state and never persists it',
      () {
        final legacy = disabled(fixture('disabled_legacy'));
        final v1HighWater = ReleaseManifestHighWaterMark.fromAcceptedPolicy(
          available(fixture('available_current')),
        );

        expect(validateManifestHighWater(legacy).isAccepted, isTrue);
        expect(
          () => ReleaseManifestHighWaterMark.fromAcceptedPolicy(legacy),
          throwsArgumentError,
        );
        expect(
          validateManifestHighWater(legacy, previous: v1HighWater).failure,
          ReleaseManifestRollbackFailure.legacyDisabledAfterV1Policy,
        );
      },
    );
  });
}
