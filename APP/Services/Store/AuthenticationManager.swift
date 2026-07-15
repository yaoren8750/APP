import Foundation
import Security

@MainActor
class AuthenticationManager: @unchecked Sendable {
    static let shared = AuthenticationManager()
    private let keychainService = "ipatool.swift.service"
    private let keychainAccount = "account"
    private let storeRequest = StoreRequest.shared
    private init() {}

    func authenticate(email: String, password: String, mfa: String? = nil) async throws -> Account {
        let response = try await StoreRequest.shared.authenticate(
            email: email,
            password: password,
            mfa: mfa
        )

        let cookieStrings = getCurrentCookies()

        let firstName = response.accountInfo.address.firstName
        let lastName = response.accountInfo.address.lastName
        let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        let finalName = name.isEmpty ? email : name

        let detectedCountryCode = detectCountryCode(from: response, email: email)
        let detectedStoreFront = detectStoreFront(from: response, countryCode: detectedCountryCode)

        print("🌍 [地区检测] 检测到的地区代码: \(detectedCountryCode)")
        print("🏪 [商店检测] 检测到的StoreFront: \(detectedStoreFront)")

        let account = Account(
            name: finalName,
            email: email,
            firstName: firstName,
            lastName: lastName,
            passwordToken: response.passwordToken,
            directoryServicesIdentifier: response.dsPersonId,
            dsPersonId: response.dsPersonId,
            cookies: cookieStrings,
            countryCode: detectedCountryCode,
            storeResponse: Account.AccountStoreResponse(
                directoryServicesIdentifier: response.dsPersonId,
                passwordToken: response.passwordToken,
                storeFront: detectedStoreFront
            )
        )

        do {
            try saveAccountToKeychain(account)
        } catch {
            print("警告: 无法将账户保存到钥匙串: \(error)")
        }
        return account
    }

    func authenticateWith2FA(code: String, isSMS: Bool = false, phoneId: String? = nil) async throws -> Account {
        let response = try await StoreRequest.shared.authenticateWith2FA(
            code: code,
            isSMS: isSMS,
            phoneId: phoneId
        )

        let cookieStrings = getCurrentCookies()

        let firstName = response.accountInfo.address.firstName
        let lastName = response.accountInfo.address.lastName
        let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        let finalName = name.isEmpty ? response.accountInfo.appleId : name

        let detectedCountryCode = detectCountryCode(from: response, email: response.accountInfo.appleId)
        let detectedStoreFront = detectStoreFront(from: response, countryCode: detectedCountryCode)

        let account = Account(
            name: finalName,
            email: response.accountInfo.appleId,
            firstName: firstName,
            lastName: lastName,
            passwordToken: response.passwordToken,
            directoryServicesIdentifier: response.dsPersonId,
            dsPersonId: response.dsPersonId,
            cookies: cookieStrings,
            countryCode: detectedCountryCode,
            storeResponse: Account.AccountStoreResponse(
                directoryServicesIdentifier: response.dsPersonId,
                passwordToken: response.passwordToken,
                storeFront: detectedStoreFront
            )
        )

        do {
            try saveAccountToKeychain(account)
        } catch {
            print("警告: 无法将账户保存到钥匙串: \(error)")
        }

        return account
    }

    func resetAuthSession() {
        AppleIDAuthenticator.shared.resetSession()
    }

    func loadAllSavedAccounts() -> [Account] {

        let newFormatAccounts = loadAllAccountsFromKeychain()
        if !newFormatAccounts.isEmpty {
            print("🔐 [AuthenticationManager] 加载了 \(newFormatAccounts.count) 个账户（新格式）")
            return newFormatAccounts
        }

        if let oldFormatAccount = loadAccountFromKeychain() {
            print("🔐 [AuthenticationManager] 加载了1个账户（旧格式），转换为新格式")

            let accounts = [oldFormatAccount]
            try? saveAllAccountsToKeychain(accounts)
            return accounts
        }

        print("🔐 [AuthenticationManager] 没有找到任何保存的账户")
        return []
    }

