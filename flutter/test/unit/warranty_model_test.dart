import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/warranty.dart';

void main() {
  group('Warranty Model warrantyCardNumber Field', () {
    test('toJson should include warrantyCardNumber', () {
      final warranty = Warranty(
        id: 'w1',
        clientId: 'c1',
        startDate: DateTime(2026, 4, 6),
        durationYears: 5,
        pdfUrl: 'url',
        createdAt: DateTime(2026, 4, 6),
        warrantyCardNumber: 'WARR-12345',
      );
      final json = warranty.toJson();
      expect(json['warrantyCardNumber'], 'WARR-12345');
    });

    test('fromJson should parse warrantyCardNumber', () {
      final json = {
        'id': 'w1',
        'clientId': 'c1',
        'startDate': DateTime(2026, 4, 6).toIso8601String(),
        'durationYears': 5,
        'pdfUrl': 'url',
        'createdAt': DateTime(2026, 4, 6).toIso8601String(),
        'warrantyCardNumber': 'WARR-0001',
      };
      final warranty = Warranty.fromJson(json);
      expect(warranty.warrantyCardNumber, 'WARR-0001');
    });
  });
}
