/// Property change listener protocol for observing device state changes.
///
/// When device properties change (from hardware, another app, or user action),
/// listeners are notified with the new value.
///
/// Evidence: CoreAudio API `AudioObjectAddPropertyListenerBlock`
/// Evidence: `og_source/maestrolink/Software/mAEstroUtilities.c` — property change notifications

import MaestroCore
import Foundation

// MARK: - Property Change

/// A notification that a device property has changed.
public struct PropertyChange: Sendable {
    /// The property that changed.
    public let address: PropertyAddress
    /// The new value (nil if the property was removed or is unavailable).
    public let value: PropertyValue?
    /// Timestamp of the change.
    public let timestamp: Date

    public init(address: PropertyAddress, value: PropertyValue?, timestamp: Date = Date()) {
        self.address = address
        self.value = value
        self.timestamp = timestamp
    }
}

// MARK: - Property Listener Protocol

/// Protocol for receiving property change notifications.
///
/// Implementations can filter, debounce, or transform property changes
/// before they reach the UI layer.
///
/// Evidence: `AudioObjectAddPropertyListenerBlock` (CoreAudio API)
/// — the real implementation will wrap CoreAudio listener blocks.
public protocol PropertyListener: AnyObject, Sendable {
    /// Called when a property changes on the device.
    func propertyDidChange(_ change: PropertyChange) async
}

// MARK: - Property Observer (AsyncStream-based)

/// Convenience class that bridges PropertyListener to an AsyncStream.
///
/// This allows SwiftUI views and other async consumers to observe
/// property changes using for-await-in loops.
public final class PropertyObserver: PropertyListener, @unchecked Sendable {
    private let continuation: AsyncStream<PropertyChange>.Continuation
    /// Stream of property changes. Consume with `for await change in stream`.
    public let stream: AsyncStream<PropertyChange>

    public init() {
        var cont: AsyncStream<PropertyChange>.Continuation!
        self.stream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    public func propertyDidChange(_ change: PropertyChange) async {
        continuation.yield(change)
    }

    /// Stop the stream.
    public func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
