# Health Command Center Provider Mode

This fork can read health metrics from a **Health Command Center (HCC)** server
the user runs themselves, instead of from a BLE device over Bluetooth. It is an
additive, opt-in mode: with it switched off, the app behaves exactly as upstream
OpenVitals does.

## What It Is

HCC is a self-hosted personal health server (Next.js + Prisma + TimescaleDB). It
already ingests wearable and lab data, computes daily recovery / sleep / strain
scores, and grades biomarkers against the owner's optimal targets. In provider
mode the phone is a thin client over that server's read API: it renders scores
the server produced and never recomputes or reinterprets them.

Two modes, one switch (`HealthMetricProvider`, `OpenVitals/HCC/HCCProvider.swift`):

| Mode | Source of metrics | Where data lives |
|---|---|---|
| `.bridge` (default) | BLE device → Rust core → local SQLite | On this iPhone only |
| `.hccCloud` | `GET https://<your server>/api/mobile/v1/*` | On the user's own server |

The default is `.bridge`, so an unconfigured build of this fork is upstream
behaviour.

## Data Flow And Consent

Provider mode is entered from an onboarding step with a consent screen. Nothing
below happens until that step is completed and a sign-in succeeds.

**Leaves the device**

- Email and password, once, to the configured server's `/api/auth/mobile/login`.
- The bearer token on every subsequent request, over HTTPS.
- Later phases only: HealthKit samples read from a paired Apple Watch, journal
  entries typed in the app, and the APNs device token for push. Each is added in
  its own phase and named on the consent screen before it is sent.

**Never leaves the device**

- BLE packet captures, raw notification spools, exports, and the local SQLite
  store. Provider mode does not upload anything the bridge path collected.
- The Keychain contents. Tokens are read for the `Authorization` header and are
  not logged, exported, or included in diagnostics bundles.

**Where it goes**

Only to the base URL the user typed. There is no analytics endpoint, no vendor
backend, and no third party in the path. The client refuses any address that is
not `https://`, except the loopback hosts a development server runs on.

**How to revoke**

1. In the app: More → Sign out. This calls `POST /api/auth/mobile/logout`, which
   revokes the mobile token and disables push registrations made with it, then
   deletes both tokens from the Keychain. It works offline too — the local
   delete happens either way.
2. On the server: Settings → mobile app sessions, which revokes the token for a
   device that is lost or was never signed out.

Signing out does not switch the app back to the bridge path; redoing onboarding
does.

## The Two Credentials

`/api/auth/mobile/login` answers with two tokens, stored under Keychain service
`com.gatbontonlabs.hcc` with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (so they survive a reboot for
background refresh, and stay out of iCloud Keychain and encrypted backups):

| Account | Token | Role |
|---|---|---|
| `mobileToken` | `hccm_…` | Reads and writes as the user — everything the app does |
| `ingestToken` | `hcc_…` | Narrow HealthKit upload credential for the Watch path |

They are separate so the upload credential can be revoked on its own without
signing the phone out. The ingest token is **rotated on every login**: the server
stores only a hash and cannot re-issue the old plaintext, so an older device
signed in to the same account stops uploading until it signs in again.

## Code Map

All new code is under `OpenVitals/HCC/`, so an upstream merge touches none of it:

- `HCCProvider.swift` — the provider enum and its `UserDefaults` keys.
- `KeychainStore.swift` — the three-function Keychain wrapper.
- `HCCModels.swift` — `Codable` DTOs mirroring the server's read API, plus
  `HCCCopy` (the one place a server identifier becomes user-facing text).
- `HCCAPIClient.swift` — `URLSession` client, typed endpoints, retry, errors.
- `HCCSession.swift` — sign-in state, Keychain plumbing, the debug bootstrap.
- `HCCSignInScreen.swift` — the sign-in form.
- `HealthDataStore+HCC.swift` — the cloud-mode cache (`HCCStoreState`), the
  store-owned refresh fan-out, and every write a screen can make.
- `UI/HCCTheme.swift` — the "C · Command" design tokens: colours, radii, the
  font resolver, the radial background, the glass-card modifier, the small-caps
  label, and the recovery bands.
- `UI/HCCRing.swift` — the score ring (`HCCRing`) and its captioned wrapper.
- `UI/HCCComponents.swift` — chips, pills, bars, sparkline, key/value grid,
  optimal band, z-score bar, three-up stats, buttons, toggle/check/menu rows,
  and the "arrives in a later phase" sheet.
- `UI/HCCHomeView.swift` + `UI/HCCHomeSections.swift` — cloud Home (`S.home`):
  the day nav and device pill, the three rings, the insight card, the day's
  activities, tonight's sleep, and the dashboard tiles. Every string on the
  screen is made in `HCCHomeView`'s formatting helpers, so there is one place
  a `--` can be introduced.
- `UI/HCCHomeRouter.swift` — the only file that names the screens Home pushes
  or presents. Integrating a new detail screen is an edit here.
- `UI/HCCStrainRecoveryChart.swift` — the dual-axis strain/recovery graph.
- `UI/HCCTabBar.swift` — the five-tab bottom bar and `HCCPhaseScreen`, the
  one-line screen a tab whose feature belongs to a later phase shows.
- `UI/HCCCoachFAB.swift` — the Coach bubble. Written, but deliberately NOT
  mounted in this phase: the Coach has no backend, and a control that does
  nothing is worse than no control.
- `UI/HCCPreviewHost.swift` — DEBUG-only component gallery.

## Copy Rule

`HCCCopy.originLabel` / `HCCCopy.sourceLabel` are the only place device naming
lives — route new labels through them. `origin: "computed"` renders as
**"Command Center"**, because that origin means the server's own scoring engine
and not any particular wrist.

**REVISED 2026-09-03 (Chris).** `origin: "whoop"` / `source: "WHOOP"` now render
as **"WHOOP"**. They previously rendered as the neutral word **"band"** under
upstream's rule that no manufacturer name reaches the interface (AGENTS.md).
That rule guards the reverse-engineered BLE client; on the cloud surface the
label is only this account's own server saying which instrument produced a
number, and "Band" sitting next to "Fitbit", "Apple Watch" and "Withings scale"
read as a missing device rather than a neutral one.

The split, so neither half gets "fixed" by a later pass:

- **Cloud surface (`HCC/**`) names the brand** — devices sheet, home device
  pill, recovery/strain provenance lines, battery card, and any server sentence
  passed through `HealthDataStore.hccNeutralCopy` (which is now a spelling
  normaliser onto `HCCCopy`'s label, not a redaction).
- **Bridge surface stays neutral** — `HCCProvider`'s onboarding picker,
  `HCCLiveCopy.sourceFootnote`'s Bluetooth sentence, `HCCBLEHeartRateSource`,
  and every upstream view outside `HCC/`, which talk about reading a device
  directly over BLE. Do not put a brand name in those.

## Card Spacing Is Stack Spacing

Vertical rhythm on the cloud screens has ONE mechanism: the spacing of the stack
that holds the cards. `HCCScreen`'s stack is `spacing: 10` (the mockup's
`.card{margin-bottom:10px}`) and backs every detail screen, More and the four
Health pages; Home's scroll stack matches it; the dashboard tile list and the
activity-row list use `spacing: 8` (`.tile`/`.actv`), as does the Health 2x2
grid.

**Do not add `.padding(.bottom)` to a card to separate it from the next one** —
it stacks on top of the container's spacing instead of replacing it, which is
exactly how the chart tile ended up 16 pt from the tile below it and the Health
monitor card 20 pt from the grid. Rows *inside* a card stay flush and are
separated by `HCCDivider`, so a `spacing: 0` stack there is correct.

