#include <Arduino.h>
#include <SPI.h>
#include <SD.h>
#include <driver/i2s.h>
#include <esp_system.h>
#include <NimBLEDevice.h>

// ============================================================
// SALAMASPHERE - DAY 10 (v1.4.0)
// TWO-MODE SOS + AUTO BLE TRANSFER + PHONE-CALL REQUEST
// Board: ESP32-S3 N16R8      Library: NimBLE-Arduino 2.5.1
// ============================================================
//
// BUTTON BEHAVIOUR (idle)
//   press  < 1 s            -> rejected, nothing happens
//   press  1 s .. 3 s       -> STANDARD SOS: event + recording
//   press  3 s .. 5 s       -> ignored (dead zone, red LED blinks once)
//   hold   >= 5 s           -> CALL SOS: event + recording + call request
//                              (fires the moment 5 s is reached)
// BUTTON BEHAVIOUR (while recording)
//   any press >= 1 s        -> stop recording (and end the call request)
//   press < 1 s             -> ignored
//
// WHAT THE BOARD DOES AFTER STOPPING
//   1. Saves /<event_id>.wav on the microSD card.
//   2. Pushes it to the app over BLE automatically (START/chunks/COMPLETE).
//   3. The app verifies the CRC, stores it under the incident, then sends
//      DONE:<event_id>. The board renames the file to .sent
//      ("successfully transferred"). Until DONE arrives the file stays
//      pending and is re-offered on every reconnect.
//   4. Sending the audio to trusted contacts is done BY THE APP (the
//      phone has the internet / SIM; the ESP32 has neither a SIM nor
//      any contact list).
//
// PHONE CALLS
//   The ESP32 cannot place calls. In CALL mode it notifies SOS_EVENT with
//   "call_action":"START" and the app (which owns the trusted contacts)
//   dials them. On stop it notifies "call_action":"END".
//
// SOS_EVENT NOTIFICATIONS (JSON)
//   start: {"event_id":..,"device_identifier":..,"event_type":"SOS",
//           "sos_mode":"STANDARD"|"CALL","call_action":"NONE"|"START",
//           "recording_status":"recording"}
//   stop : {... "event_type":"SOS_END", "call_action":"NONE"|"END",
//           "recording_status":"stopping"}
//   The app must de-duplicate by event_id (the start message is
//   re-sent once if the phone subscribes while recording is running).
//
// COMMANDS (phone -> TRANSFER_ACK_UUID)
//   GET:<id>  RESUME:<id>:<offset>  ACK:<seq>  ABORT  STATUS  LIST
//   DONE:<id>    transfer verified + stored in app -> mark as sent
//   DELETE:<id>  delete a file (pending or sent)
//
// NOTIFICATIONS (device -> phone, FILE_TRANSFER_UUID)
//   START:<id>:<size>:<chunks>:<chunkSize>:<startOffset>:<crc32hex>
//   <binary chunk> = 4-byte seq LE + 2-byte len LE + payload
//   COMPLETE:<id>:<size>:<chunks>:<crc32hex>
//   ERROR:<reason>[:<detail>[:<resumeOffset>]]
//   FILE:<id>:<size> ... LIST_END:<count>   STATUS:<state>
//   MARKED:<id>   DELETED:<id>
//
// PHONE REQUIREMENTS
//   1. Request MTU 247 right after connecting.
//   2. Enable notifications on SOS_EVENT and FILE_TRANSFER.
//   3. ACK in order; drop duplicates / out-of-order chunks.
//   4. Accept an unsolicited START (auto push) as well as a START
//      that follows your own GET.
// ============================================================

// ---------------- HARDWARE PINS -----------------------------

#define SOS_BUTTON_PIN 4

#define GREEN_LED_PIN 5
#define RED_LED_PIN   6

#define I2S_BCLK 15
#define I2S_WS   16
#define I2S_DIN  17

#define SD_CS    10
#define SD_MOSI  11
#define SD_SCLK  12
#define SD_MISO  13

// ---------------- DEVICE CONFIGURATION ----------------------

#define DEVICE_NAME      "SalamaSphere"
#define DEVICE_ID        "SALAMA-DEVICE-001"
#define FIRMWARE_VERSION "1.4.0"

// ---------------- AUDIO CONFIGURATION -----------------------

#define SAMPLE_RATE               16000
#define MAX_RECORD_SECONDS        120     // safety cap if nobody stops it
#define BITS_PER_SAMPLE           16
#define AUDIO_CHANNELS            1
#define AUDIO_SAMPLES_PER_BUFFER  256
#define WRITE_BUFFER_BYTES        4096    // SD is written in 4 KB blocks

// ---------------- BUTTON CONFIGURATION ----------------------

const unsigned long DEBOUNCE_MS      = 40;
const unsigned long SHORT_PRESS_MS   = 1000;   // below this: rejected
const unsigned long STANDARD_MAX_MS  = 3000;   // 1..3 s: standard SOS
const unsigned long CALL_HOLD_MS     = 5000;   // >= 5 s: call SOS

// ---------------- TRANSFER CONFIGURATION --------------------

#define PACKET_HEADER_SIZE    6
#define MAX_CHUNK_PAYLOAD     238   // MTU 247 - 3 - 6
#define PREFERRED_MTU         247
#define MIN_MTU_FOR_TRANSFER  100

#define WINDOW_SIZE           6

const unsigned long ACK_TIMEOUT_MS = 2000;
const int MAX_STALLS = 5;

#define MAX_LIST_ENTRIES      50
#define MAX_SENT_KEEP         20    // keep this many .sent files, delete older
#define MAX_PUSHED_IDS        8
#define MAX_AUTO_PUSH_ATTEMPTS 6

// ---------------- TYPES -------------------------------------

enum ChunkResult {
  CHUNK_SENT,
  CHUNK_BUSY,
  CHUNK_FATAL
};

enum ButtonAction {
  BTN_NONE,
  BTN_RELEASED,       // button released, pressMs valid
  BTN_HOLD_REACHED    // button still down and 5 s reached
};

enum SosMode {
  MODE_NONE,
  MODE_STANDARD,
  MODE_CALL
};

enum RecordResult {
  REC_OK,
  REC_NOT_STARTED,    // hardware/file problem before recording began
  REC_FAILED          // recording ran but produced nothing usable
};

// ---------------- COMMAND QUEUE -----------------------------

#define CMD_QUEUE_SIZE 4
#define CMD_MAX_LEN    96

// ---------------- BLE UUIDS ----------------------------------

#define SERVICE_UUID          "7b100001-5a1a-4d3e-9c2f-6b8e0d100001"
#define DEVICE_ID_UUID        "7b100002-5a1a-4d3e-9c2f-6b8e0d100001"
#define SOS_EVENT_UUID        "7b100003-5a1a-4d3e-9c2f-6b8e0d100001"
#define RECORDING_STATUS_UUID "7b100004-5a1a-4d3e-9c2f-6b8e0d100001"
#define AUDIO_METADATA_UUID   "7b100005-5a1a-4d3e-9c2f-6b8e0d100001"
#define FILE_TRANSFER_UUID    "7b100006-5a1a-4d3e-9c2f-6b8e0d100001"
#define TRANSFER_ACK_UUID     "7b100007-5a1a-4d3e-9c2f-6b8e0d100001"
#define BATTERY_UUID          "7b100008-5a1a-4d3e-9c2f-6b8e0d100001"

