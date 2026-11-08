import Foundation
import Testing

private struct AccentAsset: Decodable {
    struct Entry: Decodable {
        struct Color: Decodable {
            struct Components: Decodable, Equatable {
                let red: String
                let green: String
                let blue: String
            }
            let components: Components
        }
        let color: Color
    }
    let colors: [Entry]
}

@Test func nativeAccentColorsMeetNormalTextContrastInLightAndDarkModes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let phone = try Data(contentsOf: root.appendingPathComponent("iPhone/Assets.xcassets/AccentColor.colorset/Contents.json"))
    let watch = try Data(contentsOf: root.appendingPathComponent("Watch/Assets.xcassets/AccentColor.colorset/Contents.json"))
    let colors = try JSONDecoder().decode(AccentAsset.self, from: phone).colors
    let watchColors = try JSONDecoder().decode(AccentAsset.self, from: watch).colors
    #expect(colors.count == 2)
    #expect(watchColors.count == 2)
    let dark = try #require(colors.last)
    // watchOS can resolve the default asset variant even on its black surfaces.
    #expect(watchColors.allSatisfy { $0.color.components == dark.color.components })
    func luminance(_ channels: [Double]) -> Double {
        let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    for (index, entry) in (colors + watchColors).enumerated() {
        let rgb = try [entry.color.components.red, entry.color.components.green, entry.color.components.blue]
            .map { try #require(Double($0)) }
        let foreground = luminance(rgb)
        let backgrounds =
            index == 0
            ? [[1.0, 1.0, 1.0], [242.0 / 255, 242.0 / 255, 247.0 / 255]] : [[0.0, 0.0, 0.0], [28.0 / 255, 28.0 / 255, 30.0 / 255]]
        for background in backgrounds {
            let backdrop = luminance(background)
            let ratio = (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
            #expect(ratio >= 4.5, "Accent contrast \(ratio) must meet WCAG AA normal-text contrast.")
        }
    }
}
