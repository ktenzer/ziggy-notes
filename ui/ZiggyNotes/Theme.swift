import SwiftUI

/// Design tokens for a modern, Temporal-branded look: off-white canvas, Temporal
/// purple accents, black text, and priority color-coding for suggestions.
enum Theme {
    // Official Temporal brand palette (temporal.io/brand):
    //   UV        R68 G76 B231  (#444CE7)
    //   Off White R248 G250 B252 (#F8FAFC)
    static let background = Color(red: 0.973, green: 0.980, blue: 0.988)   // #F8FAFC off-white
    static let card = Color.white
    static let purple = Color(red: 0.267, green: 0.298, blue: 0.906)        // #444CE7 Temporal UV
    static let purpleDark = Color(red: 0.184, green: 0.216, blue: 0.722)    // deeper UV
    static let textPrimary = Color.black
    static let textSecondary = Color(white: 0.34)
    static let hairline = Color(white: 0.0, opacity: 0.08)

    static let highPriority = Color(red: 0.84, green: 0.16, blue: 0.20)     // red
    static let mediumPriority = Color(red: 0.93, green: 0.55, blue: 0.09)   // amber
    static let lowPriority = Color(red: 0.13, green: 0.60, blue: 0.33)      // green

    static func priorityColor(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "high": return highPriority
        case "medium": return mediumPriority
        case "low": return lowPriority
        default: return purple
        }
    }

    static func priorityIcon(_ priority: String) -> String {
        switch priority.lowercased() {
        case "high": return "exclamationmark.triangle.fill"
        case "medium": return "lightbulb.fill"
        case "low": return "info.circle.fill"
        default: return "sparkles"
        }
    }
}

extension View {
    /// Standard rounded card styling used across the app.
    func ziggyCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 3)
    }
}
