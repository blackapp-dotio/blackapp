import SwiftUI
import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Filters (unchanged)

enum LCFilterKind: String, CaseIterable, Identifiable {
    case none, mono, sepia, vivid
    var id: String { rawValue }
}

private let ciContext = CIContext()

func applyFilter(_ kind: LCFilterKind, to image: UIImage) -> UIImage {
    guard kind != .none, let cg = image.cgImage else { return image }
    let ci = CIImage(cgImage: cg)

    let out: CIImage
    switch kind {
    case .mono:
        let f = CIFilter.photoEffectNoir()
        f.inputImage = ci
        out = f.outputImage ?? ci
    case .sepia:
        let f = CIFilter.sepiaTone()
        f.intensity = 0.9
        f.inputImage = ci
        out = f.outputImage ?? ci
    case .vivid:
        let f = CIFilter.colorControls()
        f.inputImage = ci
        f.saturation = 1.4
        f.contrast   = 1.1
        f.brightness = 0.05
        out = f.outputImage ?? ci
    case .none:
        out = ci
    }

    guard let cgOut = ciContext.createCGImage(out, from: out.extent) else { return image }
    return UIImage(cgImage: cgOut, scale: image.scale, orientation: image.imageOrientation)
}

func makeVideoComposition(for asset: AVAsset, kind: LCFilterKind) -> AVVideoComposition? {
    guard kind != .none else { return nil }
    return AVVideoComposition(asset: asset) { request in
        var img = request.sourceImage.clampedToExtent()
        switch kind {
        case .mono:
            let f = CIFilter.photoEffectNoir()
            f.inputImage = img
            img = f.outputImage ?? img
        case .sepia:
            let f = CIFilter.sepiaTone()
            f.intensity = 0.9
            f.inputImage = img
            img = f.outputImage ?? img
        case .vivid:
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = 1.4
            f.contrast   = 1.1
            f.brightness = 0.05
            img = f.outputImage ?? img
        case .none: break
        }
        let cropped = img.cropped(to: request.sourceImage.extent)
        request.finish(with: cropped, context: nil)
    }
}

func exportFilteredVideo(asset: AVAsset, kind: LCFilterKind, completion: @escaping (URL?) -> Void) {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mp4")

    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
        completion(nil); return
    }
    exporter.outputURL = outputURL
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = true
    exporter.videoComposition = makeVideoComposition(for: asset, kind: kind)

    exporter.exportAsynchronously {
        guard exporter.status == .completed else { completion(nil); return }
        completion(outputURL)
    }
}

// MARK: - Optional resumable uploader hook

protocol MediaUploader {
    /// type: "photo" | "video"
    func upload(fileURL: URL,
                type: String,
                progress: @escaping (Double) -> Void,
                completion: @escaping (Result<URL, Error>) -> Void)
}

// MARK: - Camera Manager (Instagram-like pipeline)

final class BAICameraManager: NSObject, ObservableObject {
    // Public, observed state
    @Published var isRecording = false
    @Published var usingFrontCamera = false
    @Published var recordDuration: TimeInterval = 0
    @Published var photoProgress: Double = 0   // for UI pulse/feedback (fake-progress feel)

