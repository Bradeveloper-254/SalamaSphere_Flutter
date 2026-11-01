import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../services/api_service.dart';

class RegisterScreen extends StatefulWidget {
  final ApiService apiService;

  const RegisterScreen({super.key, required this.apiService});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();

  final usernameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  String selectedRole = 'survivor';
  String selectedDocumentType = 'national_id';

  String message = '';

  PlatformFile? selectedDocument;
  int? selectedDocumentSize;

  bool loading = false;
  bool registrationSuccessful = false;
  bool accountCreated = false;
  bool documentUploaded = false;

  bool obscurePassword = true;
  bool obscureConfirmation = true;

  // ---------------------------------------------------------
  // SELECT AUTHORITY VERIFICATION DOCUMENT
  // ---------------------------------------------------------

  Future<void> pickVerificationDocument() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
      );

      if (!mounted || files.isEmpty) {
        return;
      }

      final file = files.single;
      final fileSize = await file.length();
      if (!mounted) return;

      if (fileSize == null) {
        setState(() {
          message = 'The selected document could not be read. Please select it again.';
        });
        return;
      }

      if (fileSize > 5 * 1024 * 1024) {
        setState(() {
          message = 'The document must not exceed 5 MB.';
        });
        return;
      }

      setState(() {
        selectedDocument = file;
        selectedDocumentSize = fileSize;
        message = '';
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        message = 'Could not select the document. Please try again.';
      });
    }
  }

  // ---------------------------------------------------------
  // REGISTER ACCOUNT
  // ---------------------------------------------------------

  Future<void> register() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Authority applicants must select a verification document.
    if (selectedRole == 'authority' && selectedDocument == null) {
      setState(() {
        message = 'Please select a verification document first.';
      });
      return;
    }

    setState(() {
      loading = true;
      message = '';
    });

    try {
      final response = await widget.apiService.register(
        username: usernameController.text.trim(),
        email: emailController.text.trim(),
        phoneNumber: phoneController.text.trim(),
        password: passwordController.text,
        role: selectedRole,
      );

      if (!mounted) return;

      if (response['success'] != true) {
        setState(() {
          loading = false;
          registrationSuccessful = false;
          message =
              response['message']?.toString() ??
              'Registration failed. Please try again.';
        });
        return;
      }

      // Registration has succeeded. Remember this separately from
      // document submission so a failed upload doesn't require
      // creating the account again.
      setState(() {
        accountCreated = true;
        registrationSuccessful = true;
      });

      if (selectedRole == 'survivor') {
        setState(() {
          loading = false;
          message =
              'Your survivor account has been created. '
              'You can now return to the login screen.';
        });
        return;
      }

      // Log in to obtain the authentication token required by
      // the protected verification-document upload endpoint.
      final loginResponse = await widget.apiService.login(
        username: usernameController.text.trim(),
        password: passwordController.text,
      );

      if (!mounted) return;

      if (loginResponse['success'] != true) {
        setState(() {
          loading = false;
          message =
              'Your authority account was created, but automatic '
              'login failed. Return to login and sign in with your '
              'new credentials. Then submit your verification document.';
        });
        return;
      }

      // Account exists and we have an authenticated session.
      // Now submit the verification document.
      await _uploadSelectedDocument();
    } catch (_) {
      if (!mounted) return;

      setState(() {
        loading = false;
        message = accountCreated
            ? 'Your account was created, but the next step failed. '
                  'Please retry the verification upload or sign in again.'
            : 'Could not connect to SalamaSphere. Please try again.';
      });
    }
  }

  // ---------------------------------------------------------
  // UPLOAD AUTHORITY VERIFICATION DOCUMENT
  // ---------------------------------------------------------

  Future<void> _uploadSelectedDocument() async {
    if (selectedDocument == null) {
      if (!mounted) return;

      setState(() {
        loading = false;
        documentUploaded = false;
        message = 'Your account exists. Please select a verification document.';
      });
      return;
    }

    setState(() {
      loading = true;
      message = '';
    });

    try {
      final response = await widget.apiService.uploadAuthorityDocument(
        documentType: selectedDocumentType,
        file: selectedDocument!,
      );

      if (!mounted) return;

      final success = response['success'] == true;

      setState(() {
        loading = false;
        documentUploaded = success;

        if (success) {
          message =
              'Your authority account and verification document '
              'have been submitted successfully. Your application '
              'is awaiting administrator review. Access to restricted '
              'incident information remains unavailable until approval.';
        } else {
          message =
              'Your account has been created, but the document '
              'upload failed. ${response['message'] ?? 'Please try again.'} '
              'Use the retry button below; do not register again.';
        }
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        loading = false;
        documentUploaded = false;
        message =
            'Your account exists, but the document could not be uploaded. '
            'Check your connection and retry the upload.';
      });
    }
  }

  // ---------------------------------------------------------
  // RETRY DOCUMENT UPLOAD
  // ---------------------------------------------------------

  Future<void> retryDocumentUpload() async {
    if (!accountCreated || selectedRole != 'authority') {
      return;
    }

    // If the token is no longer valid, ask the user to log in again.
    if (!widget.apiService.isAuthenticated) {
      setState(() {
        message =
            'Your account exists, but your session is not authenticated. '
            'Return to login, sign in, and submit the document.';
      });
      return;
    }

    await _uploadSelectedDocument();
  }

  // ---------------------------------------------------------
  // VALIDATION
  // ---------------------------------------------------------

  String? validateUsername(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Username is required.';
    }

    if (value.trim().length < 3) {
      return 'Username must contain at least 3 characters.';
    }

    return null;
  }

  String? validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Email is required.';
    }

    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim())) {
      return 'Enter a valid email address.';
    }

    return null;
  }

  String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required.';
    }

    if (value.length < 8) {
      return 'Password must contain at least 8 characters.';
    }

    return null;
  }

  // ---------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------

  @override
  void dispose() {
    usernameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();

    super.dispose();
  }

  // ---------------------------------------------------------
  // USER INTERFACE
  // ---------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.shield_outlined, size: 64),

                  const SizedBox(height: 12),

                  Text(
                    'Join SalamaSphere',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),

                  const SizedBox(height: 8),

                  const Text(
                    'Create an account to access SalamaSphere services.',
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 28),

                  // USERNAME
                  TextFormField(
                    controller: usernameController,
                    enabled: !accountCreated && !loading,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      border: OutlineInputBorder(),
                    ),
                    validator: validateUsername,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                  ),

                  const SizedBox(height: 16),

                  // EMAIL
                  TextFormField(
                    controller: emailController,
                    enabled: !accountCreated && !loading,
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    validator: validateEmail,
                    textInputAction: TextInputAction.next,
                  ),

                  const SizedBox(height: 16),

                  // PHONE
                  TextFormField(
                    controller: phoneController,
                    enabled: !accountCreated && !loading,
                    decoration: const InputDecoration(
                      labelText: 'Phone number (optional)',
                      hintText: 'e.g. 07XXXXXXXX',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.phone,
                  ),

                  const SizedBox(height: 16),

                  // ACCOUNT ROLE
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(
                      labelText: 'Account type',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'survivor',
                        child: Text('Survivor'),
                      ),
                      DropdownMenuItem(
                        value: 'authority',
                        child: Text('Authority'),
                      ),
                    ],
                    onChanged: accountCreated || loading
                        ? null
                        : (value) {
                            if (value == null) return;

                            setState(() {
                              selectedRole = value;
                              selectedDocument = null;
                              selectedDocumentSize = null;
                              selectedDocumentType = 'national_id';
                              message = '';
                            });
                          },
                  ),

                  // AUTHORITY-ONLY FIELDS
                  if (selectedRole == 'authority') ...[
                    const SizedBox(height: 16),

                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Authority accounts require administrator '
                          'verification before accessing restricted '
                          'incident information.',
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // DOCUMENT TYPE
                    DropdownButtonFormField<String>(
                      initialValue: selectedDocumentType,
                      decoration: const InputDecoration(
                        labelText: 'Verification document type',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'national_id',
                          child: Text('National ID'),
                        ),
                        DropdownMenuItem(
                          value: 'employment_id',
                          child: Text('Employment ID'),
                        ),
                        DropdownMenuItem(
                          value: 'professional_id',
                          child: Text('Professional ID'),
                        ),
                        DropdownMenuItem(
                          value: 'authorization_letter',
                          child: Text('Authorization letter'),
                        ),
                        DropdownMenuItem(value: 'other', child: Text('Other')),
                      ],
                      onChanged: loading || accountCreated || documentUploaded
                          ? null
                          : (value) {
                              if (value == null) return;

                              setState(() {
                                selectedDocumentType = value;
                              });
                            },
                    ),

                    const SizedBox(height: 12),

                    // DOCUMENT PICKER
                    OutlinedButton.icon(
                      onPressed: loading || accountCreated || documentUploaded
                          ? null
                          : pickVerificationDocument,
                      icon: const Icon(Icons.upload_file),
                      label: Text(
                        selectedDocument == null
                            ? 'Choose verification document'
                            : 'Change selected document',
                      ),
                    ),

                    if (selectedDocument != null) ...[
                      const SizedBox(height: 8),

                      Text(
                        'Selected: ${selectedDocument!.name}',
                        textAlign: TextAlign.center,
                      ),

                      Text(
                        'Size: '
                        '${((selectedDocumentSize ?? 0) / 1024).toStringAsFixed(1)} KB',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],

                    const SizedBox(height: 8),

                    const Text(
                      'Accepted formats: PDF, JPG, JPEG and PNG. '
                      'Maximum size: 5 MB.',
                      textAlign: TextAlign.center,
                    ),
                  ],

                  // PASSWORD
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: passwordController,
                    enabled: !accountCreated && !loading,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: obscurePassword
                            ? 'Show password'
                            : 'Hide password',
                        onPressed: () {
                          setState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                    validator: validatePassword,
                    textInputAction: TextInputAction.next,
                  ),

                  const SizedBox(height: 16),

                  // CONFIRM PASSWORD
                  TextFormField(
                    controller: confirmPasswordController,
                    enabled: !accountCreated && !loading,
                    obscureText: obscureConfirmation,
                    decoration: InputDecoration(
                      labelText: 'Confirm password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: obscureConfirmation
                            ? 'Show password'
                            : 'Hide password',
                        onPressed: () {
                          setState(() {
                            obscureConfirmation = !obscureConfirmation;
                          });
                        },
                        icon: Icon(
                          obscureConfirmation
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (value != passwordController.text) {
                        return 'Passwords do not match.';
                      }

                      return null;
                    },
                  ),

                  // STATUS MESSAGE
                  if (message.isNotEmpty) ...[
                    const SizedBox(height: 16),

                    Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        style: TextStyle(
                          color:
                              documentUploaded ||
                                  (registrationSuccessful &&
                                      selectedRole == 'survivor')
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // MAIN ACTION
                  FilledButton(
                    onPressed: loading || registrationSuccessful
                        ? null
                        : register,
                    child: Text(loading ? 'Please wait...' : 'Create account'),
                  ),

                  // RETRY UPLOAD AFTER ACCOUNT CREATION
                  if (accountCreated &&
                      selectedRole == 'authority' &&
                      !documentUploaded) ...[
                    const SizedBox(height: 12),

                    OutlinedButton.icon(
                      onPressed: loading ? null : retryDocumentUpload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry document upload'),
                    ),
                  ],

                  const SizedBox(height: 12),

                  OutlinedButton(
                    onPressed: loading
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Back to login'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
