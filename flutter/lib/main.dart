import 'package:flutter/material.dart';
import 'src/app.dart';
import 'src/services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final apiService = ApiService();
  
  runApp(App(apiService: apiService));
}
