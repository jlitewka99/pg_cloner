import Foundation
import PGClonerCore

struct AzureCLI: Sendable {
    func accessToken(customPath: String?) async throws -> String {
        let executable = try locate(customPath: customPath)

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executable
            process.arguments = [
                "account",
                "get-access-token",
                "--resource-type",
                "oss-rdbms",
                "--query",
                "accessToken",
                "-o",
                "tsv"
            ]
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw CloneEngineError.azureCLI(error.localizedDescription)
            }
            process.waitUntilExit()

            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CloneEngineError.azureCLI(
                    message.nilIfBlank.map(Self.redacted)
                        ?? "Exit code \(process.terminationStatus). Run `az login` and try again."
                )
            }

            let token = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let token = token.nilIfBlank else {
                throw CloneEngineError.azureCLI("Azure CLI returned an empty token.")
            }
            return token
        }.value
    }

    func locate(customPath: String?) throws -> URL {
        let candidates = [
            customPath,
            "/opt/homebrew/bin/az",
            "/usr/local/bin/az",
            "/usr/bin/az"
        ].compactMap { $0?.nilIfBlank }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CloneEngineError.azureCLINotFound
    }

    private static func redacted(_ value: String) -> String {
        [
            (
                #"(?i)\b(access[_-]?token|refresh[_-]?token|password)\s*[:=]\s*["']?[^"',\s;]+"#,
                "$1=<redacted>"
            ),
            (#"(?i)\beyJ[A-Za-z0-9._-]{20,}"#, "<redacted-token>")
        ].reduce(value) { message, replacement in
            message.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }
}
