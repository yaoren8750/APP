import Foundation

@MainActor
class BagManager: ObservableObject {
    static let shared = BagManager()

    @Published private(set) var isLoaded: Bool = false
    private var bagData: [String: Any] = [:]
    private var lastLoadTime: Date?
    private let cacheDuration: TimeInterval = 3600

    private init() {}

    var buyURL: String {
        if let url = bagData["buyProductURL"] as? String {
            return url
        }
        return "https://buy.itunes.apple.com"
    }

    var downloadURL: String {
        if let url = bagData["downloadProductURL"] as? String {
            return url
        }
        return "https://p25-buy.itunes.apple.com"
    }

    var searchURL: String {
        if let url = bagData["searchURL"] as? String {
            return url
        }
        return "https://itunes.apple.com"
    }

    func value(forKey key: String) -> Any? {
        return bagData[key]
    }

    func loadBagIfNeeded(storeFront: String = "143441-1,32") async {
        let needsReload = !isLoaded ||
            bagData.isEmpty ||
            lastLoadTime == nil ||
            Date().timeIntervalSince(lastLoadTime!) > cacheDuration

        guard needsReload else { return }

        await loadBag(storeFront: storeFront)
    }

    func loadBag(storeFront: String = "143441-1,32") async {
        let bagURL = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/bag?ignoring-cache=true&sn=email@domain.com"

        guard let url = URL(string: bagURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")
        request.setValue(storeFront, forHTTPHeaderField: "X-Apple-Store-Front")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] {
                parseBagData(plist)
            }
        } catch {
            print("⚠️ [BagManager] 加载 Bag 失败: \(error.localizedDescription)")
        }
    }

    private func parseBagData(_ plist: [String: Any]) {
        bagData.removeAll()

        if let buyURL = plist["buyProductURL"] as? String {
            bagData["buyProductURL"] = buyURL
        }
        if let downloadURL = plist["downloadProductURL"] as? String {
            bagData["downloadProductURL"] = downloadURL
        } else if let musicURL = plist["musicStoreURL"] as? String {
            bagData["downloadProductURL"] = musicURL
        }
        if let searchURL = plist["searchURL"] as? String {
            bagData["searchURL"] = searchURL
        }

        for (key, value) in plist {
            if bagData[key] == nil {
                bagData[key] = value
            }
        }

        lastLoadTime = Date()
        isLoaded = true

        print("✅ [BagManager] Bag 配置加载成功，共 \(bagData.count) 个配置项")
    }

    func reset() {
        bagData.removeAll()
        lastLoadTime = nil
        isLoaded = false
    }
}
