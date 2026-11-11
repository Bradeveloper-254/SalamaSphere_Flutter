import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/wearable_event.dart';
import 'audio_chunk_ack_tracker.dart';

/// SalamaSphere BLE client for ESP32-S3 firmware v1.4.x.
/// FILE_TRANSFER (0006) receives text control messages and binary audio packets.
/// TRANSFER_ACK (0007) sends LIST, GET, ACK, DONE, DELETE and STATUS commands.
/// ACKs are generated automatically; the app must save a verified WAV before DONE.
class _AudioTransfer {
  final String eventId;
  final int fileSize;
  final int totalChunks;
  final int chunkSize;
  final int startOffset;
  final int expectedCrc32;
  final Uint8List bytes;
  final AudioChunkAckTracker ackTracker = AudioChunkAckTracker();

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
  static const String deviceName = 'SalamaSphere';

  static const String serviceUuid = '7b100001-5a1a-4d3e-9c2f-6b8e0d100001';
  static const String deviceIdUuid = '7b100002-5a1a-4d3e-9c2f-6b8e0d100002';
  static const String sosEventUuid = '7b100003-5a1a-4d3e-9c2f-6b8e0d100003';
  static const String recordingStatusUuid =
      '7b100004-5a1a-4d3e-9c2f-6b8e0d100004';
  static const String audioMetadataUuid =
      '7b100005-5a1a-4d3e-9c2f-6b8e0d100005';
  static const String fileTransferUuid = '7b100006-5a1a-4d3e-9c2f-6b8e0d100006';
  static const String transferAckUuid = '7b100007-5a1a-4d3e-9c2f-6b8e0d100007';
  static const String batteryUuid = '7b100008-5a1a-4d3e-9c2f-6b8e0d100008';

  static const int maxAudioBytes = 20 * 1024 * 1024;

  final StreamController<WearableEvent> _events =
      StreamController<WearableEvent>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  final StreamController<String> _statuses =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _metadata =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<List<int>> _chunks =
      StreamController<List<int>>.broadcast();
  final StreamController<bool> _connectionStates =
      StreamController<bool>.broadcast();
  final StreamController<Map<String, dynamic>> _battery =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _recordings =
      StreamController<Map<String, dynamic>>.broadcast();

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Set<String> _reportedEventKeys = <String>{};
  final List<String> _pendingTransferIds = <String>[];

  BluetoothDevice? _device;
  BluetoothCharacteristic? _commands;
  BluetoothCharacteristic? _fileTransfer;
  BluetoothCharacteristic? _sosEvent;
  BluetoothCharacteristic? _deviceId;
  BluetoothCharacteristic? _recordingStatus;
  BluetoothCharacteristic? _audioMetadata;
  BluetoothCharacteristic? _batteryCharacteristic;

  String _deviceIdentifier = '';
  bool _connected = false;
  bool _startingNextTransfer = false;
  String? _activeTransferId;
  _AudioTransfer? _activeTransfer;

  // Serialize ACK writes; notifications can arrive faster than GATT writes.
  Future<void> _ackWriteQueue = Future<void>.value();
  int _lastAckQueued = -1;

  Stream<WearableEvent> get events => _events.stream;
  Stream<Object> get errors => _errors.stream;
  Stream<String> get recordingStatuses => _statuses.stream;
  Stream<Map<String, dynamic>> get audioMetadata => _metadata.stream;
  Stream<List<int>> get audioChunks => _chunks.stream;
  Stream<bool> get connectionStates => _connectionStates.stream;
  Stream<Map<String, dynamic>> get batteryStatuses => _battery.stream;
  Stream<Map<String, dynamic>> get recordings => _recordings.stream;

  bool get isConnected => _connected;
  String get deviceIdentifier => _deviceIdentifier;