// ---------------- BATTERY CONFIGURATION ---------------------
// BATTERY_ADC_PIN: GPIO on a 2:1 divider from the battery (+).
// -1 = no divider fitted (app receives battery_percent = -1).
#define BATTERY_ADC_PIN     -1
#define BATTERY_DIVIDER     2.0f
#define BATTERY_EMPTY_MV    3300
#define BATTERY_FULL_MV     4200
#define BATTERY_UPDATE_MS   60000UL

// ============================================================
// HARDWARE OBJECTS
// ============================================================

SPIClass sdSPI(FSPI);

int32_t i2sSamples[AUDIO_SAMPLES_PER_BUFFER];

// ============================================================
// BLE OBJECTS
// ============================================================

NimBLEServer* bleServer = nullptr;
NimBLEService* salamaService = nullptr;

NimBLECharacteristic* deviceIdCharacteristic = nullptr;
NimBLECharacteristic* sosEventCharacteristic = nullptr;
NimBLECharacteristic* recordingStatusCharacteristic = nullptr;
NimBLECharacteristic* audioMetadataCharacteristic = nullptr;
NimBLECharacteristic* fileTransferCharacteristic = nullptr;
NimBLECharacteristic* transferAckCharacteristic = nullptr;
NimBLECharacteristic* batteryCharacteristic = nullptr;

// ============================================================
// STATE VARIABLES
// ============================================================

volatile bool deviceConnected = false;
volatile bool transferSubscribed = false;
volatile uint16_t currentMtu = 23;
volatile bool syncRequested = false;

bool microphoneReady = false;
bool sdReady = false;
bool sdInitAttempted = false;
bool micDriverInstalled = false;

// Button state
int lastRawButtonState = HIGH;
int stableButtonState = HIGH;
unsigned long lastDebounceTime = 0;
unsigned long pressStartTime = 0;
bool holdFired = false;
bool gestureFeedback = false;

// An SOS gesture detected while a file transfer was running.
SosMode pendingSosMode = MODE_NONE;
unsigned long pendingSosHold = 0;

uint32_t eventCounter = 0;

String currentEventId = "";
String currentFilename = "";
String recordingStatus = "INITIALIZING";

// Active SOS session
bool activeCallMode = false;
bool sosStartDelivered = false;
bool sosEndPublished = false;

// Auto push of saved recordings
bool autoPushPending = false;
unsigned long autoPushNotBefore = 0;
int autoPushAttempts = 0;

String pushedIds[MAX_PUSHED_IDS];
int pushedCount = 0;
int pushedNext = 0;

// Transfer state shared with the BLE callback task
volatile bool transferActive = false;
volatile bool abortRequested = false;
volatile int32_t highestAck = -1;
volatile uint32_t transferSentLimit = 0;

// Command queue (written by BLE task, read by loop())
char cmdQueue[CMD_QUEUE_SIZE][CMD_MAX_LEN];
volatile uint8_t cmdHead = 0;
volatile uint8_t cmdTail = 0;
portMUX_TYPE cmdMux = portMUX_INITIALIZER_UNLOCKED;

// CRC table
uint32_t crcTable[256];
bool crcTableReady = false;

// ============================================================
// FUNCTION DECLARATIONS
// ============================================================

String generateEventId();
bool isValidEventId(const String& id);

void updateRecordingStatus(const char* status);
bool publishTransferMessage(const String& message);
void publishAudioMetadata(const String& eventId, const String& filename,
                          uint32_t fileSize, const char* status);
bool publishSosEvent(const char* type, const String& eventId, bool callMode,
                     const char* callAction, const char* recState);

bool initializeMicrophone();
bool initializeSD();
bool ensureHardwareReady();
void updateReadyLeds();

void writeWavHeader(File& file, uint32_t sampleRate, uint16_t bitsPerSample,
                    uint16_t channels, uint32_t dataSize);

RecordResult recordAudio(const String& eventId);
void generateSosEvent(SosMode mode, unsigned long holdDuration);

uint32_t computeFileCrc32(File& file);
bool transferAudioFile(const String& eventId, uint32_t startOffset);
void listRecordings();
void deleteRecording(const String& eventId);
void markRecordingSent(const String& eventId);
void trimSentFiles(int keep);
String findPendingRecording();

ButtonAction pollButton(unsigned long& pressMs);
SosMode interpretIdleGesture(ButtonAction action, unsigned long pressMs);
void processPendingCommand();
void maintainBle();
void updateBattery(bool force);

// ============================================================
// COMMAND QUEUE HELPERS
// ============================================================

bool enqueueCommand(const char* text) {

  bool ok = false;

  portENTER_CRITICAL(&cmdMux);

  uint8_t next = (cmdHead + 1) % CMD_QUEUE_SIZE;

  if (next != cmdTail) {
    strlcpy(cmdQueue[cmdHead], text, CMD_MAX_LEN);
    cmdHead = next;
    ok = true;
  }

  portEXIT_CRITICAL(&cmdMux);

  return ok;
}

bool dequeueCommand(char* out) {

  bool ok = false;

  portENTER_CRITICAL(&cmdMux);

  if (cmdTail != cmdHead) {
    strlcpy(out, cmdQueue[cmdTail], CMD_MAX_LEN);
    cmdTail = (cmdTail + 1) % CMD_QUEUE_SIZE;
    ok = true;
  }

  portEXIT_CRITICAL(&cmdMux);

  return ok;
}

void clearCommandQueue() {

  portENTER_CRITICAL(&cmdMux);
  cmdTail = cmdHead;
  portEXIT_CRITICAL(&cmdMux);
}

// ============================================================
// PUSHED-ID LIST (files already sent this connection)
// ============================================================

bool wasPushed(const String& id) {

  for (int i = 0; i < pushedCount; i++) {
    if (pushedIds[i] == id) {
      return true;
    }
  }

  return false;
}

void rememberPushed(const String& id) {

  if (wasPushed(id)) {
    return;
  }

  if (pushedCount < MAX_PUSHED_IDS) {

    pushedIds[pushedCount++] = id;

  } else {

    pushedIds[pushedNext] = id;
    pushedNext = (pushedNext + 1) % MAX_PUSHED_IDS;
  }
}

void clearPushed() {

  for (int i = 0; i < MAX_PUSHED_IDS; i++) {
    pushedIds[i] = "";
  }

  pushedCount = 0;
  pushedNext = 0;
}

// ============================================================
// BLE SERVER CALLBACKS
// ============================================================

class SalamaServerCallbacks : public NimBLEServerCallbacks {

  void onConnect(NimBLEServer* server, NimBLEConnInfo& connInfo) override {

    deviceConnected = true;
    transferSubscribed = false;
    currentMtu = 23;
    syncRequested = false;
    abortRequested = false;
    highestAck = -1;

    clearCommandQueue();

    // 15-30 ms interval, no latency, 4 s supervision timeout.
    server->updateConnParams(connInfo.getConnHandle(), 12, 24, 0, 400);

    Serial.println();
    Serial.println("BLE CLIENT CONNECTED");
  }

  void onMTUChange(uint16_t MTU, NimBLEConnInfo& connInfo) override {

    currentMtu = MTU;

    Serial.printf("MTU negotiated: %u\n", (unsigned int)MTU);
  }

  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& connInfo, int reason) override {

    deviceConnected = false;
    transferSubscribed = false;
    currentMtu = 23;

    // Recording continues; a running transfer stops by itself.
    clearCommandQueue();

    Serial.println();
    Serial.printf("BLE CLIENT DISCONNECTED (reason %d)\n", reason);

    NimBLEDevice::startAdvertising();
  }
};

// ============================================================
// FILE TRANSFER CHARACTERISTIC CALLBACKS (subscription tracking)
// ============================================================

