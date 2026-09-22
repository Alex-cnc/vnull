import Foundation
import DoyahCore

enum SQLCompleter {
    static func suggestions(for prefix: String, dialect: SQLDialect) -> [String] {
        let normalized = prefix.uppercased()
        let candidates = dialect.keywords + dialect.builtinFunctions
        guard !normalized.isEmpty else { return Array(candidates.prefix(20)) }
        return candidates
            .filter { $0.uppercased().hasPrefix(normalized) }
            .sorted()
            .prefix(20)
            .map { $0 }
    }
}
