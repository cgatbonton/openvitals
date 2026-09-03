import SwiftUI

// `S.customize` from the approved mockup: which tiles the home dashboard shows,
// and in what order.
//
// The mockup is a flat list of switches with a footnote saying "Drag to reorder
// in the real app". This is the real app, so the list is split into the tiles
// that are shown — reorderable — and the ones that are not. A switch alone
// cannot express an order, and the order is half of what this screen saves.
//
// The catalog comes from the server on `/dashboard`. Shipping a second copy of
// it in the app bundle would mean a tile renamed on the server keeps its old
// label on the phone, which is exactly the duplicated-fact drift this project
// avoids everywhere else.
//
// ── Only what the API can serve ──────────────────────────────────────────────
// The catalog lists every tile the design has, including several the read API
// cannot fill yet (steps, average heart rate, VO₂ max). Offering those would be
// offering an empty tile: the switch turns on and the dashboard shows nothing.
// So this sheet lists only the tiles whose data the server is actually sending
// on this account, derived from the payloads already in the store — `/vitals`
// for the metric tiles, `/sleep/plan` for the sleep-derived ones, `/scores` for
// the graph. Where the server sends `available` per catalog entry — it does on
// current builds — that field IS the answer and the derivation is not consulted;
// the derivation stays as the fallback for an older instance.

struct HCCCustomizeSheet: View {
  @ObservedObject var store: HealthDataStore
  @Environment(\.dismiss) private var dismiss

  @State private var shown: [String] = []
  @State private var hidden: [String] = []
  /// Slugs the account has saved that this build cannot offer a switch for.
  /// Held so that saving a layout never silently drops a tile the user chose
  /// on the web, or before a stream stopped reporting.
  @State private var retained: [String] = []
  /// The slugs the account's saved layout already names. They stay offerable
  /// even if their stream is momentarily missing from the store — otherwise a
  /// save from this sheet would quietly delete a tile the user had chosen.
  @State private var alreadyChosen: Set<String> = []
  @State private var isSaving = false
  @State private var errorText: String?
  @State private var didPrefill = false

  /// The layout a fresh account opens with — the five the design review picked,
  /// in that order. Applied only when the server says it is serving its own
  /// default, i.e. this user has never chosen a layout.
  private static let firstLaunchDefault = [
    "strain_recovery_graph",
    "rhr",
    "hrv",
    "wrist_temp",
    "sleep_debt",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCDetailHeader(title: "Customize dashboard", subtitle: "Choose tiles and their order")
      .padding(.horizontal, 16)
      .padding(.top, 14)

      if catalog.isEmpty {
        HCCEmptyNote(
          store.hcc.dashboard == nil
            ? "The tile catalog has not loaded yet."
            : "No tiles yet — your Command Center is not sending data any tile can draw."
        )
        .hccCard()
        .padding(.horizontal, 16)
        Spacer(minLength: 0)
      } else {
        list
      }

      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .hccBackground()
    .onAppear(perform: prefillIfNeeded)
    // Same as the alarm sheet: the dashboard may still be loading when this
    // opens, and `didPrefill` only latches once a catalog has arrived.
    .onChange(of: store.hcc.dashboard?.tiles ?? []) { _, _ in prefillIfNeeded() }
    // Availability is read off several payloads that land at different moments
    // in one refresh. Waiting for the refresh to FINISH is what stops the sheet
    // from deciding a tile is unavailable simply because its read had not
    // returned yet — a race that, before this guard, dropped the graph tile.
    .onChange(of: store.healthMetricRefreshIsRunning) { _, _ in prefillIfNeeded() }
  }

  // ── List ───────────────────────────────────────────────────────────────────

