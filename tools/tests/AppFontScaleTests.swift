import Foundation
import SwiftUI

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

// Offered steps: 80…200 in 10% steps, default 100%.
for percent in stride(from: 80, through: 200, by: 10) {
    check(AppFontScale.validated(percent) == percent, "\(percent)% is a valid step")
}
check(AppFontScale.validated(70) == 100, "below range falls back to 100%")
check(AppFontScale.validated(210) == 100, "above range falls back to 100%")
check(AppFontScale.validated(115) == 100, "off-step value falls back to 100%")
check(AppFontScale.validated(0) == 100, "zero falls back to 100%")
check(AppFontScale.validated(-100) == 100, "negative falls back to 100%")
check(AppFontScale.factor(percent: 150) == 1.5, "factor of 150% is 1.5")
check(AppFontScale.factor(percent: 999) == 1, "factor of an invalid value is 1")

// Stored value: missing, invalid type and invalid number all give 100%.
let defaults = UserDefaults.standard
defaults.removeObject(forKey: AppFontScale.storageKey)
check(AppFontScale.storedFactor == 1, "missing preference is 100%")
defaults.set("large", forKey: AppFontScale.storageKey)
check(AppFontScale.storedFactor == 1, "non-numeric preference is 100%")
defaults.set(300, forKey: AppFontScale.storageKey)
check(AppFontScale.storedFactor == 1, "out-of-range preference is 100%")
defaults.set(120, forKey: AppFontScale.storageKey)
check(AppFontScale.storedFactor == 1.2, "saved 120% is used")
defaults.removeObject(forKey: AppFontScale.storageKey)

// Text styles keep the macOS hierarchy; headline stays bold.
check(AppFontScale.pointSize(.body) == 13, "body is 13 pt")
check(AppFontScale.pointSize(.caption) == 10, "caption is 10 pt")
check(AppFontScale.pointSize(.title2) == 17, "title2 is 17 pt")
check(AppFontScale.defaultWeight(.headline) == .bold, "headline is bold")
check(AppFontScale.defaultWeight(.caption) == .regular, "caption is regular")

// Editor slider mirror: its own range (10…20), independent of the interface scale.
check(EditorTextSize.validated(16) == 16, "slider size 16 is kept")
check(EditorTextSize.validated(40) == 13, "out-of-range slider size falls back to 13")
check(EditorTextSize.mirrorKey != AppFontScale.storageKey, "the two controls use separate keys")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("app-font-scale-tests: all passed")
