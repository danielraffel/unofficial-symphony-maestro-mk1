/// A FIFO owner for USB sequences; suspension never blocks a thread. Property
/// writes and multi-write replay take the same owner across XPC replies.
actor AsyncSequenceOwner {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}