    func saveAllAccounts(_ accounts: [Account]) throws {
        try saveAllAccountsToKeychain(accounts)
    }

    func validateAccount(_ account: Account) async -> Bool {

        setCookies(account.cookies)

        guard let cookies = HTTPCookieStorage.shared.cookies else { return false }

        var hasValidCookie = false
        for cookie in cookies {
            if cookie.domain.contains("apple.com") {
                if let expiresDate = cookie.expiresDate {
                    if expiresDate.timeIntervalSinceNow > 0 {
                        hasValidCookie = true
                        break
                    }
                } else {

                    hasValidCookie = true
                    break
                }
            }
        }

        return hasValidCookie
    }

    func refreshCookies(for account: Account) -> Account {
        let updatedAccount = Account(
            name: account.name,
            email: account.email,
            firstName: account.firstName,
            lastName: account.lastName,
            passwordToken: account.passwordToken,
            directoryServicesIdentifier: account.directoryServicesIdentifier,
            dsPersonId: account.dsPersonId,
            cookies: getCurrentCookies(),
            countryCode: account.countryCode,
            storeResponse: account.storeResponse,
            deviceGUID: account.deviceGUID
        )

        do {
            try saveAccountToKeychain(updatedAccount)
        } catch {
            print("警告: 无法保存更新后的账户: \(error)")
        }
        return updatedAccount
    }

