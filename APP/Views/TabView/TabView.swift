import SwiftUI

enum TabEnum: String, CaseIterable, Hashable {
    case settings
    case tfapps
    case downloads
    case search

    var title: String {
        switch self {
        case .settings:  return "tab_settings".localized
        case .tfapps:     return "tab_tfapps".localized
        case .downloads:  return "tab_downloads".localized
        case .search:     return "tab_search".localized
        }
    }

    var icon: String {
        switch self {
        case .settings:  return "gearshape.2"
        case .downloads:  return "tray.and.arrow.down"
        case .tfapps:     return "star.circle"
        case .search:     return "magnifyingglass"
        }
    }

    @ViewBuilder
    static func view(for tab: TabEnum, themeManager: ThemeManager) -> some View {
        switch tab {
        case .settings:
            SettingsView()
                .environmentObject(themeManager)
        case .downloads:
            NavigationView {
                DownloadView()
                    .environmentObject(themeManager)
            }
        case .tfapps:
            NavigationView {
                TFAppsView()
                    .environmentObject(themeManager)
            }
        case .search:
            NavigationView {
                SearchView()
                    .environmentObject(themeManager)
            }
        }
    }
}

struct TabbarView: View {
    @State private var selectedTab: TabEnum = .settings
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        TabView(selection: $selectedTab) {
            TabEnum.view(for: .settings, themeManager: themeManager)
                .tabItem {
                    Image(systemName: TabEnum.settings.icon)
                    Text(TabEnum.settings.title)
                }
                .tag(TabEnum.settings)

            TabEnum.view(for: .tfapps, themeManager: themeManager)
                .tabItem {
                    Image(systemName: TabEnum.tfapps.icon)
                    Text(TabEnum.tfapps.title)
                }
                .tag(TabEnum.tfapps)

            TabEnum.view(for: .downloads, themeManager: themeManager)
                .tabItem {
                    Image(systemName: TabEnum.downloads.icon)
                    Text(TabEnum.downloads.title)
                }
                .tag(TabEnum.downloads)

            TabEnum.view(for: .search, themeManager: themeManager)
                .tabItem {
                    Image(systemName: TabEnum.search.icon)
                    Text(TabEnum.search.title)
                }
                .tag(TabEnum.search)
        }
        .onAppear {
            AnalyticsManager.shared.trackScreen(selectedTab.rawValue)
        }
        .onChange(of: selectedTab) { newValue in
            AnalyticsManager.shared.trackScreen(newValue.rawValue)
        }
        .tint(themeManager.accentColor)
        .background(themeManager.backgroundColor)
    }
}
