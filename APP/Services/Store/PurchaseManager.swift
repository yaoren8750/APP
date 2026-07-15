import Foundation

@MainActor
class PurchaseManager: @unchecked Sendable {
    static let shared = PurchaseManager()

    private let searchManager = SearchManager.shared
    private init() {}

    func checkAppOwnership(
        appIdentifier: String,
        account: Account,
        countryCode: String = ""
    ) async -> Result<Bool, PurchaseError> {
        do {
            let trackId = try await resolveTrackId(appIdentifier: appIdentifier, countryCode: countryCode)

            do {
                let downloadResponse = try await StoreRequest.shared.download(
                    appIdentifier: trackId,
                    account: account
                )
                return .success(!downloadResponse.songList.isEmpty)
            } catch let storeError as StoreError {
                if case .licenseExpired = storeError {
                    print("🔐 [购买验证] 许可证过期，尝试 redownload 模式")
                    do {
                        let redownloadResponse = try await StoreRequest.shared.redownload(
                            appIdentifier: trackId,
                            account: account
                        )
                        return .success(!redownloadResponse.songList.isEmpty)
                    } catch {
                        return handleOwnershipError(error)
                    }
                }
                return handleOwnershipError(storeError)
            } catch {
                return handleOwnershipError(error)
            }
        } catch {
            return .failure(.appNotFound(error.localizedDescription))
        }
    }

    private func resolveTrackId(appIdentifier: String, countryCode: String) async throws -> String {
        if Int(appIdentifier) != nil {
            return appIdentifier
        }
        let trackIdResult = await searchManager.getTrackId(
            bundleIdentifier: appIdentifier,
            countryCode: countryCode,
            deviceFamily: .phone
        )
        switch trackIdResult {
        case .success(let id):
            return String(id)
        case .failure(let error):
            throw error
        }
    }

    private func handleOwnershipError(_ error: Error) -> Result<Bool, PurchaseError> {
        if let storeError = error as? StoreError {
            switch storeError {
            case .invalidLicense, .licenseExpired:
                print("🔐 [购买验证] 检测到许可证错误，用户未购买此应用")
                return .success(false)
            case .appNotAvailableInStorefront:
                print("🌍 [购买验证] 此应用在当前地区商店不可用")
                return .failure(.licenseCheckFailed("此应用在当前地区商店不可用"))
            case .tooManyRequests:
                print("⏳ [购买验证] 请求过于频繁")
                return .failure(.networkError(storeError))
            default:
                return .failure(.networkError(storeError))
            }
        }
        return .failure(.networkError(error))
    }

    func purchaseAppIfNeeded(
        appIdentifier: String,
        account: Account,
        countryCode: String = "",
        deviceFamily: DeviceFamily = .phone
    ) async -> Result<PurchaseResult, PurchaseError> {
        let ownershipResult = await checkAppOwnership(
            appIdentifier: appIdentifier,
            account: account,
            countryCode: countryCode
        )
        switch ownershipResult {
        case .success(let isOwned):
            if isOwned {
                let result = PurchaseResult(
                    trackId: appIdentifier,
                    success: true,
                    message: "应用已拥有，无需购买",
                    licenseInfo: nil
                )
                return .success(result)
            } else {
                return await performPurchase(appIdentifier: appIdentifier, account: account)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    private func performPurchase(
        appIdentifier: String,
        account: Account
    ) async -> Result<PurchaseResult, PurchaseError> {
        do {
            let _ = try await StoreRequest.shared.purchase(
                appIdentifier: String(appIdentifier),
                account: account
            )
            let result = PurchaseResult(
                trackId: appIdentifier,
                success: true,
                message: "已完成获取（零元购买）",
                licenseInfo: nil
            )
            return .success(result)
        } catch let storeError as StoreError {
            return await handlePurchaseError(storeError, appIdentifier: appIdentifier, account: account)
        } catch {
            return .failure(.networkError(error))
        }
    }

    private func handlePurchaseError(
        _ error: StoreError,
        appIdentifier: String,
        account: Account
    ) async -> Result<PurchaseResult, PurchaseError> {
        switch error {
        case .licenseExpired, .invalidLicense:
            print("🔄 [购买] 购买失败，尝试 redownload 模式")
            do {
                let redownloadResponse = try await StoreRequest.shared.redownload(
                    appIdentifier: appIdentifier,
                    account: account
                )
                if !redownloadResponse.songList.isEmpty {
                    let result = PurchaseResult(
                        trackId: appIdentifier,
                        success: true,
                        message: "已通过重新下载获取",
                        licenseInfo: nil
                    )
                    return .success(result)
                }
                return .failure(.licenseCheckFailed("无法获取应用许可证"))
            } catch {
                return .failure(.networkError(error))
            }
        case .userInteractionRequired:
            return .failure(.paymentRequired("需要在 App Store 完成一次身份验证"))
        case .paymentVerificationRequired:
            return .failure(.paymentRequired("需要验证付款信息"))
        case .termsOfServiceUpdateRequired:
            return .failure(.licenseCheckFailed("需要同意新的服务条款"))
        case .ageVerificationRequired:
            return .failure(.licenseCheckFailed("需要进行年龄验证"))
        case .storefrontChangeRequired, .appNotAvailableInStorefront:
            return .failure(.invalidCountry("此应用在当前地区商店不可用"))
        case .tooManyRequests:
            return .failure(.networkError(error))
        case .lockedAccount:
            return .failure(.licenseCheckFailed("账户已被锁定"))
        default:
            return .failure(.networkError(error))
        }
    }

}

struct PurchaseResult {
    let trackId: String
    let success: Bool
    let message: String
    let licenseInfo: LicenseInfo?
}

struct LicenseInfo {
    let licenseId: String
    let purchaseDate: Date
    let expirationDate: Date?
    let isValid: Bool
}

enum PurchaseError: LocalizedError {
    case invalidIdentifier(String)
    case appNotFound(String)
    case priceMismatch(String)
    case invalidCountry(String)
    case passwordTokenExpired(String)
    case licenseAlreadyExists(String)
    case paymentRequired(String)
    case licenseCheckFailed(String)
    case networkError(Error)
    case unknownError(String)
    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let message):
            return "无效的应用标识符: \(message)"
        case .appNotFound(let message):
            return "应用未找到: \(message)"
        case .priceMismatch(let message):
            return "价格不匹配: \(message)"
        case .invalidCountry(let message):
            return "无效的国家/地区: \(message)"
        case .passwordTokenExpired(let message):
            return "密码令牌已过期: \(message)"
        case .licenseAlreadyExists(let message):
            return "许可证已存在: \(message)"
        case .paymentRequired(let message):
            return "需要付款: \(message)"
        case .licenseCheckFailed(let message):
            return "许可证检查失败: \(message)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .unknownError(let message):
            return "未知错误: \(message)"
        }
    }
}
