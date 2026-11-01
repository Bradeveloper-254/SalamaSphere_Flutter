import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

// import 'dart:io';
// import 'package:path_provider/path_provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/wearable_event.dart';

class BleService {
  static const String deviceName = 'SalamaSphere';

  static const String serviceUuid = '7b100001-5a1a-4d3e-9c2f-6b8e0d100001';

  static const String deviceIdUuid = '7b100002-5a1a-4d3e-9c2f-6b8e0d100001';

  static const String sosEventUuid = '7b100003-5a1a-4d3e-9c2f-6b8e0d100001';

  static const String recordingStatusUuid =
      '7b100004-5a1a-4d3e-9c2f-6b8e0d100001';

  static const String audioMetadataUuid =
      '7b100005-5a1a-4d3e-9c2f-6b8e0d100001';

  // Device -> phone: transfer messages and binary packets.
  static const String fileTransferUuid = '7b100006-5a1a-4d3e-9c2f-6b8e0d100001';

  // Phone -> device: GET, RESUME, ACK, LIST and other commands.
  static const String transferCommandUuid =
      '7b100007-5a1a-4d3e-9c2f-6b8e0d100001';

  static const String batteryUuid = '7b100008-5a1a-4d3e-9c2f-6b8e0d100001';

  final StreamController<WearableEvent> _eventController =
      StreamController<WearableEvent>.broadcast();

  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  BluetoothDevice? _device;

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<List<int>>? _sosSubscription;
  StreamSubscription<List<int>>? _recordingStatusSubscription;
  StreamSubscription<List<int>>? _audioMetadataSubscription;
  StreamSubscription<List<int>>? _fileTransferSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  final StreamController<String> _recordingStatusController =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _audioMetadataController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<List<int>> _audioChunkController =
      StreamController<List<int>>.broadcast();

  BluetoothCharacteristic? _transferCommandCharacteristic;
  String? _wearableDeviceIdentifier;
  String _sosPayloadBuffer = '';

  bool _disposed = false;

  Stream<WearableEvent> get events => _eventController.stream;

  Stream<Object> get errors => _errorController.stream;

  /// Recording status values emitted by the firmware, normally UTF-8 text
  /// such as `recording`, `ready`, or `complete`.
  Stream<String> get recordingStatuses => _recordingStatusController.stream;

  /// Metadata emitted before an audio transfer starts.
  Stream<Map<String, dynamic>> get audioMetadata =>
      _audioMetadataController.stream;

  /// Raw audio/file-transfer chunks. The app must use the metadata stream to
  /// determine the codec, length, and transfer ID.
  Stream<List<int>> get audioChunks => _audioChunkController.stream;

  bool get isConnected => _device != null;

  BluetoothDevice? get connectedDevice => _device;

  String? get wearableDeviceIdentifier => _wearableDeviceIdentifier;

  /// Scans for the SalamaSphere wearable, connects, discovers the
  /// expected SOS characteristic, and subscribes to SOS notifications.
  Future<void> connectToWearable() async {
    if (_disposed) {
      throw StateError('BleService has already been disposed.');
    }

    await disconnect();

    final completer = Completer<BluetoothDevice>();

    try {
      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              throw TimeoutException(
                'Bluetooth is not enabled. Turn on Bluetooth and try again.',
              );
            },
          );

      _scanSubscription = FlutterBluePlus.onScanResults.listen(
        (results) {
          for (final result in results) {
            final advertisedName = result.advertisementData.advName;
            final platformName = result.device.platformName;

            developer.log(
              'BLE scan result: advertised="$advertisedName", '
              'platform="$platformName"',
              name: 'SalamaSphere.BLE',
            );

            if (advertisedName == deviceName || platformName == deviceName) {
              if (!completer.isCompleted) {
                completer.complete(result.device);
              }
              break;
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'BLE scan stream failed.',
            name: 'SalamaSphere.BLE',
            error: error,
            stackTrace: stackTrace,
          );

          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      );

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));

