import CryptoKit
import Foundation

/// A local installation supplied by the caller. This type never downloads models.
public struct CactusSpeakerModel: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// The published int4/int8 ZIPs at this revision are identical; their config is FP16.
    /// Pin bytes and actual format, rather than inferring precision from the filename.
    public static let recipe = SpeakerEmbeddingRecipe(
        modelID: "Cactus-Compute/wespeaker-voxceleb-resnet34-LM",
        modelRevision: "f145212639b5cea874482e70002935daa987fe44",
        weightsSHA256: "cc6fc908455c77f08a4fa2d6090649b13e13c7f865ba01c3d6ff8d82e31b1c71",
        runtimeID: "cactus-device-" + deviceRuntimeSHA256 + "-simulator-" + simulatorRuntimeSHA256,
        preprocessingID: "pcm16le-16k-mono-no-gain-cactus-80mel-mean-FP16-l2-v1",
        dimensions: 256
    )

    public static let deviceRuntimeSHA256 = "ee75cf2b583740069a0ca70c9cc6616c5ba5289005df913738b9b77b2172a622"
    public static let simulatorRuntimeSHA256 = "21141c8b13ed8f3bfc8898a4d0018694974980dcf98ab8d1dac7e142de209dbb"

    public static let archiveURL = URL(string:
        "https://huggingface.co/Cactus-Compute/wespeaker-voxceleb-resnet34-LM/resolve/"
        + "f145212639b5cea874482e70002935daa987fe44/weights/wespeaker-voxceleb-resnet34-lm-int8.zip")!

    /// Validate every extracted model file before native initialization. The 75 hashes are
    /// from the SHA256-pinned archive, not a mutable filename or user-supplied manifest.
    public func verify() throws {
        guard directory.isFileURL else {
            throw SpeakerRecognitionError.modelVerificationFailed("Model must be a local directory")
        }
        for (name, expected) in Self.fileHashes {
            let file = directory.appendingPathComponent(name)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size <= 8_000_000 else {
                throw SpeakerRecognitionError.modelVerificationFailed(name)
            }
            let data = try Data(contentsOf: file)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw SpeakerRecognitionError.modelVerificationFailed(name) }
        }
        let actualWeights = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".weights") }
        guard Set(actualWeights) == Set(Self.fileHashes.keys.filter { $0.hasSuffix(".weights") }) else {
            throw SpeakerRecognitionError.modelVerificationFailed("Unexpected model weight files")
        }
    }

    private static let fileHashes: [String: String] = [
        "config.txt": "dae59dcd3fc7e91801024285ba78c35f7e2e4a10a471d17eac896012cc2e5a3a",
        "resnet_conv1_bias.weights": "6460cec84c6a79c4124f5eead8829414d5b77c37ef63566beec5f874a9849b7f",
        "resnet_conv1_weight.weights": "00e8908a1106b13e12d827694484335027f3841ccccd800c752fedb3eb3aa2c8",
        "resnet_layer1_0_conv1_bias.weights": "00155e4de3d5edab7dab1f24c4c8a4cb1410613ee74e7a0e14aa7054b39c10f4",
        "resnet_layer1_0_conv1_weight.weights": "c8ccaffd28b27e39cc2510a6a7b2fdbb8d823370fd8418ba187f7a66293a4ee9",
        "resnet_layer1_0_conv2_bias.weights": "c8dab0d2a6f1f764e0fb943427ea6e6bff7d0b75ce30abc239571d5bc8dbf6c2",
        "resnet_layer1_0_conv2_weight.weights": "68f7e714bee34b46d857b1bb807952fd821824568fd5472e89ab5fc8f428d216",
        "resnet_layer1_1_conv1_bias.weights": "90d442d48e8983a4e8f5e380c5dfaf4422d8bbe798f2ca3a82391039257a0b68",
        "resnet_layer1_1_conv1_weight.weights": "0d6c9dbdb1a09acb49bd117a21f41460a9909228606f47671bedab77adb9ca49",
        "resnet_layer1_1_conv2_bias.weights": "5c8e10c9b4d12372bc2c219dc9f94df0e4edf030f78f49301d905284953183a1",
        "resnet_layer1_1_conv2_weight.weights": "dec9e3c71abf8bcc028957192b16b1dd4fd1d9b26c499eec813126f0b5f9f1d5",
        "resnet_layer1_2_conv1_bias.weights": "fb53f71e3ec75b3247581dc6ccec189614565327ab67dcc71ac3472ff2823501",
        "resnet_layer1_2_conv1_weight.weights": "05536ee9079f9c2943a9f99dc84f873cd6e650b24c1ad9291f3f1a0ad5d9e0f0",
        "resnet_layer1_2_conv2_bias.weights": "badb7dbb5f45ec48e27995169d0a588c31d9bb3f20552ac4d3ba94e792663e78",
        "resnet_layer1_2_conv2_weight.weights": "b695127775da2d79029102bed57085e93965abd83adfaf96cd5276fcf8d2ee94",
        "resnet_layer2_0_conv1_bias.weights": "22f94d3fe414d76f481611f4b0604978c810a5842141e3c2b3ea8aa1fc90957d",
        "resnet_layer2_0_conv1_weight.weights": "16fb0de0b21f9111cdb5d34840ada207e5b827c861701ebc8afe40e97ce1a00d",
        "resnet_layer2_0_conv2_bias.weights": "3e171d062436ff1566da5dbc7fdbfe4a0b791e8597540b33d715a8dcd6636f15",
        "resnet_layer2_0_conv2_weight.weights": "72bf817eb3c0fb42ca0bf275b9e96ab8c1c0f42012d26588a0ff74c417d1dd10",
        "resnet_layer2_0_shortcut_0_bias.weights": "3b57af854ab67d463d2ee4a9db913cd820ffdea1f03f0078c538ba1101cd3a8e",
        "resnet_layer2_0_shortcut_0_weight.weights": "5ae4cbdea64072a92d0f4e4588bd0d6c9056b857a362a7ab3380ba7ed937683f",
        "resnet_layer2_1_conv1_bias.weights": "1c05b5e0759f570d9a089ede9beee8759ace2eece22b1536c9b1d0428b2b7869",
        "resnet_layer2_1_conv1_weight.weights": "7ce45def71ed187754466eecef543178ff4164bf35ee10ab02f58e92d104aa7a",
        "resnet_layer2_1_conv2_bias.weights": "e90c782ff1f432f1dfb5008e2fada28dafe72d404136ebccac5b6fa920e1f29d",
        "resnet_layer2_1_conv2_weight.weights": "4d710f0d4d77408cc3ca867668763a7d303569b52d992f390df2ac55dab3fb99",
        "resnet_layer2_2_conv1_bias.weights": "d085bcc612c432eab2fbf1b6571a2bce861d8bad6350c4f4f3a8b40360f3c40d",
        "resnet_layer2_2_conv1_weight.weights": "40f5a0a99234ed5e8c130ef8bf5b5a68f41715ffed4ee4d54f24d64f1b40789f",
        "resnet_layer2_2_conv2_bias.weights": "87d2d2e45bd986498c944ed03e608065919e72ee810af40a4b461b49381b1350",
        "resnet_layer2_2_conv2_weight.weights": "cd56667220cabb29b91639e3c6a608a90ded8e344cbcdcd3cd73dc19f6dd8655",
        "resnet_layer2_3_conv1_bias.weights": "35828167702f9fd27b0f47fd1efbe7469ddbbd3c6ccfb09a0d0c57cafc4bf2a5",
        "resnet_layer2_3_conv1_weight.weights": "58e670f355cc605118e5f38ccfb65ef553e1e25aceb17083484f672d4b16bb6b",
        "resnet_layer2_3_conv2_bias.weights": "be771622df8a8f28ff79f043c1e1c155d97dd97a404840907a77c4d5d2c1821e",
        "resnet_layer2_3_conv2_weight.weights": "6c7291cd52eed5c1684eaa0a8593ad12519c76786168063f3d0ec5b7fd17d224",
        "resnet_layer3_0_conv1_bias.weights": "583dcadee199463be002b997ac121ac77eb5a0dbbdf951a7b7feed6c83c975bd",
        "resnet_layer3_0_conv1_weight.weights": "bc7fdcf399742abd2f42e933804ff68c9f6e30e7bff009826b2f3d7f54ad2019",
        "resnet_layer3_0_conv2_bias.weights": "86a3e66af85b34accef075a7ba3d3a84abefb59f3d1804e96b7cd9ecf584807d",
        "resnet_layer3_0_conv2_weight.weights": "2b091c6691734f2b7f1dd29cf6e290f28745122333615e5269ebb5a03ef0d30c",
        "resnet_layer3_0_shortcut_0_bias.weights": "c83fa2676464392857eccbe5b64f5f417a802e094d9280538c7122c1117ba72c",
        "resnet_layer3_0_shortcut_0_weight.weights": "e68b56d9babe2694095c95ba31ed2930f5f56c6b0d5736a95b1d15c99ffad4f8",
        "resnet_layer3_1_conv1_bias.weights": "63d32b47ed54c096e647b939021a3f66de4b296c9afcb78685598b998787772f",
        "resnet_layer3_1_conv1_weight.weights": "66a5401fee2ffc67c14b86c017318c14dee7b0b31adbc8fa5eaa83ad6dfc1d8e",
        "resnet_layer3_1_conv2_bias.weights": "3acd382116961119ddb1fe27c2e1172795f6400f2c4e9e4c2e2f722e8b6b4c55",
        "resnet_layer3_1_conv2_weight.weights": "08325889ceeb166c167abb961feab3d9596056ef86b3af21da894ca6afa5d62b",
        "resnet_layer3_2_conv1_bias.weights": "216a933eb270e9e58240377c4801bd3bf2825aa453fd54a20464c7ba6b12b563",
        "resnet_layer3_2_conv1_weight.weights": "79fa10431e19eef9a913359dfa6609d3151a8ea6b9f22c59402b8287bd1d0b65",
        "resnet_layer3_2_conv2_bias.weights": "fc8c123894220dd0f11572e23661da1e1bfe9184247c4cfa98fb8eb188c326df",
        "resnet_layer3_2_conv2_weight.weights": "60a44c4652e6e7ff393525cc400f16ec2c43b56a6292b1ab209d85ee6ad8c1d6",
        "resnet_layer3_3_conv1_bias.weights": "ca612d2b856e4cb35db718a28890e329953d8986d577d3a988759385ac1a13d0",
        "resnet_layer3_3_conv1_weight.weights": "019510016b768b1af87725056b783252294a507afb32ab789826d19301f06ed8",
        "resnet_layer3_3_conv2_bias.weights": "31e8fc987159cde69b2953ad352d5ffc101bd56e87321071792202ca2a281287",
        "resnet_layer3_3_conv2_weight.weights": "63b5ca6a4c64fed2b449f4a11fd3e6b72e1141d6940a402942c7b0ff3aa11b87",
        "resnet_layer3_4_conv1_bias.weights": "fce37f862df09c82e11c928b469c410500b2f83f2722c0d46869f031d7f627fd",
        "resnet_layer3_4_conv1_weight.weights": "2f44589ba8b8bb21188b0330e901e86e12be574648503df70656285a7d6acd96",
        "resnet_layer3_4_conv2_bias.weights": "9c2c0ce6b3136a4ae41c0315bd86f7ce9b43fefebb84597605a45344ddc7b550",
        "resnet_layer3_4_conv2_weight.weights": "df72c2d8a85172c36c419d49a639b10a2d05e7dff8f106baf2d7930d9117fd92",
        "resnet_layer3_5_conv1_bias.weights": "c090e6b3fdac5389c1f16d3aa57c5dda73ec8d71b33606132523f653841d65a8",
        "resnet_layer3_5_conv1_weight.weights": "03f3d87356b55a4b9760537b95b5f8131178d57c2c56a49cd3d2a1deac67780c",
        "resnet_layer3_5_conv2_bias.weights": "52d937b397aac9f65724f8d4ec42854294d8100192fc94f9fa7b52fcaed2866c",
        "resnet_layer3_5_conv2_weight.weights": "66e55b05be2b77fc15e5b8d5d3d8a1527e566bd4221b304ba29c3189ab2dc405",
        "resnet_layer4_0_conv1_bias.weights": "18089ade4b4fc0461a37c4099f7d2c0663c6a6505e8c9abdb2c5fdedb8642eeb",
        "resnet_layer4_0_conv1_weight.weights": "2a9c7b205eec079f0722099120943f8b6249a5ffb6366b1a751a596179528c74",
        "resnet_layer4_0_conv2_bias.weights": "529d9d2b9d9308830c206bad125f1778ded2f43c60640bf9e41c634c150d022a",
        "resnet_layer4_0_conv2_weight.weights": "99f17e3401543da8188f80414d2240d396c57e8d7087464e629aedfe07162e42",
        "resnet_layer4_0_shortcut_0_bias.weights": "edc8d70b5a28e86e5fba27052eaa79a1ff16839db048f75abeb542478f621238",
        "resnet_layer4_0_shortcut_0_weight.weights": "405832f62bd4a232c64a06132a89004bf18f294f0b69dd7d526c2368190d38f1",
        "resnet_layer4_1_conv1_bias.weights": "9bdd810f56419ed5e2155f4db1aa27e9baf62c6b54256717cf3b4356a7ba4cae",
        "resnet_layer4_1_conv1_weight.weights": "12755c8a0540632fa25a256b6bd5a325eb6a68f2c33016e1be37e56473829ee7",
        "resnet_layer4_1_conv2_bias.weights": "47d81ce34866ffe6bbc15ad49b16b44adaa579ef46ed58fc6c3e53eda8479c34",
        "resnet_layer4_1_conv2_weight.weights": "19cc925002aa7f0cbf59ad475f57cc3eeb5e90309f74463f762659cfef2a6d61",
        "resnet_layer4_2_conv1_bias.weights": "b704ede250e65092ee72cc908903506130ed9a01643e1c2b95a24f534c83d920",
        "resnet_layer4_2_conv1_weight.weights": "1ac4ca7deb7f88c470638011a03b795e7a37615aed21ef7fb0ae7452f1f6c0fa",
        "resnet_layer4_2_conv2_bias.weights": "02f57c75280692ab62eaccaae9927e28dd4a1ff11ea5c0f7face94d9d0571d36",
        "resnet_layer4_2_conv2_weight.weights": "adec9f7ddc8c8f930a6c2ba3674c188b7ac46e9e1ae4019c48754ccf15a1ed99",
        "resnet_seg_1_bias.weights": "000bd449421fbeaf2ac59e2b8bf582c564a48273354bce784f879fe8794bcdac",
        "resnet_seg_1_weight.weights": "7782aa6a5b66c34f8fbe83499c7ad757932344ce5ddbd97f1bf89bf6d3ebee85",
    ]
}
