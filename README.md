# CadenceCore

Native iPhone + Apple Watch ERG training app with **ZWO imports, Watch-first Health recording, cadence coaching, simulated travel, interrupted-ride recovery, local history and manual TCX export**.

The original app icon combines a teal **C** with a power/heart-rate pulse on a dark background. Matching opaque 1024-pixel icons are included in the iPhone and Watch asset catalogs; the operating system applies its own rounded or circular mask.

The agreed MVP is implemented in software. The user previously confirmed trainer playback, Watch start/pause/resume/finish, a single Health/Fitness save, and consecutive rides. The newly added recording details, cadence guidance, history/export and crash recovery still require the real-device acceptance round below. Supported HealthKit metrics are collected when available; proprietary Apple Workout features, arbitrary ring credit and automatic Strava sync are not promised.

## Workout library

The **Workouts** tab supports Files-based ZWO import, original example workouts, name search, favorites, local SwiftData persistence, rename, duplicate, and confirmed deletion. Open a workout for a single setup flow: **training targets → trainer → start your ride**. Enter your FTP (1–2000 W) there or in Settings to see interval watt targets alongside % FTP, a power-profile chart, and an accessible interval-list alternative. FTP and simulation preferences share one observable configuration owner and existing persisted keys; a ride keeps an immutable snapshot.

The FTP number pad has an inline **Done** button to dismiss it; scrolling also dismisses it interactively. No FTP default is assumed.

## Guided setup and navigation

- **Workouts** is the library and guided setup; **Ride** contains current controls and interrupted checkpoints; **History** contains ride summaries, separate local/Health save states and TCX sharing; **Settings** groups training preferences, devices and troubleshooting.
- **Find my trainer** requests Bluetooth/discovery in context. Choose your trainer once; later explicit searches reconnect only its remembered identifier, never an arbitrary nearby trainer. Search and connection attempts are bounded to 12 seconds and cancellable. Change trainer is allowed only when no ride/test or acknowledged trainer activity is active.
- **Prepare trainer**, or **Prepare ride on Watch**, checks connection, verified FTMS power capabilities/range, control subscription, acknowledged control, idle command/stop flow and telemetry no older than three seconds. Preparation requests control automatically when capabilities are ready, but sends no target/start command. Pedal briefly when fresh measurements are requested.
- Watch preparation first checks the trainer, then requests Health permissions if needed. **Queued** and **delivered** are distinct: open the Watch app and wait for its delivery acknowledgment before starting. Restaging updates the next-ride snapshot, not an active ride. An active Watch HR diagnostic must be ended/discarded before a recorded ride.
- Low-level tests and **Reduce load to 0 W and stop** remain under **Settings → Diagnostics and exportable log**. They are not prerequisites. iPhone-only playback is a secondary option: it saves locally and exports TCX, but has no Health recording or Watch heart rate.
- Paused/interrupted rides expose trainer preparation within **Ride**. Restoring connection/checkpoints never automatically resumes ERG. Explicit Watch reconnection can continue the same recovered Health session after matching iPhone recovery; unconfirmed or unavailable recordings must be ended locally and reviewed.
- Watch start errors include the operation, localized message and error domain/code. Last error text remains in Watch troubleshooting and, when reachable, iPhone Settings. Watch waits up to eight seconds for prepared/ended lifecycle transitions instead of immediately starting mirroring or reusing a finishing session. An unconfirmed end keeps the local-end escape hatch rather than silently claiming cleanup.

The user confirms that guided preparation, starting a short ride on Watch, finishing/saving, and then starting a second ride work on the actual devices after this milestone. This closes the reported startup acceptance blocker for that sequence; the original error's exact cause was not captured. It does not verify long-duration/interruption behavior, full native Indoor Cycle metric parity or simulated Health sample completeness. If startup fails again, share the displayed operation/domain/code. Existing Health-session recovery is now implemented conservatively, but crash/radio-loss acceptance is still outstanding.

Supported UTF-8 cycling ZWO blocks:

