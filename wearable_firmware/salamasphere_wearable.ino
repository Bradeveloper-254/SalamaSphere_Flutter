/*
  SalamaSphere ESP32-S3 wearable firmware

  Arduino IDE requirements:
    - Espressif ESP32 board package
    - Board: the ESP32-S3 board that matches your hardware
    - Partition scheme: a scheme with LittleFS enabled

  This is a single-file sketch. It:
    1. Records a mono 16 kHz WAV file from an I2S microphone when the SOS
       button is pressed.
    2. Saves the recording to LittleFS.
    3. Sends a JSON SOS event over BLE.
    4. Accepts GET:<event_id> from the Flutter app.
    5. Sends the WAV file in BLE notifications.

  IMPORTANT: update the four hardware pin constants below before uploading.
  The repository does not contain the actual microphone/button wiring.
*/

#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <LittleFS.h>
#include <driver/i2s.h>
#include <esp_system.h>

// ---------------------------------------------------------------------------
// Hardware configuration - CHANGE THESE TO MATCH YOUR BOARD
// ---------------------------------------------------------------------------
#define I2S_PORT I2S_NUM_0
#define I2S_BCLK_PIN 4
#define I2S_LRCLK_PIN 5
#define I2S_DATA_PIN 6
#define SOS_BUTTON_PIN 7
#define SOS_BUTTON_ACTIVE_LOW true

// Audio configuration
static constexpr uint32_t SAMPLE_RATE = 16000;
static constexpr uint32_t RECORD_SECONDS = 10;
static constexpr uint16_t CHANNELS = 1;
static constexpr uint16_t BITS_PER_SAMPLE = 16;
static constexpr char AUDIO_PATH[] = "/sos_latest.wav";
static constexpr char AUDIO_FILE_NAME[] = "sos_latest.wav";
static constexpr char AUDIO_MIME_TYPE[] = "audio/wav";

// 20 bytes works even when Android has not negotiated a larger BLE MTU.
static constexpr size_t AUDIO_CHUNK_SIZE = 20;

// ---------------------------------------------------------------------------
// Protocol shared with Flutter lib/services/ble_service.dart
// ---------------------------------------------------------------------------
static constexpr char DEVICE_NAME[] = "SalamaSphere";
static constexpr char DEVICE_ID[] = "SALAMA-DEVICE-001";

static constexpr char SERVICE_UUID[] =
    "7b6a0001-7d42-4a8e-9b31-2f4c8a6e1000";
static constexpr char DEVICE_ID_UUID[] =
    "7b6a0002-7d42-4a8e-9b31-2f4c8a6e1000";
static constexpr char SOS_EVENT_UUID[] =
    "7b6a0003-7d42-4a8e-9b31-2f4c8a6e1000";
static constexpr char RECORDING_STATUS_UUID[] =
    "7b6a0004-7d42-4a8e-9b31-2f4c8a6e1000";
static constexpr char AUDIO_METADATA_UUID[] =
    "7b6a0005-7d42-4a8e-9b31-2f4c8a6e1000";
static constexpr char AUDIO_CONTROL_UUID[] =
    "7b6a0006-7d42-4a8e-9b31-2f4c8a6e1000";
static constexpr char AUDIO_DATA_UUID[] =
    "7b6a0007-7d42-4a8e-9b31-2f4c8a6e1000";
static constexpr char TRANSFER_ACK_UUID[] =
    "7b6a0008-7d42-4a8e-9b31-2f4c8a6e1000";

BLEServer* bleServer = nullptr;
BLECharacteristic* deviceIdCharacteristic = nullptr;
BLECharacteristic* sosEventCharacteristic = nullptr;
BLECharacteristic* recordingStatusCharacteristic = nullptr;
BLECharacteristic* audioMetadataCharacteristic = nullptr;
BLECharacteristic* audioControlCharacteristic = nullptr;
BLECharacteristic* audioDataCharacteristic = nullptr;
BLECharacteristic* transferAckCharacteristic = nullptr;

