import Foundation
import Combine

@MainActor
final class AppearanceStore:ObservableObject {
    static let shared=AppearanceStore()
    private let defaults:UserDefaults
    @Published var selected:AppTheme {didSet {ThemePreference.save(selected,to:defaults)}}
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        selected=ThemePreference.load(from:defaults)
    }
}
