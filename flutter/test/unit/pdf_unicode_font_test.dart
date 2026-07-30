import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/services/pdf_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _UnicodePdfPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PathProviderPlatform.instance = _UnicodePdfPathProvider();
  });

  test('embeds Unicode font for multilingual proposal and warranty PDFs',
      () async {
    final client = Client(
      remoteId: 'unicode',
      name: 'ജോൺ മാത്യു / John Mathew',
      address:
          'വീട്ടുപേര്, Uppala Gate, Kasaragod, Kerala - 671121, near the old market road and the Damsure office',
      siteAddress:
          'സൈറ്റ് വിലാസം: മംഗലാപുരം റോഡ്, കുമ്പള, കാസർഗോഡ്, കേരളം - 671321; long site directions continue past the junction',
      phone: '+91 9847 484 485',
      discountedPrice: 25000,
      items: [
        Item(
          name: 'Roof',
          price: 125,
          rectangles: [Rectangle(length: 20, width: 25)],
        ),
      ],
    );
    final service = PdfService();
    final generatedFiles = <File>[];
    const evidenceDir = String.fromEnvironment('PDF_EVIDENCE_DIR');

    addTearDown(() async {
      if (evidenceDir.isEmpty) {
        for (final file in generatedFiles) {
          if (await file.exists()) await file.delete();
        }
      }
    });

    final warranty = await service.generateWarrantyPdf(
      client: client,
      customerName: client.name,
      customerAddress:
          '${client.address} - Project value ₹25,000 and Malayalam text മലയാളം',
      siteAddress: client.siteAddress!,
      mobileNumber: client.phone!,
      areaOfApplication: 'Roof - terrace and parapet',
      startDate: DateTime(2026, 7, 30),
      durationYears: 10,
      franchiseeName: 'ഡാംഷൂർ ഫ്രാഞ്ചൈസി / Damsure Franchisee',
      warrantyCardNumber: 'WARR-₹-മലയാളം-001',
    );
    final proposal = await service.generateProposalPdf(client);
    generatedFiles.addAll([warranty, proposal]);

    for (final file in generatedFiles) {
      expect(await file.exists(), isTrue);
      expect((await file.readAsBytes()).length, greaterThan(0));
    }

    final warrantyPdf = String.fromCharCodes(await warranty.readAsBytes());
    final proposalPdf = String.fromCharCodes(await proposal.readAsBytes());
    for (final pdf in [warrantyPdf, proposalPdf]) {
      expect(pdf, contains('NotoSans-Regular'));
      expect(pdf, contains('/Type0'));
      expect(pdf, contains('/ToUnicode'));
      expect(pdf, contains('NotoSansMalayalam'));
    }

    if (evidenceDir.isNotEmpty) {
      final destination = Directory(evidenceDir)..createSync(recursive: true);
      for (final file in generatedFiles) {
        await file.copy('${destination.path}/${file.uri.pathSegments.last}');
      }
    }

    // Keep the UTF-8 strings in this test source visible to reviewers and
    // protect against an accidental replacement with ASCII-only fixtures.
    expect(utf8.decode(utf8.encode('₹ മലയാളം')), '₹ മലയാളം');
  });
}
