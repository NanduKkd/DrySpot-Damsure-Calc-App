import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
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

  test('PdfService content verification - Headers', () async {
    final file = File('lib/src/services/pdf_service.dart');
    final content = await file.readAsString();
    
    // Check for specific T&C headers from index.html
    expect(content, contains('I. Warranty:'), reason: 'Missing Section I');
    expect(content, contains('II. Applicability of Warranty:'), reason: 'Missing Section II');
    expect(content, contains('III. Commencement and Duration'), reason: 'Missing Section III');
    expect(content, contains('IV. Exclusions'), reason: 'Missing Section IV');
    expect(content, contains('Standard Product & Service Warranty Statement'), reason: 'Missing Warranty Statement header');
  });

  test('PdfService content verification - Products', () async {
    final file = File('lib/src/services/pdf_service.dart');
    final content = await file.readAsString();
    
    // Check for hardcoded products
    expect(content, contains('Polybound'));
    expect(content, contains('Magnofix'));
    expect(content, contains('Poliflex'));
    expect(content, contains('Mesh'));
    expect(content, contains('Cement'));
  });

  test('PdfService content verification - Assets', () async {
    final file = File('lib/src/services/pdf_service.dart');
    final content = await file.readAsString();
    
    // Check for background image loading
    expect(content, contains('assets/pdf-images/blueBuildingsBackground.png'));
    expect(content, contains('assets/pdf-images/damsureLogo.png'));
    expect(content, contains('assets/pdf-images/drySpotLogoWhite.png'));
    expect(content, contains('assets/pdf-images/drySpotLogoBlue.png'));
    expect(content, contains('assets/pdf-images/drySpotSeal.png'));
    expect(content, contains('assets/pdf-images/franchiseeManagerNameAndSign.jpg'));
  });
}
