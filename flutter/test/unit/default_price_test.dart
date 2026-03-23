import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/default_price.dart';

void main() {
  group('DefaultPrice Model', () {
    test('fromJson and toJson', () {
      final json = {
        'remote_id': 'uuid-123',
        'price': 10.5,
        'enabled': true,
        'updated_at': '2026-03-23T10:00:00.000Z',
      };

      final defaultPrice = DefaultPrice.fromJson(json);

      expect(defaultPrice.remoteId, 'uuid-123');
      expect(defaultPrice.price, 10.5);
      expect(defaultPrice.enabled, true);

      final outJson = defaultPrice.toJson();
      expect(outJson['remote_id'], 'uuid-123');
      expect(outJson['price'], 10.5);
      expect(outJson['enabled'], true);
    });

    test('Default values', () {
      final defaultPrice = DefaultPrice(
        price: 15.0,
      );
      expect(defaultPrice.enabled, true);
      expect(defaultPrice.remoteId, isNotEmpty);
    });
  });
}
