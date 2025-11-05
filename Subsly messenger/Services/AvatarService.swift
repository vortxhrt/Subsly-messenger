import Foundation
import FirebaseStorage
import UIKit

enum AvatarServiceError: Error {
    case imageEncodingFailed
}

actor AvatarService {
    static let shared = AvatarService()

    func upload(image: UIImage, for uid: String) async throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw AvatarServiceError.imageEncodingFailed
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
