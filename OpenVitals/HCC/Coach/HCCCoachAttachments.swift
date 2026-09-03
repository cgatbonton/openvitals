import Foundation
import UIKit
import UniformTypeIdentifiers

// HCC: files the owner attaches to a Coach message.
//
// This mirrors the web client (`src/lib/attachments.ts`), deliberately and
// value for value, because the two surfaces send to the SAME route and a photo
// that is fine from the browser must be fine from the phone:
//
//  * images are downscaled to a longest edge of 1568 px and re-encoded as JPEG
//    at quality 0.85 — 1568 is the effective maximum edge the vision model
//    resolves, so anything larger is bytes spent on nothing;
//  * everything else is sent as-is;
//  * `base64` is BARE (no `data:` prefix), which is what the route's zod schema
//    accepts;
//  * at most 6 files per message, the route's own cap.
//
// The one place the phone is stricter than the browser is the size ceiling: 5 MB
// per file against the web's 20 MB. A phone is usually on cellular, and a 20 MB
// PDF over a metered link is a minutes-long upload with no progress to show for
// it. Images are downscaled before the check, so the ceiling only ever bites a
// large PDF or text file.

/// One staged file, ready to send.
struct HCCCoachAttachment: Identifiable, Equatable {
  let id = UUID()
  /// The file's own name — the server shows it in the persisted user message.
  let name: String
  /// MIME type as the route wants it (`image/jpeg`, `application/pdf`, …).
  let type: String
  /// The bytes actually sent, after any downscaling.
  let data: Data
  /// A small preview for the chip. Images only; `nil` for documents.
  let thumbnail: UIImage?

  static func == (lhs: HCCCoachAttachment, rhs: HCCCoachAttachment) -> Bool { lhs.id == rhs.id }

  var byteCount: Int { data.count }

  var isImage: Bool { type.hasPrefix("image/") }

  /// The wire shape. Base64 is computed at send time rather than stored, so a
  /// staged attachment costs its own size and not a third more.
  var body: HCCChatAttachmentBody {
    HCCChatAttachmentBody(name: name, type: type, base64: data.base64EncodedString())
  }
}

enum HCCCoachAttachmentLimits {
  /// The route's `.max(6)`.
  static let maxCount = 6
  /// Per file, after downscaling.
  static let maxBytes = 5 * 1024 * 1024
  /// The vision model's effective maximum edge; larger buys nothing.
  static let imageMaxDimension: CGFloat = 1568
  static let imageQuality: CGFloat = 0.85

  /// What the file importer offers. Images, PDFs and the text types the server
  /// can decode inline (`attachmentToPart`, `src/lib/intelligence/chat.ts`).
  static let importedTypes: [UTType] = [.image, .pdf, .plainText, .commaSeparatedText, .json]

  static func isSupported(_ type: String) -> Bool {
    type.hasPrefix("image/")
      || type == "application/pdf"
      || type.hasPrefix("text/")
      || type == "application/json"
  }
}

enum HCCCoachAttachmentError: Error, LocalizedError {
  case unsupported(String)
  case tooLarge(String)
  case unreadable(String)
  case full

  var errorDescription: String? {
    switch self {
    case let .unsupported(name):
      "\"\(name)\" isn't a type the Coach can read (images, PDF or text)."
    case let .tooLarge(name):
      "\"\(name)\" is too large to send (max 5 MB)."
    case let .unreadable(name):
      "\"\(name)\" could not be read."
    case .full:
      "You can attach up to \(HCCCoachAttachmentLimits.maxCount) files."
    }
  }
}

enum HCCCoachAttachmentFactory {
  /// Picked-from-the-library image data → a downscaled JPEG attachment.
  ///
  /// Falls back to the original bytes if the decode/re-encode path fails, which
  /// is the same fallback the web client takes — better to send a large photo
  /// than to drop the owner's file silently.
  static func image(from data: Data, name: String) throws -> HCCCoachAttachment {
    guard let source = UIImage(data: data) else {
      throw HCCCoachAttachmentError.unreadable(name)
    }
    let scaled = downscale(source)
    if let jpeg = scaled.jpegData(compressionQuality: HCCCoachAttachmentLimits.imageQuality) {
      guard jpeg.count <= HCCCoachAttachmentLimits.maxBytes else {
        throw HCCCoachAttachmentError.tooLarge(name)
      }
      return HCCCoachAttachment(name: name, type: "image/jpeg", data: jpeg, thumbnail: scaled)
    }
    guard data.count <= HCCCoachAttachmentLimits.maxBytes else {
      throw HCCCoachAttachmentError.tooLarge(name)
    }
    return HCCCoachAttachment(name: name, type: "image/jpeg", data: data, thumbnail: source)
  }

  /// A file picked through the document importer. Images go down the same
  /// downscaling path as a photo; everything else is passed through.
  static func file(at url: URL) throws -> HCCCoachAttachment {
    let name = url.lastPathComponent
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    guard let data = try? Data(contentsOf: url) else {
      throw HCCCoachAttachmentError.unreadable(name)
    }
    let mime = mimeType(for: url)
    guard HCCCoachAttachmentLimits.isSupported(mime) else {
      throw HCCCoachAttachmentError.unsupported(name)
    }
    if mime.hasPrefix("image/") {
      return try image(from: data, name: name)
    }
    guard data.count <= HCCCoachAttachmentLimits.maxBytes else {
      throw HCCCoachAttachmentError.tooLarge(name)
    }
    return HCCCoachAttachment(name: name, type: mime, data: data, thumbnail: nil)
  }

  static func mimeType(for url: URL) -> String {
    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
  }

  private static func downscale(_ image: UIImage) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > HCCCoachAttachmentLimits.imageMaxDimension, longest > 0 else { return image }
    let scale = HCCCoachAttachmentLimits.imageMaxDimension / longest
    let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }
}

/// A human size for the chip under a document, e.g. "1.2 MB".
enum HCCCoachByteFormat {
  private static let formatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB]
    return formatter
  }()

  static func string(_ bytes: Int) -> String {
    formatter.string(fromByteCount: Int64(bytes))
  }
}
