import Foundation

/// Thread-safe side channel that lets on-canvas gestures drive the bubble
/// compositor without going through `EditStore` on every drag tick.
///
/// Mutating `Timeline` per drag frame works, but it forces
/// `PlaybackController` to rebuild the `AVPlayerItem` (a ~50ms debounced hop)
/// and records a fresh undo step for every 60 fps frame — so a one-second
/// pinch lands 60 entries in the undo manager. Gestures instead write into
/// this store mid-drag and commit a single `EditStore.apply` on release; the
/// compositor consults the store each frame and prefers the override over the
/// instruction's baked transform when one is present for the clip.
///
/// Reference type so a single instance can be shared between the UI layer
/// (writer) and `BubbleVideoCompositor` (reader) without copying — the
/// compositor pulls it off each `BubbleCompositionInstruction` it processes.
public final class PreviewOverrideStore {

    private let lock = NSLock()
    private var overrides: [UUID: BubbleOverlayRenderer.LayerTransform] = [:]

    public init() {}

    /// Upsert an override for the given clip. Passing `nil` clears it.
    public func set(_ transform: BubbleOverlayRenderer.LayerTransform?,
                    forClip clipID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let transform {
            overrides[clipID] = transform
        } else {
            overrides.removeValue(forKey: clipID)
        }
    }

    public func transform(forClip clipID: UUID) -> BubbleOverlayRenderer.LayerTransform? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[clipID]
    }

    /// Drop every override at once. Used on gesture cancel / teardown paths
    /// where the committed timeline is already the source of truth again.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        overrides.removeAll()
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overrides.isEmpty
    }
}
