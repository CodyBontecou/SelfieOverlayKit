import AVFoundation
import AVKit
import Combine
import CoreMedia
import Photos
import UIKit

/// The editor shell. Shows a composed preview of the recorded project plus
/// Save / Share / Discard. Timeline UI, trim/split/speed/volume controls, and
/// the progress-aware export pipeline land in later tickets (T8–T14);
/// this view controller is only the user-visible milestone that swaps the
/// old `ExportPreviewViewController` out.
public final class EditorViewController: UIViewController {

    // MARK: - Inputs

    let project: EditorProject
    private let projectStore: ProjectStore
    private let bubbleTimeline: BubbleTimeline?
    private let editStore: EditStore
    let playback: PlaybackController

    /// Fired when the editor is about to dismiss because the user hit
    /// Discard. Host code uses this to clean up any presenting state
    /// (e.g. unhide the overlay bubble window).
    var onDismiss: (() -> Void)?

    // MARK: - Views

    let previewCanvas = PreviewCanvasView()
    let playPauseButton = UIButton(type: .system)
    let timeLabel = UILabel()
    let toolbarRow = UIStackView()
    let splitButton = UIButton(type: .system)
    let timelineView = TimelineView()
    let inspector = ClipInspectorView()

    // MARK: - State

    private var cancellables: Set<AnyCancellable> = []
    private var timeObserver: Any?

    // MARK: - Init

    convenience init(project: EditorProject) throws {
        let store = try ProjectStore()
        try self.init(project: project, projectStore: store)
    }

    init(project: EditorProject, projectStore: ProjectStore) throws {
        self.project = project
        self.projectStore = projectStore
        self.bubbleTimeline = try? projectStore.loadBubbleTimeline(for: project)

        let screenAsset = AVURLAsset(url: project.screenURL)
        let cameraAsset = AVURLAsset(url: project.cameraURL)
        let timeline = Timeline.fromAssets(screenAsset: screenAsset, cameraAsset: cameraAsset)
        self.editStore = EditStore(timeline: timeline)
        self.playback = PlaybackController(
            editStore: editStore,
            project: project,
            bubbleTimeline: bubbleTimeline)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupNavBar()
        setupLayout()
        previewCanvas.player = playback.player
        bindTimeLabel()
        bindTimeline()
    }

    private func bindTimeline() {
        editStore.$timeline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timeline in
                self?.timelineView.update(timeline: timeline)
            }
            .store(in: &cancellables)

