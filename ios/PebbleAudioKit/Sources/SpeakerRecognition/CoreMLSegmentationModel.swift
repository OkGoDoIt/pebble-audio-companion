import CryptoKit
import Foundation

/// Pinned pyannote community-1 conversion. The five compiled Core ML files are immutable.
public struct CoreMLSegmentationModel: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static let revision = "7eab74f3463c736418d0eb10296261ae581146c9"
    public static let downloadBytes: Int64 = 6_006_888
    struct File: Sendable { let path: String; let bytes: Int64; let sha256: String
        var url: URL { URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/"
            + CoreMLSegmentationModel.revision + "/Segmentation.mlmodelc/" + path)! }
    }
    static let files: [File] = [
        File(path: "analytics/coremldata.bin", bytes: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
        File(path: "coremldata.bin", bytes: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
        File(path: "metadata.json", bytes: 3410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
        File(path: "model.mil", bytes: 43063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
        File(path: "weights/weight.bin", bytes: 5959360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2")
    ]
    public func verify() throws {
        guard directory.isFileURL else { throw SpeakerRecognitionError.modelVerificationFailed("Nonlocal segmentation model") }
        for file in Self.files {
            let url = directory.appendingPathComponent(file.path)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == Int(file.bytes),
                  SHA256.hash(data: try Data(contentsOf: url)).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw SpeakerRecognitionError.modelVerificationFailed(file.path)
            }
        }
    }
}
