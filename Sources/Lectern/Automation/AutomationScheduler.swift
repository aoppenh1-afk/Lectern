import AppKit
import Foundation

@MainActor
final class AutomationScheduler {
    private let activityScheduler: NSBackgroundActivityScheduler
    private let automationService: ShiurAutomationService
    private var wakeObserver: (any NSObjectProtocol)?

    init(automationService: ShiurAutomationService) {
        self.automationService = automationService
        self.activityScheduler = NSBackgroundActivityScheduler(identifier: "com.lectern.automation.shiur")
        self.activityScheduler.repeats = true
        self.activityScheduler.interval = 30 * 60 // Checks every 30 minutes for due 1h or 12h subscriptions
        self.activityScheduler.tolerance = 5 * 60
    }

    func start() {
        // 1. Install periodic background scheduler
        activityScheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(.finished)
                    return
                }
                await self.automationService.checkSubscriptions(dueOnly: true)
                completion(.finished)
            }
        }

        // 2. Listen for Mac wake notification
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.automationService.checkSubscriptions(dueOnly: true)
            }
        }

        // 3. Catch-up & resume on startup
        automationService.resumePendingItems()
        Task {
            await automationService.checkSubscriptions(dueOnly: true)
        }
    }

    func stop() {
        activityScheduler.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func checkNow(for subscription: ShiurSubscription) {
        Task {
            await automationService.checkSubscription(subscription, ignoreDue: true)
        }
    }

    func checkAllNow() {
        Task {
            await automationService.checkSubscriptions(dueOnly: false)
        }
    }
}
