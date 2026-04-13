import 'package:uuid/uuid.dart';

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
    return Warranty(
      localId: map['local_id'],
      remoteId: map['remote_id'],
      clientId: map['client_id'],
      warrantyCardNumber: map['warranty_card_number'],
      startDate: DateTime.parse(map['start_date']),
      durationYears: map['duration_years'],
      pdfUrl: map['pdf_url'],
      isDirty: map['is_dirty'] == 1,
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
