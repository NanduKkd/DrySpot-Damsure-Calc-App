import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class WarrantyReplacementIntent {
  const WarrantyReplacementIntent({
    required this.sourceWarrantyId,
    required this.idempotencyKey,
    required this.targetWarrantyId,
  });

  final String sourceWarrantyId;
  final String idempotencyKey;
  final String targetWarrantyId;

  Map<String, String> toJson() => {
        'source_warranty_id': sourceWarrantyId,
        'idempotency_key': idempotencyKey,
        'target_warranty_id': targetWarrantyId,
      };

  static WarrantyReplacementIntent? fromJson(
    Object? value, {
    required String expectedSourceWarrantyId,
  }) {
    if (value is! Map<String, dynamic>) return null;
    final sourceWarrantyId = value['source_warranty_id'];
    final idempotencyKey = value['idempotency_key'];
    final targetWarrantyId = value['target_warranty_id'];
    if (sourceWarrantyId != expectedSourceWarrantyId ||
        idempotencyKey is! String ||
        !_uuidPattern.hasMatch(idempotencyKey) ||
        targetWarrantyId is! String ||
        !_uuidPattern.hasMatch(targetWarrantyId)) {
      return null;
    }
    return WarrantyReplacementIntent(
      sourceWarrantyId: sourceWarrantyId as String,
      idempotencyKey: idempotencyKey,
      targetWarrantyId: targetWarrantyId.toLowerCase(),
    );
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class WarrantyReplacementIntentStore {
  WarrantyReplacementIntentStore({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  static const _keyPrefix = 'warranty_replacement_intent:';
  final Uuid _uuid;

  Future<WarrantyReplacementIntent> loadOrCreate(
    String sourceWarrantyId,
  ) async {
    if (sourceWarrantyId.trim().isEmpty) {
      throw ArgumentError.value(
        sourceWarrantyId,
        'sourceWarrantyId',
        'A replacement requires a synced source warranty ID.',
      );
    }
    final preferences = await SharedPreferences.getInstance();
    final key = '$_keyPrefix$sourceWarrantyId';
    final stored = preferences.getString(key);
    if (stored != null) {
      try {
        final intent = WarrantyReplacementIntent.fromJson(
          jsonDecode(stored),
          expectedSourceWarrantyId: sourceWarrantyId,
        );
        if (intent != null) return intent;
      } on FormatException {
        // Replace malformed local-only state with a new valid intent.
      }
    }

    final intent = WarrantyReplacementIntent(
      sourceWarrantyId: sourceWarrantyId,
      idempotencyKey: _uuid.v4(),
      targetWarrantyId: _uuid.v4(),
    );
    final persisted = await preferences.setString(key, jsonEncode(intent));
    if (!persisted) {
      throw StateError('Could not persist the warranty replacement identity.');
    }
    return intent;
  }

  Future<void> clear(String sourceWarrantyId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_keyPrefix$sourceWarrantyId');
  }
}
