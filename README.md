# CadenceCore

Native iPhone + Apple Watch ERG training app, currently with **hardware diagnostics, a persistent workout library, and iPhone ERG playback**.

The original app icon combines a teal **C** with a power/heart-rate pulse on a dark background. Matching opaque 1024-pixel icons are included in the iPhone and Watch asset catalogs; the operating system applies its own rounded or circular mask.

The planned product has Watch-first controls and Health recording, iPhone trainer control, a ZWO workout library, FTP-based targets, advisory cadence guidance, and manual Strava file export. Library/import/preview and iPhone workout execution are implemented; **Watch workout controls, cadence guidance, Health saving, history/recovery, simulated speed/distance, and Strava export are not implemented yet**. Diagnostics establish the actual KICKR CORE 2 control and background behavior; general playback still needs actual-device acceptance.

## Workout library

The **Workouts** tab supports Files-based ZWO import, an original example workout, local SwiftData persistence, rename, duplicate, favorite, and delete. Enter your FTP (1–2000 W) to see interval watt targets alongside % FTP, a power-profile chart, and a full interval-list alternative. Open a workout to review warnings and start ERG playback; trainer setup and diagnostics remain in their separate tab.

The FTP number pad has a **Done** button to dismiss it; scrolling also dismisses it interactively. Importing or adding an example closes the keyboard without changing the entered FTP.

Supported UTF-8 cycling ZWO blocks:

- `SteadyState`: `Duration`, `Power`, optional `Cadence`.
- `Warmup`, `Cooldown`, `Ramp`: `Duration`, `PowerLow` (start), `PowerHigh` (end), optional `Cadence`.
- `IntervalsT`: integer `Repeat`, `OnDuration`, `OffDuration`, `OnPower`, `OffPower`; optional `Cadence` for work phases and `CadenceResting` for recovery. Work cadence is not copied to recovery.

Power values are fractions of FTP, from 0 to 3. Durations must be 0.1 seconds or greater. Limits: 1 MiB input, six hours expanded duration, 2000 expanded intervals, 1000 repetitions per block, 16 XML nesting levels, cadence 1–250 rpm. DTD/entity declarations, non-cycling sports, unsupported executable blocks and behavior-changing attributes are rejected explicitly. Metadata is retained for name/description; unknown top-level metadata produces warnings. Text cues and unsupported cadence attributes currently generate visible preview warnings rather than being silently interpreted.

Imports retain their original source bytes locally. Import/persistence errors are visible and failed mutations roll back. No in-app interval editor or calendar is included.

## iPhone ERG playback

1. Close other trainer-controlling apps. In **Diagnostics**, connect to KICKR and **Request FTMS control**. Wait for fresh telemetry; do not arm a diagnostic test.
2. Set FTP, open an imported workout in **Workouts**, review its profile/warnings, and confirm **Start ERG workout**. The player validates the loaded interval values and trainer range before sending any workout command.
3. The initial target must be acknowledged before start is sent; timing begins only after start is acknowledged. Workouts use an immutable name/interval/FTP snapshot, so library edits do not alter an active ride. Targets are rounded to supported trainer increments without exceeding the supported range.
4. The live ride shows active time, interval/remaining time, scheduled power, actual measured power/cadence, and fresh mirrored Watch HR when a separate diagnostic HR session is running. **Scheduled target** is the interval plan, not a claim about actual applied resistance during pause/finish.
5. **Pause and reduce load** freezes active time and queues the acknowledged 0 W then stop sequence behind any pending command. Resume is enabled after that sequence completes, requires fresh telemetry/control and the same trainer power range, restores the scheduled target, then starts. Paused and start-handshake time are excluded.
6. Automatic completion and confirmed **Finish workout** request the same reduced-load sequence. The player does not claim completion until both acknowledgments arrive. **Current ride** in the library lets you return to controls after navigating away.

Diagnostic target/start/test controls are blocked while the player owns the trainer, including while paused/interrupted. The explicit diagnostic reduced-load stop remains available and finishes the active workout. Disconnect, rejection, malformed control response, write failure, or timeout freezes playback with a visible reason. A gap longer than three seconds between serviced telemetry callbacks also freezes the last confirmed active time and requests reduced load when control is available; it does not silently skip intervals or auto-resume. A best-effort watchdog checks stale telemetry while the app is scheduled; it is not a background execution guarantee or hardware safety interlock. BLE telemetry callbacks own progression, not the UI refresh timer.

