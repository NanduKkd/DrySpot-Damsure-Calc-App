import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/client.dart';

void main() {
  group('Rectangle', () {
    test('Area calculation', () {
      final rect = Rectangle(length: 10, width: 20);
      expect(rect.area, 200.0);
    });

    test('Negative dimensions should throw an error', () {
      expect(() => Rectangle(length: -10, width: 20), throwsArgumentError);
      expect(() => Rectangle(length: 10, width: -20), throwsArgumentError);
      expect(() => Rectangle(length: 0, width: 20), throwsArgumentError);
    });
  });

  group('Item', () {
    test('Area calculation from multiple rectangles', () {
      final item = Item(
        name: 'Main Roof',
        rectangles: [
          Rectangle(length: 10, width: 20),
          Rectangle(length: 5, width: 10),
        ],
        price: 10.0,
      );
      expect(item.area, 250.0);
      expect(item.totalPrice, 2500.0);
    });

    test('Area ignores deleted rectangles', () {
      final item = Item(
        name: 'Main Roof',
        rectangles: [
          Rectangle(length: 10, width: 20),
          Rectangle(length: 5, width: 10, deletedAt: DateTime.now()),
        ],
        price: 10.0,
      );
      expect(item.area, 200.0);
    });
  });

  group('Client', () {
    test('Total area and price from enabled items only', () {
      final client = Client(
        name: 'John Doe',
        items: [
          Item(
            name: 'Main Roof',
            rectangles: [Rectangle(length: 10, width: 20)],
            price: 10.0,
            enabled: true,
          ),
          Item(
            name: 'Sunshade',
            rectangles: [Rectangle(length: 5, width: 10)],
            price: 5.0,
            enabled: false,
          ),
        ],
      );
      expect(client.totalArea, 200.0);
      expect(client.originalTotalPrice, 2000.0);
    });

    test('Total area and price ignore deleted items', () {
       final client = Client(
        name: 'John Doe',
        items: [
          Item(
            name: 'Main Roof',
            rectangles: [Rectangle(length: 10, width: 20)],
            price: 10.0,
            enabled: true,
          ),
          Item(
            name: 'Deleted Item',
            rectangles: [Rectangle(length: 10, width: 20)],
            price: 10.0,
            enabled: true,
            deletedAt: DateTime.now(),
          ),
        ],
      );
      expect(client.totalArea, 200.0);
      expect(client.originalTotalPrice, 2000.0);
    });

    test('Bulk overwrite pricing (Apply to All)', () {
      final client = Client(
        name: 'John Doe',
        items: [
          Item(name: 'Item 1', price: 10.0),
          Item(name: 'Item 2', price: 20.0),
        ],
      );

      final updatedItems = client.items.map((item) => item.copyWith(price: 15.0)).toList();
      final updatedClient = client.copyWith(items: updatedItems);

      for (var item in updatedClient.items) {
        expect(item.price, 15.0);
      }
    });
  });
}
