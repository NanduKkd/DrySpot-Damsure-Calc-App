import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';

void main() {
  group('Client Discount Logic', () {
    test('calculate original total correctly', () {
      final client = Client(
        name: 'Test Client',
        items: [
          Item(
            name: 'Item 1',
            price: 10.0,
            rectangles: [
              Rectangle(length: 2.0, width: 5.0), // area 10
            ],
          ),
          Item(
            name: 'Item 2',
            price: 20.0,
            rectangles: [
              Rectangle(length: 5.0, width: 5.0), // area 25
            ],
          ),
        ],
      );

      // Item 1: 10 * 10 = 100
      // Item 2: 25 * 20 = 500
      // Total: 600
      expect(client.originalTotalPrice, 600.0);
    });

    test('calculate discount amount and percentage correctly', () {
      final client = Client(
        name: 'Test Client',
        items: [
          Item(
            name: 'Item 1',
            price: 10.0,
            rectangles: [
              Rectangle(length: 10.0, width: 10.0), // area 100, price 1000
            ],
          ),
        ],
        discountedPrice: 800.0,
      );

      expect(client.originalTotalPrice, 1000.0);
      expect(client.finalTotalPrice, 800.0);
      expect(client.discountAmount, 200.0);
      expect(client.discountPercentage, 20.0);
    });

    test('handle null discounted price (no discount)', () {
      final client = Client(
        name: 'Test Client',
        items: [
          Item(
            name: 'Item 1',
            price: 10.0,
            rectangles: [
              Rectangle(length: 10.0, width: 10.0), // area 100, price 1000
            ],
          ),
        ],
        discountedPrice: null,
      );

      expect(client.originalTotalPrice, 1000.0);
      expect(client.finalTotalPrice, 1000.0);
      expect(client.discountAmount, 0.0);
      expect(client.discountPercentage, 0.0);
    });

    test('handle zero original price', () {
      final client = Client(
        name: 'Test Client',
        items: [],
        discountedPrice: 100.0,
      );

      expect(client.originalTotalPrice, 0.0);
      expect(client.finalTotalPrice, 100.0);
      expect(client.discountAmount, -100.0);
      expect(client.discountPercentage, 0.0);
    });
  });
}
