import AVFoundation

/// Thin wrapper around `AVCaptureSession` configured for the front camera.
/// All session mutation happens on a private serial queue.
///
/// Fans front-camera sample buffers out to any number of listeners. The preview
/// view consumes buffers for on-screen rendering; during recording, the camera
/// video recorder also subscribes so the feed can be composited into the final
/// export in post-processing (the overlay window is not reliably picked up by
/// `RPScreenRecorder`'s in-app capture, so we don't rely on it).
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    private let sessionQueue = DispatchQueue(label: "com.selfieoverlaykit.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.selfieoverlaykit.videoOutput", qos: .userInitiated)
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false

    private let listenersLock = NSLock()
    private var listeners: [ObjectIdentifier: (CMSampleBuffer) -> Void] = [:]

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configure()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Register a handler that receives each camera sample buffer on the session's
    /// output queue. `owner` is used as an identity key so the same instance can
    /// register/unregister idempotently.
    func addSampleBufferListener(_ owner: AnyObject,
                                 _ handler: @escaping (CMSampleBuffer) -> Void) {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        listeners[ObjectIdentifier(owner)] = handler
    }

    func removeSampleBufferListener(_ owner: AnyObject) {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        listeners.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = frontCamera(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)
        currentInput = input

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // Mirroring is handled at the view layer from SettingsStore so users can toggle it.
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }

        isConfigured = true
    }

    private func frontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .front
        )
        return discovery.devices.first
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        listenersLock.lock()
        let handlers = Array(listeners.values)
        listenersLock.unlock()
        for handler in handlers {
            handler(sampleBuffer)
        }
    }
}