- `SteadyState`: `Duration`, `Power`, optional `Cadence`.
- `Warmup`, `Cooldown`, `Ramp`: `Duration`, `PowerLow` (start), `PowerHigh` (end), optional `Cadence`.
- `IntervalsT`: integer `Repeat`, `OnDuration`, `OffDuration`, `OnPower`, `OffPower`; optional `Cadence` for work phases and `CadenceResting` for recovery. Work cadence is not copied to recovery.

Power values are fractions of FTP, from 0 to 3. Durations must be 0.1 seconds or greater. Limits: 1 MiB input, six hours expanded duration, 2000 expanded intervals, 1000 repetitions per block, 16 XML nesting levels, cadence 1–250 rpm. DTD/entity declarations, non-cycling sports, unsupported executable blocks and behavior-changing attributes are rejected explicitly. Metadata is retained for name/description; unknown top-level metadata produces warnings. Supported `textevent` instructions are shown in preview and during their active-time window on both devices. Cues in an `IntervalsT` block occur once at the block-relative offset, not once per repetition. Unsupported cadence attributes remain explicit errors/warnings rather than being guessed.

Imports retain their original source bytes locally. Import/persistence errors are visible and failed mutations roll back. No in-app interval editor or calendar is included.

## iPhone ERG playback

1. Close other trainer-controlling apps. Open a workout, enter FTP and choose your KICKR in its **Trainer** setup section.
2. Review the profile/warnings and expand **Ride without Watch recording**, then confirm **Start iPhone-only ride**. Preparation acquires trainer control and requires fresh telemetry before playback. The player validates the loaded interval values and trainer range before sending any workout command.
3. The initial target must be acknowledged before start is sent; timing begins only after start is acknowledged. Workouts use an immutable name/interval/FTP snapshot, so library edits do not alter an active ride. Targets are rounded to supported trainer increments without exceeding the supported range.
4. The live ride shows active time, interval/remaining time, scheduled power, actual measured power/cadence, and fresh mirrored Watch HR when a separate diagnostic HR session is running. **Scheduled target** is the interval plan, not a claim about actual applied resistance during pause/finish.
5. **Pause and reduce load** freezes active time and queues the acknowledged 0 W then stop sequence behind any pending command. Resume is enabled after that sequence completes, requires fresh telemetry/control and the same trainer power range, restores the scheduled target, then starts. Paused and start-handshake time are excluded.
6. Automatic completion and confirmed **Finish workout** request the same reduced-load sequence. The player does not claim completion until both acknowledgments arrive. **Current ride** in the library lets you return to controls after navigating away.

Diagnostic target/start/test controls are blocked while the player owns the trainer, including while paused/interrupted. The explicit diagnostic reduced-load stop remains available and finishes the active workout. Disconnect, rejection, malformed control response, write failure, or timeout freezes playback with a visible reason. A gap longer than three seconds between serviced telemetry callbacks also freezes the last confirmed active time and requests reduced load when control is available; it does not silently skip intervals or auto-resume. A best-effort watchdog checks stale telemetry while the app is scheduled; it is not a background execution guarantee or hardware safety interlock. BLE telemetry callbacks own progression, not the UI refresh timer.

After an interruption, reconnect/reacquire control as necessary and resume explicitly, or retry finish. **Force-quit/relaunch loses ride progress and may leave the last target on the trainer.** The user reports workout playback, pause, resume, and finish work on the actual KICKR. This establishes basic functional acceptance, not measured ramp/boundary timing, automatic completion, long-duration continuity, or interruption recovery. Locked-screen general playback remains unverified; the earlier locked-screen test covered the diagnostic schedule only.

**Start iPhone-only ride** does not save to Health or include Watch controls. A separate Watch HR diagnostic can still display HR for that option, and must be ended/discarded on Watch.

## Watch controls and Health recording

