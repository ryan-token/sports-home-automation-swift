//
//  Timeout.swift
//  sports-home-automation-swift
//

/// Thrown by `withTimeout` when the operation runs out of time.
public struct TimeoutError: Error, CustomStringConvertible {
    public let timeout: Duration

    public var description: String { "timed out after \(timeout)" }
}

/// Runs `operation`, cancelling it and throwing `TimeoutError` if it takes longer than `timeout`.
///
/// Use it to keep an external call well inside the Lambda's own timeout, so a hung dependency becomes a
/// logged error instead of the runtime killing the invocation. Unlike AsyncHTTPClient's
/// `execute(_:timeout:)`, whose deadline stops covering the request once the response head arrives,
/// this bounds everything inside it, including reading the body.
public func withTimeout<Result: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError(timeout: timeout)
        }
        // Whichever finishes first wins; cancelling stops the other (AsyncHTTPClient aborts the request).
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            preconditionFailure("withTimeout's group always has two child tasks")
        }
        return result
    }
}
