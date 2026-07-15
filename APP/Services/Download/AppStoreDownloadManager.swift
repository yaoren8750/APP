import Foundation
import CryptoKit
import SwiftUI
import UIKit

extension AppStoreDownloadManager {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("📱 [后台会话] 所有任务已完成")

        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            if let completionHandler = appDelegate.backgroundSessionCompletionHandler {

                DispatchQueue.main.async {
                    print("✅ [后台会话] 调用完成处理器")
                    completionHandler()
                    appDelegate.backgroundSessionCompletionHandler = nil
                }
            }
        }
    }
}

struct DownloadStoreItem: Codable {
    let url: String
    let md5: String
    let sinfs: [DownloadSinfInfo]
    let metadata: DownloadAppMetadata
}

struct DownloadAppMetadata: Codable {
    let bundleId: String
    let bundleDisplayName: String
    let bundleShortVersionString: String
    let softwareVersionExternalIdentifier: String
    let softwareVersionExternalIdentifiers: [Int]?
}

struct DownloadSinfInfo: Codable {
    let id: Int
    let sinf: String
}

@MainActor
class IPAProcessor: @unchecked Sendable {
    static let shared = IPAProcessor()

    private init() {}

    func processIPA(
        at ipaPath: URL,
        withSinfs sinfs: [Any],
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        print("🔧 [IPA处理器] 开始处理IPA文件: \(ipaPath.path)")
        print("🔧 [IPA处理器] 签名信息数量: \(sinfs.count)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let startTime = Date()
                let processedIPA = try self.processIPAFast(at: ipaPath, withSinfs: sinfs)
                let elapsed = Date().timeIntervalSince(startTime)
                print("⚡ [IPA处理器] 快速处理完成，耗时: \(String(format: "%.3f", elapsed))秒")
                DispatchQueue.main.async {
                    completion(.success(processedIPA))
                }
            } catch {
                print("❌ [IPA处理器] IPA处理失败: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }



    nonisolated private func processIPAFast(at ipaPath: URL, withSinfs sinfs: [Any]) throws -> URL {
        print("⚡ [IPA处理器] 开始快速增量处理")

        let ipaData = try Data(contentsOf: ipaPath)

        guard let eocd = FastZipArchive.findEndOfCentralDirectory(in: ipaData) else {
            throw NSError(domain: "IPAProcessing", code: 10, userInfo: [NSLocalizedDescriptionKey: "无效的IPA文件，未找到中央目录"])
        }

        let entries = try FastZipArchive.readCentralDirectory(from: ipaData, eocd: eocd)
        print("📦 [IPA处理器] IPA包含 \(entries.count) 个文件")

        let appFolderName = findAppFolderName(in: entries)
        guard let appName = appFolderName else {
            throw NSError(domain: "IPAProcessing", code: 11, userInfo: [NSLocalizedDescriptionKey: "未找到Payload中的.app文件夹"])
        }
        print("📱 [IPA处理器] 应用文件夹: \(appName)")

        let sinfFiles = generateSinfFiles(sinfs: sinfs, appName: appName)
        let metadataPlist = generateiTunesMetadataPlist(
            appName: appName,
            entries: entries,
            ipaData: ipaData
        )

        var filesToAdd: [(path: String, data: Data)] = []

        for (index, sinfData) in sinfFiles.enumerated() {
            let sinfPath = "Payload/\(appName).app/SC_Info/\(appName).sinf"
            if index == 0 {
                filesToAdd.append((sinfPath, sinfData))
            } else {
                let altPath = "Payload/\(appName).app/SC_Info/\(appName)_\(index).sinf"
                filesToAdd.append((altPath, sinfData))
            }
        }

        filesToAdd.append(("iTunesMetadata.plist", metadataPlist))

        print("🔧 [IPA处理器] 将增量添加 \(filesToAdd.count) 个文件")

        let success = FastZipArchive.shared.addFiles(
            toZipAtPath: ipaPath.path,
            files: filesToAdd
        )

        guard success else {
            throw NSError(domain: "IPAProcessing", code: 12, userInfo: [NSLocalizedDescriptionKey: "增量添加文件失败"])
        }

        print("✅ [IPA处理器] 快速增量处理完成")
        return ipaPath
    }

    nonisolated private func findAppFolderName(in entries: [FastZipArchive.CentralDirectoryEntry]) -> String? {
        for entry in entries {
            let path = entry.filename
            if path.hasPrefix("Payload/") && path.hasSuffix(".app/") {
                let name = path
                    .replacingOccurrences(of: "Payload/", with: "")
                    .replacingOccurrences(of: ".app/", with: "")
                return name
            }
        }
        for entry in entries {
            let path = entry.filename
            if path.hasPrefix("Payload/") && path.contains(".app/") {
                if let range = path.range(of: "Payload/"),
                   let endRange = path.range(of: ".app/") {
                    let name = String(path[range.upperBound..<endRange.lowerBound])
                    return name
                }
            }
        }
        return nil
    }

    nonisolated private func generateSinfFiles(sinfs: [Any], appName: String) -> [Data] {
        var result: [Data] = []

        if sinfs.isEmpty {
            let defaultSinf = createDefaultSinfData(for: appName)
            result.append(defaultSinf)
            print("⚠️ [IPA处理器] 无sinf数据，使用默认sinf")
            return result
        }

        for sinf in sinfs {
            if let sinfInfo = sinf as? DownloadSinfInfo {
                if let data = Data(base64Encoded: sinfInfo.sinf) {
                    result.append(data)
                    print("✅ [IPA处理器] 解析sinf(ID:\(sinfInfo.id)): \(data.count)字节")
                }
            } else if let sinfDict = sinf as? [String: Any],
                      let sinfString = sinfDict["sinf"] as? String,
                      let data = Data(base64Encoded: sinfString) {
                result.append(data)
                print("✅ [IPA处理器] 解析sinf(字典): \(data.count)字节")
            }
        }

        if result.isEmpty {
            let defaultSinf = createDefaultSinfData(for: appName)
            result.append(defaultSinf)
            print("⚠️ [IPA处理器] 所有sinf解析失败，使用默认sinf")
        }

        return result
    }

    nonisolated private func generateiTunesMetadataPlist(
        appName: String,
        entries: [FastZipArchive.CentralDirectoryEntry],
        ipaData: Data
    ) -> Data {
        var bundleId = "com.unknown.app"
        var displayName = appName
        var version = "1.0"

        let infoPlistPath = "Payload/\(appName).app/Info.plist"

        for entry in entries {
            if entry.filename == infoPlistPath {
                do {
                    let plistData = try FastZipArchive.extractSingleEntry(
                        from: ipaData,
                        entry: entry
                    )
                    if let plist = try PropertyListSerialization.propertyList(
                        from: plistData,
                        options: [],
                        format: nil
                    ) as? [String: Any] {
                        bundleId = plist["CFBundleIdentifier"] as? String ?? bundleId
                        displayName = plist["CFBundleDisplayName"] as? String ??
                                     plist["CFBundleName"] as? String ?? displayName
                        version = plist["CFBundleVersion"] as? String ?? version
                    }
                } catch {
                    print("⚠️ [IPA处理器] 读取Info.plist失败: \(error)")
                }
                break
            }
        }

        let metadataDict: [String: Any] = [
            "appleId": bundleId,
            "artistId": 0,
            "artistName": "Unknown Developer",
            "bundleId": bundleId,
            "bundleVersion": version,
            "copyright": "Copyright",
            "drmVersionNumber": 0,
            "fileExtension": "ipa",
            "fileName": "\(appName).app",
            "genre": "Productivity",
            "genreId": 6007,
            "itemId": 0,
            "itemName": displayName,
            "kind": "software",
            "playlistName": "iOS Apps",
            "price": 0.0,
            "priceDisplay": "Free",
            "rating": "4+",
            "releaseDate": "2025-01-01T00:00:00Z",
            "s": 143441,
            "softwareIcon57x57URL": "",
            "softwareIconNeedsShine": false,
            "softwareSupportedDeviceIds": [1, 2],
            "softwareVersionBundleId": bundleId,
            "softwareVersionExternalIdentifier": 0,
            "softwareVersionExternalIdentifiers": [],
            "subgenres": [],
            "vendorId": 0,
            "versionRestrictions": 0
        ]

        if let plistData = try? PropertyListSerialization.data(
            fromPropertyList: metadataDict,
            format: .xml,
            options: 0
        ) {
            return plistData
        }

        return Data()
    }

    nonisolated private func createDefaultSinfData(for appName: String) -> Data {
        var sinfData = Data()

        let header = "SINF".data(using: .utf8) ?? Data()
        sinfData.append(header)

        let version: UInt32 = 1
        var versionBytes = version
        sinfData.append(Data(bytes: &versionBytes, count: MemoryLayout<UInt32>.size))

        if let appNameData = appName.data(using: .utf8) {
            let nameLength: UInt32 = UInt32(appNameData.count)
            var nameLengthBytes = nameLength
            sinfData.append(Data(bytes: &nameLengthBytes, count: MemoryLayout<UInt32>.size))
            sinfData.append(appNameData)
        }

        let timestamp: UInt64 = UInt64(Date().timeIntervalSince1970)
        var timestampBytes = timestamp
        sinfData.append(Data(bytes: &timestampBytes, count: MemoryLayout<UInt64>.size))

        let checksum = sinfData.reduce(0) { $0 ^ $1 }
        var checksumBytes = checksum
        sinfData.append(Data(bytes: &checksumBytes, count: MemoryLayout<UInt8>.size))

        return sinfData
    }
}

class AppStoreDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = AppStoreDownloadManager()
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var progressHandlers: [String: (DownloadProgress) -> Void] = [:]
    private var completionHandlers: [String: (Result<DownloadResult, DownloadError>) -> Void] = [:]
    private var downloadStartTimes: [String: Date] = [:]
    private var lastProgressUpdate: [String: (bytes: Int64, time: Date)] = [:]
    private var lastUIUpdate: [String: Date] = [:]
    private var downloadDestinations: [String: URL] = [:]
    private var downloadStoreItems: [String: DownloadStoreItem] = [:]
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.app.appstoredownload.session"
        )
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.networkServiceType = .default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var resumeDataStore: [String: Data] = [:]
    private var persistedContexts: [String: DownloadContext] = [:]
    
    private struct DownloadContext: Codable {
        let downloadId: String
        let destinationPath: String
        let storeItem: DownloadStoreItem
        let bytesDownloaded: Int64
        let totalBytes: Int64
        let resumeDataPath: String?
    }
    
    private override init() {
        super.init()
        loadPersistedContexts()
    }
    
    private func loadPersistedContexts() {
        guard let data = UserDefaults.standard.data(forKey: "DownloadContexts") else { return }
        do {
            persistedContexts = try JSONDecoder().decode([String: DownloadContext].self, from: data)
            print("💾 [下载上下文] 已恢复 \(persistedContexts.count) 个下载上下文")
        } catch {
            print("❌ [下载上下文] 恢复失败: \(error)")
        }
    }
    
    private func savePersistedContexts() {
        do {
            let data = try JSONEncoder().encode(persistedContexts)
            UserDefaults.standard.set(data, forKey: "DownloadContexts")
        } catch {
            print("❌ [下载上下文] 保存失败: \(error)")
        }
    }
    
    private func persistContext(for downloadId: String, bytesDownloaded: Int64 = 0, totalBytes: Int64 = 0) {
        guard let destination = downloadDestinations[downloadId],
              let storeItem = downloadStoreItems[downloadId] else { return }

        var resumeDataPath: String? = nil
        if let resumeData = resumeDataStore[downloadId] {
            resumeDataPath = saveResumeData(resumeData, for: downloadId)
        }

        let context = DownloadContext(
            downloadId: downloadId,
            destinationPath: destination.path,
            storeItem: storeItem,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            resumeDataPath: resumeDataPath
        )
        persistedContexts[downloadId] = context
        savePersistedContexts()
    }

    private func resumeDataPath(for downloadId: String) -> URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resumeDir = documentsDir.appendingPathComponent("ResumeData", isDirectory: true)
        try? FileManager.default.createDirectory(at: resumeDir, withIntermediateDirectories: true)
        return resumeDir.appendingPathComponent("\(downloadId).resume")
    }

