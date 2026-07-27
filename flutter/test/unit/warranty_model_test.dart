import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/warranty.dart';

void main() {
  group('Warranty Model warrantyCardNumber Field', () {
    test('toMap should include warrantyCardNumber', () {
      final warranty = Warranty(
        localId: 1,
        remoteId: 'w1',
        clientId: 2,
        startDate: DateTime(2026, 4, 6),
        durationYears: 5,
        pdfUrl: 'url',
        updatedAt: DateTime(2026, 4, 6),
        warrantyCardNumber: 'WARR-12345',
      );
      final map = warranty.toMap();
      expect(map['warranty_card_number'], 'WARR-12345');
    });

    test('fromMap should parse warrantyCardNumber', () {
      final map = {
        'local_id': 1,
        'remote_id': 'w1',
        'client_id': 2,
        'start_date': DateTime(2026, 4, 6).toIso8601String(),
        'duration_years': 5,
        'pdf_url': 'url',
        'updated_at': DateTime(2026, 4, 6).toIso8601String(),
        'warranty_card_number': 'WARR-0001',
        'is_dirty': 1,
      };
      final warranty = Warranty.fromMap(map);
      expect(warranty.warrantyCardNumber, 'WARR-0001');
    });
  });
}
