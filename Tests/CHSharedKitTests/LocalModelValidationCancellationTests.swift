import Foundation
import Testing
@testable import CHLocalLLM

@Suite("Installation validation cancellation")
struct LocalModelValidationCancellationTests {
    @Test("Cancellation reaches validation and the next load waits for it to drain")
    func cancellationKeepsSerializationUntilDrain() async throws {
        let coordinator = LocalModelValidationCoordinator()
        let started = ValidationSignal()
        let cancelled = ValidationSignal()
        let mayDrain = ValidationSignal()
        let nextStarted = ValidationSignal()

        let first = Task {
            try await coordinator.run {
                await started.open()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    await cancelled.open()
                    // Models native work that notices cancellation but needs
                    // time to finish before its resources can be released.
                    await mayDrain.wait()
                    throw CancellationError()
                }
            }
        }
        await started.wait()
        first.cancel()
        await cancelled.wait()

        let second = Task {
            try await coordinator.run { await nextStarted.open() }
        }
        await waitForQueuedValidation(coordinator)
        #expect(await coordinator.queuedValidationCount == 1)
        #expect(await nextStarted.isOpen == false)

        await mayDrain.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        #expect(await nextStarted.isOpen)
    }

    @Test("A deadline cancels the load and releases the slot after it ends")
    func deadlineCancelsUnderlyingOperation() async throws {
        let coordinator = LocalModelValidationCoordinator()
        let cancelled = ValidationSignal()

        do {
            try await coordinator.run(timeout: .milliseconds(100)) {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    await cancelled.open()
                    throw CancellationError()
                }
            }
            Issue.record("Expected the installation validation deadline to expire")
        } catch OfflineModelInstallationError.runtimeValidationTimedOut {
            #expect(await cancelled.isOpen)
        }

        // A completed cancellation must not strand the serialization slot.
        try await coordinator.run { }
    }

    @Test("Cancelling a queued check never starts another model load")
    func cancelledWaiterSkipsLoading() async throws {
        let coordinator = LocalModelValidationCoordinator()
        let started = ValidationSignal()
        let mayFinish = ValidationSignal()
        let cancelledLoadStarted = ValidationSignal()
        let first = Task {
            try await coordinator.run {
                await started.open()
                await mayFinish.wait()
            }
        }
        await started.wait()
        let waiting = Task {
            try await coordinator.run { await cancelledLoadStarted.open() }
        }
        await waitForQueuedValidation(coordinator)
        #expect(await coordinator.queuedValidationCount == 1)
        waiting.cancel()
        await mayFinish.open()

        try await first.value
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await cancelledLoadStarted.isOpen == false)
        try await coordinator.run { }
    }

    private func waitForQueuedValidation(_ coordinator: LocalModelValidationCoordinator) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while await coordinator.queuedValidationCount == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor ValidationSignal {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