1. Rebuild/install **both** apps. Close Apple's Workout and any other workout/trainer apps; CadenceCore Watch owns one HealthKit workout, and iPhone owns trainer control.
2. In **Workouts**, open a workout, enter FTP, choose your trainer, review warnings and choose **Prepare ride on Watch**. Confirm sending, allow Health permissions if prompted, and wait for **Ready on Watch**. Preparation automatically acquires trainer control. Sending stages the immutable workout snapshot; it does not change trainer resistance.
3. Open CadenceCore on Watch, allow its Health permissions, and tap **Start workout**. Workout-write permission is required; missing optional power/cadence/energy sharing is shown explicitly. Watch prepares/mirrors its session before asking iPhone to start the trainer. The existing acknowledged target/start sequence still gates execution. Watch starts Health collection only after receiving the running state.
4. Watch shows HR, scheduled/measured watts, cadence, active time and interval remaining, plus **Pause**, **Resume**, and confirmed **Finish and save**. Requests have ride/command identities and retries reuse the same identity. Watch does not claim a paused/resumed/completed trainer state merely because a message was sent. iPhone **Current ride** controls remain available.
5. After iPhone confirms 0 W then stop, Watch ends collection and calls HealthKit's `finishWorkout` once. A successful result is an indoor cycling workout in **Health/Fitness**, with Watch HR/energy when available and measured trainer power/cadence when permission/data allow. Trainer sample windows skip stale/duplicate data and do not bridge pauses or gaps longer than three seconds. Configured simulation can add labeled speed/distance; no GPS is added.
6. Watch queues the save result back to iPhone using WatchConnectivity, because ending HealthKit automatically ends mirroring. A delayed save receipt is not a delayed trainer command; duplicate last-result receipts are ignored. Last save-result text is retained locally, not a full ride history.

Watch HR and trainer measurements become unavailable/stale rather than zero. Live snapshots are sequenced and throttled independently of SwiftUI redraws; telemetry callbacks still drive ERG. Heartbeats also refresh paused/interrupted/completed state while Watch waits for finish/save.

A live Watch-link gap longer than eight seconds freezes iPhone playback and requests reduced load when iOS can run and trainer control remains available. Watch pauses local recording on a stale/disconnected link. These are best-effort guards, not guarantees after app termination or radio loss. Resume is explicit; a broken HealthKit mirrored session cannot be reused as though still connected. After a lost link, use iPhone to finish/reduce load and Watch **End locally** if needed. Local end/save explicitly records that trainer stop was not confirmed.

Health save errors are visible; saves are not automatically retried after an ambiguous failure to avoid duplicates. A prepared ride ended before collection starts is discarded, not saved as an empty workout. Watch is the sole saver; iPhone never creates a second Health workout. There is no crash recovery or durable ride/sample checkpointing yet. Do not force-quit either app during a ride. If iPhone is relaunched after staging, resend the workout; a stale Watch start is rejected, not applied to another ride.

If the trainer has finished but a Watch save receipt cannot arrive, iPhone **Release Watch coordination** is a confirmed escape hatch. It does not promise a save or end Watch recording; end any active Watch session before starting another. In ordinary use, wait for the save result instead.

### Short device acceptance

Choose an appropriately easy workout and test a brief Watch-started ride. Verify start/HR on both devices (including wrist lowered), pause freezes active time and reduces load, resume restores the scheduled target, and **Finish and save** shows a Health workout exactly once. Check duration, pause exclusion, HR, and available power/cadence in Health/Fitness; permission-denied or missing streams are not fabricated. Export the diagnostic log if trainer state differs from the UI. Locked-screen continuity and interruption scenarios remain separate acceptance checks.

Saving to Apple Fitness does **not** make Strava automatically import this third-party workout through its native Apple Health importer. Manual TCX export remains a future milestone.

### Recording completeness and comparison

Watch explicitly collects supported **active and resting energy** through HealthKit's live data source, alongside heart rate. Watch displays active/total kcal; iPhone shows the last mirrored average/maximum HR and energy summary for the coordinated ride. Total energy is shown only when both components exist, never inferred from trainer watts or replaced with zero. Denied sharing is reported; availability depends on Watch/HealthKit and permissions. These are Apple estimates, not a promise of identical native calories, zones or ring credit.

Open **Settings → Inspect Health recording**, or **Inspect saved Health data** after a Watch ride:

