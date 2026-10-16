import Foundation
import IOKit.pwr_mgt

/// Holds the display awake while the visuals are on the wall.
///
/// Two mechanisms, because one isn't enough. The power assertion stops the
/// display idling off, but the screen saver runs on its own idle timer and can
/// still start over a display that was never allowed to sleep. So we also
/// declare user activity on a repeating timer, which pushes that idle timer
/// back the same way a keypress would.
@MainActor
final class PowerManager {
    private var timer: Timer?
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false
    private var userActivityID: IOPMAssertionID = 0

    /// Comfortably inside the shortest screen-saver delay macOS offers (1 min).
    private static let keepAwakeInterval: TimeInterval = 30
    private static let reason = "Mekong is projecting visuals" as CFString

    func setKeepAwake(_ on: Bool) {
        if on, !assertionActive {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.reason, &id)
            guard result == kIOReturnSuccess else { return }
            assertionID = id
            assertionActive = true
            declareUserActivity()
            let t = Timer(timeInterval: Self.keepAwakeInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.declareUserActivity() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on, assertionActive {
            timer?.invalidate()
            timer = nil
            IOPMAssertionRelease(assertionID)
            assertionActive = false
            assertionID = 0
        }
    }

    private func declareUserActivity() {
        guard assertionActive else { return }
        IOPMAssertionDeclareUserActivity(Self.reason, kIOPMUserActiveLocal, &userActivityID)
    }
}
