import Foundation
import Testing

struct AISessionPoolTests {
    @Test func defaultsToFiveAndClampsStoredLimit() {
        let suite = "AISessionPoolTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AISessionPool.configuredLimit(defaults: defaults) == 5)
        defaults.set(3, forKey: AISessionPool.settingsKey)
        #expect(AISessionPool.configuredLimit(defaults: defaults) == 3)
        defaults.set(0, forKey: AISessionPool.settingsKey)
        #expect(AISessionPool.configuredLimit(defaults: defaults) == 1)
        defaults.set(99, forKey: AISessionPool.settingsKey)
        #expect(AISessionPool.configuredLimit(defaults: defaults) == 20)
    }

    @Test func sharesCapacityAndCancelsWaitingJobs() async throws {
        let pool = AISessionPool(limit: 2)
        let probe = Probe()
        let first = Task { try await pool.withPermit { try await probe.run() } }
        let second = Task { try await pool.withPermit { try await probe.run() } }
        for _ in 0..<200 where await probe.started < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await probe.started == 2)
        let cancelled = Task { try await pool.withPermit { try await probe.run() } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.started == 2)
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Queued job ignored cancellation") }
        catch is CancellationError {}
        first.cancel()
        do { try await first.value; Issue.record("Active job ignored cancellation") }
        catch is CancellationError {}
        let next = Task { try await pool.withPermit { try await probe.run() } }
        for _ in 0..<200 where await probe.started < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await probe.started == 3)
        #expect(await probe.maximum == 2)
        second.cancel()
        next.cancel()
        _ = await second.result
        _ = await next.result
        #expect(await probe.running == 0)
        let value = try await pool.withPermit { 42 }
        #expect(value == 42)
    }

    private actor Probe {
        var started = 0
        var running = 0
        var maximum = 0
        func run() async throws {
            started += 1
            running += 1
            maximum = max(maximum, running)
            defer { running -= 1 }
            try await Task.sleep(for: .seconds(30))
        }
    }
}