class TransferStreamCallbacks : public NimBLECharacteristicCallbacks {

  void onSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& connInfo,
                   uint16_t subValue) override {

    transferSubscribed = (subValue & 0x01) != 0;
    syncRequested = transferSubscribed;

    Serial.printf("FILE_TRANSFER notifications %s\n",
                  transferSubscribed ? "ENABLED" : "DISABLED");
  }
};

// ============================================================
// COMMAND AND ACK CALLBACK
// ============================================================

class TransferCommandCallbacks : public NimBLECharacteristicCallbacks {

  void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& connInfo) override {

    std::string value = characteristic->getValue();

    if (value.empty()) {
      return;
    }

    char text[CMD_MAX_LEN];

    size_t n = value.size();

    if (n > sizeof(text) - 1) {
      n = sizeof(text) - 1;
    }

    memcpy(text, value.data(), n);
    text[n] = '\0';

    String command = String(text);
    command.trim();

    // Cumulative acknowledgement (hot path: no logging)
    if (command.startsWith("ACK:")) {

      String sequenceText = command.substring(4);

      if (sequenceText.length() == 0 || sequenceText.length() > 9) {
        return;
      }

      for (size_t i = 0; i < sequenceText.length(); i++) {
        if (!isDigit(sequenceText.charAt(i))) {
          return;
        }
      }

      uint32_t sequence = (uint32_t)strtoul(sequenceText.c_str(), nullptr, 10);

      if (
        transferActive &&
        sequence < transferSentLimit &&
        (int32_t)sequence > highestAck
      ) {
        highestAck = (int32_t)sequence;
      }

      return;
    }

    if (command == "ABORT") {

      if (transferActive) {
        abortRequested = true;
      }

      return;
    }

    Serial.print("BLE command received: ");
    Serial.println(command);

    if (!enqueueCommand(command.c_str())) {
      Serial.println("Command queue full; command dropped.");
    }
  }
};

// ============================================================
// EVENT ID GENERATION / VALIDATION
// ============================================================

String generateEventId() {

  eventCounter++;

  uint32_t randomPart = esp_random();

  char id[48];

  snprintf(
    id,
    sizeof(id),
    "SALAMA-%08lX-%08lX-%04lX",
    (unsigned long)(ESP.getEfuseMac() & 0xFFFFFFFF),
    (unsigned long)randomPart,
    (unsigned long)(eventCounter & 0xFFFF)
  );

  return String(id);
}

bool isValidEventId(const String& id) {

  if (id.length() == 0 || id.length() > 40) {
    return false;
  }

  if (!id.startsWith("SALAMA-")) {
    return false;
  }

  for (size_t i = 0; i < id.length(); i++) {

    char c = id.charAt(i);

    bool valid =
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-';

    if (!valid) {
      return false;
    }
  }

  return true;
}

// ============================================================
// RECORDING STATUS
// ============================================================

void updateRecordingStatus(const char* status) {

  recordingStatus = status;

  if (recordingStatusCharacteristic != nullptr) {

    recordingStatusCharacteristic->setValue(status);

    if (deviceConnected) {
      recordingStatusCharacteristic->notify();
    }
  }

  Serial.print("Recording status: ");
  Serial.println(status);
}

// ============================================================
// SOS EVENT NOTIFICATION (start / end, with call request)
// Returns true if the phone was connected, subscribed and the
// notification was accepted by the BLE stack.
// ============================================================

bool publishSosEvent(const char* type, const String& eventId, bool callMode,
                     const char* callAction, const char* recState) {

  if (sosEventCharacteristic == nullptr) {
    return false;
  }

  String json =
    String("{\"event_id\":\"") + eventId +
    "\",\"device_identifier\":\"" + DEVICE_ID +
    "\",\"event_type\":\"" + type +
    "\",\"sos_mode\":\"" + (callMode ? "CALL" : "STANDARD") +
    "\",\"call_action\":\"" + callAction +
    "\",\"recording_status\":\"" + recState + "\"}";

  Serial.println(json);

  // Stored even when nobody is connected: the app can READ it later.
  sosEventCharacteristic->setValue(json.c_str());

  if (!deviceConnected) {
    return false;
  }

  for (int attempt = 0; attempt < 5; attempt++) {

    if (sosEventCharacteristic->notify()) {
      return transferSubscribed;
    }

    if (!deviceConnected) {
      return false;
    }

    delay(20);
  }

  return false;
}

// ============================================================
// TRANSFER STATUS MESSAGE (with retry if the BLE stack is busy)
// ============================================================

bool publishTransferMessage(const String& message) {

  Serial.print("Transfer message: ");
  Serial.println(message);

  if (fileTransferCharacteristic == nullptr) {
    return false;
  }

  fileTransferCharacteristic->setValue(message.c_str());

  if (!deviceConnected) {
    return false;
  }

  if ((int)message.length() > (int)currentMtu - 3) {
    Serial.println("WARNING: message longer than MTU-3; the phone must request a larger MTU.");
  }

  for (int attempt = 0; attempt < 10; attempt++) {

    if (fileTransferCharacteristic->notify()) {
      return true;
    }

    if (!deviceConnected) {
      return false;
    }

    delay(10);
  }

  return false;
}

// ============================================================
// WAV HEADER
// ============================================================

void writeWavHeader(File& file, uint32_t sampleRate, uint16_t bitsPerSample,
                    uint16_t channels, uint32_t dataSize) {

  uint32_t byteRate = sampleRate * channels * bitsPerSample / 8;
  uint16_t blockAlign = channels * bitsPerSample / 8;

  uint32_t chunkSize = 36 + dataSize;
  uint32_t subchunk1Size = 16;

  uint16_t audioFormat = 1;

  file.write((const uint8_t*)"RIFF", 4);
  file.write((uint8_t*)&chunkSize, 4);

  file.write((const uint8_t*)"WAVE", 4);
  file.write((const uint8_t*)"fmt ", 4);

  file.write((uint8_t*)&subchunk1Size, 4);
  file.write((uint8_t*)&audioFormat, 2);
  file.write((uint8_t*)&channels, 2);

  file.write((uint8_t*)&sampleRate, 4);
  file.write((uint8_t*)&byteRate, 4);

  file.write((uint8_t*)&blockAlign, 2);
  file.write((uint8_t*)&bitsPerSample, 2);

  file.write((const uint8_t*)"data", 4);
  file.write((uint8_t*)&dataSize, 4);
}

// ============================================================
// MICROPHONE INITIALIZATION (safe to call again for recovery)
// ============================================================

bool initializeMicrophone() {

  if (micDriverInstalled) {
    i2s_driver_uninstall(I2S_NUM_0);
    micDriverInstalled = false;
  }

  i2s_config_t i2sConfig = {

    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),

    .sample_rate = SAMPLE_RATE,

    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,

    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,

    .communication_format = I2S_COMM_FORMAT_STAND_I2S,

    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,

    // 16 x 256 samples = 256 ms of buffering, so a slow SD write
    // does not overrun the microphone DMA.
    .dma_buf_count = 16,

    .dma_buf_len = AUDIO_SAMPLES_PER_BUFFER,

    .use_apll = false,

    .tx_desc_auto_clear = false,

    .fixed_mclk = 0
  };

  esp_err_t result = i2s_driver_install(I2S_NUM_0, &i2sConfig, 0, nullptr);

  if (result != ESP_OK) {

    Serial.printf("Microphone driver error: %d\n", result);

    return false;
  }

  micDriverInstalled = true;

  i2s_pin_config_t pinConfig = {

    .bck_io_num = I2S_BCLK,

    .ws_io_num = I2S_WS,

    .data_out_num = I2S_PIN_NO_CHANGE,

    .data_in_num = I2S_DIN
  };

  result = i2s_set_pin(I2S_NUM_0, &pinConfig);

  if (result != ESP_OK) {

    i2s_driver_uninstall(I2S_NUM_0);
    micDriverInstalled = false;

    Serial.printf("Microphone pin error: %d\n", result);

    return false;
  }

  i2s_zero_dma_buffer(I2S_NUM_0);

  Serial.println("Microphone initialized.");

  return true;
}