bool deviceConnected = false;
bool wasConnected = false;
bool transferActive = false;
bool recordingInProgress = false;
File transferFile;
String activeEventId;
uint32_t transferBytesSent = 0;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
void writeLittleEndian16(File& file, uint16_t value) {
  uint8_t bytes[2] = {
      static_cast<uint8_t>(value & 0xff),
      static_cast<uint8_t>((value >> 8) & 0xff),
  };
  file.write(bytes, sizeof(bytes));
}

void writeLittleEndian32(File& file, uint32_t value) {
  uint8_t bytes[4] = {
      static_cast<uint8_t>(value & 0xff),
      static_cast<uint8_t>((value >> 8) & 0xff),
      static_cast<uint8_t>((value >> 16) & 0xff),
      static_cast<uint8_t>((value >> 24) & 0xff),
  };
  file.write(bytes, sizeof(bytes));
}

void writeWavHeader(File& file, uint32_t audioBytes) {
  file.seek(0);
  file.write(reinterpret_cast<const uint8_t*>("RIFF"), 4);
  writeLittleEndian32(file, 36 + audioBytes);
  file.write(reinterpret_cast<const uint8_t*>("WAVE"), 4);
  file.write(reinterpret_cast<const uint8_t*>("fmt "), 4);
  writeLittleEndian32(file, 16);  // PCM header size
  writeLittleEndian16(file, 1);   // PCM format
  writeLittleEndian16(file, CHANNELS);
  writeLittleEndian32(file, SAMPLE_RATE);
  writeLittleEndian32(
      file, SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE / 8);
  writeLittleEndian16(file, CHANNELS * BITS_PER_SAMPLE / 8);
  writeLittleEndian16(file, BITS_PER_SAMPLE);
  file.write(reinterpret_cast<const uint8_t*>("data"), 4);
  writeLittleEndian32(file, audioBytes);
}

String makeEventId() {
  char result[48];
  const uint32_t randomValue = esp_random();
  snprintf(
      result,
      sizeof(result),
      "%08lx-%04lx-%04lx-%04lx-%012lx",
      static_cast<unsigned long>(millis()),
      static_cast<unsigned long>(randomValue & 0xffff),
      static_cast<unsigned long>((randomValue >> 16) & 0xffff),
      static_cast<unsigned long>(ESP.getChipRevision() & 0xffff),
      static_cast<unsigned long>(ESP.getEfuseMac() & 0xffffffff));
  return String(result);
}

void notifyStatus(const char* status) {
  recordingStatusCharacteristic->setValue(status);
  if (deviceConnected) recordingStatusCharacteristic->notify();
  Serial.printf("Recording status: %s\n", status);
}

void notifyAck(const char* status) {
  String payload = "{\"status\":\"";
  payload += status;
  payload += "\",\"transfer_id\":\"";
  payload += activeEventId;
  payload += "\",\"bytes\":";
  payload += String(transferBytesSent);
  payload += "}";
  transferAckCharacteristic->setValue(payload.c_str());
  if (deviceConnected) transferAckCharacteristic->notify();
}

void notifyMetadata() {
  File file = LittleFS.open(AUDIO_PATH, "r");
  const size_t fileSize = file ? file.size() : 0;
  if (file) file.close();

  String payload = "{\"available\":";
  payload += fileSize > 44 ? "true" : "false";
  payload += ",\"transfer_id\":\"";
  payload += activeEventId;
  payload += "\",\"file_name\":\"";
  payload += AUDIO_FILE_NAME;
  payload += "\",\"mime_type\":\"";
  payload += AUDIO_MIME_TYPE;
  payload += "\",\"size\":";
  payload += String(fileSize);
  payload += "}";

  audioMetadataCharacteristic->setValue(payload.c_str());
  if (deviceConnected) audioMetadataCharacteristic->notify();
  Serial.printf("Audio metadata: %s\n", payload.c_str());
}

void stopTransfer(const char* status) {
  if (transferFile) transferFile.close();
  transferActive = false;
  notifyStatus(status);
  notifyAck(status);
}

