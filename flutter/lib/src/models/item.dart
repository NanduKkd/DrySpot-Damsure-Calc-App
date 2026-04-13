import 'package:uuid/uuid.dart';
import 'rectangle.dart';

class Item {
  final int? localId;
  final String remoteId;
  final int? clientId;
  final String name;
  final double price;
  final bool enabled;
  final bool isDirty;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final List<Rectangle> rectangles;

  Item({
    this.localId,
    String? remoteId,
    this.clientId,
    required this.name,
    required this.price,
    this.enabled = true,
    this.isDirty = true,
    DateTime? updatedAt,
    this.deletedAt,
    this.rectangles = const [],
  })  : remoteId = remoteId ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  double get area {
    return rectangles
        .where((r) => r.deletedAt == null)
        .fold(0.0, (sum, rectangle) => sum + rectangle.area);
  }

  double get totalPrice {
    return area * price;
  }

  Map<String, dynamic> toMap() {
    return {
      'local_id': localId,
      'remote_id': remoteId,
      'client_id': clientId,
      'name': name,
      'price': price,
      'enabled': enabled ? 1 : 0,
      'is_dirty': isDirty ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory Item.fromMap(Map<String, dynamic> map, {List<Rectangle> rectangles = const []}) {
    return Item(
      localId: map['local_id'] is int ? map['local_id'] : null,
      remoteId: map['remote_id'] ?? '',
      clientId: map['client_id'] is int ? map['client_id'] : null,
      name: map['name'],
      price: double.tryParse(map['price']?.toString() ?? '') ?? 0.0,
      enabled: map['enabled'] == 1 || map['enabled'] == true,
      isDirty: map['is_dirty'] == 1,
      updatedAt: DateTime.parse(map['updated_at']),
      deletedAt: map['deleted_at'] != null ? DateTime.parse(map['deleted_at']) : null,
      rectangles: rectangles,
    );
  }

  Item copyWith({
    int? localId,
    String? remoteId,
    int? clientId,
    String? name,
    double? price,
    bool? enabled,
    bool? isDirty,
    DateTime? updatedAt,
    DateTime? deletedAt,
    List<Rectangle>? rectangles,
  }) {
    return Item(
      localId: localId ?? this.localId,
      remoteId: remoteId ?? this.remoteId,
      clientId: clientId ?? this.clientId,
      name: name ?? this.name,
      price: price ?? this.price,
      enabled: enabled ?? this.enabled,
      isDirty: isDirty ?? this.isDirty,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rectangles: rectangles ?? this.rectangles,
    );
  }
}