// ============================================================
// MICROSD INITIALIZATION (safe to call again for recovery)
// ============================================================

bool initializeSD() {

  if (sdInitAttempted) {
    SD.end();
    sdSPI.end();
  }

  sdInitAttempted = true;

  sdSPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);

  if (!SD.begin(SD_CS, sdSPI, 4000000)) {

    Serial.println("microSD initialization failed.");

    return false;
  }

  if (SD.cardType() == CARD_NONE) {

    Serial.println("No microSD card detected.");

    return false;
  }

  Serial.printf(
    "microSD ready. Capacity: %llu MB\n",
    SD.cardSize() / (1024ULL * 1024ULL)
  );

  return true;
}

// ============================================================
// HARDWARE RECOVERY
// ============================================================

void updateReadyLeds() {

  if (sdReady && microphoneReady) {

    digitalWrite(GREEN_LED_PIN, HIGH);
    digitalWrite(RED_LED_PIN, LOW);

  } else {

    digitalWrite(GREEN_LED_PIN, LOW);
    digitalWrite(RED_LED_PIN, HIGH);
  }
}

bool ensureHardwareReady() {

  if (!sdReady) {
    Serial.println("Recovery: re-initializing microSD...");
    sdReady = initializeSD();
  }

  if (!microphoneReady) {
    Serial.println("Recovery: re-initializing microphone...");
    microphoneReady = initializeMicrophone();
  }

  updateReadyLeds();

  return sdReady && microphoneReady;
}

// ============================================================
// AUDIO METADATA
// ============================================================

void publishAudioMetadata(const String& eventId, const String& filename,
                          uint32_t fileSize, const char* status) {

  if (audioMetadataCharacteristic == nullptr) {
    return;
  }

  String metadata =
    String("{\"event_id\":\"") + eventId +
    "\",\"filename\":\"" + filename +
    "\",\"format\":\"WAV\"" +
    ",\"sample_rate\":16000" +
    ",\"channels\":1" +
    ",\"bits_per_sample\":16" +
    ",\"file_size\":" + String(fileSize) +
    ",\"transfer_status\":\"" + status + "\"}";

  audioMetadataCharacteristic->setValue(metadata.c_str());

  if (deviceConnected) {
    audioMetadataCharacteristic->notify();
  }

  Serial.println("Audio metadata:");
  Serial.println(metadata);
}

// ============================================================
// BUTTON (debounced). Pure state machine, no side effects.
//   BTN_RELEASED     : released; pressMs = how long it was held
//   BTN_HOLD_REACHED : still held and 5 s reached (fires once; the
//                      later release is swallowed)
// ============================================================

ButtonAction pollButton(unsigned long& pressMs) {

  int rawState = digitalRead(SOS_BUTTON_PIN);

  if (rawState != lastRawButtonState) {

    lastDebounceTime = millis();

    lastRawButtonState = rawState;
  }

  if (
    millis() - lastDebounceTime >= DEBOUNCE_MS &&
    rawState != stableButtonState
  ) {

    stableButtonState = rawState;

    if (stableButtonState == LOW) {

      pressStartTime = lastDebounceTime;

      holdFired = false;

      Serial.println("SOS button pressed.");

    } else {

      Serial.println("SOS button released.");

      bool consumed = holdFired;

      holdFired = false;

      if (consumed) {
        return BTN_NONE;
      }

      pressMs = lastDebounceTime - pressStartTime;

      return BTN_RELEASED;
    }
  }

  if (
    stableButtonState == LOW &&
    !holdFired &&
    millis() - pressStartTime >= CALL_HOLD_MS
  ) {

    holdFired = true;

    pressMs = millis() - pressStartTime;

    return BTN_HOLD_REACHED;
  }

  return BTN_NONE;
}

// Decide what a gesture means while the device is idle.
SosMode interpretIdleGesture(ButtonAction action, unsigned long pressMs) {

  if (action == BTN_HOLD_REACHED) {

    Serial.println("Hold >= 5 s: CALL SOS.");

    return MODE_CALL;
  }

  if (action == BTN_RELEASED) {

    if (pressMs < SHORT_PRESS_MS) {

      Serial.printf("Short press (%lu ms) rejected. No event created.\n", pressMs);

      return MODE_NONE;
    }

    if (pressMs <= STANDARD_MAX_MS) {

      Serial.printf("Press of %lu ms: STANDARD SOS.\n", pressMs);

      return MODE_STANDARD;
    }

    Serial.printf("Press of %lu ms is between 3 s and 5 s: ignored.\n", pressMs);

    gestureFeedback = true;
  }

  return MODE_NONE;
}

// ============================================================
// AUDIO RECORDING
// Runs until the user presses the button again (>= 1 s) or the
// safety cap is reached. The button is polled inside the loop.
// ============================================================