// ---------------------------------------------------------------------------
// I2S recording
// ---------------------------------------------------------------------------
bool setupMicrophone() {
  i2s_config_t config = {};
  config.mode = static_cast<i2s_mode_t>(I2S_MODE_MASTER | I2S_MODE_RX);
  config.sample_rate = SAMPLE_RATE;
  config.bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT;
  config.channel_format = I2S_CHANNEL_FMT_ONLY_LEFT;
  config.communication_format = I2S_COMM_FORMAT_I2S;
  config.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
  config.dma_buf_count = 8;
  config.dma_buf_len = 256;
  config.use_apll = false;
  config.tx_desc_auto_clear = false;
  config.fixed_mclk = 0;

  i2s_pin_config_t pins = {};
  pins.bck_io_num = I2S_BCLK_PIN;
  pins.ws_io_num = I2S_LRCLK_PIN;
  pins.data_out_num = I2S_PIN_NO_CHANGE;
  pins.data_in_num = I2S_DATA_PIN;

  if (i2s_driver_install(I2S_PORT, &config, 0, nullptr) != ESP_OK) {
    Serial.println("I2S driver installation failed");
    return false;
  }
  if (i2s_set_pin(I2S_PORT, &pins) != ESP_OK) {
    Serial.println("I2S pin configuration failed");
    return false;
  }
  return true;
}

bool recordWav() {
  File file = LittleFS.open(AUDIO_PATH, "w");
  if (!file) {
    Serial.println("Could not create audio file");
    return false;
  }

  uint8_t emptyHeader[44] = {};
  file.write(emptyHeader, sizeof(emptyHeader));

  const uint32_t targetSamples = SAMPLE_RATE * RECORD_SECONDS;
  uint32_t samplesWritten = 0;
  int32_t inputSamples[256];

  while (samplesWritten < targetSamples) {
    size_t bytesRead = 0;
    const esp_err_t result = i2s_read(
        I2S_PORT,
        inputSamples,
        sizeof(inputSamples),
        &bytesRead,
        pdMS_TO_TICKS(100));
    if (result != ESP_OK) {
      file.close();
      LittleFS.remove(AUDIO_PATH);
      Serial.println("I2S read failed");
      return false;
    }

    const size_t availableSamples = bytesRead / sizeof(int32_t);
    const size_t remainingSamples = targetSamples - samplesWritten;
    const size_t count = min(availableSamples, remainingSamples);

    for (size_t index = 0; index < count; ++index) {
      // Most I2S MEMS microphones provide a 24/32-bit sample. Reduce it to
      // signed 16-bit PCM for a broadly playable WAV file.
      const int16_t pcm = static_cast<int16_t>(inputSamples[index] >> 14);
      file.write(reinterpret_cast<const uint8_t*>(&pcm), sizeof(pcm));
    }
    samplesWritten += count;
  }

  writeWavHeader(file, samplesWritten * sizeof(int16_t));
  file.close();
  return true;
}

// ---------------------------------------------------------------------------
// Incident generation
// ---------------------------------------------------------------------------
void emitSosEvent() {
  String payload = "{\"event_id\":\"";
  payload += activeEventId;
  payload += "\",\"device_identifier\":\"";
  payload += DEVICE_ID;
  payload += "\",\"event_type\":\"SOS\",\"timestamp\":null,";
  payload += "\"protocol_version\":1,\"recording_status\":\"ready\"}";

  sosEventCharacteristic->setValue(payload.c_str());
  if (deviceConnected) sosEventCharacteristic->notify();
  Serial.printf("SOS event: %s\n", payload.c_str());
}

void createSosRecording() {
  if (recordingInProgress || transferActive) return;
  recordingInProgress = true;
  activeEventId = makeEventId();
  transferBytesSent = 0;

  notifyStatus("recording");
  LittleFS.remove(AUDIO_PATH);

  const bool recorded = recordWav();
  if (!recorded) {
    notifyStatus("error");
    recordingInProgress = false;
    return;
  }

  // The app receives the event first, then sends GET:<event_id>. Metadata is
  // also published when GET is received, preventing a race with the app's
  // event initialization.
  emitSosEvent();
  notifyStatus("ready");
  notifyMetadata();
  recordingInProgress = false;
}