Two elements carry a small padding on purpose, as the remainder of a larger
mockup margin the stack already partly supplies: `HCCDetailHeader` adds 2 (10 +
2 = the mockup's 12) and `HCCSectionHeader` adds 4 on top (10 + 4 = 14). Both
are commented as such.

## Bundled Fonts

The "C · Command" type is bundled under `OpenVitals/HCC/Fonts/`, added to the
app target as resources and listed in `UIAppFonts` in `OpenVitals/Info.plist`:

| File | Family | Notes |
|---|---|---|
| `Outfit-Variable.ttf` | Outfit | Variable (`wght`). Display face. |
| `IBMPlexSans-Variable.ttf` | IBM Plex Sans | Variable (`wdth,wght`). Body face. |
| `IBMPlexMono-Regular.ttf` | IBM Plex Mono | Data face. |
| `IBMPlexMono-Medium.ttf` | IBM Plex Mono | Data face, medium. |

All three families are SIL Open Font License 1.1, from the `google/fonts`
repository. The OFL requires the licence to travel with the font, so
`OFL-Outfit.txt`, `OFL-IBMPlexSans.txt` and `OFL-IBMPlexMono.txt` sit alongside
them and are bundled as resources too. Do not remove them.

Two things to know before touching this:

- **IBM Plex Sans has no static weights in `google/fonts`** — only the variable
  file. Outfit is variable as well. iOS registers a variable font's named
  instances as separate faces in the family, which is what lets
  `Font.custom(family).weight(...)` pick a weight at all.
- **Outfit's DEFAULT instance is Thin, not Regular.** A `Font.custom("Outfit",
  size:)` with no `.weight()` renders hairline. `HCCTheme.Font.display` always
  applies a weight for exactly this reason.

`HCCTheme.Font` still checks `UIFont.familyNames` and falls back to system faces
(rounded / default / monospaced) when a family is absent, so a build without
these files still renders correctly — just not in the intended type. Because
that fallback is silent, `HCC_DEBUG_SMOKE=1` prints a `font` line per family
saying whether the real face was found and which concrete face a weight request
resolved to. Check those lines rather than trusting the screen.

## Civil Days Belong To The Instance, Not The Phone

The server decides which civil day a reading belongs to in the INSTANCE's
timezone, and `?date=` on `/home`, `/activities`, `/sleep` and `/insights` is
read in that same zone. So every `Date -> YYYY-MM-DD` conversion in the client
uses the instance zone too — `HealthDataStore.hccDayKey`, `hccDayLabel`,
`hccShortDayLabel` and `hccLocalDate(fromDayKey:)` all go through
`HealthDataStore.hccInstanceTimeZone`.

Using the device zone is the bug this prevents: a phone far enough east or west
to be on a different calendar day would ask for the wrong day on all four
routes at once, and every screen would agree with itself while showing the
wrong day's numbers under today's heading.

The zone is resolved, in order, from what `/instance` last reported, then the
account summary persisted at sign-in (`HCCInstanceZone`, which reads
`UserDefaults` so the `nonisolated` day-key helpers need no actor hop), then the
device zone as a last resort. A launch that has never signed in — the DEBUG
token path — settles the zone by reading `/instance` before it asks for a day.
A 401 clears it, so one account's zone cannot outlive it.

`HCC_DEBUG_SMOKE=1` prints a `civil day` line with the instance zone, the device
zone and the day the app will ask for; run the simulator under
`SIMCTL_CHILD_TZ=Pacific/Auckland` to see them diverge and confirm the app still
asks for the instance's day.

## Writes

The phone writes through `HealthDataStore`, never from a view: `dismissInsight`,
`setPreferredSource`, `saveDashboard`, `saveAlarm`, `addActivity`,
`updateActivity` and `deleteActivity`. Each applies the change locally, calls
the server, then reconciles with what the server actually stored; a failure
rolls the local edit back and puts the server's own message on
`store.hcc.lastError`, so a write that did not happen never looks like one that
did.

One encoding trap is worth knowing: `PUT /devices/preferred` takes
`{"source": null}` to CLEAR the override, and its schema requires the key. Swift's
synthesized `Encodable` omits a nil optional, which the server answers with a
400 — so `HCCPreferredSourceBody` hand-encodes the field. Any future
nullable-but-required body needs the same treatment.

## Never Fabricate A Value

The server marks a score `calibrating` when its engine has not produced a real
number yet, and `stale` when the newest reading has aged out. Both render as
unavailable with the server's own `reason` sentence and a `--` value. A missing
number is never drawn as zero, and a stale number is never drawn as fresh.

Optimal bounds from `/metrics` and `/instance` are the app's **optimal targets**,
not lab reference ranges — the payload says so in its `basis` field. A value
outside them is "below target" or "above target", never "abnormal".

## Development And Verification

**Toolchain.** Xcode 26, iOS deployment target 26.0, Swift language mode 5. The
Rust core is still required and force-linked even in provider mode: build it
with `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` and let the
`Scripts/build_ios_rust.sh` build phase stage `Rust/iphonesimulator/…` /
`Rust/iphoneos/…`. Set `OPENVITALS_SKIP_RUST_CORE_BUILD=1` only when a staged
archive already exists.

```sh
xcodebuild -project OpenVitals.xcodeproj -scheme OpenVitals \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

**Debug launch bootstrap.** Typing a password into the app under UI automation
would put a real credential into a script, a log and a shell history. Instead,
mint a token out of band and hand it to the process:

```sh
curl -s -X POST "$BASE/api/auth/mobile/login" -H 'Content-Type: application/json' \
  -d '{"email":"…","password":"…","deviceName":"sim"}'   # → { token, ingestToken, … }

# simctl forwards only variables prefixed SIMCTL_CHILD_ into the app's
# environment; anything after the bundle id is argv, which the app ignores.
SIMCTL_CHILD_HCC_DEBUG_BASE_URL=http://localhost:3999 \
SIMCTL_CHILD_HCC_DEBUG_TOKEN=hccm_… \
SIMCTL_CHILD_HCC_DEBUG_SMOKE=1 \
  xcrun simctl launch --console-pty booted com.gatbontontech.openvitals-hcc
```

| Variable | Effect |
|---|---|
| `HCC_DEBUG_BASE_URL` | Base URL for this launch, overriding the stored one |
| `HCC_DEBUG_TOKEN` | Bearer used for this process; **never written to the Keychain** |
| `HCC_DEBUG_SMOKE=1` | Runs `HCCAPIClientSmoke` at session init |
| `HCC_DEBUG_OPEN_DATE=YYYY-MM-DD` | Home selects that day on launch (cloud mode) |
| `HCC_DEBUG_OPEN_ROUTE=<HealthRoute>` | Home pushes that detail screen on launch (`sleep`, `recovery`, `strain`, `healthMonitor`) — screenshots without UI automation |
| `HCC_DEBUG_OPEN_SCREEN=gallery` | Home shows `HCCComponentGallery` — every design-system component with sample props |
| `HCC_DEBUG_OPEN_SCREEN=recovery\|sleep\|strain\|health\|biomarkers\|insights\|genetics\|protocols` | The Health tab shows that one screen instead of its landing (`HCCHealthView`), so each can be screenshotted without UI automation. Pair with `HCC_DEBUG_OPEN_TAB=health` to land on that tab, and with `HCC_DEBUG_OPEN_DATE` for the three detail screens. Value sets are disjoint from the More tab's (`more`, `devices`, `customize`, `alarm`, `addActivity`, `activity:<id>`) and from `gallery` |
| `HCC_DEBUG_GALLERY_ANCHOR=<section>` | Scrolls the gallery to `rings`, `chips`, `charts`, `rows` or `controls` on appear, so each section can be screenshotted without UI automation |
| `HCC_DEBUG_HOME_ANCHOR=<block>` | Scrolls cloud Home to `rings`, `activities`, `tonight` or `dashboard` on appear — Home is about two screens tall and `simctl` cannot scroll |
| `HCC_DEBUG_OPEN_TAB=<tab>` | Selects a bottom tab on launch (`home`, `health`, `journal`, `training`, `more`), so a tab that is not Home can be screenshotted without a tap |
| `HCC_DEBUG_OPEN_SCREEN=more` | Opens on the More tab (its cloud screen) |
| `HCC_DEBUG_OPEN_SCREEN=devices\|customize\|alarm\|addActivity` | Opens More and presents that sheet on appear |
| `HCC_DEBUG_OPEN_SCREEN=activity:<id>` | Opens More and presents the activity detail for that activity id |
| `HCC_DEBUG_SAVE=1` | On the Alarm and Customize sheets only: nudges one value and runs the sheet's own `save()`, so the write path can be proved from a launch with no UI automation. Never set it against an instance whose data you are not willing to change. |

