import Foundation
import Observation

/// Tracks whether this Mac has been through the setup assistant. Bump
/// `currentVersion` when a new step is added so existing users see it once.
@Observable
@MainActor
final class OnboardingState {
    static let completedVersionKey = "onboarding.completedVersion"
    static let currentVersion = 1

    var isPresented = false

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var completedVersion: Int {
        userDefaults.integer(forKey: Self.completedVersionKey)
    }

    var needsOnboarding: Bool {
        completedVersion < Self.currentVersion
    }

    func presentIfNeeded() {
        if needsOnboarding { isPresented = true }
    }

    func present() {
        isPresented = true
    }

    func complete() {
        userDefaults.set(Self.currentVersion, forKey: Self.completedVersionKey)
        isPresented = false
    }
}