    // Session graph
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "bai.camera.session")
    private var videoDeviceInput: AVCaptureDeviceInput?

    // Outputs
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    // Timers / state
    private var recordTimer: Timer?

    // Callbacks
    var onPhoto: ((UIImage) -> Void)?
    var onVideo: ((URL) -> Void)?

    override init() {
        super.init()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .hd1920x1080  // Target 1080p by default
        addObservers()
    }

    deinit { removeObservers() }

    // MARK: Permissions + Configure

    func requestPermissionsAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] vGranted in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                guard vGranted else { return }
                self?.sessionQueue.async { self?.configureSession() }
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Inputs
        session.inputs.forEach { session.removeInput($0) }

        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput)
        else { return }
        session.addInput(videoInput)
        videoDeviceInput = videoInput

        // Prefer 30 FPS stable pacing
        do {
            try videoDevice.lockForConfiguration()
            if videoDevice.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate }) {
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            videoDevice.focusMode = .continuousAutoFocus
            videoDevice.exposureMode = .continuousAutoExposure
            videoDevice.whiteBalanceMode = .continuousAutoWhiteBalance
            videoDevice.unlockForConfiguration()
        } catch { /* ignore */ }

        // Audio
        if let audio = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audio),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        // Outputs
        session.outputs.forEach { session.removeOutput($0) }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.isHighResolutionCaptureEnabled = true
            photoOutput.maxPhotoQualityPrioritization = .balanced
            // Pre-warm prepared photo settings (ZSL-ish feel)
            let hevc: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc]
            let heifSettings = AVCapturePhotoSettings(format: hevc)
            heifSettings.isHighResolutionPhotoEnabled = true
            heifSettings.flashMode = .off
            photoOutput.setPreparedPhotoSettingsArray([heifSettings], completionHandler: nil)
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            // Limit bit rate / file size growth in a sane way
            movieOutput.maxRecordedDuration = CMTime.invalid // unlimited
            movieOutput.movieFragmentInterval = CMTime(value: 1, timescale: 1) // smoother writing
        }
    }

    // MARK: Start/Stop

    func startRunning() {
        sessionQueue.async {
            self.activateCaptureAudioSession()
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopRunning() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func flipCamera() {
        usingFrontCamera.toggle()
        sessionQueue.async { self.configureSession() }
    }

    // MARK: Audio session

    private func activateCaptureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord,
                           mode: .videoRecording,
                           options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
        try? s.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func activatePlaybackAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true, options: [])
    }

    // MARK: Photo

    func capturePhoto() {
        // ZSL-ish: use prewarmed settings for instant shutter
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.isHighResolutionPhotoEnabled = true
        settings.flashMode = .off
        if photoOutput.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = false
        }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred() // instant haptic
        photoProgress = 0.33
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: Video

    func startRecording() {
        guard !movieOutput.isRecording else { return }

        if let conn = movieOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = usingFrontCamera }
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .cinematic // auto-crop for stability
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        // Start writing
        movieOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordDuration = 0
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            self.recordTimer?.invalidate()
            self.recordTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.recordDuration += 0.2
            }
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    // MARK: Interruptions

    private func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange),
                                               name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        // Gracefully stop timers / flags; session will be paused by the system
        DispatchQueue.main.async {
            self.recordTimer?.invalidate()
            self.recordTimer = nil
            self.isRecording = false
        }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        // Ready to resume quickly
    }

    @objc private func subjectAreaDidChange() {
        // could fine-tune focus/exposure if desired
    }
}

// MARK: Delegates

extension BAICameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { self.photoProgress = 0.66 }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            DispatchQueue.main.async { self.photoProgress = 0 }
            return
        }
        DispatchQueue.main.async {
            self.photoProgress = 1.0
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.onPhoto?(image)
            // Reset progress after a short delay to allow UI to animate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.photoProgress = 0 }
        }
    }
}

extension BAICameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        // no-op
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async {
            self.recordTimer?.invalidate()
            self.recordTimer = nil
            self.isRecording = false
            guard error == nil else { return }
            self.onVideo?(outputFileURL)
        }
    }
}

// MARK: - Preview Layer Host

struct BAICameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - LiveCaptureView (water-drop UI + uploader hook)

