import SwiftUI
import UIKit
import Foundation

private extension UIUserInterfaceStyle {
    static var allStyles: [UIUserInterfaceStyle] {
        return [.unspecified, .light, .dark]
    }

    var displayName: String {
        switch self {
        case .unspecified: return "follow_system".localized
        case .light: return "light_mode".localized
        case .dark: return "dark_mode".localized
        @unknown default: return "none".localized
        }
    }
}

struct SettingsView: View {
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var appStore: AppStore

    @AppStorage("APP.userTintColor") private var selectedColorHex: String = "#007AFF"
    @State private var selectedColor = Color(hex: "#007AFF")
    @State private var showingIconSuccess = false
    @State private var isIconLoading = false
    @State private var showAccountSheet = false
    @State private var showingColorPicker = false

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

    var allIcons: [AltIcon] {
        let allIcons = AppIconView.getAllIconsFromFolder()

        if !allIcons.isEmpty {
            return allIcons.sorted { icon1, icon2 in
                if icon1.key == "app" { return true }
                if icon2.key == "app" { return false }
                return icon1.key ?? "" < icon2.key ?? ""
            }
        }

        return [
            AltIcon(
                displayName: "icon_default".localized,
                author: "icon_author".localized,
                key: "app"
            ),
            AltIcon(
                displayName: "icon_love".localized,
                author: "icon_author".localized,
                key: "kana_love"
            ),
            AltIcon(
                displayName: "icon_peek".localized,
                author: "icon_author".localized,
                key: "kana_peek"
            )
        ]
    }

    private let presetColorHexes: [String] = [
        "#B496DC", "#848ef9", "#ff7a83", "#4161F1", "#FF00FF",
        "#4CD964", "#FF2D55", "#FF9500", "#4860e8", "#5394F7",
        "#e18aab", "#00CED1", "#228B22", "#FF6347", "#191970",
        "#FFB6C1", "#98FB98", "#E6E6FA", "#FF7F50", "#50C878"
    ]

    private var presetColors: [Color] {
        presetColorHexes.map { Color(hex: $0) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    accountHeaderSection
                    appearanceSection
                    languageSection
                    iconSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .onAppear {
                selectedColor = Color(hex: selectedColorHex)
                currentIcon = UIApplication.shared.alternateIconName
            }
            .onChange(of: selectedColorHex, perform: { newValue in
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    for window in windowScene.windows {
                        window.tintColor = UIColor(Color(hex: newValue))
                    }
                }
                themeManager.objectWillChange.send()
            })
            .sheet(isPresented: $showAccountSheet) {
                AccountSheetView()
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
        }
    }

    private var accountHeaderSection: some View {
        Button(action: {
            showAccountSheet = true
        }) {
            if let account = appStore.selectedAccount {
                HStack(spacing: 16) {
                    ZStack {
                        AccountAvatarButton(size: 64)

                        Circle()
                            .stroke(themeManager.accentColor.opacity(0.3), lineWidth: 2)
                            .frame(width: 72, height: 72)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name.isEmpty ? account.email : account.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if !account.name.isEmpty {
                            Text(account.email)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 6) {
                            Text(flag(country: account.countryCode))
                                .font(.caption)
                            Text(countryName(account.countryCode))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary.opacity(0.5))
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("sign_in_apple_id".localized)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)

                        Text("sign_in_apple_id_desc".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func flag(country: String) -> String {
        let base: UInt32 = 127397
        var s = ""
        for v in country.uppercased().unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return s
    }

    private func countryName(_ code: String) -> String {
        let locale = LanguageManager.shared.locale
        return locale.localizedString(forRegionCode: code) ?? code.uppercased()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ThemeManager.shared)
            .environmentObject(AppStore.this)
    }
}

extension SettingsView {
    @ViewBuilder
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("appearance".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                appearanceRow
                Divider()
                    .padding(.leading, 52)
                colorRow
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }

    private var appearanceRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(themeManager.accentColor)
                    )

                Text("appearance".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)

                Spacer()
            }

            Picker("", selection: selectedStyle) {
                ForEach(UIUserInterfaceStyle.allStyles, id: \.self) { style in
                    Text(style.displayName)
                        .tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: {
                showingColorPicker = true
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(selectedColor)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                        
                        Image(systemName: "eyedropper")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("color".localized)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                        
                        Text(selectedColorHex)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .sheet(isPresented: $showingColorPicker) {
                ColorPickerView(selectedColor: $selectedColor)
            }
            .onChange(of: selectedColor) { newColor in
                selectedColorHex = newColor.toHex()
                themeManager.accentColor = newColor
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presetColors, id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        selectedColor == color ? Color.primary : Color.clear,
                                        lineWidth: 2.5
                                    )
                            )
                            .overlay(
                                selectedColor == color ?
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .background(
                                        Circle()
                                            .fill(Color.primary.opacity(0.3))
                                            .frame(width: 18, height: 18)
                                    ) : nil
                            )
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedColor = color
                                    selectedColorHex = color.toHex()
                                    themeManager.accentColor = color
                                }
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                            }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("icon".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(allIcons) { icon in
                    iconItem(icon: icon)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("general".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            NavigationLink(destination: LanguageSettingsView().environmentObject(themeManager)) {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(themeManager.accentColor)
                        )

                    Text("language".localized)
                        .font(.system(size: 16))
                        .foregroundColor(.primary)

                    Spacer()

                    HStack(spacing: 6) {
                        Text(LanguageManager.shared.currentLanguage.flag)
                        Text(LanguageManager.shared.currentLanguage.nativeName)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private func iconItem(icon: AltIcon) -> some View {
        Button {
            isIconLoading = true

            let iconNameToSet = icon.key == "app" ? nil : icon.key

            UIApplication.shared.setAlternateIconName(iconNameToSet) { error in
                DispatchQueue.main.async {
                    isIconLoading = false
                    currentIcon = UIApplication.shared.alternateIconName
                    if error == nil {
                        showingIconSuccess = true
                    } else {
                        print("❌ [AppIcon] 设置图标失败: \(error!.localizedDescription)")
                    }
                }
            }
        } label: {
            VStack(alignment: .center, spacing: 6) {
                ZStack {
                    Image(uiImage: icon.image)
                        .appIconStyle()
                }

                VStack(alignment: .center, spacing: 2) {
                    Text(icon.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                    Text(icon.author)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