After an interruption, reconnect/reacquire control as necessary and resume explicitly, or retry finish. **Force-quit/relaunch loses ride progress and may leave the last target on the trainer.** The user reports workout playback, pause, resume, and finish work on the actual KICKR. This establishes basic functional acceptance, not measured ramp/boundary timing, automatic completion, long-duration continuity, or interruption recovery. Locked-screen general playback remains unverified; the earlier locked-screen test covered the diagnostic schedule only.

This milestone does **not** create a saved ride, Health/Fitness workout, or export. Watch HR diagnostics must still be started and ended separately on Watch and are discarded. Watch-first coordinated controls/recording are the next integration, not an invitation to run Apple's Workout app simultaneously.

## What this build does

- Discovers nearby named BLE devices and lists a selected device's GATT services/characteristics.
- Reads model, manufacturer, and firmware when standard Device Information characteristics are available.
- Decodes FTMS indoor-bike power/cadence.
- Enables FTMS control only when target-power capability, supported power range, and control indications are present.
- Sends explicit request-control, target-power, start, and stop commands, serializing them and checking trainer responses with a five-second timeout.
- **Reduce load to 0 W and stop** cancels diagnostic progression, waits for any in-flight command, requests 0 W, and sends FTMS stop only after the 0 W acknowledgment. Repeated taps cannot interleave the sequence. Timeout, rejection, or connection loss produces an explicit unconfirmed-state warning, not success.
- Offers operator-armed **4-minute (default)** and **20-minute** background tests: four equal stages at 80 W, 100 W, a 100–120 W ramp, and 80 W. Stages last one minute or five minutes respectively. Requires support for every integer target in that range. The timeline uses monotonic elapsed time and is serviced by BLE telemetry callbacks, not a foreground UI timer. Duration is fixed when armed and cannot change mid-test.
- Measures live Watch heart rate in an indoor-cycling HealthKit session and mirrors it to iPhone.
- Shows missing/stale trainer measurements after three seconds and HR after ten seconds.
- Saves a bounded, millisecond-timestamped diagnostic log locally, restores it at launch, and exports it using the share sheet. During the background test, measured power/cadence are logged every 15 seconds with monotonic elapsed time. Log files are writable after the first device unlock, including while subsequently locked. No heart-rate samples are written to that log.

Diagnostic Watch sessions are **discarded**, not saved to Health/Fitness. Cadence coaching, history recording, coordinated Watch playback controls, and Strava integration are not available yet.

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
6. Tap **Reduce load to 0 W and stop** and verify the log shows target payload `05 00 00` acknowledged before stop payload `08 01` is issued/acknowledged. Observe reduced resistance. On the tested KICKR firmware 3.5.37, the user observed little resistance at 0/20 W (roughly 30 W measured while pedaling); FTMS stop alone had no apparent physical effect. A 0 W target does not guarantee zero resistance or zero measured power. Disconnecting is not a load-release command.
7. On iPhone, tap **Enable Watch diagnostic mirroring** and authorize HealthKit. Start the diagnostic in the CadenceCore Watch app. Check live HR on both devices; lower your wrist and verify it continues. End/discard afterward.
8. If manual control is working, send an initial target/start, choose **4 minutes**, then explicitly arm the background test. Fresh trainer telemetry and support for 0 W are required. Disconnect the Mac/debugger, lock iPhone, and ride only if those targets are appropriate for you. With ongoing telemetry, completion requests 0 W first and then stop. To end early, use **Reduce load to 0 W and stop**. Repeat with another app open. Export logs after each run. The short test checks transitions and automatic finish; retain the 20-minute option for longer continuity checks.
9. Check scheduled command issue/acknowledgment timestamps at the one-minute transitions (five minutes for the extended test) and power tracking after settling. The timing gate is commands issued within two seconds of their expected steady-interval boundary, not instantaneous watt matching.
10. Test disconnects, Bluetooth off/on, and unexpected interruptions. Confirm the UI reports uncertain trainer state rather than false success.

**Limits:** The test depends on ongoing trainer telemetry. If notifications stop, the app is force-quit, the phone shuts down, or the connection is lost, continued control and reduced-load/stop delivery cannot be guaranteed. The trainer may keep its last ERG target. A reconnect does not automatically resume the test. Even if 0 W succeeds and stop fails, the UI reports unconfirmed state rather than a completed stop. Stop pedaling if you need to end the ride; this diagnostic is not a safety interlock.

The short locked-screen stage/automatic-finish test has passed on the user's trainer; longer continuity/interruption testing remains outstanding. Library/import development can proceed independently, but full workout operation must still pass end-to-end device acceptance.

## Strava

The eventual MVP uses TCX export and manual Strava website upload. Strava's native Apple Health importer excludes custom-app recordings; using a custom Watch app does not make them Apple Workout recordings.
