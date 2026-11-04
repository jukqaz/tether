import SwiftUI

/// Live views pass the native values; optional snapshot injections never change macOS settings.
struct WorkSessionVisualPreferences {
    let contrast: ColorSchemeContrast
    let reduceTransparency: Bool
    var usesOpaqueControls: Bool { reduceTransparency || contrast == .increased }
    var borderOpacity: Double { contrast == .increased ? 0.4 : 0.07 }
    var borderWidth: CGFloat { contrast == .increased ? 1 : 0.5 }
    var borderColor: Color {
        contrast == .increased ? Color.tetherPrimary.opacity(borderOpacity) : Color.tetherControlBorder
    }
}
