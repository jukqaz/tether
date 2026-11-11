import Foundation

/// App/controller fixtures need UserDefaults semantics, not CFPreferences files.
/// Domain operations remain separate so migration/removal tests keep their scope.
final class TestMemoryDefaults: UserDefaults {
    private let domain: String
    private var domains: [String: [String: Any]] = [:]
    private var registered: [String: Any] = [:]

    init(domain: String) {
        self.domain = domain
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { domains[domain]?[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { domains[domain, default: [:]][key] = value }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func removeObject(forKey key: String) { domains[domain]?[key] = nil }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool {
        (object(forKey: key) as? NSNumber)?.boolValue ?? (object(forKey: key) as? NSString)?.boolValue ?? false
    }
    override func integer(forKey key: String) -> Int {
        (object(forKey: key) as? NSNumber)?.intValue ?? (object(forKey: key) as? NSString)?.integerValue ?? 0
    }
    override func float(forKey key: String) -> Float {
        (object(forKey: key) as? NSNumber)?.floatValue ?? (object(forKey: key) as? NSString)?.floatValue ?? 0
    }
    override func double(forKey key: String) -> Double {
        (object(forKey: key) as? NSNumber)?.doubleValue ?? (object(forKey: key) as? NSString)?.doubleValue ?? 0
    }
    override func dictionaryRepresentation() -> [String: Any] {
        registered.merging(domains[domain] ?? [:]) { _, stored in stored }
    }
    override func persistentDomain(forName name: String) -> [String: Any]? { domains[name] }
    override func setPersistentDomain(_ values: [String: Any], forName name: String) { domains[name] = values }
    override func removePersistentDomain(forName name: String) { domains.removeValue(forKey: name) }
    override func synchronize() -> Bool { true }
}