With a token present, the bootstrap also marks onboarding complete and selects
`.hccCloud` for the launch, so the simulator lands on Home. The whole mechanism
is inside `#if DEBUG` and is compiled out of Release — a shipped app has no
environment-variable path into a signed-in state.

`HCCAPIClientSmoke` hits `/instance`, `/home`, `/scores`, `/sleep/latest`,
`/vitals`, `/insights`, `/activities`, `/sleep/plan`, `/dashboard`, `/alarm`,
`/devices`, `/biomarkers`, `/genetics` and `/api/protocols`, and prints one
`[hcc-smoke]` line per call saying whether the payload decoded. Its job is to catch DTO drift: the models here are a hand-copy of the
server's types, and this is what proves the copy still matches. Run it after any
change to the server's read API. It prints shapes and counts, never a metric
value.

There is no XCTest target in this project; a clean simulator build plus that
smoke run is the verification bar for this code.

### Scroll a screen to its end for a screenshot

`SIMCTL_CHILD_HCC_DEBUG_SCROLL_BOTTOM=1` makes every `HCCScreen` scroll to its
last card about four seconds after it appears. It exists to prove that the last
card clears the tab bar; the bar is laid out UNDER each tab's stack in
`AppShellView.cloudShell` (a safe-area inset never reached the scroll views
inside the per-tab `NavigationStack`s, and the last row sat under the bar by
exactly its height).

## The Journal Tab

`HCCJournalView` is the Journal tab in cloud mode. Three cards, in the mockup's
order: **Behaviors** (the day's yes/no and numeric answers), **Doses** (what the
active protocols owe that day), **Impact on recovery** (what the answers have
cost or bought). Files: `HCC/UI/HCCJournalView.swift` (the screen and every
number-to-string helper), `HCC/UI/HCCJournalSections.swift` (the rows,
presentation only), `HCC/HCCModels+Journal.swift` (DTOs),
`HCC/HCCAPIClient+Journal.swift` (the five calls),
`HCC/HealthDataStore+HCCJournal.swift` (`HCCJournalState` and the three writes).

It deliberately does **not** list the day's activities. Home owns that list, and
two places showing the same rows is how they end up disagreeing.

### Unanswered Is Not "No"

A behavior with no entry for a day is *unanswered*, which is a third state, not
a "no". The server enforces this — clearing both values on an entry **deletes
the row** (`upsertJournalDay`) — because the impact maths counts only days that
were actually answered, and a phone that wrote a "no" for every untouched
behavior would manufacture the sample it then reports on.

So the switch has three renderings, not two: unanswered draws off with a **muted
label**, "no" draws off with a normal label, "yes" draws on. Tapping cycles
yes ↔ no; **long-pressing an answered row clears it** back to unanswered, and
there is no other way to take an answer back. A numeric behavior is the same
idea: zero is a real answer ("no drinks"), so it is never used to mean "not
logged" — the row says which in words.

### The Day Navigator

The header carries the same `HCCDayNav` Home uses: back is unlimited, forward
stops at today. A journal that could only be filled in on the day itself would
quietly lose every busy evening, and those are exactly the days the impact rows
need. `‹`/`›` step in the **instance's** calendar, not the phone's, and the card
title reads "Doses today" only when the day on screen actually is today.

### A Cancelled Read Is Not A Failed One

Stepping the day retargets `.task(id: dayKey)`, which cancels the read already in
flight. `loadJournal` therefore ignores cancellation in all three shapes it
arrives in (`CancellationError`, `HCCAPIError.transport(CancellationError)`,
`URLError.cancelled`) and leaves `loading`/`lastError` to the newer task —
otherwise a fast double-tap on `‹` puts "not loaded" over a screen that is, at
that moment, loading the day the user asked for.

### Bare Routes

`/api/journal/*` are web routes: they answer with `ok()`, the object itself, not
the read API's `{data, generatedAt, instance}` envelope. So every call goes
through one of the client's **bare** methods — `getBare` for the two reads,
`putBare`/`postBare`/`deleteBare` for the three writes. Those all share the
client's one `send` pipeline, so these calls carry the same bearer closure, the
same timeouts and the same `failure(status:data:)` mapping as every other call:
a 401 here is the same `HCCAPIError` a 401 anywhere else is, and the store's
sign-out path still fires. `send` does not retry a write, which matters — a
replayed POST would log a second dose.

### Journal Launch Hooks (DEBUG)

| Variable | Effect |
|---|---|
| `HCC_DEBUG_OPEN_TAB=journal` | Opens the tab |
| `HCC_DEBUG_OPEN_DATE=YYYY-MM-DD` | Which day the Journal opens on — `simctl` cannot tap the day navigator |
| `HCC_DEBUG_JOURNAL_ANCHOR=behaviors\|doses\|impacts` | Scrolls to one card on appear (the impact card is aimed at the bottom edge; it cannot reach the top, there is nothing below it) |
| `HCC_DEBUG_JOURNAL_ANCHOR=impactsOnly` | Draws the impact card **alone**, so it can be screenshotted — see the caveat below |
| `HCC_DEBUG_SAVE=1` | On the Journal: answers the first two yes/no behaviors (one yes, one no) and logs the first due dose, through the same store writes a tap goes through. Same warning as the Alarm and Customize sheets — it MUTATES SERVER STATE. |

### The Tab Bar Is Laid Out Under Each Tab, Not As A Safe-Area Inset

`AppShellView.cloudShell` used to mount `HCCTabBar` in a
`.safeAreaInset(edge: .bottom)` on the `TabView`. That inset never reached the
`ScrollView` inside `HCCScreen`: at maximum scroll the last ~85 pt of every
cloud screen sat under the bar, hiding the Journal's whole impact grid and
More's sign-out row. Moving the inset onto each tab's own stack did not fix it
either. The bar is now a plain sibling in a `VStack` below each tab's stack,
which bounds the scroll view above it for certain.

Verify with `HCC_DEBUG_SCROLL_BOTTOM=1`, which scrolls any `HCCScreen` to its
last card a few seconds after it appears.

## The Training Tab

`HCCTrainingView` is the web app's Wendler 5/3/1 tracker
(`src/components/TrainingClient.tsx` + `TrainingProgression.tsx`), ported. It
reads `GET /api/training` — the same serialised `TrainingData` the web page
hands its client — and writes through the four existing web routes:
`PUT /api/training/plan`, `POST /api/training/sessions`,
`PATCH /api/training/sessions/{id}`, `PATCH /api/training/sets/{id}` and
`POST /api/training/cycle`. All of them answer with a bare `ok()` object, not the
`/api/mobile/v1` envelope.

