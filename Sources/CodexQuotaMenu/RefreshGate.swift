import Foundation

struct RefreshGate {
    let interval: TimeInterval
    let manualMinimumInterval: TimeInterval

    func shouldRefresh(lastAttempt: Date?, now: Date, manual: Bool) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        if elapsed < 0 { return true }
        return elapsed >= (manual ? manualMinimumInterval : interval)
    }
}
