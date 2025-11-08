import Foundation

struct PendingAttachment: Identifiable, Sendable {
    let id = UUID()
    enum Kind: Sendable {
        case image(data: Data, width: Int, height: Int)
        case video(fileURL: URL, thumbnailData: Data, width: Int, height: Int, duration: Double)
    }

    let kind: Kind

    var isVideo: Bool {
        switch kind {
        case .image:
            return false
        case .video:
            return true
        }
    }

    var previewData: Data? {
        switch kind {
        case .image(let data, _, _):
            return data
        case .video(_, let thumbnailData, _, _, _):
            return thumbnailData
        }
    }

    var width: Int {
        switch kind {
        case .image(_, let width, _):
            return width
        case .video(_, _, let width, _, _):
            return width
        }
    }

    var height: Int {
        switch kind {
        case .image(_, _, let height):
            return height
        case .video(_, _, _, let height, _):
            return height
        }
    }

    var duration: Double? {
        switch kind {
        case .image:
            return nil
        case .video(_, _, _, _, let duration):
            return duration
        }
    }

    var fileURL: URL? {
        switch kind {
        case .image:
            return nil
        case .video(let url, _, _, _, _):
            return url
        }
    }

    func asMessageMedia() -> MessageModel.Media {
        switch kind {
        case .image(let data, let width, let height):
            return MessageModel.Media(
                kind: .image,
                url: nil,
                thumbnailURL: nil,
                width: Double(width),
                height: Double(height),
                duration: nil,
                localData: data,
                localThumbnailData: nil
            )
        case .video(_, let thumbnailData, let width, let height, let duration):
            return MessageModel.Media(
                kind: .video,
                url: nil,
                thumbnailURL: nil,
                width: Double(width),
                height: Double(height),
                duration: duration,
                localData: nil,
                localThumbnailData: thumbnailData
            )
        }
    }
}
