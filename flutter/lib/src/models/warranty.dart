class Warranty {
  final String id;
  final String clientId;
  final DateTime startDate;
  final int durationYears;
  final String pdfUrl;
  final DateTime createdAt;

  Warranty({
    required this.id,
    required this.clientId,
    required this.startDate,
    required this.durationYears,
    required this.pdfUrl,
    required this.createdAt,
  });

  factory Warranty.fromJson(Map<String, dynamic> json) {
    return Warranty(
      id: json['id'],
      clientId: json['clientId'],
      startDate: DateTime.parse(json['startDate']),
      durationYears: json['durationYears'],
      pdfUrl: json['pdfUrl'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'clientId': clientId,
      'startDate': startDate.toIso8601String(),
      'durationYears': durationYears,
      'pdfUrl': pdfUrl,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
