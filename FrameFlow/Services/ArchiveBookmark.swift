import Foundation
import Security

/// Store only the system folder grant. Files manages the server login.
enum ArchiveBookmark {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "FrameFlow") + ".archive",
         kSecAttrAccount as String: "last-folder"]
    }

    static func save(_ url: URL) throws {
        let data = try ScopedFile.access(url) {
            try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { _, rhs in rhs } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw FlowError("无法保存归档目录授权（\(status)）") }
    }

    static func load() throws -> URL {
        var request = query
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            throw FlowError("请先选择归档目录")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw FlowError("目录授权已过期，请重新选择") }
        return url
    }
}
