import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'services/api_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final apiService = ApiService();

  // Restore authentication before displaying the application.
  await apiService.restoreToken();

  runApp(SalamaSphereApp(apiService: apiService));
}

class SalamaSphereApp extends StatefulWidget {
  final ApiService apiService;

  const SalamaSphereApp({super.key, required this.apiService});

  @override
  State<SalamaSphereApp> createState() => _SalamaSphereAppState();
}

class _SalamaSphereAppState extends State<SalamaSphereApp> {
  @override
  void dispose() {
    widget.apiService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SalamaSphere',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: LoginScreen(apiService: widget.apiService),
    );
  }
}
