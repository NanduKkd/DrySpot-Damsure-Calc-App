class WarrantyDeletionTombstone {
  final String warrantyId;
  final String franchiseeId;
  final String deletionSequence;
  final DateTime deletedAt;

  const WarrantyDeletionTombstone({
    required this.warrantyId,
    required this.franchiseeId,
    required this.deletionSequence,
    required this.deletedAt,
  });

  Map<String, dynamic> toMap() => {
        'warranty_id': warrantyId,
        'franchisee_id': franchiseeId,
        'deletion_sequence': deletionSequence,
        'deleted_at': deletedAt.toIso8601String(),
      };

  factory WarrantyDeletionTombstone.fromServer(
    Map<String, dynamic> map, {
    required String franchiseeId,
  }) =>
      WarrantyDeletionTombstone(
        warrantyId: map['warranty_id'].toString(),
        franchiseeId: franchiseeId,
        deletionSequence: map['deletion_sequence'].toString(),
        deletedAt: DateTime.parse(map['deleted_at'].toString()),
      );
}
