import Foundation

/// Runs `work` with an upper bound on how long the caller will wait for it.
///
/// - Returns: `true` if `work` finished in time, `false` if the deadline won.
///
/// Deliberately **not** a task group. A group awaits every child before returning, so a
/// child that ignores cancellation — precisely the case this exists to defend against —
/// makes the group hang for exactly as long as awaiting the child directly would have.
/// Both sides run detached here and only the first answer is read; the loser is abandoned.
///
/// It exists because two calls in the dictation tail have been observed never to return:
/// `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()` on a session that received almost
/// no audio, and the drain of the result stream that follows it. Waiting on either without
/// a bound left the HUD on screen until the app was relaunched.
func withDeadline(seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))

    Task.detached {
        await work()
        continuation.yield(true)
        continuation.finish()
    }
    Task.detached {
        try? await Task.sleep(for: .seconds(seconds))
        continuation.yield(false)
        continuation.finish()
    }

    var iterator = stream.makeAsyncIterator()
    return await iterator.next() ?? false
}