**`HCCFiveThreeOne.swift` is a mirror, not a source.** It is a 1:1 port of
`src/lib/fiveThreeOne.ts`. The server writes the prescribed `LiftSet` rows the
moment a session is created, so a STARTED day always renders the server's own
numbers; the port exists only for the PREVIEW of a day that has not been started,
which has no rows anywhere and which the web page also generates from these
functions. If a number here disagrees with the TypeScript, this file is wrong.

There is no XCTest target, so the port is verified by running the same inputs
through both and diffing:

```sh
# Swift: prints a 38-line block at launch
SIMCTL_CHILD_HCC_DEBUG_531_CHECK=1 ... xcrun simctl launch --console-pty <udid> com.gatbontontech.openvitals-hcc
# TypeScript: transpiles src/lib/fiveThreeOne.ts and prints the same block
node <scratch>/pt-531.mjs
```

The two blocks must be byte-identical. They cover `waveSets(120, 1…4)`,
`platesPerSide` (97.5 → unloadable, 100, 20 → bar, 17.5 → below the bar),
`epleyE1rm(85,7)`, `nextTm` for all four lifts, `projectWave` two weeks ahead from
each anchor week plus one negative offset (JS `Math.floor` vs Swift's truncating
division), the whole `dayOptionCatalog`, and the day-key arithmetic. Re-run it
after any change to either side.

**Two weeks, not free paging.** The web strip pages across arbitrary weeks and
fetches each one from `/api/training/plan?weekStart=`. The phone shows only the
week the payload carries and the one after it, per the mockup's
`‹ this week / next week ›` chip. What a Tuesday IS depends on stored plan rows
and on the last week actually trained — a server answer — so a third week would
have to be guessed, and a guessed week is a wrong week.

**Tapping a day opens its picker.** The mockup's strip changes what a day is; it
does not move a selection. Only today's body is rendered, plus a preview of the
next strength day. Logging a past day, which the web page allows by selecting it,
is not on the phone.

**"Start live activity" is not drawn.** `HCCTrainingView.liveActivityIsAvailable`
is a static `false` until the live workout screen exists. A control that cannot
do anything must not be on screen.

### Debug hooks

| Variable | Effect |
|---|---|
| `HCC_DEBUG_531_CHECK=1` | Prints the ported 5/3/1 math for the drift check above. Reads nothing, writes nothing. |
| `HCC_DEBUG_TRAINING_WEEK=next` | Opens on the next-week preview instead of today. |
| `HCC_DEBUG_TRAINING_PICKER=YYYY-MM-DD` | Opens that day's workout picker on appear. |
| `HCC_DEBUG_TRAINING_ANCHOR=week\|progression\|controls` | Scrolls to that block on appear — the tab is several screens tall and `simctl` cannot scroll. Same trick as `HCC_DEBUG_HOME_ANCHOR`. |
| `HCC_DEBUG_TRAINING_SAVE=<action>` | Runs ONE write through the same store method the button runs, so a write path can be proved from a launch with no UI automation — the Alarm/Customize `HCC_DEBUG_SAVE` pattern. **It MUTATES SERVER STATE**: never set it against an instance whose data you are not willing to change. Actions: `start`, `logset`, `amrap:<n>`, `note:<text>`, `plan:<ymd>:<catalog key>`, `cycle:<action>[:<week>]`. |

The anchor retries at 2 s, 4 s and 8 s. Once is not enough: a debug write
re-reads the payload and relays out after the first jump, and a permission alert
raised by another surface can land on top of the second — a single early jump
leaves the screen short of the block and reads as "the block is not rendering".

## Apple Watch Upload

Readings the Apple Watch records into HealthKit are POSTed to the instance's
`/api/ingest/apple-health` and land as `APPLE_HEALTH` rows tagged
`sourceDetail: "Apple Watch"`. Code: `HCC/HCCHealthKitUploader.swift` (the
HealthKit reads, the queue and the delivery), `HCC/HCCHealthKitBatch.swift` (the
wire shape and the metric/stage/workout maps, no HealthKit import), and
`HCC/UI/HCCWatchUploadView.swift` (`HCCWatchUploadRow` for the More screen's
Devices & data card, and `HCCWatchUploadSheet`).

**This path uses the INGEST token, not the mobile one.** The two credentials are
already described above; the uploader reads `HCCSession.ingestToken()`.

**The source filter is the point of the feature.** Apple Health is a merged
store: Google Health writes Fitbit's readings into it, other apps write their
own, and values can be typed in by hand. A sample is uploaded only when Apple's
own health daemon wrote it (`sourceRevision.source.bundleIdentifier` starts with
`com.apple.health`) AND the sample carries an Apple Watch device (HealthKit
records a Watch as `device.model == "Watch"`). Uploading anything else would put
another device's numbers under the Watch's name and break the co-wear comparison
the instance exists to make. `deviceModel` on the batch is read off the sample's
own device rather than assumed, because the server turns a model containing
"watch" into the `Apple Watch` source detail.

**Anchors advance only after a 2xx.** Each sweep writes its batch to the App
Group container (`hcc-healthkit-pending/`, one `.json` wrapper carrying the
anchors plus one `.body` holding the exact request body) before uploading. The
anchors are committed and the files deleted when the server acknowledges the
batch; an undelivered batch is retried oldest-first by the next sweep and dropped
after seven days. A first read of a type is bounded to the last 30 days.

**Two streams are daily totals, not samples.** `stepCount` and
`activeEnergyBurned` are uploaded as one total per CLOSED civil day in the
instance's time zone, via a statistics query, rather than as their thousands of
constituent samples: the catalog's `steps` and `active_energy` are daily figures,
and `recordMeasurements` SKIPS a duplicate `(metric, time, source)` rather than
updating it — so a partial total uploaded mid-day would be frozen at that value
for the rest of the day. Everything else uses one `HKAnchoredObjectQuery` per
type.

**Units are sent as measured.** Wrist temperature goes up in °C and the server's
`toCatalogUnit` converts it to the catalog's °F; SpO2 is scaled from HealthKit's
fraction to a percent. `name` strings are the adapter's `APPLE_MAP` keys, not
HealthKit identifiers.

**`asleepUnspecified` is sent as `asleep`,** a word the server does not count as
a stage. "Asleep, stage unknown" is what an unstaged source reports and calling
it light sleep would invent a breakdown nobody measured. A night with no staged
segments therefore produces no sleep row — correct here, since only Watch-recorded
sleep is uploaded and that is always staged.

**Background.** `HKObserverQuery` + hourly background delivery per type, a daily
`BGProcessingTaskRequest` (`com.gatbontontech.openvitals-hcc.hcc.healthkit-upload`),
and a background `URLSession`
(`com.gatbontontech.openvitals-hcc.hcc.upload`) for sweeps that were not started from
the foreground. Neither background delivery nor `BGTaskScheduler` works in the
simulator; when either is refused the sheet says so instead of hiding it. Known
gap: relaunching the app to hand it a finished background transfer needs
`application(_:handleEventsForBackgroundURLSession:)`, a `UIApplicationDelegate`
method, and this app has no app delegate — the transfer still completes, its
completion is just processed on the next run.

**Onboarding.** In cloud mode the existing `.healthKit` step is this opt-in
rather than the body-mass prefill: `OnboardingModels.swift` names it "Apple
Watch", `OnboardingView.swift` renders the Watch copy, and
`OnboardingPermissions.requestHCCWatchUploadAccess()` asks for the read set and
turns the upload on. Bridge mode is untouched.