        playback.currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.timelineView.setPlayhead(time)
                self?.updateSplitButtonEnabled()
            }
            .store(in: &cancellables)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playback.play()
        updatePlayPauseButton()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playback.pause()
    }

    // MARK: - Layout

    private func setupNavBar() {
        title = "Recording"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Discard", style: .plain, target: self, action: #selector(didTapDiscard))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(didTapSave)),
            UIBarButtonItem(
                barButtonSystemItem: .action, target: self, action: #selector(didTapShare))
        ]
    }

    private func setupLayout() {
        previewCanvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewCanvas)

        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        timeLabel.text = "00:00 / 00:00"
        timeLabel.textAlignment = .center
        timeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let transportRow = UIStackView(arrangedSubviews: [playPauseButton, timeLabel])
        transportRow.axis = .horizontal
        transportRow.spacing = 16
        transportRow.alignment = .center
        transportRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transportRow)

        toolbarRow.axis = .horizontal
        toolbarRow.spacing = 12
        toolbarRow.distribution = .equalSpacing
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbarRow)

        splitButton.setImage(UIImage(systemName: "scissors"), for: .normal)
        splitButton.accessibilityLabel = "Split at playhead"
        splitButton.accessibilityIdentifier = "editor.split"
        splitButton.addTarget(self, action: #selector(didTapSplit), for: .touchUpInside)
        splitButton.isEnabled = false
        toolbarRow.addArrangedSubview(splitButton)

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.layer.cornerRadius = 8
        timelineView.clipsToBounds = true
        timelineView.update(timeline: editStore.timeline)
        timelineView.onSeek = { [weak self] time in
            self?.playback.seek(to: time)
        }
        timelineView.onClipSelected = { [weak self] id in
            self?.updateSplitButtonEnabled()
            self?.updateInspector(for: id)
        }
        timelineView.onClipEdgeDrag = { [weak self] clipID, event in
            self?.handleEdgeDrag(clipID: clipID, event: event)
        }
        view.addSubview(timelineView)

        inspector.isHidden = true
        inspector.onSpeedCommit = { [weak self] speed in
            self?.commitSpeed(speed)
        }
        inspector.onVolumeCommit = { [weak self] volume in
            self?.commitVolume(volume)
        }
        view.addSubview(inspector)

        NSLayoutConstraint.activate([
            previewCanvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            previewCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewCanvas.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.55),

            transportRow.topAnchor.constraint(equalTo: previewCanvas.bottomAnchor, constant: 12),
            transportRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            transportRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            toolbarRow.topAnchor.constraint(equalTo: transportRow.bottomAnchor, constant: 12),
            toolbarRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toolbarRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            toolbarRow.heightAnchor.constraint(equalToConstant: 36),

            timelineView.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor, constant: 12),
            timelineView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            timelineView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            timelineView.bottomAnchor.constraint(equalTo: inspector.topAnchor, constant: -12),

            inspector.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            inspector.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            inspector.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func bindTimeLabel() {
        let total = editStore.timeline.duration
        let totalString = Self.formatTime(total)
        timeLabel.text = "00:00 / \(totalString)"

        // AVPlayer periodic time observer gives us updates the PlaybackController
        // layers a CADisplayLink over; either keeps the label ticking while
        // playing, and reacts on seek when paused.
        timeObserver = playback.player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.timeLabel.text = "\(Self.formatTime(time)) / \(totalString)"
        }

        playback.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePlayPauseButton() }
            .store(in: &cancellables)
    }

    private func updatePlayPauseButton() {
        let name = playback.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: name), for: .normal)
    }

    private static func formatTime(_ t: CMTime) -> String {
        let seconds = max(0, Int(t.seconds.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Actions

    // MARK: - Inspector binding

    func updateInspector(for clipID: UUID?) {
        guard let clipID,
              let loc = editStore.timeline.locate(clipID: clipID) else {
            inspector.isHidden = true
            return
        }
        let track = editStore.timeline.tracks[loc.trackIndex]
        let clip = track.clips[loc.clipIndex]
        inspector.configure(with: clip, trackKind: track.kind)
        inspector.isHidden = false
    }

    // MARK: - Trim drag

    /// Snapshot captured on `.began` so drag updates can compute frames off a
    /// stable baseline. `1 / 30s` is the minimum clip duration per ticket AC.
    private var activeDrag: TrimDragState?

    private struct TrimDragState {
        let clipID: UUID
        let edge: ClipView.Edge
        let initialFrame: CGRect
        let originalSourceRange: CMTimeRange
        let originalTimelineRange: CMTimeRange
        let pixelsPerSecond: CGFloat
        let neighborEdges: [CMTime]
    }

    private static let minClipSeconds: Double = 1.0 / 30.0

    func handleEdgeDrag(clipID: UUID, event: ClipView.EdgeDragEvent) {
        switch event.state {
        case .began:
            beginEdgeDrag(clipID: clipID, edge: event.edge)
        case .changed:
            updateEdgeDrag(translation: event.translationPoints)
        case .ended, .cancelled, .failed:
            commitEdgeDrag(translation: event.translationPoints)
        default:
            break
        }
    }

    private func beginEdgeDrag(clipID: UUID, edge: ClipView.Edge) {
        guard let loc = editStore.timeline.locate(clipID: clipID) else { return }
        let track = editStore.timeline.tracks[loc.trackIndex]
        let clip = track.clips[loc.clipIndex]

        // Neighbor edges to snap against: current playhead + every edge of
        // every other clip on the same track.
        var neighbors: [CMTime] = [playback.player.currentTime()]
        for other in track.clips where other.id != clip.id {
            neighbors.append(other.timelineRange.start)
            neighbors.append(other.timelineRange.end)
        }

        guard let row = timelineView.trackRowView(track.id),
              let clipView = row.clipView(for: clipID) else { return }

        clipView.isDraggingEdge = true
        activeDrag = TrimDragState(
            clipID: clipID,
            edge: edge,
            initialFrame: clipView.frame,
            originalSourceRange: clip.sourceRange,
            originalTimelineRange: clip.timelineRange,
            pixelsPerSecond: timelineView.pixelsPerSecond,
            neighborEdges: neighbors)
    }

    private func updateEdgeDrag(translation: CGFloat) {
        guard let drag = activeDrag,
              let loc = editStore.timeline.locate(clipID: drag.clipID),
              let row = timelineView.trackRowView(editStore.timeline.tracks[loc.trackIndex].id),
              let clipView = row.clipView(for: drag.clipID) else { return }

        let minWidth = CGFloat(Self.minClipSeconds) * drag.pixelsPerSecond
        switch drag.edge {
        case .leading:
            var newX = drag.initialFrame.origin.x + translation
            // Clamp so the clip retains minimum width.
            let maxX = drag.initialFrame.maxX - minWidth
            newX = min(newX, maxX)
            newX = max(newX, 0)
            newX = snappedX(newX, drag: drag)
            let newWidth = drag.initialFrame.maxX - newX
            clipView.frame = CGRect(
                x: newX, y: drag.initialFrame.origin.y,
                width: newWidth, height: drag.initialFrame.height)
        case .trailing:
            var newMaxX = drag.initialFrame.maxX + translation
            let minAllowed = drag.initialFrame.minX + minWidth
            newMaxX = max(newMaxX, minAllowed)
            newMaxX = snappedX(newMaxX, drag: drag)
            let newWidth = newMaxX - drag.initialFrame.minX
            clipView.frame = CGRect(
                x: drag.initialFrame.minX, y: drag.initialFrame.origin.y,
                width: newWidth, height: drag.initialFrame.height)
        }
    }

    private func snappedX(_ x: CGFloat, drag: TrimDragState) -> CGFloat {
        let pps = drag.pixelsPerSecond
        let threshold = SnapEngine.thresholdSeconds(forPoints: 8, pixelsPerSecond: pps)
        let candidate = CMTime(seconds: Double(x) / Double(pps), preferredTimescale: 600)
        let snapped = SnapEngine.snap(
            candidate: candidate,
            neighbors: drag.neighborEdges,
            thresholdSeconds: threshold)
        return CGFloat(snapped.seconds) * pps
    }

    private func commitEdgeDrag(translation: CGFloat) {
        guard let drag = activeDrag else { return }
        defer { activeDrag = nil }

        guard let loc = editStore.timeline.locate(clipID: drag.clipID),
              let row = timelineView.trackRowView(editStore.timeline.tracks[loc.trackIndex].id),
              let clipView = row.clipView(for: drag.clipID) else { return }

        clipView.isDraggingEdge = false

        // Convert the final frame back to a new sourceRange.
        let pps = drag.pixelsPerSecond
        let finalFrame = clipView.frame
        let newTimelineStart = Double(finalFrame.origin.x) / Double(pps)
        let newTimelineEnd = Double(finalFrame.maxX) / Double(pps)
        let newTimelineDuration = newTimelineEnd - newTimelineStart

        // Back-solve the source range. Timeline duration = source duration / speed;
        // for the edge being trimmed, the source edge slides by the timeline delta * speed.
        let clip = editStore.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let speed = clip.speed
        let sourceDuration = newTimelineDuration * speed
        let newSourceRange: CMTimeRange
        switch drag.edge {
        case .leading:
            let sourceStart = drag.originalSourceRange.end.seconds - sourceDuration
            newSourceRange = CMTimeRange(
                start: CMTime(seconds: max(0, sourceStart), preferredTimescale: 600),
                duration: CMTime(seconds: sourceDuration, preferredTimescale: 600))
        case .trailing:
            newSourceRange = CMTimeRange(
                start: drag.originalSourceRange.start,
                duration: CMTime(seconds: sourceDuration, preferredTimescale: 600))
        }

        editStore.apply(name: "Trim") {
            $0.trimming(clipID: drag.clipID, edge: drag.edge == .leading ? .start : .end,
                        newSourceRange: newSourceRange)
        }
    }

    private func commitSpeed(_ speed: Double) {
        guard let clipID = timelineView.selectedClipID else { return }
        editStore.apply(name: "Speed") { $0.settingPairedSpeed(clipID: clipID, speed) }
    }

    private func commitVolume(_ volume: Float) {
        guard let clipID = timelineView.selectedClipID else { return }
        editStore.apply(name: "Volume") { $0.settingVolume(clipID: clipID, volume) }
    }

    @objc func didTapSplit() {
        guard let clipID = timelineView.selectedClipID,
              let loc = editStore.timeline.locate(clipID: clipID) else { return }
        let track = editStore.timeline.tracks[loc.trackIndex]
        let playhead = playback.player.currentTime()
        editStore.apply(name: "Split") { $0.splitting(at: playhead, trackID: track.id) }
    }

    private func updateSplitButtonEnabled() {
        let canSplit: Bool
        if let clipID = timelineView.selectedClipID,
           let loc = editStore.timeline.locate(clipID: clipID) {
            let clip = editStore.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            let playhead = playback.player.currentTime()
            canSplit = playhead > clip.timelineRange.start && playhead < clip.timelineRange.end
        } else {
            canSplit = false
        }
        splitButton.isEnabled = canSplit
    }

    @objc private func didTapPlayPause() {
        if playback.isPlaying {
            playback.pause()
        } else {
            playback.play()
        }
        updatePlayPauseButton()
    }

    @objc private func didTapDiscard() {
        let alert = UIAlertController(
            title: "Discard Recording?",
            message: "This recording will be deleted and cannot be recovered.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.performDiscard()
        })
        present(alert, animated: true)
    }

    @objc func didTapSave() {
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

    @objc func didTapShare() {
        // Minimal export path; T14 replaces with a progress-aware pipeline.
        exportToTempFile { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.presentAlert(title: "Share Failed",
                                      message: error.localizedDescription)
                case .success(let url):
                    let activity = UIActivityViewController(
                        activityItems: [url], applicationActivities: nil)
                    activity.popoverPresentationController?.sourceView = self.view
                    self.present(activity, animated: true)
                }
            }
        }
    }

    // MARK: - Save / discard / export

    func performDiscard() {
        playback.pause()
        try? projectStore.delete(project)
        dismiss(animated: true) { [onDismiss] in onDismiss?() }
    }

    private func performSave() {
        exportToTempFile { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.presentAlert(
                        title: "Save Failed", message: error.localizedDescription)
                case .success(let url):
                    PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.creationRequestForAssetFromVideo(
                            atFileURL: url)
                    } completionHandler: { [weak self] ok, err in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            try? FileManager.default.removeItem(at: url)
                            if ok {
                                self.presentAlert(title: "Saved", message: "Saved to Photos.")
                            } else {
                                self.presentAlert(
                                    title: "Save Failed",
                                    message: err?.localizedDescription ?? "Unknown error.")
                            }
                        }
                    }
                }
            }
        }
    }

    func exportToTempFile(completion: @escaping (Result<URL, Error>) -> Void) {
        let output = CompositionBuilder.build(
            timeline: editStore.timeline,
            project: project,
            bubbleTimeline: bubbleTimeline)
        guard let session = AVAssetExportSession(
            asset: output.composition,
            presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(ExportError.unsupportedExportPreset))
            return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selfieoverlay-editor-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = output.videoComposition
        session.audioMix = output.audioMix
        session.exportAsynchronously {
            switch session.status {
            case .completed:
                completion(.success(url))
            case .failed, .cancelled:
                completion(.failure(session.error ?? ExportError.unknown))
            default:
                completion(.failure(ExportError.unknown))
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(
            title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    deinit {
        if let timeObserver {
            playback.player.removeTimeObserver(timeObserver)
        }
    }

    enum ExportError: Error {
        case unsupportedExportPreset
        case unknown
    }
}
