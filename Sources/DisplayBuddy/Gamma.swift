import CoreGraphics
import Foundation

/// Software picture adjustments. We use the screen's colour curves (gamma
/// tables) for two things the monitor hardware can't do on its own:
///  - "sub-zero" dimming below the monitor's lowest backlight level
///  - warm/cool colour temperature
enum Gamma {
    static let tableSize = 256

    /// dim: 1.0 = normal, 0.05 = almost black. kelvin: 6500 = neutral.
    static func apply(to display: CGDirectDisplayID, dim: Double, kelvin: Double) {
        let white = whitePoint(kelvin: kelvin)
        var r = [CGGammaValue](repeating: 0, count: tableSize)
        var g = r, b = r
        for i in 0 ..< tableSize {
            let v = Double(i) / Double(tableSize - 1)
            r[i] = CGGammaValue(v * dim * white.r)
            g[i] = CGGammaValue(v * dim * white.g)
            b[i] = CGGammaValue(v * dim * white.b)
        }
        CGSetDisplayTransferByTable(display, UInt32(tableSize), &r, &g, &b)
    }

    static func isNeutral(dim: Double, kelvin: Double) -> Bool {
        dim >= 0.999 && abs(kelvin - 6500) < 50
    }

    static func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }

    /// Converts a colour temperature in Kelvin to RGB multipliers (0...1),
    /// normalised so 6500K is pure white. Based on Tanner Helland's fit of
    /// black-body radiation data.
    static func whitePoint(kelvin: Double) -> (r: Double, g: Double, b: Double) {
        func raw(_ k: Double) -> (Double, Double, Double) {
            let t = min(max(k, 1000), 40000) / 100
            var r, g, b: Double
            if t <= 66 {
                r = 255
                g = 99.4708025861 * log(t) - 161.1195681661
                b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
            } else {
                r = 329.698727446 * pow(t - 60, -0.1332047592)
                g = 288.1221695283 * pow(t - 60, -0.0755148492)
                b = 255
            }
            let c = { (x: Double) in min(max(x, 0), 255) / 255 }
            return (c(r), c(g), c(b))
        }
        let ref = raw(6500)
        let v = raw(kelvin)
        return (min(v.0 / ref.0, 1), min(v.1 / ref.1, 1), min(v.2 / ref.2, 1))
    }
}
