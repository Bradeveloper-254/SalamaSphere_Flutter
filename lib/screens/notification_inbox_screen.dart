import 'package:flutter/material.dart';

import '../services/api_service.dart';

class NotificationInboxScreen extends StatefulWidget {
  final ApiService apiService;

  const NotificationInboxScreen({super.key, required this.apiService});

  @override
  State<NotificationInboxScreen> createState() =>
      _NotificationInboxScreenState();
}

class _NotificationInboxScreenState extends State<NotificationInboxScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _notifications = [];

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final response = await widget.apiService.fetchNotifications();
    if (!mounted) return;

    final rawData = response['data'];
    final rawItems = rawData is List
        ? rawData
        : rawData is Map<String, dynamic>
        ? rawData['results']
        : null;

    if (response['success'] == true && rawItems is List) {
      final notifications = <Map<String, dynamic>>[];
      for (final item in rawItems) {
        if (item is Map && item.keys.every((key) => key is String)) {
          notifications.add(Map<String, dynamic>.from(item));
        }
      }
      setState(() {
        _notifications = notifications;
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage =
            response['message']?.toString() ?? 'Could not load notifications.';
      });
    }
  }

  Future<void> _markRead(Map<String, dynamic> notification) async {
    if (notification['is_read'] == true) return;
    final id = notification['id']?.toString();
    if (id == null || id.isEmpty) return;

    final response = await widget.apiService.markNotificationRead(id);
    if (!mounted) return;
    if (response['success'] == true) {
      setState(() => notification['is_read'] = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            response['message']?.toString() ??
                'Could not mark notification as read.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Refresh notifications',
            onPressed: _isLoading ? null : _loadNotifications,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading && _notifications.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null && _notifications.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _loadNotifications,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadNotifications,
              child: _notifications.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 120),
                        Icon(Icons.notifications_none, size: 56),
                        SizedBox(height: 12),
                        Center(child: Text('No notifications yet.')),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(12),
                      itemCount: _notifications.length,
                      itemBuilder: (context, index) {
                        final item = _notifications[index];
                        final isRead = item['is_read'] == true;
                        final date = DateTime.tryParse(
                          item['created_at']?.toString() ?? '',
                        );
                        return Card(
                          color: isRead
                              ? null
                              : Theme.of(context).colorScheme.primaryContainer,
                          child: ListTile(
                            leading: Icon(
                              isRead
                                  ? Icons.notifications_none
                                  : Icons.notifications_active,
                            ),
                            title: Text(
                              item['title']?.toString() ??
                                  'SalamaSphere update',
                              style: TextStyle(
                                fontWeight: isRead
                                    ? FontWeight.normal
                                    : FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              [
                                item['message']?.toString() ?? '',
                                if (date != null) date.toLocal().toString(),
                              ].where((part) => part.isNotEmpty).join('\n'),
                            ),
                            onTap: () => _markRead(item),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
