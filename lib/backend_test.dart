import 'package:flutter/material.dart';

import 'services/api_service.dart';

void main() {
  runApp(const BackendTestApp());
}

class BackendTestApp extends StatelessWidget {
  const BackendTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: BackendTestScreen(),
    );
  }
}

class BackendTestScreen extends StatefulWidget {
  const BackendTestScreen({super.key});

  @override
  State<BackendTestScreen> createState() => _BackendTestScreenState();
}

class _BackendTestScreenState extends State<BackendTestScreen> {
  final ApiService apiService = ApiService();

  final usernameController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = false;
  bool loggedIn = false;

  String result = 'Enter your development account credentials.';

  Future<void> login() async {
    setState(() {
      loading = true;
      result = 'Connecting to Django...';
    });

    final response = await apiService.login(
      username: usernameController.text.trim(),
      password: passwordController.text,
    );

    if (!mounted) return;

    setState(() {
      loading = false;
      loggedIn = response['success'] == true;

      result =
          '''
${response['message']}
HTTP status: ${response['status_code'] ?? 'Unavailable'}
''';
    });
  }

  Future<void> loadIncidents() async {
    setState(() {
      loading = true;
      result = 'Retrieving incidents...';
    });

    final response = await apiService.fetchIncidents();

    if (!mounted) return;

    setState(() {
      loading = false;

      result =
          '''
${response['message']}
HTTP status: ${response['status_code'] ?? 'Unavailable'}

Response:
${response['data'] ?? ''}
''';
    });
  }

  void logout() {
    apiService.logout();

    setState(() {
      loggedIn = false;
      result = 'Logged out. Your in-memory token has been cleared.';
      passwordController.clear();
    });
  }

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    apiService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SalamaSphere Backend Test')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.security, size: 64),
                const SizedBox(height: 16),
                const Text(
                  'Connect to SalamaSphere Django',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),

                if (!loggedIn) ...[
                  TextField(
                    controller: usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Development username',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) {
                      if (!loading) login();
                    },
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: loading ? null : login,
                    child: Text(loading ? 'Connecting...' : 'Log in'),
                  ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: loading ? null : loadIncidents,
                    icon: const Icon(Icons.sync),
                    label: const Text('Fetch Incidents'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: loading ? null : logout,
                    child: const Text('Log out'),
                  ),
                ],

                const SizedBox(height: 24),
                const Text(
                  'Connection result',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SelectableText(result),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