    private func getCurrentCookies() -> [String] {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return [] }
        return cookies.compactMap { cookie in
            if cookie.domain.contains("apple.com") || cookie.domain.contains("itunes.apple.com") {
                return cookie.description
            }
            return nil
        }
    }

    func setCookies(_ cookies: [String]) {
        for cookieString in cookies {
            let components = cookieString.components(separatedBy: ";")
            var cookieDict: [HTTPCookiePropertyKey: Any] = [:]
            for component in components {
                let parts = component.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    if parts[0].lowercased() == "domain" {
                        cookieDict[.domain] = parts[1]
                    } else if parts[0].lowercased() == "path" {
                        cookieDict[.path] = parts[1]
                    } else if parts[0].lowercased() == "secure" {
                        cookieDict[.secure] = true
                    } else {
                        cookieDict[.name] = parts[0]
                        cookieDict[.value] = parts[1]
                    }
                }
            }
            if let _ = cookieDict[.name] as? String, let _ = cookieDict[.value] as? String {
                cookieDict[.domain] = cookieDict[.domain] as? String ?? ".apple.com"
                cookieDict[.path] = cookieDict[.path] as? String ?? "/"
                if let cookie = HTTPCookie(properties: cookieDict) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
        }
    }

    private func detectCountryCode(from response: StoreAuthResponse, email: String) -> String {
        print("🌍 [地区检测] 开始检测地区代码，邮箱: \(email)")

        if let serverCountryCode = response.accountInfo.countryCode, !serverCountryCode.isEmpty {
            print("🌍 [地区检测] 使用服务器返回的地区代码: \(serverCountryCode)")
            return serverCountryCode
        }

        if let storeFront = response.accountInfo.storeFront, !storeFront.isEmpty {
            let inferredCountryCode = inferCountryCodeFromStoreFront(storeFront)
            print("🌍 [地区检测] 从StoreFront推断地区代码: \(inferredCountryCode) (StoreFront: \(storeFront))")
            return inferredCountryCode
        }

        let cookieCountryCode = detectCountryCodeFromCookies()
        print("🌍 [地区检测] 从Cookie检测地区代码: \(cookieCountryCode)")

        if cookieCountryCode != "" {
            return cookieCountryCode
        }

        let emailCountryCode = inferCountryCodeFromEmail(email)
        print("🌍 [地区检测] 从邮箱推断地区代码: \(emailCountryCode)")

        if emailCountryCode != "" {
            return emailCountryCode
        }

        return "US"
    }

    private func inferCountryCodeFromStoreFront(_ storeFront: String) -> String {

        let storeFrontCode = storeFront.components(separatedBy: "-").first ?? storeFront
        print("🔍 [StoreFront解析] 提取的数字部分: \(storeFrontCode)")

        for (countryCode, code) in Apple.storeFrontCodeMap {
            if code == storeFrontCode {
                print("✅ [地区映射] 找到匹配: StoreFront=\(storeFrontCode) -> 国家代码=\(countryCode)")
                return countryCode
            }
        }

        return ""
    }

    private func detectCountryCodeFromCookies() -> String {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return "" }

        for cookie in cookies {
            if cookie.domain.contains("apple.com") {

                let cookieString = "\(cookie.name)=\(cookie.value)"

                if cookieString.contains("storefront") || cookieString.contains("storeFront") {

                    let components = cookieString.components(separatedBy: "=")
                    if components.count > 1 {
                        let value = components[1]
                        let storeFrontCode = value.components(separatedBy: "-").first ?? value
                        return inferCountryCodeFromStoreFront(storeFrontCode)
                    }
                }
            }
        }

        return ""
    }

    private func inferCountryCodeFromEmail(_ email: String) -> String {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        print("🌍 [邮箱检测] 分析邮箱域名: \(domain)")

        if domain.hasSuffix(".cn") {
            print("🌍 [邮箱检测] 检测到.cn域名，推断为中国区")
            return "CN"
        } else if domain.hasSuffix(".jp") {
            print("🌍 [邮箱检测] 检测到.jp域名，推断为日本区")
            return "JP"
        } else if domain.hasSuffix(".kr") {
            print("🌍 [邮箱检测] 检测到.kr域名，推断为韩国区")
            return "KR"
        } else if domain.hasSuffix(".hk") {
            print("🌍 [邮箱检测] 检测到.hk域名，推断为香港区")
            return "HK"
        } else if domain.hasSuffix(".tw") {
            print("🌍 [邮箱检测] 检测到.tw域名，推断为台湾区")
            return "TW"
        } else if domain.hasSuffix(".sg") {
            print("🌍 [邮箱检测] 检测到.sg域名，推断为新加坡区")
            return "SG"
        } else if domain.hasSuffix(".au") {
            print("🌍 [邮箱检测] 检测到.au域名，推断为澳大利亚区")
            return "AU"
        } else if domain.hasSuffix(".ca") {
            print("🌍 [邮箱检测] 检测到.ca域名，推断为加拿大区")
            return "CA"
        } else if domain.hasSuffix(".uk") {
            print("🌍 [邮箱检测] 检测到.uk域名，推断为英国区")
            return "GB"
        } else if domain.hasSuffix(".de") {
            print("🌍 [邮箱检测] 检测到.de域名，推断为德国区")
            return "DE"
        } else if domain.hasSuffix(".fr") {
            print("🌍 [邮箱检测] 检测到.fr域名，推断为法国区")
            return "FR"
        }

        return "US"
    }

    private func detectStoreFront(from response: StoreAuthResponse, countryCode: String) -> String {

        if let serverStoreFront = response.accountInfo.storeFront, !serverStoreFront.isEmpty {
            print("🏪 [商店检测] 使用服务器返回的StoreFront: \(serverStoreFront)")
            return serverStoreFront
        }

        let storeFrontCode = Apple.storeFrontCodeMap[countryCode] ?? "143441"
        let generatedStoreFront = "\(storeFrontCode)-1,29"
        print("🏪 [商店检测] 根据地区代码生成StoreFront: \(generatedStoreFront)")
        return generatedStoreFront
    }

    private func loadAllAccountsFromKeychain() -> [Account] {

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess,
              let data = dataTypeRef as? Data else {
            return []
        }

        let decoder = JSONDecoder()

        if let accounts = try? decoder.decode([Account].self, from: data) {
            return accounts
        } else if let account = try? decoder.decode(Account.self, from: data) {
            return [account]
        } else {
            return []
        }
    }

    private func saveAccountToKeychain(_ account: Account) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainError
        }
    }

    private func loadAccountFromKeychain() -> Account? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess,
              let data = dataTypeRef as? Data else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(Account.self, from: data)
    }

    private func saveAllAccountsToKeychain(_ accounts: [Account]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(accounts)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainError
        }
    }

}
