import AVFoundation
import UIKit

/// Thin wrapper around `AVCaptureSession` configured for the front camera.
/// All session mutation happens on a private serial queue.
final class CameraSession {

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.selfieoverlaykit.session", qos: .userInitiated)
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false

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
}
