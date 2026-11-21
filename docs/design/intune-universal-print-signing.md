# LabelWerk – Intune, Universal Print, Developer ID: Implementation Design

Status: design for implementation, 2026-11-21. Audience: the implementing agents and reviewers.
Repo: `/home/user/Zebra-MacOS-Treiber-Software` (read-only while this was written; no files were changed).

## 0. Decisions in one page

| # | Decision | Why |
|---|---|---|
| D1 | Preference domain = bundle ID **`com.labelwerk.app`** (`Installer/config.env` `BUNDLE_ID`). It is frozen from now on. | Intune "Preference file" and `com.apple.ManagedClient.preferences` key on the domain. Renaming it later breaks profiles, privacy approvals and Intune detection. |
| D2 | Intune app type **"macOS app (PKG)"** (unmanaged PKG), not LOB. | Our pkg is a distribution of 3 components (app, driver with scripts, `--nopayload` cli), so LOB "install as managed" does not apply. The PKG type also accepts unsigned packages until Developer ID exists. |
| D3 | Managed config is parsed and merged by **pure Foundation code in `Sources/LabelWerkKit/Managed/`** (no new SwiftPM target). | It needs `ConnectionDescriptor`/`DiscoveryNetworks` (LabelWerkTransport) and `QueueDefaults`/`LabelTypeQueueNaming` (Core). Kit already depends on both and builds and tests on Linux. Not adding a target keeps `Package.swift` free for chunk 3, so no two chunks edit it. |
| D4 | **Device scope owns the CUPS queues of managed printers.** `lwctl managed apply` runs as root from an Intune shell script and from an optional LaunchDaemon watcher. The app never runs `lpadmin` for managed printers. | Intune users are usually standard users and cannot use `lpadmin`. Queues must exist before anyone logs in. |
| D5 | Universal Print: **feasible as a self-built "Universal Print ready printer" (OEM protocol), not as a supported connector.** We build it as the **"UP-Brücke"**, a root LaunchDaemon `labelwerk-up` on the office Mac. Each published LabelWerk queue (printer or label type) becomes one cloud printer. Jobs arrive as PDF and are printed with `lp` into the existing LabelWerk queue. | Unattended operation is possible with the device certificate and device token, with no user refresh token. The CUPS path already handles PDF, fit-to-label and resume-after-paper-out. Gate: a 1–2 day spike against the real tenant (§B9). If it fails, fall back to B1 (Windows connector VM). |
| D6 | Signing: CI signs, notarizes and staples **only when secrets are present**. Otherwise the current ad-hoc/unsigned behaviour stays exactly as it is. The updater checks pkg signature and Team ID **only if the running app has `LWTeamIdentifier`**. | Nothing changes until the Apple account exists. Once it does, nobody can downgrade to an unsigned pkg through the updater. |
| D7 | On Intune-managed Macs the in-app updater is switched off by policy (`UpdatesEnabled = false`). New versions come as a new pkg uploaded to the same Intune app. | Standard users cannot authenticate the `installer` admin prompt. Intune detection also stays consistent. |

---

## 1. Relevant facts from the codebase (verified by reading)

* State: `PersistenceStore` → `~/Library/Application Support/LabelWerk/state.json` (`PersistedState`: `printers: [SavedPrinter]`, `customStocks`, `preferences: AppPreferences`, history …). Decoding is lenient (`LenientContainer`).
* `SavedPrinter` (App/Model/AppTypes.swift): `id: UUID`, `name`, `descriptor: ConnectionDescriptor`, `modelID`, `resolution`, `language`, `stockID`, `settings: PrintSettings`, `cupsQueueName`, `adoptedQueueNames`, `labelTypes: [LabelType]`, `location`, `accentHue`, `isFavorite`.
* `LabelType` (Core): `id`, `name`, `stockID`, `overrides: LabelTypeOverrides`, `queueName`. Queue naming lives in `LabelTypeQueueNaming` (Core): `queueName(baseQueue:typeName:existing:)` and `description(printerName:modelName:host:typeName:)`.
* `PrintSettings` ↔ CUPS options: `cupsOptions()` and `init(cupsOptions:)` (Core). Semantics are identical to the C filter. `CUPSOptionName.*` holds the `lw*` names. Queue-level `lwResumeOnError`/`lwReprintAfterError` are in `QueueDeviceURI` (Core).
* Queue plans: `QueueDefaults.plan(settings:language:removingStale:resolution:labelSize:maxSpeed:)` and `QueueDefaults.difference` (Core). PPD patching: `QueuePPD`, `PPDFiles` (Kit).
* App queue logic: `CUPSService` (installQueue, ensureLabelTypeQueue, apply …) and `QueueSyncService` (debounced sync, adoption, label-type queues; never prompts for a password in automatic runs).
* lwctl: `install` (`Sources/lwctl/InstallCommands.swift`) creates a queue with `lpadmin`, `--model` works offline, reuses an existing LabelWerk queue for the same device, keeps that queue's settings, and supports `--size`/`--stock`/`--resume`/`--reprint`/`--dry-run`/`--json`. Tests fake `lpadmin`/`lp`/`lpstat`/`lpoptions` through `$PATH` (`Tests/LabelWerkKitTests/LwctlInstallTests.swift`).
* App preferences UI: `Features/Settings/AppSettingsView.swift` (tabs general/printing/advanced/updates/about). Discovery networks: `AppPreferences.extraDiscoveryNetworks`, `NetworkDiscoveryService`, normalised by `DiscoveryNetworks.normalizedUserEntries`. The app writes several UI blobs to `UserDefaults.standard` (keys like `designerTitle…`, discovery sources, label-print state), so managed keys must not collide (§A2: PascalCase reserved names).
* Updater: `UpdateController` (app) and `LabelWerkKit/Update/*`. `UpdateInstaller.shellCommand(pkg:expectedSHA256:)` copies the pkg to a root-only temp dir, checks SHA-256, then runs `installer`. **There is no signature check today.**
* Signing is already wired: `lw_codesign` (common.sh) uses `--options runtime` and `--timestamp` when `DEVELOPER_ID_APP` is set. `build_app.sh` signs from the inside out. `make_pkg.sh` runs `productbuild --sign … --timestamp` when `DEVELOPER_ID_INSTALLER` is set. `Scripts/notarize.sh` does submit, wait, log, staple, spctl, and refreshes `.sha256`. `ci.yml` passes no signing secrets. `step_pkg` passes `--unsigned` when `DEVELOPER_ID_INSTALLER` is empty.
* The pkg's driver `postinstall` skips the setup assistant when `COMMAND_LINE_INSTALL` is set (MDM and `installer` installs). The CLI component links `/usr/local/bin/lwctl` → `/Applications/LabelWerk.app/Contents/Helpers/lwctl`.
* There is no login item (`SMAppService`) and no daemon. The MenuBarExtra exists (`preferences.showMenuBarExtra`).
* Template placeholders in `Installer/Info.plist` are rendered by `lw_render_template` (common.sh). Its fixed key list is `APP_NAME BUNDLE_ID VERSION BUILD COPYRIGHT_YEAR UPDATE_REPOSITORY LW_PKG_ID_*`. Any leftover `@X@` is a hard error.

---

## A. Managed configuration (Intune)

### A1. Delivery

| Channel | How | Where macOS stores it | Read by |
|---|---|---|---|
| **Recommended:** Intune › Devices › macOS › Configuration › Templates › **Preference file**, domain `com.labelwerk.app`, file `Installer/Intune/com.labelwerk.app.intune.xml` (bare `<key>/<value>` pairs, no `<plist>`/`<dict>` wrapper). Device channel. | MDM → `/Library/Managed Preferences/com.labelwerk.app.plist` (root:wheel 0644) | App (`UserDefaults`/`CFPreferences`, forced), `lwctl managed apply` (file), `labelwerk-up` (file) |
| Alternative: Custom profile `Installer/Intune/LabelWerk-Konfiguration.mobileconfig` (`com.apple.ManagedClient.preferences` › `com.labelwerk.app` › `Forced` › `[{mcx_preference_settings: {...}}]`), device or user channel | device: same file. User channel: `/Library/Managed Preferences/<user>/com.labelwerk.app.plist` | App: both. lwctl/labelwerk-up: device file only (documented) |

The app treats a key as managed **only if `UserDefaults.standard.objectIsForced(forKey:)` is true**, so `defaults write` by a user can never inject managed printers. `lwctl` treats the device file as trusted only if it is owned by root and is not group- or world-writable (otherwise exit 2 with a message). `--file` bypasses this check for tests and validation.

### A2. Key schema, version 1

