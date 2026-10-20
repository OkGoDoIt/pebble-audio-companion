import AVFoundation
import CompanionRuntime
import SwiftUI

/// Step 1 of 3, Link (round 3: 03a, 03b). Scan the code the server's Link a phone page shows, or
/// type the server and the code. A code the app was opened with (`pebbleaudio://link`, or
/// `https://<server>/link?code=`) arrives here already filled in; nothing is sent until Link This
/// Phone.
struct AssistantsLinkScreen: View {
    private var source: AssistantsSource { SettingsDataSources.current.assistants }

    @State private var server = ""
    @State private var code = ""
    @State private var scanned = false
    @FocusState private var focus: Field?

    private enum Field { case server, code }

    var body: some View {
        @Bindable var flow = source.flow
        AssistantScroll(bottom: 34) {
            SetupStepBar(now: 0)
            Text(Copy.AssistantAccess.linkTitle)
                .font(AppFont.screenTitle)
                .kerning(0.36)
                .foregroundStyle(Tokens.label)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            if let failure = source.linkFailure {
                failureCard(failure)
            } else {
                Text(AttributedString.boldMarked(Copy.AssistantAccess.linkLede))
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .tint(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -4)
                CodeFinder { found in
                    server = found.host
                    code = found.code
                    scanned = true
                    link()
                }
            }
            AssistantSectionHeader(title: Copy.AssistantAccess.orEnterIt)
            AssistantCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Copy.AssistantAccess.serverField)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tertiary)
                        TextField(AssistantsDemo.host, text: $server)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.label)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                            .submitLabel(.next)
                            .focused($focus, equals: .server)
                            .onSubmit { focus = .code }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Tokens.fieldFill, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel(Copy.AssistantAccess.serverField)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Copy.AssistantAccess.codeField)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tertiary)
                        CodeBoxes(
                            code: $code, isFocused: focus == .code,
                            isError: source.linkFailure?.code != nil && source.linkFailure?.code == code
                        )
                        .focused($focus, equals: .code)
                    }
                    Button(action: link) {
                        HStack(spacing: 8) {
                            if source.isWorking { ProgressView().controlSize(.small) }
                            Text(source.isWorking ? Copy.AssistantAccess.linking : Copy.AssistantAccess.linkThisPhone)
                        }
                    }
                    .buttonStyle(.assistantBordered)
                    .disabled(!canLink)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(Copy.AssistantAccess.linkTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
        .onAppear {
            if server.isEmpty { server = flow.serverText }
            if code.isEmpty { code = flow.codeText }
            scanned = !flow.codeText.isEmpty
        }
        // An old failure never outlives the attempt it was about (it named a host the fields no
        // longer show, sweep item 20).
        .onDisappear { source.clearLinkFailure() }
        .onChange(of: server) { _, _ in clearFailureIfEdited() }
        .onChange(of: code) { _, newValue in
            if newValue != source.linkFailure?.code { clearFailureIfEdited() }
            scanned = false
        }
        .navigationDestination(isPresented: $flow.showChoose) { AssistantsChooseScreen() }
    }

    private var canLink: Bool {
        !source.isWorking && ArchiveLinkInvitation.normalizedCode(code).count == 8
            && source.linkFailure?.code != code
    }

    private func clearFailureIfEdited() {
        guard source.linkFailure != nil, !source.isWorking else { return }
        source.clearLinkFailure()
    }

    private func link() {
        focus = nil
        source.link(code: code, server: server, fromScan: scanned)
    }

    private func failureCard(_ failure: AssistantsLinkFailure) -> some View {
        AssistantCard {
            AssistantStateHead(dot: Tokens.attention, heading: failure.heading, line: failure.line)
            if failure.code != nil {
                Button {
                    code = ""
                    source.clearLinkFailure()
                } label: {
                    AssistantButtonLabel(title: Copy.AssistantAccess.scanNewCode, systemImage: "camera")
                }
                .buttonStyle(.assistantFilled)
                .padding(.top, 14)
            }
        }
    }
}

/// The 8 boxes of a code, with the dash after the fourth. A hidden field takes the typing (and a
/// paste of the whole code with its dash).
struct CodeBoxes: View {
    @Binding var code: String
    let isFocused: Bool
    var isError = false

