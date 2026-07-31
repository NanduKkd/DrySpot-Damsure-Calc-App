import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/services/pdf_service.dart';
import 'package:app_client/src/services/session_manager.dart';
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

  test('stale proposal and warranty generation remove their new files',
      () async {
    final service = PdfService();
    const session = SessionSnapshot(
      token: 'a',
      userName: 'A',
      franchiseeId: 'tenant-a',
      franchiseeName: 'A',
      generation: 1,
    );
    final client = Client(
      remoteId: 'app106-stale-pdf',
      name: 'Retained tenant client',
      updatedAt: DateTime.now(),
    );
    final temp = Directory.systemTemp;
    final proposalFile = File('${temp.path}/proposal_${client.remoteId}.pdf');
    final warrantyFile = File('${temp.path}/warranty_${client.remoteId}.pdf');
    if (await proposalFile.exists()) await proposalFile.delete();
    if (await warrantyFile.exists()) await warrantyFile.delete();

    var proposalChecks = 0;
    await expectLater(
      service.generateProposalPdf(
        client,
        session: session,
        // The fourth check is immediately after writeAsBytes: model logout
        // racing the generation's final physical file mutation.
        isSessionCurrent: () => ++proposalChecks < 4,
      ),
      throwsA(isA<StaleSessionException>()),
    );
    expect(await proposalFile.exists(), isFalse);

    var warrantyChecks = 0;
    await expectLater(
      service.generateWarrantyPdf(
        client: client,
        customerName: client.name,
        customerAddress: '',
        siteAddress: '',
        mobileNumber: '',
        areaOfApplication: 'Roof',
        startDate: DateTime.utc(2026, 7, 31),
        durationYears: 1,
        franchiseeName: 'Tenant A',
        warrantyCardNumber: 'A-106',
        session: session,
        isSessionCurrent: () => ++warrantyChecks < 4,
      ),
      throwsA(isA<StaleSessionException>()),
    );
    expect(await warrantyFile.exists(), isFalse);
  });
}
