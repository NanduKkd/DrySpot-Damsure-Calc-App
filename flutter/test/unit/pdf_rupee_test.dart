import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/services/pdf_service.dart';
import 'dart:io';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async {
    return Directory.systemTemp.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    PathProviderPlatform.instance = MockPathProviderPlatform();
  });

  group('PDF Generation and Rupee Symbol', () {
    test('generateProposalPdf should not crash with Rupee symbol', () async {
      final pdfService = PdfService();
      final client = Client(
        name: 'Test Client',
        phone: '1234567890',
        items: [
          Item(
            name: 'Roof',
            price: 150.0,
            rectangles: [
              Rectangle(length: 10, width: 20),
            ],
          ),
        ],
        discountedPrice: 25000.0,
      );

      final file = await pdfService.generateProposalPdf(client);
      expect(file, isNotNull);
      expect(await file.exists(), isTrue);

      // Note: We cannot easily verify if the Rupee symbol rendered correctly
      // without visual inspection or complex PDF parsing, but we verify no crash.
      // print('PDF generated at: ${file.path}');
    });

    test('generateWarrantyPdf should not crash with Rupee symbol', () async {
      final pdfService = PdfService();
      final client = Client(
        name: 'Test Client',
        items: [
          Item(
            name: 'Roof',
            price: 150.0,
            rectangles: [
              Rectangle(length: 10, width: 20),
            ],
          ),
        ],
      );

      final file = await pdfService.generateWarrantyPdf(
        client: client,
        customerName: client.name,
        customerAddress: client.address ?? '',
        siteAddress: client.siteAddress ?? '',
        mobileNumber: client.phone ?? '',
        areaOfApplication: 'Roof',
        startDate: DateTime.now(),
        durationYears: 5,
        franchiseeName: 'Test Franchisee',
        warrantyCardNumber: 'WARR-001',
      );
      expect(file, isNotNull);
      expect(await file.exists(), isTrue);
    });
  });
}