RecordResult recordAudio(const String& eventId) {

  if (!ensureHardwareReady()) {

    Serial.println("Recording unavailable: hardware not ready.");

    updateRecordingStatus("ERROR");

    return REC_NOT_STARTED;
  }

  String filename = "/" + eventId + ".wav";

  uint32_t minPartialBytes =
    SAMPLE_RATE * AUDIO_CHANNELS * (BITS_PER_SAMPLE / 8) / 2;   // 0.5 s

  if (SD.exists(filename.c_str())) {

    Serial.println("File already exists; refusing overwrite.");

    return REC_NOT_STARTED;
  }

  File audioFile = SD.open(filename.c_str(), FILE_WRITE);

  if (!audioFile) {

    Serial.println("Could not create WAV file.");

    sdReady = false;

    updateRecordingStatus("ERROR");

    return REC_NOT_STARTED;
  }

  writeWavHeader(audioFile, SAMPLE_RATE, BITS_PER_SAMPLE, AUDIO_CHANNELS, 0);

  // Throw away anything the DMA captured while idle.
  i2s_zero_dma_buffer(I2S_NUM_0);

  static uint8_t writeBuf[WRITE_BUFFER_BYTES];

  size_t writeLen = 0;

  uint32_t totalAudioBytes = 0;

  bool recordingOK = true;
  bool stoppedByUser = false;

  bool wasSubscribed = transferSubscribed;

  unsigned long startTime = millis();

  Serial.println("AUDIO RECORDING STARTED (press button >= 1 s to stop)");

  while (millis() - startTime < (unsigned long)MAX_RECORD_SECONDS * 1000UL) {

    // ----- stop gesture -----

    unsigned long pressMs = 0;

    ButtonAction action = pollButton(pressMs);

    if (
      action == BTN_HOLD_REACHED ||
      (action == BTN_RELEASED && pressMs >= SHORT_PRESS_MS)
    ) {

      stoppedByUser = true;

      Serial.println("Stop gesture detected.");

      break;
    }

    // ----- phone subscribed late: repeat the start (and call) request -----

    bool subscribedNow = transferSubscribed;

    if (subscribedNow && !wasSubscribed && !sosStartDelivered) {

      delay(200);

      sosStartDelivered = publishSosEvent(
        "SOS", currentEventId, activeCallMode,
        activeCallMode ? "START" : "NONE", "recording"
      );
    }

    wasSubscribed = subscribedNow;

    // ----- read microphone -----

    size_t bytesRead = 0;

    esp_err_t result = i2s_read(
      I2S_NUM_0,
      i2sSamples,
      sizeof(i2sSamples),
      &bytesRead,
      pdMS_TO_TICKS(1000)
    );

    if (result != ESP_OK || bytesRead == 0) {

      recordingOK = false;
      microphoneReady = false;

      Serial.println("Microphone read failed.");

      break;
    }

    int count = bytesRead / sizeof(int32_t);

    int16_t pcm[AUDIO_SAMPLES_PER_BUFFER];

    for (int i = 0; i < count; i++) {

      int32_t sample = i2sSamples[i] >> 14;

      if (sample > 32767) {
        sample = 32767;
      }

      if (sample < -32768) {
        sample = -32768;
      }

      pcm[i] = (int16_t)sample;
    }

    size_t bytes = count * sizeof(int16_t);

    if (writeLen + bytes > sizeof(writeBuf)) {

      size_t written = audioFile.write(writeBuf, writeLen);

      if (written != writeLen) {

        recordingOK = false;
        sdReady = false;

        Serial.println("microSD write failed.");

        writeLen = 0;

        break;
      }

      totalAudioBytes += written;

      writeLen = 0;
    }

    memcpy(writeBuf + writeLen, pcm, bytes);

    writeLen += bytes;
  }

  // ----- recording loop finished: end the call request immediately -----

  if (!sosEndPublished) {

    sosEndPublished = true;

    publishSosEvent(
      "SOS_END", eventId, activeCallMode,
      activeCallMode ? "END" : "NONE", "stopping"
    );
  }

  // ----- flush the remaining audio -----

  if (writeLen > 0) {

    size_t written = audioFile.write(writeBuf, writeLen);

    if (written == writeLen) {

      totalAudioBytes += written;

    } else {

      recordingOK = false;
      sdReady = false;

      Serial.println("microSD final write failed.");
    }

    writeLen = 0;
  }

  if (!stoppedByUser && recordingOK) {
    Serial.println("Recording stopped by the safety time limit.");
  }

  // ----- rewrite the WAV header with the real data size -----

  audioFile.seek(0);

  writeWavHeader(audioFile, SAMPLE_RATE, BITS_PER_SAMPLE, AUDIO_CHANNELS, totalAudioBytes);

  audioFile.flush();
  audioFile.close();

  uint32_t actualFileSize = 0;

  if (SD.exists(filename.c_str())) {

    File verifyFile = SD.open(filename.c_str(), FILE_READ);

    if (verifyFile) {

      actualFileSize = verifyFile.size();

      verifyFile.close();
    }
  }

  bool sizeConsistent = (actualFileSize == 44 + totalAudioBytes);

  bool usable = sizeConsistent && totalAudioBytes >= minPartialBytes;

  if (!usable) {

    Serial.println("Recording verification failed; removing bad file.");

    if (SD.exists(filename.c_str())) {
      SD.remove(filename.c_str());
    }

    updateRecordingStatus("ERROR");

    return REC_FAILED;
  }

  currentFilename = filename;

  // SAVED = ended normally, SAVED_PARTIAL = hardware error cut it short.
  updateRecordingStatus(recordingOK ? "SAVED" : "SAVED_PARTIAL");

  publishAudioMetadata(eventId, filename, actualFileSize, "PENDING");

  Serial.print("Saved file: ");
  Serial.println(filename);

  Serial.printf("File size: %lu bytes\n", (unsigned long)actualFileSize);

  return REC_OK;
}

// ============================================================
// SOS ACTIVATION
// ============================================================

void generateSosEvent(SosMode mode, unsigned long holdDuration) {

  activeCallMode = (mode == MODE_CALL);
  sosEndPublished = false;

  currentEventId = generateEventId();

  Serial.println();
  Serial.println("==================================");
  Serial.println(activeCallMode ? "SALAMASPHERE SOS (CALL MODE)" : "SALAMASPHERE SOS (STANDARD)");
  Serial.println("==================================");

  Serial.print("Event ID: ");
  Serial.println(currentEventId);

  Serial.printf("Button hold: %lu ms\n", holdDuration);

  digitalWrite(GREEN_LED_PIN, LOW);
  digitalWrite(RED_LED_PIN, HIGH);

  // The app creates the incident and, in CALL mode, dials the
  // trusted contacts when it receives this notification.
  sosStartDelivered = publishSosEvent(
    "SOS", currentEventId, activeCallMode,
    activeCallMode ? "START" : "NONE", "recording"
  );

  updateRecordingStatus("RECORDING");

  RecordResult result = recordAudio(currentEventId);

  if (result == REC_NOT_STARTED) {

    // One retry after re-initializing the hardware.
    Serial.println("Recording did not start; retrying once.");

    updateRecordingStatus("RECORDING");

    result = recordAudio(currentEventId);
  }

  // Make sure the app always hears that the call/recording ended.
  if (!sosEndPublished) {

    sosEndPublished = true;

    publishSosEvent(
      "SOS_END", currentEventId, activeCallMode,
      activeCallMode ? "END" : "NONE", "stopping"
    );
  }

  if (result == REC_OK) {

    Serial.println("SOS recording saved. Starting automatic transfer.");

    // Automatic BLE transfer to the app (newest recording first).
    autoPushPending = true;
    autoPushAttempts = 0;
    autoPushNotBefore = millis() + 800;

  } else {

    Serial.println("SOS recording failed.");

    if (ensureHardwareReady()) {
      updateRecordingStatus("READY");
    }
  }

  activeCallMode = false;

  updateReadyLeds();
}

// ============================================================
// CRC32 (standard zlib polynomial) OF A WHOLE FILE
// ============================================================

void buildCrcTable() {

  for (uint32_t i = 0; i < 256; i++) {

    uint32_t c = i;

    for (int k = 0; k < 8; k++) {
      c = (c & 1) ? (0xEDB88320UL ^ (c >> 1)) : (c >> 1);
    }

    crcTable[i] = c;
  }

  crcTableReady = true;
}

uint32_t computeFileCrc32(File& file) {

  if (!crcTableReady) {
    buildCrcTable();
  }

  uint32_t crc = 0xFFFFFFFFUL;

  uint8_t buffer[1024];

  file.seek(0);

  while (true) {

    int n = file.read(buffer, sizeof(buffer));

    if (n <= 0) {
      break;
    }

    for (int i = 0; i < n; i++) {
      crc = crcTable[(crc ^ buffer[i]) & 0xFF] ^ (crc >> 8);
    }
  }

  return ~crc;
}

// ============================================================
// SEND ONE AUDIO CHUNK
// ============================================================

