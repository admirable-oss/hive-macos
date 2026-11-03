import SwiftUI

extension Color {
    /// Hive's brand amber. Read from the asset directly so it stays amber even
    /// when the user has picked a different system accent color.
    static let hiveAmber = Color("AccentColor")
}