All keys are top level in the domain and named in PascalCase. This set of names is reserved: app code must never write these keys to `UserDefaults`. Unknown keys produce an `info` issue and are ignored. Enumerated values match **case-insensitively** either the CUPS/PPD choice string (`cupsValue`) or the Swift raw value, e.g. `DirectThermal` / `directThermal`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `ConfigurationVersion` | Integer | 1 | Schema version. If it is greater than the version the app supports, the app does **not** touch `Printers` (it keeps the last applied managed printers) and shows a warning issue. Other keys it knows still apply. Additive changes do not bump the version. |
| `ConfigurationRevision` | String | "" | Free text set by the admin (e.g. `2026-11-21a`). Shown under Einstellungen › Verwaltung and in `applied.json`. Not used for logic; fingerprints are. |
| `Printers` | Array<Dict> | – | Managed printers (§A2.1). The key being present, even as an empty array, means "the managed printer set is exactly this". If the key is absent, there are no managed printers. |
| `DefaultPrintSettings` | Dict (§A2.2) | – | Base settings for every managed printer (the printer's own `Settings` are layered on top) and starting settings for printers the user adds. |
| `DiscoveryNetworks` | Array<String> | – | Extra networks for discovery (`10.62.13.0/24`, `10.62.13.1-10.62.13.254`), validated with `DiscoveryNetworks.parse`. Merged with the user's list. |
| `AllowUserDiscoveryNetworks` | Bool | true | If false, the user's `extraDiscoveryNetworks` are ignored and the editor is read-only. |
| `AllowUserPrinters` | Bool | true | If false: no "Drucker hinzufügen", no wizard, no "Hinzufügen" in discovery, and no demo printer. Printers the user added earlier stay but show "Nicht verwaltet". |
| `LockPrinterSettings` | Bool | true | Default for `Printers[].Locked`. |
| `UpdatesEnabled` | Bool | true | If false, the updater never checks, downloads or installs. The menu item and Einstellungen › Updates show "Updates werden von Ihrer IT verteilt." |
| `HiddenFeatures` | Array<String> | [] | Any of `designer`, `terminal`, `tools`, `files`, `network`, `maintenance`, `rfid`, `firmware`, `driver` (sidebar "Treiber & Warteschlangen"), `developerMode`, `demoPrinter`, `universalPrint`. Unknown values produce an issue and are ignored. |
| `SkipOnboarding` | Bool | true if `Printers` is non-empty | Sets `hasCompletedOnboarding`. |
| `LaunchAtLogin` | Bool | – | If forced, the "Beim Anmelden starten" toggle is set and locked (`SMAppService.mainApp`). |
| `AppPreferences` | Dict | – | Forced values for `AppPreferences` fields, using their property names: `pollInterval` (Real), `notificationsEnabled`, `showMenuBarExtra`, `playSounds`, `reduceMotion`, `appearance` (`system`/`light`/`dark`), `autoConnect`, `imageDither`, `confirmDestructiveActions`, `developerMode`, `showDemoPrinter`, `measurementUnit` (`millimeters`/`inches`/`dots`), `automaticNetworkDiscovery`. Each one present is applied and its UI control is disabled with a lock badge. |
| `UniversalPrint` | Dict | – | Bridge settings, read only by `labelwerk-up` and shown read-only in the app: `Enabled` (Bool), `TenantID` (String: GUID or `contoso.onmicrosoft.com`), `ClientID` (GUID), `RedirectURI` (String, default `http://localhost`), `PollIntervalSeconds` (Int 5…300, default 15), `PublishQueues` (Array<String> of CUPS queue names to publish automatically once registered; registration itself always needs an admin sign-in). |

#### A2.1 `Printers[]` entry

| Key | Type | Required | Notes |
|---|---|---|---|
| `ID` | String `[A-Za-z0-9._-]{1,64}` | yes | Stable admin key. Must be unique (case-insensitive). The printer UUID and queue names derive from it, so renaming `Name` never changes them. |
| `Name` | String | yes | Display name in the app and the CUPS description (`-D`). |
| `Host` | String | yes | IPv4/IPv6/hostname, validated like `InstallCommands.isValidHost`. |
| `Port` | Integer 1…65535 | no (9100) | |
| `Model` | String | yes | Catalog ID (`lwctl models`, e.g. `zd421t`) or `generic`. v1 never auto-detects, so `apply` works when the printer is offline at install time. |
| `DPI` | Integer 152/203/300/600 | no | Model default. Checked against the model (`InstallCommands.check`). |
| `Language` | `zpl`/`epl`/`cpcl` | no | Model default. |
| `Location` | String | no | `-L` |
| `QueueName` | String | no | Default `LabelWerk_<ID>` (sanitised with `CUPSService.sanitizedQueueName` rules). Duplicates across printers are an error. |
| `Stock` | String (catalog stock ID) | no | Mutually exclusive with `LabelSize`. |
| `LabelSize` | String `104x76.2mm` / `4x3in` | no | `LabelSizing.parseSize`. It creates a managed custom stock `managed-<w>x<h>mm` (`LabelStock`, `isCustom`, gap 3 mm, `.gap`). |
| `Settings` | Dict (§A2.2) | no | Layered over `DefaultPrintSettings`. |
| `LabelTypes` | Array<Dict> | no | `ID` (same pattern, unique per printer), `Name`, `Stock`/`LabelSize`, `Overrides` (Dict: `LabelTypeOverrides` names `rotation`, `darkness`, `speed`, `mediaTracking`, `mediaType`, `printMode`, `labelTop`, `labelLeft`, `tearOffAdjust`, `mirror`, `negative`, `fitToLabel`), optional `QueueName`. |
| `Default` | Bool | no | System default printer (`lpadmin -d`). At most one printer may set it; more is an error. |
| `Locked` | Bool | no (`LockPrinterSettings`) | If locked: the user cannot change settings, label types, stock or queue. Unlocked: the managed values are only the **initial** values, and re-applied only when their fingerprint changes (§A4.3). |
| `UniversalPrint` | Bool | no (false) | Hint for the bridge: publish this printer's queue and its label-type queues if this Mac is the bridge. |

#### A2.2 Settings dict (`DefaultPrintSettings`, `Printers[].Settings`)

These are friendly keys mapped onto CUPS option names, so the semantics are exactly those of `PrintSettings(cupsOptions:)` and the C filter:

| Managed key | CUPS option | Value type |
|---|---|---|
| `Darkness` | `lwDarkness` | Int 0…30 or `"Default"` (= printer value) |
| `Speed` | `lwSpeed` | Int ips 1…14 or `"Default"` |
| `MediaType` | `lwMediaType` | `DirectThermal`/`ThermalTransfer`/`Default` |
| `MediaTracking` | `lwMediaTracking` | `Gap`/`BlackMark`/`Continuous`/`Auto`/`Notch`/`Default` |
| `PrintMode` | `lwPrintMode` | PPD choice string or rawValue (`tearOff`, `peelOff`, `cutter`, …) |
| `LabelTop`, `LabelLeft`, `TearOff` | `lwLabelTop`, `lwLabelLeft`, `lwTearOff` | Int or `"Default"` |
| `Backfeed` | `lwBackfeed` | `After`/`Before`/`Normal`/`Off`/`Default` |
| `Rotation` | `lwRotation` | 0/90/180/270 |
| `Mirror`, `Negative`, `CalibrateBeforeJob`, `SaveToPrinter`, `SkipBlankLabels`, `CancelJobsBeforePrint`, `StopAtLastElement` | `lwMirror`, `lwNegative`, `lwCalibrate`, `lwSaveSettings`, `lwSkipBlank`, `lwCancelBefore`, `lwStopAtLast` | Bool |
| `Dither`, `Threshold`, `Compression` | `lwDither`, `lwThreshold`, `lwCompression` | `Threshold`/`Ordered`/`Halftone`/`FloydSteinberg`/`Atkinson`/`Stucki`; Int 1…254; `Z64`/`ACS`/`Hex` |
| `CutEvery`, `PauseEvery`, `StopOffset`, `CancelDelayMs`, `MarkOffset` | `lwCutEvery`, `lwPauseEvery`, `lwStopOffset`, `lwCancelDelay`, `lwMarkOffset` | Int |
| `FitToLabel` | `lwFitToLabel` | `Auto`/`Off` |
| `RTC` | `lwRTC` | `JobStart`/`EveryLabel`/`EveryMinute`/`Default` |
| `PowerUpAction`, `HeadCloseAction` | `lwPowerUpAction`, `lwHeadCloseAction` | `Feed`/`Calibrate`/`Length`/`NoMotion`/`ShortCalibration`/`Default` |
| `StartCommands`, `EndCommands`, `LabelStartCommands`, `LabelEndCommands` | `lwStartCmd`… | **Plain text** (ZPL). Encoded internally with `CUPSCommandEncoding.encode` |
| `ResumeAfterError` | queue-level `lwResumeOnError` / `labelwerk://` vs `socket://` | Bool (default true) |
| `ReprintAfterError` | queue-level `lwReprintAfterError` | Int 0…99 (default 1) |
| `CUPSOptions` | any `lw*` | Dict<String,String> expert passthrough, applied last. Keys must be in `CUPSOptionName.all`; others are an error. |

Layering algorithm (pure, `ManagedPrintSettings.resolve`):
`base = PrintSettings.default.cupsOptions()` → overlay `DefaultPrintSettings` → overlay `Printers[].Settings` → overlay `CUPSOptions` → `PrintSettings(cupsOptions:)` → set `resumeAfterError`/`reprintAfterError`. Out-of-range values are clamped by `clamped()` **and** reported as a `warning` issue, so the admin sees that the value was changed.

#### A2.3 Example (also `Installer/Intune/com.labelwerk.app.plist`)

```xml
<key>ConfigurationVersion</key><integer>1</integer>
<key>ConfigurationRevision</key><string>2026-11-21a</string>
<key>UpdatesEnabled</key><false/>
<key>AllowUserPrinters</key><false/>
<key>HiddenFeatures</key><array><string>firmware</string><string>terminal</string><string>developerMode</string></array>
<key>DiscoveryNetworks</key><array><string>10.62.13.0/24</string></array>
<key>DefaultPrintSettings</key>
<dict><key>Darkness</key><integer>20</integer><key>FitToLabel</key><string>Auto</string><key>ResumeAfterError</key><true/></dict>
<key>Printers</key>
<array>
  <dict>
    <key>ID</key><string>lager-tor1</string>
    <key>Name</key><string>Versand Tor 1</string>
    <key>Host</key><string>10.62.13.19</string>
    <key>Model</key><string>zd421t</string>
    <key>DPI</key><integer>203</integer>
    <key>Location</key><string>Lager, Tor 1</string>
    <key>LabelSize</key><string>104x76.2mm</string>
    <key>Default</key><true/>
    <key>Settings</key><dict><key>Speed</key><integer>4</integer></dict>
    <key>LabelTypes</key>
    <array>
      <dict>
        <key>ID</key><string>brille</string>
        <key>Name</key><string>Brillenetikett</string>
        <key>LabelSize</key><string>57x32mm</string>
        <key>Overrides</key><dict><key>darkness</key><integer>25</integer><key>rotation</key><integer>90</integer></dict>
      </dict>
    </array>
    <key>UniversalPrint</key><true/>
  </dict>
</array>
<key>UniversalPrint</key>
<dict><key>Enabled</key><true/><key>TenantID</key><string>contoso.onmicrosoft.com</string><key>ClientID</key><string>00000000-0000-0000-0000-000000000000</string></dict>
```

### A3. Kit module `Sources/LabelWerkKit/Managed/` (pure, Linux)

| File | Contents (public API) |
|---|---|
| `ManagedConfiguration.swift` | `public struct ManagedConfiguration: Equatable, Sendable { schemaVersion, revision, printers: [ManagedPrinter]?, defaultSettingsKeys: ManagedSettingsPatch?, discoveryNetworks: [String]?, allowUserDiscoveryNetworks: Bool?, allowUserPrinters: Bool?, lockPrinterSettings: Bool?, updatesEnabled: Bool?, hiddenFeatures: Set<ManagedFeature>, skipOnboarding: Bool?, launchAtLogin: Bool?, appPreferences: ManagedAppPreferences, universalPrint: ManagedUniversalPrint? }`. Every policy is `Optional`, where `nil` means not managed. `static let supportedSchemaVersion = 1`, `static let domain = "com.labelwerk.app"`, `static let devicePlistPath = "/Library/Managed Preferences/com.labelwerk.app.plist"`. Also `ManagedPrinter { id, name, host, port, modelID: String? (nil = generic), resolution: Resolution, language: PrinterLanguage, location, queueName, stock: ManagedStockRef, settings: PrintSettings (resolved), settingsFingerprint: String, labelTypes: [ManagedLabelType], isDefault, isLocked, publishToUniversalPrint }`, `ManagedLabelType { id, name, stock: ManagedStockRef, overrides: LabelTypeOverrides, queueName: String? }`, `enum ManagedStockRef { case catalog(String), custom(widthMM: Double, heightMM: Double) }` with `func labelStock() -> LabelStock?`, `enum ManagedFeature: String`, `struct ManagedAppPreferences` (optional fields, §A2), `struct ManagedUniversalPrint`. |
| `ManagedConfigurationParser.swift` | `public enum ManagedConfigurationParser { static func parse(_ dictionary: [String: Any]) -> ManagedParseResult; static func parse(plistData: Data) -> ManagedParseResult; static func parse(fileAt: URL, requireRootOwned: Bool) throws -> ManagedParseResult }`. `ManagedParseResult { configuration: ManagedConfiguration, issues: [ManagedIssue], hasErrors }`. `ManagedIssue { severity: .error/.warning/.info, path: String ("Printers[2].LabelTypes[0].LabelSize"), message: String (German) }`. Uses `PropertyListSerialization`, which works on Linux corelibs. Lenient: an invalid printer entry is dropped with an error, and the other printers still apply. `Int`/`Bool`/`Double` are accepted from NSNumber or numeric strings, because Intune admins type strings. |
| `ManagedPrintSettings.swift` | Friendly-key table (§A2.2): `static func resolve(defaults: [String: Any]?, printer: [String: Any]?, path: String) -> (PrintSettings, [ManagedIssue])`, `static func fingerprint(_ s: PrintSettings) -> String` (SHA-256 hex of sorted `cupsOptions()` plus resume/reprint, using Kit `SHA256`). |
| `ManagedIdentity.swift` | `static func printerUUID(managedID:) -> UUID` and `labelTypeUUID(printerManagedID:typeID:) -> UUID`: name-based UUIDs from SHA-256 (RFC 9562 version 8 layout: version nibble 8, variant 10). Namespaces are the strings `"labelwerk.managed.printer:"` and `"labelwerk.managed.labeltype:"`. Also `defaultQueueName(managedID:)` and `labelTypeQueueName(printerQueue:type:)`, which calls `LabelTypeQueueNaming.queueName(baseQueue:typeName: type.id …, existing: [])`, i.e. it uses the **ID** as the slug, so the name is stable across renames. |
| `ManagedReconciler.swift` | Merge planning for the app (§A4) on minimal value types, so it is testable without `SavedPrinter`: `struct ExistingPrinter { id: UUID, managedID: String?, host: String?, port: Int?, isManaged: Bool }`. `static func plan(managed: [ManagedPrinter]?, existing: [ExistingPrinter]) -> [ManagedAction]`. `enum ManagedAction { case create(ManagedPrinter, uuid: UUID); case update(existingID: UUID, ManagedPrinter); case adopt(existingID: UUID, ManagedPrinter) /* user printer with same host:port becomes managed, keeps UUID/history */; case unmanage(existingID: UUID) /* removed from config */ }`. Rules: match by `managedID` first, then by `normalizedHost:port` (`QueueAdoption.normalizedHost`) for unmanaged printers. Several user printers on the same device: the first in list order is adopted, the rest stay unmanaged. |
| `ManagedQueuePlanner.swift` | Desired CUPS state for `lwctl managed apply`: `struct ManagedQueueTarget { queueName, description, location, deviceHost, port, modelID, resolution, language, labelSize: QueueLabelSize?, settings: PrintSettings, fingerprint, enforce: Bool (= locked), isDefault, owner: (printerID, labelTypeID?) }`. `static func targets(for config: ManagedConfiguration) -> [ManagedQueueTarget]` (printer queue plus one per label type, with settings `type.settings(printerSettings:printerStock:stock:)`). `static func reconcile(targets:, applied: ManagedAppliedRecord?, existingQueues: [QueueSnapshot]) -> [QueueOperation]` with `enum QueueOperation { case create(target), reuse(existingName, target) /* existing LabelWerk queue for same device+size, recorded as mapping */, updateDefaults(name, target), keep(name), remove(name) /* only names recorded in applied.json and no longer targeted */, setDefault(name) }`. `QueueSnapshot { name, deviceURI, isLabelWerk, options: [String:String] }`. |
| `ManagedAppliedRecord.swift` | `Codable` record at `/Library/Application Support/LabelWerk/Managed/applied.json` (root:wheel 0644): `{ "schema":1, "revision": "...", "appliedAt": ISO8601, "lwctlVersion": "...", "queues": [{ "printerID": "lager-tor1", "labelTypeID": null|"brille", "queueName": "...", "fingerprint": "...", "createdByManaged": true, "status": "ok"|"failed", "message": "..." }] }`. This is the source of truth for the queue names of managed printers (the app reads it, and falls back to `ManagedIdentity` names). |

No AppKit, no `Process` in this folder. `lwctl` and the app do the I/O.

### A4. App merge semantics (chunk 2)

**A4.1 Reading.** `ManagedConfigurationService` (new, `@Observable`, MainActor) builds `[String: Any]` from `UserDefaults.standard.dictionaryRepresentation()`, filtered to the reserved keys where `objectIsForced(forKey:)` is true, and runs `ManagedConfigurationParser.parse`. It re-reads on launch, on KVO of each reserved key (`UserDefaults` KVO fires for changes made by `cfprefsd`/MDM; `didChangeNotification` does not), on `NSApplication.didBecomeActiveNotification`, and every 15 min as a safety net. It publishes `configuration`, `issues`, `lastChange` and `appliedRecord` (reads applied.json). Changes are debounced by 1 s.

**A4.2 Data model changes (AppTypes.swift).**
```swift
struct ManagedOrigin: Codable, Hashable {
    var managedID: String            // Printers[].ID
    var isLocked: Bool
    var settingsFingerprint: String  // last managed settings applied to `settings`
    var managedLabelTypeIDs: [UUID]  // label types owned by the configuration
    var revision: String
}
// SavedPrinter: + var managed: ManagedOrigin? = nil   (lenient decode, default nil)
```
Managed printers **are** persisted in `state.json`, so history, favourites and the accent colour survive, and the app starts correctly offline. The configuration re-asserts them at every launch.

**A4.3 Reconcile (`AppModel+Managed.swift`, called from `AppModel.init` after `restore()` and on every change).** `ManagedReconciler.plan(...)` → apply:
* `create`: `SavedPrinter(id: printerUUID, name, descriptor: .tcp(host, port), modelID, resolution, language, stockID, settings, cupsQueueName: applied/derived name, location)`, plus label types (`LabelType(id: labelTypeUUID, …, queueName: applied/derived)`), plus `managed`. It is added via `addPrinter(_:connect:)` (autoConnect respected).
* `update`/`adopt`: overwrite `name`, `descriptor`, `modelID`, `resolution`, `language`, `location`, `cupsQueueName`. Overwrite `stockID`, `settings` and the managed label types **if `isLocked` or the fingerprint changed**. User label types on unlocked printers are kept, and their IDs are not in `managedLabelTypeIDs`. Keep `id`, `accentHue`, `isFavorite`, `addedAt`.
* `unmanage`: the printer is **removed** (its queues belong to the device script, which removes them on the next `apply`). History stays. This happens only when the `Printers` key is forced and the entry is gone, or when the `Printers` key is no longer forced (profile removed).
* Custom stocks for `LabelSize` go into a separate, non-persisted `managedStocks: [LabelStock]`. `AppModel.stock(id:)` and `allStocks` include them. They cannot be edited.

**A4.4 Guards (UI and model).** `PrinterSession.isManaged`/`isLocked` (new file `PrinterSession+Managed.swift`).
* `AppModel.removePrinter`: no-op with a toast "Dieser Drucker wird von Ihrer IT verwaltet." Sidebar context menu: "Entfernen" disabled.
* Printer row badge: `lock.fill` with the help text "Verwaltet".
* Locked printers: `PrintPreferencesView` and the Etikettentypen and Stocks editors are read-only, with a banner "Von Ihrer IT verwaltet – Änderungen sind nicht möglich." Printing, status, tools and Nachdrucken stay available.
* `QueueSyncService`: `fingerprint(for:)` returns nil for managed sessions, so there are no `lpadmin` calls, no label-type queue creation and no adoption for their hosts. `labelTypeStatus` for managed types comes from `appliedRecord` ("Angelegt durch Verwaltung", "Fehlt – wird beim nächsten Verwaltungslauf angelegt", "Fehlgeschlagen: …").
* `AllowUserPrinters == false`: hide File › Drucker hinzufügen/installieren, the "Hinzufügen" buttons in Discovery, the wizard entry points and the demo printer.
* `HiddenFeatures`: filter `PrinterSection.available(...)`, `SidebarItem` (designer, driver) and Settings › developerMode. A hidden feature is not reachable through menus or shortcuts either (the command handler checks the same predicate `AppModel.isFeatureHidden(_:)`).
* Preferences: `AppModel.effectivePreferences` = stored preferences overlaid with `ManagedAppPreferences`. `AppModel.preferences` keeps the user's stored values unchanged, so removing the profile restores them. All existing reads of `model.preferences.X` that are managed must go through `effectivePreferences`. Settings controls for forced keys are `.disabled(true)` with `Image(systemName: "lock.fill")` and the help text "Von Ihrer IT festgelegt".
* `NetworkDiscoveryService`: effective networks = `DiscoveryNetworks.normalizedUserEntries(managed + (allowUser ? user : []))`.
* `UpdateController`: `isEnabled` becomes false when `UpdatesEnabled == false`, and `disabledReason` = "Updates werden von Ihrer IT verteilt (Intune)." `start()` does nothing.
* New Settings tab **"Verwaltung"** (visible only when any key is forced): source (device/user profile), `ConfigurationRevision`, number of managed printers, issues list (severity icon, path, message), the last `applied.json` run (time, per queue OK/failed), and a button "Konfiguration anzeigen …" (read-only JSON of the parsed config).
* "Beim Anmelden starten" (Settings › Allgemein): `SMAppService.mainApp.register()/unregister()`, status from `.status`. If `LaunchAtLogin` is forced, the toggle is set and locked. Note: login items for ad-hoc-signed apps work, but approval is tracked by code signature (re-approval after updates until Developer ID). An MDM profile `com.apple.servicemanagement` with a TeamIdentifier rule only works once the app is signed.

### A5. Device scope: `lwctl managed …` (chunk 1)

New file `Sources/lwctl/ManagedCommands.swift`. Commands are registered in `CommandCatalog.swift` and `Commands.swift`.

| Command | Behaviour |
|---|---|
| `lwctl managed show [--file P] [--json]` | Parses (default: device plist) and prints the configuration and issues. Exit 0, or 2 if there are errors. |
| `lwctl managed validate --file P [--json]` | Same as show with a mandatory file, meant for admins checking their XML before uploading. Also accepts the Intune **fragment** format (bare key/values): if parsing fails, it is retried wrapped in `<plist><dict>…</dict></plist>`. |
| `lwctl managed apply [--file P] [--dry-run] [--json] [--no-prune] [--ppd-dir D] [--log FILE] [--quiet]` | Root required unless `--dry-run`. Steps: (1) parse, and refuse to apply `Printers` if there are schema errors on the printer list (exit 2); (2) list queues (`CUPSQueues.list()` plus `lpoptions` per LabelWerk queue); (3) `ManagedQueuePlanner.reconcile`; (4) execute each operation, reusing the refactored install core (below); (5) write `applied.json` atomically (tmp + rename, root:wheel 0644); (6) print a summary (JSON with `--json`). A failed printer does not stop the others. |
| `lwctl managed install-watcher [--interval 21600]` / `remove-watcher` | Writes or removes `/Library/LaunchDaemons/com.labelwerk.app.managed.plist` (root:wheel 0644): `ProgramArguments` = `[/Applications/LabelWerk.app/Contents/Helpers/lwctl, managed, apply, --quiet, --log, /Library/Logs/LabelWerk/managed-apply.log]`, `WatchPaths` = `[/Library/Managed Preferences/com.labelwerk.app.plist]`, `RunAtLoad` true, `StartInterval` = interval, `ThrottleInterval` 60. Then `launchctl bootstrap system …` (`bootout` before replacing). Linux: `--dry-run` only (prints the plist). |

**Exit codes for apply** (they drive Intune retries): 0 = all OK; 1 = at least one queue failed (the others are applied); 2 = invalid configuration or usage; 6 = **no managed configuration on this Mac yet** (Intune retries the script, and the watcher applies it when the profile arrives); 7 = LabelWerk driver not installed (PPD dir missing).

**Install-core refactor (InstallCommands.swift).** Extract the body of `install` after argument parsing into
`static func installQueue(_ request: QueueInstallRequest, dryRun: Bool, json: Bool) async throws -> InstallPlan`,
where `QueueInstallRequest { host, port, model: PrinterModel?, forceGeneric, resolution, language, labelSize: QueueLabelSize?, stock: LabelStock?, name: String?, description: String?, location: String?, replace: Bool, resume: Bool?, reprint: Int?, setDefault: Bool, extraDefaults: QueueDefaults.Plan? (full settings plan to enforce), keepExistingSettings: Bool }`. `install` parses its arguments and calls it, with byte-for-byte the same commands and output (the existing `LwctlInstallTests` must pass unchanged). `managed apply` calls it with `extraDefaults` from `QueueDefaults.plan(settings:…)` when the target is created or `enforce || fingerprint changed`, and otherwise with `keepExistingSettings`. Label-type queues use the same function with `name: target.queueName`, `description:` from `LabelTypeQueueNaming.description`, and the device URI of the printer. `remove` uses the existing uninstall-queue path (only LabelWerk queues, only names recorded in applied.json with `createdByManaged`). Reused pre-existing user queues are never removed; only their mapping is dropped.

**Intune shell script `Installer/Intune/labelwerk-managed-apply.sh`** (Devices › macOS › Shell scripts; run as signed-in user: **No** (root); frequency: every 1 day; retries: 3; under 15 kB):
1. Wait up to 10 min for `/Applications/LabelWerk.app/Contents/Helpers/lwctl` (the pkg may arrive after the script); exit 1 if it is still missing, so Intune retries.
2. `lwctl managed install-watcher` (idempotent).
3. `lwctl managed apply --log /Library/Logs/LabelWerk/managed-apply.log`; pass through exit codes 0/1/2/6/7.
4. Optional block, commented out by default: Local Network allowance for macOS 15.5+ (`defaults write /Library/Preferences/com.apple.network.local-network AllowedEthernetLocalNetworkAddresses -array …`, same for Wi-Fi). This lives in a separate file `labelwerk-local-network.sh`, because it needs a restart and affects all apps.

### A6. Files in `Installer/Intune/` (chunk 1)

| File | Purpose |
|---|---|
| `README.md` | Short English index pointing to `docs/intune/` (German guides). |
| `com.labelwerk.app.intune.xml` | Intune "Preference file" upload format (bare key/value pairs), the example from §A2.3. |
| `com.labelwerk.app.plist` | Same content as a full plist (for `lwctl managed validate`, `defaults import`, and tests). |
| `LabelWerk-Konfiguration.mobileconfig` | Custom profile (`com.apple.ManagedClient.preferences`, Forced, same content). PayloadIdentifier `com.labelwerk.app.managed.preferences`, fixed PayloadUUIDs, `PayloadScope` System. |
| `LabelWerk-Mitteilungen.mobileconfig` | `com.apple.notificationsettings`: `BundleIdentifier com.labelwerk.app`, `NotificationsEnabled true`, `AlertType 1`, `BadgesEnabled true`, `SoundsEnabled true`. |
| `LabelWerk-Hintergrunddienste.mobileconfig` | `com.apple.servicemanagement` `Rules`: a `TeamIdentifier` rule with placeholder `TEAMID` (comment: only after Developer ID), plus `Label` rules for `com.labelwerk.app.managed` and `com.labelwerk.app.upbridge`. |
| `labelwerk-managed-apply.sh` | §A5 |
| `labelwerk-local-network.sh` | Optional (macOS 15.5+). |
| `labelwerk-uninstall.sh` | Intune removal helper: `/Library/Printers/LabelWerk/uninstall.sh --yes --remove-queues` plus `lwctl managed remove-watcher`. |

### A7. Tests (Linux unless noted)

* `Tests/LabelWerkKitTests/ManagedConfigurationTests.swift`: parse the sample plist; every key type including string-typed numbers; unknown keys produce info; schema version 2 makes printers untouched and gives a warning; duplicate `ID`/`QueueName`/`Default` produce errors; `Stock`+`LabelSize` together is an error; invalid host/model/dpi/language; `HiddenFeatures` unknown value gives a warning; the fragment format is accepted by `parse(plistData:)` after wrapping; the root-owned check (temp file chmod 0666 → error).
* `ManagedPrintSettingsTests.swift`: layering order; `CUPSOptions` passthrough wins; out-of-range values are clamped with a warning; commands are base64url-encoded; the fingerprint is stable and order-independent, and changes when one value changes; round trip `resolve` → `cupsOptions()` → `PrintSettings(cupsOptions:)` is equal.
* `ManagedReconcilerTests.swift`: create / update by managedID / adopt by host:port (IPv6, case-insensitive host, default port) / unmanage / two user printers on the same device / UUIDs deterministic across runs.
* `ManagedQueuePlannerTests.swift`: target names (default `LabelWerk_<ID>`, label type `<queue>_<slug(ID)>`, length ≤ 127); reuse of an existing LabelWerk queue for the same device; prune only `createdByManaged`; locked versus unlocked (fingerprint) decides `updateDefaults`; exactly one `setDefault`.
* `LwctlManagedTests.swift` (subprocess, fake `lpadmin`/`lpstat`/`lpoptions`/`lp`/`launchctl` in `$PATH`, `--ppd-dir` with generated PPDs as in `LwctlInstallTests`): `apply --dry-run --json` gives the exact `lpadmin` lines; a real run with fakes gives logged calls plus `applied.json` written to `--state-dir` (hidden test option, default `/Library/Application Support/LabelWerk/Managed`); a second run is a no-op; removing a printer from the config gives `lpadmin -x` for its managed queues only; exit code 6 without a file; exit 2 with an invalid file; `install-watcher --dry-run` plist content. `LwctlInstallTests` unchanged and green (refactor guard).
* `Scripts/tests/test_intune_samples.py`: `plistlib` loads all `.plist`/`.mobileconfig`; mobileconfig structure (PayloadType, PayloadContent › `com.labelwerk.app` › Forced › mcx_preference_settings); the XML fragment wrapped equals `com.labelwerk.app.plist`; the shell scripts pass `bash -n` (and `shellcheck` if present); `labelwerk-managed-apply.sh` is under 15360 characters; `lwctl managed validate` on the sample gives exit 0 (if a built lwctl exists, otherwise skipped).

---

## B. Universal Print connector ("UP-Brücke")

### B0. Feasibility verdict

**Feasible, with caveats; build it behind a spike gate.**
* Microsoft's own connector is Windows-only, and the FAQ answers "No" for Linux/macOS. A Mac **cannot be an official connector**.
* A Mac **can act as a "Universal Print ready printer"** through the documented OEM protocol:
  * registration at `register.print.microsoft.com`;
  * a device token from the printer certificate (unattended, no user refresh token);
  * IPP INFRA (PWG 5100.18) at `print.print.microsoft.com`.
  Microsoft's MIT sample `BadgeReleaseDemo` registers a virtual printer and fetches and completes jobs this way.
* Caveats:
  * It is unsupported as a "connector" (Microsoft support is limited to the OEM protocol).
  * The notification channel is undocumented, so we poll.
  * Label sizes are "limited" in UP.
  * Mac UP clients see such printers only with "Show all printers" ("partially supported").
  * iOS is not supported (do not promise it).
* Each published LabelWerk queue becomes one cloud printer with a fixed label size. The existing CUPS pipeline (PDF → `cgpdftoraster` → `rastertolabelwerk` with fit-to-label → `labelwerk://` backend with resume and reprint) does the printing, so the bridge does not render at all.
* **Fallback B1** (documented in the German guide, no development): a Windows 11/Server VM running the Microsoft connector and Zebra ZDesigner drivers. It is fully supported, including for Mac UP clients.

### B1. Architecture

```
 Windows / Mac (UP app) users ──► Universal Print (tenant) ──IPP INFRA (HTTPS, device token)──┐
                                                                                              ▼
 Office Mac (always on)                                     labelwerk-up (LaunchDaemon, root)
   /Applications/LabelWerk.app/Contents/Helpers/labelwerk-up serve                           │
     ├─ per published queue: Registration (cloud_device_id, cert, key in System keychain)    │
     ├─ DeviceTokenProvider (srv_challenge → RS256 JWT → access token, ~1 h)                 │
     ├─ JobLoop: Get-Jobs(fetchable) → Fetch-Job → Acknowledge-Job → Fetch-Document (PDF)    │
     ├─ CUPSSink: lp -d <LabelWerk queue> -n <copies> -t <title> -U <user> <pdf>             │
     ├─ LocalJobMonitor: IPP Get-Job-Attributes ipp://localhost:631/jobs/<id>                │
     └─ Update-Job-Status (processing/stopped/completed/aborted)                             │
   LabelWerk.app (admin, optional) ── control dir ──► requests/*.json · status.json ◄────────┘
```

### B2. One-time tenant setup (documented in `docs/intune/05-universal-print.md`)

* Create an Entra app registration "LabelWerk UP-Brücke": **single tenant**, platform "Mobile and desktop applications", redirect URI `http://localhost`, **Allow public client flows: Yes** (needed for the device code flow).
* API permissions on **Universal Print** (`da9b70f6-5323-4ce6-ae5c-88dcc5082966`):
  * delegated `Printers.Create`;
  * application `Printers.Read`, `PrinterProperties.ReadWrite`, `PrintJob.Read`, `PrintJob.ReadWriteBasic`;
  * then grant admin consent.
* Optional Microsoft Graph delegated `PrinterShare.ReadWrite.All`, so the app can create the share itself.
* Universal Print portal: switch **Document conversion on** (XPS→PDF for Windows clients). After registering: create a share and grant users or groups access.
* Mac UP app: the admin sets "Show all printers" (otherwise our printers are hidden).
* Roles: whoever registers needs the **Printer Administrator** directory role. Every user who prints needs an eligible licence (Business Premium). Quota: 100 jobs per licence per month, pooled; a job counts once, when it completes.

### B3. Swift module layout (chunk 3)

`Package.swift` additions (chunk 3 owns the file):
```swift
.target(name: "LabelWerkCloud", dependencies: ["LabelWerkKit"], swiftSettings: strictLibrary),
.target(name: "LabelWerkCloudMock", dependencies: ["LabelWerkCloud"], swiftSettings: strictLibrary),
.executableTarget(name: "labelwerk-up", dependencies: ["LabelWerkCloud"], swiftSettings: strictLibrary),
.executableTarget(name: "labelwerk-up-mock", dependencies: ["LabelWerkCloudMock"], swiftSettings: strictLibrary),
.testTarget(name: "LabelWerkCloudTests", dependencies: ["LabelWerkCloud", "LabelWerkCloudMock"]),
// products: .executable(name: "labelwerk-up", targets: ["labelwerk-up"])
// macOS block: LabelWerkApp dependencies += ["LabelWerkCloud"]   (status/control types only)
```
Everything builds on Linux. `#if canImport(FoundationNetworking) import FoundationNetworking #endif` as in `UpdateTransfer.swift`. `#if canImport(Security)` for the macOS crypto and keychain implementations. No external packages.

| Folder/File | Contents |
|---|---|
| `HTTP/HTTPTransport.swift` | `protocol HTTPTransport: Sendable { func send(_ r: HTTPRequest) async throws -> HTTPResponse }` (method, url, headers, body; status, headers, body). `URLSessionTransport` with a 60 s timeout, 300 s for Fetch-Document, no cookies (`httpShouldSetCookies=false`, ephemeral config), HTTPS only except loopback when `UPEndpoints.allowInsecureLoopback`. Redirects: only HTTPS, and the `Authorization` header is stripped on host change (same policy as `UpdateRedirectPolicy`). |
| `UPEndpoints.swift` | `struct UPEndpoints { loginBase = https://login.microsoftonline.com, register = https://register.print.microsoft.com/api/v1.0/register, graph = https://graph.microsoft.com/v1.0, printScope = "https://print.print.microsoft.com/.default", allowInsecureLoopback = false }`, plus `static func fromEnvironment()`: only if `LW_UP_ENDPOINTS_OVERRIDE=<json>` **and** `LW_UP_ALLOW_INSECURE_LOOPBACK=1` **and** every host is a loopback address (`QueueAdoption.isLoopbackHost`); otherwise the defaults. |
| `IPP/IPPTypes.swift` | `enum IPPTag: UInt8` (operation 0x01, job 0x02, end 0x03, printer 0x04, unsupported 0x05, integer 0x21, boolean 0x22, enum 0x23, octetString 0x30, dateTime 0x31, resolution 0x32, rangeOfInteger 0x33, begCollection 0x34, endCollection 0x37, textWithoutLanguage 0x41, nameWithoutLanguage 0x42, keyword 0x44, uri 0x45, charset 0x47, naturalLanguage 0x48, mimeMediaType 0x49, memberAttrName 0x4A). `enum IPPOperation: UInt16` (getJobs 0x000A, getJobAttributes 0x0009, getPrinterAttributes 0x000B, acknowledgeJob 0x0041, fetchDocument 0x0042, fetchJob 0x43, updateJobStatus 0x0048, updateOutputDeviceAttributes 0x0049, createPrinterSubscriptions 0x0016, getNotifications 0x001C). `enum IPPValue { integer(Int32), boolean(Bool), enumValue(Int32), string(String, tag), octets(Data), range(Int32,Int32), resolution(Int32,Int32,UInt8), collection([IPPAttribute]) }`, `struct IPPAttribute { name, values: [IPPValue] }`, `struct IPPGroup { tag, attributes }`, `struct IPPMessage { version (2,0), code: UInt16 (op or status), requestID: UInt32, groups, data: Data }`. |
| `IPP/IPPCodec.swift` | `encode(_:) -> Data` and `decode(_:) throws -> IPPMessage` (RFC 8010: additional values with an empty name, collections with memberAttrName, unknown tags preserved as octets, trailing document data). Limits: 1 MB of attributes; data up to 100 MB. |
| `IPP/INFRARequests.swift` | Builders for the operations above with the mandatory operation attributes `attributes-charset utf-8`, `attributes-natural-language en-us`, `printer-uri ipps://print.print.microsoft.com/printers/{cloudID}` (host taken from `print_svc_url`), `output-device-uuid urn:uuid:{cloudID}`; `which-jobs=fetchable` for Get-Jobs; `job-id`/`document-number=1`; for Update-Job-Status `output-device-job-state` (enum), `output-device-job-state-reasons` (keyword), `output-device-job-state-message` (text). |
| `IPP/PrinterCapabilities.swift` | `func capabilityAttributes(for q: PublishedQueue) -> [IPPAttribute]` for Update-Output-Device-Attributes. Printer group: `printer-make-and-model` ("Zebra ZD421t (LabelWerk)"); `document-format-supported` [`application/pdf`] (URF behind a config flag, default off); `document-format-default` `application/pdf`; `copies-supported` 1…999; `copies-default` 1; `sides-supported` [`one-sided`]; `print-color-mode-supported` [`monochrome`]; `printer-resolution-supported/default` (dpi from PPD); `media-supported` [`custom_lw-<w>x<h>mm_<w>x<h>mm`]; `media-default` same; `media-col-database`/`media-col-default` (`media-size` {`x-dimension` w×100, `y-dimension` h×100 in 1/100 mm}, `media-top/bottom/left/right-margin` 0, `media-source` `main`); `orientation-requested-supported` [3,4]; `printer-state` (3 idle/4 processing/5 stopped); `printer-state-reasons`; `printer-is-accepting-jobs`. |
| `Crypto/DER.swift` | Minimal ASN.1 DER writer and reader (SEQUENCE, SET, INTEGER, BIT STRING, OCTET STRING, NULL, OID, UTF8String, PrintableString, UTCTime/GeneralizedTime, context tags). |
| `Crypto/RSAKey.swift` | `protocol RSAPrivateKey: Sendable { var publicKeySPKI: Data { get }; func signSHA256(_ data: Data) throws -> Data; func exportPKCS1() throws -> Data }`, `protocol RSAKeyFactory { func generate2048() throws -> RSAPrivateKey; func load(pkcs1: Data) throws -> RSAPrivateKey }`. `SecurityRSAKeyFactory` (macOS: `SecKeyCreateRandomKey` RSA 2048, `SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA256)`, `SecKeyCopyExternalRepresentation`). `OpenSSLRSAKeyFactory` (Linux, dev and tests: `openssl genpkey`, `openssl pkeyutl/dgst -sha256 -sign` via `Process` on temp files 0600). |
| `Crypto/PKCS10.swift` | `static func certificationRequest(subjectCN: String, key: RSAPrivateKey) throws -> Data` (DER: version 0, subject CN=<device_id>, SPKI rsaEncryption, attributes [0] empty, sha256WithRSAEncryption). `base64(der)` without PEM headers. `transportKey = base64(SPKI)`. |
| `Crypto/X509Info.swift` | Parse `notBefore`/`notAfter`/subject from a DER certificate (expiry warning). |
| `Auth/DeviceCodeFlow.swift` | `start(tenant:clientID:scope:) -> DeviceCodeChallenge {userCode, verificationURI, expiresIn, interval, message}` (POST `{login}/{tenant}/oauth2/v2.0/devicecode`). `poll(...) -> AdminToken` (POST `/token`, `grant_type=urn:ietf:params:oauth:grant-type:device_code`; handles `authorization_pending`, `slow_down` (+5 s), `expired_token`, `authorization_declined`). `refresh(for scope:)`: exchanges the in-memory refresh token for a Graph token (optional share). **Admin tokens are never written to disk**; they live in memory for the length of one registration session. |
| `Auth/DeviceTokenProvider.swift` | Per registration (actor): `token() async throws -> String` cached until `expires_in − 300 s`. Flow: POST `device_token_url` form `grant_type=srv_challenge&windows_api_version=2.0` → `Nonce`; JWT header `{"alg":"RS256","typ":"JWT","x5c":["<cert b64>"]}`, claims `{request_nonce, grant_type:"device_token", resource: mcp_svc_resource_id, client_id, redirect_uri, iss: cloud_device_id}`, base64url, signed; POST `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&request=<jwt>`. Errors: `invalid_grant` + `device_authentication_failed` → `RegistrationInvalid` (state `needsReregistration`, no automatic re-registration). 401 on IPP → one forced refresh and retry. |
| `Auth/JWT.swift` | base64url, compact serialisation. |
| `Registration/RegistrationClient.swift` | `register(adminToken:, name:, manufacturer: "Zebra Technologies", model:, deviceID: UUID, csr:, transportKey:) -> RegistrationResult`. POST JSON `{name, manufacturer, model, device_id, device_type:"printer", has_physical_device:false, device_capabilities:["print"], preferred_lang:"de-de", certificate_request:{type:"pkcs10", data, transport_key}}` → 202 `{registration_id, interval}` → poll GET `?registration_id=` (202 means wait `interval`, 200 means done; timeout 10 min). The 200 body is decoded leniently into `RegistrationResult {cloudDeviceID, certificateDER, printServiceURL, notificationURL, mcpResourceID, deviceTokenURL, printerClientID?, printerRedirectURI?}`. Errors: `device_already_exists` (we always generate a fresh device_id, so this means a retry with the same ID; show a message), `invalid_registration_id`. |
| `Graph/GraphShareClient.swift` | Optional: `createShare(printerID:, displayName:, allowAllUsers:)` → POST `/print/shares` `{displayName, allowAllUsers, "printer@odata.bind": ".../print/printers/{id}"}`; `deletePrinter(id)` (portal fallback documented). |
| `Bridge/BridgeConfiguration.swift` | `struct BridgeConfiguration: Codable { tenant, clientID, redirectURI, pollInterval, documentFormats, enabled }`. Precedence: managed `UniversalPrint` dict (device plist, via `ManagedConfigurationParser`), then `bridge.json`. |
| `Bridge/BridgeStore.swift` | Files under `BridgePaths.root` (`/Library/Application Support/LabelWerk/UniversalPrint`, overridable with `--state-dir`): `bridge.json` (config + `[Registration {queueName, displayName, cloudDeviceID, deviceID, printServiceURL, notificationURL, mcpResourceID, deviceTokenURL, clientID, redirectURI, certNotAfter, registeredAt, published: Bool}]`, no secrets, 0640 root:admin), `jobs.json` (in-flight and last 200 jobs, 0640), `status.json` (§B5), `requests/` (0770 root:admin), `spool/` (0700 root). Atomic writes. |
| `Bridge/SecretStore.swift` | `protocol SecretStore { func put(_ data: Data, account: String) throws; func get(account:) throws -> Data?; func delete(account:) throws }`, holding the private key (PKCS#1) and certificate under the accounts `key.<cloudID>` and `cert.<cloudID>`. `SystemKeychainSecretStore` (macOS: generic-password items, service `com.labelwerk.app.universalprint`, in `/Library/Keychains/System.keychain` via `SecKeychainOpen` + `kSecUseKeychain`, a deprecated but working API that is the only keychain available to a root daemon without a user session). `FileSecretStore` (Linux/tests, and the macOS fallback if the keychain call fails: `secrets/` root 0700, files 0600). The device token stays in memory only. |
| `Bridge/LocalQueues.swift` | `protocol LocalQueueInspector { func labelWerkQueues() async -> [PublishedQueueCandidate] }` (name, description, deviceURI, labelSize from `lwLabelWidth/Height` defaults or PPD `DefaultPageSize` via `QueuePPD.paperDimension`, dpi via `QueuePPD.resolutionDPI`, model via `QueuePPD.lwModel`, plus queue state and reasons). The implementation uses `lpstat -v`, `lpoptions -p` and `/etc/cups/ppd/<q>.ppd`, parsed with Core `LPOptionsList`/`QueuePPD`. |
| `Bridge/CUPSSink.swift` | `protocol PrintSink { func submit(pdf: URL, queue:, copies:, title:, user:) async throws -> LocalJobID; func state(of: LocalJobID) async throws -> LocalJobState; func cancel(_:) async }`. `LPPrintSink`: `lp -d q -n copies -t title -U user -o lwSource=UniversalPrint file` (parses "request id is Q-123"); state via IPP Get-Job-Attributes to `http://localhost:631/jobs/<n>` (our codec, `requesting-user-name root`), falling back to `lpstat -W all -o q`. |
| `Bridge/JobStateMapping.swift` | CUPS 3/4 → UP 5 processing (`job-queued`); 5 → 5; 6 stopped → 6 stopped plus reasons taken from the queue's `printer-state-reasons` (`media-empty`, `marker-supply-empty` (ribbon), `cover-open`, `paused`); 7 → 7 canceled; 8 → 8 aborted; 9 → 9 completed. |
| `Bridge/BridgeEngine.swift` | `actor BridgeEngine` with one `PrinterWorker` task per published registration. Loop: ensure the token; on start and every 6 h, plus on queue size/state changes, Update-Output-Device-Attributes; Get-Jobs(fetchable) every `pollInterval` (15 s default; 5 s for 2 min after activity; exponential backoff to 5 min on errors); for each new job (not in `jobs.json`): Fetch-Job (attributes: `job-name`, `copies`, `job-originating-user-name`, `document-format`), Acknowledge-Job, Fetch-Document → spool file (refused if the format is not PDF or the size is over 50 MB → Update-Job-Status aborted with reason `document-format-error`/`job-data-insufficient`), `PrintSink.submit`, then delete the spool file, persist the mapping, Update-Job-Status 5. A `JobMonitor` polls local jobs every 3 s and pushes state changes. Final states are reported once. Restart recovery: `jobs.json` entries in `acknowledged` without a local job → Fetch-Document again (if that fails → aborted); `submitted` → resume monitoring. Idempotency: a job ID once in `submitted`/final is never printed again. Cancellation from the cloud: Get-Jobs/Get-Job-Attributes show the job as canceled → `PrintSink.cancel`. Printer offline (queue stopped) → printer attributes `printer-state 5` + reasons; jobs keep waiting (UP aborts jobs not fetched within 3 days). |
| `Bridge/NotificationWatcher.swift` | Experimental, off by default (`--experimental-notifications`): Create-Printer-Subscriptions (`notify-pull-method ippget`, `notify-events job-fetchable`) plus Get-Notifications (`notify-wait true`) on `notification_url`. Polling Get-Jobs stays as a 60 s safety net. Behind a flag because the channel is undocumented. |
| `Control/ControlProtocol.swift` | Shared with the app (§B5): `BridgeStatus`, `BridgeRequest`, `BridgePaths` Codable types. |

`Sources/LabelWerkCloudMock/` (chunk 3):
* `MockUniversalPrintService` (in-memory, deterministic) implements the endpoints of `HTTPTransport`:
  * device code: issues `ABCD-EFGH`; becomes authorised after N polls, or by calling `approve()`;
  * `/register` with 202 → 200;
  * device token: nonce, JWT checked for structure and claims, signature verified with the SPKI from the CSR via the injected `RSAKeyFactory`;
  * `/printers` IPP: validates the mandatory attributes and the Bearer token; job queue simulation `enqueue(pdf:, user:, copies:)`; records status updates; 401 after the token expires.
* `MockHTTPServer`: a POSIX-socket HTTP/1.1 server on 127.0.0.1 (Content-Length bodies only) wrapping the service for subprocess end-to-end tests.
* Executable `labelwerk-up-mock --port 0 --print-port`: writes the endpoint-override JSON to stdout and serves until killed. Test hooks: `POST /_mock/enqueue`, `POST /_mock/approve`, `GET /_mock/events`.

### B4. `labelwerk-up` executable (chunk 3)

Installed as `/Applications/LabelWerk.app/Contents/Helpers/labelwerk-up`. Bundling and signing are done by chunk 5 in `build_app.sh`. German CLI text, in the same style as lwctl.

| Command | Behaviour |
|---|---|
| `labelwerk-up status [--json]` | Reads `status.json`. Works without root for members of the admin group. |
| `labelwerk-up configure --tenant T --client-id C [--redirect-uri U] [--poll S]` | Root. Writes `bridge.json`. Refused if a managed `UniversalPrint` dict is present (managed wins). |
| `labelwerk-up register --queue Q [--name N]` | Root. Interactive: prints "Öffnen Sie https://microsoft.com/devicelogin und geben Sie den Code ABCD-EFGH ein …", then polls, generates a key, creates the CSR, registers, polls, and stores the result. Exit 0, or 1 on failure. `--json-events` emits progress as JSON lines (used by the daemon to serve app requests). |
| `labelwerk-up publish/unpublish --queue Q` | Starts or stops serving a registered queue (`published` flag). |
| `labelwerk-up share --queue Q [--all-users]` | Optional Graph share (needs a fresh admin sign-in with the Graph scope). |
| `labelwerk-up unregister --queue Q [--delete-in-cloud]` | Removes the local registration and secrets. `--delete-in-cloud` sends a Graph DELETE `/print/printers/{id}` after an admin sign-in; otherwise it prints a portal hint. |
| `labelwerk-up serve [--once] [--state-dir D]` | The daemon loop (`--once`: one poll cycle per printer, then exit; used by tests). It also watches `requests/` (every 2 s) and handles `register`, `publish`, `unpublish`, `unregister` and `refreshCapabilities` requests from the app. A registration request runs the device-code flow inside the daemon, and the user code goes into `status.json` for the app to show. |
| `labelwerk-up enable-daemon` / `disable-daemon` | Root. Creates the directories with their modes. Writes `/Library/LaunchDaemons/com.labelwerk.app.upbridge.plist` (`ProgramArguments [.../labelwerk-up, serve]`, `RunAtLoad`, `KeepAlive {SuccessfulExit: false}`, `ThrottleInterval 30`, `StandardErrorPath /Library/Logs/LabelWerk/upbridge.log`, `ProcessType Background`), then `launchctl bootstrap system`, and does the reverse on disable. Idempotent. |
| `labelwerk-up doctor` | Checks connectivity (DNS and TLS to the 4 hosts), token, certificate expiry, queues, and the CUPS PDF filter presence. Prints German results. |

Logging: `os_log` is not available on Linux; use a `Logger` protocol writing to stderr (launchd redirects it to the log file) with ISO timestamps. Never log tokens, codes after approval, or document contents.

### B5. App ↔ daemon control protocol (files)

* Directory `/Library/Application Support/LabelWerk/UniversalPrint/`, root:admin 0750. `requests/` is root:admin 0770; `status.json` is root:admin 0640.
* App (admin user) → `requests/<uuid>.json`: `{"id","created","action":"register|publish|unpublish|unregister|refreshCapabilities","queue":"…","name":"…"}`, written atomically (`.tmp` → rename). The daemon deletes the request when done.
* Daemon → `status.json` (rewritten at most every 2 s and on change):
  * daemon fields: `{"schema":1,"daemonVersion","pid","updatedAt","state":"running|disabled|misconfigured|error","message","tenant","clientID","managed":bool}`;
  * `"printers":[{"queue","displayName","cloudDeviceID","published","state":"registering|waitingForAdmin|active|tokenError|needsReregistration|offline","userCode?","verificationURI?","codeExpiresAt?","lastPoll","lastJob","certNotAfter","message"}]`;
  * `"jobs":[{"id","queue","title","user","copies","received","state","message"}]` (last 50);
  * `"requests":[{"id","state":"pending|running|done|failed","message"}]`.
* Non-admin users cannot read it, so the app shows "Nur Administratoren können die Universal-Print-Brücke verwalten."

### B6. App UI (chunk 4) – Einstellungen › Universal Print

New files: `Features/UniversalPrint/UniversalPrintSettingsView.swift`, `UPDeviceCodeSheet.swift`, `UPPublishRow.swift`, `Services/UniversalPrintService.swift` (`@Observable`, `static let shared`; polls `status.json` every 2 s while visible and every 30 s otherwise; writes requests; runs `labelwerk-up enable-daemon` with admin rights via the existing `ProcessRunner` admin path).

Layout (style as in `AppSettingsView`; all strings through `tr()`):
1. **Card "Universal-Print-Brücke"**:
   * `StatusOrb` + state text: "Nicht eingerichtet", "Dienst aus", "Aktiv – 3 Drucker, letzter Abruf vor 12 s", or "Fehler: …";
   * buttons "Auf diesem Mac aktivieren …" / "Deaktivieren" (admin prompt);
   * hint: "Der Mac muss eingeschaltet und mit dem Internet verbunden bleiben (Energie: Ruhezustand deaktivieren)."
2. **"Microsoft 365"**:
   * fields Mandant (Tenant-ID oder Domäne), Anwendungs-ID (Client-ID), Weiterleitungs-URI;
   * the fields are read-only with a lock when they come from the Intune `UniversalPrint` dict;
   * "Speichern" writes a `configure` request;
   * link "Anleitung: App-Registrierung anlegen …" opens the German guide on GitHub.
3. **"Drucker freigeben"**: a list of LabelWerk queues on this Mac (printer queues and label-type queues, by description, e.g. "Zebra ZD421t – Brillenetikett", with the size "57 × 32 mm"). Per row:
   * not registered → "Registrieren …";
   * registering → spinner;
   * waitingForAdmin → opens `UPDeviceCodeSheet`;
   * active → green "Freigegeben in Universal Print", with a menu "In Universal Print freigeben …" (Graph share, or opens the portal), "Fähigkeiten aktualisieren", "Pausieren", "Entfernen …" (`HoldToConfirmButton`).
4. **`UPDeviceCodeSheet`**:
   * large monospaced user code with "Kopieren" and "Anmeldeseite öffnen" (verification URI);
   * text: "Melden Sie sich mit einem Konto mit der Rolle Druckeradministrator an. Das kann auch an einem anderen Gerät geschehen.";
   * countdown until expiry; closes automatically on success with a `CelebrationBurst`.
5. **"Letzte Aufträge"**: time, user, document, printer, status (Gedruckt / Wartet auf Papier / Abgebrochen).
6. **"Hinweise für Ihre IT"** (collapsible):
   * enable document conversion;
   * create the share and grant access;
   * Mac users: Universal Print app with "Alle Drucker anzeigen";
   * iOS not supported;
   * quota of 100 jobs per licence per month.

Menu bar (`MenuBarView.swift`, chunk 4): a single row "Universal Print · aktiv · 3 Drucker" with a warning colour when any printer is not active. It is hidden if the bridge is not set up or `HiddenFeatures` contains `universalPrint`. The predicate is read from `UniversalPrintService.isHidden`, which chunk 2 sets through a static hook (§E interface I3).

### B7. Background running

* The bridge is a **LaunchDaemon** and runs without anyone logged in, which matters after a reboot. It is not a user login item: the UI is optional.
* Because it runs as root, it is exempt from Local Network privacy (it only talks to the internet and to local cupsd anyway).
* On macOS 13+ Background Task Management shows "LabelWerk" under Anmeldeobjekte › Im Hintergrund erlauben. The MDM profile `LabelWerk-Hintergrunddienste.mobileconfig` (Label rule `com.labelwerk.app.upbridge`, plus a TeamIdentifier rule after signing) keeps users from switching it off.
* The app's own "Beim Anmelden starten" (chunk 2) only matters for menu-bar status.

### B8. Tests (Linux)

* `IPPCodecTests`: round trip of every tag; collections (media-col); additional values; decoding `BadgeReleaseDemo` fixture bytes (copy the hex fixtures into the test, MIT, attributed); malformed input (truncated, oversized length) throws.
* `INFRARequestsTests`: exact bytes for Get-Jobs, Fetch-Job, Acknowledge-Job, Fetch-Document and Update-Job-Status (golden byte arrays); attribute order matches the sample (operation attributes first, output-device-uuid after printer-uri).
* `CapabilitiesTests`: 57×32 mm gives `custom_lw-57x32mm_57x32mm` and `x-dimension 5700`/`y-dimension 3200`; 4×6 in gives `10160`×`15240`; dpi.
* `DERTests`/`PKCS10Tests`: DER encoding; the CSR verifies with `openssl req -verify -inform DER` (skipped if openssl is missing); SPKI round trip.
* `JWTTests`: header and claims; signature verifies with `openssl dgst -verify`.
* `DeviceCodeFlowTests`: pending → slow_down → success; expired; declined.
* `RegistrationTests`: 202 → 202 → 200 against the mock; lenient decoding of optional fields.
* `DeviceTokenProviderTests`: caching, refresh before expiry, a 401 forces a refresh, `device_authentication_failed` gives `needsReregistration`.
* `BridgeEngineTests` (mock service + fake `PrintSink` + `FileSecretStore` in a temp dir):
  * full path: job enqueued → acknowledged → document fetched → submitted with copies, title and user → states 5, 6 (media-empty) and 9 reported in order;
  * crash recovery from `jobs.json`;
  * no duplicate print after a restart;
  * non-PDF is aborted;
  * a cloud cancel cancels the local job;
  * backoff after HTTP 503.
* `ControlProtocolTests`: request pickup, status JSON schema, atomic writes.
* End-to-end in `Scripts/ci_linux.sh` step `test-up-bridge`:
  1. start `labelwerk-up-mock`;
  2. create fake `lp`, `lpstat` and `lpoptions` in a temp `PATH` (a fake `lp` copies the file and prints `request id is LabelWerk_test-7 (1 file(s))`);
  3. `labelwerk-up configure`/`register --queue LabelWerk_test` with `--state-dir`, the env override, and mock auto-approve;
  4. `POST /_mock/enqueue` a PDF;
  5. `labelwerk-up serve --once` twice;
  6. assert that the fake `lp` received the PDF and that the mock events show Acknowledge plus Update-Job-Status 9.

### B9. Spike gate (first task of chunk 3, done manually with a real tenant)

1. Create the app registration (§B2).
2. Run `labelwerk-up register --queue X` on a Mac.
3. Create the share in the portal.
4. Print a PDF from Windows 11.
5. Check that `serve` fetches it and prints it through CUPS.
6. Check that Windows shows "Abgeschlossen".
7. Repeat with the macOS Universal Print app ("Alle Drucker anzeigen").
8. Repeat with a Windows XPS app (document conversion on).

Record which media/size attributes Windows honours. **Go:** steps 1–6 work. **No-go:** registration or device token is refused for in-tenant single-tenant apps, or jobs never become fetchable. In that case, stop B, ship B1 (Windows connector VM guide), and keep chunk 4's UI out (`HiddenFeatures` default).

---

## C. Developer ID signing and notarization (chunk 5)

### C1. Secrets (GitHub › Settings › Secrets and variables › Actions)

| Secret | Content |
|---|---|
| `APPLE_DEVELOPER_ID_APP_P12` | base64 of the .p12 holding "Developer ID Application: <Firma> (TEAMID)" with its private key |
| `APPLE_DEVELOPER_ID_INSTALLER_P12` | base64 of the .p12 holding "Developer ID Installer: <Firma> (TEAMID)" |
| `APPLE_P12_PASSWORD` | the password of both .p12 files (use the same one) |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_NOTARY_API_KEY_P8` | base64 of `AuthKey_<ID>.p8` (App Store Connect › Users and Access › Integrations › Team key, role Developer) |
| `APPLE_NOTARY_API_KEY_ID` | Key ID |
| `APPLE_NOTARY_API_ISSUER` | Issuer UUID |

Repository variable (not a secret) `LW_SIGNING`: `auto` (default) or `required`. `required` makes tag builds (`refs/tags/v*`) fail when signing is impossible. The temporary keychain password is generated at random per run (`openssl rand -hex 24`), so no secret is needed for it.

### C2. Workflow changes (`.github/workflows/ci.yml`, macOS job)

* New step before "App-Bundle": **"Signaturzertifikate einrichten (falls vorhanden)"** runs `Scripts/ci_macos.sh signing-setup` with `env:` mapping all secrets above to the variables of the same name, plus `LW_SIGNING: ${{ vars.LW_SIGNING || 'auto' }}`.
* Step names "App-Bundle (Release, Universal Binary, ad hoc signiert)" → "App-Bundle (Release, Universal Binary, signiert)", and "Installationspaket (unsigniert)" → "Installationspaket".
* New step after "Paketinhalt prüfen": **"Notarisieren (falls signiert)"** runs `Scripts/ci_macos.sh notarize`.
* New final step **"Signaturschlüsselbund entfernen"** with `if: always()` runs `Scripts/ci_macos.sh signing-cleanup`.
* Order: setup … app → pkg → verify-pkg → notarize → install-test/e2e-print → artifacts → release. The release therefore ships the stapled pkg, and `notarize.sh` already refreshes `.sha256`.
* PRs from forks get no secrets, and the macOS job does not run for PRs anyway.

### C3. Script changes

**`Installer/lib/signing.sh` (new, sourced by ci_macos.sh):**
* `lw_signing_available`: true if both P12 secrets, the password and the Team ID are non-empty.
* `lw_signing_setup`:
  1. Create `"$RUNNER_TEMP/labelwerk-signing.keychain-db"` (outside Actions: `$TMPDIR`) with a random password; `set-keychain-settings -lut 21600`; `unlock-keychain`.
  2. Decode the P12s with `base64 --decode` to 0600 temp files; `security import … -P "$APPLE_P12_PASSWORD" -A -t cert -f pkcs12 -k KC` for each; `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" KC`; `security list-keychains -d user -s KC $(security list-keychains -d user | tr -d '"')`.
  3. Detect identities: `security find-identity -v -p codesigning KC` gives the `Developer ID Application: … (TEAM)` line; `security find-identity -v -p basic KC` gives the `Developer ID Installer: … (TEAM)` line. Verify both contain `(${APPLE_TEAM_ID})`.
  4. Write the `.p8` to `$RUNNER_TEMP/AuthKey.p8` (0600).
  5. Export to the following steps via `$GITHUB_ENV` (or print `export …` lines outside Actions): `DEVELOPER_ID_APP`, `DEVELOPER_ID_INSTALLER`, `TEAM_ID`, `NOTARY_API_KEY_PATH`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER`, `LW_SIGNING_KEYCHAIN`.
  6. Delete the decoded P12 files.

  Never `set -x`; secret values are never printed.
* `lw_signing_cleanup`: `security delete-keychain`, restore the search list, `rm -f` the key files. Idempotent.

**`Scripts/ci_macos.sh`:**
* add steps `signing-setup`, `notarize`, `signing-cleanup` to `ALL_STEPS` (not to `DEFAULT_STEPS`, because they need secrets) and to `usage`;
* `step_signing_setup`: if unavailable and `LW_SIGNING=required` and the ref is a tag → `lw_die`; if unavailable otherwise → `lw_ci_warning "Keine Signaturzertifikate – App ad hoc signiert, Paket unsigniert (wie bisher)."` and return 0;
* `step_notarize`: if `DEVELOPER_ID_INSTALLER` is empty, skip with a notice; else `Scripts/notarize.sh "${PKG}"`, then `xcrun stapler staple "${APP}"` (the nested app's ticket was created by the pkg submission), `xcrun stapler validate "${APP}"`, `spctl -a -t exec -vv "${APP}"`; ZIP artifacts are created afterwards from the stapled app;
* `step_verify_pkg` additions, only when signed:
  * `pkgutil --check-signature "${PKG}"` contains `Developer ID Installer:` and `(${TEAM_ID})`;
  * `codesign -dv --verbose=4` on the app, `Helpers/lwctl`, `Helpers/labelwerk-up`, the filters and the backend shows `TeamIdentifier=${TEAM_ID}`, `Authority=Developer ID Application`, `flags=0x10000(runtime)`, and a `Timestamp=`;
  * when unsigned, the existing checks stay unchanged;
* `step_test_swift` target loop: add `LabelWerkCloudTests`;
* `step_setup`: also print "Paket-Signatur: …".

**`Installer/lib/common.sh`:**
* `lw_load_config` derives `LW_SIGNED_TEAM_ID` = `TEAM_ID` if `DEVELOPER_ID_APP` is non-empty, else empty;
* `lw_render_template` key list += `LW_SIGNED_TEAM_ID`;
* new helper `lw_team_id_of_identity "<Developer ID …: Name (ABCDE12345)>"` → `ABCDE12345`, used as the default for `TEAM_ID` when only the identity is given.

**`Installer/Info.plist`:** add `<key>LWTeamIdentifier</key><string>@LW_SIGNED_TEAM_ID@</string>` and document it in the header comment.

**`Scripts/build_app.sh`:**
* bundle `labelwerk-up`: build it with the app (`swift build --product labelwerk-up` for both architectures, `lipo`), copy it to `Contents/Helpers/labelwerk-up`, and sign it with `lw_codesign "…/labelwerk-up" "${BUNDLE_ID}.labelwerk-up"` before the app;
* if the product does not exist (chunk 3 not merged), skip it with a warning;
* after signing with a real identity, `codesign --verify --strict --verbose=2` on every Helpers binary.

**`Scripts/notarize.sh`:** accept `NOTARY_API_KEY_P8_BASE64` as an alternative to `NOTARY_API_KEY_PATH` (decode to a 0600 temp file in `WORK`) for local use. No other behaviour changes.

**`Installer/LabelWerk.entitlements`:**
* **No functional change.** Hardened runtime with no exceptions: no JIT, no unsigned memory, library validation stays on, `automation.apple-events` is not needed (osascript runs as a child process).
* The sandbox device/network keys are inert without the sandbox; keep them.
* `lwctl`, `labelwerk-up`, filters and backend get **no** entitlements (hardened runtime only).
* Add one comment line saying that `labelwerk-up` needs no entitlements.

**`Installer/config.env`:** comments for the new CI variables (`LW_SIGNING`) and the secret names. `TEAM_ID` stays empty in the file (CI supplies it).

### C4. Updater implications

**`Sources/LabelWerkKit/Update/UpdateInstaller.swift`:**
* new parameter `requiredTeamID: String? = UpdateInstaller.bundleTeamIdentifier()`. It reads `Bundle.main.infoDictionary?["LWTeamIdentifier"]`, trimmed; empty or nil means nil. Being a default argument, it needs **no edit in `UpdateController`**.
* If `requiredTeamID` is set, the root shell command checks the **private copy**, after SHA-256 and before `installer`:
  1. `pkgutil --check-signature "$p"`, which must exit 0;
  2. its output contains `Developer ID Installer:` and `(TEAMID)`;
  3. the status line `Status: signed by a developer certificate issued by Apple`;
  4. `spctl --assess --type install "$p"` (notarized/stapled).
  - New exit codes: 4 = not signed or wrong team; 5 = Gatekeeper rejects.
* `Tools` gains `pkgutil` and `spctl` paths, so the Linux tests use fake scripts.
* `UpdateInstaller` error mapping gets German messages for 4 and 5: "Das Update ist nicht mit dem Zertifikat von LabelWerk signiert – es wird nicht installiert."
* **Transition:** the first signed release is installed over unsigned builds normally, because old apps do not check. From then on unsigned or foreign packages are refused. Developer builds without a Team ID keep the old behaviour.

Other effects, documented in `06-signatur-notarisierung.md`:
* after switching from ad hoc to Developer ID, macOS asks once again for the keychain item of the GitHub token ("Immer erlauben"), for Bluetooth/Local Network, and for login-item approval;
* from then on the approvals stick across updates;
* the PPPC/login-item MDM rules can use the Team ID;
* on Intune Macs the updater is switched off by policy anyway (D7).

The installer certificate expires after 5 years. An expired installer certificate stops the pkg from launching unless it is timestamped and notarized, so keep `--timestamp`. Apps keep running after the certificate expires.

### C5. Tests

* `Tests/LabelWerkKitTests/UpdateInstallerTests.swift` (extended): with `requiredTeamID` → the command contains a `pkgutil` check on the private copy, after `shasum` and before `installer`; quoting of a malicious team ID (only `[A-Z0-9]{10}` accepted, otherwise the check fails closed); executed against fake `pkgutil`/`spctl`/`installer` on Linux (the `Tools` injection exists): exit codes 0/4/5; without a team ID the command is byte-identical to today.
* `Scripts/tests/test_signing.py` (new):
  * `bash -n`/shellcheck on `signing.sh`;
  * `lw_signing_available` truth table;
  * `lw_team_id_of_identity`;
  * `lw_render_template` renders `LWTeamIdentifier` empty when ad hoc and `ABCDE12345` when signed;
  * `ci_macos.sh --help` lists the new steps;
  * `signing-setup` without secrets returns 0 with a warning, and with `LW_SIGNING=required` plus a tag ref returns non-zero (run with `lw_is_macos` stubbed, via `LW_CI_PROCESS_ARG` calling the function directly under a fake `security`).
* `Scripts/tests/test_release.py` unchanged and green.

---

## D. German admin guides (`docs/intune/*.md`, chunk 6)

Shared conventions: German (Sie-Form), same terms as the app UI (Einstellungen, Drucker, Etikettentypen, Warteschlange), every Intune path written as a click path "Geräte › macOS › Konfiguration › …", every step with an expected result, plus a section "Fehlerbehebung" and one "Prüfen" with Terminal commands. The guides link to each other and to `docs/INSTALLATION.md`.

1. **`README.md` – Übersicht für Administratoren**
   * What LabelWerk is in a managed setting: the 3 components and what runs as root.
   * Decision matrix: Intune only / Intune + UP-Brücke / Intune + Windows connector (B1).
   * Order of setup with a checklist; licences (Business Premium includes Intune P1 and UP); the support position of the UP-Brücke.
2. **`01-intune-bereitstellung.md` – App und Treiber per Intune verteilen**
   * Prerequisites (Intune agent 2308.006+, ADE/enrolment, user-approved MDM); where to get the pkg (GitHub Releases, `.sha256` check).
   * Apps › macOS › Hinzufügen › "macOS-App (PKG)": name, publisher, pre/post-install scripts (none needed); detection: "Enthaltene Apps" = only `com.labelwerk.app`; "App-Version ignorieren" (yes while the updater is on, otherwise no); assignment Required to device groups.
   * Updating: upload the new pkg to the same app, increment the version; no uninstall assignment exists, use the uninstall script.
   * Unsigned packages before Developer ID: what Intune accepts and what users see (nothing, because `installer` bypasses Gatekeeper).
   * Verification: `pkgutil --pkg-info com.labelwerk.app.driver`, `cat /Library/Printers/LabelWerk/VERSION`, `lwctl version`; Intune logs `/Library/Logs/Microsoft/Intune/`.
3. **`02-verwaltete-konfiguration.md` – Drucker, Etikettentypen und Einstellungen zentral festlegen**
   * Concept (managed versus user printers, "Verwaltet" badge, locked versus unlocked).
   * Profile creation, both ways: Preference file (recommended) step by step, or Custom mobileconfig.
   * **Key reference tables** (all of §A2 in German, with types, defaults and examples); settings key table (§A2.2) with value lists; label types; size notation.
   * Policy keys (UpdatesEnabled, AllowUserPrinters, HiddenFeatures, AppPreferences); versioning and `ConfigurationRevision`.
   * Testing before upload: `lwctl managed validate --file …`; what users see.
   * Changing and removing printers: effects and timing (profile delivery, watcher, script frequency).
   * Fehlerbehebung: Einstellungen › Verwaltung, `defaults read "/Library/Managed Preferences/com.labelwerk.app"`, `lwctl managed show`.
4. **`03-druckerwarteschlangen.md` – Druckerwarteschlangen vor der Anmeldung anlegen (`lwctl managed apply`)**
   * Why a root script (standard users, before login).
   * The Intune shell-script settings: run as signed-in user "Nein", frequency, retries; uploading `labelwerk-managed-apply.sh`; exit code table (0/1/2/6/7).
   * The watcher daemon; the `applied.json` format and its location; reuse of existing queues; what is removed and what is never removed.
   * Manual commands (`--dry-run`, `--json`); logs `/Library/Logs/LabelWerk/managed-apply.log`, `lpstat -v`, `lpoptions -p`.
   * Plain `lwctl install` loops for setups without managed configuration.
5. **`04-datenschutz-und-systemprofile.md` – Datenschutz, Mitteilungen, Hintergrunddienste**
   * Local network: why it cannot be pre-approved (TN3179); which parts are exempt (CUPS backend, root scripts, `lwctl` in Terminal); macOS 15.5+ `AllowedEthernetLocalNetworkAddresses` script with restart; what users see in the app ("Lokales Netzwerk erlauben").
   * Notifications profile; background services/login items profile (Label and TeamIdentifier rules, only after signing); Bluetooth (PPPC, only with signature; deprecated in macOS 27).
   * A table "Was braucht eine Signatur?".
6. **`05-universal-print.md` – Etiketten über Microsoft Universal Print drucken**
   * Options and the recommendation (UP-Brücke vs. Windows connector, the support statement, limits: no iOS, partial macOS, label sizes, quota and how jobs are counted, the 3-day fetch limit).
   * Part A, Entra app registration with exact permissions and IDs, public client flows, admin consent.
   * Part B, office Mac: requirements (always on, energy settings, wired network, LabelWerk queues for the printers/label types); enabling the bridge in Einstellungen › Universal Print, or Intune `UniversalPrint` dict plus `labelwerk-up enable-daemon` script; registering each printer with the device code as Printer Administrator.
   * Part C, Universal Print portal: document conversion, share, access, naming conventions.
   * Part D, clients: Windows (Einstellungen › Drucker & Scanner › Drucker hinzufügen, or the Intune Settings catalog "Printer Provisioning" with Cloud Device ID/Share ID/Share Name); macOS (Universal Print app from the App Store via Intune VPP, "Alle Drucker anzeigen").
   * Operation: status, jobs, certificate expiry, re-registration, removing a printer (app plus portal).
   * Fehlerbehebung: `labelwerk-up doctor`, `/Library/Logs/LabelWerk/upbridge.log`, typical errors (wrong size → label types; "Dokumentformat" → conversion off; jobs stuck → Mac asleep).
   * Fallback: Windows connector VM in brief.
7. **`06-signatur-notarisierung.md` – Developer ID und Notarisierung einrichten**
   * Apple Developer Program (organisation, D-U-N-S, Account Holder role); creating both certificates (CSR from Schlüsselbundverwaltung, export as .p12); App Store Connect API key.
   * GitHub secrets table (§C1) with `base64 -i file.p12 | pbcopy`; variable `LW_SIGNING`.
   * What changes after the first signed build (Gatekeeper silent, one-time re-approvals, the updater's team check); verification commands (`pkgutil --check-signature`, `spctl -a -vv -t install`, `stapler validate`, `codesign -dv`).
   * Certificate renewal (5 years) and revocation; the Intune LOB option becoming possible (not needed).
8. **`07-deinstallation.md` – Entfernen**: the Intune uninstall script, removing profiles, what remains (user data, UP registrations in the portal).

Also: `docs/INSTALLATION.md` gets a short section "Verwaltete Macs (Intune)" linking to `docs/intune/`. `README.md` gets a feature table row. `ARCHITECTURE.md` gets new sections §12 "Verwaltete Konfiguration" and §13 "Universal-Print-Brücke" (binding names as in §A3/§B3). `docs/DEVELOPMENT.md` gets "Signieren in der CI" and "UP-Brücke testen (Mock)".

---

## E. Work breakdown

Six chunks. **No file is edited by more than one chunk.** Interfaces between chunks are fixed below, so they can be built in parallel. The merge order constraint is that **chunk 1 → chunk 2** and **chunk 3 → chunk 4 → chunk 2** for compile dependencies (chunk 2 references types from 1, 3 and 4). Chunks 5 and 6 are independent; 6 finalises strings last.

### Cross-chunk interfaces (frozen by this design)

* **I1** (chunk 1 → 2): Kit public API exactly as §A3 (`ManagedConfiguration`, `ManagedConfigurationParser`, `ManagedReconciler.plan`, `ManagedIdentity`, `ManagedAppliedRecord.load(from:)`, `ManagedFeature`, `ManagedAppPreferences`).
* **I2** (chunk 3 → 4): `LabelWerkCloud` public `BridgeStatus`, `BridgeRequest`, `BridgePaths` (`root`, `requestsDirectory`, `statusFile`) as in §B5; executable path `Contents/Helpers/labelwerk-up`; CLI `enable-daemon`/`disable-daemon`/`configure`.
* **I3** (chunk 4 → 2): `struct UniversalPrintSettingsView: View { init() }`; `@MainActor final class UniversalPrintService { static let shared; static var isFeatureHidden: () -> Bool = { false } }`. Chunk 2 sets `isFeatureHidden` at launch from `HiddenFeatures` and adds the Settings tab.
* **I4** (chunk 3 → 5): SwiftPM product `labelwerk-up` exists. `build_app.sh` skips it if it is absent.
* **I5** (chunk 1 → 3): `ManagedConfiguration.universalPrint` (the `UniversalPrint` dict) for daemon configuration precedence.

### Chunk 1 – Managed core, `lwctl managed`, Intune samples (Linux: fully verifiable)

Files (new unless marked edit):
* `Sources/LabelWerkKit/Managed/ManagedConfiguration.swift`, `ManagedConfigurationParser.swift`, `ManagedPrintSettings.swift`, `ManagedIdentity.swift`, `ManagedReconciler.swift`, `ManagedQueuePlanner.swift`, `ManagedAppliedRecord.swift`
* `Sources/lwctl/ManagedCommands.swift`
* edit `Sources/lwctl/CommandCatalog.swift`, `Sources/lwctl/Commands.swift`, `Sources/lwctl/InstallCommands.swift` (refactor `installQueue`), `Sources/lwctl/CUPSQueues.swift` (if snapshot with options is needed)
* `Tests/LabelWerkKitTests/ManagedConfigurationTests.swift`, `ManagedPrintSettingsTests.swift`, `ManagedReconcilerTests.swift`, `ManagedQueuePlannerTests.swift`, `LwctlManagedTests.swift`
* `Installer/Intune/*` (all of §A6)
* `Scripts/tests/test_intune_samples.py`

Acceptance:
1. `swift build` and `swift test --filter LabelWerkKitTests` green on Linux, with the new suites as in §A7.
2. Existing `LwctlInstallTests` unchanged and green.
3. `lwctl managed validate --file Installer/Intune/com.labelwerk.app.plist` exits 0 with no issues; with the fragment file it also exits 0.
4. `lwctl managed apply --file … --dry-run --json --ppd-dir <generated>` lists exactly 2 creates (`LabelWerk_lager-tor1`, `LabelWerk_lager-tor1_brille`) plus 1 setDefault, with the expected `lpadmin` arguments (`-o lwDarkness-default=20`, `-o lwLabelWidth-default=10400`, `PageSize=w295h216` …).
5. With fakes: a second run makes no `lpadmin` calls; removing the label type from the file gives `lpadmin -x LabelWerk_lager-tor1_brille` only.
6. `python3 -m unittest discover -s Scripts/tests` green.

Not verifiable on Linux: real `/Library/Managed Preferences` delivery by Intune, launchd watcher triggering, macOS `lpadmin` acceptance (covered later by a manual check on a test Mac: `sudo lwctl managed apply` with the sample, then `lpstat -v`, then printing a test page).

### Chunk 2 – App: managed configuration integration (macOS only)

Files:
* new `Sources/LabelWerkApp/Services/ManagedConfigurationService.swift`, `Model/AppModel+Managed.swift`, `Model/PrinterSession+Managed.swift`, `Features/Settings/ManagedSettingsPane.swift`
* edit `Model/AppTypes.swift`, `Model/AppModel.swift`, `Model/Navigation.swift`, `Services/QueueSyncService.swift`, `Services/UpdateController.swift`, `Services/NetworkDiscoveryService.swift`, `Features/Settings/AppSettingsView.swift` (Verwaltung tab, Universal Print tab via I3, lock badges, "Beim Anmelden starten"), `Features/Updates/UpdateSettingsView.swift` (and the other update view files only if needed for the disabled reason), `Features/Root/SidebarView.swift`, `Features/Root/PrinterDetailView.swift`, `Features/Preferences/PrintPreferencesView.swift`, `Features/Preferences/PrintPrefsLabelTypesPane.swift`, `Features/Stocks/*` (read-only for locked), `Features/Discovery/DiscoveryPanel.swift` / `DiscoveryDeviceList.swift` / `DiscoveryNetworksSheet.swift` (add hidden, networks lock), `App/LabelWerkApp.swift` (menu commands hidden or disabled by policy)

Acceptance (manual on macOS 14 and 15, plus `swift build --product LabelWerk`, `swiftc -parse`):
1. `sudo defaults write "/Library/Managed Preferences/com.labelwerk.app" …` is **not** used. Instead, install `LabelWerk-Konfiguration.mobileconfig` manually on a test Mac (System Settings › Profiles). The app shows the 1 managed printer with the lock badge and the label type "Brillenetikett". Removing it is impossible. Druckeinstellungen are read-only with a banner.
2. A user printer at 10.62.13.19 that existed before the profile becomes managed, and its history is kept.
3. Removing the profile (without restarting the app) makes the managed printer disappear within 2 s, and the user preferences come back.
4. `UpdatesEnabled=false`: no network request to api.github.com (checked with Little Snitch or `nettop`), and the Updates tab shows the managed text.
5. `HiddenFeatures=[firmware,terminal]`: those tabs are gone, and the ⌘ shortcuts do nothing.
6. With `AllowUserPrinters=false`, no add entry points remain.
7. Settings › Verwaltung lists the parser issues for a deliberately broken profile.
8. `QueueSyncService` makes no `lpadmin` calls for managed printers (log check).
9. Everything works as before with no profile installed (regression run).

Not verifiable on Linux: all of chunk 2 (SwiftUI/AppKit, `objectIsForced`, KVO from cfprefsd, `SMAppService`).

### Chunk 3 – LabelWerkCloud, `labelwerk-up`, mock service (Linux: fully verifiable against the mock)

Files:
* edit `Package.swift`
* new `Sources/LabelWerkCloud/**` (§B3), `Sources/LabelWerkCloudMock/**`, `Sources/labelwerk-up/**`, `Sources/labelwerk-up-mock/main.swift`
* new `Tests/LabelWerkCloudTests/**`
* edit `Scripts/ci_linux.sh` (test target loop + `test-up-bridge` step)
* edit `.github/workflows/ci.yml`? **No**: that file belongs to chunk 5. Chunk 5 adds a Linux workflow step "UP-Brücke (Mock)" that runs `Scripts/ci_linux.sh test-up-bridge`.
* edit `Scripts/uninstall.sh` (also remove the LaunchDaemons `com.labelwerk.app.upbridge` and `com.labelwerk.app.managed`, `/Library/Application Support/LabelWerk/UniversalPrint`, and the System keychain items of service `com.labelwerk.app.universalprint`, with `--keep-up-registration` to keep them)
* edit `Scripts/tests/test_installer_scripts.py` (uninstall dry-run covers the new paths)

Acceptance:
1. `swift build`, plus `swift test --filter LabelWerkCloudTests` green on Linux (§B8 list).
2. `Scripts/ci_linux.sh test-up-bridge` green: the fake `lp` receives the PDF, the mock records Acknowledge-Job plus Update-Job-Status 5 → 9, and `status.json` matches the schema.
3. `labelwerk-up --help` and every subcommand `--help` are in German.
4. No secrets in logs (a test greps the captured stderr for the mock token, user code after approval, and the key).
5. The spike gate §B9 is passed and documented in the PR description, with the attributes Windows honoured.

Not verifiable on Linux: real Microsoft endpoints and tenant behaviour; Security.framework RSA; the System keychain; launchd/BTM; macOS cupsd PDF filter chain (`lp` of a PDF onto a LabelWerk queue); Windows and Mac UP clients; long-run stability (24 h soak on the office Mac).

### Chunk 4 – App: Universal Print UI and status (macOS only; depends on I2)

Files:
* new `Sources/LabelWerkApp/Features/UniversalPrint/UniversalPrintSettingsView.swift`, `UPDeviceCodeSheet.swift`, `UPPublishRow.swift`, `UPJobsList.swift`, `Sources/LabelWerkApp/Services/UniversalPrintService.swift`
* edit `Sources/LabelWerkApp/Features/MenuBar/MenuBarView.swift`

Acceptance (manual on macOS against `labelwerk-up-mock` with `LW_UP_ENDPOINTS_OVERRIDE`, then against the real tenant after §B9):
1. As a non-admin you see the hint "Nur Administratoren…".
2. "Auf diesem Mac aktivieren" asks for the admin password once and installs the daemon (`launchctl print system/com.labelwerk.app.upbridge` shows it running).
3. Registering a label-type queue shows the device code sheet. After approval the row turns "Freigegeben".
4. A job printed from Windows appears under "Letzte Aufträge" as "Gedruckt".
5. With the Zebra paper out, the row shows "Wartet auf Papier", and the Windows queue shows the job stopped.
6. The menu bar row reflects the state.
7. Managed `UniversalPrint` values are shown with a lock and cannot be edited.
8. Reduced motion is respected; all strings go through `tr()`.

Not verifiable on Linux: all of chunk 4.

### Chunk 5 – Signing, notarization, updater team check, bundling (Linux: the scripts and the Kit part)

Files:
* new `Installer/lib/signing.sh`, `Scripts/tests/test_signing.py`
* edit `Scripts/ci_macos.sh`, `.github/workflows/ci.yml` (macOS signing and notarize steps; Linux step for `test-up-bridge`), `Installer/lib/common.sh`, `Installer/Info.plist`, `Installer/config.env`, `Installer/LabelWerk.entitlements` (comment only), `Scripts/build_app.sh`, `Scripts/notarize.sh`, `Sources/LabelWerkKit/Update/UpdateInstaller.swift`, `Tests/LabelWerkKitTests/UpdateInstallerTests.swift`

Acceptance:
1. On Linux: `swift test --filter LabelWerkKitTests/UpdateInstaller` green; `python3 -m unittest Scripts/tests/test_signing.py Scripts/tests/test_release.py Scripts/tests/test_installer_scripts.py` green; shellcheck clean.
2. macOS CI **without secrets**: the run is identical to today (ad-hoc app, unsigned pkg, warning "Keine Signaturzertifikate"), and the release is still published.
3. macOS CI **with secrets** (after the Apple account exists):
   * `verify-pkg` shows Developer ID and TeamIdentifier for all binaries;
   * `notarize` is Accepted;
   * `stapler validate` passes on the pkg and the app;
   * `spctl -a -t install` reports "accepted, source=Notarized Developer ID";
   * a download of the release on a clean Mac installs by double-click with no Gatekeeper prompt;
   * an app updated from it refuses a manually injected unsigned pkg (exit code 4 message).
4. `LW_SIGNING=required` on a tag without secrets fails the job.

Not verifiable on Linux: codesign, productbuild, notarytool, stapler, spctl, keychain import (the logic is tested with fakes; the real path only with an Apple account on a macOS runner).

### Chunk 6 – Documentation and localisation (no code)

Files:
* new `docs/intune/README.md`, `01-…` to `07-…` (§D)
* edit `README.md`, `docs/INSTALLATION.md`, `ARCHITECTURE.md`, `docs/APP_ARCHITECTURE.md`, `docs/DEVELOPMENT.md`, `Installer/Resources/de.lproj/Localizable.strings`, `Installer/Resources/en.lproj/Localizable.strings` (after chunks 2 and 4 merge: `Scripts/extract_strings.py`, then translate the new English entries)

Acceptance:
1. Every Intune click path and permission name has been checked against the current Microsoft Learn pages on the day of writing (link plus date in each guide).
2. The key tables in `02-…` match the `ManagedConfigurationParser` (a test in chunk 1, `test_intune_samples.py`, greps `docs/intune/02-verwaltete-konfiguration.md` for every key name of §A2; until chunk 6 lands that check is skipped when the file is missing).
3. `Scripts/extract_strings.py --check --strict` green.
4. Markdown links resolve (a link checker in `ci_linux.sh lint`, if present).
5. A German native-speaker read-through.

Not verifiable on Linux: none of the text itself, but the screenshots and click paths need a real Intune tenant and Mac.

### Ownership matrix (conflict check)

| File / folder | Chunk |
|---|---|
| `Package.swift` | 3 |
| `Sources/LabelWerkKit/Managed/**`, `Sources/lwctl/{ManagedCommands,CommandCatalog,Commands,InstallCommands,CUPSQueues}.swift`, `Installer/Intune/**`, `Tests/LabelWerkKitTests/Managed*`, `LwctlManagedTests.swift`, `Scripts/tests/test_intune_samples.py` | 1 |
| `Sources/LabelWerkApp/{Model,Services/ManagedConfigurationService.swift,Services/QueueSyncService.swift,Services/UpdateController.swift,Services/NetworkDiscoveryService.swift}`, `Features/{Settings,Updates,Root,Preferences,Stocks,Discovery}`, `App/LabelWerkApp.swift` | 2 |
| `Sources/LabelWerkCloud/**`, `Sources/LabelWerkCloudMock/**`, `Sources/labelwerk-up*/**`, `Tests/LabelWerkCloudTests/**`, `Scripts/ci_linux.sh`, `Scripts/uninstall.sh`, `Scripts/tests/test_installer_scripts.py` | 3 |
| `Sources/LabelWerkApp/Features/UniversalPrint/**`, `Services/UniversalPrintService.swift`, `Features/MenuBar/MenuBarView.swift` | 4 |
| `Scripts/{ci_macos,build_app,notarize}.sh`, `.github/workflows/ci.yml`, `Installer/lib/{common,signing}.sh`, `Installer/{Info.plist,config.env,LabelWerk.entitlements}`, `Sources/LabelWerkKit/Update/UpdateInstaller.swift`, `Tests/LabelWerkKitTests/UpdateInstallerTests.swift`, `Scripts/tests/test_signing.py` | 5 |
| `docs/**`, `README.md`, `ARCHITECTURE.md`, `Installer/Resources/*.lproj/Localizable.strings` | 6 |

(`Model/` in chunk 2 means `AppTypes.swift`, `AppModel.swift`, `Navigation.swift`, plus the new `AppModel+Managed.swift` and `PrinterSession+Managed.swift`. `PrinterSession.swift` itself is not edited.)

---

## F. Risks and open questions

1. **UP OEM protocol for in-house single-tenant apps.** It is likely to work (the sample reads AppId/Tenant from config) but unverified. The §B9 spike decides.
2. **Device certificate lifetime and renewal** are undocumented. We monitor `notAfter` (warning at 30 days), and re-registration needs an admin. Ask Microsoft or find out in the spike.
3. **Label size fidelity from Windows clients.** Mitigation: one cloud printer per label type, and the filter's fit-to-label.
4. **Polling volume.** 15 s × N printers. Tunable; notifications are experimental.
5. **Mac UP clients** need "Show all printers"; iOS cannot print.
6. **The System keychain API is deprecated.** The `FileSecretStore` fallback is root-only 0600.
7. **Intune Preference-file payloads with nested arrays/dicts.** Supported by plist, but must be verified in the Intune UI (otherwise use the Custom mobileconfig path, which certainly supports them). Chunk 6 records the result.
8. **Freezing the bundle ID `com.labelwerk.app`** before the first Intune rollout is mandatory (D1).
