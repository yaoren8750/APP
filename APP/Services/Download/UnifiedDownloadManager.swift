import Foundation
import SwiftUI
import Combine

@MainActor
class UnifiedDownloadManager: ObservableObject, @unchecked Sendable {
    static let shared = UnifiedDownloadManager()

    @Published var downloadRequests: [DownloadRequest] = []
    @Published var completedRequests: Set<UUID> = []
    @Published var activeDownloads: Set<UUID> = []
    @Published var waitingDownloads: Set<UUID> = []

    var sortedDownloadRequests: [DownloadRequest] {
        downloadRequests.sorted { req1, req2 in
            let priority1 = downloadPriority(for: req1)
            let priority2 = downloadPriority(for: req2)
            if priority1 != priority2 {
                return priority1 > priority2
            }
            return req1.createdAt > req2.createdAt
        }
    }

    private func downloadPriority(for request: DownloadRequest) -> Int {
        switch request.runtime.status {
        case .downloading:
            return 4
        case .waiting:
            return 3
        case .paused:
            return 2
        case .failed:
            return 1
        case .cancelled:
            return 1
        case .completed:
            return 0
        }
    }

    var maxConcurrentDownloads: Int = 3

    private let downloadManager = AppStoreDownloadManager.shared
    private let purchaseManager = PurchaseManager.shared

    private var downloadQueue: [DownloadRequest] = []


    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func relativePath(for fullPath: String) -> String {
        let docsPath = documentsDirectory.path
        if fullPath.hasPrefix(docsPath) {
            return String(fullPath.dropFirst(docsPath.count + 1))
        }
        return (fullPath as NSString).lastPathComponent
    }

    private func fullPath(for relativePath: String) -> String {
        documentsDirectory.appendingPathComponent(relativePath).path
    }

    private init() {

        configureSessionMonitoring()
    }