1. Tap **Load recent cycling workouts** and allow the read types you want to inspect. This is an explicit, read-only request; it does not start a ride, change trainer load, write another workout or automatically share data.
2. Choose your ride and optionally a separate native Indoor Cycle reference of similar duration/effort. The list contains the latest 10 accessible cycling workouts within 30 days, identified by source/time; indoor metadata is reported rather than assumed.
3. Tap **Inspect saved data**. Reports show source/identity, start/end, Health active duration, pause/resume event counts, HR average/maximum, active/resting/total energy, power/cadence, cycling speed/distance, accessible sample counts and timestamp coverage.
4. Newly saved CadenceCore rides include the final iPhone active time and expected simulated distance in metadata, plus inclusion/stop-confirmation/warning flags. Inspection reports the Health-duration difference and checks saved distance within **1 m** of the expected aggregate. Mirroring/lifecycle latency can affect duration; local-end saves may contain only the last received iPhone total.
5. Compare against Fitness separately for presentation, Activity credit and native HR zones. The app does not recreate proprietary zones/calculations or spoof Apple's native source.

Missing samples mean **no accessible data**, not necessarily zero or failure: Health read-denial status is intentionally private and Watch sync can take time. Reload after sync. Queries inspect at most 10,000 samples per metric and explicitly mark truncation; coverage unions timestamp spans without filling gaps and is not proof of continuous sensor quality. Simulation's one aggregate distance sample spans the workout but contains only active fresh-telemetry distance, so its timestamp coverage must not be interpreted as travel during pauses.

The optional **Share recording report** action shares only the visible summary text, including workout UUID/times/source/health summaries. Review it first; there is no automatic upload, raw-sample export or background collection by this inspector.

This milestone makes supported recording inspectable; **full native Indoor Cycle parity remains pending device comparison**. Test a newly saved ride with a pause, simulation inclusion and one Health save, then inspect it and a native reference. Verify energy availability, pause events/duration, power/cadence/speed samples and the distance check. Repeat with simulation Health inclusion off; no simulated samples should appear. Permission denial must remain explicit rather than fabricated.

## Simulated speed and distance

Open iPhone **Settings** to configure **Ride simulation**, then confirm setup. Simulation is off until configured; rider mass has no default and is not read from Health. Model settings persist locally. Updating/turning off settings affects the next ride or next **Send to Watch**, never a staged/active ride's snapshot.

Enter rider mass (20–300 kg) and bicycle mass (1–50 kg, default 10). Advanced editable assumptions are drag area CdA (0.1–1 m², default 0.32), rolling resistance coefficient (0.001–0.03, default 0.005), air density (0.5–2 kg/m³, default 1.225), and drivetrain efficiency (0.5–1, default 0.97). Every value must be finite and within the displayed range. Numeric keyboards have **Done** and interactive scroll dismissal. Invalid stored settings produce a visible reconfiguration warning, not silent defaults.

Model v1 solves the flat-road steady-state balance in SI units:

```text
measured watts × efficiency =
  (rider kg + bicycle kg) × 9.80665 × rolling coefficient × speed m/s
  + 0.5 × air density × CdA × (speed m/s)³
```

A bounded 60-step bisection finds nonnegative speed; distance uses trapezoidal integration between fresh monotonic trainer callbacks and is clipped to active workout time. Nonpositive power yields zero speed; missing/invalid power or telemetry, pause, finish, disconnect and interruption break the integration window. Gaps over three seconds and duplicate/replayed timestamps add no distance. No values are calculated from ERG target watts. No acceleration/coasting, grade, wind, drafting or virtual route is simulated, and trainer commands do not change.

iPhone owns the model/accumulator and shows **Simulated speed** (km/h) and **Simulated distance** (km) on the ride screen, retaining the final total until another ride/app restart. Watch receives timestamped estimates and hides stale/paused speed, while retaining accumulated distance. These are estimates of flat-road travel, not actual outdoor distance or trainer flywheel speed.

**Save simulated speed and distance** is on by default when you explicitly confirm setup, with an opt-out:

