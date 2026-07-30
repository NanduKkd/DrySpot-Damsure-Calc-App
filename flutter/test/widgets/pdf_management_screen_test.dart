import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/proposal.dart';
import 'package:app_client/src/models/warranty.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/services/api_service.dart';
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
    final client =
        Client(name: 'Acme', localId: 1, remoteId: 'client-remote-id');
    final provider = MockClientProvider(
      warranties: [
        Warranty(
          clientId: 1,
          warrantyCardNumber: 'W-1',
          startDate: DateTime(2026, 1, 1),
          durationYears: 5,
          pdfUrl: 'https://example.com/w1.pdf',
          version: 4,
        ),
      ],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: provider),
          Provider<ApiService>.value(
            value: ApiService(serverUrl: 'http://localhost'),
          ),
        ],
        child: MaterialApp(
          home: PdfManagementScreen(client: client),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
        find.widgetWithText(ElevatedButton, 'Create Warranty'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Create Warranty'));
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Create Warranty'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('Permanently replace warranty?'), findsOneWidget);
    expect(
      find.text(
        'Warranty "W-1" (server version 4) will be permanently deleted. Its record and stored PDF cannot be recovered. Continue only if you intend to replace this exact warranty.',
      ),
      findsOneWidget,
    );

    await tester
        .tap(find.widgetWithText(ElevatedButton, 'Permanently replace'));
    await tester.pumpAndSettle();

    expect(find.byType(WarrantyFormScreen), findsOneWidget);
    final form = tester.widget<WarrantyFormScreen>(
      find.byType(WarrantyFormScreen),
    );
    expect(form.warrantyToReplace?.warrantyCardNumber, 'W-1');
    expect(form.warrantyToReplace?.version, 4);
    expect(form.replacementIdempotencyKey, isNotEmpty);
  });

  testWidgets('warranty deletion confirmation names the exact server version',
      (tester) async {
    final client =
        Client(name: 'Acme', localId: 1, remoteId: 'client-remote-id');
    final provider = MockClientProvider(
      warranties: [
        Warranty(
          localId: 2,
          remoteId: 'warranty-remote-id',
          clientId: 1,
          warrantyCardNumber: 'W-DELETE',
          startDate: DateTime(2026, 1, 1),
          durationYears: 5,
          pdfUrl: '/api/warranty/warranty-remote-id/download',
          version: 7,
        ),
      ],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: provider),
          Provider<ApiService>.value(
            value: ApiService(serverUrl: 'http://localhost'),
          ),
        ],
        child: MaterialApp(home: PdfManagementScreen(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete).first);
    await tester.tap(find.byIcon(Icons.delete).first, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Permanently delete warranty?'), findsOneWidget);
    expect(
      find.text(
        'Warranty "W-DELETE" (server version 7) and its stored PDF will be permanently deleted and cannot be recovered.',
      ),
      findsOneWidget,
    );
    expect(find.text('Permanently delete'), findsOneWidget);
  });
}
