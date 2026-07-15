import SwiftUI
import Foundation

struct ModernTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            )
            .foregroundColor(.primary)
    }
}
@MainActor
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: AppStore
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var code: String = ""
    @State private var errorMessage: String = ""
    @State private var isLoading: Bool = false
    @State private var showTwoFactorField: Bool = false
    @FocusState private var isCodeFieldFocused: Bool
    var body: some View {
        NavigationView {
            ZStack {

                themeManager.backgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 0) {

                    GeometryReader { geometry in
                        Color.clear
                            .frame(height: geometry.safeAreaInsets.top > 0 ? geometry.safeAreaInsets.top : 44)
                    }
                    .frame(height: 44)

                    VStack(spacing: 0) {
                        Spacer()

                        VStack(spacing: 20) {
                            Image("AppLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 120, height: 120)
                                .cornerRadius(12)
                                .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)

                            VStack(spacing: 8) {
                                Text("apple_id".localized)
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundColor(.primary)

                                Text("login_your_account".localized)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        VStack(spacing: 24) {

                            VStack(alignment: .leading, spacing: 8) {
                                Text("apple_id".localized)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                TextField("enter_apple_id".localized, text: $email)
                                    .textFieldStyle(ModernTextFieldStyle())
                                    .keyboardType(.emailAddress)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("password".localized)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                SecureField("enter_password".localized, text: $password)
                                    .textFieldStyle(ModernTextFieldStyle())
                            }

                            if showTwoFactorField {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("two_factor_code".localized)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    TextField("enter_6digit_code".localized, text: $code)
                                        .textFieldStyle(ModernTextFieldStyle())
                                        .keyboardType(.numberPad)
                                        .focused($isCodeFieldFocused)
                                        .onChange(of: code) { newValue in

                                            let filtered = String(newValue.filter { $0.isNumber })

                                            if filtered.count > 6 {
                                                code = String(filtered.prefix(6))
                                            } else {
                                                code = filtered
                                            }

                                            if code.count == 6 {

                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {

                                                    isCodeFieldFocused = false

                                                    Task {
                                                        await authenticate()
                                                    }
                                                }
                                            }
                                        }
                                    Text("check_trusted_device".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(.horizontal, 24)

                        Spacer()

                        VStack(spacing: 16) {
                            Button(action: {
                                Task {
                                    await authenticate()
                                }
                            }) {
                                HStack(spacing: 12) {
                                    if isLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(0.8)
                                    } else {

                                    }
                                    Text(isLoading ? "verifying".localized : "add_account".localized)
                                        .font(.system(size: 17, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    LinearGradient(
                                        colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundColor(.white)
                                .cornerRadius(16)
                                .shadow(color: themeManager.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                            }
                            .disabled(isLoading || email.isEmpty || password.isEmpty)

                            if !errorMessage.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("cancel".localized) {
                dismiss()
            }.foregroundColor(.primary))
            .onTapGesture {

                isCodeFieldFocused = false
            }
            .onAppear {

            }
        }
    }
    @MainActor
    private func authenticate() async {

        if email.isEmpty || password.isEmpty {
            errorMessage = "enter_full_credentials".localized
            return
        }

        if showTwoFactorField && code.count != 6 {
            errorMessage = "enter_6digit_code_verify".localized

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isCodeFieldFocused = true
            }
            return
        }

        print("🔐 [AddAccountView] 开始认证流程")
        print("📧 [AddAccountView] Apple ID: \(email)")
        print("🔐 [AddAccountView] 密码长度: \(password.count)")
        print("📱 [AddAccountView] 验证码: \(showTwoFactorField ? code : "无")")

        isLoading = true
        errorMessage = ""
        isCodeFieldFocused = false

        do {

            try await vm.loginAccount(
                email: email,
                password: password,
                code: showTwoFactorField ? code : nil
            )

            print("✅ [AddAccountView] 认证成功，关闭视图")

            dismiss()
        } catch {
            print("❌ [AddAccountView] 认证失败: \(error)")
            print("❌ [AddAccountView] 错误类型: \(type(of: error))")

            isLoading = false

            if let storeError = error as? StoreError {
                print("🔍 [AddAccountView] 检测到StoreError: \(storeError)")

                switch storeError {
                case .invalidCredentials:
                    errorMessage = "wrong_credentials".localized
                case .codeRequired:
                    handleTwoFactorAuthRequired()
                case .lockedAccount:
                    errorMessage = "account_locked".localized
                case .networkError:
                    errorMessage = "network_error_retry".localized
                case .authenticationFailed:
                    errorMessage = "auth_failed".localized
                case .invalidResponse:
                    errorMessage = "invalid_server_response".localized
                case .unknownError:
                    errorMessage = "unknown_error".localized
                default:
                    errorMessage = String(format: "auth_error".localized, storeError.localizedDescription)
                }
            } else {

                print("🔍 [AddAccountView] 未知错误类型: \(error)")
                errorMessage = String(format: "auth_error".localized, error.localizedDescription)
            }
        }
    }

    private func handleTwoFactorAuthRequired() {
        print("🔐 [AddAccountView] 需要双重认证码")

        if !showTwoFactorField {

            withAnimation(.easeInOut(duration: 0.3)) {
                showTwoFactorField = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isCodeFieldFocused = true
            }

            errorMessage = "check_apple_device_code".localized
        } else {

            errorMessage = "wrong_verification_code".localized

            code = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isCodeFieldFocused = true
            }
        }
    }
}
