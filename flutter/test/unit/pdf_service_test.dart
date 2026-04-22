import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/services/pdf_service.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async {
    return Directory.systemTemp.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PathProviderPlatform.instance = MockPathProvider();
  });

  test('PdfService generates a file', () async {
    final pdfService = PdfService();
    final client = Client(
      remoteId: 'c1',
      name: 'John Doe',
      address: '123 Main St',
      siteAddress: '456 Site Rd',
      email: 'john@example.com',
      updatedAt: DateTime.now(),
      items: [
        Item(
          name: 'Roof',
          rectangles: [Rectangle(length: 10, width: 20)],
          price: 10.0,
          enabled: true,
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

    expect(await file.exists(), isTrue);
    expect(file.path, contains('warranty_c1.pdf'));
    expect(await file.length(), lessThan(1024 * 1024));

    // Clean up
    await file.delete();
  });

  test('PdfService generates a proposal file', () async {
    final pdfService = PdfService();
    final client = Client(
      remoteId: 'c2',
      name: 'Jane Doe',
      address: '456 Elm St',
      email: 'jane@example.com',
      updatedAt: DateTime.now(),
      items: [
        Item(
          name: 'Kitchen',
          rectangles: [Rectangle(length: 10, width: 10)],
          price: 15.0,
          enabled: true,
        ),
      ],
      discountedPrice: 1200.0,
    );

    final file = await pdfService.generateProposalPdf(client);

    expect(await file.exists(), isTrue);
    expect(file.path, contains('proposal_c2.pdf'));

    // Clean up
    await file.delete();
  });
}
