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

class Proposal {
  final int? localId;
  final String remoteId;
  final int clientId; // local client id
  final String? remoteClientId; // remote client id for sync
  final String pdfUrl;
  final bool isDirty;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Proposal({
    this.localId,
    String? remoteId,
    required this.clientId,
    this.remoteClientId,
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
      'pdf_url': pdfUrl,
      'is_dirty': isDirty ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory Proposal.fromMap(Map<String, dynamic> map) {
    final localClientId = _parseInt(map['client_id']);

    return Proposal(
      localId: _parseInt(map['local_id']),
      remoteId: map['remote_id']?.toString() ?? '',
      clientId: localClientId ?? 0,
      remoteClientId:
          localClientId == null ? map['client_id']?.toString() : null,
      pdfUrl: map['pdf_url']?.toString() ?? '',
      isDirty: _parseBool(map['is_dirty']),
      updatedAt: DateTime.parse(map['updated_at']),
      deletedAt:
          map['deleted_at'] != null ? DateTime.parse(map['deleted_at']) : null,
    );
  }

  Proposal copyWith({
    int? localId,
    String? remoteId,
    int? clientId,
    String? remoteClientId,
    String? pdfUrl,
    bool? isDirty,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return Proposal(
      localId: localId ?? this.localId,
      remoteId: remoteId ?? this.remoteId,
      clientId: clientId ?? this.clientId,
      remoteClientId: remoteClientId ?? this.remoteClientId,
      pdfUrl: pdfUrl ?? this.pdfUrl,
      isDirty: isDirty ?? this.isDirty,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
