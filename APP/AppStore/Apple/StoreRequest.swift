import Foundation

private final class GUIDCache {
    static let shared = GUIDCache()
    private let lock = NSLock()
    private var cachedGUID: String?

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let g = cachedGUID, !g.isEmpty, g != "000000000000" { return g }
        let generated = generateFallbackGUID()
        cachedGUID = generated
        return generated
    }

    func set(_ guid: String) {
        lock.lock()
        defer { lock.unlock() }
        cachedGUID = guid
    }

    private func generateFallbackGUID() -> String {
        let hex = "0123456789ABCDEF"
        var out = ""
        for _ in 0..<12 { out.append(hex.randomElement()!) }
        return out
    }
}

class StoreRequestDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

@MainActor
class StoreRequest {
    static let shared = StoreRequest()
    private let session: URLSession
    private let baseURL = "https://p25-buy.itunes.apple.com"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: StoreRequestDelegate(), delegateQueue: delegateQueue)
    }

    func authenticate(
        email: String,
        password: String,
        mfa: String? = nil
    ) async throws -> StoreAuthResponse {
        let authenticator = AppleIDAuthenticator.shared
        if let mfa = mfa, !mfa.isEmpty {
            return try await authenticator.validate2FACode(mfa)
        }
        do {
            return try await authenticator.authenticate(email: email, password: password)
        } catch StoreError.codeRequired {
            throw StoreError.codeRequired
        } catch {
            throw error
        }
    }

    func authenticateWith2FA(
        code: String,
        isSMS: Bool = false,
        phoneId: String? = nil
    ) async throws -> StoreAuthResponse {
        let authenticator = AppleIDAuthenticator.shared
        return try await authenticator.validate2FACode(code)
    }

    func download(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        appVersion: String? = nil,
        passwordToken: String? = nil,
        storeFront: String? = nil
    ) async throws -> StoreDownloadResponse {
        let guid = GUIDCache.shared.get()
        let url = URL(string: "\(baseURL)/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(guid)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(getUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
        if let passwordToken = passwordToken {
            request.setValue(passwordToken, forHTTPHeaderField: "X-Token")
        }
        if let storeFront = storeFront {
            request.setValue(normalizeStoreFront(storeFront), forHTTPHeaderField: "X-Apple-Store-Front")
        }
        var body: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": appIdentifier
        ]
        if let appVersion = appVersion {
            if let versionId = Int(appVersion) {
                body["externalVersionId"] = versionId
            } else {
                body["externalVersionId"] = appVersion
            }
        }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: body,
            format: .xml,
            options: 0
        )
        request.httpBody = plistData
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StoreError.invalidResponse
        }
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] ?? [:]
        return try parseDownloadResponse(plist: plist, httpResponse: httpResponse)
    }

    func purchase(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        passwordToken: String,
        storeFront: String
    ) async throws -> StorePurchaseResponse {
        let guid = GUIDCache.shared.get()
        let url = URL(string: "https://buy.itunes.apple.com/WebObjects/MZBuy.woa/wa/buyProduct")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(getUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(normalizeStoreFront(storeFront), forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(passwordToken, forHTTPHeaderField: "X-Token")
        var body: [String: Any] = [
            "guid": guid,
            "salableAdamId": appIdentifier,
            "dsPersonId": directoryServicesIdentifier,
            "passwordToken": passwordToken,
            "price": "0",
            "pricingParameters": "STDQ",
            "productType": "C",
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "needDiv": "0",
            "origPage": "Software-\(appIdentifier)",
            "origPageLocation": "Buy"
        ]
        body["pg"] = "default"
        body["sd"] = "true"
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: body,
            format: .xml,
            options: 0
        )
        request.httpBody = plistData
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StoreError.invalidResponse
        }
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] ?? [:]
        return try parsePurchaseResponse(plist: plist, httpResponse: httpResponse)
    }

    func getUserAgent() -> String {
        return "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    }

    private func normalizeStoreFront(_ value: String) -> String {
        let digitsPrefix = value.split(separator: "-").first.map(String.init) ?? value
        return digitsPrefix.split(separator: ",").first.map(String.init) ?? digitsPrefix
    }

    private func acquireGUID() -> String {
        GUIDCache.shared.get()
    }

    func currentGUID() -> String { acquireGUID() }

    nonisolated static func setGUID(_ guid: String) {
        GUIDCache.shared.set(guid)
    }

    private func parseAuthResponse(
        plist: [String: Any],
        httpResponse: HTTPURLResponse
    ) throws -> StoreAuthResponse {
        if httpResponse.statusCode == 200 {
            let accountInfo = parseAccountInfo(from: plist)
            let passwordToken = plist["passwordToken"] as? String ?? ""
            let dsPersonId = (plist["dsPersonId"] as? String) ??
                           (plist["dsPersonID"] as? String) ??
                           (plist["dsid"] as? String) ??
                           (plist["DSID"] as? String) ??
                           (plist["directoryServicesIdentifier"] as? String) ?? ""
            let pings = plist["pings"] as? [String]
            let accountDsPersonId = accountInfo?.dsPersonId ?? ""
            let finalDsPersonId = !dsPersonId.isEmpty ? dsPersonId : accountDsPersonId
            let response = StoreAuthResponse(
                accountInfo: accountInfo ?? StoreAuthResponse.AccountInfo(
                    appleId: "",
                    address: StoreAuthResponse.AccountInfo.Address(
                        firstName: "",
                        lastName: ""
                    ),
                    dsPersonId: finalDsPersonId,
                    countryCode: nil,
                    storeFront: nil
                ),
                passwordToken: passwordToken,
                dsPersonId: finalDsPersonId,
                pings: pings
            )
            return response
        } else {
            let failureType = plist["failureType"] as? String ?? ""
            let customerMessage = plist["customerMessage"] as? String ?? ""
            if !failureType.isEmpty {
                throw StoreError.fromFailureType(failureType)
            } else if customerMessage == "MZFinance.BadLogin.Configurator_message" {
                throw StoreError.codeRequired
            } else if customerMessage.contains("AMD-Action") {
                let emptyResponse = StoreAuthResponse(
                    accountInfo: StoreAuthResponse.AccountInfo(
                        appleId: "",
                        address: StoreAuthResponse.AccountInfo.Address(
                            firstName: "",
                            lastName: ""
                        ),
                        dsPersonId: "",
                        countryCode: "",
                        storeFront: nil
                    ),
                    passwordToken: "",
                    dsPersonId: "",
                    pings: []
                )
                return emptyResponse
            } else {
                throw StoreError.unknownError
            }
        }
    }

    private func parseAccountInfo(from plist: [String: Any]) -> StoreAuthResponse.AccountInfo? {
        guard let accountInfo = plist["accountInfo"] as? [String: Any] else {
            return nil
        }
        let appleId = accountInfo["appleId"] as? String ?? ""
        let address = accountInfo["address"] as? [String: Any]
        let firstName = address?["firstName"] as? String ?? ""
        let lastName = address?["lastName"] as? String ?? ""
        let dsPersonId = (accountInfo["dsPersonId"] as? String) ??
                        (accountInfo["dsPersonID"] as? String) ??
                        (accountInfo["dsid"] as? String) ??
                        (accountInfo["DSID"] as? String) ??
                        (accountInfo["directoryServicesIdentifier"] as? String) ?? ""
        let countryCode = detectCountryCodeFromAccountInfo(accountInfo)
        let storeFront = detectStoreFrontFromAccountInfo(accountInfo)
        return StoreAuthResponse.AccountInfo(
            appleId: appleId,
            address: StoreAuthResponse.AccountInfo.Address(
                firstName: firstName,
                lastName: lastName
            ),
            dsPersonId: dsPersonId,
            countryCode: countryCode,
            storeFront: storeFront
        )
    }

    private func detectCountryCodeFromAccountInfo(_ accountInfo: [String: Any]) -> String? {
        if let countryCode = accountInfo["countryCode"] as? String, !countryCode.isEmpty {
            return countryCode
        }
        if let storeFront = accountInfo["storeFront"] as? String, !storeFront.isEmpty {
            return inferCountryCodeFromStoreFront(storeFront)
        }
        let regionFields = ["region", "country", "locale", "territory", "market"]
        for field in regionFields {
            if let value = accountInfo[field] as? String, !value.isEmpty {
                return value.uppercased()
            }
        }
        return nil
    }

    private func detectStoreFrontFromAccountInfo(_ accountInfo: [String: Any]) -> String? {
        if let storeFront = accountInfo["storeFront"] as? String, !storeFront.isEmpty {
            return storeFront
        }
        let storeFields = ["storefront", "storeFront", "store_front", "marketId", "market_id"]
        for field in storeFields {
            if let value = accountInfo[field] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func inferCountryCodeFromStoreFront(_ storeFront: String) -> String {
        let storeFrontCode = storeFront.components(separatedBy: "-").first ?? storeFront
        for (countryCode, code) in Apple.storeFrontCodeMap {
            if code == storeFrontCode {
                return countryCode
            }
        }
        return ""
    }

    private func parseDownloadResponse(
        plist: [String: Any],
        httpResponse: HTTPURLResponse
    ) throws -> StoreDownloadResponse {
        if httpResponse.statusCode == 200 {
            var songList: [StoreItem] = []
            if let songs = plist["songList"] as? [[String: Any]] {
                songList = songs.compactMap { parseStoreItem(from: $0) }
            }
            if songList.isEmpty {
                throw StoreError.invalidLicense
            }
            let dsPersonId = plist["dsPersonID"] as? String ?? ""
            let jingleDocType = plist["jingleDocType"] as? String
            let jingleAction = plist["jingleAction"] as? String
            let pings = plist["pings"] as? [String]
            return StoreDownloadResponse(
                songList: songList,
                dsPersonId: dsPersonId,
                jingleDocType: jingleDocType,
                jingleAction: jingleAction,
                pings: pings
            )
        } else {
            let failureType = plist["failureType"] as? String ?? "unknownError"
            throw StoreError.fromFailureType(failureType)
        }
    }

    private func parseStoreItem(from dict: [String: Any]) -> StoreItem? {
        guard let url = dict["URL"] as? String,
              let md5 = dict["md5"] as? String else {
            return nil
        }
        var sinfs: [SinfInfo] = []
        if let sinfsArray = dict["sinfs"] as? [[String: Any]] {
            sinfs = sinfsArray.compactMap { sinfDict in
                guard let id = sinfDict["id"] as? Int,
                      let sinfString = sinfDict["sinf"] as? String else {
                    return nil
                }
                return SinfInfo(id: id, sinf: sinfString)
            }
        }
        var metadata: AppMetadata
        if let metadataDict = dict["metadata"] as? [String: Any] {
            let bundleId = metadataDict["softwareVersionBundleId"] as? String ??
                          metadataDict["bundle-identifier"] as? String ?? ""
            let bundleDisplayName = metadataDict["bundleDisplayName"] as? String ??
                                   metadataDict["itemName"] as? String ??
                                   metadataDict["item-name"] as? String ?? ""
            let bundleShortVersionString = metadataDict["bundleShortVersionString"] as? String ??
                                          metadataDict["bundle-short-version-string"] as? String ?? ""
            let softwareVersionExternalIdentifier = String(metadataDict["softwareVersionExternalIdentifier"] as? Int ?? 0)
            let softwareVersionExternalIdentifiers = metadataDict["softwareVersionExternalIdentifiers"] as? [Int]
            metadata = AppMetadata(
                bundleId: bundleId,
                bundleDisplayName: bundleDisplayName,
                bundleShortVersionString: bundleShortVersionString,
                softwareVersionExternalIdentifier: softwareVersionExternalIdentifier,
                softwareVersionExternalIdentifiers: softwareVersionExternalIdentifiers
            )
        } else {
            metadata = AppMetadata(
                bundleId: "",
                bundleDisplayName: "",
                bundleShortVersionString: "",
                softwareVersionExternalIdentifier: "",
                softwareVersionExternalIdentifiers: nil
            )
        }
        return StoreItem(
            url: url,
            md5: md5,
            sinfs: sinfs,
            metadata: metadata
        )
    }

    private func parsePurchaseResponse(
        plist: [String: Any],
        httpResponse: HTTPURLResponse
    ) throws -> StorePurchaseResponse {
        if httpResponse.statusCode == 200 {
            if plist["dialog"] != nil || plist["failureType"] != nil {
                throw StoreError.userInteractionRequired
            }
            let dsPersonId = plist["dsPersonID"] as? String ?? ""
            let jingleDocType = plist["jingleDocType"] as? String
            let jingleAction = plist["jingleAction"] as? String
            let pings = plist["pings"] as? [String]
            return StorePurchaseResponse(
                dsPersonId: dsPersonId,
                jingleDocType: jingleDocType,
                jingleAction: jingleAction,
                pings: pings
            )
        } else {
            throw StoreError.fromFailureType(plist["failureType"] as? String ?? "unknownError")
        }
    }
}

public enum StoreError: Error, LocalizedError, Equatable {
    case networkError(Error)
    case invalidResponse
    case authenticationFailed
    case accountNotFound
    case invalidCredentials
    case serverError(Int)
    case unknown(String)
    case genericError
    case invalidItem
    case invalidLicense
    case unknownError
    case codeRequired
    case lockedAccount
    case keychainError
    case userInteractionRequired
    case invalidVerificationCode

    public var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .authenticationFailed:
            return "Authentication failed"
        case .accountNotFound:
            return "Account not found"
        case .invalidCredentials:
            return "Invalid credentials"
        case .serverError(let code):
            return "Server error: \(code)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        case .genericError:
            return "Generic error occurred"
        case .invalidItem:
            return "Invalid item"
        case .invalidLicense:
            return "Invalid license"
        case .codeRequired:
            return "Verification code required"
        case .lockedAccount:
            return "Account is locked"
        case .keychainError:
            return "Keychain error occurred"
        case .userInteractionRequired:
            return "需要在 App Store 完成一次身份验证/获取"
        case .invalidVerificationCode:
            return "验证码错误，请检查后重试"
        case .unknownError:
            return "Unknown error occurred"
        }
    }

    public static func fromFailureType(_ failureType: String) -> StoreError {
        switch failureType {
        case "authenticationFailed":
            return .authenticationFailed
        case "accountNotFound":
            return .accountNotFound
        case "invalidCredentials":
            return .invalidCredentials
        case "codeRequired":
            return .codeRequired
        case "lockedAccount":
            return .lockedAccount
        case "invalidVerificationCode":
            return .invalidVerificationCode
        default:
            return .unknownError
        }
    }

    public static func == (lhs: StoreError, rhs: StoreError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse),
             (.authenticationFailed, .authenticationFailed),
             (.accountNotFound, .accountNotFound),
             (.invalidCredentials, .invalidCredentials),
             (.genericError, .genericError),
             (.invalidItem, .invalidItem),
             (.invalidLicense, .invalidLicense),
             (.unknownError, .unknownError),
             (.codeRequired, .codeRequired),
             (.lockedAccount, .lockedAccount),
             (.keychainError, .keychainError),
             (.userInteractionRequired, .userInteractionRequired),
             (.invalidVerificationCode, .invalidVerificationCode):
            return true
        case (.networkError(let lhsError), .networkError(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        case (.serverError(let lhsCode), .serverError(let rhsCode)):
            return lhsCode == rhsCode
        case (.unknown(let lhsMessage), .unknown(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

struct StoreAuthResponse: Codable {
    let accountInfo: AccountInfo
    let passwordToken: String
    let dsPersonId: String
    let pings: [String]?

    struct AccountInfo: Codable {
        let appleId: String
        let address: Address
        let dsPersonId: String
        let countryCode: String?
        let storeFront: String?

        struct Address: Codable {
            let firstName: String
            let lastName: String
        }
    }
}

struct StoreDownloadResponse: Codable {
    let songList: [StoreItem]
    let dsPersonId: String
    let jingleDocType: String?
    let jingleAction: String?
    let pings: [String]?
}

struct StorePurchaseResponse: Codable {
    let dsPersonId: String
    let jingleDocType: String?
    let jingleAction: String?
    let pings: [String]?
}

struct StoreItem: Codable {
    let url: String
    let md5: String
    let sinfs: [SinfInfo]
    let metadata: AppMetadata
}

struct AppMetadata: Codable {
    let bundleId: String
    let bundleDisplayName: String
    let bundleShortVersionString: String
    let softwareVersionExternalIdentifier: String
    let softwareVersionExternalIdentifiers: [Int]?

    enum CodingKeys: String, CodingKey {
        case bundleId = "softwareVersionBundleId"
        case bundleDisplayName
        case bundleShortVersionString
        case softwareVersionExternalIdentifier
        case softwareVersionExternalIdentifiers
    }
}

struct SinfInfo: Codable {
    let id: Int
    let sinf: String
}
