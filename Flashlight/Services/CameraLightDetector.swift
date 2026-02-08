import AVFoundation
import SwiftUI
import CoreImage

/// Detects light/flash patterns from the camera feed for morse code decoding
class CameraLightDetector: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var currentBrightness: Double = 0.0
    @Published var previewLayer: AVCaptureVideoPreviewLayer?

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let processingQueue = DispatchQueue(label: "com.flashlight.camera", qos: .userInteractive)

    /// Region of interest for light detection (center portion of frame)
    var roiSize: CGFloat = 0.3

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

    /// Calculate average brightness of the center region of a pixel buffer
    private func calculateBrightness(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return 0 }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Calculate ROI (center region)
        let roiWidth = Int(Double(width) * Double(roiSize))
        let roiHeight = Int(Double(height) * Double(roiSize))
        let startX = (width - roiWidth) / 2
        let startY = (height - roiHeight) / 2

        var totalBrightness: Double = 0
        var pixelCount: Double = 0

        // Sample every 4th pixel for performance
        let step = 4
        for y in stride(from: startY, to: startY + roiHeight, by: step) {
            for x in stride(from: startX, to: startX + roiWidth, by: step) {
                let offset = y * bytesPerRow + x * 4
                let b = Double(buffer[offset])
                let g = Double(buffer[offset + 1])
                let r = Double(buffer[offset + 2])
                // Perceived luminance formula
                let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                totalBrightness += luminance
                pixelCount += 1
            }
        }

        return pixelCount > 0 ? totalBrightness / pixelCount : 0
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraLightDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let brightness = calculateBrightness(from: sampleBuffer)

        DispatchQueue.main.async { [weak self] in
            self?.currentBrightness = brightness
            self?.onBrightnessUpdate?(brightness)
        }
    }
}
