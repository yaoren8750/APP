import Foundation

typealias iTunesSearchResponse = iTunesResponse

public struct StoreAppVersion: Codable, Identifiable {
    public let id: UUID
    public let versionString: String
    public let versionId: String
    public let isCurrent: Bool
    public let releaseDate: Date?

    public init(versionString: String, versionId: String, isCurrent: Bool, releaseDate: Date? = nil) {
        self.id = UUID()
        self.versionString = versionString
        self.versionId = versionId
        self.isCurrent = isCurrent
        self.releaseDate = releaseDate
    }

    public var displayName: String {
        return isCurrent ? "\(versionString) (当前版本)" : versionString
    }

    public var formattedReleaseDate: String? {
        guard let date = releaseDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct AppVersionInfo: Codable {
    let bundle_version: String
    let external_identifier: Int
    let created_at: String
}

@MainActor
public class StoreClient: @unchecked Sendable {
    public static let shared = StoreClient()
    private init() {}

    public func getAppVersions(
        trackId: String,
        account: Account,
        countryCode: String? = nil
    ) async -> Result<[StoreAppVersion], StoreError> {
        AuthenticationManager.shared.setCookies(account.cookies)
        let regionToUse = countryCode ?? account.countryCode
        print("[StoreClient] 获取应用版本，使用地区: \(regionToUse)")
        do {
            if let thirdPartyVersions = try await fetchVersionsFromThirdPartyAPI(appId: trackId), !thirdPartyVersions.isEmpty {
                print("[调试] 成功从第三方API获取版本: \(thirdPartyVersions.count) 个版本")
                return .success(thirdPartyVersions)
            }
            print("[调试] 第三方API失败、无数据或返回空数组，回退到苹果官方API")
            let result = try await StoreRequest.shared.download(
                appIdentifier: trackId,
                directoryServicesIdentifier: account.directoryServicesIdentifier,
                appVersion: nil,
                passwordToken: account.passwordToken,
                storeFront: account.storeResponse.storeFront
            )
            guard !result.songList.isEmpty else {
                return .failure(.invalidItem)
            }
            let item = result.songList[0]
            var versions: [StoreAppVersion] = []
            let currentVersion = StoreAppVersion(
                versionString: item.metadata.bundleShortVersionString,
                versionId: item.metadata.softwareVersionExternalIdentifier,
                isCurrent: true
            )
            versions.append(currentVersion)
            if let historicalVersionIds = item.metadata.softwareVersionExternalIdentifiers {
                let reversedIds = Array(historicalVersionIds.reversed())
                var versionCounter = 1
                for versionId in reversedIds {
                    let versionIdString = String(versionId)
                    if versionIdString != item.metadata.softwareVersionExternalIdentifier {
                        let historicalVersion = StoreAppVersion(
                            versionString: "历史版本 \(versionCounter)",
                            versionId: versionIdString,
                            isCurrent: false
                        )
                        versions.append(historicalVersion)
                        versionCounter += 1
                        if versionCounter > 20 { break }
                    }
                }
            }
            return .success(versions)
        } catch {
            print("[调试] getAppVersions中出错: \(error)")
            return .failure(.genericError)
        }
    }

    private func fetchVersionsFromThirdPartyAPI(appId: String) async throws -> [StoreAppVersion]? {
        let apiUrl = "https://api.timbrd.com/apple/app-version/index.php?id=\(appId)"
        guard let url = URL(string: apiUrl) else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 10.0)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            let decoder = JSONDecoder()
            let versionData = try decoder.decode([AppVersionInfo].self, from: data)
            if versionData.isEmpty { return nil }
            let versions = versionData.sorted { version1, version2 -> Bool in
                if let date1 = parseDate(version1.created_at), let date2 = parseDate(version2.created_at) {
                    return date1 > date2
                }
                return compareVersionStrings(version1.bundle_version, version2.bundle_version) > 0
            }.map { versionInfo -> StoreAppVersion in
                let isCurrent = versionInfo.bundle_version == versionData.first?.bundle_version
                let releaseDate = parseDate(versionInfo.created_at)
                return StoreAppVersion(
                    versionString: versionInfo.bundle_version,
                    versionId: String(versionInfo.external_identifier),
                    isCurrent: isCurrent,
                    releaseDate: releaseDate
                )
            }
            return versions
        } catch {
            print("[调试] 从第三方API获取数据时出错: \(error)")
            return nil
        }
    }

    private func parseDate(_ dateString: String) -> Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return dateFormatter.date(from: dateString)
    }

    private func compareVersionStrings(_ v1: String, _ v2: String) -> Int {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(components1.count, components2.count) {
            let num1 = i < components1.count ? components1[i] : 0
            let num2 = i < components2.count ? components2[i] : 0
            if num1 > num2 { return 1 }
            else if num1 < num2 { return -1 }
        }
        return 0
    }
}
