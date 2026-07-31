import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/auth_provider.dart';
import 'providers/client_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/sync_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/clients/client_list_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/update/update_gate_screen.dart';
import 'services/api_service.dart';
import 'services/session_manager.dart';
import 'services/sync_service.dart';
import 'updates/update_coordinator.dart';

/// APP-113 owns the outer bootstrap. The normal application subtree (including
/// AuthProvider and every tenant-aware provider) does not exist until the
/// updater has loaded cached policy and permits normal use.
class App extends StatefulWidget {
  const App({
    super.key,
    required this.apiService,
    this.sessionManager,
    this.updateCoordinator,
  });

  final ApiService apiService;
  final SessionManager? sessionManager;
  final UpdateCoordinator? updateCoordinator;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  late final SessionManager _sessionManager =
      widget.sessionManager ?? SessionManager();
  late final UpdateCoordinator _updateCoordinator =
      widget.updateCoordinator ?? UpdateCoordinator();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateCoordinator.initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.updateCoordinator == null) _updateCoordinator.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateCoordinator.reconcileInstalledVersionAfterResume();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<UpdateCoordinator>.value(
          value: _updateCoordinator,
        ),
      ],
      child: Consumer2<ThemeProvider, UpdateCoordinator>(
        builder: (context, theme, update, _) {
          final state = update.state;
          if (state.isStartupPending) {
            return _materialApp(theme, const SplashScreen());
          }
          if (state.blocksNormalFlow) {
            return _materialApp(theme, const UpdateGateScreen());
          }
          // The provider graph wraps the navigator, rather than just its
          // home route, so normal pushed routes retain their app-scoped
          // dependencies.  Transitioning back to a blocking state removes
          // this entire subtree (and every pushed normal route) before the
          // updater gate is rendered.
          return _NormalApplication(
            apiService: widget.apiService,
            sessionManager: _sessionManager,
            child: _materialApp(theme, const _AuthRestoreGate()),
          );
        },
      ),
    );
  }

  Widget _materialApp(ThemeProvider theme, Widget home) => MaterialApp(
        title: 'DrySpot Uppala',
        theme: ThemeData.light(useMaterial3: true),
        darkTheme: ThemeData.dark(useMaterial3: true),
        themeMode: theme.themeMode,
        home: home,
      );
}

class _NormalApplication extends StatelessWidget {
  const _NormalApplication({
    required this.apiService,
    required this.sessionManager,
    required this.child,
  });

  final ApiService apiService;
  final SessionManager sessionManager;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // This entire provider graph is excluded from required-update startup.
    final syncService = SyncService(
      apiService: apiService,
      sessionManager: sessionManager,
    );
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthProvider(
            apiService: apiService,
            sessionManager: sessionManager,
          ),
        ),
        ChangeNotifierProxyProvider<AuthProvider, ClientProvider>(
          create: (_) => ClientProvider(sessionManager: sessionManager),
          update: (_, auth, clientProvider) {
            final provider = clientProvider ??
                ClientProvider(sessionManager: sessionManager);
            provider.updateSession(
              isAuthenticated: auth.isAuthenticated,
              franchiseeId: auth.franchiseeId,
            );
            return provider;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, SettingsProvider>(
          create: (_) => SettingsProvider(sessionManager: sessionManager),
          update: (_, auth, settingsProvider) {
            final provider = settingsProvider ??
                SettingsProvider(sessionManager: sessionManager);
            provider.updateSession(
              isAuthenticated: auth.isAuthenticated,
              franchiseeId: auth.franchiseeId,
            );
            return provider;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, SyncProvider>(
          create: (_) => SyncProvider(syncService: syncService),
          update: (_, auth, syncProvider) {
            final provider =
                syncProvider ?? SyncProvider(syncService: syncService);
            provider.updateSession(
              auth.sessionSnapshot,
              onAuthenticationExpired: auth.logout,
            );
            return provider;
          },
        ),
        Provider<ApiService>.value(value: apiService),
      ],
      child: child,
    );
  }
}

class _AuthRestoreGate extends StatefulWidget {
  const _AuthRestoreGate();

  @override
  State<_AuthRestoreGate> createState() => _AuthRestoreGateState();
}

class _AuthRestoreGateState extends State<_AuthRestoreGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().tryAutoLoginOnce();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) => Stack(
        children: [
          auth.isRestoringSession
              ? const SplashScreen()
              : auth.isAuthenticated
                  ? const ClientListScreen()
                  : const LoginScreen(),
          const OptionalUpdatePrompt(),
        ],
      ),
    );
  }
}