ChunkResult sendAudioChunk(
  File& file,
  uint32_t startOffset,
  uint32_t fileSize,
  uint32_t chunkSize,
  uint32_t sequence,
  uint8_t* packet
) {

  uint32_t position = startOffset + sequence * chunkSize;

  if (position >= fileSize) {
    return CHUNK_FATAL;
  }

  uint32_t remaining = fileSize - position;
  uint32_t toRead = (remaining < chunkSize) ? remaining : chunkSize;

  if ((uint32_t)file.position() != position) {

    if (!file.seek(position)) {

      Serial.println("Could not seek in audio file.");

      return CHUNK_FATAL;
    }
  }

  int n = file.read(packet + PACKET_HEADER_SIZE, toRead);

  if (n != (int)toRead) {

    Serial.println("Chunk read failed.");

    return CHUNK_FATAL;
  }

  packet[0] = sequence & 0xFF;
  packet[1] = (sequence >> 8) & 0xFF;
  packet[2] = (sequence >> 16) & 0xFF;
  packet[3] = (sequence >> 24) & 0xFF;

  packet[4] = toRead & 0xFF;
  packet[5] = (toRead >> 8) & 0xFF;

  // Publish the new send limit BEFORE notifying so an immediate
  // ACK from the phone is never rejected.
  if (sequence + 1 > transferSentLimit) {
    transferSentLimit = sequence + 1;
  }

  fileTransferCharacteristic->setValue(packet, PACKET_HEADER_SIZE + toRead);

  if (!fileTransferCharacteristic->notify()) {
    return CHUNK_BUSY;
  }

  return CHUNK_SENT;
}

// ============================================================
// TRANSFER A SAVED WAV FILE (sliding window, resumable)
// Returns true only when COMPLETE was sent.
// ============================================================

bool transferAudioFile(const String& eventId, uint32_t startOffset) {

  if (!deviceConnected) {

    Serial.println("Transfer rejected: Android is disconnected.");

    return false;
  }

  if (transferActive) {

    Serial.println("Another transfer is active.");

    return false;
  }

  if (!isValidEventId(eventId)) {

    publishTransferMessage("ERROR:INVALID_EVENT_ID");

    return false;
  }

  if (!transferSubscribed) {

    Serial.println("Transfer rejected: enable notifications on FILE_TRANSFER first.");

    fileTransferCharacteristic->setValue("ERROR:NOT_SUBSCRIBED");

    return false;
  }

  if (currentMtu < MIN_MTU_FOR_TRANSFER) {

    publishTransferMessage("ERROR:MTU_TOO_SMALL");

    return false;
  }

  if (!sdReady) {
    sdReady = initializeSD();
  }

  if (!sdReady) {

    publishTransferMessage("ERROR:SD_UNAVAILABLE");

    return false;
  }

  String filename = "/" + eventId + ".wav";

  if (!SD.exists(filename.c_str())) {

    publishTransferMessage("ERROR:FILE_NOT_FOUND");

    return false;
  }

  File file = SD.open(filename.c_str(), FILE_READ);

  if (!file) {

    publishTransferMessage("ERROR:OPEN_FAILED");

    return false;
  }

  uint32_t fileSize = file.size();

  if (fileSize < 44) {

    file.close();

    publishTransferMessage("ERROR:INVALID_WAV_SIZE");

    return false;
  }

  if (startOffset > fileSize) {

    file.close();

    publishTransferMessage("ERROR:BAD_OFFSET");

    return false;
  }

  uint32_t chunkSize = (uint32_t)currentMtu - 3 - PACKET_HEADER_SIZE;

  if (chunkSize > MAX_CHUNK_PAYLOAD) {
    chunkSize = MAX_CHUNK_PAYLOAD;
  }

  uint32_t totalChunks =
    (fileSize - startOffset + chunkSize - 1) / chunkSize;

  uint32_t crc = computeFileCrc32(file);

  if (!file.seek(startOffset)) {

    file.close();

    publishTransferMessage("ERROR:SEEK_FAILED");

    return false;
  }

  // ----- reset shared transfer state -----

  abortRequested = false;
  highestAck = -1;
  transferSentLimit = 0;
  transferActive = true;

  char msg[128];

  snprintf(
    msg,
    sizeof(msg),
    "START:%s:%lu:%lu:%lu:%lu:%08lX",
    eventId.c_str(),
    (unsigned long)fileSize,
    (unsigned long)totalChunks,
    (unsigned long)chunkSize,
    (unsigned long)startOffset,
    (unsigned long)crc
  );

  publishTransferMessage(String(msg));

  Serial.println();
  Serial.println("AUDIO TRANSFER STARTED");
  Serial.printf("File size: %lu, offset: %lu, chunk size: %lu, chunks: %lu\n",
                (unsigned long)fileSize,
                (unsigned long)startOffset,
                (unsigned long)chunkSize,
                (unsigned long)totalChunks);

  delay(100);

  static uint8_t packet[PACKET_HEADER_SIZE + MAX_CHUNK_PAYLOAD];

  uint32_t base = 0;
  uint32_t next = 0;

  int stalls = 0;

  unsigned long lastProgress = millis();

  const char* failReason = nullptr;

  while (base < totalChunks) {

    if (!deviceConnected) {
      failReason = "DISCONNECTED";
      break;
    }

    if (abortRequested) {
      failReason = "ABORTED";
      break;
    }

    // An SOS gesture must never be blocked by a file transfer.
    unsigned long pressMs = 0;

    ButtonAction action = pollButton(pressMs);

    if (action != BTN_NONE) {

      SosMode mode = interpretIdleGesture(action, pressMs);

      if (mode != MODE_NONE) {

        pendingSosMode = mode;
        pendingSosHold = pressMs;

        failReason = "ABORTED_FOR_SOS";
        break;
      }
    }

    // ----- fill the window -----

    bool fatal = false;

    while (next < totalChunks && next < base + WINDOW_SIZE) {

      ChunkResult r = sendAudioChunk(
        file, startOffset, fileSize, chunkSize, next, packet
      );

      if (r == CHUNK_SENT) {
        next++;
        continue;
      }

      if (r == CHUNK_FATAL) {
        fatal = true;
      }

      break;
    }

    if (fatal) {
      failReason = "SD_READ_ERROR";
      break;
    }

    // ----- process acknowledgements -----

    int32_t ack = highestAck;

    if (ack >= (int32_t)base) {

      base = (uint32_t)ack + 1;

      if (next < base) {
        next = base;
      }

      stalls = 0;
      lastProgress = millis();

      if (base % 200 == 0) {
        Serial.printf("Progress: %lu / %lu chunks\n",
                      (unsigned long)base, (unsigned long)totalChunks);
      }

      continue;
    }

    // ----- timeout: go back to the oldest unacknowledged chunk -----

    if (millis() - lastProgress > ACK_TIMEOUT_MS) {

      stalls++;

      Serial.printf("ACK timeout at chunk %lu (stall %d of %d)\n",
                    (unsigned long)base, stalls, MAX_STALLS);

      if (stalls >= MAX_STALLS) {
        failReason = "ACK_TIMEOUT";
        break;
      }

      next = base;

      lastProgress = millis();
    }

    delay(2);
  }

  file.close();

  uint32_t resumeOffset = startOffset + base * chunkSize;

  if (resumeOffset > fileSize) {
    resumeOffset = fileSize;
  }

  bool success = (failReason == nullptr);

  if (success) {

    snprintf(
      msg,
      sizeof(msg),
      "COMPLETE:%s:%lu:%lu:%08lX",
      eventId.c_str(),
      (unsigned long)fileSize,
      (unsigned long)totalChunks,
      (unsigned long)crc
    );

    publishTransferMessage(String(msg));

    rememberPushed(eventId);

    Serial.println();
    Serial.println("AUDIO TRANSFER COMPLETED (waiting for DONE from the app)");

  } else {

    Serial.println();
    Serial.printf("AUDIO TRANSFER STOPPED: %s (resume offset %lu)\n",
                  failReason, (unsigned long)resumeOffset);

    if (deviceConnected) {

      snprintf(
        msg,
        sizeof(msg),
        "ERROR:TRANSFER_INCOMPLETE:%s:%lu",
        failReason,
        (unsigned long)resumeOffset
      );

      publishTransferMessage(String(msg));
    }
  }

  transferActive = false;
  abortRequested = false;

  return success;
}

