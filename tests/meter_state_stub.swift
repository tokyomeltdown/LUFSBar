// Stands in for the app's SystemAudioTap when MeterState.swift is built on its
// own (see meter_state.swift): the meter is whatever the test puts here, it is
// always delivering, and resets are counted.
import Foundation

final class SystemAudioTap {
    static let shared = SystemAudioTap()
    var loudnessMeter: LoudnessMeter?
    var isDelivering = true
    private(set) var resets = 0

    func start() {}

    func resetIntegrated() {
        resets += 1
        loudnessMeter?.resetIntegrated()
    }
}
