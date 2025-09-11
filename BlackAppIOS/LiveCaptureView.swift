import SwiftUI
import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Filters

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

// MARK: - Camera Manager

final class BAICameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "bai.camera.session")
    private var videoDeviceInput: AVCaptureDeviceInput?

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    @Published var isRecording = false
    @Published var usingFrontCamera = false

    // Callbacks
    var onPhoto: ((UIImage) -> Void)?
    var onVideo: ((URL) -> Void)?

    override init() {
        super.init()
        session.sessionPreset = .high
    }

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

        session.inputs.forEach { session.removeInput($0) }
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else { return }
        session.addInput(videoInput)
        videoDeviceInput = videoInput

        if let audio = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audio),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        session.outputs.forEach { session.removeOutput($0) }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.isHighResolutionCaptureEnabled = true
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
    }

    func startRunning() {
        sessionQueue.async {
            self.activateCaptureAudioSession()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopRunning() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func flipCamera() {
        usingFrontCamera.toggle()
        sessionQueue.async { self.configureSession() }
    }

    // MARK: Audio session

    private func activateCaptureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func activatePlaybackAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true, options: [])
    }

    // MARK: Photo

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: Video

    func startRecording() {
        guard !movieOutput.isRecording else { return }
        if let conn = movieOutput.connection(with: .video),
           conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = usingFrontCamera }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        DispatchQueue.main.async {
            self.isRecording = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }
}

extension BAICameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        DispatchQueue.main.async { self.onPhoto?(image) }
    }
}

extension BAICameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async {
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

// MARK: - LiveCaptureView

struct LiveCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = BAICameraManager()

    // Editing / preview state
    @State private var capturedImage: UIImage? = nil
    @State private var capturedVideoURL: URL? = nil
    @State private var selectedFilter: LCFilterKind = .none

    // Video preview plumbing
    @State private var previewPlayer: AVPlayer? = nil
    @State private var itemObserver: NSKeyValueObservation? = nil
    @State private var videoReady = false
    @State private var isExportingVideo = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Live camera behind
            if capturedImage == nil && capturedVideoURL == nil {
                BAICameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                // Preview (image or video)
                Group {
                    if let img = capturedImage {
                        Image(uiImage: applyFilter(selectedFilter, to: img))
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 380)
                            .cornerRadius(16)
                            .padding(.horizontal, 12)
                    } else if capturedVideoURL != nil {
                        VideoPlayer(player: previewPlayer)
                            .frame(height: 380)
                            .cornerRadius(16)
                            .padding(.horizontal, 12)
                            .overlay(
                                Group {
                                    if !videoReady {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 16)
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
                        if capturedImage != nil || capturedVideoURL != nil {
                            // Back to live camera
                            capturedImage = nil
                            capturedVideoURL = nil
                            selectedFilter = .none
                            itemObserver?.invalidate()
                            previewPlayer?.pause()
                            previewPlayer = nil
                            videoReady = false
                            camera.startRunning()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundColor(.white)
                            .shadow(color: .blue.opacity(0.35), radius: 8, x: 0, y: 0)
                    }
                    Spacer()
                    Button { camera.flipCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundColor(.white)
                            .shadow(color: .purple.opacity(0.35), radius: 8, x: 0, y: 0)
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
                setupVideoPreview(initialUnfiltered: true) // show something immediately
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
        // Rebuild video preview when filter changes
        .onChange(of: selectedFilter) { _ in
            if capturedVideoURL != nil { setupVideoPreview(initialUnfiltered: false) }
        }
    }

    // MARK: Capture controls (futuristic styling)

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
                    Text("Recording…")
                        .font(.caption).bold()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.25))
                .cornerRadius(10)
            }

            HStack {
                Spacer()
                Button {
                    camera.capturePhoto()
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 86, height: 86)
                            .shadow(color: .blue.opacity(0.45), radius: 12)
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 6)
                            .frame(width: 78, height: 78)
                            .shadow(color: .cyan.opacity(0.7), radius: 8)
                        Circle()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: 62, height: 62)
                    }
                }
                Spacer()
            }

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

    // MARK: Editor controls

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
                routeToGossip()
            } label: {
                HStack {
                    if isExportingVideo { ProgressView().padding(.trailing, 6) }
                    Text(isExportingVideo ? "Preparing…" : "Use")
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
            .disabled(isExportingVideo)
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

        // Step 1: always show unfiltered first (fast path, avoids blank)
        if initialUnfiltered || selectedFilter == .none {
            let asset = AVAsset(url: url)
            let rawItem = AVPlayerItem(asset: asset)
            install(item: rawItem)
            previewPlayer?.play()
            videoReady = rawItem.status == .readyToPlay
        }

        // Step 2: if a filter is selected, build a filtered item and swap in when ready
        guard selectedFilter != .none else { return }

        let asset = AVAsset(url: url)
        let filteredItem = AVPlayerItem(asset: asset)
        if let comp = makeVideoComposition(for: asset, kind: selectedFilter) {
            filteredItem.videoComposition = comp
        }
        install(item: filteredItem)   // this will replace + observe status
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

    // MARK: Routing

    private func routeToGossip() {
        if let img = capturedImage {
            let filtered = applyFilter(selectedFilter, to: img)
            let payload: [String: Any] = [
                "type": "photo",
                "filter": selectedFilter.rawValue,
                "hasURL": false,
                "hasImage": true,
                "mediaURL": NSNull(),
                "image": filtered
            ]
            NotificationCenter.default.post(name: .inviteOrbCapturedMedia, object: nil, userInfo: payload)
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
                    let payload: [String: Any] = [
                        "type": "video",
                        "filter": self.selectedFilter.rawValue,
                        "hasURL": true,
                        "hasImage": false,
                        "mediaURL": finalURL,
                        "image": NSNull()
                    ]
                    NotificationCenter.default.post(name: .inviteOrbCapturedMedia, object: nil, userInfo: payload)
                    self.dismiss()
                }
            }
        }
    }
}
