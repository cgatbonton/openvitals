import Foundation

// HCC: the Coach's JSON calls — the thread list, one thread, and deleting one.
//
// `/api/conversations*` are WEB routes: they answer with `ok()`, the object
// itself rather than the read API's `{data, generatedAt, instance}` envelope, so
// each goes through one of the client's BARE methods. They then carry the same
// bearer closure, timeouts and `failure(status:data:)` mapping as every other
// call, which is what keeps a 401 here indistinguishable from a 401 anywhere
// else — the sign-out path fires the same way.
//
// `POST /api/chat` is deliberately NOT here. It answers `text/plain` and writes
// the reply as raw chunks with no framing, so there is nothing for the client's
// decoder to do and everything for it to get in the way of: the model needs the
// live byte sequence AND the `x-conversation-id` response header. That one
// request is built in `HCCCoachChatModel` (see the note there).

extension HCCAPIClient {
  /// The owner's threads, newest first (the server takes the top 100).
  func conversations() async throws -> [HCCConversationSummary] {
    let response: HCCConversationList = try await getBare("/api/conversations")
    return response.conversations
  }

  /// One thread with its messages, oldest first. 404s if it is not the caller's.
  func conversation(id: String) async throws -> HCCConversationDetail {
    try await getBare("/api/conversations/\(id)")
  }

  /// Delete a thread. The server cascades its messages; there is no undo, which
  /// is why the only affordance for it is a swipe.
  @discardableResult
  func deleteConversation(id: String) async throws -> Bool {
    let response: HCCConversationDeleted = try await deleteBare("/api/conversations/\(id)")
    return response.deleted
  }
}
