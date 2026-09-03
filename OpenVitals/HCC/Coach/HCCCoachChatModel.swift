import Foundation
import SwiftUI
import UIKit

// HCC: the Coach — "ask your command center, with your data in context".
//
// The Coach is one sheet over whatever screen the owner is on, and this is the
// object behind it. Everything it knows comes from the server: the threads, the
// messages in them, and the answer arriving a chunk at a time. Nothing is
// composed, summarised or cached here — a reply is exactly the bytes the server
// wrote, minus the two markers it frames them with.
//
// ── Why the stream is not an `HCCAPIClient` call ─────────────────────────────
// Every other call in this app goes through `HCCAPIClient`, and this one wants
// to: same bearer, same base URL, same 401 handling. But `/api/chat` answers
// `text/plain; charset=utf-8` and writes the reply as raw text chunks with NO
// framing — no SSE, no JSON — and the thread's id comes back on the
// `x-conversation-id` RESPONSE HEADER. The client's one `send` pipeline decodes
// a `Decodable` from a finished body and hands back only that value: there is no
// shape it could return that carries a live byte sequence and a response header.
// So this one request is built here, from the session's own base URL and token,
// and maps its failures onto the same `HCCAPIError` cases — a 401 from the Coach
// is the same sign-out a 401 anywhere else is. The three JSON calls (thread
// list, one thread, delete) DO go through the client — see
// `HCCAPIClient+Coach.swift`.
//
// ── The two markers ─────────────────────────────────────────────────────────
// Every reply ends with `<NUL>MEM:<n><NUL>` — a control sentinel, never shown
// (the delimiter is a literal NUL, not the space a hexdump reads like). A reply
// where the model changed something also carries a `\n\n— Updated: …` footer,
// which IS shown, muted, because it is the receipt for a write that already
// happened. Both are the server's (`src/lib/intelligence/chat.ts`); the parsing
// lives in `HCCCoachWire`.

/// The thread the sheet is currently in. Named at top level rather than nested
/// so it never shadows `Foundation.Thread` inside this file.
struct HCCCoachThread: Equatable {
  let id: String
  var title: String?
}

@MainActor
final class HCCCoachChatModel: ObservableObject {
  // ── Types ──────────────────────────────────────────────────────────────────

  enum Role: String {
    case user
    case assistant
  }

  /// One bubble.
  ///
  /// `text` is the answer; `footer` is the server's `— Updated:` receipt held
  /// apart from it so the view can render it muted without re-parsing. A
  /// message that is still arriving has `isStreaming` true — the view shows a
  /// caret and the composer offers Stop instead of Send.
  struct Message: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var text: String
    var isStreaming: Bool = false
    var footer: String?
    /// `[Attached 1 file: …]` under a user message. Held apart from `text`
    /// because the SERVER writes this same line onto the message it persists
    /// (`chatStream`, `src/lib/intelligence/chat.ts`): sending it as part of the
    /// content too made every attached message say it twice.
    var attachmentNote: String?

    /// What the bubble shows.
    var displayText: String {
      guard let attachmentNote, !attachmentNote.isEmpty else { return text }
      return text.isEmpty ? attachmentNote : "\(text)\n\n\(attachmentNote)"
    }

