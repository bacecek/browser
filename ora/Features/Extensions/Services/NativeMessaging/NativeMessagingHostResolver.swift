import Foundation

/// A validated Native Messaging Host manifest (`<host name>.json`), Chrome's
/// format: `name`, `path` to the host executable, `type: "stdio"`, and the
/// `allowed_origins` list naming which extensions may connect.
struct NativeMessagingHostManifest: Equatable {
    let name: String
    let path: String
    let allowedOrigins: [String]

    var executableURL: URL {
        URL(fileURLWithPath: path)
    }
}

/// Locates and validates Native Messaging Host manifests. Search order is
/// Ora's own directory first, then Chrome's user and system directories, so
/// hosts already installed for Chrome (1Password's BrowserSupport) work with
/// zero setup while Ora-only hosts don't have to squat in Chrome's
/// directories. First match wins; a found-but-invalid manifest is an error,
/// never a fall-through.
struct NativeMessagingHostResolver {
    let searchDirectories: [URL]

    init(searchDirectories: [URL] = Self.defaultSearchDirectories()) {
        self.searchDirectories = searchDirectories
    }

    static func defaultSearchDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Application Support/Ora/NativeMessagingHosts",
                isDirectory: true
            ),
            home.appendingPathComponent(
                "Library/Application Support/Google/Chrome/NativeMessagingHosts",
                isDirectory: true
            ),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        ]
    }

    func resolve(hostName: String) throws -> NativeMessagingHostManifest {
        guard Self.isValidHostName(hostName) else {
            throw NativeMessagingError.invalidHostName(hostName)
        }

        for directory in searchDirectories {
            let manifestURL = directory.appendingPathComponent("\(hostName).json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            return try validatedManifest(at: manifestURL, hostName: hostName)
        }
        throw NativeMessagingError.hostNotFound(hostName)
    }

    /// Chrome's host naming rules: lowercase alphanumerics, underscores and
    /// dots; must not start or end with a dot, and dots must not be adjacent.
    static func isValidHostName(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.hasPrefix("."),
              !name.hasSuffix("."),
              !name.contains("..")
        else { return false }
        return name.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "." || character == "_")
        }
    }

    private func validatedManifest(at manifestURL: URL, hostName: String) throws -> NativeMessagingHostManifest {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw NativeMessagingError.invalidManifest(hostName: hostName, reason: error.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeMessagingError.invalidManifest(hostName: hostName, reason: "not a JSON object")
        }
        guard let name = object["name"] as? String, name == hostName else {
            throw NativeMessagingError.invalidManifest(hostName: hostName, reason: "name does not match the host")
        }
        guard object["type"] as? String == "stdio" else {
            throw NativeMessagingError.invalidManifest(hostName: hostName, reason: "type must be \"stdio\"")
        }
        guard let path = object["path"] as? String, path.hasPrefix("/") else {
            throw NativeMessagingError.invalidManifest(hostName: hostName, reason: "path must be absolute")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw NativeMessagingError.invalidManifest(hostName: hostName, reason: "path is not an executable file")
        }
        let allowedOrigins = object["allowed_origins"] as? [String] ?? []

        return NativeMessagingHostManifest(name: name, path: path, allowedOrigins: allowedOrigins)
    }
}