  Future<void> connectToWearable() async {
    await disconnect();

    await FlutterBluePlus.adapterState
        .where((state) => state == BluetoothAdapterState.on)
        .first
        .timeout(const Duration(seconds: 15));

    final found = Completer<BluetoothDevice>();
    _subscriptions.add(
      FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          if (result.advertisementData.advName == deviceName ||
              result.device.platformName == deviceName) {
            if (!found.isCompleted) found.complete(result.device);
          }
        }
      }, onError: _errors.add),
    );

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));

    BluetoothDevice device;
    try {
      device = await found.future.timeout(const Duration(seconds: 15));
    } finally {
      await FlutterBluePlus.stopScan();
    }

    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 20),
    );

    _device = device;
    _connected = true;
    _connectionStates.add(true);

    _subscriptions.add(
      device.connectionState.listen((state) {
        final connected = state == BluetoothConnectionState.connected;
        if (_connected == connected) return;
        _connected = connected;
        _connectionStates.add(connected);
        if (!connected) {
          _activeTransfer = null;
          _activeTransferId = null;
          _pendingTransferIds.clear();
          _lastAckQueued = -1;
          _ackWriteQueue = Future<void>.value();
        }
      }, onError: _errors.add),
    );

    try {
      await device.requestMtu(247);
    } catch (error) {
      _errors.add(error);
    }

    final services = await device.discoverServices();
    final matching = services.where(
      (service) => service.uuid.str.toLowerCase() == serviceUuid,
    );
    if (matching.isEmpty) {
      throw StateError(
        'SalamaSphere BLE service not found. Check firmware UUID.',
      );
    }

    for (final characteristic in matching.first.characteristics) {
      final id = characteristic.uuid.str.toLowerCase();
      if (id == deviceIdUuid) _deviceId = characteristic;
      if (id == sosEventUuid) _sosEvent = characteristic;
      if (id == recordingStatusUuid) _recordingStatus = characteristic;
      if (id == audioMetadataUuid) _audioMetadata = characteristic;
      if (id == fileTransferUuid) _fileTransfer = characteristic;
      if (id == transferAckUuid) _commands = characteristic;
      if (id == batteryUuid) _batteryCharacteristic = characteristic;
    }

    if (_sosEvent == null || _fileTransfer == null || _commands == null) {
      final discovered = matching.first.characteristics
          .map((characteristic) => characteristic.uuid.str.toLowerCase())
          .join(', ');
      throw StateError(
        'Missing required SOS_EVENT (0003), FILE_TRANSFER (0006), '
        'or TRANSFER_ACK (0007) characteristic. Discovered: '
        '${discovered.isEmpty ? '(none)' : discovered}.',
      );
    }
    if (!_commands!.properties.write &&
        !_commands!.properties.writeWithoutResponse) {
      throw StateError('TRANSFER_ACK characteristic is not writable.');
    }
    if (!_fileTransfer!.properties.notify &&
        !_fileTransfer!.properties.indicate) {
      throw StateError('FILE_TRANSFER characteristic cannot notify.');
    }

    if (_deviceId != null && _deviceId!.properties.read) {
      _readDeviceIdentifier(await _deviceId!.read());
    }

    if (_recordingStatus != null) {
      await _subscribe(_recordingStatus!, (bytes) {
        _statuses.add(utf8.decode(bytes, allowMalformed: true).trim());
      });
      if (_recordingStatus!.properties.read) {
        _statuses.add(
          utf8
              .decode(await _recordingStatus!.read(), allowMalformed: true)
              .trim(),
        );
      }
    }

    if (_audioMetadata != null) {
      await _subscribe(_audioMetadata!, _readMetadata);
      if (_audioMetadata!.properties.read) {
        final value = await _audioMetadata!.read();
        if (value.isNotEmpty) _readMetadata(value);
      }
    }

    if (_batteryCharacteristic != null) {
      await _subscribe(_batteryCharacteristic!, _readBattery);
      if (_batteryCharacteristic!.properties.read) {
        final value = await _batteryCharacteristic!.read();
        if (value.isNotEmpty) _readBattery(value);
      }
    }

    // Subscribe before LIST: the firmware may start pushing pending WAV files.
    await _subscribe(_fileTransfer!, _readFileTransfer);
    await _subscribe(_sosEvent!, _readSosEvent);
    if (_sosEvent!.properties.read) {
      _readSosEvent(await _sosEvent!.read());
    }
    await _sendCommand('LIST');
  }

  Future<void> _subscribe(
    BluetoothCharacteristic characteristic,
    void Function(List<int>) handler,
  ) async {
    if (!(characteristic.properties.notify ||
        characteristic.properties.indicate)) {
      return;
    }
    _subscriptions.add(
      characteristic.onValueReceived.listen(handler, onError: _errors.add),
    );
    await characteristic.setNotifyValue(true);
  }

  void _readDeviceIdentifier(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes).trim());
      if (decoded is Map) {
        _deviceIdentifier =
            (decoded['device_id'] ?? decoded['device_identifier'] ?? '')
                .toString();
      }
    } catch (error) {
      _errors.add(error);
    }
  }

  void _readMetadata(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes).trim());
      if (decoded is Map) {
        final value = Map<String, dynamic>.from(decoded);
        value['transfer_id'] ??= value['event_id'];
        value['mime_type'] ??= 'audio/wav';
        _metadata.add(value);
      }
    } catch (error) {
      _errors.add(error);
    }
  }

  void _readBattery(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes).trim());
      if (decoded is Map) _battery.add(Map<String, dynamic>.from(decoded));
    } catch (error) {
      _errors.add(error);
    }
  }

  void _readSosEvent(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      final decoded = jsonDecode(utf8.decode(bytes).trim());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('SOS notification is not a JSON object.');
      }
      final type = (decoded['event_type'] ?? '').toString();
      if (type.isEmpty || type == 'NONE') return;
      final eventId = (decoded['event_id'] ?? '').toString();
      final callAction = (decoded['call_action'] ?? 'NONE').toString();
      if (_reportedEventKeys.add('$eventId:$type:$callAction')) {
        _events.add(WearableEvent.fromJson(decoded));
      }
    } catch (error) {
      _errors.add(error);
    }
  }

  void _readFileTransfer(List<int> bytes) {
    if (bytes.isEmpty) return;
    if (_isKnownTextMessage(bytes)) {
      _handleTransferMessage(utf8.decode(bytes, allowMalformed: true).trim());
    } else {
      _handleAudioPacket(bytes);
    }
  }

  bool _isKnownTextMessage(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    return text.startsWith('START:') ||
        text.startsWith('COMPLETE:') ||
        text.startsWith('ERROR:') ||
        text.startsWith('FILE:') ||
        text.startsWith('LIST_END:') ||
        text.startsWith('STATUS:') ||
        text.startsWith('MARKED:') ||
        text.startsWith('DELETED:') ||
        text == 'IDLE';
  }

  void _handleTransferMessage(String message) {
    if (message.startsWith('START:')) {
      _handleStart(message);
      return;
    }
    if (message.startsWith('COMPLETE:')) {
      _completeAudioTransfer(message);
      return;
    }
    if (message.startsWith('FILE:')) {
      final fields = message.split(':');
      if (fields.length >= 3) {
        _recordings.add({
          'event_id': fields[1],
          'file_size': int.tryParse(fields[2]),
          'filename': '${fields[1]}.wav',
          'mime_type': 'audio/wav',
          'transfer_status': 'PENDING',
        });
      }
      return;
    }
    if (message.startsWith('STATUS:')) {
      _statuses.add(message.substring('STATUS:'.length));
      return;
    }
    if (message.startsWith('ERROR:')) {
      _errors.add(StateError('ESP32 transfer message: $message'));
      _activeTransfer = null;
      _activeTransferId = null;
      _lastAckQueued = -1;
      unawaited(_startNextAudioTransfer());
      return;
    }
    if (message.startsWith('MARKED:') ||
        message.startsWith('DELETED:') ||
        message.startsWith('LIST_END:')) {
      _statuses.add(message);
    }
  }

  void _handleStart(String message) {
    final fields = message.split(':');
    if (fields.length != 7) {
      _errors.add(const FormatException('Invalid START message.'));
      return;
    }

    final eventId = fields[1];
    final fileSize = int.tryParse(fields[2]);
    final totalChunks = int.tryParse(fields[3]);
    final chunkSize = int.tryParse(fields[4]);
    final startOffset = int.tryParse(fields[5]);
    final expectedCrc = int.tryParse(fields[6], radix: 16);

    if (eventId.isEmpty ||
        fileSize == null ||
        fileSize < 44 ||
        fileSize > maxAudioBytes ||
        totalChunks == null ||
        totalChunks <= 0 ||
        chunkSize == null ||
        chunkSize <= 0 ||
        chunkSize > 238 ||
        startOffset == null ||
        startOffset < 0 ||
        startOffset >= fileSize ||
        expectedCrc == null) {
      _errors.add(const FormatException('Invalid audio START metadata.'));
      unawaited(_sendCommand('ABORT'));
      return;
    }

    // Fresh transfers only. Resume requires persisted partial data and
    // matching byte-offset/sequence handling on both phone and firmware.
    if (startOffset != 0) {
      _errors.add(
        StateError(
          'ESP32 requested resume offset $startOffset; this build requires '
          'a fresh transfer starting at offset zero.',
        ),
      );
      unawaited(_sendCommand('ABORT'));
      _activeTransfer = null;
      _activeTransferId = null;
      return;
    }

    if (_activeTransferId != null &&
        _activeTransferId != eventId &&
        _activeTransfer != null) {
      _errors.add(
        StateError(
          'Received START for $eventId while another transfer is active.',
        ),
      );
      unawaited(_sendCommand('ABORT'));
      return;
    }

    _lastAckQueued = -1;
    _activeTransferId = eventId;
    _activeTransfer = _AudioTransfer(
      eventId: eventId,
      fileSize: fileSize,
      totalChunks: totalChunks,
      chunkSize: chunkSize,
      startOffset: startOffset,
      expectedCrc32: expectedCrc,
    );

    _metadata.add({
      'event_id': eventId,
      'transfer_id': eventId,
      'filename': '$eventId.wav',
      'mime_type': 'audio/wav',
      'format': 'WAV',
      'file_size': fileSize,
      'total_chunks': totalChunks,
      'chunk_size': chunkSize,
      'start_offset': startOffset,
      'crc32': fields[6],
    });
    _statuses.add('AUDIO_TRANSFER_STARTED:$eventId');
  }

  void _queueCumulativeAck(
    int sequence,
    _AudioTransfer transfer, {
    bool repeat = false,
  }) {
    if (sequence < 0 || !_connected) return;
    if (!repeat && sequence <= _lastAckQueued) return;
    if (sequence > _lastAckQueued) _lastAckQueued = sequence;

    _ackWriteQueue = _ackWriteQueue
        .then((_) => _writeAckWithRetry(sequence, transfer))
        .catchError((Object error) {
          _errors.add(StateError('Failed to send audio ACK $sequence: $error'));
        });
  }

  Future<void> _writeAckWithRetry(int sequence, _AudioTransfer transfer) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!_connected || !identical(_activeTransfer, transfer)) return;
      try {
        await _sendCommand('ACK:$sequence');
        return;
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 100 << attempt));
        }
      }
    }

    if (_connected && identical(_activeTransfer, transfer)) {
      throw StateError('ACK:$sequence failed after 3 attempts: $lastError');
    }
  }

  void _handleAudioPacket(List<int> packet) {
    final transfer = _activeTransfer;
    if (transfer == null) {
      _errors.add(
        const FormatException('Binary audio packet received before START.'),
      );
      return;
    }
    if (packet.length < 7) {
      _errors.add(const FormatException('Audio packet is too short.'));
      return;
    }

    final packetBytes = Uint8List.fromList(packet);
    final header = ByteData.sublistView(packetBytes);
    final sequence = header.getUint32(0, Endian.little);
    final payloadLength = header.getUint16(4, Endian.little);

    if (sequence >= transfer.totalChunks ||
        payloadLength <= 0 ||
        packet.length != payloadLength + 6 ||
        payloadLength > transfer.chunkSize) {
      _errors.add(const FormatException('Invalid audio packet header.'));
      return;
    }

    final offset = transfer.startOffset + sequence * transfer.chunkSize;
    if (offset < 0 || offset + payloadLength > transfer.fileSize) {
      _errors.add(const FormatException('Audio packet exceeds file size.'));
      unawaited(_sendCommand('ABORT'));
      return;
    }

    transfer.bytes.setRange(offset, offset + payloadLength, packetBytes, 6);
    final acknowledgement = transfer.ackTracker.recordReceived(sequence);
    if (acknowledgement != null) {
      _queueCumulativeAck(
        acknowledgement,
        transfer,
        repeat: acknowledgement <= _lastAckQueued,
      );
    }
  }

  void _completeAudioTransfer(String message) {
    final transfer = _activeTransfer;
    final fields = message.split(':');
    if (transfer == null || fields.length != 5) {
      _errors.add(const FormatException('Unexpected COMPLETE message.'));
      return;
    }

    final receivedSize = int.tryParse(fields[2]);
    final receivedChunks = int.tryParse(fields[3]);
    final receivedCrc = int.tryParse(fields[4], radix: 16);
    final allChunksPresent =
        transfer.ackTracker.receivedCount == transfer.totalChunks &&
        transfer.ackTracker.highestContiguousSequence ==
            transfer.totalChunks - 1;

    final valid =
        fields[1] == transfer.eventId &&
        receivedSize == transfer.fileSize &&
        receivedChunks == transfer.totalChunks &&
        receivedCrc == transfer.expectedCrc32 &&
        allChunksPresent &&
        crc32(transfer.bytes) == transfer.expectedCrc32;

    if (!valid) {
      _errors.add(
        StateError(
          'Audio integrity verification failed for ${transfer.eventId}. '
          'Expected CRC ${transfer.expectedCrc32.toRadixString(16)}, '
          'received ${receivedCrc?.toRadixString(16)}.',
        ),
      );
      _statuses.add('AUDIO_TRANSFER_FAILED:${transfer.eventId}');
    } else {
      // Persist these bytes before calling acknowledgeAudioTransfer().
      _chunks.add(List<int>.unmodifiable(transfer.bytes));
      _statuses.add('AUDIO_TRANSFER_VERIFIED:${transfer.eventId}');
    }

    _activeTransfer = null;
    _activeTransferId = null;
    _lastAckQueued = -1;
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
    if (!_connected) throw StateError('Wearable is not connected.');
    if (transferId.isEmpty) throw ArgumentError('transferId cannot be empty.');
    if (_activeTransferId == transferId ||
        _pendingTransferIds.contains(transferId)) {
      return;
    }
    _pendingTransferIds.add(transferId);
    await _startNextAudioTransfer();
  }

  Future<void> _startNextAudioTransfer() async {
    if (_startingNextTransfer ||
        _activeTransferId != null ||
        _pendingTransferIds.isEmpty ||
        !_connected) {
      return;
    }

    _startingNextTransfer = true;
    final transferId = _pendingTransferIds.removeAt(0);
    _activeTransferId = transferId;
    try {
      await _sendCommand('GET:$transferId');
    } catch (error) {
      _activeTransferId = null;
      _pendingTransferIds.insert(0, transferId);
      _errors.add(error);
    } finally {
      _startingNextTransfer = false;
    }
  }

  /// Call only after the verified WAV has been durably saved.
  Future<void> acknowledgeAudioTransfer({required String transferId}) async {
    if (transferId.isEmpty) throw ArgumentError('transferId cannot be empty.');
    await _sendCommand('DONE:$transferId');
  }

  /// Destructive operation: removes a recording from the wearable.
  Future<void> deleteWearableRecording({required String transferId}) async {
    if (transferId.isEmpty) throw ArgumentError('transferId cannot be empty.');
    await _sendCommand('DELETE:$transferId');
  }

  Future<void> requestRecordingList() => _sendCommand('LIST');
  Future<void> requestWearableStatus() => _sendCommand('STATUS');

  Future<void> _sendCommand(String command) async {
    final characteristic = _commands;
    if (!_connected || characteristic == null) {
      throw StateError('Wearable command characteristic is unavailable.');
    }
    final bytes = utf8.encode(command);

    if (characteristic.properties.write) {
      await characteristic.write(bytes, withoutResponse: false);
    } else if (characteristic.properties.writeWithoutResponse) {
      await characteristic.write(bytes, withoutResponse: true);
    } else {
      throw StateError('TRANSFER_ACK characteristic does not support writing.');
    }
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

    _commands = null;
    _fileTransfer = null;
    _sosEvent = null;
    _deviceId = null;
    _recordingStatus = null;
    _audioMetadata = null;
    _batteryCharacteristic = null;

    _deviceIdentifier = '';
    _activeTransfer = null;
    _activeTransferId = null;
    _pendingTransferIds.clear();
    _reportedEventKeys.clear();
    _lastAckQueued = -1;
    _ackWriteQueue = Future<void>.value();
    _startingNextTransfer = false;

    if (device != null) {
      try {
        await device.disconnect();
      } catch (error) {
        _errors.add(error);
      }
    }
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // No active scan.
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
    await _errors.close();
    await _statuses.close();
    await _metadata.close();
    await _chunks.close();
    await _connectionStates.close();
    await _battery.close();
    await _recordings.close();
  }

  /// Kept for compatibility with existing callers.
  void parseEvent(Uint8List bytes) => _readSosEvent(bytes);
}
