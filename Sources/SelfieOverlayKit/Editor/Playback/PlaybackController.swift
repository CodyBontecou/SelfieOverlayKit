import AVFoundation
import Combine
import CoreMedia
import Foundation
import QuartzCore
import UIKit

/// Owns the single `AVPlayer` backing the editor's preview surface, rebuilds
/// its `AVPlayerItem` from the current `EditStore.timeline` whenever the edit
/// state changes, and publishes playhead time so UI consumers (preview,
/// timeline playhead) can follow along.
///
/// Rebuilds are debounced by 50ms: dragging a trim handle mutates the
/// timeline many times per second, but we only want one composition rebuild
/// after the user stops dragging.
public final class PlaybackController {

    // MARK: - Inputs

    private let editStore: EditStore
    private let project: EditorProject
    private let bubbleTimeline: BubbleTimeline?
    private let screenScale: CGFloat

    // MARK: - Outputs

    public let player: AVPlayer

    @Published public private(set) var isPlaying: Bool = false

    public var currentTime: AnyPublisher<CMTime, Never> {
        currentTimeSubject.eraseToAnyPublisher()
    }

    /// Increments whenever the player item is rebuilt. Exposed primarily for
    /// tests that want to verify debounce behavior without peering at the
    /// internal work-item scheduling.
    @Published public private(set) var rebuildCount: Int = 0

    // MARK: - Private

    private let currentTimeSubject = PassthroughSubject<CMTime, Never>()
    private var cancellables: Set<AnyCancellable> = []
    private var rebuildWorkItem: DispatchWorkItem?
    private let rebuildDebounce: TimeInterval
    private var displayLink: CADisplayLink?

    // MARK: - Init

    init(editStore: EditStore,
         project: EditorProject,
         bubbleTimeline: BubbleTimeline? = nil,
         screenScale: CGFloat? = nil,
         rebuildDebounce: TimeInterval = 0.05) {
        self.editStore = editStore
        self.project = project
        self.bubbleTimeline = bubbleTimeline
        self.screenScale = screenScale ?? Self.mainScreenScale()
        self.rebuildDebounce = rebuildDebounce
        self.player = AVPlayer()

        rebuildPlayerItem(preservingTime: .zero)

        editStore.$timeline
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
    }

    deinit {
        stopDisplayLink()
        rebuildWorkItem?.cancel()
    }

    // MARK: - Public API

    public func play() {
        player.play()
        isPlaying = true
        startDisplayLink()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        stopDisplayLink()
        currentTimeSubject.send(player.currentTime())
    }

    public func seek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.currentTimeSubject.send(time)
        }
    }

    /// Force an immediate rebuild, skipping the debounce window. Useful from
    /// tests and from the initial load path.
    public func rebuildNow() {
        rebuildWorkItem?.cancel()
        rebuildWorkItem = nil
        rebuildPlayerItem(preservingTime: player.currentTime())
    }

    // MARK: - Rebuild pipeline

    private func scheduleRebuild() {
        rebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildPlayerItem(preservingTime: self.player.currentTime())
        }
        rebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rebuildDebounce, execute: work)
    }

    private func rebuildPlayerItem(preservingTime targetTime: CMTime) {
        let output: CompositionBuilder.Output
        do {
            output = try CompositionBuilder.build(
                timeline: editStore.timeline,
                project: project,
                bubbleTimeline: bubbleTimeline,
                screenScale: screenScale)
        } catch {
            DebugLog.log("Playback", "composition build failed — \(error.localizedDescription)")
            return
        }
        let item = AVPlayerItem(asset: output.composition)
        item.videoComposition = output.videoComposition
        item.audioMix = output.audioMix
        player.replaceCurrentItem(with: item)

        // Clamp preserved time to the new duration. Using the composition's
        // duration keeps us in sync with actually-inserted segments even if
        // the timeline's declared duration lags behind a mutation.
        let clampedTarget = targetTime.isValid
            ? min(targetTime, output.composition.duration)
            : .zero
        if clampedTarget > .zero {
            player.seek(to: clampedTarget,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
        }

        rebuildCount += 1
    }

    // MARK: - Playhead ticking

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: DisplayLinkProxy(controller: self),
                                 selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick() {
        currentTimeSubject.send(player.currentTime())
    }

    // MARK: - Helpers

    private static func mainScreenScale() -> CGFloat {
        if Thread.isMainThread {
            return UIScreen.main.scale
        }
        var scale: CGFloat = 1
        DispatchQueue.main.sync {
            scale = UIScreen.main.scale
        }
        return scale
    }
}

/// `CADisplayLink` retains its target. Proxying through a separate class with
/// a weak reference to the controller lets the controller deallocate cleanly
/// when the host view disappears.
private final class DisplayLinkProxy {
    weak var controller: PlaybackController?
    init(controller: PlaybackController) {
        self.controller = controller
    }
    @objc func tick() {
        controller?.tick()
    }
}
