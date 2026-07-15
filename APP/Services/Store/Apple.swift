import Foundation

public struct Account: Codable, Identifiable {
    public var id: String { email }

    public let name: String
    public let email: String
    public let firstName: String
    public let lastName: String

    public let passwordToken: String
    public let directoryServicesIdentifier: String
    public let dsPersonId: String

    public let cookies: [String]
    public let countryCode: String

    public let storeResponse: AccountStoreResponse

    public var deviceGUID: String

    public init(
        name: String,
        email: String,
        firstName: String,
        lastName: String,
        passwordToken: String,
        directoryServicesIdentifier: String,
        dsPersonId: String,
        cookies: [String] = [],
        countryCode: String = "",
        storeResponse: AccountStoreResponse,
        deviceGUID: String = ""
    ) {
        self.name = name
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.passwordToken = passwordToken
        self.directoryServicesIdentifier = directoryServicesIdentifier
        self.dsPersonId = dsPersonId
        self.cookies = cookies
        self.countryCode = countryCode
        self.storeResponse = storeResponse
        if deviceGUID.isEmpty {
            self.deviceGUID = Account.generateDeviceGUID()
        } else {
            self.deviceGUID = deviceGUID
        }
    }

    private static func generateDeviceGUID() -> String {
        let guid = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased()
        return String(guid)
    }

    public struct AccountStoreResponse: Codable {
        public let directoryServicesIdentifier: String
        public let passwordToken: String
        public let storeFront: String
        public init(directoryServicesIdentifier: String, passwordToken: String, storeFront: String) {
            self.directoryServicesIdentifier = directoryServicesIdentifier
            self.passwordToken = passwordToken
            self.storeFront = storeFront
        }
    }
    enum CodingKeys: String, CodingKey {
        case name = "n"
        case email = "e"
        case firstName = "fn"
        case lastName = "ln"
        case passwordToken = "p"
        case directoryServicesIdentifier = "dsi"
        case dsPersonId = "d"
        case cookies = "c"
        case countryCode = "cc"
        case storeResponse = "sr"
        case deviceGUID = "guid"
    }
}

public enum Apple: @unchecked Sendable {

    static let storeFrontCodeMap: [String: String] = [
        "US": "143441", "CN": "143465", "JP": "143462", "GB": "143444",
        "DE": "143443", "FR": "143442", "AU": "143460", "CA": "143455",
        "IT": "143450", "ES": "143454", "KR": "143466", "BR": "143503",
        "MX": "143468", "IN": "143467", "RU": "143469", "NL": "143452",
        "SE": "143456", "NO": "143457", "DK": "143458", "FI": "143447"
    ]
}