// ============================================================
// LIST / MARK-SENT / DELETE RECORDINGS
//   pending = /<id>.wav      transferred = /<id>.sent
// ============================================================

String stripLeadingSlash(String name) {

  if (name.startsWith("/")) {
    name = name.substring(1);
  }

  return name;
}

void listRecordings() {

  if (!sdReady) {
    sdReady = initializeSD();
  }

  if (!sdReady) {

    publishTransferMessage("ERROR:SD_UNAVAILABLE");

    return;
  }

  File root = SD.open("/");

  if (!root) {

    publishTransferMessage("ERROR:SD_UNAVAILABLE");

    return;
  }

  int count = 0;

  File entry = root.openNextFile();

  while (entry && deviceConnected && count < MAX_LIST_ENTRIES) {

    if (!entry.isDirectory()) {

      String name = stripLeadingSlash(String(entry.name()));

      if (name.startsWith("SALAMA-") && name.endsWith(".wav")) {

        String id = name.substring(0, name.length() - 4);

        publishTransferMessage(
          String("FILE:") + id + ":" + String((unsigned long)entry.size())
        );

        count++;

        delay(40);
      }
    }

    entry.close();

    entry = root.openNextFile();
  }

  if (entry) {
    entry.close();
  }

  root.close();

  publishTransferMessage(String("LIST_END:") + String(count));
}

// Newest pending recording that has not been pushed in this connection.
String findPendingRecording() {

  String found = "";

  if (!sdReady) {
    return found;
  }

  File root = SD.open("/");

  if (!root) {
    return found;
  }

  File entry = root.openNextFile();

  while (entry) {

    if (!entry.isDirectory()) {

      String name = stripLeadingSlash(String(entry.name()));

      if (name.startsWith("SALAMA-") && name.endsWith(".wav")) {

        String id = name.substring(0, name.length() - 4);

        if (isValidEventId(id) && !wasPushed(id)) {
          found = id;   // keep the last one = newest
        }
      }
    }

    entry.close();

    entry = root.openNextFile();
  }

  root.close();

  return found;
}

// Keep only the newest `keep` transferred files to protect SD space.
void trimSentFiles(int keep) {

  String names[64];
  int n = 0;

  File root = SD.open("/");

  if (!root) {
    return;
  }

  File entry = root.openNextFile();

  while (entry && n < 64) {

    if (!entry.isDirectory()) {

      String name = String(entry.name());

      if (!name.startsWith("/")) {
        name = "/" + name;
      }

      if (name.endsWith(".sent")) {
        names[n++] = name;
      }
    }

    entry.close();

    entry = root.openNextFile();
  }

  if (entry) {
    entry.close();
  }

  root.close();

  for (int i = 0; i < n - keep; i++) {

    Serial.print("Removing old sent file: ");
    Serial.println(names[i]);

    SD.remove(names[i].c_str());
  }
}

// App verified the CRC and stored the audio under the incident.
void markRecordingSent(const String& eventId) {

  if (!isValidEventId(eventId)) {

    publishTransferMessage("ERROR:INVALID_EVENT_ID");

    return;
  }

  String wav = "/" + eventId + ".wav";
  String sent = "/" + eventId + ".sent";

  if (SD.exists(sent.c_str())) {

    publishTransferMessage(String("MARKED:") + eventId);

    return;
  }

  if (!SD.exists(wav.c_str())) {

    publishTransferMessage("ERROR:FILE_NOT_FOUND");

    return;
  }

  uint32_t size = 0;

  File f = SD.open(wav.c_str(), FILE_READ);

  if (f) {
    size = f.size();
    f.close();
  }

  if (!SD.rename(wav.c_str(), sent.c_str())) {

    publishTransferMessage("ERROR:MARK_FAILED");

    return;
  }

  rememberPushed(eventId);

  publishAudioMetadata(eventId, wav, size, "TRANSFERRED");

  publishTransferMessage(String("MARKED:") + eventId);

  Serial.println("Transfer marked as successful.");

  trimSentFiles(MAX_SENT_KEEP);
}

void deleteRecording(const String& eventId) {

  if (!isValidEventId(eventId)) {

    publishTransferMessage("ERROR:INVALID_EVENT_ID");

    return;
  }

  String wav = "/" + eventId + ".wav";
  String sent = "/" + eventId + ".sent";

  String target = "";

  if (SD.exists(wav.c_str())) {
    target = wav;
  } else if (SD.exists(sent.c_str())) {
    target = sent;
  }

  if (target.length() == 0) {

    publishTransferMessage("ERROR:FILE_NOT_FOUND");

    return;
  }

  if (SD.remove(target.c_str())) {

    publishTransferMessage(String("DELETED:") + eventId);

  } else {

    publishTransferMessage("ERROR:DELETE_FAILED");
  }
}

// ============================================================
// PROCESS ANDROID COMMANDS
// ============================================================

void processPendingCommand() {

  char buffer[CMD_MAX_LEN];

  if (!dequeueCommand(buffer)) {
    return;
  }

  String command = String(buffer);

  command.trim();

  if (command.startsWith("GET:")) {

    String eventId = command.substring(4);

    eventId.trim();

    transferAudioFile(eventId, 0);

    return;
  }

  if (command.startsWith("RESUME:")) {

    String rest = command.substring(7);

    int colon = rest.lastIndexOf(':');

    if (colon <= 0 || colon == (int)rest.length() - 1) {

      publishTransferMessage("ERROR:BAD_RESUME_FORMAT");

      return;
    }

    String eventId = rest.substring(0, colon);
    String offsetText = rest.substring(colon + 1);

    eventId.trim();
    offsetText.trim();

    for (size_t i = 0; i < offsetText.length(); i++) {

      if (!isDigit(offsetText.charAt(i))) {

        publishTransferMessage("ERROR:BAD_RESUME_FORMAT");

        return;
      }
    }

    uint32_t offset = (uint32_t)strtoul(offsetText.c_str(), nullptr, 10);

    transferAudioFile(eventId, offset);

    return;
  }

  if (command == "STATUS") {

    publishTransferMessage(String("STATUS:") + recordingStatus);

    return;
  }

  if (command == "LIST") {

    listRecordings();

    return;
  }

  if (command.startsWith("DONE:")) {

    String eventId = command.substring(5);

    eventId.trim();

    markRecordingSent(eventId);

    return;
  }

  if (command.startsWith("DELETE:")) {

    String eventId = command.substring(7);

    eventId.trim();

    deleteRecording(eventId);

    return;
  }

  publishTransferMessage("ERROR:UNKNOWN_COMMAND");
}

// ============================================================
// BATTERY STATUS
// ============================================================

void updateBattery(bool force) {

  static unsigned long lastUpdate = 0;
  static int lastPercent = -2;

  if (batteryCharacteristic == nullptr) {
    return;
  }

  if (!force && millis() - lastUpdate < BATTERY_UPDATE_MS) {
    return;
  }

  lastUpdate = millis();

  int millivolts = -1;
  int percent = -1;

#if BATTERY_ADC_PIN >= 0

  uint32_t sum = 0;

  for (int i = 0; i < 8; i++) {
    sum += analogReadMilliVolts(BATTERY_ADC_PIN);
  }

  millivolts = (int)((sum / 8) * BATTERY_DIVIDER);

  percent = (int)(
    ((long)(millivolts - BATTERY_EMPTY_MV) * 100L) /
    (BATTERY_FULL_MV - BATTERY_EMPTY_MV)
  );

  if (percent < 0) {
    percent = 0;
  }

  if (percent > 100) {
    percent = 100;
  }

#endif

  char json[64];

  snprintf(
    json,
    sizeof(json),
    "{\"battery_percent\":%d,\"voltage_mv\":%d}",
    percent,
    millivolts
  );

  batteryCharacteristic->setValue(json);

  if (deviceConnected && (force || percent != lastPercent)) {
    batteryCharacteristic->notify();
  }

  lastPercent = percent;
}

