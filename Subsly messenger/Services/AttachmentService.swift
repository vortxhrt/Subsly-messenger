import Foundation
import FirebaseStorage

struct UploadedAttachment {
    let kind: MessageModel.Media.Kind
    let mediaURL: String
    let thumbnailURL: String?
    let width: Int
    let height: Int
    let duration: Double?

    var previewText: String {
        switch kind {
        case .image:
            return "Photo"
        case .video:
            return "Video"
        }
    }
}

actor AttachmentService {
    static let shared = AttachmentService()

    func upload(_ attachment: PendingAttachment, threadId: String) async throws -> UploadedAttachment {
        let storage = Storage.storage()
        let root = storage.reference().child("threads/\(threadId)/attachments")

        switch attachment.kind {
        case .image(let data, let width, let height):
            let fileName = UUID().uuidString + ".jpg"
            let reference = root.child(fileName)
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"

            _ = try await reference.putDataAsync(data, metadata: metadata)
            let url = try await reference.downloadURL()

            return UploadedAttachment(
                kind: .image,
                mediaURL: url.absoluteString,
                thumbnailURL: nil,
                width: width,
                height: height,
                duration: nil
            )

        case .video(let fileURL, let thumbnailData, let width, let height, let duration):
            let baseName = UUID().uuidString
            let videoName = baseName + ".mp4"
            let thumbName = baseName + "_thumb.jpg"

            let videoRef = root.child(videoName)
            let videoMeta = StorageMetadata()
            videoMeta.contentType = "video/mp4"
            _ = try await videoRef.putFileAsync(from: fileURL, metadata: videoMeta)
            let videoURL = try await videoRef.downloadURL()

            let thumbRef = root.child(thumbName)
            let thumbMeta = StorageMetadata()
            thumbMeta.contentType = "image/jpeg"
            _ = try await thumbRef.putDataAsync(thumbnailData, metadata: thumbMeta)
            let thumbURL = try await thumbRef.downloadURL()

            // Clean up the local file once uploaded
            try? FileManager.default.removeItem(at: fileURL)

            return UploadedAttachment(
                kind: .video,
                mediaURL: videoURL.absoluteString,
                thumbnailURL: thumbURL.absoluteString,
                width: width,
                height: height,
                duration: duration
            )
        }
    }
}
