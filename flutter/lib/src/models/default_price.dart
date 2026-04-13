import 'package:uuid/uuid.dart';

class DefaultPrice {
  final int? localId;
  final String remoteId;
  final double price;
  final bool enabled;
  final DateTime updatedAt;

  DefaultPrice({
    this.localId,
    String? remoteId,
    required this.price,
    this.enabled = true,
    DateTime? updatedAt,
  })  : remoteId = remoteId ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  factory DefaultPrice.createNew({required double price}) {
    return DefaultPrice(
      price: price,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'local_id': localId,
      'remote_id': remoteId,
      'price': price,
      'enabled': enabled ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory DefaultPrice.fromMap(Map<String, dynamic> map) {
    return DefaultPrice(
      localId: map['local_id'] is int ? map['local_id'] : null,
      remoteId: map['remote_id'],
      price: double.tryParse(map['price']?.toString() ?? '') ?? 0.0,
      enabled: (map['enabled'] is int) ? (map['enabled'] == 1) : map['enabled'] == true,
      updatedAt: DateTime.parse(map['updated_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'remote_id': remoteId,
      'price': price,
      'enabled': enabled,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory DefaultPrice.fromJson(Map<String, dynamic> json) {
    return DefaultPrice(
      remoteId: json['remote_id'],
      price: double.tryParse(json['price']?.toString() ?? '') ?? 0.0,
      enabled: json['enabled'] ?? true,
      updatedAt: DateTime.parse(json['updated_at']),
    );
  }

  DefaultPrice copyWith({
    int? localId,
    String? remoteId,
    double? price,
    bool? enabled,
    DateTime? updatedAt,
  }) {
    return DefaultPrice(
      localId: localId ?? this.localId,
      remoteId: remoteId ?? this.remoteId,
      price: price ?? this.price,
      enabled: enabled ?? this.enabled,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
