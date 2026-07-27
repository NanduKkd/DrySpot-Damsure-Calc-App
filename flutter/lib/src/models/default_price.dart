import 'package:uuid/uuid.dart';

class DefaultPrice {
  final int? localId;
  final String remoteId;
  final String franchiseeId;
  final double price;
  final bool enabled;
  final bool isDirty;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  DefaultPrice({
    this.localId,
    String? remoteId,
    this.franchiseeId = '',
    required this.price,
    this.enabled = true,
    this.isDirty = true,
    DateTime? updatedAt,
    this.deletedAt,
  })  : remoteId = remoteId ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  factory DefaultPrice.createNew({
    required String franchiseeId,
    required double price,
  }) {
    return DefaultPrice(
      franchiseeId: franchiseeId,
      price: price,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'local_id': localId,
      'remote_id': remoteId,
      'franchisee_id': franchiseeId,
      'price': price,
      'enabled': enabled ? 1 : 0,
      'is_dirty': isDirty ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory DefaultPrice.fromMap(Map<String, dynamic> map) {
    return DefaultPrice(
      localId: map['local_id'] is int ? map['local_id'] : null,
      remoteId: map['remote_id'],
      franchiseeId: map['franchisee_id']?.toString() ?? '',
      price: double.tryParse(map['price']?.toString() ?? '') ?? 0.0,
      enabled: (map['enabled'] is int)
          ? (map['enabled'] == 1)
          : map['enabled'] == true,
      isDirty: (map['is_dirty'] is int)
          ? map['is_dirty'] == 1
          : map['is_dirty'] == true,
      updatedAt: DateTime.parse(map['updated_at']),
      deletedAt:
          map['deleted_at'] == null ? null : DateTime.parse(map['deleted_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'remote_id': remoteId,
      'price': price,
      'enabled': enabled,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory DefaultPrice.fromJson(Map<String, dynamic> json) {
    return DefaultPrice(
      remoteId: json['remote_id'],
      franchiseeId: json['franchisee_id']?.toString() ?? '',
      price: double.tryParse(json['price']?.toString() ?? '') ?? 0.0,
      enabled: json['enabled'] ?? true,
      isDirty: json['is_dirty'] == null
          ? false
          : (json['is_dirty'] == 1 || json['is_dirty'] == true),
      updatedAt: DateTime.parse(json['updated_at']),
      deletedAt: json['deleted_at'] == null
          ? null
          : DateTime.parse(json['deleted_at']),
    );
  }

  DefaultPrice copyWith({
    int? localId,
    String? remoteId,
    String? franchiseeId,
    double? price,
    bool? enabled,
    bool? isDirty,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return DefaultPrice(
      localId: localId ?? this.localId,
      remoteId: remoteId ?? this.remoteId,
      franchiseeId: franchiseeId ?? this.franchiseeId,
      price: price ?? this.price,
      enabled: enabled ?? this.enabled,
      isDirty: isDirty ?? this.isDirty,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
