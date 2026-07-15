import Foundation
import SwiftUI
import Combine

@MainActor
class AppStore: ObservableObject {

    static let this = AppStore()

    @Published var savedAccounts: [Account] = []

    @Published var selectedAccount: Account? = nil

    @Published var selectedAccountIndex: Int = 0

    private init() {
        loadAccounts()
    }

    private func loadAccounts() {

        let allAccounts = AuthenticationManager.shared.loadAllSavedAccounts()
        savedAccounts = allAccounts

        if !allAccounts.isEmpty {

            selectedAccount = allAccounts.first
            selectedAccountIndex = 0
            print("[AppStore] 加载了 \(allAccounts.count) 个账户")
            for (index, account) in allAccounts.enumerated() {
                print("[AppStore] 账户 \(index + 1): \(account.email), 地区: \(account.countryCode)")
            }
        } else {
            print("[AppStore] 没有找到保存的账户")
            selectedAccount = nil
            selectedAccountIndex = 0
        }
    }

    func loginAccount(email: String, password: String, code: String?) async throws {

        let account = try await AuthenticationManager.shared.authenticate(
            email: email,
            password: password,
            mfa: code
        )

        if let existingIndex = savedAccounts.firstIndex(where: { $0.email == account.email }) {

            savedAccounts[existingIndex] = account
            selectedAccountIndex = existingIndex
            print("[AppStore] 更新现有账户: \(account.email), 地区: \(account.countryCode)")
        } else {

            savedAccounts.append(account)
            selectedAccountIndex = savedAccounts.count - 1
            print("[AppStore] 添加新账户: \(account.email), 地区: \(account.countryCode)")
        }

        selectedAccount = account

        try AuthenticationManager.shared.saveAllAccounts(savedAccounts)

        print("[AppStore] 账户登录成功: \(account.email), 地区: \(account.countryCode), 总账户数: \(savedAccounts.count)")
    }

    func logoutAccount() {
        guard let currentAccount = selectedAccount else { return }
        deleteAccount(currentAccount)
        print("[AppStore] 账户已登出: \(currentAccount.email), 剩余账户数: \(savedAccounts.count)")
    }

    func deleteAccount(_ account: Account) {
        if let index = savedAccounts.firstIndex(where: { $0.email == account.email }) {
            savedAccounts.remove(at: index)

            if savedAccounts.isEmpty {
                selectedAccount = nil
                selectedAccountIndex = 0
            } else {

                selectedAccountIndex = min(index, savedAccounts.count - 1)
                selectedAccount = savedAccounts[selectedAccountIndex]
            }
        }

        try? AuthenticationManager.shared.saveAllAccounts(savedAccounts)

        print("[AppStore] 删除账户: \(account.email), 剩余账户数: \(savedAccounts.count)")
    }

    func refreshAccount() {

        loadAccounts()
        objectWillChange.send()
    }

    func switchToAccount(at index: Int) {
        guard index >= 0 && index < savedAccounts.count else { return }

        selectedAccountIndex = index
        selectedAccount = savedAccounts[index]

        print("[AppStore] 切换到账户: \(selectedAccount?.email ?? "未知"), 索引: \(index)")
    }

    func switchToAccount(_ account: Account) {
        if let index = savedAccounts.firstIndex(where: { $0.email == account.email }) {
            switchToAccount(at: index)
        }
    }

    func updateAccount(_ account: Account) {

        selectedAccount = account

        if let index = savedAccounts.firstIndex(where: { $0.email == account.email }) {
            savedAccounts[index] = account
        }

        try? AuthenticationManager.shared.saveAllAccounts(savedAccounts)
        print("[AppStore] 账户信息已更新: \(account.email)")
    }

    func refreshCurrentAccount() async throws {
        guard let account = selectedAccount else {
            print("[AppStore] 没有当前账户需要刷新")
            return
        }

        AuthenticationManager.shared.setCookies(account.cookies)

        if await AuthenticationManager.shared.validateAccount(account) {

            let updatedAccount = AuthenticationManager.shared.refreshCookies(for: account)

            selectedAccount = updatedAccount
            print("[AppStore] 账户令牌已刷新: \(updatedAccount.email)")
        } else {
            print("[AppStore] 账户验证失败，需要重新登录")
            logoutAccount()
        }
    }

    func setCurrentAccountCookies() {
        guard let account = selectedAccount else {
            print("[AppStore] 没有当前账户可设置Cookie")
            return
        }

        AuthenticationManager.shared.setCookies(account.cookies)
        print("[AppStore] 已设置账户Cookie: \(account.email)")
    }

    var currentAccountRegion: String {
        return selectedAccount?.countryCode ?? ""
    }

    var allAccountRegions: [String] {
        return savedAccounts.map { $0.countryCode }
    }

    var hasMultipleAccounts: Bool {
        return savedAccounts.count > 1
    }
}