**Health never says whether a READ was allowed** — a denied type simply returns
nothing. The sheet therefore reports what was REQUESTED and points at
Health → Sharing → Apps; it must never print "Authorized".

### Debug hooks

| Variable | Effect |
|---|---|
| `HCC_DEBUG_HK_ANY_SOURCE=1` | Disables the Watch source filter (both the bundle-id and the device-model half). Simulator verification only — there is no Watch on a simulator. |
| `HCC_DEBUG_HK_SEED=1` | Requests WRITE authorization for a few types and saves a fixture into HealthKit: 3 HRV, 2 resting HR, one running workout with 30 HR samples, and one four-stage night, all stamped with an `HKDevice` shaped like a real Apple Watch. DEBUG only; `NSHealthUpdateUsageDescription` exists for this and the shipped app never requests a share type. |
| `HCC_DEBUG_HK_SYNC=1` | Runs one sweep at launch. |
| `HCC_DEBUG_HK_FIXTURE=1` | Prints the encoded wire batch for the fixture and does not upload it. |
| `HCC_DEBUG_HK_FIXTURE_UPLOAD=1` | Pushes that fixture through the REAL delivery path — pending files, ingest token, POST, response decode, state. **It MUTATES SERVER STATE.** Exists because the simulator's Health authorization sheet is a system alert `simctl` cannot dismiss, so a machine-driven run cannot get past the read prompt; everything downstream of HealthKit is still exercised against a real server. |
| `HCC_DEBUG_INGEST_TOKEN=…` | Uses this ingest bearer instead of the Keychain's, the same way `HCC_DEBUG_TOKEN` stands in for the mobile one. |
| `HCC_DEBUG_OPEN_SCREEN=watchUpload` | Opens the sheet (the More screen owns the row, so this is how the sheet is reached in verification). |

## Alarm scheduling on the phone (`HCCAlarmScheduler`)

`HCCAlarmSheet` writes the alarm INTENT to the server (`PUT /api/mobile/v1/alarm`)
because that row is what the web app reads too. `HCCAlarmScheduler` is the only
thing that turns that intent into something the OS will ring, and it is
deliberately the only one: a second resolver could pick a different minute than
the one the sheet is showing.

**Resolution** (`HCCAlarmScheduler.resolve`, pure and static so it can be
reasoned about on its own):

- `mode == "exact"` → the next occurrence of `HH:MM` **in the instance's
  timezone** (`HCCInstanceZone.current`). The device's own zone never enters the
  arithmetic — a travelling phone still rings at the hour the Command Center
  reasons about.
- `mode == "goal"` → the server's `sleepPlan.recommendedWake`, but only when it
  lands inside `[time − smartWindowMin, time]` and is still in the future.
  Anything outside that window is the server disagreeing with the user's own
  ceiling, and the ceiling wins: a wake time later than the alarm would be an
  alarm that overslept.
- `on == false` → everything is cancelled.

**One alarm.** The AlarmKit id is a UUID minted once into `UserDefaults`
(`hcc.alarm.scheduledAlarmId`), so every change cancels and re-schedules rather
than stacking. Re-resolution runs on each `store.objectWillChange` and on
`UIApplication.didBecomeActiveNotification`; an unchanged resolution is a no-op.
`HCCMoreScreen.onAppear` and `HCCAlarmSheet.onAppear` both call
`HCCAlarmScheduler.shared.observe(store)`, which is idempotent — an app-launch
touch point can replace them later.

**Fallback.** If AlarmKit is unavailable or refused, a time-sensitive
`UNCalendarNotificationTrigger` stands in and the sheet says so
("Notification fallback — enable alarms in Settings"). Permission is settled
*before* the request is registered: iOS silently discards a request added while
notification authorization is undetermined (`add` returns without throwing and
`pendingNotificationRequests()` then comes back empty — measured, not assumed).
The permission prompt is therefore raised *without* blocking the commit, and its
answer re-runs the resolution.

**The card never overclaims.** "Scheduled for Fri 6:35 a.m." is only shown when
something will actually alert; registered-but-silenced reads "Nothing will wake
you…", and an unanswered prompt reads "Waiting for notification permission".

**Simulator note.** AlarmKit authorization is not reliably grantable in the
simulator: `mobiletimerd` either raises the real prompt (which no scripted run
can tap) or answers `AlarmKitCore.AuthorizationManager.AuthorizationManagerError
Code=1`. Both were observed on iOS 26.5 simulators.

## Log a reading

More → "Log a reading" opens `HCCLogReadingSheet`: a searchable metric picker
fed by `/api/mobile/v1/metrics`, a value field carrying the catalog's unit, a
time in the instance's timezone, an optional note, and
`POST /api/measurements` (a web route — bare `ok()`, 201
`{metric,value,written,skipped}`; 409 when a reading already exists at that
exact instant, whose server sentence is what the sheet shows).

The sheet never grades the value — `refLow`/`refHigh` arrive on the same payload
and are deliberately not rendered; a logging form is not where a value meets its
optimal target. It never converts either: the unit beside the field is the
catalog's, which is the unit the server stores.

"Recent on this iPhone" is the last five slugs logged **from this handset**,
held in `UserDefaults` (`hcc.readings.recentSlugs`). The server has no
"recently logged" endpoint and inferring one from the timeline would make the
shortcut disagree with itself the moment a reading arrived from a device — hence
the section title says whose fact it is.

### Debug hooks

| Variable | Effect |
|---|---|
| `HCC_DEBUG_OPEN_SCREEN=logReading` | Opens the Log-a-reading sheet from the More tab. |
| `HCC_DEBUG_OPEN_SCREEN=logReadingPicker` | Same sheet, opened straight onto its metric picker, so the picker can be screenshotted without a tap. |
| `HCC_DEBUG_SAVE=1` (on `logReading`) | Fills in a fixed `weight` 80.5 reading at "now" and runs the same `save()` the button calls. **It MUTATES SERVER STATE.** |
| `HCC_DEBUG_SAVE=1` (on `alarm`) | Nudges the wake time, flips the mode, saves, and — new in this phase — keeps the sheet open so the schedule card can be screenshotted. **It MUTATES SERVER STATE.** |
| `HCC_DEBUG_NOTIF_PROVISIONAL=1` | Takes PROVISIONAL notification authorization, which iOS grants with no prompt, so a scripted run can exercise the notification fallback. The shipping app NEVER requests provisional — a quiet Notification-Centre entry is not an alarm. DEBUG only. |

## The Coach (`HCCCoachSheet`, `HCCCoachChatModel`)

The mockup's floating bubble and the sheet behind it. The Coach is asked from
wherever the owner already is: `HCCCoachFAB` is overlaid on the cloud shell —
not on a screen — and the sheet it opens carries the name of the screen behind
it as `pageContext`, so a question about "this" resolves against what the owner
is looking at. The design review kept the bubble hidden until the chat actually
worked; it works now, and the placeholder sheet it used to open is gone.

### Where the code is

| File | What it holds |
|---|---|
| `HCC/HCCModels+Coach.swift` | The thread DTOs, the `POST /api/chat` request body, and `HCCCoachWire` — the parsing for the two markers the server frames a reply with. |
| `HCC/HCCAPIClient+Coach.swift` | The three JSON calls: list threads, load one, delete one. All `getBare`/`deleteBare`, because `/api/conversations*` answer `ok()`. |
| `HCC/Coach/HCCCoachChatModel.swift` | The `@MainActor ObservableObject` behind the sheet: threads, messages, the draft, staged attachments, and the streaming request. |
| `HCC/Coach/HCCCoachAttachments.swift` | Staging a photo or file: downscaling, size limits, MIME types. |
| `HCC/UI/HCCCoachSheet.swift` | The sheet: header, Chat/Conversations panes, bubbles, composer. |
| `HCC/UI/HCCCoachFAB.swift`, `AppShellView.swift` | The button and where it is mounted. |

