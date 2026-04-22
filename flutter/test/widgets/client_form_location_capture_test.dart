import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/proposal.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/warranty.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/screens/clients/client_form_screen.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/geo_service.dart';
import 'package:app_client/src/services/map_launcher_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

class MockClientProvider extends ChangeNotifier implements ClientProvider {
  Client? addedClient;

  @override
  Future<void> addClient(Client client) async {
    addedClient = client;
    notifyListeners();
  }

  @override
  Future<void> updateClient(Client client) async {
    addedClient = client;
    notifyListeners();
  }

  @override
  List<Client> get clients => [];
  @override
  bool get isLoading => false;
  @override
  Future<void> loadClients() async {}
  @override
  Future<void> deleteClient(int localId) async {}
  @override
  Future<Item?> getItemByLocalId(int localId) async => null;
  @override
  Future<void> addRectangle(Rectangle rectangle) async {}
  @override
  Future<void> updateRectangle(Rectangle rectangle) async {}
  @override
  Future<void> deleteRectangle(int localId) async {}
  @override
  Future<void> updateItem(Item item) async {}
  @override
  Future<int> addItem(Item item) async => 0;
  @override
  Future<void> deleteItem(int localId) async {}
  @override
  Future<void> applyBulkPrice(int clientLocalId, double price) async {}
  @override
  List<Warranty> get currentClientWarranties => [];
  @override
  List<Proposal> get currentClientProposals => [];
  @override
  Future<void> loadWarranties(int clientLocalId) async {}
  @override
  Future<void> loadProposals(int clientLocalId) async {}
  @override
  Future<void> addWarranty(Warranty warranty) async {}
  @override
  Future<void> addProposal(Proposal proposal) async {}
  @override
  Future<void> deleteWarranty(int localId, int clientLocalId) async {}
  @override
  Future<void> deleteProposal(int localId, int clientLocalId) async {}
}

class MockAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  ApiService get apiService => throw UnimplementedError();
  @override
  String? get franchiseeId => 'f1-id';
  @override
  String? get userName => 'User';
  @override
  String? get franchiseeName => null;

  @override
  bool get isAuthenticated => true;
  @override
  Future<void> login(String email, String password) async {}
  @override
  Future<void> logout() async {}
  @override
  Future<void> tryAutoLogin() async {}
}

class FakeGeoService extends GeoService {
  FakeGeoService({required this.result, this.throwError = false});

  final Position? result;
  final bool throwError;
  int callCount = 0;

  @override
  Future<Position?> getCurrentLocation() async {
    callCount++;
    if (throwError) throw Exception('Geo failure');
    return result;
  }
}

class FakeMapLauncherService extends MapLauncherService {
  int callCount = 0;
  double? lastLatitude;
  double? lastLongitude;

  @override
  Future<bool> openCoordinates({
    required double latitude,
    required double longitude,
  }) async {
    callCount++;
    lastLatitude = latitude;
    lastLongitude = longitude;
    return true;
  }
}

Position _testPosition({double lat = 12.34, double lng = 56.78}) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.now(),
    accuracy: 1,
    altitude: 0,
    altitudeAccuracy: 1,
    heading: 0,
    headingAccuracy: 1,
    speed: 0,
    speedAccuracy: 0,
  );
}

void main() {
  testWidgets('captures and saves location when available',
      (WidgetTester tester) async {
    final mockClientProvider = MockClientProvider();
    final mockAuthProvider = MockAuthProvider();
    final fakeGeoService = FakeGeoService(result: _testPosition());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<AuthProvider>.value(value: mockAuthProvider),
        ],
        child: MaterialApp(
          home: ClientFormScreen(geoService: fakeGeoService),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('12.340000, 56.780000'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Client Name *'),
      'Location Client',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(mockClientProvider.addedClient, isNotNull);
    expect(mockClientProvider.addedClient!.latitude, 12.34);
    expect(mockClientProvider.addedClient!.longitude, 56.78);
  });

  testWidgets('tapping the coordinate link opens the map app',
      (WidgetTester tester) async {
    final mockClientProvider = MockClientProvider();
    final mockAuthProvider = MockAuthProvider();
    final fakeGeoService = FakeGeoService(result: _testPosition());
    final fakeMapLauncher = FakeMapLauncherService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<AuthProvider>.value(value: mockAuthProvider),
        ],
        child: MaterialApp(
          home: ClientFormScreen(
            geoService: fakeGeoService,
            mapLauncherService: fakeMapLauncher,
          ),
        ),
      ),
    );

    await tester.pump();

    await tester.tap(find.text('12.340000, 56.780000'));
    await tester.pumpAndSettle();

    expect(fakeMapLauncher.callCount, 1);
    expect(fakeMapLauncher.lastLatitude, 12.34);
    expect(fakeMapLauncher.lastLongitude, 56.78);
  });

  testWidgets('shows retry state when location cannot be captured',
      (WidgetTester tester) async {
    final mockClientProvider = MockClientProvider();
    final mockAuthProvider = MockAuthProvider();
    final fakeGeoService = FakeGeoService(result: null);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<AuthProvider>.value(value: mockAuthProvider),
        ],
        child: MaterialApp(
          home: ClientFormScreen(geoService: fakeGeoService),
        ),
      ),
    );

    await tester.pump();

    expect(
      find.text('Location unavailable. Enable GPS/permission and retry.'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextButton, 'Change to Current Location'),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(TextButton, 'Change to Current Location'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Change'));
    await tester.pumpAndSettle();

    expect(fakeGeoService.callCount, 2);
  });

  testWidgets('changing to current location asks for confirmation',
      (WidgetTester tester) async {
    final mockClientProvider = MockClientProvider();
    final mockAuthProvider = MockAuthProvider();
    final fakeGeoService = FakeGeoService(result: _testPosition());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<AuthProvider>.value(value: mockAuthProvider),
        ],
        child: MaterialApp(
          home: ClientFormScreen(geoService: fakeGeoService),
        ),
      ),
    );

    await tester.pump();

    expect(fakeGeoService.callCount, 1);

    await tester.tap(
      find.widgetWithText(TextButton, 'Change to Current Location'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Change Location'), findsOneWidget);
    expect(
      find.text('Use your device\'s current location for this client?'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Change'));
    await tester.pumpAndSettle();

    expect(fakeGeoService.callCount, 2);
  });
}
