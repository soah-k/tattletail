import os

/// A tiny thread-safe flag the panic hotkey and Stop button set to abort a
/// replay in progress. The playback thread checks it before every event.
final class PlaybackAbortController: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func reset() { state.withLock { $0 = false } }
    func abort() { state.withLock { $0 = true } }
    var isAborted: Bool { state.withLock { $0 } }
}
