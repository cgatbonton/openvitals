import Foundation

// HCC: the Coach's DTOs.
//
// Three of the four Coach calls are ordinary JSON web routes under
// `/api/conversations*`, which answer with `ok()` — a bare object, not the read
// API's `{data, generatedAt, instance}` envelope — so they go through the
// client's BARE methods (see `HCCAPIClient+Coach.swift`).
//
// The fourth, `POST /api/chat`, is NOT JSON at all: it answers
// `text/plain; charset=utf-8` and writes the assistant's reply as raw text
// chunks with no framing, so it cannot go through the decoding client. Its
// request BODY is JSON though, and the encodable shapes for it live here so
// there is one place where the route's zod schema is mirrored.
//
// Server sources of truth: `src/app/api/chat/route.ts` (the body schema and the
// response headers), `src/lib/intelligence/chat.ts` (the sentinel and the
// footer), `src/app/api/conversations/route.ts` and
// `src/app/api/conversations/[id]/route.ts` (the thread shapes).

// ── Threads ──────────────────────────────────────────────────────────────────

/// One row of `GET /api/conversations`.
///
/// `title` is genuinely nullable: the server auto-titles a thread from its first
/// user message only after that turn completes, so a thread that is mid-first-
/// answer has none yet. The phone shows the server's title or nothing — it never
/// invents one.
struct HCCConversationSummary: Decodable, Identifiable, Equatable {
  let id: String
  let title: String?
  /// ISO instant. Parse with `HCCTime.instant` — never with a day formatter.
  let updatedAt: String?
  let messageCount: Int

  var updatedAtDate: Date? { HCCTime.instant(updatedAt) }
}

struct HCCConversationList: Decodable {
  let conversations: [HCCConversationSummary]
}

/// One persisted turn as the server stored it. `role` is `user` or `assistant`.
struct HCCConversationMessage: Decodable, Equatable {
  let role: String
  let content: String
}

/// `GET /api/conversations/{id}` — the whole thread, oldest first.
struct HCCConversationDetail: Decodable {
  let id: String
  let title: String?
  let messages: [HCCConversationMessage]
}

/// `DELETE /api/conversations/{id}`.
struct HCCConversationDeleted: Decodable {
  let deleted: Bool
}

// ── The chat request ─────────────────────────────────────────────────────────

/// One message on the wire. The client resends the visible history every turn —
/// the server persists its own copy but reads the conversation from what it is
/// sent, so a trimmed history is a trimmed context.
struct HCCChatWireMessage: Encodable {
  /// `user` | `assistant`.
  let role: String
  let content: String
}

/// A file attached to the latest user message.
///
/// `base64` is BARE — no `data:` prefix — because that is what the route's zod
/// schema accepts and what the server hands the vision model. The route caps the
/// array at 6 and each base64 string at ~28 MB.
struct HCCChatAttachmentBody: Encodable {
  let name: String
  /// MIME type, e.g. `image/jpeg`, `application/pdf`, `text/plain`.
  let type: String
  let base64: String
}

/// `POST /api/chat` body. Mirrors the route's zod schema field for field.
struct HCCChatRequestBody: Encodable {
  let messages: [HCCChatWireMessage]
  /// The thread to continue. Omitted on the first turn; the server creates one
  /// and names it back on the `x-conversation-id` response header.
  let conversationId: String?
  /// A short human-readable name for the screen the question was asked from —
  /// the server uses it to resolve "this"/"here" in a contextual question. The
  /// route caps it at 300 characters.
  let pageContext: String?
  let attachments: [HCCChatAttachmentBody]?
}

// ── The plain-text stream ────────────────────────────────────────────────────

/// The two markers the `/api/chat` body carries besides the answer itself.
///
/// Both are the server's, not conventions invented here:
///
///  * **The memory sentinel.** Every reply ends `<NUL>MEM:<n><NUL>` — how many
///    durable memories that turn produced (`MEMORY_SENTINEL`,
///    `src/lib/intelligence/chat.ts`). The delimiter is a literal NUL, not a
///    space: the server picked it because "null chars never occur in model
///    output and don't render", and it is easy to read a hexdump of the wire as
///    a space and get this wrong. A NUL renders as nothing, so a sentinel that
///    is not stripped shows up as `…analysis.MEM:0` — text with no visible
///    separator, which is exactly how this was caught. Whitespace is accepted
///    either side too, in case the server ever changes the delimiter back.
///  * **The updates footer.** When the model changed something (an insight, an
///    action item, a protocol, a logged reading) the server appends a
///    deterministic `\n\n— Updated: …` line so the change is stated even if the
///    model did not narrate it. That one IS shown — muted, under the answer —
///    because it is the receipt for a write that already happened.
enum HCCCoachWire {
  /// The trailing `<NUL>MEM:<n><NUL>`, with the delimiter either side optional
  /// and either a NUL or ordinary whitespace.
  static let sentinelPattern = #"[\s\x{0}]?MEM:\d+[\s\x{0}]?$"#

  /// A sentinel still arriving: the tail of a chunk that could grow into one.
  /// Stripped from the DISPLAYED text while a reply streams so the marker never
  /// flashes on screen, and re-evaluated on every chunk.
  static let partialSentinelPattern = #"[\s\x{0}]?M(?:E(?:M(?::\d*[\s\x{0}]?)?)?)?$"#

  /// What a finished message is trimmed with. Whitespace AND control characters:
  /// the sentinel's delimiter is a NUL, and a NUL left on the end of a bubble is
  /// invisible junk that `.whitespacesAndNewlines` would not remove.
  static let trimSet: CharacterSet = .whitespacesAndNewlines.union(.controlCharacters)

  static let updatesFooterMarker = "\n\n— Updated:"

  /// Strip the memory sentinel from a finished reply.
  static func stripSentinel(_ text: String) -> String {
    replacingTrailingMatch(in: text, pattern: sentinelPattern)
  }

  /// Strip a sentinel that may still be arriving, for the streaming display.
  static func stripPartialSentinel(_ text: String) -> String {
    replacingTrailingMatch(in: text, pattern: partialSentinelPattern)
  }

  /// Split a finished reply into the answer and the server's updates footer.
  /// The footer is returned verbatim, including its leading marker.
  static func splitFooter(_ text: String) -> (body: String, footer: String?) {
    guard let range = text.range(of: updatesFooterMarker) else { return (text, nil) }
    let body = String(text[text.startIndex..<range.lowerBound])
    let footer = String(text[range.lowerBound...]).trimmingCharacters(in: trimSet)
    return (body, footer.isEmpty ? nil : footer)
  }

  /// The mockup's `.msg.ai .src` line: a trailing `sources · …` the model wrote
  /// itself. Returned ONLY when the text actually ends with such a line — this
  /// never composes a source list out of anything else.
  static func splitSources(_ text: String) -> (body: String, sources: String?) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let lastIndex = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
      return (text, nil)
    }
    let candidate = lines[lastIndex].trimmingCharacters(in: .whitespaces)
    let lowered = candidate.lowercased()
    guard lowered.hasPrefix("sources ·") || lowered.hasPrefix("sources:") else { return (text, nil) }
    let body = lines[lines.startIndex..<lastIndex]
      .joined(separator: "\n")
      .trimmingCharacters(in: trimSet)
    return (body, candidate)
  }

  private static func replacingTrailingMatch(in text: String, pattern: String) -> String {
    guard let range = text.range(of: pattern, options: [.regularExpression]) else { return text }
    guard range.upperBound == text.endIndex else { return text }
    return String(text[text.startIndex..<range.lowerBound])
  }
}