### The one request that does not go through `HCCAPIClient`

`POST /api/chat` answers `text/plain; charset=utf-8` and writes the assistant's
reply as raw text chunks with **no framing** — no SSE, no JSON — and the thread
id comes back on the `x-conversation-id` **response header**. The client's single
`send` pipeline decodes a `Decodable` from a finished body and returns only that
value: there is no shape it could hand back that carries a live byte sequence
*and* a response header. So this one request is built in `HCCCoachChatModel`,
from `HCCSession.shared.baseURL` and `HCCSession.currentToken()`, and maps its
failures onto the same `HCCAPIError` cases — a 401 from the Coach is the same
`handleUnauthorized()` sign-out a 401 anywhere else is. Everything else Coach-
related goes through the client. **Do not take this as licence for a second HTTP
stack**: the rule is still one client, and this is the documented exception for
the one route that is not JSON.

Chunk boundaries do not respect character boundaries, so the reader decodes only
the part of its byte buffer that is a **complete** UTF-8 sequence and holds any
trailing partial character back for the next chunk
(`HCCCoachChatModel.takeCompleteUTF8`). Display updates are batched on a 50 ms
interval rather than fired per byte — live enough to read as typing, without
redrawing a long answer thousands of times.

### The two markers on a reply

Both are the server's, from `src/lib/intelligence/chat.ts`:

* **`<NUL>MEM:<n><NUL>`** closes every reply — how many durable memories that
  turn produced. It is a control sentinel and is **never shown**. Note the
  delimiter: a literal **NUL**, not a space. A hexdump of the wire reads like a
  space, and the first cut of this client matched `\s?MEM:\d+\s?$` and left the
  marker in the bubble as `…analysis.MEM:0` — invisible separator, visible
  marker. The patterns accept a NUL *or* whitespace either side. It is stripped
  on completion, and a partially-arrived one is stripped from the streaming
  display too, so it never flashes on screen.
* **`\n\n— Updated: …`** appears when the turn actually changed something (an
  insight, an action item, a protocol, a logged reading). That one **is** shown,
  muted, under the answer: a write the owner did not read about is a write they
  do not know happened.

### `sources ·` is the model's line, never ours

The mockup shows a muted `sources · …` line under an assistant bubble. It is
rendered **only** when the model's own text ends with a line beginning
`sources ·` or `Sources:` (`HCCCoachWire.splitSources`). Composing one out of
the metrics an answer happens to mention would be the phone inventing a citation
for someone else's sentence — the same rule as "never fabricate a value",
applied to provenance.

### Attachments

Mirrors the web client (`src/lib/attachments.ts`) value for value, because both
surfaces post to the same route: images are downscaled to a longest edge of
1568 px and re-encoded as JPEG at quality 0.85, base64 is bare (no `data:`
prefix), and at most six files ride on a message. The one place the phone is
stricter is the per-file ceiling — 5 MB against the web's 20 MB — because a
phone is usually on a metered link and a 20 MB PDF is a minutes-long upload with
nothing to show for it. Images are downscaled *before* the check, so the ceiling
only ever bites a large document.

### History

The visible thread is resent every turn, capped at the last 40 messages. Older
turns are **dropped, not summarised**: a summary the phone wrote would be the
phone putting words into the conversation, and the server keeps its own full
copy of the thread regardless.

### Debug hooks

The Coach is a sheet, and `simctl` cannot tap — without these no scripted run
could screenshot it. All are DEBUG-only. None of them fabricates an answer:
`HCC_DEBUG_COACH_PROMPT` asks the real server a real question and shows whatever
comes back.

| Variable | Effect |
|---|---|
| `HCC_DEBUG_OPEN_COACH=1` | Presents the Coach sheet on launch, over whichever tab `HCC_DEBUG_OPEN_TAB` selected. |
| `HCC_DEBUG_COACH_VIEW=conversations` | Opens the sheet on the thread drawer instead of the chat. |
| `HCC_DEBUG_COACH_PROMPT=<text>` | Sends `<text>` the moment the sheet appears. **It MUTATES SERVER STATE** — the server persists the turn and may create a thread. |
| `HCC_DEBUG_COACH_ATTACHMENT=1` | Stages one generated swatch (`debug-swatch.jpg`) so the attachment chip can be screenshotted without the photo picker. |

Verifying the stream against a dev server whose OpenAI key is revoked does not
work — a revoked key streams an error, not an answer. Start a second dev server
with the key explicitly **empty** (`OPENAI_API_KEY=''`, which `src/lib/env.ts`
treats as unset) and the route returns its static offline reply plus the
sentinel, which exercises the whole plain-text path end to end.

## Push, background refresh, widgets and the strain Live Activity

Everything in this section is cloud-mode only and lives behind
`HCCProviderSettings.isCloud`. Bridge mode asks for nothing, registers nothing
and wakes for nothing — a fork that changed how the local-only app behaves is a
fork upstream cannot merge.

### The app delegate

`OpenVitals/HCC/HCCAppDelegate.swift` is the app's only `UIApplicationDelegate`,
installed by a single line in `OpenVitalsApp` (`@UIApplicationDelegateAdaptor`).
It exists for the four things the SwiftUI lifecycle cannot express: the APNs
device token, a silent push's background-fetch result, the relaunch that
finishes a background HealthKit upload, and the `UNUserNotificationCenter`
delegate that decides what a tapped notification does.

A tapped notification is NOT routed inside the delegate. It reads the payload's
top-level `deepLink` and calls `UIApplication.open`, so a push tap goes through
the same `onOpenURL` → `AppRouter.handleDeepLink` path a link from anywhere else
does — one router, one set of destinations, one thing to test.

### The store the background paths use

The `HealthDataStore` is a `@StateObject` on the shell, so at launch — and in a
process woken by a silent push with no window at all — there is not one yet.
`HCCAppServices` (bottom of `HCCAppDelegate.swift`) closes that gap: the store
registers itself at the end of `performHCCRead`, a background wake that finds
none builds one, and work queued with `whenStoreAvailable(_:)` runs as soon as
either happens. There is never more than one store in the process.

### The token is a credential

`HCCPushRegistrar` posts the APNs token to `/api/mobile/v1/push-devices` and
nothing else ever touches it. It is never logged, never put in an error string
and never shown on a screen — More says "Registered 07:12", not a hex. A POST
happens only when the token changed or the last successful registration is over
24 h old, so a cold launch is not a write.

`environment` is `sandbox` in a Debug build and `production` otherwise. This is
not cosmetic: a sandbox token aimed at the production gateway comes back
`BadDeviceToken`, which the server's fan-out reads as a dead device and disables.

Sign-out unregisters BEFORE `clearCredentials()` — the DELETE is authenticated
with the bearer that is about to be deleted — and ends any running Live Activity.

### The two push rows are statements, not switches

"Morning recovery" and "Insight alerts" report the OS's answer and the server's;
they are not toggles, because nothing on this phone decides what the instance
sends. The footnote under the card says so. Only "Strain Live Activity" is a
real switch, because that one IS the phone's decision.

### The widget contract