// ---------------------------------------------------------------------------
// BLE callbacks and setup
// ---------------------------------------------------------------------------
class ServerCallbacks final : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    deviceConnected = true;
    Serial.println("Flutter app connected");
  }

  void onDisconnect(BLEServer*) override {
    deviceConnected = false;
    if (transferActive) stopTransfer("disconnected");
    Serial.println("Flutter app disconnected");
  }
};

class AudioControlCallbacks final : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const String command = characteristic->getValue().c_str();
    Serial.printf("BLE command: %s\n", command.c_str());

    if (command == "GET_METADATA") {
      notifyMetadata();
      return;
    }

    if (command == "STOP_TRANSFER") {
      stopTransfer("stopped");
      return;
    }

    if (!command.startsWith("GET:")) return;

    const String requestedId = command.substring(4);
    if (requestedId != activeEventId || !LittleFS.exists(AUDIO_PATH)) {
      notifyStatus("error");
      notifyAck("invalid_transfer");
      return;
    }

    if (transferFile) transferFile.close();
    transferFile = LittleFS.open(AUDIO_PATH, "r");
    if (!transferFile) {
      notifyStatus("error");
      notifyAck("open_failed");
      return;
    }

    transferBytesSent = 0;
    transferActive = true;
    notifyMetadata();
    notifyStatus("transferring");
  }
};

void setupBle() {
  BLEDevice::init(DEVICE_NAME);
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);

  deviceIdCharacteristic = service->createCharacteristic(
      DEVICE_ID_UUID, BLECharacteristic::PROPERTY_READ);
  deviceIdCharacteristic->setValue(DEVICE_ID);

  sosEventCharacteristic = service->createCharacteristic(
      SOS_EVENT_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  sosEventCharacteristic->addDescriptor(new BLE2902());

  recordingStatusCharacteristic = service->createCharacteristic(
      RECORDING_STATUS_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  recordingStatusCharacteristic->addDescriptor(new BLE2902());

  audioMetadataCharacteristic = service->createCharacteristic(
      AUDIO_METADATA_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  audioMetadataCharacteristic->addDescriptor(new BLE2902());

  audioControlCharacteristic = service->createCharacteristic(
      AUDIO_CONTROL_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  audioControlCharacteristic->setCallbacks(new AudioControlCallbacks());

  audioDataCharacteristic = service->createCharacteristic(
      AUDIO_DATA_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  audioDataCharacteristic->addDescriptor(new BLE2902());

  transferAckCharacteristic = service->createCharacteristic(
      TRANSFER_ACK_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  transferAckCharacteristic->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();
  Serial.println("SalamaSphere BLE advertising started");
}

void setup() {
  Serial.begin(115200);
  delay(500);

  pinMode(
      SOS_BUTTON_PIN,
      SOS_BUTTON_ACTIVE_LOW ? INPUT_PULLUP : INPUT);

  if (!LittleFS.begin(true)) {
    Serial.println("LittleFS mount failed");
    while (true) delay(1000);
  }

  if (!setupMicrophone()) {
    while (true) delay(1000);
  }

  setupBle();
  Serial.println("SalamaSphere wearable ready");
}

void loop() {
  static bool previousButtonState = false;
  const bool buttonPressed = digitalRead(SOS_BUTTON_PIN) ==
      (SOS_BUTTON_ACTIVE_LOW ? LOW : HIGH);

  if (buttonPressed && !previousButtonState) {
    createSosRecording();
  }
  previousButtonState = buttonPressed;

  if (transferActive && transferFile && deviceConnected) {
    uint8_t chunk[AUDIO_CHUNK_SIZE];
    const size_t bytesRead = transferFile.read(chunk, sizeof(chunk));

    if (bytesRead == 0) {
      stopTransfer("complete");
    } else {
      audioDataCharacteristic->setValue(chunk, bytesRead);
      audioDataCharacteristic->notify();
      transferBytesSent += bytesRead;
      delay(8);
    }
  }

  if (!deviceConnected && wasConnected) {
    delay(300);
    bleServer->startAdvertising();
    wasConnected = false;
  }
  if (deviceConnected && !wasConnected) {
    wasConnected = true;
  }
}
