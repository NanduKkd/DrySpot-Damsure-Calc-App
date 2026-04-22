import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/proposal.dart';
import 'package:app_client/src/models/warranty.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/screens/clients/pdf_management_screen.dart';
import 'package:app_client/src/screens/clients/warranty_form_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class MockClientProvider extends ClientProvider {
  MockClientProvider({
    List<Warranty> warranties = const [],
    List<Proposal> proposals = const [],
  })  : _warranties = warranties,
        _proposals = proposals;

  final List<Warranty> _warranties;
  final List<Proposal> _proposals;

  @override
  List<Warranty> get currentClientWarranties => _warranties;

  @override
  List<Proposal> get currentClientProposals => _proposals;

  @override
  Future<void> loadWarranties(int clientLocalId) async {}

  @override
  Future<void> loadProposals(int clientLocalId) async {}
}

void main() {
  testWidgets(
      'PdfManagementScreen allows creating another warranty when one already exists',
      (tester) async {
    final client = Client(name: 'Acme', localId: 1);
    final provider = MockClientProvider(
      warranties: [
        Warranty(
          clientId: 1,
          warrantyCardNumber: 'W-1',
          startDate: DateTime(2026, 1, 1),
          durationYears: 5,
          pdfUrl: 'https://example.com/w1.pdf',
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ClientProvider>.value(
        value: provider,
        child: MaterialApp(
          home: PdfManagementScreen(client: client),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
        find.widgetWithText(ElevatedButton, 'Create Warranty'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Create Warranty'));
    await tester.pumpAndSettle();

    expect(find.text('Warranty Exists'), findsNothing);
    expect(find.byType(WarrantyFormScreen), findsOneWidget);
  });
}
