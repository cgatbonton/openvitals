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

No manufacturer name reaches the interface (AGENTS.md). The server's
`origin: "whoop"` renders as **"band"**; `origin: "computed"` renders as
**"Command Center"**, because that origin means the server's own scoring engine
and not any particular wrist. `HCCCopy.originLabel` / `HCCCopy.sourceLabel` are
the only place that mapping lives — route new labels through them.

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
  xcrun simctl launch --console-pty booted com.gatbontontech.openvitals
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
