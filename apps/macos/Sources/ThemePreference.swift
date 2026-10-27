import Foundation

// UI preferences are independent of model configuration and credentials.
enum AppTheme:String,CaseIterable,Identifiable {
    case liquidGlass="liquid-glass"
    case midnight="midnight-glass"
    var id:String {rawValue}
    var title:String {self == .liquidGlass ? "Liquid Glass" : "午夜毛玻璃"}
    var subtitle:String {self == .liquidGlass ? "晨光 · 通透与流动" : "深色 · 专注与克制"}
}

struct ThemePreference {
    static let storageKey="TaskSecretary.appearance.theme"
    static func load(from defaults:UserDefaults)->AppTheme {
        defaults.string(forKey:storageKey).flatMap(AppTheme.init(rawValue:)) ?? .liquidGlass
    }
    static func save(_ theme:AppTheme,to defaults:UserDefaults) {defaults.set(theme.rawValue,forKey:storageKey)}
}
