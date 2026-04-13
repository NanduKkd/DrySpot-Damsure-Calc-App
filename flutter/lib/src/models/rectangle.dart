import 'package:uuid/uuid.dart';

class Rectangle {
  final int? localId;
  final String remoteId;
  final int? itemId;
  final double length;
  final double width;
  final bool isDirty;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Rectangle({
    this.localId,
    String? remoteId,
    this.itemId,
    required this.length,
    required this.width,
    this.isDirty = true,
    DateTime? updatedAt,
    this.deletedAt,
  })  : remoteId = remoteId ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now() {
    if (length <= 0) throw ArgumentError('Length must be positive');
    if (width <= 0) throw ArgumentError('Width must be positive');
  }

  double get area => length * width;

  Map<String, dynamic> toMap() {
    return {
      'local_id': localId,
      'remote_id': remoteId,
      'item_id': itemId,
      'length': length,
      'width': width,
      'is_dirty': isDirty ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory Rectangle.fromMap(Map<String, dynamic> map) {
    return Rectangle(
      localId: map['local_id'] is int ? map['local_id'] : null,
      remoteId: map['remote_id'] ?? '',
      itemId: map['item_id'] is int ? map['item_id'] : null,
      length: double.tryParse(map['length']?.toString() ?? '') ?? 0.0,
      width: double.tryParse(map['width']?.toString() ?? '') ?? 0.0,
      isDirty: map['is_dirty'] == 1,
      updatedAt: DateTime.parse(map['updated_at']),
      deletedAt: map['deleted_at'] != null ? DateTime.parse(map['deleted_at']) : null,
    );
  }

  Rectangle copyWith({
    int? localId,
    String? remoteId,
    int? itemId,
    double? length,
    double? width,
    bool? isDirty,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return Rectangle(
      localId: localId ?? this.localId,
      remoteId: remoteId ?? this.remoteId,
      itemId: itemId ?? this.itemId,
      length: length ?? this.length,
      width: width ?? this.width,
      isDirty: isDirty ?? this.isDirty,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