      final device = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException(
            'SalamaSphere was not found. '
            'Check that the wearable is powered on and advertising.',
          );
        },
      );

      await _stopScanning();

      developer.log(
        'Connecting to ${device.platformName}, '
        'remote ID: ${device.remoteId}',
        name: 'SalamaSphere.BLE',
      );

      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );

      _device = device;

      _connectionSubscription = device.connectionState.listen(
        (state) {
          developer.log(
            'Wearable connection state: $state',
            name: 'SalamaSphere.BLE',
          );

          if (state == BluetoothConnectionState.disconnected &&
              identical(_device, device)) {
            _sosSubscription?.cancel();
            _sosSubscription = null;

            _device = null;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'Connection-state stream error.',
            name: 'SalamaSphere.BLE',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );

      final services = await device.discoverServices();

      developer.log(
        'Discovered ${services.length} BLE services.',
        name: 'SalamaSphere.BLE',
      );

      BluetoothCharacteristic? foundCharacteristic;
      BluetoothCharacteristic? foundDeviceIdCharacteristic;

      for (final service in services) {
        final discoveredServiceUuid = service.uuid.str.toLowerCase();

        developer.log(
          'Discovered service: $discoveredServiceUuid',
          name: 'SalamaSphere.BLE',
        );

        if (discoveredServiceUuid != serviceUuid) {
          continue;
        }

        for (final characteristic in service.characteristics) {
          final characteristicUuid = characteristic.uuid.str.toLowerCase();

          developer.log(
            'Discovered characteristic: $characteristicUuid',
            name: 'SalamaSphere.BLE',
          );

          if (characteristicUuid == sosEventUuid) {
            foundCharacteristic = characteristic;
          }
          if (characteristicUuid == deviceIdUuid) {
            foundDeviceIdCharacteristic = characteristic;
          }
          if (characteristicUuid == transferCommandUuid) {
            _transferCommandCharacteristic = characteristic;
          }
          if (characteristicUuid == recordingStatusUuid &&
              (characteristic.properties.notify ||
                  characteristic.properties.indicate)) {
            _recordingStatusSubscription = characteristic.onValueReceived
                .listen(_handleRecordingStatus);
            await characteristic.setNotifyValue(true);
          }
          if (characteristicUuid == audioMetadataUuid &&
              (characteristic.properties.notify ||
                  characteristic.properties.indicate)) {
            _audioMetadataSubscription = characteristic.onValueReceived.listen(
              _handleAudioMetadata,
            );
            await characteristic.setNotifyValue(true);
          }
          if (characteristicUuid == fileTransferUuid &&
              (characteristic.properties.notify ||
                  characteristic.properties.indicate)) {
            _fileTransferSubscription = characteristic.onValueReceived.listen(
              (bytes) => _audioChunkController.add(List<int>.from(bytes)),
            );
            await characteristic.setNotifyValue(true);
          }
        }
      }

      if (foundCharacteristic == null) {
        throw StateError(
          'SOS characteristic $sosEventUuid was not found '
          'inside service $serviceUuid. Check the firmware UUIDs.',
        );
      }

      if (foundDeviceIdCharacteristic != null &&
          foundDeviceIdCharacteristic.properties.read) {
        final deviceIdBytes = await foundDeviceIdCharacteristic.read();
        final deviceId = utf8
            .decode(deviceIdBytes, allowMalformed: true)
            .trim();
        if (deviceId.isNotEmpty) {
          _wearableDeviceIdentifier = deviceId;
          developer.log(
            'Registered wearable ID: $deviceId',
            name: 'SalamaSphere.BLE',
          );
        }
      }

      if (!foundCharacteristic.properties.notify &&
          !foundCharacteristic.properties.indicate) {
        throw StateError(
          'The SOS characteristic does not support notifications '
          'or indications.',
        );
      }

      // Subscribe before enabling notifications so early events
      // are less likely to be missed.
      _sosSubscription = foundCharacteristic.onValueReceived.listen(
        (bytes) {
          developer.log(
            'SOS_NOTIFICATION_RECEIVED: $bytes',
            name: 'SalamaSphere.BLE',
            level: 800,
          );

          if (bytes.isEmpty) {
            developer.log(
              'Ignoring empty SOS notification.',
              name: 'SalamaSphere.BLE',
            );
            return;
          }

          _consumeSosBytes(bytes);
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'SOS notification stream error.',
            name: 'SalamaSphere.BLE',
            error: error,
            stackTrace: stackTrace,
          );

          if (!_errorController.isClosed) {
            _errorController.add(error);
          }
        },
      );

      await foundCharacteristic.setNotifyValue(true);

      developer.log(
        'SOS notifications enabled successfully.',
        name: 'SalamaSphere.BLE',
      );
    } catch (error, stackTrace) {
      developer.log(
        'Failed to connect to SalamaSphere.',
        name: 'SalamaSphere.BLE',
        error: error,
        stackTrace: stackTrace,
      );

      await _stopScanning();

      await _sosSubscription?.cancel();
      _sosSubscription = null;

      await _connectionSubscription?.cancel();
      _connectionSubscription = null;

      final connectedDevice = _device;
      _device = null;

      if (connectedDevice != null) {
        try {
          await connectedDevice.disconnect();
        } catch (disconnectError) {
          developer.log(
            'Cleanup disconnect failed.',
            name: 'SalamaSphere.BLE',
            error: disconnectError,
          );
        }
      }

      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _consumeSosBytes(List<int> bytes) {
    try {
      _sosPayloadBuffer += utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      // A UTF-8 code point may be split across notifications. Keep the
      // bytes buffered by decoding the complete accumulated payload next
      // time; malformed complete payloads are reported below.
      _sosPayloadBuffer += utf8.decode(bytes, allowMalformed: true);
    }

    final payload = _sosPayloadBuffer.trim();
    final start = payload.indexOf('{');
    if (start < 0) return;

    var depth = 0;
    var inString = false;
    var escaped = false;
    var end = -1;

    for (var i = start; i < payload.length; i++) {
      final character = payload[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (character == '\\') {
          escaped = true;
        } else if (character == '"') {
          inString = false;
        }
      } else if (character == '"') {
        inString = true;
      } else if (character == '{') {
        depth++;
      } else if (character == '}') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }

    if (end < 0) return;

    final objectText = payload.substring(start, end + 1);
    _sosPayloadBuffer = payload.substring(end + 1);

    try {
      final event = parseEvent(utf8.encode(objectText));
      if (_wearableDeviceIdentifier != null &&
          event.deviceIdentifier != _wearableDeviceIdentifier) {
        throw StateError(
          'SOS event device ID does not match the connected wearable.',
        );
      }
      _eventController.add(event);
      developer.log(
        'SOS event parsed successfully: ${event.eventId}',
        name: 'SalamaSphere.BLE',
      );
    } catch (error, stackTrace) {
      if (!_errorController.isClosed) _errorController.add(error);
      if (!_eventController.isClosed) {
        _eventController.addError(error, stackTrace);
      }
    }

    if (_sosPayloadBuffer.trim().isNotEmpty) {
      _consumeSosBytes(const <int>[]);
    }
  }

  void _handleRecordingStatus(List<int> bytes) {
    final status = utf8.decode(bytes, allowMalformed: true).trim();
    if (status.isNotEmpty && !_recordingStatusController.isClosed) {
      _recordingStatusController.add(status);
    }
  }

  void _handleAudioMetadata(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes).trim());
      if (decoded is Map<String, dynamic> &&
          !_audioMetadataController.isClosed) {
        _audioMetadataController.add(decoded);
      }
    } catch (error) {
      if (!_errorController.isClosed) _errorController.add(error);
    }
  }

  /// Requests the firmware to begin sending audio/file-transfer chunks.
  /// The command is JSON so it remains compatible with the wearable event
  /// protocol and can be extended without changing the characteristic UUID.
  Future<void> requestAudioTransfer({required String transferId}) async {
    await _sendTransferCommand('GET:$transferId');
  }

  Future<void> _sendTransferCommand(String command) async {
    final characteristic = _transferCommandCharacteristic;

    if (characteristic == null) {
      throw StateError('Audio transfer command characteristic is unavailable.');
    }

    await characteristic.write(
      utf8.encode(command),
      withoutResponse:
          characteristic.properties.writeWithoutResponse &&
          !characteristic.properties.write,
    );

    developer.log('Transfer command sent: $command', name: 'SalamaSphere.BLE');
  }

  /// Parses only the JSON payload received from the SOS event
  /// characteristic. File-transfer chunks and other characteristic
  /// payloads must never be passed to this method.
  WearableEvent parseEvent(List<int> bytes) {
    if (bytes.isEmpty) {
      throw const FormatException(
        'The wearable sent an empty SOS notification.',
      );
    }

    final rawText = utf8.decode(bytes, allowMalformed: false).trim();

    developer.log('SOS raw payload: $rawText', name: 'SalamaSphere.BLE');

    developer.log(
      'SOS payload byte count: ${bytes.length}',
      name: 'SalamaSphere.BLE',
    );

    developer.log('SOS payload bytes: $bytes', name: 'SalamaSphere.BLE');

    dynamic decoded;

    try {
      decoded = jsonDecode(rawText);
    } on FormatException catch (error, stackTrace) {
      developer.log(
        'Invalid SOS JSON: $error',
        name: 'SalamaSphere.BLE',
        error: error,
        stackTrace: stackTrace,
      );

      developer.log(
        'Malformed SOS payload was: $rawText',
        name: 'SalamaSphere.BLE',
      );

      rethrow;
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'SOS notification must contain a JSON object.',
      );
    }

    try {
      final event = WearableEvent.fromJson(decoded);

      developer.log(
        'Validated SOS event: ${event.eventId}; '
        'device=${event.deviceIdentifier}; '
        'type=${event.eventType}',
        name: 'SalamaSphere.BLE',
      );

      return event;
    } on FormatException catch (error, stackTrace) {
      developer.log(
        'SOS JSON decoded, but event validation failed.',
        name: 'SalamaSphere.BLE',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Stops scanning and releases the scan subscription.
  Future<void> _stopScanning() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (error) {
      developer.log(
        'Could not stop BLE scan cleanly.',
        name: 'SalamaSphere.BLE',
        error: error,
      );
    }

    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  /// Disconnects from the wearable and cancels active subscriptions.
  Future<void> disconnect() async {
    await _sosSubscription?.cancel();
    _sosSubscription = null;
    await _recordingStatusSubscription?.cancel();
    _recordingStatusSubscription = null;
    await _audioMetadataSubscription?.cancel();
    _audioMetadataSubscription = null;
    await _fileTransferSubscription?.cancel();
    _fileTransferSubscription = null;
    _transferCommandCharacteristic = null;
    _wearableDeviceIdentifier = null;
    _sosPayloadBuffer = '';

    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    final device = _device;
    _device = null;

    if (device != null) {
      await device.disconnect();
    }

    await _stopScanning();
  }

  /// Releases all resources. Do not reuse this service after disposal.
  Future<void> dispose() async {
    if (_disposed) return;

    await disconnect();

    _disposed = true;

    await _eventController.close();
    await _errorController.close();
    await _recordingStatusController.close();
    await _audioMetadataController.close();
    await _audioChunkController.close();
  }
}