struct LiveCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = BAICameraManager()

    // Optional uploader (inject from parent when ready)
    var uploader: MediaUploader? = nil

    // Editing / preview state
    @State private var capturedImage: UIImage? = nil
    @State private var capturedVideoURL: URL? = nil
    @State private var selectedFilter: LCFilterKind = .none

    // Video preview plumbing
    @State private var previewPlayer: AVPlayer? = nil
    @State private var itemObserver: NSKeyValueObservation? = nil
    @State private var videoReady = false
    @State private var isExportingVideo = false

    // Upload UI
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0

    // Pulse indicator for recording
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Live camera or media preview
            if capturedImage == nil && capturedVideoURL == nil {
                BAICameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Group {
                    if let img = capturedImage {
                        Image(uiImage: applyFilter(selectedFilter, to: img))
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 380)
                            .cornerRadius(20)
                            .padding(.horizontal, 12)
                    } else if capturedVideoURL != nil {
                        VideoPlayer(player: previewPlayer)
                            .frame(height: 380)
                            .cornerRadius(20)
                            .padding(.horizontal, 12)
                            .overlay(
                                Group {
                                    if !videoReady {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 20)
                                                .fill(Color.black.opacity(0.35))
                                            ProgressView("Loading preview…")
                                                .padding()
                                        }
                                    }
                                }
                            )
                            .onDisappear { previewPlayer?.pause() }
                    }
                }
                .transition(.opacity)
                .ignoresSafeArea(edges: .bottom)
            }

            // Top bar
            VStack {
                HStack {
                    Button {
                        if capturedImage != nil || capturedVideoURL != nil || isUploading || isExportingVideo {
                            // Back to live camera only when safe
                            guard !isUploading, !isExportingVideo else { return }
                            resetToLive()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundColor(.white)
                            .shadow(color: .blue.opacity(0.35), radius: 8)
                    }
                    Spacer()
                    Button {
                        guard !camera.isRecording else { return }
                        camera.flipCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundColor(.white)
                            .shadow(color: .purple.opacity(0.35), radius: 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 48)

                Spacer()

                // Bottom controls
                if capturedImage == nil && capturedVideoURL == nil {
                    captureControls
                } else {
                    editorControls
                }
            }

            // Overlay: photo “fake progress” ring for instant feedback
            if camera.photoProgress > 0 && capturedImage == nil && capturedVideoURL == nil {
                Circle()
                    .trim(from: 0, to: CGFloat(camera.photoProgress))
                    .stroke(style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 96, height: 96)
                    .shadow(radius: 8)
                    .transition(.opacity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            camera.onPhoto = { img in
                camera.stopRunning()
                camera.activatePlaybackAudioSession()
                capturedImage = img
                capturedVideoURL = nil
                selectedFilter = .none
            }
            camera.onVideo = { url in
                camera.stopRunning()
                camera.activatePlaybackAudioSession()
                capturedVideoURL = url
                capturedImage = nil
                selectedFilter = .none
                setupVideoPreview(initialUnfiltered: true)
            }
            camera.requestPermissionsAndConfigure()
            camera.startRunning()
        }
        .onDisappear {
            itemObserver?.invalidate()
            previewPlayer?.pause()
            previewPlayer = nil
            camera.stopRunning()
        }
        .onChange(of: selectedFilter) { _ in
            if capturedVideoURL != nil { setupVideoPreview(initialUnfiltered: false) }
        }
    }

    // MARK: Capture controls (water-drop style)

    private var captureControls: some View {
        VStack(spacing: 18) {
            if camera.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .scaleEffect(pulse ? 1.3 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                    Text(String(format: "REC • %.1fs", camera.recordDuration))
                        .font(.caption).bold()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.25))
                .cornerRadius(10)
            }

            // Shutter
            HStack {
                Spacer()
                Button {
                    camera.capturePhoto()
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 92, height: 92)
                            .shadow(color: .blue.opacity(0.45), radius: 12)
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 6)
                            .frame(width: 84, height: 84)
                            .shadow(color: .cyan.opacity(0.7), radius: 8)
                        Circle()
                            .fill(Color.white.opacity(0.98))
                            .frame(width: 66, height: 66)
                    }
                }
                Spacer()
            }

            // Record toggle
            HStack(spacing: 22) {
                Button {
                    camera.isRecording ? camera.stopRecording() : camera.startRecording()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: camera.isRecording ? "stop.fill" : "record.circle")
                        Text(camera.isRecording ? "Stop" : "Record")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(camera.isRecording ? Color.red : Color.white.opacity(0.14))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .shadow(color: .red.opacity(camera.isRecording ? 0.4 : 0.0), radius: 10)
                }
            }
            .padding(.bottom, 36)
        }
        .padding(.bottom, 18)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: Editor controls (filters + Use/Upload)

    private var editorControls: some View {
        VStack(spacing: 12) {
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LCFilterKind.allCases) { f in
                        Button {
                            selectedFilter = f
                        } label: {
                            Text(f.rawValue.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(selectedFilter == f ? Color.blue.opacity(0.9) : Color.white.opacity(0.18))
                                )
                                .overlay(
                                    Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                                .foregroundColor(.white)
                                .shadow(color: selectedFilter == f ? .blue.opacity(0.4) : .clear, radius: 8)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            Button {
                routeToGossipOrUpload()
            } label: {
                HStack {
                    if isExportingVideo || isUploading { ProgressView().padding(.trailing, 6) }
                    Text(isUploading ? "\(Int(uploadProgress * 100))% Uploading" :
                         (isExportingVideo ? "Preparing…" : "Use"))
                        .bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .leading, endPoint: .trailing))
                )
                .foregroundColor(.white)
                .shadow(color: .blue.opacity(0.35), radius: 10)
                .padding(.horizontal, 16)
            }
            .disabled(isExportingVideo || isUploading)
            .padding(.bottom, 28)
        }
        .background(
            LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: Video preview plumbing

    private func setupVideoPreview(initialUnfiltered: Bool) {
        guard let url = capturedVideoURL else { return }

        // Step 1: always show unfiltered first (fast path)
        if initialUnfiltered || selectedFilter == .none {
            let asset = AVAsset(url: url)
            let rawItem = AVPlayerItem(asset: asset)
            install(item: rawItem)
            previewPlayer?.play()
            videoReady = rawItem.status == .readyToPlay
        }

        // Step 2: if a filter is selected, build a filtered item and swap when ready
        guard selectedFilter != .none else { return }
        let asset = AVAsset(url: url)
        let filteredItem = AVPlayerItem(asset: asset)
        if let comp = makeVideoComposition(for: asset, kind: selectedFilter) {
            filteredItem.videoComposition = comp
        }
        install(item: filteredItem)
        previewPlayer?.play()
    }

    private func install(item: AVPlayerItem) {
        itemObserver?.invalidate()
        itemObserver = item.observe(\.status, options: [.initial, .new]) { itm, _ in
            DispatchQueue.main.async {
                self.videoReady = (itm.status == .readyToPlay)
            }
        }
        if let p = previewPlayer {
            p.replaceCurrentItem(with: item)
            p.isMuted = true
        } else {
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            previewPlayer = p
        }
    }

    // MARK: Routing / Upload

    private func routeToGossipOrUpload() {
        if let img = capturedImage {
            let filtered = applyFilter(selectedFilter, to: img)

            // If uploader provided, write image to temp and upload; else notify
            if let uploader = uploader,
               let data = filtered.jpegData(compressionQuality: 0.92) {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("jpg")
                do {
                    try data.write(to: tempURL)
                    isUploading = true
                    uploadProgress = 0
                    uploader.upload(fileURL: tempURL, type: "photo") { p in
                        DispatchQueue.main.async { self.uploadProgress = p }
                    } completion: { result in
                        DispatchQueue.main.async {
                            self.isUploading = false
                            switch result {
                            case .success(let remoteURL):
                                postNotification(type: "photo", mediaURL: remoteURL, image: nil)
                                self.dismiss()
                            case .failure:
                                // fall back to local route if needed
                                postNotification(type: "photo", mediaURL: nil, image: filtered)
                                self.dismiss()
                            }
                        }
                    }
                } catch {
                    postNotification(type: "photo", mediaURL: nil, image: filtered)
                    dismiss()
                }
                return
            }

            // Original route: post in-memory image
            postNotification(type: "photo", mediaURL: nil, image: filtered)
            dismiss()
            return
        }

        if let url = capturedVideoURL {
            isExportingVideo = true
            let asset = AVAsset(url: url)
            exportFilteredVideo(asset: asset, kind: selectedFilter) { outputURL in
                DispatchQueue.main.async {
                    self.isExportingVideo = false
                    let finalURL = outputURL ?? url

                    if let uploader = uploader {
                        self.isUploading = true
                        self.uploadProgress = 0
                        uploader.upload(fileURL: finalURL, type: "video") { p in
                            DispatchQueue.main.async { self.uploadProgress = p }
                        } completion: { result in
                            DispatchQueue.main.async {
                                self.isUploading = false
                                switch result {
                                case .success(let remoteURL):
                                    self.postNotification(type: "video", mediaURL: remoteURL, image: nil)
                                case .failure:
                                    self.postNotification(type: "video", mediaURL: finalURL, image: nil)
                                }
                                self.dismiss()
                            }
                        }
                        return
                    }

                    // Original route: notify with local file URL
                    self.postNotification(type: "video", mediaURL: finalURL, image: nil)
                    self.dismiss()
                }
            }
        }
    }

    private func postNotification(type: String, mediaURL: URL?, image: UIImage?) {
        let payload: [String: Any] = [
            "type": type,
            "filter": selectedFilter.rawValue,
            "hasURL": mediaURL != nil,
            "hasImage": image != nil,
            "mediaURL": mediaURL as Any? ?? NSNull(),
            "image": image as Any? ?? NSNull()
        ]
        NotificationCenter.default.post(name: .inviteOrbCapturedMedia, object: nil, userInfo: payload)
    }

    private func resetToLive() {
        capturedImage = nil
        capturedVideoURL = nil
        selectedFilter = .none
        itemObserver?.invalidate()
        previewPlayer?.pause()
        previewPlayer = nil
        videoReady = false
        camera.startRunning()
    }
}

/*// MARK: - Notification name (unchanged from your downstream usage)
 
 extension Notification.Name {
 static let inviteOrbCapturedMedia = Notification.Name("inviteOrbCapturedMedia")
 }
 */