    private func saveResumeData(_ data: Data, for downloadId: String) -> String {
        let path = resumeDataPath(for: downloadId)
        do {
            try data.write(to: path)
            return path.path
        } catch {
            print("❌ [断点续传] 保存续传数据失败: \(error.localizedDescription)")
            return path.path
        }
    }

    private func loadResumeData(for downloadId: String) -> Data? {
        let path = resumeDataPath(for: downloadId)
        guard let data = try? Data(contentsOf: path) else {
            return nil
        }
        return data
    }

    private func deleteResumeData(for downloadId: String) {
        let path = resumeDataPath(for: downloadId)
        try? FileManager.default.removeItem(at: path)
    }

    private func checkPartialFile(for downloadId: String) -> Int64? {
        guard let destinationURL = downloadDestinations[downloadId] else { return nil }
        let tempPath = destinationURL.path + ".download"
        guard FileManager.default.fileExists(atPath: tempPath) else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: tempPath)
            return attrs[.size] as? Int64
        } catch {
            return nil
        }
    }

    private func verifyDownloadedFile(downloadId: String, fileURL: URL, expectedMD5: String) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("❌ [文件校验] 文件不存在: \(fileURL.path)")
            return false
        }

        print("🔍 [文件校验] 开始校验文件 MD5...")
        let isValid = verifyFileIntegrity(fileURL: fileURL, expectedMD5: expectedMD5)
        if isValid {
            print("✅ [文件校验] MD5 校验通过")
        } else {
            print("❌ [文件校验] MD5 校验失败")
        }
        return isValid
    }

    private func removePersistedContext(for downloadId: String) {
        persistedContexts.removeValue(forKey: downloadId)
        deleteResumeData(for: downloadId)
        savePersistedContexts()
    }
    
    func restoreBackgroundTasks(
        progressHandler: @escaping @Sendable (String, DownloadProgress) -> Void,
        completion: @escaping @Sendable (String, Result<DownloadResult, DownloadError>) -> Void
    ) {
        Task { @MainActor in
            let tasks = await urlSession.allTasks
            var restoredCount = 0
            
            for task in tasks {
                guard let downloadTask = task as? URLSessionDownloadTask,
                      let downloadId = downloadTask.taskDescription,
                      !downloadId.isEmpty else { continue }
                
                guard let context = persistedContexts[downloadId] else {
                    print("⚠️ [后台恢复] 任务 \(downloadId) 没有持久化上下文，跳过")
                    continue
                }
                
                downloadTasks[downloadId] = downloadTask
                downloadDestinations[downloadId] = URL(fileURLWithPath: context.destinationPath)
                downloadStoreItems[downloadId] = context.storeItem
                downloadStartTimes[downloadId] = Date()
                
                progressHandlers[downloadId] = { progress in
                    progressHandler(downloadId, progress)
                }
                completionHandlers[downloadId] = { result in
                    completion(downloadId, result)
                }
                
                restoredCount += 1
                print("✅ [后台恢复] 已恢复任务: \(downloadId)")
            }
            
            print("✅ [后台恢复] 共恢复 \(restoredCount) 个后台下载任务")
        }
    }

    @MainActor
    func downloadApp(
        appIdentifier: String,
        account: Account,
        destinationURL: URL,
        appVersion: String? = nil,
        downloadId: String? = nil,
        progressHandler: @escaping @Sendable (DownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<DownloadResult, DownloadError>) -> Void
    ) {
        let downloadId = downloadId ?? UUID().uuidString
        print("📥 [下载管理器] 开始下载应用: \(appIdentifier)")
        print("📥 [下载管理器] 下载ID: \(downloadId)")
        print("📥 [下载管理器] 目标路径: \(destinationURL.path)")
        print("📥 [下载管理器] 应用版本: \(appVersion ?? "最新版本")")
        print("📥 [下载管理器] 账户信息: \(account.email)")
        Task { @MainActor in
            do {
                print("🔍 [下载管理器] 正在获取下载信息...")

                let dsPersonId = account.dsPersonId
                let passwordToken = account.passwordToken
                let storeFront = account.storeResponse.storeFront

                print("🔍 [账户信息] dsPersonId: \(dsPersonId)")
                print("🔍 [账户信息] passwordToken: \(passwordToken.isEmpty ? "空" : "已获取")")
                print("🔍 [账户信息] storeFront: \(storeFront)")

                let plistResponse = try await downloadFromStoreAPI(
                    appIdentifier: appIdentifier,
                    directoryServicesIdentifier: dsPersonId,
                    appVersion: appVersion,
                    passwordToken: passwordToken,
                    storeFront: storeFront
                )

                var downloadStoreItem: DownloadStoreItem?

                if let songList = plistResponse["songList"] as? [[String: Any]], !songList.isEmpty {
                    let firstSongItem = songList[0]
                    print("✅ [下载管理器] 成功获取下载信息")
                    print("   - 下载URL: \(firstSongItem["URL"] as? String ?? "未知")")
                    print("   - MD5: \(firstSongItem["md5"] as? String ?? "未知")")

                    if let sinfs = firstSongItem["sinfs"] as? [[String: Any]] {
                        print("   - 真实Sinf数量: \(sinfs.count)")
                        for (index, sinf) in sinfs.enumerated() {
                            if let sinfData = sinf["sinf"] as? String {
                                print("   - Sinf \(index + 1): 长度 \(sinfData.count) 字符 (真实数据)")
                            }
                        }
                    } else {
                        print("   - 警告: 没有找到 sinf 数据")
                    }

                    downloadStoreItem = convertToDownloadStoreItem(from: firstSongItem)
                } else {

                    print("⚠️ [下载管理器] songList为空，用户可能未购买此应用")

                    if let failureType = plistResponse["failureType"] as? String,
                       let customerMessage = plistResponse["customerMessage"] as? String {
                        print("⚠️ [下载管理器] 响应包含错误: \(failureType) - \(customerMessage)")
                    }

                    let error: DownloadError = .licenseError("应用未购买，请先前往App Store购买")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }

                guard let storeItem = downloadStoreItem else {
                    let error: DownloadError = .unknownError("无法创建下载项")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }

                await startFileDownload(
                    downloadId: downloadId,
                    storeItem: storeItem,
                    destinationURL: destinationURL,
                    progressHandler: progressHandler,
                    completion: completion
                )
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.networkError(error)))
                }
            }
        }
    }

    private func convertToDownloadStoreItem(from storeItem: Any) -> DownloadStoreItem {
        print("🔍 [转换开始] 开始解析StoreItem数据")
        print("🔍 [转换开始] StoreItem类型: \(type(of: storeItem))")

        if let dict = storeItem as? [String: Any] {
            print("🔍 [转换开始] 检测到字典类型，直接访问键值")

            let url = dict["URL"] as? String ?? ""
            let md5 = dict["md5"] as? String ?? ""

            print("🔍 [转换开始] 从字典获取:")
            print("   - URL: \(url.isEmpty ? "空" : "已获取(\(url.count)字符)")")
            print("   - MD5: \(md5.isEmpty ? "空" : "已获取(\(md5.count)字符)")")

            var bundleId = "unknown"
            var bundleDisplayName = "Unknown App"
            var bundleShortVersionString = "1.0"
            var softwareVersionExternalIdentifier = "0"
            var softwareVersionExternalIdentifiers: [Int] = []

            if let metadata = dict["metadata"] as? [String: Any] {
                bundleId = metadata["softwareVersionBundleId"] as? String ?? "unknown"
                bundleDisplayName = metadata["bundleDisplayName"] as? String ?? "Unknown App"
                bundleShortVersionString = metadata["bundleShortVersionString"] as? String ?? "1.0"
                if let extId = metadata["softwareVersionExternalIdentifier"] as? Int {
                    softwareVersionExternalIdentifier = String(extId)
                }
                softwareVersionExternalIdentifiers = metadata["softwareVersionExternalIdentifiers"] as? [Int] ?? []

                print("🔍 [转换开始] 从metadata获取:")
                print("   - Bundle ID: \(bundleId)")
                print("   - Display Name: \(bundleDisplayName)")
                print("   - Version: \(bundleShortVersionString)")
                print("   - External ID: \(softwareVersionExternalIdentifier)")
            }

            var sinfs: [DownloadSinfInfo] = []
            if let sinfsArray = dict["sinfs"] as? [[String: Any]] {
                print("🔍 [转换开始] 发现sinfs数组，长度: \(sinfsArray.count)")

                for (index, sinfDict) in sinfsArray.enumerated() {
                    print("🔍 [转换开始] 解析 Sinf \(index + 1):")

                    let sinfId = sinfDict["id"] as? Int ?? index
                    print("   - ID: \(sinfId)")

                    if let sinfData = sinfDict["sinf"] {
                        print("   - Sinf 数据类型: \(type(of: sinfData))")

                        var finalSinfData: String = ""

                        if let stringData = sinfData as? String {
                            finalSinfData = stringData
                            print("   - 字符串类型 sinf 数据，长度: \(stringData.count)")
                        } else if let dataData = sinfData as? Data {
                            finalSinfData = dataData.base64EncodedString()
                            print("   - Data 类型 sinf 数据，转换为 base64，长度: \(finalSinfData.count)")
                        } else {

                            finalSinfData = "\(sinfData)"
                            print("   - 其他类型 sinf 数据，转换为字符串，长度: \(finalSinfData.count)")
                        }

                        if !finalSinfData.isEmpty && finalSinfData.count > 10 {
                            let sinfInfo = DownloadSinfInfo(
                                id: sinfId,
                                sinf: finalSinfData
                            )
                            sinfs.append(sinfInfo)
                            print("✅ [转换开始] 成功添加 Sinf \(index + 1)，ID: \(sinfId)，数据长度: \(finalSinfData.count)")
                        } else {
                            print("⚠️ [转换开始] Sinf \(index + 1) 数据无效，跳过")
                        }
                    } else {
                        print("⚠️ [转换开始] Sinf \(index + 1) 没有 sinf 字段")
                    }
                }
            } else {
                print("⚠️ [转换开始] 没有找到 sinfs 数组或格式错误")
            }

            guard !url.isEmpty && !md5.isEmpty else {
                print("❌ [转换失败] 无法获取URL或MD5")
                print("🔍 [转换开始] 字典内容: \(dict)")
                return createDefaultDownloadStoreItem()
            }

            let downloadMetadata = DownloadAppMetadata(
                bundleId: bundleId,
                bundleDisplayName: bundleDisplayName,
                bundleShortVersionString: bundleShortVersionString,
                softwareVersionExternalIdentifier: softwareVersionExternalIdentifier,
                softwareVersionExternalIdentifiers: softwareVersionExternalIdentifiers
            )

            print("✅ [转换成功] 解析到以下数据:")
            print("   - URL: \(url)")
            print("   - MD5: \(md5)")
            print("   - Bundle ID: \(bundleId)")
            print("   - Display Name: \(bundleDisplayName)")
            print("   - 真实sinf数量: \(sinfs.count)")

            print("✅ [转换完成] 成功创建DownloadStoreItem，包含真实的 Apple ID 签名数据")
            return DownloadStoreItem(
                url: url,
                md5: md5,
                sinfs: sinfs,
                metadata: downloadMetadata
            )
        } else {
            print("❌ [转换失败] StoreItem不是字典类型")
            return createDefaultDownloadStoreItem()
        }
    }

    private func createDefaultDownloadStoreItem() -> DownloadStoreItem {
        return DownloadStoreItem(
            url: "",
            md5: "",
            sinfs: [],
            metadata: DownloadAppMetadata(
                bundleId: "unknown",
                bundleDisplayName: "Unknown App",
                bundleShortVersionString: "1.0",
                softwareVersionExternalIdentifier: "0",
                softwareVersionExternalIdentifiers: []
            )
        )
    }

    private func startFileDownload(
        downloadId: String,
        storeItem: DownloadStoreItem,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (DownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<DownloadResult, DownloadError>) -> Void
    ) async {
        guard let downloadURL = URL(string: storeItem.url) else {
            DispatchQueue.main.async {
                completion(.failure(.unknownError("无效的下载URL: \(storeItem.url)")))
            }
            return
        }
        print("🚀 [下载开始] URL: \(downloadURL.absoluteString)")
        print("🚀 [下载开始] 任务ID: \(downloadId)")
        var request = URLRequest(url: downloadURL)

        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let downloadTask: URLSessionDownloadTask

        if let resumeData = resumeDataStore[downloadId] {
            downloadTask = urlSession.downloadTask(withResumeData: resumeData)
            resumeDataStore.removeValue(forKey: downloadId)
            print("🔄 [下载恢复] 使用内存中的断点续传数据恢复下载")
        } else if let savedResumeData = loadResumeData(for: downloadId) {
            downloadTask = urlSession.downloadTask(withResumeData: savedResumeData)
            print("🔄 [下载恢复] 使用磁盘中的断点续传数据恢复下载")
        } else {
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            downloadTask = urlSession.downloadTask(with: request)
        }

        downloadTask.taskDescription = downloadId

        downloadStartTimes[downloadId] = Date()
        downloadTasks[downloadId] = downloadTask
        progressHandlers[downloadId] = progressHandler

        downloadDestinations[downloadId] = destinationURL
        downloadStoreItems[downloadId] = storeItem
        completionHandlers[downloadId] = completion
        
        persistContext(for: downloadId)
        
        print("📥 [下载任务] ID: \(downloadId) 已创建并启动")
        downloadTask.resume()
    }

    private func verifyFileIntegrity(fileURL: URL, expectedMD5: String) -> Bool {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            return false
        }
        let digest = Insecure.MD5.hash(data: fileData)
        let calculatedMD5 = digest.map { String(format: "%02hhx", $0) }.joined()
        return calculatedMD5.lowercased() == expectedMD5.lowercased()
    }

    func pauseDownload(downloadId: String) {
        guard let task = downloadTasks[downloadId] else {
            print("⏸️ [暂停下载] 未找到任务: \(downloadId)")
            return
        }
        task.suspend()
        print("⏸️ [暂停下载] 已暂停: \(downloadId)")
    }

    func resumeDownload(downloadId: String) {
        guard let task = downloadTasks[downloadId] else {
            print("▶️ [恢复下载] 未找到任务: \(downloadId)")
            return
        }
        task.resume()
        print("▶️ [恢复下载] 已恢复: \(downloadId)")
    }

    func cancelDownload(downloadId: String) {
        guard let task = downloadTasks[downloadId] else {
            print("🚫 [取消下载] 未找到任务: \(downloadId)")
            return
        }
        task.cancel()
        print("🚫 [取消下载] 已取消: \(downloadId)")
    }

    var activeDownloadIds: Set<String> {
        get async {
            let tasks = await urlSession.allTasks
            let ids = tasks.compactMap { task -> String? in
                guard let desc = task.taskDescription, !desc.isEmpty else { return nil }
                return desc
            }
            var result = Set(ids)
            result.formUnion(downloadTasks.keys)
            return result
        }
    }
    
    func hasActiveDownload(for downloadId: String) -> Bool {
        downloadTasks[downloadId] != nil
    }

    private func cleanupDownload(downloadId: String) {
        downloadTasks.removeValue(forKey: downloadId)
        progressHandlers.removeValue(forKey: downloadId)
        completionHandlers.removeValue(forKey: downloadId)
        downloadStartTimes.removeValue(forKey: downloadId)
        lastProgressUpdate.removeValue(forKey: downloadId)
        lastUIUpdate.removeValue(forKey: downloadId)
        downloadDestinations.removeValue(forKey: downloadId)
        downloadStoreItems.removeValue(forKey: downloadId)
        removePersistedContext(for: downloadId)
        print("🧹 [清理完成] 下载任务 \(downloadId) 的所有资源已清理")
    }

    private func downloadFromStoreAPI(
        appIdentifier: String,
        directoryServicesIdentifier: String,
        appVersion: String?,
        passwordToken: String,
        storeFront: String
    ) async throws -> [String: Any] {
        print("🔍 [Store API] 开始获取真实的下载信息...")

        let guid = await StoreRequest.shared.currentGUID()
        let url = URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(guid)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")

        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")

        if !passwordToken.isEmpty {
            request.setValue(passwordToken, forHTTPHeaderField: "X-Token")
        }
        if !storeFront.isEmpty {

            let normalizedStoreFront = storeFront.split(separator: "-").first.map(String.init) ?? storeFront
            request.setValue(normalizedStoreFront, forHTTPHeaderField: "X-Apple-Store-Front")
        }

        var body: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": appIdentifier
        ]

        if let appVersion = appVersion {
            body["externalVersionId"] = appVersion
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: body,
            format: .xml,
            options: 0
        )
        request.httpBody = plistData

        print("🔍 [Store API] 发送请求到: \(url.absoluteString)")
        print("🔍 [Store API] 请求体: \(body)")

        let storeConfig = URLSessionConfiguration.default
        storeConfig.timeoutIntervalForRequest = 30
        let storeSession = URLSession(configuration: storeConfig, delegate: SRPURLSessionDelegate.shared, delegateQueue: nil)
        let (data, response) = try await storeSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.networkError(NSError(domain: "StoreAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的HTTP响应"]))
        }

        print("🔍 [Store API] 响应状态码: \(httpResponse.statusCode)")

        if httpResponse.statusCode != 200 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "未知错误"
            print("❌ [Store API] 请求失败: \(errorMessage)")
            throw DownloadError.networkError(NSError(domain: "StoreAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
        }

        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] ?? [:]

        print("🔍 [Store API] 响应包含键: \(Array(plist.keys).sorted())")

        if let songList = plist["songList"] as? [[String: Any]], !songList.isEmpty {
            print("🔍 [Store API] 找到 songList，包含 \(songList.count) 个项目")

            let firstSong = songList[0]
            print("🔍 [Store API] 第一个 song 项目的键: \(Array(firstSong.keys).sorted())")

            if let sinfs = firstSong["sinfs"] as? [[String: Any]], !sinfs.isEmpty {
                print("✅ [Store API] 成功获取真实的 sinf 数据，数量: \(sinfs.count)")
                for (index, sinf) in sinfs.enumerated() {
                    print("🔍 [Store API] Sinf \(index + 1) 的键: \(Array(sinf.keys).sorted())")
                    if let sinfData = sinf["sinf"] as? String {
                        print("🔍 [Store API] Sinf \(index + 1): 长度 \(sinfData.count) 字符")
                        print("🔍 [Store API] Sinf \(index + 1) 前100字符: \(String(sinfData.prefix(100)))")
                    } else {
                        print("⚠️ [Store API] Sinf \(index + 1): sinf 字段类型错误: \(type(of: sinf["sinf"]))")
                    }
                }
            } else {
                print("⚠️ [Store API] 没有找到 sinf 数据")
                print("🔍 [Store API] sinfs 字段类型: \(type(of: firstSong["sinfs"]))")
                if let sinfsRaw = firstSong["sinfs"] {
                    print("🔍 [Store API] sinfs 原始值: \(sinfsRaw)")
                }
            }

            print("🔍 [Store API] URL 字段: \(firstSong["URL"] ?? "未找到")")
            print("🔍 [Store API] md5 字段: \(firstSong["md5"] ?? "未找到")")
            print("🔍 [Store API] metadata 字段类型: \(type(of: firstSong["metadata"]))")

            if let metadata = firstSong["metadata"] as? [String: Any] {
                print("🔍 [Store API] metadata 键: \(Array(metadata.keys).sorted())")
            }
        } else {
            print("⚠️ [Store API] songList 为空或格式错误")
            print("🔍 [Store API] songList 类型: \(type(of: plist["songList"]))")
        }

        return plist
    }

    private func generateGUID() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased()
    }

    private func mapStoreError(_ failureType: String, customerMessage: String?) -> DownloadError {
        switch failureType {
        case "INVALID_ITEM":
            return .appNotFound(customerMessage ?? "应用未找到")
        case "INVALID_LICENSE":
            return .licenseError(customerMessage ?? "许可证无效")
        case "INVALID_CREDENTIALS":
            return .authenticationError(customerMessage ?? "认证失败")
        default:
            return .unknownError(customerMessage ?? "未知错误")
        }
    }
}