- Watch requests cycling speed/distance sharing only when enabled. Missing authorization and failed sample writes are visible; live simulation can still run.
- Fresh cycling-speed samples are added to the single Watch-owned workout alongside measured power/cadence. Speed samples are not backfilled across mirrored gaps.
- At finish, one **aggregate cycling-distance sample** uses the final iPhone total. Its interval spans the recording, but its quantity contains only integrated active fresh-telemetry distance; it does not assign distance to paused/missing periods. This avoids undercounting or duplicate distance from dropped/replayed mirrored speed packets. Local end after a broken link uses only the last received total, so it may be lower than iPhone's final total.
- Sample/workout metadata explicitly mark simulation, model version, parameter snapshot and measured-power provenance. Health/Fitness may display distance without preserving a prominent “simulated” label. Neither GPS nor Watch-estimated speed/distance is included.
- With inclusion off, no simulation samples are saved to Health. iPhone-only playback still does not save any workout.

After rebuilding **both apps**, configure simulation, resend a workout and try a short Watch ride. Check fresh speed/distance on both devices, unchanged distance during pause, and one saved workout after finish. Compare saved cycling distance in Health with iPhone's final simulated total (within 1 meter before UI rounding); verify cycling-speed samples and absence of GPS. Also verify opt-out and denied permissions. Actual-device Health/Fitness presentation remains unverified by simulator builds.

The desired recording baseline is Apple's native Indoor Cycle: duration/pause events, HR, supported energy and summaries, plus measured trainer metrics and simulated speed/distance. The inspection workflow above supports this comparison; actual-device availability and proprietary Fitness presentation remain acceptance tasks. Missing values are not fabricated.

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

Diagnostic Watch sessions are **discarded**, not saved to Health/Fitness. Coordinated Watch-started rides save to Health, with configured optional simulated speed/distance. Cadence coaching, history/checkpoint recovery and Strava export are not available yet.

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
7. On iPhone, tap **Prepare Watch connection** and authorize HealthKit. Start **HR diagnostic** in the CadenceCore Watch app. Check live HR on both devices; lower your wrist and verify it continues. End/discard afterward.
8. If manual control is working, send an initial target/start, choose **4 minutes**, then explicitly arm the background test. Fresh trainer telemetry and support for 0 W are required. Disconnect the Mac/debugger, lock iPhone, and ride only if those targets are appropriate for you. With ongoing telemetry, completion requests 0 W first and then stop. To end early, use **Reduce load to 0 W and stop**. Repeat with another app open. Export logs after each run. The short test checks transitions and automatic finish; retain the 20-minute option for longer continuity checks.
9. Check scheduled command issue/acknowledgment timestamps at the one-minute transitions (five minutes for the extended test) and power tracking after settling. The timing gate is commands issued within two seconds of their expected steady-interval boundary, not instantaneous watt matching.
10. Test disconnects, Bluetooth off/on, and unexpected interruptions. Confirm the UI reports uncertain trainer state rather than false success.

**Limits:** The test depends on ongoing trainer telemetry. If notifications stop, the app is force-quit, the phone shuts down, or the connection is lost, continued control and reduced-load/stop delivery cannot be guaranteed. The trainer may keep its last ERG target. A reconnect does not automatically resume the test. Even if 0 W succeeds and stop fails, the UI reports unconfirmed state rather than a completed stop. Stop pedaling if you need to end the ride; this diagnostic is not a safety interlock.

The short locked-screen stage/automatic-finish test has passed on the user's trainer; longer continuity/interruption testing remains outstanding. Library/import development can proceed independently, but full workout operation must still pass end-to-end device acceptance.

## Cadence guidance and intensity

Settings contains editable advisory ranges: at most 75% FTP, 75–90 rpm; over 75% through 100%, 80–95 rpm; above 100%, 85–100 rpm. Explicit ZWO cadence takes precedence, including low-cadence drills. Guidance smooths fresh cadence, gives interval/resume grace, uses hysteresis, and suppresses feedback during pauses, stale data and no pedaling. These are suggestions, not scientifically individualized optima, and never change ERG power.

Gentle Watch haptics are opt-in, require sustained deviation and are limited to one per 30 seconds. The iPhone ride dashboard and secondary Watch controls allow 50–150% session intensity. Every adjusted target is validated against trainer limits; FTP and the workout snapshot stay unchanged.

