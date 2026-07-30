import 'dart:convert';

import 'package:crypto/crypto.dart';

dynamic _stableJsonValue(dynamic value) {
  if (value is List) return value.map(_stableJsonValue).toList();
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {
      for (final key in keys) key: _stableJsonValue(value[key]),
    };
  }
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return value;
}

String canonicalLwwPayloadHash(Map<String, dynamic> payload) => sha256
    .convert(utf8.encode(jsonEncode(_stableJsonValue(payload))))
    .toString();