  private var list: some View {
    List {
      Section {
        ForEach(shown, id: \.self) { slug in
          tileRow(slug, isShown: true)
        }
        .onMove(perform: move)
        if shown.isEmpty {
          HCCEmptyNote("No tiles. Turn one on below.")
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      } header: {
        HCCLabel("Shown · drag to reorder")
      }

      if !hidden.isEmpty {
        Section {
          ForEach(hidden, id: \.self) { slug in
            tileRow(slug, isShown: false)
          }
        } header: {
          HCCLabel("Not shown")
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollIndicators(.hidden)
    .environment(\.editMode, .constant(.active))
    .disabled(isSaving)
  }

  private func tileRow(_ slug: String, isShown: Bool) -> some View {
    HStack(spacing: 10) {
      Text(label(for: slug))
        .font(HCCTheme.Font.body(size: 13))
        .foregroundStyle(HCCTheme.Color.text)
      Spacer(minLength: 8)
      // A `Button` rather than the tap gesture `HCCToggleRow` uses: a row inside
      // an editing List swallows plain tap gestures, and a switch that only
      // works outside edit mode is worse than no switch.
      Button {
        toggle(slug, isShown: isShown)
      } label: {
        HCCSwitch(isOn: .constant(isShown))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(label(for: slug))
      .accessibilityValue(isShown ? "Shown" : "Not shown")
      .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
    }
    .padding(.vertical, 4)
    .listRowBackground(
      RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
        .fill(HCCTheme.Color.card2)
        .overlay(
          RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
            .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        )
        .padding(.vertical, 2)
    )
    .listRowSeparator(.hidden)
  }

  // ── Footer ─────────────────────────────────────────────────────────────────

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let errorText {
        HCCEmptyNote(errorText).hccCard()
      }
      HCCButtonRow(
        primary: HCCButtonSpec(title: "Save", isEnabled: !isSaving && !catalog.isEmpty, action: save),
        secondary: HCCButtonSpec(title: "Cancel", isEnabled: !isSaving) { dismiss() }
      )
      HCCFootnote("Saved to your account, so the web dashboard shows the same layout. Tiles your Command Center is not sending data for yet are not listed.")
        .padding(.top, 10)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
  }

  // ── State ──────────────────────────────────────────────────────────────────

  /// The whole catalog, unfiltered.
  private var fullCatalog: [HCCDashboardTile] { store.hcc.dashboard?.catalog ?? [] }

  /// The catalog this build can honestly offer a switch for.
  private var catalog: [HCCDashboardTile] {
    fullCatalog.filter { isAvailable($0) || (!serverReportsAvailability && alreadyChosen.contains($0.slug)) }
  }

  /// True when this instance answers the availability question itself.
  private var serverReportsAvailability: Bool { fullCatalog.contains { $0.available != nil } }

  private func label(for slug: String) -> String {
    fullCatalog.first { $0.slug == slug }?.label ?? slug
  }

  /// Can the server fill this tile on this account, right now?
  ///
  /// Derived from what the store has already read rather than guessed from the
  /// slug, so an account that starts reporting steps gets the tile without an
  /// app update. `/vitals` is the authority for the metric tiles: a tile whose
  /// metric has no series is a tile with nothing to draw.
  private func isAvailable(_ tile: HCCDashboardTile) -> Bool {
    // The server's own answer wins wherever it gives one — it knows about
    // streams this client never reads.
    if let available = tile.available { return available }
    switch tile.kind {
    case "metric":
      guard let slug = tile.metricSlug else { return false }
      return store.hcc.vitals.contains { $0.slug == slug }
    case "graph":
      return !store.hcc.scoreDays.isEmpty
    case "derived":
      // The two sleep terms come off `/sleep/plan`; weekly strain off `/scores`.
      switch tile.slug {
      case "sleep_debt", "sleep_need": return store.hcc.sleepPlan != nil
      default: return !store.hcc.scoreDays.isEmpty
      }
    case "list":
      return true
    default:
      return false
    }
  }

  private func prefillIfNeeded() {
    guard !didPrefill,
          let dashboard = store.hcc.dashboard,
          // See the `.onChange` above: availability is only meaningful once the
          // refresh that fills `/vitals`, `/scores` and `/sleep/plan` is done.
          !store.healthMetricRefreshIsRunning
    else { return }
    didPrefill = true
    // `isDefault` means the server is serving its built-in order because this
    // user has never chosen one — the moment to apply the design's first-launch
    // layout rather than the catalog's full order.
    let base = dashboard.isDefault ? Self.firstLaunchDefault : dashboard.tiles
    let chosenBase = Set(base)
    alreadyChosen = chosenBase
    // Computed from the LOCAL set rather than through `catalog`: a `@State`
    // write is not visible to a read in the same call, and reading the stale
    // value here is what would drop a chosen tile.
    let offerableTiles = fullCatalog.filter {
      isAvailable($0) || (!serverReportsAvailability && chosenBase.contains($0.slug))
    }
    let offerable = Set(offerableTiles.map(\.slug))
    shown = base.filter(offerable.contains)
    let chosen = Set(shown)
    hidden = offerableTiles.map(\.slug).filter { !chosen.contains($0) }
    // Anything saved that this build cannot offer is carried, not discarded.
    retained = dashboard.isDefault ? [] : dashboard.tiles.filter { !offerable.contains($0) }
    #if DEBUG
    runDebugSaveIfRequested()
    #endif
  }

  #if DEBUG
  /// Verification hook, DEBUG only — see the same method on `HCCAlarmSheet`.
  /// `HCC_DEBUG_SAVE=1` moves the first shown tile to the end and runs the SAME
  /// `save()` the button calls, so the write can be proved from a simulator run
  /// with no UI automation. Compiled out of Release.
  private func runDebugSaveIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_SAVE"] == "1", shown.count > 1 else {
      return
    }
    shown.append(shown.removeFirst())
    save()
  }
  #endif

  private func move(from offsets: IndexSet, to destination: Int) {
    shown.move(fromOffsets: offsets, toOffset: destination)
  }

  private func toggle(_ slug: String, isShown: Bool) {
    if isShown {
      shown.removeAll { $0 == slug }
      // Back to the catalog's own order, so turning a tile off and on again
      // does not silently reshuffle the list it came from.
      hidden = catalog.map(\.slug).filter { !shown.contains($0) }
    } else {
      hidden.removeAll { $0 == slug }
      shown.append(slug)
    }
  }

  private func save() {
    guard !isSaving else { return }
    isSaving = true
    errorText = nil
    // The retained slugs ride along so a save from this build cannot delete a
    // tile it never showed. They go last because this sheet has no position for
    // them; they draw nothing until their stream comes back either way.
    let tiles = shown + retained.filter { !shown.contains($0) }
    Task {
      if await store.saveDashboard(tiles: tiles) {
        isSaving = false
        dismiss()
        return
      }
      errorText = store.hcc.lastError ?? "That did not save. The dashboard is unchanged."
      isSaving = false
    }
  }
}
