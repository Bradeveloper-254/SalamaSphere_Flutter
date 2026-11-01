// import 'package:flutter/material.dart';

// void main() {
//   runApp(const SalamaSphereApp());
// }

// class SalamaSphereApp extends StatelessWidget {
//   const SalamaSphereApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       title: 'SalamaSphere',
//       debugShowCheckedModeBanner: false,
//       theme: ThemeData(
//         colorScheme: ColorScheme.fromSeed(
//           seedColor: Colors.teal,
//         ),
//         useMaterial3: true,
//       ),
//       home: const DashboardScreen(),
//     );
//   }
// }

// class DashboardScreen extends StatefulWidget {
//   const DashboardScreen({super.key});

//   @override
//   State<DashboardScreen> createState() =>
//       _DashboardScreenState();
// }

// class _DashboardScreenState extends State<DashboardScreen> {
//   String connectionStatus = 'Not connected';
//   int pendingIncidents = 0;
//   int synchronizedIncidents = 0;

//   final List<Map<String, dynamic>> incidents = [];

//   void createSimulatedIncident() {
//     final now = DateTime.now();

//     final eventId =
//         'SS-${now.millisecondsSinceEpoch}';

//     setState(() {
//       pendingIncidents++;

//       incidents.insert(0, {
//         'event_id': eventId,
//         'event_type': 'SOS',
//         'recording_status': 'SIMULATED',
//         'sync_status': 'PENDING',
//         'created_at': now.toIso8601String(),
//       });
//     });

//     ScaffoldMessenger.of(context).showSnackBar(
//       const SnackBar(
//         content: Text(
//           'Simulated SOS event created.',
//         ),
//       ),
//     );
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         title: const Text('SalamaSphere'),
//         centerTitle: true,
//       ),
//       body: SafeArea(
//         child: ListView(
//           padding: const EdgeInsets.all(16),
//           children: [
//             Card(
//               child: Padding(
//                 padding: const EdgeInsets.all(16),
//                 child: Column(
//                   crossAxisAlignment:
//                       CrossAxisAlignment.start,
//                   children: [
//                     const Text(
//                       'Wearable Connection',
//                       style: TextStyle(
//                         fontSize: 18,
//                         fontWeight: FontWeight.bold,
//                       ),
//                     ),
//                     const SizedBox(height: 8),
//                     Row(
//                       children: [
//                         const Icon(
//                           Icons.bluetooth_disabled,
//                           color: Colors.grey,
//                         ),
//                         const SizedBox(width: 8),
//                         Text(connectionStatus),
//                       ],
//                     ),
//                   ],
//                 ),
//               ),
//             ),

//             const SizedBox(height: 12),

//             Row(
//               children: [
//                 Expanded(
//                   child: _buildSummaryCard(
//                     'Pending',
//                     pendingIncidents,
//                     Icons.pending_actions,
//                   ),
//                 ),
//                 const SizedBox(width: 12),
//                 Expanded(
//                   child: _buildSummaryCard(
//                     'Synchronized',
//                     synchronizedIncidents,
//                     Icons.cloud_done,
//                   ),
//                 ),
//               ],
//             ),

//             const SizedBox(height: 24),

//             FilledButton.icon(
//               onPressed: createSimulatedIncident,
//               icon: const Icon(Icons.add_alert),
//               label: const Text(
//                 'Create Test SOS Event',
//               ),
//             ),

//             const SizedBox(height: 24),

//             const Text(
//               'Incidents',
//               style: TextStyle(
//                 fontSize: 20,
//                 fontWeight: FontWeight.bold,
//               ),
//             ),

//             const SizedBox(height: 8),

//             if (incidents.isEmpty)
//               const Card(
//                 child: Padding(
//                   padding: EdgeInsets.all(20),
//                   child: Center(
//                     child: Text(
//                       'No incidents recorded yet.',
//                     ),
//                   ),
//                 ),
//               ),

//             ...incidents.map((incident) {
//               return Card(
//                 child: ListTile(
//                   leading: const CircleAvatar(
//                     child: Icon(Icons.notifications),
//                   ),
//                   title: Text(
//                     incident['event_type'],
//                   ),
//                   subtitle: Text(
//                     'ID: ${incident['event_id']}\n'
//                     'Status: ${incident['sync_status']}',
//                   ),
//                   isThreeLine: true,
//                 ),
//               );
//             }),
//           ],
//         ),
//       ),
//     );
//   }

//   Widget _buildSummaryCard(
//     String title,
//     int count,
//     IconData icon,
//   ) {
//     return Card(
//       child: Padding(
//         padding: const EdgeInsets.all(16),
//         child: Column(
//           children: [
//             Icon(icon, size: 30),
//             const SizedBox(height: 8),
//             Text(
//               '$count',
//               style: const TextStyle(
//                 fontSize: 24,
//                 fontWeight: FontWeight.bold,
//               ),
//             ),
//             Text(title),
//           ],
//         ),
//       ),
//     );
//   }
// }

import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'services/api_service.dart';

void main() {
  runApp(const SalamaSphereApp());
}

class SalamaSphereApp extends StatefulWidget {
  const SalamaSphereApp({super.key});

  @override
  State<SalamaSphereApp> createState() => _SalamaSphereAppState();
}

class _SalamaSphereAppState extends State<SalamaSphereApp> {
  late final ApiService apiService;

  @override
  void initState() {
    super.initState();
    apiService = ApiService();
  }

  @override
  void dispose() {
    apiService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SalamaSphere',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
        ),
        useMaterial3: true,
      ),
      home: LoginScreen(
        apiService: apiService,
      ),
    );
  }
}