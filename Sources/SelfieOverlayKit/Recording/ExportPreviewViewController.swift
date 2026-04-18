import AVKit
import Photos
import UIKit

/// Preview sheet shown after a post-processed recording is ready. Replaces
/// `RPPreviewViewController`, which can only preview files produced by
/// `RPScreenRecorder.stopRecording` — not our exported file.
final class ExportPreviewViewController: UIViewController {

    private let videoURL: URL
    private let playerVC = AVPlayerViewController()

    /// Called after the preview is dismissed. Gives the caller a chance to
    /// clean up the temp file.
    var onDismiss: ((URL) -> Void)?

    init(videoURL: URL) {
        self.videoURL = videoURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        let navItem = UINavigationItem(title: "Recording")
        navItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(didTapCancel))
        let saveItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(didTapSave))
        let shareItem = UIBarButtonItem(
            barButtonSystemItem: .action, target: self, action: #selector(didTapShare))
        navItem.rightBarButtonItems = [saveItem, shareItem]
        navBar.setItems([navItem], animated: false)
        view.addSubview(navBar)

        playerVC.player = AVPlayer(url: videoURL)
        playerVC.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)

        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerVC.view.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            playerVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playerVC.player?.play()
    }

    @objc private func didTapCancel() {
        let alert = UIAlertController(
            title: "Discard Recording?",
            message: "This recording will be deleted and cannot be recovered.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.dismissAndCleanup()
        })
        present(alert, animated: true)
    }

    @objc private func didTapSave() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized, .limited:
                    self.performSave()
                default:
                    self.presentAlert(
                        title: "Photos Access Denied",
                        message: "Enable Photos access in Settings to save recordings.")
                }
            }
        }
    }

    @objc private func didTapShare() {
        let activity = UIActivityViewController(
            activityItems: [videoURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
        present(activity, animated: true)
    }

    // MARK: - Helpers

    private func performSave() {
        let url = videoURL
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.dismissAndCleanup()
                } else {
                    self.presentAlert(
                        title: "Save Failed",
                        message: error?.localizedDescription ?? "Unknown error.")
                }
            }
        }
    }

    private func dismissAndCleanup() {
        playerVC.player?.pause()
        let url = videoURL
        dismiss(animated: true) { [onDismiss] in onDismiss?(url) }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Modal HUD shown while post-processing is running. `setStatus` can be called
/// from any thread to update the caption — the compositor uses this to surface
/// frame-by-frame progress so a stall is visible instead of silent.
final class ProcessingHUDViewController: UIViewController {

    private let statusLabel = UILabel()
    // Buffered status text for callers that set it before viewDidLoad runs.
    private var pendingStatus = "Processing…"

    init() {
        super.init(nibName: nil, bundle: nil)
        // Set before the presenting VC calls present(...), or UIKit falls back to
        // the default sheet presentation and our dark backdrop never takes effect.
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.85)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()

        statusLabel.text = pendingStatus
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    func setStatus(_ text: String) {
        let apply = { [weak self] in
            guard let self else { return }
            self.pendingStatus = text
            if self.isViewLoaded {
                self.statusLabel.text = text
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}
