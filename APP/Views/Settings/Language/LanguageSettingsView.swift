import SwiftUI

struct LanguageSettingsView: View {
    @StateObject private var languageManager = LanguageManager.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRestartAlert = false
    @State private var selectedLanguage: AppLanguage = .system

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { lang in
                    languageRow(language: lang)
                }
            } header: {
                Text("language_select".localized)
            } footer: {
                Text("language_footer".localized)
            }

            Section {
                Button(action: openSystemSettings) {
                    HStack(spacing: 12) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("language_system_settings".localized)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(themeManager.accentColor)

                            Text("language_system_hint".localized)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("language".localized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedLanguage = languageManager.currentLanguage
        }
        .alert("language_switch".localized, isPresented: $showRestartAlert) {
            Button("cancel".localized, role: .cancel) {
                selectedLanguage = languageManager.currentLanguage
            }
            Button("confirm_switch".localized) {
                languageManager.setLanguage(selectedLanguage)
                dismiss()
            }
        } message: {
            Text("language_switch_message".localized)
        }
    }

    private func languageRow(language: AppLanguage) -> some View {
        Button(action: {
            if language != languageManager.currentLanguage {
                selectedLanguage = language
                showRestartAlert = true
            }
        }) {
            HStack(spacing: 12) {
                Text(language.flag)
                    .font(.system(size: 22))

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.nativeName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)

                    if language != .system {
                        Text(language.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if selectedLanguage == language {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(themeManager.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSystemSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}

#Preview {
    NavigationView {
        LanguageSettingsView()
            .environmentObject(ThemeManager.shared)
    }
}
