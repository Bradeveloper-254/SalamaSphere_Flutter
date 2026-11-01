import 'package:flutter/material.dart';

import 'dashboards/victim.dart';
import '../services/api_service.dart';

import 'dashboards/admin.dart';
import 'dashboards/authority.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';
import 'incident_dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  final ApiService apiService;

  const LoginScreen({super.key, required this.apiService});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _isCheckingSession = true;
  bool _obscurePassword = true;
  String? _errorMessage;
  String? _loadingMessage;

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _navigateForAccount(Map<String, dynamic> result) async {
    if (!mounted) return;

    final username =
        result['username']?.toString() ?? _usernameController.text.trim();

    final role = result['role']?.toString().toLowerCase();

    final authorityStatus = result['authority_status']
        ?.toString()
        .toLowerCase();

    final isSuperuser = result['is_superuser'] == true;

    // Preserve authority verification restrictions.
    if (role == 'authority' && authorityStatus != 'approved') {
      widget.apiService.logout();

      setState(() {
        _isLoading = false;
        _errorMessage =
            'Your authority account is awaiting verification approval.';
      });
      return;
    }

    final Widget destination;

    if (isSuperuser || role == 'admin') {
      destination = AdminDashboardScreen(
        apiService: widget.apiService,
        username: username,
      );
    } else if (role == 'authority') {
      destination = AuthorityDashboardScreen(
        apiService: widget.apiService,
        username: username,
      );
    } else if (role == 'survivor' || role == 'victim') {
      destination = VictimDashboardScreen(
        apiService: widget.apiService,
        username: username,
      );
    } else if (role == 'trusted_contact' ||
        role == 'responder' ||
        role == 'designated_responder') {
      destination = IncidentDashboardScreen(
        apiService: widget.apiService,
        username: username,
        role: role!,
      );
    } else {
      widget.apiService.logout();

      setState(() {
        _isLoading = false;
        _errorMessage =
            'This account has an unsupported role. Contact support.';
      });
      return;
    }

    setState(() => _isLoading = false);

    await Navigator.of(context)
        .pushReplacement(MaterialPageRoute<void>(builder: (_) => destination));
  }

  Future<void> _checkExistingSession() async {
    if (!widget.apiService.isAuthenticated) {
      if (mounted) {
        setState(() => _isCheckingSession = false);
      }
      return;
    }

    setState(() {
      _isCheckingSession = true;
      _errorMessage = null;
    });

    final result = await widget.apiService.getCurrentUser();

    if (!mounted) return;

    if (result['success'] == true) {
      await _navigateForAccount(result);
      return;
    }

    final statusCode = result['status_code'];

    setState(() {
      _isCheckingSession = false;

      if (statusCode != 401 && widget.apiService.isAuthenticated) {
        _errorMessage = 'Could not verify your saved session. Check your internet connection and retry.';
      }
    });
  }

  Future<void> _login() async {
    if (_isLoading) return;

    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _loadingMessage = 'Connecting to SalamaSphere services. Please wait...';
    });

    try {
      final result = await widget.apiService.login(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );

      if (!mounted) return;

      if (result['success'] != true) {
        setState(() {
          _isLoading = false;
          _loadingMessage = null;
          _errorMessage =
              result['message']?.toString() ??
              'Unable to sign in. Please try again.';
        });
        return;
      }

      await _navigateForAccount(result);
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _loadingMessage = null;
        _errorMessage = 'Unable to connect to SalamaSphere. Check your internet connection and try again.';
      });

      debugPrint('SalamaSphere login error: $error');
    }
  }

  void _openRegister() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RegisterScreen(apiService: widget.apiService),
      ),
    );
  }

  void _openForgotPassword() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ForgotPasswordScreen(apiService: widget.apiService),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF176B5B);

    if (_isCheckingSession) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Checking your secure session...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('SalamaSphere'),
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      size: 76,
                      color: primaryColor,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Welcome back',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Sign in to continue to your secure account.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _usernameController,
                      enabled: !_isLoading,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter your username.'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      enabled: !_isLoading,
                      autocorrect: false,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (!_isLoading) _login();
                      },
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Enter your password.'
                          : null,
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ],
                    if (!_isCheckingSession &&
                        widget.apiService.isAuthenticated) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _isLoading ? null : _checkExistingSession,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry session verification'),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _isLoading ? null : _openForgotPassword,
                        child: const Text('Forgot password?'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_loadingMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _loadingMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF176B5B),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed: _isLoading ? null : _login,
                        child: _isLoading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('SIGN IN'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _isLoading ? null : _openRegister,
                      child: const Text('Create an account'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
