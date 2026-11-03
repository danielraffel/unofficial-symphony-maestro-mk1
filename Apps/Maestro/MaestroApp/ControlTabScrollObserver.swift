import AppKit
import SwiftUI

/// Reports the horizontal origin of the enclosing native scroll view.
/// The control tabs are backed by an NSScrollView whose clip view reports both
/// trackpad movement and AppKit accessibility scroll actions. Keeping this as
/// the sole persistence path avoids duplicate SwiftUI/AppKit writes per frame.
struct ControlTabScrollObserver: NSViewRepresentable {
    let tab: String
    let onOffsetChange: (CGFloat) -> Void
    let onDetachOffset: ((CGFloat) -> Void)?
    let restorationOffset: CGFloat

    init(
        tab: String,
        restorationOffset: CGFloat,
        onOffsetChange: @escaping (CGFloat) -> Void,
        onDetachOffset: ((CGFloat) -> Void)? = nil
    ) {
        self.tab = tab
        self.onOffsetChange = onOffsetChange
        self.onDetachOffset = onDetachOffset
        self.restorationOffset = restorationOffset
    }

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(
            tab: tab,
            onOffsetChange: onOffsetChange,
            onDetachOffset: onDetachOffset,
            restorationOffset: restorationOffset
        )
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onOffsetChange = onOffsetChange
        nsView.onDetachOffset = onDetachOffset
        nsView.restorationOffset = restorationOffset
        nsView.tab = tab
        nsView.attachIfNeeded()
    }

    final class ObserverView: NSView {
        var tab: String
        var onOffsetChange: (CGFloat) -> Void
        var onDetachOffset: ((CGFloat) -> Void)?
        var restorationOffset: CGFloat
        private var boundsObserver: NSObjectProtocol?
        private var liveScrollObserver: NSObjectProtocol?
        private var documentFrameObserver: NSObjectProtocol?
        private var restorationApplied = false
        private weak var observedClipView: NSClipView?
        private var attachAttempts = 0
        private var restorationCancelled = false
        private var pendingOffset: CGFloat?
        private var offsetWriteScheduled = false

        init(
            tab: String,
            onOffsetChange: @escaping (CGFloat) -> Void,
            onDetachOffset: ((CGFloat) -> Void)?,
            restorationOffset: CGFloat
        ) {
            self.tab = tab
            self.onOffsetChange = onOffsetChange
            self.onDetachOffset = onDetachOffset
            self.restorationOffset = restorationOffset
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard boundsObserver == nil, window != nil else { return }
            // SwiftUI may put a background representable behind an intermediate
            // hosting view, so the enclosing scroll view is not always a direct
            // ancestor during the first layout pass. Prefer AppKit's enclosing
            // lookup, then retain the old ancestor walk as a fallback.
            let scrollView = enclosingScrollView ?? enclosingScrollViewByWalkingAncestors()
            guard let scrollView else {
                scheduleRetry()
                return
            }

            let clipView = scrollView.contentView
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            restorationCancelled = false
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restorationCancelled = true
                }
            }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak clipView] _ in
                guard let self, let clipView else { return }
                let offset = clipView.bounds.origin.x
                ScrollPerformanceInstrumentation.record(tab: self.tab, offset: offset)
                self.scheduleOffsetWrite(offset)
            }
            // Apply the saved offset the moment the document gets its width —
            // synchronously, inside the layout pass that sizes it — so the first
            // frame painted with content is already at the saved position.
            // Measured 2026-10-21: the delayed passes below found no document
            // width for >50 ms after attach, so the strips painted at 0 and then
            // jumped (0 → 2197 pt at +205 ms), which read as a slide during
            // the tab cross-fade.
            restorationApplied = false
            if let documentView = scrollView.documentView {
                documentView.postsFrameChangedNotifications = true
                documentFrameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: nil   // deliver synchronously on the posting (main) thread
                ) { [weak self, weak scrollView] _ in
                    guard let self, let scrollView else { return }
                    self.applyRestorationNow(on: scrollView)
                }
            }
            applyRestorationNow(on: scrollView)
            restoreOffset(on: scrollView)
            let offset = clipView.bounds.origin.x
            ScrollPerformanceInstrumentation.record(tab: tab, offset: offset)
            scheduleOffsetWrite(offset)
        }

        /// Bounds notifications can arrive more than once during one display
        /// frame. Keep scrolling entirely in AppKit, but coalesce persistence
        /// callbacks so SwiftUI state and the session dictionary are written at
        /// most once per main-loop turn.
        private func scheduleOffsetWrite(_ offset: CGFloat) {
            pendingOffset = offset
            guard !offsetWriteScheduled else { return }
            offsetWriteScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.offsetWriteScheduled = false
                guard let pendingOffset = self.pendingOffset else { return }
                self.pendingOffset = nil
                self.onOffsetChange(pendingOffset)
            }
        }

        /// SwiftUI may recreate the scroll view with a zero-width document and
        /// clamp ScrollPosition before the asynchronous channel layout arrives.
        /// Restore against the native clip view after each layout pass instead.
        private func restoreOffset(on scrollView: NSScrollView) {
            guard restorationOffset > 0, !restorationCancelled else { return }
            let delays: [UInt64] = [0, 50_000_000, 150_000_000, 300_000_000, 600_000_000]
            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    self.applyRestorationNow(on: scrollView)
                }
            }
        }

        /// Move the clip view to the saved offset (clamped to the document)
        /// the first time the document has a width, then stop listening to
        /// document frame changes.
        private func applyRestorationNow(on scrollView: NSScrollView) {
            guard restorationOffset > 0, !restorationCancelled, !restorationApplied else { return }
            let clipView = scrollView.contentView
            let documentWidth = scrollView.documentView?.bounds.width ?? 0
            guard documentWidth > 0 else { return }
            let maxOffset = max(0, documentWidth - clipView.bounds.width)
            let x = min(max(0, restorationOffset), maxOffset)
            if abs(clipView.bounds.origin.x - x) > 0.5 {
                var bounds = clipView.bounds
                bounds.origin.x = x
                clipView.setBoundsOrigin(bounds.origin)
                scrollView.reflectScrolledClipView(clipView)
            }
            // One synchronous application is the point: the first frame with
            // content is painted at the saved (or best reachable) position.
            // Detach now even when the target was clamped — the delayed
            // passes still refine toward the exact target as before, and a
            // later resize/relayout can never yank the user back here.
            restorationApplied = true
            if let documentFrameObserver {
                NotificationCenter.default.removeObserver(documentFrameObserver)
                self.documentFrameObserver = nil
            }
        }

        private func enclosingScrollViewByWalkingAncestors() -> NSScrollView? {
            var ancestor: NSView? = superview
            while let view = ancestor {
                if let scrollView = view as? NSScrollView { return scrollView }
                ancestor = view.superview
            }
            return nil
        }

        private func scheduleRetry() {

            guard attachAttempts < 20 else { return }
            attachAttempts += 1
            DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
        }

        override func removeFromSuperview() {
            // A tab switch can remove this representable before the coalesced
            // main-queue write runs. Commit the native position synchronously
            // so rapid Input → Output → Mixer navigation cannot lose the last
            // position for the tab being left.
            if let onDetachOffset {
                let offset = observedClipView?.bounds.origin.x
                    ?? pendingOffset
                    ?? 0
                onDetachOffset(offset)
            }
            pendingOffset = nil
            offsetWriteScheduled = false
            observedClipView = nil
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
                self.liveScrollObserver = nil
            }
            if let documentFrameObserver {
                NotificationCenter.default.removeObserver(documentFrameObserver)
                self.documentFrameObserver = nil
            }
            super.removeFromSuperview()
        }

    }
}
