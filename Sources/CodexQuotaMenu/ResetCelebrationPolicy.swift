import Foundation

struct ResetQuotaObservation: Codable, Equatable {
    let shortRemainingPercent: Int
    let shortResetsAt: Date
    let weeklyRemainingPercent: Int
    let weeklyResetsAt: Date
}

struct ResetCelebrationState: Codable, Equatable {
    var wasHigh: Bool
    var dismissed: Bool
    var observation: ResetQuotaObservation?

    static let initial = ResetCelebrationState(
        wasHigh: false,
        dismissed: false,
        observation: nil
    )
}

struct ResetCelebrationDecision: Equatable {
    let isActive: Bool
    let state: ResetCelebrationState
}

enum ResetCelebrationPolicy {
    static func evaluate(
        state: ResetCelebrationState,
        probability48h: Int?,
        observation: ResetQuotaObservation?
    ) -> ResetCelebrationDecision {
        guard let probability48h else {
            return ResetCelebrationDecision(isActive: false, state: state)
        }

        guard probability48h >= 80 else {
            return ResetCelebrationDecision(
                isActive: false,
                state: ResetCelebrationState(
                    wasHigh: false,
                    dismissed: false,
                    observation: observation
                )
            )
        }

        if !state.wasHigh {
            return ResetCelebrationDecision(
                isActive: true,
                state: ResetCelebrationState(
                    wasHigh: true,
                    dismissed: false,
                    observation: observation
                )
            )
        }

        var dismissed = state.dismissed
        if !dismissed,
           let previous = state.observation,
           let observation,
           resetCompleted(previous: previous, current: observation) {
            dismissed = true
        }
        return ResetCelebrationDecision(
            isActive: !dismissed,
            state: ResetCelebrationState(
                wasHigh: true,
                dismissed: dismissed,
                observation: observation ?? state.observation
            )
        )
    }

    private static func resetCompleted(
        previous: ResetQuotaObservation,
        current: ResetQuotaObservation
    ) -> Bool {
        let reachedFull = current.shortRemainingPercent == 100 &&
            current.weeklyRemainingPercent == 100 &&
            (previous.shortRemainingPercent < 100 || previous.weeklyRemainingPercent < 100)
        if reachedFull { return true }

        let quotasRefilled = current.shortRemainingPercent >= previous.shortRemainingPercent &&
            current.weeklyRemainingPercent >= previous.weeklyRemainingPercent &&
            (current.shortRemainingPercent > previous.shortRemainingPercent ||
                current.weeklyRemainingPercent > previous.weeklyRemainingPercent)
        let cyclesAdvanced = current.shortResetsAt > previous.shortResetsAt &&
            current.weeklyResetsAt > previous.weeklyResetsAt
        return quotasRefilled && cyclesAdvanced
    }
}

final class UserDefaultsResetCelebrationStateStore {
    private let defaults: UserDefaults
    private let key = "resetCelebration.state.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ResetCelebrationState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(ResetCelebrationState.self, from: data) else {
            return .initial
        }
        return state
    }

    func save(_ state: ResetCelebrationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
