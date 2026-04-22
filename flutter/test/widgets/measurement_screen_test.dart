import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/measurement_screen.dart';
import 'package:app_client/src/screens/clients/item_detail_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/default_price.dart';
import 'package:app_client/src/services/geo_service.dart';
import 'package:app_client/src/services/map_launcher_service.dart';
import 'package:geolocator/geolocator.dart';

class MockClientProvider extends ClientProvider {
  Client _client;
  Client? updatedClient;

  MockClientProvider(this._client);

  @override
  List<Client> get clients => [updatedClient ?? _client];

  @override
  Future<int> addItem(Item item) async {
    // Return a dummy ID
    return 999;
  }

  @override
  Future<Item?> getItemByLocalId(int localId) async {
    return (updatedClient ?? _client)
        .items
        .firstWhere((i) => i.localId == localId);
  }

  @override
  Future<void> updateClient(Client client) async {
    updatedClient = client;
    _client = client;
    notifyListeners();
  }
}

class MockSettingsProvider extends SettingsProvider {
  @override
  double get firstDefaultPrice => 12.5;

  @override
  Future<void> loadSettings() async {}

  @override
  List<DefaultPrice> get defaultPrices => [];
}

class FakeGeoService extends GeoService {
  FakeGeoService(this.position);

  final Position? position;
  int callCount = 0;

  @override
  Future<Position?> getCurrentLocation() async {
    callCount++;
    return position;
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

Position _testPosition({double lat = 13.37, double lng = 77.59}) {
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
  testWidgets('MeasurementScreen: Add Item dialog only has Name field',
      (WidgetTester tester) async {
    final client = Client(name: 'Test Client', localId: 1, items: []);
    final mockClientProvider = MockClientProvider(client);
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<SettingsProvider>.value(
              value: mockSettingsProvider),
        ],
        child: MaterialApp(
          home: MeasurementScreen(client: client),
        ),
      ),
    );

    // Tap the button to add item
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add Item'));
    await tester.pumpAndSettle();

    // The dialog should have "Add Item" as title
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('Add Item')),
        findsOneWidget);
    expect(find.widgetWithText(TextField, 'Name (e.g., Roof)'), findsOneWidget);
    // Ensure Price field is NOT present
    expect(find.widgetWithText(TextField, 'Price'), findsNothing);
  });

  testWidgets(
      'MeasurementScreen: Tapping an item navigates to ItemDetailScreen',
      (WidgetTester tester) async {
    final item =
        Item(name: 'Test Item', price: 10.0, localId: 101, clientId: 1);
    final client = Client(name: 'Test Client', localId: 1, items: [item]);
    final mockClientProvider = MockClientProvider(client);
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<SettingsProvider>.value(
              value: mockSettingsProvider),
        ],
        child: MaterialApp(
          home: MeasurementScreen(client: client),
        ),
      ),
    );

    await tester.tap(find.textContaining('Test Item'));
    await tester.pumpAndSettle();

    expect(find.byType(ItemDetailScreen), findsOneWidget);
  });

  testWidgets(
      'MeasurementScreen: Location dialog opens map app from coordinates',
      (WidgetTester tester) async {
    final client = Client(
      name: 'Test Client',
      localId: 1,
      latitude: 12.34,
      longitude: 56.78,
      items: [],
    );
    final mockClientProvider = MockClientProvider(client);
    final mockSettingsProvider = MockSettingsProvider();
    final fakeGeoService = FakeGeoService(_testPosition());
    final fakeMapLauncher = FakeMapLauncherService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<SettingsProvider>.value(
              value: mockSettingsProvider),
        ],
        child: MaterialApp(
          home: MeasurementScreen(
            client: client,
            geoService: fakeGeoService,
            mapLauncherService: fakeMapLauncher,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.location_on).first);
    await tester.pumpAndSettle();

    expect(find.text('Client Location'), findsOneWidget);
    expect(find.text('12.340000, 56.780000'), findsOneWidget);

    await tester.tap(find.text('12.340000, 56.780000'));
    await tester.pumpAndSettle();

    expect(fakeMapLauncher.callCount, 1);
    expect(fakeMapLauncher.lastLatitude, 12.34);
    expect(fakeMapLauncher.lastLongitude, 56.78);
  });

  testWidgets(
      'MeasurementScreen: Change to current location confirms before updating',
      (WidgetTester tester) async {
    final client = Client(
      name: 'Test Client',
      localId: 1,
      latitude: 12.34,
      longitude: 56.78,
      items: [],
    );
    final mockClientProvider = MockClientProvider(client);
    final mockSettingsProvider = MockSettingsProvider();
    final fakeGeoService =
        FakeGeoService(_testPosition(lat: 22.22, lng: 33.33));
    final fakeMapLauncher = FakeMapLauncherService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<SettingsProvider>.value(
              value: mockSettingsProvider),
        ],
        child: MaterialApp(
          home: MeasurementScreen(
            client: client,
            geoService: fakeGeoService,
            mapLauncherService: fakeMapLauncher,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.location_on).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change to Current Location'));
    await tester.pumpAndSettle();

    expect(find.text('Change Location'), findsOneWidget);
    expect(
      find.text(
        'Replace this client\'s saved coordinates with your current location?',
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Change'));
    await tester.pumpAndSettle();

    expect(fakeGeoService.callCount, 1);
    expect(mockClientProvider.updatedClient, isNotNull);
    expect(mockClientProvider.updatedClient!.latitude, 22.22);
    expect(mockClientProvider.updatedClient!.longitude, 33.33);
  });
}
