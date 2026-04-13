import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'item.dart';

class Client {
  final int? localId;
  final String remoteId;
  final String? franchiseeId;
  final String name;
  final String? address;
  final String? siteAddress;
  final String? email;
  final String? phone;
  final double? latitude;
  final double? longitude;
  final List<String> photos;
  final bool isDirty;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final List<Item> items;
  final double? discountedPrice;

  Client({
    this.localId,
    String? remoteId,
    this.franchiseeId,
    required this.name,
    this.address,
    this.siteAddress,
    this.email,
    this.phone,
    this.latitude,
    this.longitude,
    this.photos = const [],
    this.isDirty = true,
    DateTime? updatedAt,
    this.deletedAt,
    this.items = const [],
    this.discountedPrice,
  })  : remoteId = remoteId ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  double get totalArea {
    return items
        .where((item) => item.enabled && item.deletedAt == null)
        .fold(0.0, (sum, item) => sum + item.area);
  }

  double get originalTotalPrice {
    return items
        .where((item) => item.enabled && item.deletedAt == null)
        .fold(0.0, (sum, item) => sum + item.totalPrice);
  }

  double get finalTotalPrice => discountedPrice ?? originalTotalPrice;
  double get discountAmount => originalTotalPrice - finalTotalPrice;
  double get discountPercentage =>
      originalTotalPrice > 0 ? (discountAmount / originalTotalPrice) * 100 : 0;

  Map<String, dynamic> toMap() {
    return {
      'local_id': localId,
      'remote_id': remoteId,
      'franchisee_id': franchiseeId,
      'name': name,
      'address': address,
      'site_address': siteAddress,
      'email': email,
      'phone': phone,
      'latitude': latitude,
      'longitude': longitude,
      'photos': jsonEncode(photos),
      'discounted_price': discountedPrice,
      'is_dirty': isDirty ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory Client.fromMap(Map<String, dynamic> map,
      {List<Item> items = const []}) {
    return Client(
      localId: map['local_id'] is int ? map['local_id'] : null,
      remoteId: map['remote_id'] ?? '',
      franchiseeId: map['franchisee_id']?.toString(),
      name: map['name'] ?? 'Unknown',
      address: map['address'],
      siteAddress: map['site_address'],
      email: map['email'],
      phone: map['phone'],
      latitude: map['latitude'] != null ? double.tryParse(map['latitude'].toString()) : null,
      longitude: map['longitude'] != null ? double.tryParse(map['longitude'].toString()) : null,
      photos: List<String>.from(jsonDecode(map['photos'] ?? '[]')),
      discountedPrice: map['discounted_price'] != null ? double.tryParse(map['discounted_price'].toString()) : null,
      isDirty: map['is_dirty'] == 1,
      updatedAt: DateTime.parse(map['updated_at']),
      deletedAt:
          map['deleted_at'] != null ? DateTime.parse(map['deleted_at']) : null,
      items: items,
    );
  }

  Client copyWith({
    int? localId,
    String? remoteId,
    String? franchiseeId,
    String? name,
    String? address,
    String? siteAddress,
    String? email,
    String? phone,
    double? latitude,
    double? longitude,
    List<String>? photos,
    bool? isDirty,
    DateTime? updatedAt,
    DateTime? deletedAt,
    List<Item>? items,
    double? discountedPrice,
    bool clearDiscount = false,
  }) {
    return Client(
      localId: localId ?? this.localId,
      remoteId: remoteId ?? this.remoteId,
      franchiseeId: franchiseeId ?? this.franchiseeId,
      name: name ?? this.name,
      address: address ?? this.address,
      siteAddress: siteAddress ?? this.siteAddress,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      photos: photos ?? this.photos,
      isDirty: isDirty ?? this.isDirty,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      items: items ?? this.items,
      discountedPrice:
          clearDiscount ? null : (discountedPrice ?? this.discountedPrice),
    );
  }
}