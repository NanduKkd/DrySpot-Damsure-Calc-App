class AppConfig {
  static const String defaultServerUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'http://localhost:3000',
  );

  static const bool showBackendUrlButton = bool.fromEnvironment(
    'SHOW_BACKEND_URL_BUTTON',
    defaultValue: false,
  );
}
