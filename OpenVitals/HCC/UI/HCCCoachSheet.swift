import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// HCC: the mockup's `.sheet` — the Coach, over whatever screen it was opened
// from. Header ("Coach" / "Asks your command center, with your data in
// context" / ×), the message list, and a composer pinned to the bottom.
//
// Two things this screen will not do:
//
//  * **It never writes a `sources ·` line.** The mockup shows one under an
//    assistant bubble, and it appears here ONLY when the model's own text ends
//    with such a line (`HCCCoachWire.splitSources`). Composing one out of the
//    metrics the answer happens to mention would be the phone inventing a
//    citation for someone else's sentence.
//  * **It never shows a control that does nothing.** Send is Stop while a reply
//    is arriving; the paperclip disappears at six files rather than sitting
//    there dead; a failed turn shows the server's own message with a Retry that
//    resends the same question.
//
// The thread drawer is a second view of the same sheet rather than a separate
// screen — the mockup has one sheet, and a push would put chrome above chrome.

struct HCCCoachSheet: View {
  @ObservedObject var model: HCCCoachChatModel
  /// A short label naming the screen the Coach was opened from, e.g.
  /// `mobile:home 2026-09-03`. The server uses it to resolve a contextual
  /// question ("what does this mean") against the right page.
  let pageContext: String

  @Environment(\.dismiss) private var dismiss

  private enum Pane: Hashable {
    case chat
    case threads
  }

  @State private var pane: Pane = .chat
  @State private var photoSelection: [PhotosPickerItem] = []
  @State private var showsAttachOptions = false
  @State private var showsPhotoPicker = false
  @State private var showsFileImporter = false
  @State private var didAppear = false
  @State private var lastSentPrompt: String?

  private static let bottomAnchor = "hcc.coach.bottom"

