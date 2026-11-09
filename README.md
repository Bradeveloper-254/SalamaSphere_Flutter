# SalamaSphere Mobile

Flutter Android client for SalamaSphere.

## Incident flow

- Connect to the wearable over BLE and subscribe to SOS, recording status,
  audio metadata, and audio data.
- Recover stored recordings with `LIST`; transfer WAV files with `GET`, framed
  chunks, cumulative `ACK`, and whole-file CRC-32 verification.
- Capture phone GPS when the SOS is received, then persist the incident and
  audio locally. Pending data is retried when connectivity returns.
- Store incident details and audio bytes encrypted with AES-256-GCM. The
  encryption key is held in Android secure storage; database schema version 6
  encrypts existing unencrypted queued records during upgrade.
- Submit incident JSON and WAV evidence to the HTTPS Django API using the
  logged-in user's token. Keep the wearable's SD-card copy until the backend
  confirms the audio upload.
- When a wearable requests a call, offer the user a trusted contact and open
  Android's dialer. The user must confirm/place the call; the ESP32 cannot
  place telephone calls itself.

The wearable identifier must be active and owned by the authenticated user in
the backend before its SOS can be accepted. Configure the production API in
`lib/config/api_config.dart`.

## Development checks

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

BLE reception currently requires the app to be running and connected; this
project does not implement an Android foreground service for monitoring while
the app is terminated. Test GPS permission, BLE reliability, SOS delivery,
audio integrity, and calls on the actual phone and wearable before relying on
the prototype. It is not a guaranteed emergency-response service.
