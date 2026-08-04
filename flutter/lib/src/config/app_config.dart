class AppConfig {
  static const String productionServerUrl = 'https://damsure.nandakrishnan.in';
  static const String _flavor = String.fromEnvironment(
    'DAMSURE_RELEASE_FLAVOR',
    defaultValue: 'production',
  );
  static const String _stagingServerUrl = String.fromEnvironment(
    'DAMSURE_STAGING_ORIGIN',
  );

  /// The staging URL is a compile-time define. Production is fixed.
  static String get defaultServerUrl =>
      _flavor == 'staging' ? _stagingServerUrl : productionServerUrl;

  static void validateBuildConfiguration() {
    if (_flavor != 'production' && _flavor != 'staging') {
      throw StateError('Unsupported Android application flavor.');
    }
    if (_flavor == 'production' && _stagingServerUrl.isNotEmpty) {
      throw StateError('Production builds must not contain a staging origin.');
    }
    final origin = Uri.tryParse(_stagingServerUrl);
    if (_flavor == 'staging' &&
        (origin == null ||
            origin.scheme != 'https' ||
            origin.host.isEmpty ||
            origin.hasPort ||
            (origin.path.isNotEmpty && origin.path != '/') ||
            origin.hasQuery ||
            origin.hasFragment ||
            origin.userInfo.isNotEmpty)) {
      throw StateError(
          'Staging builds require an HTTPS origin without a path.');
    }
  }

  static const bool showBackendUrlButton = false;
}
