import Foundation

protocol PreferencesStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
    func double(forKey defaultName: String) -> Double
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func string(forKey defaultName: String) -> String?
}

extension UserDefaults: PreferencesStore {}
