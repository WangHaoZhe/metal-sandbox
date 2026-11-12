import Foundation

public enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english
    public static let preferenceKey = "interface_language"
    public var id: String { rawValue }
    public static var current: InterfaceLanguage {
        InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }
    public var title: String {
        switch self {
        case .system: return ui("跟随系统", "System Default")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> InterfaceLanguage {
        self == .system ? (preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english) : self
    }
    public var locale: Locale { Locale(identifier: resolved() == .chinese ? "zh_Hans" : "en") }
}

public func ui(_ chinese: String, _ english: String, language: InterfaceLanguage = .current) -> String {
    language.resolved() == .chinese ? chinese : english
}
