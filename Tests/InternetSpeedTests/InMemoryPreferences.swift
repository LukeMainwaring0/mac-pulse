import Foundation
@testable import InternetSpeed

final class InMemoryPreferences: PreferencesStore {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }

    func double(forKey defaultName: String) -> Double {
        (values[defaultName] as? NSNumber)?.doubleValue
            ?? values[defaultName] as? Double
            ?? 0
    }

    func bool(forKey defaultName: String) -> Bool {
        (values[defaultName] as? NSNumber)?.boolValue
            ?? values[defaultName] as? Bool
            ?? false
    }

    func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }
}