  var body: some View {
    VStack(spacing: 0) {
      header
      HCCSegmentedControl(
        options: [
          .init(value: Pane.chat, title: "Chat"),
          .init(value: Pane.threads, title: "Conversations"),
        ],
        selection: $pane
      )
      .padding(.horizontal, 16)

      switch pane {
      case .chat:
        messageList
        composer
      case .threads:
        threadList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .hccBackground()
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationBackground(HCCTheme.Color.bg)
    .confirmationDialog("Attach", isPresented: $showsAttachOptions, titleVisibility: .hidden) {
      Button("Photo") { showsPhotoPicker = true }
      Button("File") { showsFileImporter = true }
      Button("Cancel", role: .cancel) {}
    }
    .photosPicker(
      isPresented: $showsPhotoPicker,
      selection: $photoSelection,
      maxSelectionCount: max(1, HCCCoachAttachmentLimits.maxCount - model.attachments.count),
      matching: .images
    )
    .onChange(of: photoSelection) { _, items in
      guard !items.isEmpty else { return }
      photoSelection = []
      Task { await stagePhotos(items) }
    }
    .fileImporter(
      isPresented: $showsFileImporter,
      allowedContentTypes: HCCCoachAttachmentLimits.importedTypes,
      allowsMultipleSelection: true
    ) { result in
      if case let .success(urls) = result { model.attachFiles(urls) }
    }
    .task { await model.refreshConversations() }
    .onAppear(perform: onFirstAppear)
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Coach")
          .font(HCCTheme.Font.display(size: 20, weight: .medium))
          .tracking(-0.4)
          .foregroundStyle(HCCTheme.Color.text)
        Text("Asks your command center, with your data in context")
          .font(HCCTheme.Font.body(size: 11.5))
          .foregroundStyle(HCCTheme.Color.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      if pane == .threads {
        Button { newThread() } label: {
          Text("New")
            .font(HCCTheme.Font.body(size: 11, weight: .medium))
            .foregroundStyle(HCCTheme.Color.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(glass(radius: 10))
        }
        .buttonStyle(.plain)
      }

      Button { dismiss() } label: {
        Text("×")
          .font(.system(size: 22, weight: .regular))
          .foregroundStyle(HCCTheme.Color.text)
          .frame(width: 32, height: 32)
          .background(glass(radius: 10))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if model.messages.isEmpty {
            HCCEmptyNote("Ask about a score, a lab, a protocol, or what today should look like.")
              .padding(.top, 24)
          }
          ForEach(model.messages) { message in
            HCCCoachBubble(message: message)
          }
          if let failure = model.stream.failure {
            HCCErrorNote(failure, title: "Not answered", retry: retryLastPrompt)
              .hccCard()
          }
          Color.clear.frame(height: 1).id(Self.bottomAnchor)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
      }
      .scrollIndicators(.hidden)
      .onChange(of: model.messages.last?.text) { _, _ in scrollToEnd(proxy) }
      .onChange(of: model.messages.count) { _, _ in scrollToEnd(proxy) }
    }
  }

  private func scrollToEnd(_ proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.15)) {
      proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }
  }

  // ── Composer ───────────────────────────────────────────────────────────────

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !model.attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(model.attachments) { attachment in
              HCCCoachAttachmentChip(attachment: attachment) { model.removeAttachment(attachment) }
            }
          }
        }
        .scrollIndicators(.hidden)
        .frame(height: 44)
      }

      if let attachmentError = model.attachmentError {
        Text(attachmentError)
          .font(HCCTheme.Font.body(size: 11.5))
          .foregroundStyle(HCCTheme.Color.warn)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        if model.canAttachMore {
          attachButton
        }

        TextField(
          "",
          text: $model.draft,
          prompt: Text("Ask about your data…").foregroundColor(HCCTheme.Color.muted),
          axis: .vertical
        )
        .lineLimit(1...5)
        .font(HCCTheme.Font.body(size: 13))
        .foregroundStyle(HCCTheme.Color.text)
        .textInputAutocapitalization(.sentences)
        .submitLabel(.send)

        sendButton
      }
      .padding(.leading, 12)
      .padding(.trailing, 8)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
          .fill(HCCTheme.Color.card)
      )
      .overlay(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
          .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
      )
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }

  // A photo goes through the same picker the rest of iOS uses, and is downscaled
  // before it leaves the phone (see `HCCCoachAttachments`). The button offers the
  // choice rather than guessing: a lab PDF and a photo of a meal are both normal
  // things to send here.
  private var attachButton: some View {
    Button {
      showsAttachOptions = true
    } label: {
      Image(systemName: "paperclip")
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(HCCTheme.Color.muted)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Attach a file")
  }

  private var sendButton: some View {
    Button {
      if model.stream.isStreaming {
        model.stop()
      } else {
        lastSentPrompt = model.draft
        model.send(pageContext: pageContext)
      }
    } label: {
      Image(systemName: model.stream.isStreaming ? "stop.fill" : "arrow.up")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.bg)
        .frame(width: 30, height: 30)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(sendEnabled ? HCCTheme.Color.accent : HCCTheme.Color.band)
        )
    }
    .buttonStyle(.plain)
    .disabled(!sendEnabled)
    .accessibilityLabel(model.stream.isStreaming ? "Stop" : "Send")
  }

  private var sendEnabled: Bool { model.stream.isStreaming || model.canSend }

  private func stagePhotos(_ items: [PhotosPickerItem]) async {
    for item in items {
      guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
      let name = item.itemIdentifier.map { "photo-\($0.prefix(8)).jpg" } ?? "photo.jpg"
      model.attachImage(data: data, name: name)
    }
  }

  private func retryLastPrompt() async {
    guard let prompt = lastSentPrompt, !prompt.isEmpty else { return }
    model.draft = prompt
    model.send(pageContext: pageContext)
  }

  // ── Threads ────────────────────────────────────────────────────────────────

  private var threadList: some View {
    Group {
      if model.conversations.isEmpty {
        VStack(spacing: 10) {
          if model.isLoadingConversations {
            HCCLoadingNote(text: "Loading your conversations…")
          } else if let listError = model.listError {
            HCCErrorNote(listError, title: "Not loaded") { await model.refreshConversations(force: true) }
              .hccCard()
          } else {
            HCCEmptyNote("No conversations yet. Ask something and this is where it lands.")
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      } else {
        List {
          ForEach(model.conversations) { summary in
            Button { openThread(summary) } label: {
              HCCCoachThreadRow(summary: summary, isCurrent: summary.id == model.current?.id)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
          }
          .onDelete(perform: deleteThreads)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .refreshable { await model.refreshConversations(force: true) }
      }
    }
  }

  private func openThread(_ summary: HCCConversationSummary) {
    Task {
      await model.open(summary)
      pane = .chat
    }
  }

  private func deleteThreads(at offsets: IndexSet) {
    let targets = offsets.map { model.conversations[$0] }
    Task {
      for target in targets { await model.delete(target) }
    }
  }

  private func newThread() {
    model.startNewThread()
    pane = .chat
  }

  // ── Chrome ─────────────────────────────────────────────────────────────────

  private func glass(radius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return shape
      .fill(HCCTheme.Color.card2)
      .overlay(shape.strokeBorder(HCCTheme.Color.line, lineWidth: 1))
  }

  private func onFirstAppear() {
    guard !didAppear else { return }
    didAppear = true
    #if DEBUG
    if HCCCoachChatModel.debugWantsConversations { pane = .threads }
    model.applyDebugLaunchStateIfNeeded()
    if let prompt = HCCCoachChatModel.debugPrompt, model.messages.isEmpty {
      model.draft = prompt
      lastSentPrompt = prompt
      model.send(pageContext: pageContext)
    }
    #endif
  }
}

// ── Bubble ───────────────────────────────────────────────────────────────────

/// `.msg.me` / `.msg.ai` — 86 % max width, 14-pt corners with the corner nearest
/// the speaker squared off to 4, accent-on-dark for the owner and card-with-a-
/// hairline for the Coach.
private struct HCCCoachBubble: View {
  let message: HCCCoachChatModel.Message

  private var isUser: Bool { message.role == .user }

  private var parts: (body: String, sources: String?) {
    guard !isUser else { return (message.displayText, nil) }
    return HCCCoachWire.splitSources(message.displayText)
  }

  var body: some View {
    // The mockup's `max-width:86%` expressed as the gutter it leaves rather than
    // as a fraction of a screen width read off `UIScreen` — the sheet, not the
    // device, is what a bubble is 86 % of.
    HStack(spacing: 0) {
      if isUser { Spacer(minLength: 48) }
      bubble
      if !isUser { Spacer(minLength: 48) }
    }
  }

  private var bubble: some View {
    let split = parts
    return VStack(alignment: .leading, spacing: 6) {
      if split.body.isEmpty && message.isStreaming {
        // A reply that has been asked for but has not started: three dots, not
        // a spinner, so the bubble is already the shape the text will fill.
        Text("···")
          .font(HCCTheme.Font.data(size: 13, weight: .medium))
          .foregroundStyle(HCCTheme.Color.muted)
      } else {
        Text(split.body)
          .font(HCCTheme.Font.body(size: 13))
          .lineSpacing(4)
          .foregroundStyle(isUser ? HCCTheme.Color.bg : HCCTheme.Color.text)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let sources = split.sources {
        Text(sources)
          .font(HCCTheme.Font.data(size: 10))
          .tracking(0.4)
          .foregroundStyle(HCCTheme.Color.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      // The server's deterministic receipt for anything the turn changed. It is
      // shown because a write the owner did not read about is a write they do
      // not know happened.
      if let footer = message.footer, !footer.isEmpty {
        Text(footer)
          .font(HCCTheme.Font.data(size: 10.5))
          .foregroundStyle(HCCTheme.Color.accent)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(bubbleShape.fill(isUser ? HCCTheme.Color.accent : HCCTheme.Color.card))
    .overlay(isUser ? nil : bubbleShape.strokeBorder(HCCTheme.Color.line, lineWidth: 1))
  }

  private var bubbleShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: 14,
      bottomLeadingRadius: isUser ? 14 : 4,
      bottomTrailingRadius: isUser ? 4 : 14,
      topTrailingRadius: 14,
      style: .continuous
    )
  }
}

// ── Attachment chip ──────────────────────────────────────────────────────────

private struct HCCCoachAttachmentChip: View {
  let attachment: HCCCoachAttachment
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if let thumbnail = attachment.thumbnail {
        Image(uiImage: thumbnail)
          .resizable()
          .scaledToFill()
          .frame(width: 28, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      } else {
        Image(systemName: "doc")
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(HCCTheme.Color.muted)
          .frame(width: 28, height: 28)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(attachment.name)
          .font(HCCTheme.Font.body(size: 11.5, weight: .medium))
          .foregroundStyle(HCCTheme.Color.text)
          .lineLimit(1)
        Text(HCCCoachByteFormat.string(attachment.byteCount))
          .font(HCCTheme.Font.data(size: 10))
          .foregroundStyle(HCCTheme.Color.muted)
      }

      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(HCCTheme.Color.muted)
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(attachment.name)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: 220)
    .background(
      RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
        .fill(HCCTheme.Color.card2)
    )
    .overlay(
      RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
        .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
    )
  }
}

// ── Thread row ───────────────────────────────────────────────────────────────

private struct HCCCoachThreadRow: View {
  let summary: HCCConversationSummary
  let isCurrent: Bool

  private static let relative: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  private var subtitle: String {
    let count = "\(summary.messageCount) message\(summary.messageCount == 1 ? "" : "s")"
    guard let date = summary.updatedAtDate else { return count }
    return "\(count) · \(Self.relative.localizedString(for: date, relativeTo: Date()))"
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        // A thread the server has not titled yet says so; the phone does not
        // make a title up out of its first message.
        Text(summary.title ?? "Untitled conversation")
          .font(HCCTheme.Font.body(size: 13.5, weight: .medium))
          .foregroundStyle(HCCTheme.Color.text)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Text(subtitle)
          .font(HCCTheme.Font.data(size: 11))
          .foregroundStyle(HCCTheme.Color.muted)
      }
      Spacer(minLength: 8)
      if isCurrent {
        HCCChip("Open")
      }
      Text("›")
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(HCCTheme.Color.muted)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .hccCard()
  }
}
