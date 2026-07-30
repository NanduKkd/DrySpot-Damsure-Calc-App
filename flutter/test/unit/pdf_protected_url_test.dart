import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/pdf_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('protected relative PDFs resolve only against the configured server',
      () {
    final service = PdfService(
      apiService: ApiService(serverUrl: 'https://damsure.example.test'),
    );

    expect(
      service.resolveProtectedPdfUrl('/api/warranty/w1/download').toString(),
      'https://damsure.example.test/api/warranty/w1/download',
    );
    expect(
      service.resolveProtectedPdfUrl(
          'https://attacker.example/api/warranty/w1/download'),
      isNull,
    );
  });
}
