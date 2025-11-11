import Foundation
import FirebaseStorage
import UIKit

enum AvatarServiceError: Error {
    case imageEncodingFailed
    case imageTooLarge
}

actor AvatarService {
    static let shared = AvatarService()

    func upload(image: UIImage, for uid: String) async throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw AvatarServiceError.imageEncodingFailed
        }

        guard data.count <= 5 * 1024 * 1024 else {
            throw AvatarServiceError.imageTooLarge
        }

        let storage = Storage.storage()
        let reference = storage.reference().child("avatars/\(uid).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await reference.putDataAsync(data, metadata: metadata)
        let url = try await reference.downloadURL()
        return url.absoluteString
    }
}