extension AppStoreDownloadManager {
    private func downloadId(for task: URLSessionTask) -> String? {
        if let taskDesc = task.taskDescription, !taskDesc.isEmpty {
            return taskDesc
        }
        return downloadTasks.first(where: { $0.value == task })?.key
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {

        guard let downloadId = downloadId(for: downloadTask),
              let completion = completionHandlers[downloadId],
              let destinationURL = downloadDestinations[downloadId],
              let storeItem = downloadStoreItems[downloadId] else {
            print("❌ [下载完成] 无法找到下载任务ID、完成处理器、目标URL或storeItem")
            return
        }
        print("📁 [临时文件] 下载完成，临时文件位置: \(location.path)")
        print("📂 [目标位置] 将移动到: \(destinationURL.path)")

        guard FileManager.default.fileExists(atPath: location.path) else {
            print("❌ [临时文件] 文件不存在: \(location.path)")
            DispatchQueue.main.async {
                completion(.failure(.fileSystemError("临时下载文件不存在")))
            }
            cleanupDownload(downloadId: downloadId)
            return
        }

        do {

            let targetDirectory = destinationURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: targetDirectory.path) {
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)
                print("📁 [目录创建] 已创建目标目录: \(targetDirectory.path)")
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                print("🗑️ [文件清理] 已删除现有文件: \(destinationURL.path)")
            }

            try FileManager.default.moveItem(at: location, to: destinationURL)
            print("✅ [文件移动] 成功移动到: \(destinationURL.path)")

            if !storeItem.md5.isEmpty {
                let isValid = verifyDownloadedFile(
                    downloadId: downloadId,
                    fileURL: destinationURL,
                    expectedMD5: storeItem.md5
                )
                if !isValid {
                    print("⚠️ [文件校验] MD5 校验失败，但继续处理（如需重试请手动重新下载）")
                }
            }

            let result = DownloadResult(
                downloadId: downloadId,
                fileURL: destinationURL,
                fileSize: downloadTask.countOfBytesReceived,
                metadata: DownloadAppMetadata(
                    bundleId: storeItem.metadata.bundleId,
                    bundleDisplayName: storeItem.metadata.bundleDisplayName,
                    bundleShortVersionString: storeItem.metadata.bundleShortVersionString,
                    softwareVersionExternalIdentifier: storeItem.metadata.softwareVersionExternalIdentifier,
                    softwareVersionExternalIdentifiers: storeItem.metadata.softwareVersionExternalIdentifiers
                ),
                sinfs: storeItem.sinfs,
                expectedMD5: storeItem.md5
            )
            print("✅ [下载完成] 文件大小: \(ByteCountFormatter().string(fromByteCount: downloadTask.countOfBytesReceived))")

            print("🔧 [下载完成] 开始处理IPA文件...")
            print("🔧 [下载完成] 签名信息数量: \(storeItem.sinfs.count)")

            print("🔍 [调试] storeItem详细信息:")
            print("   - URL: \(storeItem.url)")
            print("   - MD5: \(storeItem.md5)")
            print("   - Bundle ID: \(storeItem.metadata.bundleId)")
            print("   - Display Name: \(storeItem.metadata.bundleDisplayName)")
            print("   - Version: \(storeItem.metadata.bundleShortVersionString)")
            print("   - Sinf数量: \(storeItem.sinfs.count)")

            for (index, sinf) in storeItem.sinfs.enumerated() {
                print("   - Sinf \(index + 1): ID=\(sinf.id), 数据长度=\(sinf.sinf.count)")
            }

            print("🔧 [下载完成] 开始处理IPA文件，确保创建必要的签名文件...")
            print("🔧 [下载完成] 签名信息数量: \(storeItem.sinfs.count)")

            Task { @MainActor in
                IPAProcessor.shared.processIPA(at: destinationURL, withSinfs: storeItem.sinfs) { processingResult in
                switch processingResult {
                case .success(let processedIPA):
                    print("✅ [IPA处理] 成功处理IPA文件: \(processedIPA.path)")

                    Task {
                        do {
                            print("🔧 [元数据处理] 开始为IPA添加iTunesMetadata.plist...")

                            guard let metadata = result.metadata else {
                                print("❌ [元数据处理] metadata为空，无法创建iTunesMetadata.plist")
                                DispatchQueue.main.async {
                                    completion(.success(result))
                                }
                                return
                            }

                            print("🔧 [元数据处理] 元数据信息:")
                            print("   - Bundle ID: \(metadata.bundleId)")
                            print("   - Display Name: \(metadata.bundleDisplayName)")
                            print("   - Version: \(metadata.bundleShortVersionString)")

                            let finalIPA = try await self.generateiTunesMetadata(
                                for: processedIPA.path,
                                bundleId: metadata.bundleId,
                                displayName: metadata.bundleDisplayName,
                                version: metadata.bundleShortVersionString,
                                externalVersionId: Int(metadata.softwareVersionExternalIdentifier) ?? 0,
                                externalVersionIds: metadata.softwareVersionExternalIdentifiers
                            )

                            print("✅ [元数据处理] 成功生成iTunesMetadata.plist，最终IPA: \(finalIPA)")

                            let finalResult = DownloadResult(
                                downloadId: result.downloadId,
                                fileURL: URL(fileURLWithPath: finalIPA),
                                fileSize: result.fileSize,
                                metadata: result.metadata,
                                sinfs: result.sinfs,
                                expectedMD5: result.expectedMD5
                            )

                            DispatchQueue.main.async {
                                completion(.success(finalResult))
                            }
                        } catch {
                            print("❌ [元数据处理] 生成iTunesMetadata.plist失败: \(error)")
                            DispatchQueue.main.async {
                                completion(.success(result))
                            }
                        }
                    }
                case .failure(let error):
                    print("❌ [IPA处理] 处理失败: \(error.localizedDescription)")

                    DispatchQueue.main.async {
                        completion(.success(result))
                    }
                }
            }
            }
        } catch {
            print("❌ [文件移动失败] \(error.localizedDescription)")
            DispatchQueue.main.async {
                completion(.failure(.fileSystemError("文件移动失败: \(error.localizedDescription)")))
            }
        }
        cleanupDownload(downloadId: downloadId)
    }
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {

        guard let downloadId = downloadId(for: downloadTask),
              let progressHandler = progressHandlers[downloadId],
              let startTime = downloadStartTimes[downloadId] else {
            return
        }
        let currentTime = Date()

        var speed: Double = 0.0
        var remainingTime: TimeInterval = 0.0
        if let lastUpdate = lastProgressUpdate[downloadId] {
            let timeDiff = currentTime.timeIntervalSince(lastUpdate.time)
            if timeDiff > 0 {
                let bytesDiff = totalBytesWritten - lastUpdate.bytes
                speed = Double(bytesDiff) / timeDiff
            }
        } else {

            let totalTime = currentTime.timeIntervalSince(startTime)
            if totalTime > 0 {
                speed = Double(totalBytesWritten) / totalTime
            }
        }

        if speed > 0 && totalBytesExpectedToWrite > totalBytesWritten {
            let remainingBytes = totalBytesExpectedToWrite - totalBytesWritten
            remainingTime = Double(remainingBytes) / speed
        }
        let progressValue = totalBytesExpectedToWrite > 0 ?
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        let progress = DownloadProgress(
            downloadId: downloadId,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite,
            progress: progressValue,
            speed: speed,
            remainingTime: remainingTime,
            status: DownloadStatus.downloading
        )

        let lastUIUpdateTime = lastUIUpdate[downloadId] ?? Date.distantPast
        let shouldUpdate = currentTime.timeIntervalSince(lastUIUpdateTime) >= 0.1 || progressValue >= 1.0

        lastProgressUpdate[downloadId] = (bytes: totalBytesWritten, time: currentTime)
        if shouldUpdate {
            lastUIUpdate[downloadId] = currentTime
            
            if persistedContexts[downloadId] != nil {
                persistContext(
                    for: downloadId,
                    bytesDownloaded: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            }
            
            DispatchQueue.main.async {
                progressHandler(progress)
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let downloadId = downloadId(for: downloadTask),
              let completion = completionHandlers[downloadId],
              let _ = downloadDestinations[downloadId],
              let _ = downloadStoreItems[downloadId] else {
            return
        }

        if let error = error {
            print("❌ [下载失败] 任务ID: \(downloadId)，错误: \(error.localizedDescription)")

            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeDataStore[downloadId] = resumeData
                print("💾 [断点续传] 已保存断点续传数据，大小: \(resumeData.count) 字节")
            }

            if let nsError = error as NSError? {

                if nsError.domain == NSURLErrorDomain {

                    switch nsError.code {
                    case NSURLErrorNotConnectedToInternet:
                        print("📶 [网络错误] 设备未连接到互联网")
                        DispatchQueue.main.async {
                            completion(.failure(.networkError(NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "设备未连接到互联网，请检查网络连接后重试"]))))
                        }
                    case NSURLErrorTimedOut:
                        print("⏱️ [网络错误] 下载超时")
                        DispatchQueue.main.async {
                            completion(.failure(.networkError(NSError(domain: "DownloadManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "下载超时，请检查网络连接后重试"]))))
                        }
                    case NSURLErrorCancelled:
                        print("🚫 [下载取消] 下载任务已被取消")
                        DispatchQueue.main.async {
                            completion(.failure(.unknownError("下载已取消")))
                        }
                    default:
                        print("🌐 [网络错误] 其他网络错误，错误码: \(nsError.code)")
                        DispatchQueue.main.async {
                            completion(.failure(.networkError(NSError(domain: "DownloadManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "下载失败，请稍后重试"]))))
                        }
                    }
                } else if nsError.domain == "NSCocoaErrorDomain" {

                    print("💾 [文件错误] 文件系统错误，错误码: \(nsError.code)")
                    DispatchQueue.main.async {
                        completion(.failure(.fileSystemError("文件操作失败，请确保有足够的存储空间")))
                    }
                } else {

                    print("❓ [未知错误] 错误域: \(nsError.domain)，错误码: \(nsError.code)")
                    DispatchQueue.main.async {
                        completion(.failure(.unknownError("下载过程中发生未知错误")))
                    }
                }
            } else {

                DispatchQueue.main.async {
                    completion(.failure(.unknownError("下载失败: \(error.localizedDescription)")))
                }
            }
        }
        cleanupDownload(downloadId: downloadId)
    }
}

struct DownloadProgress {
    let downloadId: String
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let progress: Double
    let speed: Double
    let remainingTime: TimeInterval
    let status: DownloadStatus
    var formattedProgress: String {
        return String(format: "%.1f%%", progress * 100)
    }
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: bytesDownloaded)) / \(formatter.string(fromByteCount: totalBytes))"
    }
    var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(speed)))/s"
    }
    var formattedRemainingTime: String {
        if remainingTime <= 0 {
            return "--:--"
        }
        let hours = Int(remainingTime) / 3600
        let minutes = (Int(remainingTime) % 3600) / 60
        let seconds = Int(remainingTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct DownloadResult {
    let downloadId: String
    let fileURL: URL
    let fileSize: Int64
    var metadata: DownloadAppMetadata?
    var sinfs: [DownloadSinfInfo]?
    var expectedMD5: String?
    var isIntegrityValid: Bool {
        guard let expectedMD5 = expectedMD5,
              let fileData = try? Data(contentsOf: fileURL) else {
            return false
        }
        let digest = Insecure.MD5.hash(data: fileData)
        let calculatedMD5 = digest.map { String(format: "%02hhx", $0) }.joined()
        return calculatedMD5.lowercased() == expectedMD5.lowercased()
    }
}

enum DownloadError: LocalizedError {
    case invalidURL(String)
    case appNotFound(String)
    case licenseError(String)
    case authenticationError(String)
    case downloadNotFound(String)
    case fileSystemError(String)
    case integrityCheckFailed(String)
    case licenseCheckFailed(String)
    case networkError(Error)
    case unknownError(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return "无效的URL: \(message)"
        case .appNotFound(let message):
            return "应用未找到: \(message)"
        case .licenseError(let message):
            return "许可证错误: \(message)"
        case .authenticationError(let message):
            return "认证错误: \(message)"
        case .downloadNotFound(let message):
            return "下载未找到: \(message)"
        case .fileSystemError(let message):
            return "文件系统错误: \(message)"
        case .integrityCheckFailed(let message):
            return "完整性检查失败: \(message)"
        case .licenseCheckFailed(let message):
            return "许可证检查失败: \(message)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .unknownError(let message):
            return "未知错误: \(message)"
        }
    }
}

struct UnifiedDownloadRequest: Identifiable, Codable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let version: String
    let identifier: String
    let iconURL: String?
    let versionId: String?
    var status: DownloadStatus
    var progress: Double
    let createdAt: Date
    var completedAt: Date?
    var filePath: String?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, name, version, identifier, iconURL, versionId, status, progress
        case createdAt, completedAt, filePath, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        identifier = try container.decode(String.self, forKey: .identifier)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        versionId = try container.decodeIfPresent(String.self, forKey: .versionId)
        status = try container.decode(DownloadStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)

        let createdAtString = try container.decode(String.self, forKey: .createdAt)
        createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()

        if let completedAtString = try container.decodeIfPresent(String.self, forKey: .completedAt) {
            completedAt = ISO8601DateFormatter().date(from: completedAtString)
        }

        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(identifier, forKey: .identifier)
        try container.encodeIfPresent(iconURL, forKey: .iconURL)
        try container.encodeIfPresent(versionId, forKey: .versionId)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)

        let dateFormatter = ISO8601DateFormatter()
        try container.encode(dateFormatter.string(from: createdAt), forKey: .createdAt)

        if let completedAt = completedAt {
            try container.encode(dateFormatter.string(from: completedAt), forKey: .completedAt)
        }

        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
}

extension AppStoreDownloadManager {

    private func generateiTunesMetadata(
        for ipaPath: String,
        bundleId: String,
        displayName: String,
        version: String,
        externalVersionId: Int,
        externalVersionIds: [Int]?
    ) async throws -> String {
        print("🔧 [iTunesMetadata] 开始为IPA文件强制生成iTunesMetadata.plist: \(ipaPath)")
        print("🔧 [iTunesMetadata] 参数信息:")
        print("   - Bundle ID: \(bundleId)")
        print("   - Display Name: \(displayName)")
        print("   - Version: \(version)")
        print("   - External Version ID: \(externalVersionId)")
        print("   - External Version IDs: \(externalVersionIds ?? [])")

        let metadataDict: [String: Any] = [
            "appleId": bundleId,
            "artistId": 0,
            "artistName": displayName,
            "bundleId": bundleId,
            "bundleVersion": version,
            "copyright": "Copyright © 2025",
            "drmVersionNumber": 0,
            "fileExtension": "ipa",
            "fileName": "\(displayName).ipa",
            "genre": "Productivity",
            "genreId": 6007,
            "itemId": 0,
            "itemName": displayName,
            "kind": "software",
            "playlistName": "iOS Apps",
            "price": 0.0,
            "priceDisplay": "Free",
            "rating": "4+",
            "releaseDate": "2025-01-01T00:00:00Z",
            "s": 143441,
            "softwareIcon57x57URL": "",
            "softwareIconNeedsShine": false,
            "softwareSupportedDeviceIds": [1, 2],
            "softwareVersionBundleId": bundleId,
            "softwareVersionExternalIdentifier": externalVersionId,
            "softwareVersionExternalIdentifiers": externalVersionIds ?? [],
            "subgenres": [],
            "vendorId": 0,
            "versionRestrictions": 0
        ]

        print("🔧 [iTunesMetadata] 构建的元数据字典包含 \(metadataDict.count) 个字段")

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: metadataDict,
            format: .xml,
            options: 0
        )

        print("🔧 [iTunesMetadata] 成功生成plist数据，大小: \(ByteCountFormatter().string(fromByteCount: Int64(plistData.count)))")


        print("⚡ [iTunesMetadata] 使用FastZipArchive增量添加iTunesMetadata.plist")

        let success = FastZipArchive.shared.addFiles(
            toZipAtPath: ipaPath,
            files: [("iTunesMetadata.plist", plistData)]
        )

        guard success else {
            throw NSError(domain: "iTunesMetadataProcessing", code: 1, userInfo: [NSLocalizedDescriptionKey: "FastZipArchive添加iTunesMetadata.plist失败"])
        }

        print("✅ [iTunesMetadata] 成功使用FastZipArchive处理IPA文件")
        return ipaPath
    }
}