    private func configureSessionMonitoring() {

        Task { @MainActor in
            restoreDownloadTasks()
            restoreBackgroundDownloadHandlers()
            syncDownloadStatus()
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.saveDownloadTasks()
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.restoreBackgroundDownloadHandlers()
                self.syncDownloadStatus()
                self.saveDownloadTasks()
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.saveDownloadTasks()
            }
        }
    }
    
    private func restoreBackgroundDownloadHandlers() {
        downloadManager.restoreBackgroundTasks(
            progressHandler: { [weak self] downloadId, downloadProgress in
                Task { @MainActor in
                    guard let self = self else { return }
                    let uuid = UUID(uuidString: downloadId)
                    guard let request = self.downloadRequests.first(where: { $0.id.uuidString == downloadId || $0.id == uuid }) else {
                        return
                    }
                    
                    request.runtime.updateProgress(
                        completed: downloadProgress.bytesDownloaded,
                        total: downloadProgress.totalBytes
                    )
                    request.runtime.speed = downloadProgress.formattedSpeed
                    request.runtime.status = .downloading
                    
                    if !self.activeDownloads.contains(request.id) {
                        self.activeDownloads.insert(request.id)
                    }
                    
                    request.objectWillChange.send()
                    request.runtime.objectWillChange.send()
                }
            },
            completion: { [weak self] downloadId, result in
                Task { @MainActor in
                    guard let self = self else { return }
                    let uuid = UUID(uuidString: downloadId)
                    guard let request = self.downloadRequests.first(where: { $0.id.uuidString == downloadId || $0.id == uuid }) else {
                        return
                    }
                    
                    switch result {
                    case .success(let downloadResult):
                        request.runtime.updateProgress(
                            completed: downloadResult.fileSize,
                            total: downloadResult.fileSize
                        )
                        request.runtime.status = .completed
                        request.localFilePath = downloadResult.fileURL.path
                        self.completedRequests.insert(request.id)
                        print("✅ [后台下载完成] \(request.name) 已保存到: \(downloadResult.fileURL.path)")
                        
                    case .failure(let error):
                        request.runtime.error = error.localizedDescription
                        request.runtime.status = .failed
                        print("❌ [后台下载失败] \(request.name): \(error.localizedDescription)")
                    }
                    
                    self.activeDownloads.remove(request.id)
                    self.processNextInQueue()
                    self.saveDownloadTasks()
                }
            }
        )
    }

    func addDownload(
        bundleIdentifier: String,
        name: String,
        version: String,
        identifier: Int,
        iconURL: String? = nil,
        versionId: String? = nil
    ) -> UUID {
        print("🔍 [添加下载] 开始添加下载请求")
        print("   - Bundle ID: \(bundleIdentifier)")
        print("   - 名称: \(name)")
        print("   - 版本: \(version)")
        print("   - 标识符: \(identifier)")
        print("   - 版本ID: \(versionId ?? "无")")

        let package = DownloadArchive(
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            identifier: identifier,
            iconURL: iconURL
        )

        let request = DownloadRequest(
            bundleIdentifier: bundleIdentifier,
            version: version,
            name: name,
            package: package,
            versionId: versionId
        )

        downloadRequests.append(request)
        print("✅ [添加下载] 下载请求已添加，ID: \(request.id)")
        print("📊 [添加下载] 当前下载请求总数: \(downloadRequests.count)")
        print("🖼️ [图标信息] 图标URL: \(request.iconURL ?? "无")")
        print("📦 [包信息] 包名称: \(request.package.name), 标识符: \(request.package.identifier)")
        return request.id
    }

    func deleteDownload(request: DownloadRequest) {
        if let index = downloadRequests.firstIndex(where: { $0.id == request.id }) {
            downloadRequests.remove(at: index)
        }
        if let queueIndex = downloadQueue.firstIndex(where: { $0.id == request.id }) {
            downloadQueue.remove(at: queueIndex)
        }
        activeDownloads.remove(request.id)
        completedRequests.remove(request.id)
        waitingDownloads.remove(request.id)
        print("🗑️ [删除下载] 已删除下载请求: \(request.name)")
    }

    func startDownload(for request: DownloadRequest) {
        guard !activeDownloads.contains(request.id),
              !waitingDownloads.contains(request.id) else {
            print("⚠️ [下载跳过] 请求 \(request.id) 已在下载队列中")
            return
        }

        print("🚀 [下载启动] 开始下载: \(request.name) v\(request.version)")
        print("🔍 [调试] 下载请求详情:")
        print("   - Bundle ID: \(request.bundleIdentifier)")
        print("   - 版本: \(request.version)")
        print("   - 版本ID: \(request.versionId ?? "无")")
        print("   - 包标识符: \(request.package.identifier)")
        print("   - 包名称: \(request.package.name)")
        print("   - 当前状态: \(request.runtime.status)")
        print("   - 当前进度: \(request.runtime.progressValue)")

        print("📊 [队列状态] 当前活跃: \(activeDownloads.count)/\(maxConcurrentDownloads)")

        if activeDownloads.count >= maxConcurrentDownloads {
            request.runtime.status = DownloadStatus.waiting
            waitingDownloads.insert(request.id)
            downloadQueue.append(request)
            print("⏳ [下载排队] \(request.name) 已加入等待队列，位置: \(downloadQueue.count)")
            return
        }

        activeDownloads.insert(request.id)
        request.runtime.status = DownloadStatus.downloading
        request.runtime.error = nil

        request.runtime.progress = Progress(totalUnitCount: 0)
        request.runtime.progress.completedUnitCount = 0

        print("✅ [状态更新] 状态已设置为: \(request.runtime.status)")
        print("✅ [进度重置] 进度已重置为: \(request.runtime.progressValue)")

        Task {
            guard let account = AppStore.this.selectedAccount else {
                await MainActor.run {
                    request.runtime.error = "请先添加Apple ID账户"
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                    print("❌ [认证失败] 未找到有效的Apple ID账户")
                }
                return
            }

            print("🔐 [认证信息] 使用账户: \(account.email)")
            print("🏪 [商店信息] StoreFront: \(account.storeResponse.storeFront)")

            AuthenticationManager.shared.setCookies(account.cookies)

            let storeAccount = Account(
                name: account.email,
                email: account.email,
                firstName: account.firstName,
                lastName: account.lastName,
                passwordToken: account.storeResponse.passwordToken,
                directoryServicesIdentifier: account.storeResponse.directoryServicesIdentifier,
                dsPersonId: account.storeResponse.directoryServicesIdentifier,
                cookies: account.cookies,
                countryCode: account.countryCode,
                storeResponse: account.storeResponse,
                deviceGUID: account.deviceGUID
            )

            let isValid = await AuthenticationManager.shared.validateAccount(storeAccount)
            if !isValid {
                await MainActor.run {
                    request.runtime.error = "Apple ID会话已过期，请重新登录"
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                    print("❌ [会话失效] Apple ID会话已过期")
                }
                return
            }

            let regionValidation = (account.countryCode == storeAccount.countryCode)

            if !regionValidation {
                await MainActor.run {
                    request.runtime.error = "地区设置不匹配，请检查账户地区设置"
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                    print("❌ [地区错误] 账户地区与设置不匹配")
                }
                return
            }

            print("🔍 [购买验证] 开始验证应用所有权: \(request.name)")
            let purchaseResult = await purchaseManager.purchaseAppIfNeeded(
                appIdentifier: String(request.package.identifier),
                account: storeAccount,
                countryCode: account.countryCode
            )

            switch purchaseResult {
            case .success(let result):
                print("✅ [购买验证] \(result.message)")

                proceedWithDownload(
                    for: request,
                    storeAccount: storeAccount
                )
            case .failure(let error):
                await MainActor.run {
                    request.runtime.error = error.localizedDescription
                    request.runtime.status = DownloadStatus.failed
                    self.activeDownloads.remove(request.id)
                    print("❌ [购买失败] \(request.name): \(error.localizedDescription)")
                }
            }
        }
    }

    private func proceedWithDownload(
        for request: DownloadRequest,
        storeAccount: Account
    ) {

        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ [下载管理] 无法获取文档目录路径")
            request.runtime.status = .failed
            request.runtime.error = "无法获取文档目录路径"
            return
        }
        let sanitizedName = request.package.name.replacingOccurrences(of: "/", with: "_")
        let destinationURL = documentsPath.appendingPathComponent("\(sanitizedName)_\(request.version).ipa")

        print("📁 [文件路径] 目标位置: \(destinationURL.path)")
        print("🆔 [应用信息] ID: \(request.package.identifier), 版本: \(request.versionId ?? request.version)")

        downloadManager.downloadApp(
            appIdentifier: String(request.package.identifier),
            account: storeAccount,
            destinationURL: destinationURL,
            appVersion: request.versionId,
            downloadId: request.id.uuidString,
            progressHandler: { downloadProgress in
                Task { @MainActor in

                    request.runtime.updateProgress(
                        completed: downloadProgress.bytesDownloaded,
                        total: downloadProgress.totalBytes
                    )
                    request.runtime.speed = downloadProgress.formattedSpeed

                    switch downloadProgress.status {
                    case .waiting:
                        request.runtime.status = DownloadStatus.waiting
                    case .downloading:
                        request.runtime.status = DownloadStatus.downloading
                    case .paused:
                        request.runtime.status = DownloadStatus.paused
                    case .completed:
                        request.runtime.status = DownloadStatus.completed
                    case .failed:
                        request.runtime.status = DownloadStatus.failed
                    case .cancelled:
                        request.runtime.status = DownloadStatus.cancelled
                    }

                    let progressPercent = Int(downloadProgress.progress * 100)
                    if progressPercent % 1 == 0 && progressPercent > 0 {
                        print("📊 [下载进度] \(request.name): \(progressPercent)% (\(downloadProgress.formattedSize)) - 速度: \(downloadProgress.formattedSpeed)")
                    }

                    request.objectWillChange.send()
                    request.runtime.objectWillChange.send()
                }
            },
            completion: { result in
                Task { @MainActor in
                    switch result {
                    case .success(let downloadResult):

                        request.runtime.updateProgress(
                            completed: downloadResult.fileSize,
                            total: downloadResult.fileSize
                        )
                        request.runtime.status = DownloadStatus.completed

                        request.localFilePath = downloadResult.fileURL.path
                        self.completedRequests.insert(request.id)
                        print("✅ [下载完成] \(request.name) 已保存到: \(downloadResult.fileURL.path)")
                        print("📊 [文件信息] 大小: \(ByteCountFormatter().string(fromByteCount: downloadResult.fileSize))")

                        self.saveDownloadTasks()

                    case .failure(let error):
                        request.runtime.error = error.localizedDescription
                        request.runtime.status = DownloadStatus.failed
                        print("❌ [下载失败] \(request.name): \(error.localizedDescription)")
                    }

                    self.activeDownloads.remove(request.id)
                    self.processNextInQueue()
                }
            }
        )
    }

    private func processNextInQueue() {
        guard !downloadQueue.isEmpty else { return }
        guard activeDownloads.count < maxConcurrentDownloads else { return }

        let nextRequest = downloadQueue.removeFirst()
        waitingDownloads.remove(nextRequest.id)

        print("▶️ [队列调度] 从队列中取出下一个下载: \(nextRequest.name)")

        startDownload(for: nextRequest)
    }

    func moveToFront(requestId: UUID) {
        guard let index = downloadQueue.firstIndex(where: { $0.id == requestId }) else { return }
        let request = downloadQueue.remove(at: index)
        downloadQueue.insert(request, at: 0)
        print("⬆️ [队列调整] \(request.name) 已移至队列首位")
    }

    func cancelDownload(request: DownloadRequest) {
        if let index = downloadQueue.firstIndex(where: { $0.id == request.id }) {
            downloadQueue.remove(at: index)
            waitingDownloads.remove(request.id)
            request.runtime.status = DownloadStatus.cancelled
            request.runtime.error = nil
            print("🚫 [取消下载] 已从队列中移除: \(request.name)")
            saveDownloadTasks()
            return
        }

        if activeDownloads.contains(request.id) {
            downloadManager.cancelDownload(downloadId: request.id.uuidString)
            request.runtime.status = DownloadStatus.cancelled
            request.runtime.error = nil
            activeDownloads.remove(request.id)
            print("🚫 [取消下载] 已取消活跃下载: \(request.name)")
            processNextInQueue()
            saveDownloadTasks()
        }
    }

    func pauseDownload(request: DownloadRequest) {
        if waitingDownloads.contains(request.id) {
            if let index = downloadQueue.firstIndex(where: { $0.id == request.id }) {
                downloadQueue.remove(at: index)
            }
            waitingDownloads.remove(request.id)
            request.runtime.status = DownloadStatus.paused
            print("⏸️ [暂停下载] 已暂停队列中的下载: \(request.name)")
            saveDownloadTasks()
            return
        }

        if activeDownloads.contains(request.id) {
            downloadManager.pauseDownload(downloadId: request.id.uuidString)
            request.runtime.status = DownloadStatus.paused
            activeDownloads.remove(request.id)
            print("⏸️ [暂停下载] 已暂停活跃下载: \(request.name)")
            processNextInQueue()
            saveDownloadTasks()
        }
    }

    func resumeDownload(request: DownloadRequest) {
        guard request.runtime.status == DownloadStatus.paused ||
              request.runtime.status == DownloadStatus.failed else { return }

        request.runtime.error = nil
        startDownload(for: request)
    }

    var queuePosition: (Int, Int) {
        let waiting = downloadQueue.count
        let active = activeDownloads.count
        return (active, waiting)
    }
}