// ============================================================
// BLE WATCHDOG: make sure the device is always discoverable
// ============================================================

void maintainBle() {

  static unsigned long lastCheck = 0;

  if (millis() - lastCheck < 2000) {
    return;
  }

  lastCheck = millis();

  if (deviceConnected) {
    return;
  }

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();

  if (!advertising->isAdvertising()) {

    Serial.println("Advertising was stopped; restarting.");

    advertising->start();
  }
}

// ============================================================
// SETUP
// ============================================================

void setup() {

  Serial.begin(115200);

  delay(1000);

  pinMode(SOS_BUTTON_PIN, INPUT_PULLUP);

  pinMode(GREEN_LED_PIN, OUTPUT);
  pinMode(RED_LED_PIN, OUTPUT);

  digitalWrite(GREEN_LED_PIN, LOW);
  digitalWrite(RED_LED_PIN, LOW);

  Serial.println();
  Serial.println("==================================");
  Serial.println("SalamaSphere Day 10 v" FIRMWARE_VERSION);
  Serial.println("==================================");

  buildCrcTable();

  sdReady = initializeSD();

  microphoneReady = initializeMicrophone();

  // ----------------------------------------
  // Initialize BLE
  // ----------------------------------------

  NimBLEDevice::init(DEVICE_NAME);

  NimBLEDevice::setMTU(PREFERRED_MTU);

  bleServer = NimBLEDevice::createServer();

  bleServer->setCallbacks(new SalamaServerCallbacks());

  salamaService = bleServer->createService(SERVICE_UUID);

  deviceIdCharacteristic =
    salamaService->createCharacteristic(
      DEVICE_ID_UUID,
      NIMBLE_PROPERTY::READ
    );

  deviceIdCharacteristic->setValue(
    "{\"device_id\":\"" DEVICE_ID "\","
    "\"device_name\":\"" DEVICE_NAME "\","
    "\"firmware_version\":\"" FIRMWARE_VERSION "\"}"
  );

  sosEventCharacteristic =
    salamaService->createCharacteristic(
      SOS_EVENT_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );

  sosEventCharacteristic->setValue("{\"event_type\":\"NONE\"}");

  recordingStatusCharacteristic =
    salamaService->createCharacteristic(
      RECORDING_STATUS_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );

  recordingStatusCharacteristic->setValue("INITIALIZING");

  audioMetadataCharacteristic =
    salamaService->createCharacteristic(
      AUDIO_METADATA_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );

  audioMetadataCharacteristic->setValue("{\"transfer_status\":\"NONE\"}");

  fileTransferCharacteristic =
    salamaService->createCharacteristic(
      FILE_TRANSFER_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );

  fileTransferCharacteristic->setValue("IDLE");

  fileTransferCharacteristic->setCallbacks(new TransferStreamCallbacks());

  transferAckCharacteristic =
    salamaService->createCharacteristic(
      TRANSFER_ACK_UUID,
      NIMBLE_PROPERTY::READ |
      NIMBLE_PROPERTY::WRITE |
      NIMBLE_PROPERTY::WRITE_NR |
      NIMBLE_PROPERTY::NOTIFY
    );

  transferAckCharacteristic->setValue("IDLE");

  transferAckCharacteristic->setCallbacks(new TransferCommandCallbacks());

  batteryCharacteristic =
    salamaService->createCharacteristic(
      BATTERY_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );

  batteryCharacteristic->setValue("{\"battery_percent\":-1,\"voltage_mv\":-1}");

  updateBattery(true);

  salamaService->start();

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();

  advertising->addServiceUUID(SERVICE_UUID);

  advertising->setName(DEVICE_NAME);

  advertising->enableScanResponse(true);

  advertising->start();

  // ----------------------------------------
  // Report initialization status
  // ----------------------------------------

  updateReadyLeds();

  if (sdReady && microphoneReady) {

    updateRecordingStatus("READY");

    Serial.println("STATUS: READY");

  } else {

    updateRecordingStatus("ERROR");

    Serial.println("STATUS: INITIALIZATION FAILED (will retry automatically)");
  }

  Serial.println("BLE advertising started.");
  Serial.println("Press 1-3 s: standard SOS | hold 5 s+: SOS + call request.");
  Serial.println("While recording, press >= 1 s to stop.");
}

// ============================================================
// MAIN LOOP
// ============================================================

void loop() {

  // ----- SOS gestures have priority over everything -----

  SosMode startMode = MODE_NONE;
  unsigned long holdDuration = 0;

  if (pendingSosMode != MODE_NONE) {

    startMode = pendingSosMode;
    holdDuration = pendingSosHold;
    pendingSosMode = MODE_NONE;

  } else {

    unsigned long pressMs = 0;

    ButtonAction action = pollButton(pressMs);

    if (action != BTN_NONE) {

      startMode = interpretIdleGesture(action, pressMs);
      holdDuration = pressMs;
    }
  }

  if (startMode != MODE_NONE) {
    generateSosEvent(startMode, holdDuration);
  }

  // Ignored 3-5 s press: one red blink so the user knows nothing started.
  if (gestureFeedback) {

    gestureFeedback = false;

    digitalWrite(RED_LED_PIN, HIGH);
    delay(150);
    updateReadyLeds();
  }

  // ----- commands from the phone -----

  processPendingCommand();

  maintainBle();

  updateBattery(false);

  // ----- after (re)connection: list what is still on the card, then
  //       give the app 4 s to request files itself before auto push -----

  if (
    syncRequested &&
    deviceConnected &&
    transferSubscribed &&
    currentMtu >= 64
  ) {

    syncRequested = false;

    clearPushed();

    delay(300);

    listRecordings();

    autoPushPending = true;
    autoPushAttempts = 0;
    autoPushNotBefore = millis() + 4000;
  }

  // ----- automatic transfer of pending recordings (newest first) -----

  if (
    autoPushPending &&
    millis() >= autoPushNotBefore &&
    deviceConnected &&
    transferSubscribed &&
    currentMtu >= MIN_MTU_FOR_TRANSFER &&
    !transferActive &&
    pendingSosMode == MODE_NONE
  ) {

    String id = findPendingRecording();

    if (id.length() == 0) {

      autoPushPending = false;

      Serial.println("Auto transfer: nothing pending.");

    } else {

      Serial.print("Auto transfer: ");
      Serial.println(id);

      bool ok = transferAudioFile(id, 0);

      if (ok) {

        autoPushAttempts = 0;

      } else if (pendingSosMode == MODE_NONE) {

        autoPushAttempts++;

        autoPushNotBefore = millis() + 5000;

        if (autoPushAttempts >= MAX_AUTO_PUSH_ATTEMPTS) {

          autoPushPending = false;

          Serial.println("Auto transfer gave up; will retry on next connection.");
        }
      }
    }
  }

  // ----- hardware recovery while idle (SD removed, mic fault...) -----

  static unsigned long lastRecoveryTry = 0;

  if (
    (!sdReady || !microphoneReady) &&
    millis() - lastRecoveryTry > 10000
  ) {

    lastRecoveryTry = millis();

    if (ensureHardwareReady()) {
      updateRecordingStatus("READY");
    }
  }

  delay(5);
}
