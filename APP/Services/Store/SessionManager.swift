import Foundation
import Combine
import SwiftUI

@MainActor
class SessionManager: ObservableObject, @unchecked Sendable {
    static let shared = SessionManager()

    @Published var isSessionValid = true
    @Published var isReconnecting = false
    @Published var lastSessionCheck = Date()
    @Published var sessionError: String?

    private var sessionTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    private let sessionCheckInterval: TimeInterval = 30
    private let sessionTimeout: TimeInterval = 300

    private init() {
        startSessionMonitoring()
    }

    deinit {
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    func startSessionMonitoring() {
        print("🔐 [SessionManager] 开始会话监控")
        sessionTimer = Timer.scheduledTimer(withTimeInterval: sessionCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkSessionValidity()
            }
        }
    }

    @MainActor
    func stopSessionMonitoring() {
        print("🔐 [SessionManager] 停止会话监控")
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    func checkSessionValidity() async {
        guard let account = AppStore.this.selectedAccount else {
            print("🔐 [SessionManager] 没有当前选中的账户，跳过会话检查")
            return
        }

        print("🔐 [SessionManager] 检查会话有效性...")

        let isValid = await validateSessionWithAPI(account: account)

        if isValid {
            print("✅ [SessionManager] 会话有效")
            isSessionValid = true
            sessionError = nil
            reconnectAttempts = 0
            lastSessionCheck = Date()
        } else {
            print("❌ [SessionManager] 无效，需要重新认证")
            await handleSessionInvalid()
        }
    }

    private func validateSessionWithAPI(account: Account) async -> Bool {

        return await AuthenticationManager.shared.validateAccount(account)
    }

    private func handleSessionInvalid() async {
        print("🔐 [SessionManager] 处理会话无效")
        isSessionValid = false

        if reconnectAttempts < maxReconnectAttempts {
            await attemptReconnection()
        } else {
            sessionError = "Apple ID会话已过期，请重新登录"
            print("🔐 [SessionManager] 重连尝试次数已达上限")
        }
    }

    private func attemptReconnection() async {
        guard let account = AppStore.this.selectedAccount else {
            print("🔐 [SessionManager] 没有当前选中的账户，无法重连")
            return
        }

        reconnectAttempts += 1
        isReconnecting = true
        sessionError = "正在重新连接... (\(reconnectAttempts)/\(maxReconnectAttempts))"

        print("🔄 [SessionManager] 尝试重新连接 (\(reconnectAttempts)/\(maxReconnectAttempts))")

        let refreshedAccount = AuthenticationManager.shared.refreshCookies(for: account)

        let isValid = await validateSessionWithAPI(account: refreshedAccount)

        if isValid {
            print("✅ [SessionManager] 重连成功")
            isSessionValid = true
            isReconnecting = false
            sessionError = nil
            reconnectAttempts = 0
            lastSessionCheck = Date()

            await notifySessionRestored()
        } else {
            print("❌ [SessionManager] 重连失败")
            isReconnecting = false
            sessionError = "重连失败，请检查网络连接"
        }
    }

    private func notifySessionRestored() async {
        print("🔐 [SessionManager] 通知会话已恢复")

        NotificationCenter.default.post(name: .sessionRestored, object: nil)

        AppStore.this.refreshAccount()
    }

    func manualSessionCheck() async {
        print("🔐 [SessionManager] 手动检查会话")
        await checkSessionValidity()
    }

    func forceReauthentication() async {
        print("🔐 [SessionManager] 强制重新认证")
        isSessionValid = false
        isReconnecting = false
        sessionError = "需要重新登录"
        reconnectAttempts = maxReconnectAttempts
    }

    func resetSessionState() {
        print("🔐 [SessionManager] 重置会话状态")
        isSessionValid = true
        isReconnecting = false
        sessionError = nil
        reconnectAttempts = 0
        lastSessionCheck = Date()
    }

    func resumeFailedDownloads() async {
        print("🔐 [SessionManager] 恢复失败的下载任务")

        let downloadManager = UnifiedDownloadManager.shared

        for request in downloadManager.downloadRequests {
            if request.runtime.status == .failed &&
               request.runtime.error?.contains("认证") == true {
                print("🔄 [SessionManager] 恢复下载任务: \(request.name)")

                request.runtime.status = .waiting
                request.runtime.error = nil
                request.runtime.progressValue = 0

                downloadManager.startDownload(for: request)
            }
        }
    }
}

extension Notification.Name {
    static let sessionRestored = Notification.Name("sessionRestored")
    static let sessionInvalid = Notification.Name("sessionInvalid")
}
