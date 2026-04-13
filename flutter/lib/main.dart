import 'package:flutter/material.dart';
import 'src/app.dart';
import 'src/config/app_config.dart';
import 'src/services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final apiService = ApiService();
  if (AppConfig.showBackendUrlButton) {
    await apiService.loadServerUrl();
  }

  runApp(App(apiService: apiService));
}
