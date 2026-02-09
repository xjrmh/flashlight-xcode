import AVFoundation
import SwiftUI
import CoreImage

/// Light source analysis result
struct LightAnalysis {
    let averageBrightness: Double  // 0-1 average luminance
    let peakBrightness: Double     // 0-1 max luminance in ROI
    let saturationRatio: Double    // Ratio of near-white pixels (likely light source)
    let contrast: Double           // Difference between brightest and average
    
    /// Combined score that favors actual light sources over reflective surfaces
    var lightSourceScore: Double {
        // A true light source has:
        // - High peak brightness (saturated/blown out pixels)
        // - High saturation ratio (many very bright pixels)
        // - High contrast (bright center, darker edges)
        
        let peakWeight = 0.3
        let saturationWeight = 0.4
        let contrastWeight = 0.3
        
        return (peakBrightness * peakWeight) +
               (saturationRatio * saturationWeight) +
               (contrast * contrastWeight)
    }
}

/// Detects light/flash patterns from the camera feed for morse code decoding
class CameraLightDetector: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var currentBrightness: Double = 0.0
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var lastAnalysis: LightAnalysis?

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let processingQueue = DispatchQueue(label: "com.flashlight.camera", qos: .userInteractive)

    /// Region of interest for light detection (center portion of frame)
    var roiSize: CGFloat = 0.3
    
    /// Threshold for considering a pixel "saturated" (likely from a light source)
    private let saturationThreshold: Double = 0.85

    var onBrightnessUpdate: ((Double) -> Void)?

    override init() {
        super.init()
    }

    func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("No back camera available")
            return
        }

        do {
            // Configure camera for light detection
            try camera.lockForConfiguration()
            // Disable auto-exposure to get consistent readings
            if camera.isExposureModeSupported(.locked) {
                camera.exposureMode = .locked
            }
            // Disable auto white balance
            if camera.isWhiteBalanceModeSupported(.locked) {
                camera.whiteBalanceMode = .locked
            }
            camera.unlockForConfiguration()

            let input = try AVCaptureDeviceInput(device: camera)
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
            print("Camera setup error: \(error.localizedDescription)")
        }
    }

    func start() {
        guard let session = captureSession, !session.isRunning else { return }
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
            }
        }
    }

    /// Analyze the center region for light source characteristics
    private func analyzeForLightSource(from sampleBuffer: CMSampleBuffer) -> LightAnalysis {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return LightAnalysis(averageBrightness: 0, peakBrightness: 0, saturationRatio: 0, contrast: 0)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return LightAnalysis(averageBrightness: 0, peakBrightness: 0, saturationRatio: 0, contrast: 0)
        }
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Calculate ROI (center square region to match overlay)
        let roiSide = Int(Double(min(width, height)) * Double(roiSize))
        let roiWidth = roiSide
        let roiHeight = roiSide
        let startX = (width - roiWidth) / 2
        let startY = (height - roiHeight) / 2

        var totalBrightness: Double = 0
        var peakBrightness: Double = 0
        var saturatedPixels: Double = 0
        var pixelCount: Double = 0

        // Sample every 2nd pixel for better sensitivity
        let step = 2
        for y in stride(from: startY, to: startY + roiHeight, by: step) {
            for x in stride(from: startX, to: startX + roiWidth, by: step) {
                let offset = y * bytesPerRow + x * 4
                let b = Double(buffer[offset])
                let g = Double(buffer[offset + 1])
                let r = Double(buffer[offset + 2])
                
                // Perceived luminance formula
                let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                
                totalBrightness += luminance
                peakBrightness = max(peakBrightness, luminance)
                
                // Count saturated/near-white pixels (indicates actual light source)
                if luminance > saturationThreshold {
                    saturatedPixels += 1
                }
                
                pixelCount += 1
            }
        }

        guard pixelCount > 0 else {
            return LightAnalysis(averageBrightness: 0, peakBrightness: 0, saturationRatio: 0, contrast: 0)
        }
        
        let avgBrightness = totalBrightness / pixelCount
        let saturationRatio = saturatedPixels / pixelCount
        let contrast = peakBrightness - avgBrightness
        
        return LightAnalysis(
            averageBrightness: avgBrightness,
            peakBrightness: peakBrightness,
            saturationRatio: saturationRatio,
            contrast: contrast
        )
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
        
        // Use a combined signal strength that also considers overall brightness.
        let lightScore = analysis.lightSourceScore
        let contrastWeighted = analysis.peakBrightness * 0.6 + analysis.contrast * 0.4
        let signalStrength = max(lightScore, contrastWeighted, analysis.peakBrightness, analysis.averageBrightness)

        DispatchQueue.main.async { [weak self] in
            self?.currentBrightness = signalStrength
            self?.lastAnalysis = analysis
            self?.onBrightnessUpdate?(signalStrength)
        }
    }
}