A widget process is woken with no session and a few hundred milliseconds of
budget, so it cannot read the API. The app writes `summary.json`
(`HCCWidgetSummary`, in `OpenVitals/HCC/Shared/`, compiled into both targets)
into the App Group container `group.com.gatbontontech.openvitals-hcc` at the end of
every completed read, and the widgets draw that file. Nothing is computed on the
widget side; `HCCWidgetBridge` copies the same `hcc.homeByDate` entry Home draws
from, so the two can never disagree.

A `calibrating` score is treated as absent, exactly as it is on the rings, and
renders `--` beside the server's own reason — never 0.

When the App Group container is unavailable (an unsigned simulator build has no
entitlement), the write falls back to each process's own Application Support
directory and stamps `HCCWidgetStore.noGroupNote` onto the summary's `reason`.
That is deliberate: the two processes are then reading different files, and a
widget stuck on `--` is the App Group missing, not the data. More → Widgets
reports it as "Shared container — Unavailable".

The widget extension does not share `HCCTheme.swift`/`HCCRing.swift`: those
compile against `HCCModels.swift`, which would drag the whole DTO layer into the
extension. `OpenVitalsWorkoutLiveActivityExtension/HCC/HCCWidgetTheme.swift`
restates the handful of tokens it needs with the source line of each cited in
its header, and draws a minimal ring. The bundled fonts are app-target
resources, so the widgets use the same system fallbacks `HCCTheme.Font` would
resolve to in a process without them.

### The strain Live Activity

Off by default — a Live Activity is a persistent claim on the lock screen. It
starts only when the owner turns it on AND today has a strain value the server
is not still calibrating; no strain means no activity, because a bar sitting at
zero reads as "you have done nothing today". It is requested with
`pushType: .token` so the instance can drive it later; the token is kept in the
controller and **not** sent anywhere, because there is no route to accept it yet.
A running activity is reclaimed on launch (`Activity.activities.first`) so a
relaunch updates it rather than orphaning a banner nothing can end.

### Debug hooks

All DEBUG-only, all compiled out of Release.

| Variable | Effect |
|---|---|
| `HCC_DEBUG_DEEPLINK=openvitals://health/recovery` | Opens that link ~2 s after launch, through the same `UIApplication.open` a notification tap uses. `simctl` can deliver a push but cannot tap the banner it draws, so this is the only way to screenshot where a tap LANDS. |
| `HCC_DEBUG_SILENT_PUSH=1` | Hands the delegate the payload a silent push carries, through the real entry point. The Simulator does not deliver `aps.content-available` (an alert payload in the same run does arrive), so what stays unverified is Apple's delivery, not this app's handling. |
| `HCC_DEBUG_NOTIF_PROVISIONAL=1` | Shared with `HCCAlarmScheduler`. Grants provisional notification authorization, which is the only grant a script can obtain — a full prompt is a system alert and `simctl` cannot tap one. |
| `HCC_DEBUG_LIVE_ACTIVITY=1` | Turns the Live Activity switch on **for this launch only**; deliberately not written to defaults, so a verification run never leaves a setting the owner did not choose. |
| `HCC_DEBUG_LIVE_ACTIVITY_FIXTURE=1` | Starts the activity from fixture numbers so the presentation can be screenshotted on an instance whose scores are all still calibrating. The numbers are the hook's, not the instance's, and `sync(from:)` replaces them with the server's the moment a real score exists. |
| `HCC_DEBUG_SKIP_ALARM=1` | Leaves `HCCAlarmScheduler` unstarted. Starting it raises the AlarmKit permission alert on a fresh install, and a system alert cannot be dismissed by `simctl` — it blocks every other screenshot. |
| `HCC_DEBUG_OPEN_SCREEN=widgets` | Opens More → Widgets. (`notifications` is accepted too and opens no sheet — the card is on More itself, so landing there IS the screenshot.) |

Two things cannot be verified in the Simulator at all, and neither is a code
question: a real APNs token from Apple's gateway (the Simulator issues its own),
and any flow that needs a system permission alert tapped.

Verification needs entitlements, so the usual `CODE_SIGNING_ALLOWED=NO` build is
not enough — without `aps-environment` the app cannot register at all, and
without the App Group the widgets read a different file. Build with ad-hoc
signing instead and the simulated entitlements are embedded in the binary:

```sh
xcodebuild -project OpenVitals.xcodeproj -scheme OpenVitals \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" build
```

## The live workout screen (`HCCLiveSetupSheet`, `HCCLiveActivityView`)

`S.live` from the mockup: the heart rate right now, the zone it is in, and what
the session has added up to so far. Reached from Home's "◉ Start activity" and
from a Training conditioning day's "Start live activity" — the same setup sheet
in both cases, pre-filled with the day's title when it comes from Training.

Files:

| File | What it holds |
|---|---|
| `HCC/Live/HCCLiveHeartRateSource.swift` | the `HCCLiveHeartRateSource` protocol, `HCCHeartRateSample`, `HCCLiveSourceKind`, and the DEBUG synthetic source |
| `HCC/Live/HCCBLEHeartRateSource.swift` | a standalone `CBCentralManager` for the standard 0x180D / 0x2A37 heart-rate service |
| `HCC/Live/HCCWatchMirrorSource.swift` | the HealthKit workout-mirroring handler and the watch↔phone message contract |
| `HCC/Live/HCCZones.swift` | the pure zone/strain arithmetic and its self-check |
| `HCC/HealthDataStore+HCCLive.swift` | `HCCLiveState` and the one write the feature makes |
| `HCC/HCCModels+Live.swift`, `HCC/HCCAPIClient+Live.swift` | the POST body and the route |
| `HCC/UI/HCCLiveSetupSheet.swift`, `HCC/UI/HCCLiveActivityView.swift` | the two screens |

### The phone's number is never the stored number

"Strain so far" is the phone's own arithmetic over the zone time accumulated on
the device, and it is labelled **est.** everywhere it appears. When the session
ends, the phone posts the window, the heart-rate series and the zone durations;
the SERVER computes the strain from them, and the activity screen this hands off
to shows that number. The running estimate is never written anywhere.

The big number is the last reading a source actually delivered. Twenty seconds
without one and it becomes `--` with the source's own status line underneath — a
held value under a live heading would be a fabricated measurement. kcal shows
only when the source reports energy; heart rate is not turned into calories here.

### Zone cuts come from the server, and the screen says which ceiling it used

`GET /api/mobile/v1/instance` carries `zones: {maxHr, floors[6], method}`.
`HCCZones` bins against those, on %HRR when today's resting HR is known (from
`/home`) and on %HRmax otherwise — the rule `binHrSamplesToZoneMs` applies. The
fallback, used before `/instance` lands, is the value the server currently
publishes, and the footnote says whether the ceiling shown is the instance's or
the default.

**That ceiling is a placeholder today** (`PLACEHOLDER_MAX_HR = 190` in
`src/lib/activities/zones.ts`). Because the phone uploads `zoneMs`, the server
takes the strain as measured and stores `strainEstimated: false` — a stronger
claim than the evidence, and the reason the running screen states the ceiling in
full. Publishing a measured max HR per instance is what makes the flag true.

Server indices run 0…5 and index 0 is "below zone 1", not Z1: the bars here draw
indices 1…5 as Z1…Z5, and a reading in index 0 gets a chip that says so.

### Zone accumulation

Each reading owns the stretch that follows it, capped at two minutes
(`MAX_SAMPLE_GAP_MS`), and a paused stretch is credited to nothing. The running
total therefore lags one sampling interval — the server's median-gap tail is a
closing adjustment on a finished series, meaningless while it is still growing.

