import SwiftUI

extension Color {
    static func necessity(_ value: String) -> Color {
        switch value {
        case "必要": return .indigo
        case "便利": return .orange
        case "贅沢": return .pink
        default:    return .gray
        }
    }
}
