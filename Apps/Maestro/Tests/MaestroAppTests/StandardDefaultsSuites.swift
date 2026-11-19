import Testing

/// Suites that read and write UserDefaults.standard (the legacy, unscoped
/// keys) run one at a time, never alongside each other.
@Suite(.serialized)
@MainActor
enum StandardDefaultsSuites {}