`HCCZones.strain` is a 1:1 port of `zoneMsToBuckets` + `strainFromZoneMinutes`.
Checked, not assumed: `HCC_DEBUG_ZONES_CHECK=1` prints the same fixtures a node
run of `src/lib/activities/zones.ts` prints. Both agree to nine decimal places
(10.691040917 and 12.291009082) and on all twelve zone assignments.

### Sources

- **Apple Watch** — `HKHealthStore.workoutSessionMirroringStartHandler`. The
  WATCH starts the session and mirrors it; the phone becomes its delegate and
  decodes `{"t":"hr","bpm":Int,"at":unix}`, `{"t":"kcal","value":Double}` and
  `{"t":"batt","level":Double}`. Call `HCCWatchMirrorSource.installHandler()`
  once at launch — a mirrored session can arrive before any screen exists.
  `associatedWorkoutBuilder` is deliberately not called on a mirrored session:
  the header documents that it throws for a session not created with
  `init(healthStore:configuration:)`. The Watch companion is a later workstream,
  so the format above is a contract, not something already in use.
- **Bluetooth** — its own `CBCentralManager`, modelled on
  `OpenVitalsRRReferenceCapture`. It is NOT routed through `OpenVitalsBLEClient`,
  which is brand-gated and disconnects any peripheral without vendor evidence
  even when that peripheral offers 0x180D. Copy names no manufacturer.
- **Synthetic** (`HCC_DEBUG_FAKE_HR=1`, DEBUG only) — a 60→165 bpm ramp at 1 Hz
  with accruing kcal. The only source a simulator has.

### Verification hooks (DEBUG)

| Variable | Effect |
|---|---|
| `HCC_DEBUG_OPEN_SHEET=live` | Home presents the live setup sheet on launch |
| `HCC_DEBUG_FAKE_HR=1` | offers and defaults to the synthetic source |
| `HCC_DEBUG_LIVE=start` | starts the session two seconds after the sheet appears |
| `HCC_DEBUG_LIVE_PAUSE_AFTER=<s>` | pauses that many seconds after the start |
| `HCC_DEBUG_LIVE_END_AFTER=<s>` | ends and SAVES that many seconds after the pause (or the start) |
| `HCC_DEBUG_ZONES_CHECK=1` | prints the zone/strain fixtures |
| `HCC_DEBUG_WATCH_WIRE=1` | prints the decode of one of each watch message |

`HCC_DEBUG_LIVE_END_AFTER` **writes an activity** to whatever backend the run
points at, so it belongs against a local test instance only.

## The watchOS companion (`HCCWatch`)

A second, separate target — a "Watch App for iOS App", bundle id
`com.gatbontontech.openvitals-hcc.watchkitapp`, `WKCompanionAppBundleIdentifier`
pointing back at `com.gatbontontech.openvitals-hcc`. It shares **no code** with the
iPhone build: no HCC design system, no `HCCAPIClient`, no token, no server call.
Four files under `HCCWatch/` and one screen.

It exists because of a fact about the OS, not a design preference: the phone
cannot start an `HKWorkoutSession`. Only the watch can. So the watch owns the
session and the sensor, and the phone owns every screen.

| File | What it is |
|---|---|
| `HCCWatch/HCCWatchApp.swift` | `@main`; activates battery reporting at launch |
| `HCCWatch/HCCWatchContentView.swift` | the one screen: heart rate, elapsed clock, Start/End |
| `HCCWatch/HCCWatchWorkoutManager.swift` | the session, the live builder, and the send side of the mirror |
| `HCCWatch/HCCWatchBattery.swift` | `WKInterfaceDevice` battery + the `WCSession` relay |
| `OpenVitals/HCC/Live/HCCWatchConnectivity.swift` | the PHONE side of that relay |

The screen is plain watchOS rather than the phone's design system on purpose:
that system is built on registered custom fonts and a card chassis belonging to
the iPhone target, and pulling it across for two labels and a button would tie a
thin companion to a large dependency for nothing. No reading is ever held over —
no heart rate yet, or a session that is not running, shows `--`.

### The two links, and why there are two

**During a workout — the mirrored session.** `start()` begins collection, then
calls `startMirroringToCompanionDevice()`, which launches the iPhone app in the
background and hands it the same session through the handler
`HCCWatchMirrorSource.installHandler()` installed at launch. Readings then travel
as the three messages that source documents, encoded here by `WireMessage` with
the same field names its `Message` decodes. Energy is only sent when the
cumulative total actually moves (0.5 kcal), because the link is capped at 100 KB
per 10 s. A send failure is swallowed: the phone reads a gap as a gap and shows
`--`, which is truer than a heart rate resent a second late.

**Outside a workout — `WCSession`.** The mirrored session lives only as long as
the workout, so the watch also pushes its battery on every activation as an
application context, `{"watchBattery": Double, "at": unix}`.
`updateApplicationContext` keeps exactly one dictionary, always the newest,
delivered whenever the phone next runs — right for a level, wrong for anything
historical, which is why nothing else travels this way.

`HCCWatchConnectivity` on the phone hands what it receives to
`HCCWatchMirrorSource.handle(payload:)` as a `batt` message rather than writing
it anywhere directly, so the watch's battery has ONE decoder and ONE route
whichever link it arrived on — and that route already feeds
`HCCLiveState.watchBattery` through `onBatteryChanged`. The consequence is worth
stating: outside a live session with the watch source selected nothing is
listening, so the value stops at `HCCWatchMirrorSource.shared.battery`. No screen
draws a watch battery yet. A context with no usable level, or one older than 12
hours, is dropped rather than shown — a day-old percentage presented as current
would be a fabricated reading.

### Building it

**The watch app is defined in the project but NOT embedded in the iOS app**, and
that is a deliberate, reversible state. Xcode refuses to build *any* scheme that
embeds a watch app unless the matching watchOS platform is installed:

```
xcodebuild: error: Failed to build project OpenVitals with scheme OpenVitals.:
This scheme builds an embedded Apple Watch app. watchOS 26.5 must be installed
in order to run the scheme
```

This Mac has the watchOS **SDKs** but no watchOS platform/runtime, and installing
one is a 3.96 GB download onto a boot volume that was at 98 % with 20 GB free. So
the `Embed Watch Content` copy phase and the `HCCWatch` target dependency are
defined in `project.pbxproj` but not referenced from the OpenVitals target, which
keeps the everyday build green for everyone. Turning it on is two lines:

```
python3 <scratch>/p4w-embed-watch.py on     # or: off | status
xcodebuild -downloadPlatform watchOS        # ~4 GB, needed first
```

Until then the watch app is built on its own, by target rather than by scheme —
scheme builds need a destination and destinations need a runtime:

```
xcodebuild -project OpenVitals.xcodeproj -target HCCWatch -sdk watchsimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  SYMROOT=<out>/Products OBJROOT=<out>/Intermediates.noindex build
```

`-sdk watchos -configuration Release` builds the same target for real hardware
(arm64_32 + arm64). A shared `HCCWatch` scheme exists for Xcode; it will resolve
a destination once a watchOS runtime is installed.

### Verification hooks (DEBUG)

| Variable | Effect |
|---|---|
| `HCC_DEBUG_WATCH_CONTEXT=1` | phone side: decodes five `WCSession` contexts — fresh, unstamped, 24 h old, level-less, out of range — and prints what each routed to and what the mirror source holds afterwards |

The watch app itself cannot be run here: `xcrun simctl list runtimes` has no
watchOS entry and `xcrun simctl list pairs` is empty, so nothing can be paired
and nothing can be booted. What IS checked is that the two halves of the wire
agree — the watch's encoder and the phone's decoder, run over the same three
messages in one process, produce and accept the identical JSON.
