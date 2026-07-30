import 'dart:convert';
import 'dart:typed_data';

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

String canonicalLwwJson(dynamic value) => jsonEncode(_stableJsonValue(value));

String canonicalLwwPayloadHash(Map<String, dynamic> payload) =>
    sha256.convert(utf8.encode(canonicalLwwJson(payload))).toString();

dynamic _canonicalJsonNumber(double value) {
  final normalized = value == 0 ? 0.0 : value;
  if (normalized.isFinite && normalized == normalized.truncateToDouble()) {
    return normalized.toInt();
  }
  return normalized;
}

dynamic _canonicalStorageReal(dynamic value) {
  if (value == null || value is! num || !value.isFinite) return value;
  final values = Float32List(1)..[0] = value.toDouble();
  return _canonicalJsonNumber(values[0]);
}

dynamic _canonicalCurrency(dynamic value) {
  if (value == null || value is! num || !value.isFinite) return value;
  final candidate = value.toDouble();
  final rounded = (candidate * 100).round() / 100;
  if (rounded != candidate) return value;
  return _canonicalJsonNumber(rounded);
}

Map<String, dynamic> canonicalLwwMutablePayload(
  String collection,
  Map<String, dynamic> payload,
) {
  if (payload.isEmpty) return <String, dynamic>{};
  return switch (collection) {
    'clients' => {
        'address': payload['address'],
        'discounted_price': _canonicalCurrency(payload['discounted_price']),
        'email': payload['email'] == '' ? null : payload['email'],
        'latitude': _canonicalStorageReal(payload['latitude']),
        'longitude': _canonicalStorageReal(payload['longitude']),
        'name': payload['name'],
        'phone': payload['phone'],
        'site_address': payload['site_address'],
      },
    'items' => {
        'enabled': payload['enabled'],
        'name': payload['name'],
        'price': _canonicalCurrency(payload['price']),
      },
    'rectangles' => {
        'length': _canonicalStorageReal(payload['length']),
        'width': _canonicalStorageReal(payload['width']),
      },
    'default_prices' => {
        'enabled': payload['enabled'],
        'price': _canonicalCurrency(payload['price']),
      },
    _ => throw ArgumentError.value(
        collection,
        'collection',
        'Unsupported LWW collection',
      ),
  };
}

String canonicalLwwMutablePayloadHash(
  String collection,
  Map<String, dynamic> payload,
) =>
    canonicalLwwPayloadHash(
      canonicalLwwMutablePayload(collection, payload),
    );
