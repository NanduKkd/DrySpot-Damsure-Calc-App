import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/client_provider.dart';
import 'providers/sync_provider.dart';
import 'providers/settings_provider.dart';
import 'services/api_service.dart';
import 'services/sync_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/clients/client_list_screen.dart';
import 'screens/splash_screen.dart';

class App extends StatelessWidget {
  final ApiService apiService;
  const App({super.key, required this.apiService});

  @override
  Widget build(BuildContext context) {
    final syncService = SyncService(apiService: apiService);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(
            create: (_) =>
                AuthProvider(apiService: apiService)..tryAutoLogin()),
        ChangeNotifierProxyProvider<AuthProvider, ClientProvider>(
          create: (_) => ClientProvider(),
          update: (_, auth, clientProvider) {
            final provider = clientProvider ?? ClientProvider();
            provider.updateSession(
              isAuthenticated: auth.isAuthenticated,
              franchiseeId: auth.franchiseeId,
            );
            return provider;
          },
        ),
        ChangeNotifierProvider(
            create: (_) => SettingsProvider()..loadSettings()),
        ChangeNotifierProvider(
            create: (_) => SyncProvider(syncService: syncService)),
        Provider.value(value: apiService),
      ],
      child: Consumer2<AuthProvider, ThemeProvider>(
        builder: (context, auth, theme, _) {
          return MaterialApp(
            key: ValueKey(auth.isAuthenticated),
            title: 'DrySpot Uppala',
            theme: ThemeData.light(useMaterial3: true),
            darkTheme: ThemeData.dark(useMaterial3: true),
            themeMode: theme.themeMode,
            home: auth.isRestoringSession
                ? const SplashScreen()
                : auth.isAuthenticated
                    ? const ClientListScreen()
                    : const LoginScreen(),
          );
        },
      ),
    );
  }
}
