import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/wearable_event.dart';

class _AudioTransfer {
  final String eventId;
  final int fileSize;
  final int totalChunks;
  final int chunkSize;
  final int startOffset;
  final int expectedCrc32;
  final Uint8List bytes;
  final Set<int> receivedSequences = <int>{};
  int highestContiguousSequence = -1;

  _AudioTransfer({
    required this.eventId,
    required this.fileSize,
    required this.totalChunks,
    required this.chunkSize,
    required this.startOffset,
    required this.expectedCrc32,
  }) : bytes = Uint8List(fileSize);
}

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
  final _connectionStates = StreamController<bool>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final Set<String> _reportedEventIds = <String>{};
  final List<String> _pendingTransferIds = <String>[];
  BluetoothDevice? _device;
  BluetoothCharacteristic? _control;
  BluetoothCharacteristic? _transferAck;
  String _deviceIdentifier = '';
  bool _connected = false;
  String? _activeTransferId;
  _AudioTransfer? _activeTransfer;
  Stream<WearableEvent> get events => _events.stream;
  Stream<Object> get errors => _errors.stream;
  Stream<String> get recordingStatuses => _statuses.stream;
  Stream<Map<String, dynamic>> get audioMetadata => _metadata.stream;
  Stream<List<int>> get audioChunks => _chunks.stream;
  bool get isConnected => _connected;
  Stream<bool> get connectionStates => _connectionStates.stream;
  Future<void> connectToWearable() async {
    await disconnect();
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first;
    final found = Completer<BluetoothDevice>();
    _subscriptions.add(
      FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          if (result.advertisementData.advName == deviceName ||
              result.device.platformName == deviceName) {
            if (!found.isCompleted) found.complete(result.device);
          }
        }
      }),
    );
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    final device = await found.future.timeout(const Duration(seconds: 15));
    await FlutterBluePlus.stopScan();
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );
    _device = device;
    _connected = true;
    _connectionStates.add(true);
    _subscriptions.add(
      device.connectionState.listen((state) {
        final connected = state == BluetoothConnectionState.connected;
        if (connected == isConnected) return;
        _connected = connected;
        _connectionStates.add(connected);
        if (!connected) {
          _activeTransfer = null;
          _activeTransferId = null;
        }
      }, onError: _errors.add),
    );
    try {
      await device.requestMtu(247);
    } catch (error) {
      _errors.add(error);
    }

    final services = await device.discoverServices();
    final service = services.firstWhere(
      (s) => s.uuid.str.toLowerCase() == serviceUuid,
    );
    BluetoothCharacteristic? sos;
    BluetoothCharacteristic? deviceId;
    for (final c in service.characteristics) {
      final id = c.uuid.str.toLowerCase();
      if (id == sosEventUuid) sos = c;
      if (id == audioControlUuid) _control = c;
      if (id == transferAckUuid) _transferAck = c;
      if (id == deviceIdUuid) deviceId = c;
      if (id == recordingStatusUuid) {
        await _subscribe(
          c,
          (b) => _statuses.add(utf8.decode(b, allowMalformed: true).trim()),
        );
        if (c.properties.read) {
          _statuses.add(
            utf8.decode(await c.read(), allowMalformed: true).trim(),
          );
        }
      }
      if (id == audioMetadataUuid) await _subscribe(c, _readMetadata);
      if (id == audioDataUuid) await _subscribe(c, _readAudioData);
    }
    if (sos == null) {
      throw StateError('SOS characteristic not found.');
    }
    if (_control == null) {
      throw StateError('Audio control characteristic not found.');
    }
    if (_transferAck == null) {
      throw StateError('Transfer ACK characteristic not found.');
    }

    if (deviceId != null && deviceId.properties.read) {
      _readDeviceIdentifier(await deviceId.read());
    }

    await _subscribe(sos, _readSosEvent);
    if (sos.properties.read) _readSosEvent(await sos.read());
    await _sendControl('LIST');
  }

  Future<void> _subscribe(
    BluetoothCharacteristic c,
    void Function(List<int>) handler,
  ) async {
    if (!(c.properties.notify || c.properties.indicate)) return;
    _subscriptions.add(c.onValueReceived.listen(handler, onError: _errors.add));
    await c.setNotifyValue(true);
  }

  void _readMetadata(List<int> b) {
    try {
      final metadata = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(b)) as Map,
      );
      metadata['transfer_id'] ??= metadata['event_id'];
      metadata['mime_type'] ??= 'audio/wav';
      _metadata.add(metadata);
    } catch (e) {
      _errors.add(e);
    }
  }

  void _readDeviceIdentifier(List<int> bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map) {
        _deviceIdentifier =
            (value['device_id'] ?? value['device_identifier'] ?? '').toString();
      }
    } catch (e) {
      _errors.add(e);
    }
  }

  void _readSosEvent(List<int> bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes).trim());
      if (value is! Map<String, dynamic> ||
          value['event_type'] == null ||
          value['event_type'] == 'NONE') {
        return;
      }
      _emitEvent(WearableEvent.fromJson(value));
    } catch (error) {
      _errors.add(error);
    }
  }

  void _emitEvent(WearableEvent event) {
    if (_reportedEventIds.add(event.eventId)) _events.add(event);
  }

  void _readAudioData(List<int> bytes) {
    if (bytes.isEmpty) return;
    if (_isTextMessage(bytes)) {
      _handleAudioMessage(utf8.decode(bytes, allowMalformed: true).trim());
    } else {
      _handleAudioPacket(bytes);
    }
  }

  bool _isTextMessage(List<int> bytes) => bytes.every(
    (byte) =>
        byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte <= 126),
  );

  void _handleAudioMessage(String message) {
    if (message.startsWith('START:')) {
      final fields = message.split(':');
      if (fields.length != 7) {
        _errors.add(const FormatException('Invalid audio START message.'));
        return;
      }
      final fileSize = int.tryParse(fields[2]);
      final totalChunks = int.tryParse(fields[3]);
      final chunkSize = int.tryParse(fields[4]);
      final startOffset = int.tryParse(fields[5]);
      final expectedCrc = int.tryParse(fields[6], radix: 16);
      if (fileSize == null ||
          fileSize <= 0 ||
          fileSize > 20 * 1024 * 1024 ||
          totalChunks == null ||
          totalChunks <= 0 ||
          chunkSize == null ||
          chunkSize <= 0 ||
          startOffset == null ||
          expectedCrc == null) {
        _errors.add(const FormatException('Invalid audio transfer metadata.'));
        return;
      }
      if (startOffset != 0) {
        _activeTransfer = null;
        _activeTransferId = fields[1];
        unawaited(_sendControl('GET:${fields[1]}').catchError(_errors.add));
        return;
      }

      _activeTransferId = fields[1];
      _activeTransfer = _AudioTransfer(
        eventId: fields[1],
        fileSize: fileSize,
        totalChunks: totalChunks,
        chunkSize: chunkSize,
        startOffset: startOffset,
        expectedCrc32: expectedCrc,
      );
      _metadata.add({
        'event_id': fields[1],
        'transfer_id': fields[1],
        'filename': '${fields[1]}.wav',
        'mime_type': 'audio/wav',
        'file_size': fileSize,
        'total_chunks': totalChunks,
        'chunk_size': chunkSize,
        'crc32': fields[6],
      });
      return;
    }

    if (message.startsWith('FILE:')) {
      final fields = message.split(':');
      if (fields.length >= 3 && _deviceIdentifier.isNotEmpty) {
        _emitEvent(
          WearableEvent(
            eventId: fields[1],
            deviceIdentifier: _deviceIdentifier,
            eventType: 'SOS',
            timestamp: DateTime.now().toUtc(),
            recordingStatus: 'SAVED',
          ),
        );
      }
      return;
    }

    if (message.startsWith('COMPLETE:')) {
      _completeAudioTransfer(message);
      return;
    }

    if (message.startsWith('ERROR:')) {
      _errors.add(StateError('Wearable transfer failed: $message'));
      _activeTransfer = null;
      _activeTransferId = null;
      unawaited(_startNextAudioTransfer());
    }
  }

  void _handleAudioPacket(List<int> packet) {
    final transfer = _activeTransfer;
    if (transfer == null || packet.length < 6) {
      _errors.add(const FormatException('Audio packet arrived without START.'));
      return;
    }
    final sequence =
        packet[0] | (packet[1] << 8) | (packet[2] << 16) | (packet[3] << 24);
    final length = packet[4] | (packet[5] << 8);
    if (sequence >= transfer.totalChunks ||
        length <= 0 ||
        packet.length != length + 6) {
      _errors.add(const FormatException('Invalid audio data packet.'));
      return;
    }

    final offset = transfer.startOffset + sequence * transfer.chunkSize;
    if (offset + length > transfer.fileSize) {
      _errors.add(
        const FormatException('Audio data packet exceeds file size.'),
      );
      return;
    }
    transfer.bytes.setRange(offset, offset + length, packet, 6);
    transfer.receivedSequences.add(sequence);

    final previousAck = transfer.highestContiguousSequence;
    while (transfer.receivedSequences.contains(
      transfer.highestContiguousSequence + 1,
    )) {
      transfer.highestContiguousSequence++;
    }
    if (transfer.highestContiguousSequence > previousAck) {
      unawaited(
        _sendAcknowledgement(transfer.highestContiguousSequence)
            .catchError(_errors.add),
      );
    }
  }

  void _completeAudioTransfer(String message) {
    final transfer = _activeTransfer;
    final fields = message.split(':');
    if (transfer == null || fields.length != 5) {
      _errors.add(const FormatException('Unexpected audio COMPLETE message.'));
      return;
    }
    final receivedSize = int.tryParse(fields[2]);
    final receivedChunks = int.tryParse(fields[3]);
    final receivedCrc = int.tryParse(fields[4], radix: 16);
    if (fields[1] != transfer.eventId ||
        receivedSize != transfer.fileSize ||
        receivedChunks != transfer.totalChunks ||
        receivedCrc != transfer.expectedCrc32 ||
        transfer.receivedSequences.length != transfer.totalChunks ||
        crc32(transfer.bytes) != transfer.expectedCrc32) {
      _errors.add(
        const FormatException('Audio transfer integrity check failed.'),
      );
    } else {
      _chunks.add(List<int>.from(transfer.bytes));
    }
    _activeTransfer = null;
    _activeTransferId = null;
    unawaited(_startNextAudioTransfer());
  }

  static int crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  Future<void> requestAudioTransfer({required String transferId}) async {
    if (_activeTransferId == transferId ||
        _pendingTransferIds.contains(transferId)) {
      return;
    }
    _pendingTransferIds.add(transferId);
    await _startNextAudioTransfer();
  }

  Future<void> _startNextAudioTransfer() async {
    if (_activeTransferId != null || _pendingTransferIds.isEmpty) return;
    final transferId = _pendingTransferIds.removeAt(0);
    _activeTransferId = transferId;
    try {
      await _sendControl('GET:$transferId');
    } catch (error) {
      _activeTransferId = null;
      _pendingTransferIds.insert(0, transferId);
      rethrow;
    }
  }

  Future<void> _sendAcknowledgement(int sequence) async {
    final ack = _transferAck;
    if (ack == null) {
      throw StateError('Transfer ACK characteristic unavailable.');
    }
    await ack.write(
      utf8.encode('ACK:$sequence'),
      withoutResponse:
          ack.properties.writeWithoutResponse && !ack.properties.write,
    );
  }

  Future<void> _sendControl(String command) async {
    final control = _control;
    if (control == null) {
      throw StateError('Audio control characteristic unavailable.');
    }
    await control.write(
      utf8.encode(command),
      withoutResponse:
          control.properties.writeWithoutResponse && !control.properties.write,
    );
  }

  Future<void> acknowledgeAudioTransfer({required String transferId}) =>
      _sendControl('DELETE:$transferId');

  WearableEvent parseEvent(List<int> bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('Empty SOS notification.');
    }
    final decoded = jsonDecode(utf8.decode(bytes).trim());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('SOS must be a JSON object.');
    }
    return WearableEvent.fromJson(decoded);
  }

  Future<void> disconnect() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final device = _device;
    _device = null;
    _connected = false;
    _connectionStates.add(false);
    _control = null;
    _transferAck = null;
    _deviceIdentifier = '';
    _activeTransfer = null;
    _activeTransferId = null;
    _pendingTransferIds.clear();
    if (device != null) await device.disconnect();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
    await _errors.close();
    await _statuses.close();
    await _metadata.close();
    await _chunks.close();
    await _connectionStates.close();
  }
}
