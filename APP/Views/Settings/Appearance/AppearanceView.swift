import SwiftUI
import UIKit

private extension UIUserInterfaceStyle {
    static var allStyles: [UIUserInterfaceStyle] {
        return [.unspecified, .light, .dark]
    }

    var displayName: String {
        switch self {
        case .unspecified: return "auto".localized
        case .light: return "light_mode".localized
        case .dark: return "dark_mode".localized
        @unknown default: return "unknown".localized
        }
    }
}

struct AppearanceView: View {
    @EnvironmentObject var themeManager: ThemeManager

    private var selectedStyle: Binding<UIUserInterfaceStyle> {
        Binding(
            get: {
                switch themeManager.selectedTheme {
                case .system: return .unspecified
                case .light: return .light
                case .dark: return .dark
                }
            },
            set: { newStyle in
                switch newStyle {
                case .unspecified: themeManager.selectedTheme = .system
                case .light: themeManager.selectedTheme = .light
                case .dark: themeManager.selectedTheme = .dark
                @unknown default: break
                }
            }
        )
    }

    var body: some View {
        List {
            Section {
                Picker("appearance".localized, selection: selectedStyle) {
                    ForEach(UIUserInterfaceStyle.allStyles, id: \.self) { style in
                        Text(style.displayName)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