struct DownloadArchive {
    let bundleIdentifier: String
    let name: String
    let version: String
    let identifier: Int
    let iconURL: String?
    let description: String?

    init(bundleIdentifier: String, name: String, version: String, identifier: Int = 0, iconURL: String? = nil, description: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.identifier = identifier
        self.iconURL = iconURL
        self.description = description
    }
}

class DownloadRuntime: ObservableObject {
    @Published var status: DownloadStatus = DownloadStatus.waiting
    @Published var progress: Progress = Progress(totalUnitCount: 0)
    @Published var speed: String = ""
    @Published var error: String?
    @Published var progressValue: Double = 0.0

    init() {

        progress.completedUnitCount = 0
    }

    @MainActor
    func updateProgress(completed: Int64, total: Int64) {

        progress = Progress(totalUnitCount: total)
        progress.completedUnitCount = completed
        progressValue = total > 0 ? Double(completed) / Double(total) : 0.0

        objectWillChange.send()

        let percent = Int(progressValue * 100)
        print("🔄 [进度更新] \(percent)% (\(ByteCountFormatter().string(fromByteCount: completed))/\(ByteCountFormatter().string(fromByteCount: total)))")
    }
}

enum DownloadStatus: String, Codable {
    case waiting
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

class DownloadRequest: Identifiable, ObservableObject, Equatable, @unchecked Sendable {
    let id: UUID
    let bundleIdentifier: String
    let version: String
    let name: String
    var createdAt: Date
    let package: DownloadArchive
    let versionId: String?
    @Published var localFilePath: String?

