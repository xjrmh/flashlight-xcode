import AVFoundation
import SwiftUI
import CoreImage
import Accelerate
import ImageIO
import os.log

/// Detailed light analysis for debugging and visualization
struct LightAnalysis {
    let peakBrightness: Double      // 0-1 max luminance in ROI
    let centerBrightness: Double    // 0-1 brightness at center cluster
    let edgeBrightness: Double      // 0-1 average brightness at edges
    let signalToNoise: Double       // Ratio of center to edge brightness
    let timestamp: CFAbsoluteTime
    
    /// Score optimized for detecting a point light source
    var lightSourceScore: Double {
        // A flashlight pointed at camera will have:
        // - Very high center brightness (often saturated)
        // - Lower edge brightness
        // - High signal-to-noise ratio
        let centerWeight = 0.5
        let snrWeight = 0.3
        let peakWeight = 0.2
        
        return (centerBrightness * centerWeight) +
               (min(1.0, signalToNoise / 3.0) * snrWeight) +
               (peakBrightness * peakWeight)
    }
}

/// High-performance light detector optimized for morse code reception
class CameraLightDetector: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isRunning = false
    @Published var currentBrightness: Double = 0.0
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var lastAnalysis: LightAnalysis?
    @Published var permissionStatus: AVAuthorizationStatus = .notDetermined
    @Published var isCalibrating = true
    @Published var signalQuality: SignalQuality = .none
    
    enum SignalQuality: String {
        case none = "No Signal"
        case weak = "Weak"
        case good = "Good"
        case strong = "Strong"
    }

    // MARK: - Camera
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var camera: AVCaptureDevice?
    private let processingQueue = DispatchQueue(label: "com.flashlight.camera", qos: .userInteractive)
    private let ciContext = CIContext()
    
    // MARK: - Calibration
    private var calibrationFrameCount = 0
    private let calibrationFramesNeeded = 20
    private var baselineLevel: Double = 0
    private var baselineSamples: [Double] = []
    
    // MARK: - Signal Processing
    private var signalHistory: [Double] = []
    private let signalHistorySize = 4  // Smaller for faster response
    private var lastFrameTime: CFAbsoluteTime = 0
    
    /// Region of interest for light detection (center portion of frame)
    var roiSize: CGFloat = 0.25
    
    /// ROI center position (normalized 0-1), default is center
    @Published var roiCenterX: CGFloat = 0.5
    @Published var roiCenterY: CGFloat = 0.5
    
    /// Callback for brightness updates with high-precision timestamp
    var onBrightnessUpdate: ((Double, CFAbsoluteTime) -> Void)?
    
    // MARK: - Recording for Replay
    @Published var isRecording = false
    @Published var hasRecording = false
    @Published var isReplaying = false
    private var recordedFrames: [RecordedFrame] = []
    private var replayIndex = 0
    private var replayTimer: Timer?
    private let maxRecordingFrames = 1800  // 30 seconds at 60fps
    
    struct RecordedFrame {
        let imageData: Data  // JPEG compressed for memory efficiency
        let timestamp: CFAbsoluteTime
        let width: Int
        let height: Int
    }
    
    // MARK: - Memory Pressure Monitoring
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    @Published var isUnderMemoryPressure = false
    
    /// Estimated memory usage of recorded frames in bytes
    var recordingMemoryUsage: Int {
        recordedFrames.reduce(0) { $0 + $1.imageData.count }
    }
    
    /// Formatted memory usage string
    var recordingMemoryUsageFormatted: String {
        let bytes = recordingMemoryUsage
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    override init() {
        super.init()
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
        setupMemoryPressureMonitoring()
    }
    
    deinit {
        memoryPressureSource?.cancel()
    }
    
    private func setupMemoryPressureMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let event = self.memoryPressureSource?.data ?? []
            
            if event.contains(.critical) {
                Logger.log("Critical memory pressure - clearing recording buffer", level: .warning, category: .camera)
                self.isUnderMemoryPressure = true
                self.clearRecording()
                self.stopRecording()
            } else if event.contains(.warning) {
                Logger.log("Memory pressure warning - recording has \(self.recordingMemoryUsageFormatted)", level: .warning, category: .camera)
                self.isUnderMemoryPressure = true
                
                // If we have a lot of frames, trim to half
                if self.recordedFrames.count > 300 {
                    let keepCount = self.recordedFrames.count / 2
                    self.recordedFrames = Array(self.recordedFrames.suffix(keepCount))
                    Logger.log("Trimmed recording to \(keepCount) frames", level: .info, category: .camera)
                }
            }
        }
        
        memoryPressureSource?.resume()
    }

    func checkPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async {
                self.permissionStatus = .authorized
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.permissionStatus = granted ? .authorized : .denied
                    completion(granted)
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.permissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
                completion(false)
            }
        @unknown default:
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func setupCamera() {
        let session = AVCaptureSession()
        // Use higher frame rate for better timing resolution
        session.sessionPreset = .high

        guard let cameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            Logger.log("No back camera available", level: .error, category: .camera)
            return
        }

        self.camera = cameraDevice

        do {
            try cameraDevice.lockForConfiguration()
            
            // Configure for maximum frame rate
            let desiredFrameRate: Double = 60
            var bestFormat: AVCaptureDevice.Format?
            var bestFrameRateRange: AVFrameRateRange?
            
            for format in cameraDevice.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate >= desiredFrameRate {
                        if bestFrameRateRange == nil || range.maxFrameRate > bestFrameRateRange!.maxFrameRate {
                            bestFormat = format
                            bestFrameRateRange = range
                        }
                    }
                }
            }
            
            if let format = bestFormat, let range = bestFrameRateRange {
                cameraDevice.activeFormat = format
                cameraDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(range.maxFrameRate))
                cameraDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(range.maxFrameRate))
            }
            
            // Start with auto-exposure for calibration
            if cameraDevice.isExposureModeSupported(.continuousAutoExposure) {
                cameraDevice.exposureMode = .continuousAutoExposure
            }
            if cameraDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                cameraDevice.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            cameraDevice.unlockForConfiguration()

            let input = try AVCaptureDeviceInput(device: cameraDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: processingQueue)
            output.alwaysDiscardsLateVideoFrames = true

            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            self.captureSession = session
            self.videoOutput = output

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill

            DispatchQueue.main.async {
                self.previewLayer = layer
            }

        } catch {
            Logger.logError("Camera setup failed", error: error, category: .camera)
        }
    }

    private func lockExposureSettings() {
        guard let camera = camera else { return }
        do {
            try camera.lockForConfiguration()
            
            // Lock current exposure
            if camera.isExposureModeSupported(.locked) {
                camera.exposureMode = .locked
            }
            // Keep auto white balance - it helps with light detection
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            camera.unlockForConfiguration()
        } catch {
            Logger.logError("Failed to lock camera settings", error: error, category: .camera)
        }
    }

    func start() {
        guard let session = captureSession, !session.isRunning else { return }
        
        // Reset state
        isCalibrating = true
        calibrationFrameCount = 0
        baselineSamples = []
        baselineLevel = 0
        signalHistory = []
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        
        processingQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }

    func stop() {
        guard let session = captureSession, session.isRunning else { return }
        processingQueue.async {
            session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
                self.isCalibrating = true
            }
        }
    }
    
    // MARK: - Recording
    
    func startRecording() {
        recordedFrames.removeAll()
        isRecording = true
        hasRecording = false
    }
    
    func stopRecording() {
        isRecording = false
        hasRecording = !recordedFrames.isEmpty
    }
    
    func clearRecording() {
        recordedFrames.removeAll()
        hasRecording = false
        isReplaying = false
        replayTimer?.invalidate()
        replayTimer = nil
    }
    
    // MARK: - Replay
    
    func startReplay(onFrame: @escaping (CGImage, CFAbsoluteTime) -> Void) {
        guard hasRecording, !recordedFrames.isEmpty else { return }
        
        isReplaying = true
        replayIndex = 0
        
        // Calculate frame interval from recording
        let frameInterval: TimeInterval
        if recordedFrames.count > 1 {
            let totalTime = recordedFrames.last!.timestamp - recordedFrames.first!.timestamp
            frameInterval = totalTime / Double(recordedFrames.count - 1)
        } else {
            frameInterval = 1.0 / 60.0
        }
        
        replayTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isReplaying else {
                self?.replayTimer?.invalidate()
                return
            }
            
            if self.replayIndex < self.recordedFrames.count {
                let frame = self.recordedFrames[self.replayIndex]
                if let image = self.decompressFrame(frame) {
                    onFrame(image, frame.timestamp)
                }
                self.replayIndex += 1
            } else {
                // Loop replay
                self.replayIndex = 0
            }
        }
    }
    
    func stopReplay() {
        isReplaying = false
        replayTimer?.invalidate()
        replayTimer = nil
    }
    
    /// Restart replay from the beginning
    func restartReplay(onFrame: @escaping (CGImage, CFAbsoluteTime) -> Void) {
        stopReplay()
        startReplay(onFrame: onFrame)
    }
    
    /// Reprocess all recorded frames with current ROI position
    func reprocessRecording(roiCenterX: CGFloat, roiCenterY: CGFloat) -> [(brightness: Double, timestamp: CFAbsoluteTime)] {
        self.roiCenterX = roiCenterX
        self.roiCenterY = roiCenterY
        
        var results: [(brightness: Double, timestamp: CFAbsoluteTime)] = []
        
        // Reset calibration for reprocessing
        var reprocessBaselineSamples: [Double] = []
        var reprocessBaselineLevel: Double = 0
        var reprocessSignalHistory: [Double] = []
        
        for (index, frame) in recordedFrames.enumerated() {
            guard let cgImage = decompressFrame(frame) else { continue }
            
            let analysis = analyzeImageForLightSource(cgImage, width: frame.width, height: frame.height, timestamp: frame.timestamp)
            let score = analysis.lightSourceScore
            
            // Calibration phase
            if index < calibrationFramesNeeded {
                reprocessBaselineSamples.append(score)
                if index == calibrationFramesNeeded - 1 {
                    let sorted = reprocessBaselineSamples.sorted()
                    reprocessBaselineLevel = sorted[sorted.count / 2]
                }
                continue
            }
            
            // Smoothing
            let smoothedScore: Double
            if reprocessSignalHistory.isEmpty {
                smoothedScore = score
            } else {
                let lastValue = reprocessSignalHistory.last ?? score
                let alpha = score > lastValue ? 0.85 : 0.6
                smoothedScore = lastValue * (1 - alpha) + score * alpha
            }
            
            reprocessSignalHistory.append(smoothedScore)
            if reprocessSignalHistory.count > signalHistorySize {
                reprocessSignalHistory.removeFirst()
            }
            
            // Normalize
            let normalizedSignal: Double
            if reprocessBaselineLevel > 0.01 {
                normalizedSignal = max(0, (smoothedScore - reprocessBaselineLevel * 0.8) / (1.0 - reprocessBaselineLevel * 0.8))
            } else {
                normalizedSignal = smoothedScore
            }
            
            results.append((normalizedSignal, frame.timestamp))
        }
        
        return results
    }
    
    private func compressFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CFAbsoluteTime) -> RecordedFrame? {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Camera captures in landscape, rotate to portrait (90 degrees clockwise)
        // The orientation transform rotates the image to match the screen orientation
        ciImage = ciImage.oriented(.right)

        // Scale down for memory efficiency
        let scale: CGFloat = 0.3
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledWidth = Int(scaledImage.extent.width)
        let scaledHeight = Int(scaledImage.extent.height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5
        ]

        guard let jpegData = ciContext.jpegRepresentation(of: scaledImage, colorSpace: colorSpace, options: options) else {
            return nil
        }

        return RecordedFrame(imageData: jpegData, timestamp: timestamp, width: scaledWidth, height: scaledHeight)
    }

    private func decompressFrame(_ frame: RecordedFrame) -> CGImage? {
        let data = frame.imageData as CFData
        guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    
    /// Analyze a CGImage for light source (used in replay/reprocess)
    private func analyzeImageForLightSource(_ cgImage: CGImage, width: Int, height: Int, timestamp: CFAbsoluteTime) -> LightAnalysis {
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let buffer = CFDataGetBytePtr(data) else {
            return LightAnalysis(peakBrightness: 0, centerBrightness: 0, edgeBrightness: 0, signalToNoise: 0, timestamp: timestamp)
        }
        
        let bytesPerRow = cgImage.bytesPerRow
        let bitsPerPixel = cgImage.bitsPerPixel
        let bytesPerPixel = bitsPerPixel / 8
        
        // Use actual CGImage dimensions for analysis (they match the stored frame dimensions)
        let actualWidth = cgImage.width
        let actualHeight = cgImage.height
        
        // Calculate ROI based on current position
        let roiSide = Int(Double(min(actualWidth, actualHeight)) * Double(roiSize))
        let centerX = Int(CGFloat(actualWidth) * roiCenterX)
        let centerY = Int(CGFloat(actualHeight) * roiCenterY)
        
        let innerSize = roiSide * 2 / 5
        let innerStartX = max(0, centerX - innerSize / 2)
        let innerStartY = max(0, centerY - innerSize / 2)
        
        var centerTotal: Double = 0
        var centerCount: Double = 0
        var centerPeak: Double = 0
        
        for y in stride(from: innerStartY, to: min(innerStartY + innerSize, actualHeight), by: 1) {
            for x in stride(from: innerStartX, to: min(innerStartX + innerSize, actualWidth), by: 1) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                
                let r: Double, g: Double, b: Double
                if bytesPerPixel >= 3 {
                    r = Double(buffer[offset])
                    g = Double(buffer[offset + 1])
                    b = Double(buffer[offset + 2])
                } else {
                    let gray = Double(buffer[offset])
                    r = gray; g = gray; b = gray
                }
                
                let luminance = (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
                centerTotal += luminance
                centerPeak = max(centerPeak, luminance)
                centerCount += 1
            }
        }
        
        let centerBrightness = centerCount > 0 ? centerTotal / centerCount : 0
        
        return LightAnalysis(
            peakBrightness: centerPeak,
            centerBrightness: centerBrightness,
            edgeBrightness: 0,
            signalToNoise: centerBrightness * 10,
            timestamp: timestamp
        )
    }

    /// Analyze the center region for light source with optimized algorithm
    private func analyzeForLightSource(from sampleBuffer: CMSampleBuffer) -> LightAnalysis {
        let timestamp = CFAbsoluteTimeGetCurrent()
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return LightAnalysis(peakBrightness: 0, centerBrightness: 0, edgeBrightness: 0, signalToNoise: 0, timestamp: timestamp)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return LightAnalysis(peakBrightness: 0, centerBrightness: 0, edgeBrightness: 0, signalToNoise: 0, timestamp: timestamp)
        }
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Calculate ROI dimensions
        let roiSide = Int(Double(min(width, height)) * Double(roiSize))
        let centerX = width / 2
        let centerY = height / 2
        
        // Center region (inner 40% of ROI) - where the light source should be
        let innerSize = roiSide * 2 / 5
        let innerStartX = centerX - innerSize / 2
        let innerStartY = centerY - innerSize / 2
        
        // Edge region (outer ring of ROI)
        let outerStartX = centerX - roiSide / 2
        let outerStartY = centerY - roiSide / 2

        var centerTotal: Double = 0
        var centerCount: Double = 0
        var centerPeak: Double = 0
        
        var edgeTotal: Double = 0
        var edgeCount: Double = 0

        // Sample center region densely
        let centerStep = 1
        for y in stride(from: innerStartY, to: innerStartY + innerSize, by: centerStep) {
            for x in stride(from: innerStartX, to: innerStartX + innerSize, by: centerStep) {
                guard y >= 0 && y < height && x >= 0 && x < width else { continue }
                let offset = y * bytesPerRow + x * 4
                let b = Double(buffer[offset])
                let g = Double(buffer[offset + 1])
                let r = Double(buffer[offset + 2])
                
                // Fast luminance approximation
                let luminance = (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
                
                centerTotal += luminance
                centerPeak = max(centerPeak, luminance)
                centerCount += 1
            }
        }
        
        // Sample edge region (only the outer ring, skip center)
        let edgeStep = 2
        for y in stride(from: outerStartY, to: outerStartY + roiSide, by: edgeStep) {
            for x in stride(from: outerStartX, to: outerStartX + roiSide, by: edgeStep) {
                guard y >= 0 && y < height && x >= 0 && x < width else { continue }
                
                // Skip if inside center region
                if x >= innerStartX && x < innerStartX + innerSize &&
                   y >= innerStartY && y < innerStartY + innerSize {
                    continue
                }
                
                let offset = y * bytesPerRow + x * 4
                let b = Double(buffer[offset])
                let g = Double(buffer[offset + 1])
                let r = Double(buffer[offset + 2])
                
                let luminance = (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
                
                edgeTotal += luminance
                edgeCount += 1
            }
        }

        let centerBrightness = centerCount > 0 ? centerTotal / centerCount : 0
        let edgeBrightness = edgeCount > 0 ? edgeTotal / edgeCount : 0
        let snr = edgeBrightness > 0.01 ? centerBrightness / edgeBrightness : centerBrightness * 10
        
        return LightAnalysis(
            peakBrightness: centerPeak,
            centerBrightness: centerBrightness,
            edgeBrightness: edgeBrightness,
            signalToNoise: snr,
            timestamp: timestamp
        )
    }
    
    private func updateSignalQuality(_ score: Double) {
        let quality: SignalQuality
        if score < 0.1 {
            quality = .none
        } else if score < 0.3 {
            quality = .weak
        } else if score < 0.6 {
            quality = .good
        } else {
            quality = .strong
        }
        
        if quality != signalQuality {
            DispatchQueue.main.async {
                self.signalQuality = quality
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraLightDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let analysis = analyzeForLightSource(from: sampleBuffer)
        let score = analysis.lightSourceScore
        
        // Record frame if recording is enabled
        if isRecording, recordedFrames.count < maxRecordingFrames {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
               let frame = compressFrame(pixelBuffer, timestamp: analysis.timestamp) {
                recordedFrames.append(frame)
            }
        }
        
        // Calibration phase: collect baseline samples
        if isCalibrating {
            calibrationFrameCount += 1
            baselineSamples.append(score)
            
            if calibrationFrameCount >= calibrationFramesNeeded {
                // Calculate baseline as median of samples (robust to outliers)
                let sorted = baselineSamples.sorted()
                baselineLevel = sorted[sorted.count / 2]
                
                DispatchQueue.main.async {
                    self.isCalibrating = false
                }
                lockExposureSettings()
            }
        }
        
        // Apply minimal smoothing for fast response at high speeds
        // At 60fps, each frame is ~16ms, so we need very fast response
        let smoothedScore: Double
        if signalHistory.isEmpty {
            smoothedScore = score
        } else {
            let lastValue = signalHistory.last ?? score
            // Very fast attack (0.85), faster decay (0.6) for high-speed morse
            let alpha = score > lastValue ? 0.85 : 0.6
            smoothedScore = lastValue * (1 - alpha) + score * alpha
        }
        
        // Update history
        signalHistory.append(smoothedScore)
        if signalHistory.count > signalHistorySize {
            signalHistory.removeFirst()
        }
        
        // Normalize signal relative to baseline
        let normalizedSignal: Double
        if baselineLevel > 0.01 {
            // Signal strength relative to baseline
            normalizedSignal = max(0, (smoothedScore - baselineLevel * 0.8) / (1.0 - baselineLevel * 0.8))
        } else {
            normalizedSignal = smoothedScore
        }
        
        updateSignalQuality(normalizedSignal)
        
        DispatchQueue.main.async { [weak self] in
            self?.currentBrightness = normalizedSignal
            self?.lastAnalysis = analysis
        }
        
        // Call update with high-precision timestamp on main actor for UI-safe updates
        Task { @MainActor [weak self] in
            self?.onBrightnessUpdate?(normalizedSignal, analysis.timestamp)
        }
        
        lastFrameTime = analysis.timestamp
    }
}
