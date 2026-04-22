import 'package:uuid/uuid.dart';

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _parseBool(dynamic value) {
  return value == true || value == 1 || value == '1';
}

class Warranty {
  final int? localId;
  final String remoteId;
  final int clientId; // local client id
  final String? remoteClientId; // remote client id for sync
  final String warrantyCardNumber;
  final DateTime startDate;
  final int durationYears;
  final String pdfUrl;
  final bool isDirty;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Warranty({
    this.localId,
    String? remoteId,
    required this.clientId,
    this.remoteClientId,
    required this.warrantyCardNumber,
    required this.startDate,
    required this.durationYears,
    required this.pdfUrl,
    this.isDirty = true,
    DateTime? updatedAt,
    this.deletedAt,
  })  : remoteId = remoteId ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'local_id': localId,
      'remote_id': remoteId,
      'client_id': clientId,
      'warranty_card_number': warrantyCardNumber,
      'start_date': startDate.toIso8601String(),
      'duration_years': durationYears,
      'pdf_url': pdfUrl,
      'is_dirty': isDirty ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory Warranty.fromMap(Map<String, dynamic> map) {
    final localClientId = _parseInt(map['client_id']);

    return Warranty(
      localId: _parseInt(map['local_id']),
      remoteId: map['remote_id']?.toString() ?? '',
      clientId: localClientId ?? 0,
      remoteClientId:
          localClientId == null ? map['client_id']?.toString() : null,
      warrantyCardNumber: map['warranty_card_number']?.toString() ?? '',
      startDate: DateTime.parse(map['start_date']),
      durationYears: _parseInt(map['duration_years']) ?? 0,
      pdfUrl: map['pdf_url']?.toString() ?? '',
      isDirty: _parseBool(map['is_dirty']),
      updatedAt: DateTime.parse(map['updated_at']),
      deletedAt:
          map['deleted_at'] != null ? DateTime.parse(map['deleted_at']) : null,
    );
  }

  Warranty copyWith({
    int? localId,
    String? remoteId,
    int? clientId,
    String? remoteClientId,
    String? warrantyCardNumber,
    DateTime? startDate,
    int? durationYears,
    String? pdfUrl,
    bool? isDirty,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return Warranty(
      localId: localId ?? this.localId,
      remoteId: remoteId ?? this.remoteId,
      clientId: clientId ?? this.clientId,
      remoteClientId: remoteClientId ?? this.remoteClientId,
      warrantyCardNumber: warrantyCardNumber ?? this.warrantyCardNumber,
      startDate: startDate ?? this.startDate,
      durationYears: durationYears ?? this.durationYears,
      pdfUrl: pdfUrl ?? this.pdfUrl,
      isDirty: isDirty ?? this.isDirty,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