    private var cancellables: Set<AnyCancellable> = []
    @Published var runtime: DownloadRuntime { didSet { bindRuntime() } }

    var iconURL: String? {
        return package.iconURL
    }

    var identifier: Int {
        return package.identifier
    }

    init(id: UUID = UUID(), bundleIdentifier: String, version: String, name: String, package: DownloadArchive, versionId: String? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.name = name
        self.createdAt = Date()
        self.package = package
        self.versionId = versionId
        self.runtime = DownloadRuntime()

        bindRuntime()
    }

    private func bindRuntime() {
        cancellables.removeAll()
        runtime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var hint: String {
        if let error = runtime.error {
            return error
        }
        return switch runtime.status {
        case DownloadStatus.waiting:
            "等待中..."
        case DownloadStatus.downloading:
            [
                String(Int(runtime.progressValue * 100)) + "%",
                runtime.speed.isEmpty ? "" : runtime.speed,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        case DownloadStatus.paused:
            "已暂停"
        case DownloadStatus.completed:
            "已完成"
        case DownloadStatus.failed:
            "下载失败"
        case DownloadStatus.cancelled:
            "已取消"
        }
    }

    static func == (lhs: DownloadRequest, rhs: DownloadRequest) -> Bool {
        return lhs.id == rhs.id
    }
}

extension UnifiedDownloadManager {

    func saveDownloadTasks() {
        NSLog("💾 [UnifiedDownloadManager] 开始保存下载任务")

        let saveData = DownloadTasksSaveData(
            downloadRequests: downloadRequests.map { request in
                DownloadRequestSaveData(
                    id: request.id,
                    bundleIdentifier: request.bundleIdentifier,
                    version: request.version,
                    name: request.name,
                    package: request.package,
                    versionId: request.versionId,
                    runtime: DownloadRuntimeSaveData(
                        status: request.runtime.status,
                        progressValue: request.runtime.progressValue,
                        error: request.runtime.error,
                        speed: request.runtime.speed,
                        localFilePath: request.localFilePath.map { relativePath(for: $0) }
                    ),
                    createdAt: request.createdAt
                )
            },
            completedRequests: Array(completedRequests),
            activeDownloads: Array(activeDownloads),
            waitingDownloads: Array(waitingDownloads),
            queueOrder: downloadQueue.map { $0.id }
        )

        do {
            let data = try JSONEncoder().encode(saveData)
            UserDefaults.standard.set(data, forKey: "DownloadTasks")
            NSLog("✅ [UnifiedDownloadManager] 下载任务保存成功，共\(downloadRequests.count)个任务")
        } catch {
            NSLog("❌ [UnifiedDownloadManager] 下载任务保存失败: \(error)")
        }
    }

    func restoreDownloadTasks() {
        NSLog("🔄 [UnifiedDownloadManager] 开始恢复下载任务")

        guard let data = UserDefaults.standard.data(forKey: "DownloadTasks") else {
            NSLog("ℹ️ [UnifiedDownloadManager] 没有找到保存的下载任务")
            return
        }

        do {
            let saveData = try JSONDecoder().decode(DownloadTasksSaveData.self, from: data)

            downloadRequests = saveData.downloadRequests.map { saveRequest in
                let request = DownloadRequest(
                    id: saveRequest.id,
                    bundleIdentifier: saveRequest.bundleIdentifier,
                    version: saveRequest.version,
                    name: saveRequest.name,
                    package: saveRequest.package,
                    versionId: saveRequest.versionId
                )

                request.runtime.status = saveRequest.runtime.status
                request.runtime.progressValue = saveRequest.runtime.progressValue
                request.runtime.error = saveRequest.runtime.error
                request.runtime.speed = saveRequest.runtime.speed
                request.createdAt = saveRequest.createdAt


                if let relativePath = saveRequest.runtime.localFilePath {
                    let fullPath = fullPath(for: relativePath)
                    if FileManager.default.fileExists(atPath: fullPath) {
                        request.localFilePath = fullPath
                        NSLog("✅ [UnifiedDownloadManager] 文件路径恢复成功: \(request.name) -> \(fullPath)")
                    } else {

                        let fileName = (relativePath as NSString).lastPathComponent
                        let fallbackPath = documentsDirectory.appendingPathComponent(fileName).path
                        if FileManager.default.fileExists(atPath: fallbackPath) {
                            request.localFilePath = fallbackPath
                            NSLog("⚠️ [UnifiedDownloadManager] 通过文件名恢复路径: \(request.name) -> \(fallbackPath)")
                        } else {
                            request.localFilePath = nil
                            NSLog("❌ [UnifiedDownloadManager] 文件不存在，清空路径: \(request.name)")

                            if request.runtime.status == .completed {
                                request.runtime.status = .cancelled
                                request.runtime.error = "本地文件已丢失，请重新下载"
                            }
                        }
                    }
                }

                return request
            }

            completedRequests = Set(saveData.completedRequests)
            let savedActive = Set(saveData.activeDownloads)
            let savedWaiting = Set(saveData.waitingDownloads ?? [])

            var newActive: Set<UUID> = []
            var newWaiting: Set<UUID> = []

            for request in downloadRequests {
                if completedRequests.contains(request.id) {

                    if request.localFilePath != nil {
                        request.runtime.status = .completed
                    } else {
                        completedRequests.remove(request.id)
                        request.runtime.status = .cancelled
                        request.runtime.error = "本地文件已丢失，请重新下载"
                    }
                } else if savedActive.contains(request.id) {
                    request.runtime.status = .downloading
                    newActive.insert(request.id)
                    NSLog("ℹ️ [恢复下载] \(request.name) 恢复为下载中状态，等待同步")
                } else if savedWaiting.contains(request.id) {

                    request.runtime.status = .waiting
                    newWaiting.insert(request.id)
                }
            }

            activeDownloads = newActive
            waitingDownloads = newWaiting


            if let queueOrder = saveData.queueOrder {
                downloadQueue = queueOrder.compactMap { requestId in
                    downloadRequests.first(where: { $0.id == requestId && newWaiting.contains(requestId) })
                }
            } else {
                downloadQueue = downloadRequests.filter { newWaiting.contains($0.id) }
            }

            let refreshed = downloadRequests
            downloadRequests = refreshed

            NSLog("✅ [UnifiedDownloadManager] 下载任务恢复成功，共\(downloadRequests.count)个任务")

        } catch {
            NSLog("❌ [UnifiedDownloadManager] 下载任务恢复失败: \(error)")
        }
    }

    func syncDownloadStatus() {
        NSLog("🔄 [UnifiedDownloadManager] 同步下载任务状态")

        Task { @MainActor in
            let activeIds = await downloadManager.activeDownloadIds
            
            for request in downloadRequests {
                let hasActiveTask = activeIds.contains(request.id.uuidString)
                
                if request.runtime.status == .downloading && !hasActiveTask {
                    request.runtime.status = .paused
                    activeDownloads.remove(request.id)
                    NSLog("⚠️ [状态同步] \(request.name) 下载已中断，标记为已暂停")
                } else if request.runtime.status == .paused && hasActiveTask {
                    request.runtime.status = .downloading
                    activeDownloads.insert(request.id)
                    NSLog("⚠️ [状态同步] \(request.name) 检测到后台下载，恢复为下载中")
                }
            }
            
            let validActive = activeDownloads.filter { id in
                downloadRequests.contains(where: { $0.id == id })
            }
            activeDownloads = validActive
            
            let refreshed = downloadRequests
            downloadRequests = refreshed
            
            NSLog("✅ [UnifiedDownloadManager] 下载状态同步完成")
        }
    }

    func pauseAllDownloads() {
        NSLog("⏸️ [UnifiedDownloadManager] 暂停所有下载任务")

        for request in downloadRequests {
            if request.runtime.status == DownloadStatus.downloading {
                request.runtime.status = DownloadStatus.paused
                activeDownloads.remove(request.id)
                NSLog("⏸️ [UnifiedDownloadManager] 已暂停: \(request.name)")
            }
            if request.runtime.status == DownloadStatus.waiting {
                request.runtime.status = DownloadStatus.paused
                waitingDownloads.remove(request.id)
                NSLog("⏸️ [UnifiedDownloadManager] 已暂停队列中的: \(request.name)")
            }
        }

        downloadQueue.removeAll()

        saveDownloadTasks()
    }

    func resumeAllDownloads() {
        NSLog("▶️ [UnifiedDownloadManager] 恢复所有暂停的下载任务")

        let pausedRequests = downloadRequests.filter {
            $0.runtime.status == DownloadStatus.paused
        }

        for request in pausedRequests {
            startDownload(for: request)
        }

        saveDownloadTasks()
    }
}

private struct DownloadTasksSaveData: Codable {
    let downloadRequests: [DownloadRequestSaveData]
    let completedRequests: [UUID]
    let activeDownloads: [UUID]
    let waitingDownloads: [UUID]?
    let queueOrder: [UUID]?
}

private struct DownloadRequestSaveData: Codable {
    let id: UUID
    let bundleIdentifier: String
    let version: String
    let name: String
    let packageIdentifier: Int
    let packageIconURL: String?
    let versionId: String?
    let runtime: DownloadRuntimeSaveData
    var createdAt: Date

    init(id: UUID, bundleIdentifier: String, version: String, name: String, package: DownloadArchive, versionId: String?, runtime: DownloadRuntimeSaveData, createdAt: Date) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.name = name
        self.packageIdentifier = package.identifier
        self.packageIconURL = package.iconURL
        self.versionId = versionId
        self.runtime = runtime
        self.createdAt = createdAt
    }

    var package: DownloadArchive {
        return DownloadArchive(
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            identifier: packageIdentifier,
            iconURL: packageIconURL
        )
    }
}

private struct DownloadRuntimeSaveData: Codable {
    let status: DownloadStatus
    let progressValue: Double
    let error: String?
    let speed: String
    let localFilePath: String?
}
