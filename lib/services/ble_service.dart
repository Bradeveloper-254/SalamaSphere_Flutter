import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/wearable_event.dart';

class BleService {
  static const deviceName = 'SalamaSphere';
  static const serviceUuid = '7b6a0001-7d42-4a8e-9b31-2f4c8a6e1000';
  static const deviceIdUuid = '7b6a0002-7d42-4a8e-9b31-2f4c8a6e1000';
  static const sosEventUuid = '7b6a0003-7d42-4a8e-9b31-2f4c8a6e1000';
  static const recordingStatusUuid = '7b6a0004-7d42-4a8e-9b31-2f4c8a6e1000';
  static const audioMetadataUuid = '7b6a0005-7d42-4a8e-9b31-2f4c8a6e1000';
  static const audioControlUuid = '7b6a0006-7d42-4a8e-9b31-2f4c8a6e1000';
  static const audioDataUuid = '7b6a0007-7d42-4a8e-9b31-2f4c8a6e1000';
  static const transferAckUuid = '7b6a0008-7d42-4a8e-9b31-2f4c8a6e1000';
  final _events = StreamController<WearableEvent>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _statuses = StreamController<String>.broadcast();
  final _metadata = StreamController<Map<String, dynamic>>.broadcast();
  final _chunks = StreamController<List<int>>.broadcast();
  final _acks = StreamController<Map<String, dynamic>>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  BluetoothDevice? _device;
  BluetoothCharacteristic? _control;
  Stream<WearableEvent> get events => _events.stream;
  Stream<Object> get errors => _errors.stream;
  Stream<String> get recordingStatuses => _statuses.stream;
  Stream<Map<String, dynamic>> get audioMetadata => _metadata.stream;
  Stream<List<int>> get audioChunks => _chunks.stream;
  Stream<Map<String, dynamic>> get transferAcks => _acks.stream;
  bool get isConnected => _device != null;
  Future<void> connectToWearable() async {
    await disconnect();
    await FlutterBluePlus.adapterState.where((s) => s == BluetoothAdapterState.on).first;
    final found = Completer<BluetoothDevice>();
    _subscriptions.add(FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        if (result.advertisementData.advName == deviceName || result.device.platformName == deviceName) {
          if (!found.isCompleted) found.complete(result.device);
        }
      }
    }));
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    final device = await found.future.timeout(const Duration(seconds: 15));
    await FlutterBluePlus.stopScan();
    await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 15));
    _device = device;
    final services = await device.discoverServices();
    final service = services.firstWhere((s) => s.uuid.str.toLowerCase() == serviceUuid);
    BluetoothCharacteristic? sos;
    for (final c in service.characteristics) {
      final id = c.uuid.str.toLowerCase();
      if (id == sosEventUuid) sos = c;
      if (id == audioControlUuid) _control = c;
      if (id == recordingStatusUuid) await _subscribe(c, (b) => _statuses.add(utf8.decode(b, allowMalformed: true).trim()));
      if (id == audioMetadataUuid) await _subscribe(c, _readMetadata);
      if (id == audioDataUuid) await _subscribe(c, (b) => _chunks.add(List<int>.from(b)));
      if (id == transferAckUuid) await _subscribe(c, _readAck);
    }
    if (sos == null) throw StateError('SOS characteristic not found.');
    await _subscribe(sos, (b) {
      try { _events.add(WearableEvent.fromJson(jsonDecode(utf8.decode(b)) as Map<String, dynamic>)); }
      catch (e) { _errors.add(e); }
    });
  }
  Future<void> _subscribe(BluetoothCharacteristic c, void Function(List<int>) handler) async {
    if (!(c.properties.notify || c.properties.indicate)) return;
    _subscriptions.add(c.onValueReceived.listen(handler, onError: _errors.add));
    await c.setNotifyValue(true);
  }
  void _readMetadata(List<int> b) { try { _metadata.add(Map<String, dynamic>.from(jsonDecode(utf8.decode(b)) as Map)); } catch (e) { _errors.add(e); } }
  void _readAck(List<int> b) { try { _acks.add(Map<String, dynamic>.from(jsonDecode(utf8.decode(b)) as Map)); } catch (e) { _errors.add(e); } }
  Future<void> requestAudioTransfer({required String transferId}) => _send('GET:$transferId');
  Future<void> acknowledgeAudioTransfer({required String transferId}) => _send('DONE:$transferId');
  WearableEvent parseEvent(List<int> bytes) {
    if (bytes.isEmpty) throw const FormatException('Empty SOS notification.');
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    if (decoded is! Map<String, dynamic>) throw const FormatException('SOS must be a JSON object.');
    return WearableEvent.fromJson(decoded);
  }
  Future<void> _send(String value) async {
    final control = _control;
    if (control == null) throw StateError('Audio control characteristic unavailable.');
    await control.write(utf8.encode(value), withoutResponse: control.properties.writeWithoutResponse && !control.properties.write);
  }
  Future<void> disconnect() async {
    for (final subscription in _subscriptions) await subscription.cancel();
    _subscriptions.clear();
    final device = _device; _device = null; _control = null;
    if (device != null) await device.disconnect();
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
  }
  Future<void> dispose() async {
    await disconnect();
    await _events.close(); await _errors.close(); await _statuses.close();
    await _metadata.close(); await _chunks.close(); await _acks.close();
  }
}