## History, recovery and Strava

Rides save to app-private, protected, atomic per-ride JSON files with a small manifest. Telemetry is sampled at up to 1 Hz and checkpoints flush every five seconds and on state changes; completed rides are not rewritten while another ride records. Limits are 100 rides, 21,600 samples per ride, 2,048 events and 128 MiB of referenced history. Limits and corruption produce visible errors, not silent trimming. Initial persistence failure blocks trainer start; a mid-ride failure offers **Retry local save**.

Each archive preserves workout/FTP/intensity, trainer identity, simulation/cadence policy, pause/interruption events, measured telemetry and independent Health save receipt. Fresh Watch heart-rate readings are aligned once to a trainer sample within three seconds; original reading timestamps are retained, and missing data is not interpolated. Final simulated distance is captured at the state boundary, even without another telemetry sample.

After relaunch, use **Ride → Recover this ride**, explicitly connect the original trainer, then resume. Recovery may replay up to the five-second checkpoint window; it never credits the termination gap. For a recovered Watch ride, use **Reconnect existing ride** on Watch only after iPhone recovery/preparation. The existing Watch session stays paused until iPhone confirms running. A last confirmed Watch distance can preserve a newer known simulation total without inventing travel in the gap.

If Watch recovery finds an attempted but unconfirmed Health save, **Check saved workout** reconciles by the ride's stable external UUID. It never automatically calls finish/save again. Review Health and end the existing recording locally when reconnection is unavailable. **End local checkpoint** only closes local history: it does not reduce trainer resistance, stop Watch recording, or confirm Health saving.

Completed History details offer **Export TCX**, a simulation inclusion toggle and native sharing to Files. Export remains available if Health saving fails. TCX contains measured power/cadence/heart rate, UTC timestamps, active duration, available energy and optional clearly disclosed simulated speed/distance, with separate tracks at pauses and gaps. No GPS, target watts masquerading as measurements, missing trackpoint zeros or inferred calories are inserted. Mandatory TCX Lap zero placeholders are disclosed in Notes. Empty measured rides cannot export. Re-export uses a stable activity identity/file URL.

Upload the TCX manually at `https://www.strava.com/upload/select`. Automatic sync is excluded: Strava's native Health importer excludes custom-app recordings. A repeated manual upload may be rejected as a duplicate; it is not an automatic-upload retry. The external service may not retain simulation labels.

### Remaining real-device acceptance

1. Install both updated targets. Import a ZWO through Files/Open in CadenceCore, relaunch, and confirm library/search/favorites.
2. Set FTP, rider mass/simulation consent and cadence preferences. Use **Five-Minute Ride Check** for a short Watch-started ride; pause/resume, adjust intensity, finish/save, then repeat a second ride.
3. Check one Health/Fitness workout per ride, supported heart rate/energy/power/cadence, active timing and simulated speed/distance. Use **Settings → Inspect Health recording** to compare actual accessible samples with a native Indoor Cycle reference; permissions/sync may hide data.
4. Export a TCX from History with simulation on/off, save/share it, and manually upload once to Strava. Inspect parsed power, cadence, heart rate, active time and simulated distance; do not assume an upload has been verified yet.
5. Test comfortable explicit ZWO cadence drills, guidance-disabled and haptics-on modes; verify suggestions do not alter power.
6. Test app switching, locked iPhone, wrist lowering and a longer ride. Then test Bluetooth loss and app relaunch safely: stop pedaling first, recover explicitly, and confirm no termination-gap distance or duplicate Health save.
7. Verify light/dark mode, larger text and VoiceOver on your devices. The Watch separates glanceable metrics from wrist controls on vertically paged screens.

Software validation includes deterministic model/protocol/archive tests, native paired builds, a real system Health-denial/empty-state UI workflow, and TCX validation against Garmin's public TCX v2 and ActivityExtension v2 schemas. Schema validation can be rerun with `CADENCECORE_TCX_SCHEMA=/path/to/local/validation.xsd swift test`; without local schemas that explicitly optional test is skipped.