    /// What goes back on the wire when this message is part of the resent
    /// history. The assistant's footer is part of what the server stored, so it
    /// is reassembled; the user's attachment note is the server's own addition
    /// and is left to it.
    var wireContent: String {
      guard let footer, !footer.isEmpty else { return text }
      return "\(text)\n\n\(footer)"
    }
  }

  enum StreamState: Equatable {
    case idle
    case streaming
    case failed(String)

    var isStreaming: Bool { self == .streaming }

    var failure: String? {
      if case let .failed(message) = self { return message }
      return nil
    }
  }

  // ── State ──────────────────────────────────────────────────────────────────

  @Published private(set) var conversations: [HCCConversationSummary] = []
  @Published private(set) var current: HCCCoachThread?
  @Published private(set) var messages: [Message] = []
  @Published var draft: String = ""
  @Published private(set) var attachments: [HCCCoachAttachment] = []
  @Published private(set) var stream: StreamState = .idle
  @Published private(set) var isLoadingConversations = false
  @Published private(set) var isLoadingThread = false
  @Published var listError: String?
  @Published var attachmentError: String?

  /// The history the server is sent. Older turns are dropped rather than
  /// summarised: a summary the phone wrote would be the phone putting words in
  /// the conversation, and the server keeps its own full copy regardless.
  private static let historyLimit = 40

  private var streamTask: Task<Void, Never>?
  private var didLoadConversations = false

  private var client: HCCAPIClient { HCCSession.shared.client }

  var canSend: Bool {
    !stream.isStreaming
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
  }

  var canAttachMore: Bool { attachments.count < HCCCoachAttachmentLimits.maxCount }

  // ── Sending ────────────────────────────────────────────────────────────────

  /// Send the draft (with anything staged) and stream the answer in.
  ///
  /// `pageContext` names the screen the question was asked from, so the server
  /// can resolve "this"/"here" against it. It is a short label, never data.
  func send(pageContext: String?) {
    guard canSend else { return }

    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let staged = attachments
    // The line the SERVER writes onto the message it persists. The bubble shows
    // the same wording so a live thread and a re-opened one read identically —
    // but it is NOT sent, or the persisted message would carry it twice.
    let note = staged.isEmpty
      ? nil
      : "[Attached \(staged.count) file\(staged.count > 1 ? "s" : ""): \(staged.map(\.name).joined(separator: ", "))]"

    draft = ""
    attachments = []
    attachmentError = nil
    stream = .streaming

    messages.append(Message(role: .user, text: prompt, attachmentNote: note))
    let reply = Message(role: .assistant, text: "", isStreaming: true)
    messages.append(reply)

    let history = Array(messages.dropLast().suffix(Self.historyLimit)).map {
      HCCChatWireMessage(role: $0.role.rawValue, content: $0.wireContent)
    }
    let body = HCCChatRequestBody(
      messages: history,
      conversationId: current?.id,
      pageContext: pageContext.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) },
      attachments: staged.isEmpty ? nil : staged.map(\.body)
    )

    streamTask?.cancel()
    streamTask = Task { [weak self] in
      await self?.runStream(body: body, replyID: reply.id)
    }
  }

  /// Stop a reply mid-flight. What already arrived stays — it is the server's
  /// text, and the server has its own copy of the full turn either way.
  func stop() {
    streamTask?.cancel()
    streamTask = nil
  }

  private func runStream(body: HCCChatRequestBody, replyID: UUID) async {
    do {
      let request = try makeChatRequest(body: body)
      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw HCCAPIError.http(status: -1, message: "Malformed response.")
      }
      guard (200..<300).contains(http.statusCode) else {
        let failure = try await Self.failure(status: http.statusCode, bytes: bytes)
        throw failure
      }

      // The thread id arrives on the header, before a single byte of the answer.
      if let id = http.value(forHTTPHeaderField: "x-conversation-id"), !id.isEmpty, current?.id != id {
        current = HCCCoachThread(id: id, title: nil)
      }

      var accumulated = ""
      var buffer: [UInt8] = []
      var lastFlush = Date.distantPast

      for try await byte in bytes {
        try Task.checkCancellation()
        buffer.append(byte)
        // A chunk boundary can fall inside a multi-byte character, so only the
        // part of the buffer that is a COMPLETE UTF-8 sequence is decoded; the
        // rest waits for its continuation bytes. Flushing on a short interval
        // rather than per byte keeps a long reply from redrawing thousands of
        // times without making it look any less live.
        guard Date().timeIntervalSince(lastFlush) >= 0.05 else { continue }
        guard let text = Self.takeCompleteUTF8(&buffer), !text.isEmpty else { continue }
        accumulated += text
        lastFlush = Date()
        apply(displayText: HCCCoachWire.stripPartialSentinel(accumulated), to: replyID)
      }
      if let tail = Self.takeCompleteUTF8(&buffer, flushAll: true) { accumulated += tail }

      try Task.checkCancellation()
      finish(accumulated: accumulated, replyID: replyID)
    } catch is CancellationError {
      settleCancelled(replyID: replyID)
    } catch let error as HCCAPIError {
      if case .unauthorized = error { HCCSession.shared.handleUnauthorized() }
      fail(error.errorDescription ?? "The Coach could not answer.", replyID: replyID)
    } catch {
      let wrapped = HCCAPIError.transport(error)
      fail(wrapped.errorDescription ?? "The Coach could not answer.", replyID: replyID)
    }
    streamTask = nil
  }

  private func index(of id: UUID) -> Int? {
    messages.firstIndex { $0.id == id }
  }

  private func apply(displayText: String, to id: UUID) {
    guard let index = index(of: id) else { return }
    messages[index].text = displayText
  }

  private func finish(accumulated: String, replyID: UUID) {
    let stripped = HCCCoachWire.stripSentinel(accumulated)
    let (body, footer) = HCCCoachWire.splitFooter(stripped)
    if let index = index(of: replyID) {
      messages[index].text = body.trimmingCharacters(in: HCCCoachWire.trimSet)
      messages[index].footer = footer
      messages[index].isStreaming = false
    }
    stream = .idle
    // The server auto-titles a fresh thread from the first user message once the
    // turn completes, so the list is only right after the answer lands.
    Task { await refreshConversations(force: true) }
  }

  private func settleCancelled(replyID: UUID) {
    if let index = index(of: replyID) {
      let stripped = HCCCoachWire.stripSentinel(messages[index].text)
      messages[index].text = stripped.trimmingCharacters(in: HCCCoachWire.trimSet)
      messages[index].isStreaming = false
      if messages[index].text.isEmpty { messages.remove(at: index) }
    }
    if stream.isStreaming { stream = .idle }
  }

  private func fail(_ message: String, replyID: UUID) {
    if let index = index(of: replyID) {
      messages[index].isStreaming = false
      if messages[index].text.trimmingCharacters(in: HCCCoachWire.trimSet).isEmpty {
        messages.remove(at: index)
      }
    }
    stream = .failed(message)
  }

  private func makeChatRequest(body: HCCChatRequestBody) throws -> URLRequest {
    let url = HCCSession.shared.baseURL.appendingPathComponent("/api/chat")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("text/plain", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = HCCSession.currentToken() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    // An answer can take a while to begin and a while to finish; the client's
    // 20 s request timeout would cut a long tool-using turn off mid-sentence.
    request.timeoutInterval = 120
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw HCCAPIError.decoding(error, path: "request body")
    }
    return request
  }

  /// A non-2xx `/api/chat` answers `{error}` as JSON, like every other route —
  /// read it off the byte stream and map it onto the same typed failure.
  private static func failure(status: Int, bytes: URLSession.AsyncBytes) async throws -> HCCAPIError {
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count > 4096 { break }
    }
    return HCCAPIClient.failure(status: status, data: data)
  }

  // ── UTF-8 across chunk boundaries ──────────────────────────────────────────

  /// Take the longest prefix of `buffer` that is a complete UTF-8 sequence,
  /// leaving any trailing partial character behind for the next chunk.
  ///
  /// `flushAll` decodes whatever is left at the end of the stream — a truncated
  /// final character becomes a replacement character rather than vanishing.
  static func takeCompleteUTF8(_ buffer: inout [UInt8], flushAll: Bool = false) -> String? {
    guard !buffer.isEmpty else { return nil }
    let cut = flushAll ? buffer.count : completeLength(of: buffer)
    guard cut > 0 else { return nil }
    let head = Array(buffer[0..<cut])
    buffer.removeFirst(cut)
    return String(decoding: head, as: UTF8.self)
  }

  private static func completeLength(of buffer: [UInt8]) -> Int {
    var cut = buffer.count
    var trailing = 0
    while cut > 0, trailing < 4 {
      let byte = buffer[cut - 1]
      if byte & 0x80 == 0 { break }                                  // ASCII — complete.
      if byte & 0xC0 == 0x80 { cut -= 1; trailing += 1; continue }   // continuation byte.
      let needed: Int
      if byte & 0xE0 == 0xC0 { needed = 2 }
      else if byte & 0xF0 == 0xE0 { needed = 3 }
      else if byte & 0xF8 == 0xF0 { needed = 4 }
      else { needed = 1 }                                            // invalid lead — let it through.
      if trailing + 1 < needed { cut -= 1 }                          // still arriving.
      break
    }
    return cut
  }

  // ── Threads ────────────────────────────────────────────────────────────────

  func refreshConversations(force: Bool = false) async {
    guard force || !didLoadConversations else { return }
    guard !isLoadingConversations else { return }
    isLoadingConversations = true
    defer { isLoadingConversations = false }
    do {
      conversations = try await client.conversations()
      didLoadConversations = true
      listError = nil
      if let id = current?.id, let match = conversations.first(where: { $0.id == id }) {
        current?.title = match.title
      }
    } catch let error as HCCAPIError {
      if case .unauthorized = error { HCCSession.shared.handleUnauthorized() }
      listError = error.errorDescription
    } catch {
      listError = HCCAPIError.transport(error).errorDescription
    }
  }

  /// Open a stored thread. Its messages REPLACE what is on screen — this is a
  /// different conversation, not more of the current one.
  func open(_ summary: HCCConversationSummary) async {
    guard !isLoadingThread else { return }
    stop()
    isLoadingThread = true
    defer { isLoadingThread = false }
    do {
      let detail = try await client.conversation(id: summary.id)
      current = HCCCoachThread(id: detail.id, title: detail.title)
      messages = detail.messages.compactMap { stored in
        guard let role = Role(rawValue: stored.role) else { return nil }
        let (body, footer) = HCCCoachWire.splitFooter(HCCCoachWire.stripSentinel(stored.content))
        return Message(
          role: role,
          text: body.trimmingCharacters(in: HCCCoachWire.trimSet),
          footer: footer
        )
      }
      stream = .idle
      listError = nil
    } catch let error as HCCAPIError {
      if case .unauthorized = error { HCCSession.shared.handleUnauthorized() }
      listError = error.errorDescription
    } catch {
      listError = HCCAPIError.transport(error).errorDescription
    }
  }

  /// Start a fresh thread. Nothing is sent — the server creates the thread when
  /// the first message arrives and names it back on the response header.
  func startNewThread() {
    stop()
    current = nil
    messages = []
    attachments = []
    attachmentError = nil
    stream = .idle
  }

  func delete(_ summary: HCCConversationSummary) async {
    let previous = conversations
    conversations.removeAll { $0.id == summary.id }
    do {
      _ = try await client.deleteConversation(id: summary.id)
      if current?.id == summary.id { startNewThread() }
    } catch let error as HCCAPIError {
      if case .unauthorized = error { HCCSession.shared.handleUnauthorized() }
      conversations = previous
      listError = error.errorDescription
    } catch {
      conversations = previous
      listError = HCCAPIError.transport(error).errorDescription
    }
  }

  // ── Attachments ────────────────────────────────────────────────────────────

  func attach(_ attachment: HCCCoachAttachment) {
    guard canAttachMore else {
      attachmentError = HCCCoachAttachmentError.full.errorDescription
      return
    }
    attachments.append(attachment)
    attachmentError = nil
  }

  func attachImage(data: Data, name: String) {
    guard canAttachMore else {
      attachmentError = HCCCoachAttachmentError.full.errorDescription
      return
    }
    do {
      attachments.append(try HCCCoachAttachmentFactory.image(from: data, name: name))
      attachmentError = nil
    } catch {
      attachmentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  func attachFiles(_ urls: [URL]) {
    for url in urls {
      guard canAttachMore else {
        attachmentError = HCCCoachAttachmentError.full.errorDescription
        return
      }
      do {
        attachments.append(try HCCCoachAttachmentFactory.file(at: url))
        attachmentError = nil
      } catch {
        attachmentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }

  func removeAttachment(_ attachment: HCCCoachAttachment) {
    attachments.removeAll { $0.id == attachment.id }
  }

  // ── DEBUG launch hooks ─────────────────────────────────────────────────────
  //
  // The Coach is a sheet, and `simctl` cannot tap: without these, no scripted
  // run could screenshot it. All of them are compiled out of Release, and none
  // fabricates an answer — `HCC_DEBUG_COACH_PROMPT` asks the real server a real
  // question and shows whatever comes back.

  #if DEBUG
  /// `HCC_DEBUG_OPEN_COACH=1` — present the sheet on launch.
  static var debugWantsSheet: Bool {
    ProcessInfo.processInfo.environment["HCC_DEBUG_OPEN_COACH"] == "1"
  }

  /// `HCC_DEBUG_COACH_VIEW=conversations` — open on the thread drawer.
  static var debugWantsConversations: Bool {
    ProcessInfo.processInfo.environment["HCC_DEBUG_COACH_VIEW"] == "conversations"
  }

  /// `HCC_DEBUG_COACH_PROMPT=<text>` — ask this the moment the sheet appears.
  static var debugPrompt: String? {
    guard let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_COACH_PROMPT"], !raw.isEmpty else {
      return nil
    }
    return raw
  }

  /// `HCC_DEBUG_COACH_ATTACHMENT=1` — stage one generated swatch so the
  /// attachment chip can be screenshotted without the photo picker. It is
  /// plainly named as a debug file and goes nowhere unless a prompt sends it.
  static var debugWantsAttachment: Bool {
    ProcessInfo.processInfo.environment["HCC_DEBUG_COACH_ATTACHMENT"] == "1"
  }

  func applyDebugLaunchStateIfNeeded() {
    guard Self.debugWantsAttachment, attachments.isEmpty else { return }
    let size = CGSize(width: 96, height: 96)
    let image = UIGraphicsImageRenderer(size: size).image { context in
      UIColor(HCCTheme.Color.accent).setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    guard let data = image.jpegData(compressionQuality: 0.85) else { return }
    attach(HCCCoachAttachment(name: "debug-swatch.jpg", type: "image/jpeg", data: data, thumbnail: image))
  }
  #endif
}
