# CadenceCore

Native iPhone + Apple Watch ERG training app, currently at the **hardware diagnostic milestone**.

The planned product has Watch-first controls and Health recording, iPhone trainer control, a ZWO workout library, FTP-based targets, advisory cadence guidance, and manual Strava file export. Those product features are **not implemented yet**. This first build establishes whether the actual KICKR CORE 2 supports the required Bluetooth control and background behavior.

## What this build does

- Discovers nearby named BLE devices and lists a selected device's GATT services/characteristics.
- Reads model, manufacturer, and firmware when standard Device Information characteristics are available.
- Decodes FTMS indoor-bike power/cadence.
- Enables FTMS control only when target-power capability, supported power range, and control indications are present.
- Sends explicit request-control, target-power, start, and stop commands, serializing them and checking trainer responses with a five-second timeout.
- Offers an operator-armed 20-minute background test: five minutes each at 80 W, 100 W, a 100–120 W ramp, and 80 W. Requires support for every integer target in that range. The timeline uses monotonic elapsed time and is serviced by BLE telemetry callbacks, not a foreground UI timer.
- Measures live Watch heart rate in an indoor-cycling HealthKit session and mirrors it to iPhone.
- Shows missing/stale trainer measurements after three seconds and HR after ten seconds.
- Saves a bounded timestamped diagnostic log locally, restores it at launch, and exports it using the share sheet. No heart-rate samples are written to that log.

Diagnostic Watch sessions are **discarded**, not saved to Health/Fitness. No workout import, cadence coaching, history recording, or Strava integration is available yet.

## Build

Use full Xcode compatible with your installed iPhone/Watch OS. The deployment baseline is iOS 18 / watchOS 11.

Open [CadenceCore.xcodeproj](./CadenceCore.xcodeproj). The project is generated from [project.yml](./project.yml) using XcodeGen. Source additions or changes to the specification require regeneration:

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CadenceCore.xcodeproj -scheme CadenceCore \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Do not pass `-sdk iphonesimulator` to the paired-target build: that overrides the Watch SDK as well. Let the destination select each target's platform.

### Install on your devices

1. In Xcode Settings > Accounts, sign in locally with your Apple Account.
2. In the project editor, select **CadenceCore**, then **Signing & Capabilities**, and choose your Personal Team with automatic signing. Repeat for **CadenceCoreWatch**.
3. Keep the iPhone unlocked, trusted, and connected. Enable Developer Mode if prompted. Keep the paired Watch nearby and unlocked.
4. Select the **CadenceCore** scheme and your iPhone destination, then Run.
5. Select the **CadenceCoreWatch** scheme and your paired Watch destination, then Run. Resolve any device preparation/signing prompts in Xcode.
6. Personal Team profiles expire after seven days; rebuild/reinstall periodically. Do not share credentials or commit signing secrets.

If you regenerate after selecting your team, XcodeGen can remove manually edited project settings. Set `DEVELOPMENT_TEAM` locally again in Xcode, or supply it as a build setting; do not put credentials in the project.

## Hardware gate procedure

1. Close Zwift/Wahoo/other trainer-controlling apps. Set up the trainer using Wahoo's instructions and keep a practical way to stop pedaling/power down the trainer.
2. Open CadenceCore on iPhone, scan, and select your KICKR.
3. Export the discovery log. Confirm whether service `1826` (FTMS) exists, target power is supported, and a control point/power range is reported.
4. **If FTMS is missing or unsupported, stop here.** No vendor-specific writes are implemented. The next step is investigating a supported Wahoo protocol, not trying random commands.
5. Request control. Confirm the log reports a successful trainer acknowledgment. Send a modest supported target, then start; observe actual measured power and trainer behavior.
6. Send stop and physically verify what it does. An acknowledgment is not proof that resistance was removed. Disconnecting is not a load-release command.
7. On iPhone, tap **Enable Watch diagnostic mirroring** and authorize HealthKit. Start the diagnostic in the CadenceCore Watch app. Check live HR on both devices; lower your wrist and verify it continues. End/discard afterward.
8. If manual control is working, send an initial target/start, then explicitly arm the 20-minute background test. Lock iPhone and ride only if those targets are appropriate for you. Repeat with another app open. Export logs after each run.
9. Check scheduled command issue/acknowledgment timestamps at the five-minute transitions and power tracking after settling. The timing gate is commands issued within two seconds of their expected steady-interval boundary, not instantaneous watt matching.
10. Test disconnects, Bluetooth off/on, and unexpected interruptions. Confirm the UI reports uncertain trainer state rather than false success.

**Limits:** The test depends on ongoing trainer telemetry. If notifications stop, the app is force-quit, the phone shuts down, or the connection is lost, continued control and stop delivery cannot be guaranteed. The trainer may keep its last ERG target. A reconnect does not automatically resume the test. This diagnostic is not a safety interlock.

Only after the actual-device gate passes should the full workout engine, ZWO library, coordinated Watch controls, Health saves, and cadence guidance be built.

## Strava

The eventual MVP uses TCX export and manual Strava website upload. Strava's native Apple Health importer excludes custom-app recordings; using a custom Watch app does not make them Apple Workout recordings.