    var body: some View {
        let characters = Array(ArchiveLinkInvitation.normalizedCode(code).prefix(8))
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<8, id: \.self) { index in
                    if index == 4 {
                        Capsule().fill(Tokens.faint).frame(width: 6, height: 2)
                    }
                    box(index < characters.count ? String(characters[index]) : "", index: index, filled: characters.count)
                }
            }
            TextField("", text: $code)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 48)
                .opacity(0.02)
                .accessibilityLabel(Copy.AssistantAccess.codeAccessibility)
                .accessibilityValue(String(characters))
        }
        .onChange(of: code) { _, newValue in
            let normalized = String(ArchiveLinkInvitation.normalizedCode(newValue).prefix(8))
            if normalized != newValue { code = normalized }
        }
    }

    private func box(_ text: String, index: Int, filled: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return Text(text)
            .font(AssistantFont.codeBox)
            .foregroundStyle(isError ? Tokens.tertiary : Tokens.label)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Tokens.fieldFill, in: shape)
            .overlay {
                if isError {
                    shape.strokeBorder(Tokens.attention, lineWidth: 1.5)
                } else if isFocused, index == min(filled, 7) {
                    shape.strokeBorder(Tokens.tint, lineWidth: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - The camera

/// The inline camera: 212 pt, radius 12, four white corners, and what it is doing.
struct CodeFinder: View {
    let onCode: (ArchiveLinkInvitation) -> Void

    @State private var access = CameraAccess.current

    var body: some View {
        ZStack {
            Rectangle().fill(Color(hex: 0x1C1C1E))
            if access == .available {
                QRScannerView(onCode: onCode)
            } else {
                RadialGradient(
                    colors: [Color(hex: 0x3A3A40), Color(hex: 0x1C1C1E), Color(hex: 0x111111)],
                    center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: 320)
            }
            FinderCorners()
                .frame(width: 136, height: 136)
                .offset(y: -10)
            VStack {
                Spacer()
                Text(caption)
                    .font(AssistantFont.cameraCaption)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
        .frame(height: 212)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.AssistantAccess.cameraAccessibility)
        .accessibilityValue(caption)
        .task {
            guard access == .undetermined else { return }
            access = await AVCaptureDevice.requestAccess(for: .video) ? .available : .denied
        }
    }

    private var caption: String {
        switch access {
        case .available, .undetermined, .demo: return Copy.AssistantAccess.cameraLooking
        case .denied: return Copy.AssistantAccess.cameraDenied
        case .unavailable: return Copy.AssistantAccess.cameraUnavailable
        }
    }
}

enum CameraAccess: Equatable {
    case available, undetermined, denied, unavailable
    /// The review screenshots: the finder as the mockup draws it, no camera.
    case demo

    @MainActor
    static var current: CameraAccess {
        if AssistantsDemo.state != nil { return .demo }
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .available
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }
}

struct FinderCorners: View {
    var body: some View {
        Canvas { context, size in
            let length: CGFloat = 28
            let radius: CGFloat = 10
            let inset: CGFloat = 1.75
            var path = Path()
            let w = size.width - inset
            let h = size.height - inset
            let i = inset
            // Top left, top right, bottom left, bottom right.
            path.move(to: CGPoint(x: i, y: length))
            path.addArc(tangent1End: CGPoint(x: i, y: i), tangent2End: CGPoint(x: length, y: i), radius: radius)
            path.addLine(to: CGPoint(x: length, y: i))
            path.move(to: CGPoint(x: w - length, y: i))
            path.addArc(tangent1End: CGPoint(x: w, y: i), tangent2End: CGPoint(x: w, y: length), radius: radius)
            path.addLine(to: CGPoint(x: w, y: length))
            path.move(to: CGPoint(x: i, y: h - length))
            path.addArc(tangent1End: CGPoint(x: i, y: h), tangent2End: CGPoint(x: length, y: h), radius: radius)
            path.addLine(to: CGPoint(x: length, y: h))
            path.move(to: CGPoint(x: w - length, y: h))
            path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w, y: h - length), radius: radius)
            path.addLine(to: CGPoint(x: w, y: h - length))
            context.stroke(path, with: .color(.white), lineWidth: 3.5)
        }
        .accessibilityHidden(true)
    }
}

/// A camera preview that reports the first link code it sees (the server's QR code holds a
/// `pebbleaudio://link` URL).
struct QRScannerView: UIViewRepresentable {
    let onCode: (ArchiveLinkInvitation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (ArchiveLinkInvitation) -> Void
        private let capture = CaptureBox()
        private var reported = false

        init(onCode: @escaping (ArchiveLinkInvitation) -> Void) {
            self.onCode = onCode
        }

        func attach(to view: PreviewView) {
            let session = capture.session
            view.previewLayer.session = session
            guard let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
            else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            capture.start()
        }

        func stop() { capture.stop() }

        /// Delivered on the main queue (`setMetadataObjectsDelegate(_:queue: .main)`).
        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let texts = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated { self.found(texts) }
        }

        private func found(_ texts: [String]) {
            guard !reported else { return }
            for text in texts {
                guard let url = URL(string: text), let invitation = ArchiveLinkInvitation.parse(url)
                else { continue }
                reported = true
                capture.stop()
                onCode(invitation)
                return
            }
        }
    }

    /// The session, started and stopped off the main thread as AVFoundation asks.
    final class CaptureBox: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "dev.audiocompanion.link-camera")

        func start() {
            queue.async { [self] in if !self.session.isRunning { self.session.startRunning() } }
        }

        func stop() {
            queue.async { [self] in if self.session.isRunning { self.session.stopRunning() } }
        }
    }
}
