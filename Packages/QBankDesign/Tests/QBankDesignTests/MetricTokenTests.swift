import Foundation
import Testing
@testable import QBankDesign

@Suite("Type, spacing, radii, elevation and motion match the web")
struct MetricTokenTests {
    let typography: [String: String]
    let spacing: WebTokens

    init() throws {
        typography = try #require(WebTokens(file: "typography").blocks[":root"])
        spacing = try WebTokens(file: "spacing")
    }

    /// The web's names for each style: `--size-<size>` / `--lh-<size>` and `--text-<shorthand>`.
    static let webNames: [QBankTextStyle: (size: String, shorthand: String)] = [
        .largeTitle: ("large-title", "large-title"), .title1: ("title-1", "title-1"),
        .title2: ("title-2", "title-2"), .title3: ("title-3", "title-3"),
        .headline: ("headline", "headline"), .body: ("body", "body"), .callout: ("callout", "callout"),
        .subheadline: ("subhead", "subhead"), .footnote: ("footnote", "footnote"),
        .caption1: ("caption-1", "caption"), .caption2: ("caption-2", "caption-2"),
        .reading: ("reading", "reading"), .readingLarge: ("reading-lg", "reading-lg"),
        .readingSmall: ("reading-sm", "reading-sm"),
    ]

    @Test("Type scale: size, line height, weight and face", arguments: QBankTextStyle.allCases)
    func typeScale(style: QBankTextStyle) throws {
        let names = try #require(Self.webNames[style])
        #expect(try WebTokens.number(WebTokens.resolve("--size-\(names.size)", in: typography), unit: "px") == style.size)
        #expect(try WebTokens.number(WebTokens.resolve("--lh-\(names.size)", in: typography), unit: "px") == style.lineHeight)

        // e.g. "var(--weight-bold) var(--size-title-1)/var(--lh-title-1) var(--font-display)"
        let shorthand = try #require(typography["--text-\(names.shorthand)"])
        let weightName = try #require(shorthand.split(separator: " ").first).dropFirst(4).dropLast()
        let weight = try WebTokens.resolve(String(weightName), in: typography)
        #expect(Int(weight) == style.weight.cssValue)
        #expect(shorthand.hasSuffix("var(--font-mono)") == (style.design == .monospaced))
    }

    @Test("Every Dynamic Type size the web defines has a Swift style")
    func noTypeSizeIsMissing() {
        let webSizes = Set(typography.keys.filter { $0.hasPrefix("--size-") })
        let swiftSizes = Set(Self.webNames.values.map { "--size-\($0.size)" })
        #expect(webSizes == swiftSizes)
    }

    @Test("Tracking")
    func tracking() throws {
        #expect(try WebTokens.number(#require(typography["--tracking-tight"]), unit: "px") == QBankTextStyle.largeTitle.tracking)
        // The web sets tight tracking on the large title and title 1 only.
        for style in QBankTextStyle.allCases {
            let expected = [.largeTitle, .title1].contains(style) ? -0.4 : 0
            #expect(style.tracking == expected, "\(style)")
        }
        #expect(try WebTokens.number(#require(typography["--tracking-caps"]), unit: "em") == QBankTextStyle.capsTrackingEm)
    }

    @Test("Spacing, radii, borders and layout")
    func lengths() throws {
        let root = try #require(spacing.blocks[":root"])
        let expectations: [(String, CGFloat)] = [
            ("--space-0", QBankSpacing.space0), ("--space-1", QBankSpacing.space1), ("--space-2", QBankSpacing.space2),
            ("--space-3", QBankSpacing.space3), ("--space-4", QBankSpacing.space4), ("--space-5", QBankSpacing.space5),
            ("--space-6", QBankSpacing.space6), ("--space-7", QBankSpacing.space7), ("--space-8", QBankSpacing.space8),
            ("--space-9", QBankSpacing.space9), ("--space-10", QBankSpacing.space10), ("--space-11", QBankSpacing.space11),
            ("--gutter-phone", QBankSpacing.gutterPhone), ("--gutter-tablet", QBankSpacing.gutterTablet),
            ("--gap-stack", QBankSpacing.gapStack), ("--gap-section", QBankSpacing.gapSection),
            ("--row-min", QBankSpacing.rowMin), ("--row-pad-y", QBankSpacing.rowPaddingVertical),
            ("--row-pad-x", QBankSpacing.rowPaddingHorizontal),
            ("--radius-xs", QBankRadius.xs), ("--radius-sm", QBankRadius.sm),
            ("--radius-md", QBankRadius.md), ("--radius-lg", QBankRadius.lg),
            ("--border-hairline", QBankBorder.hairline), ("--border-1", QBankBorder.regular),
            ("--border-2", QBankBorder.emphasis),
            ("--sidebar-width", QBankLayout.sidebarWidth), ("--content-max", QBankLayout.contentMax),
            ("--content-max-wide", QBankLayout.contentMaxWide), ("--tabbar-height", QBankLayout.tabBarHeight),
            ("--navbar-height", QBankLayout.navBarHeight),
        ]
        for (name, value) in expectations {
            let literal = try #require(root[name], "\(name) is missing on the web")
            #expect(try WebTokens.number(literal, unit: "px") == Double(value), "\(name)")
        }
        let webSpaces = root.keys.filter { $0.hasPrefix("--space-") }
        #expect(webSpaces.count == 12)
    }

    @Test("Motion durations and curves")
    func motion() throws {
        let root = try #require(spacing.blocks[":root"])
        let durations: [(String, Double)] = [
            ("--dur-instant", QBankMotion.instant), ("--dur-quick", QBankMotion.quick),
            ("--dur-standard", QBankMotion.standard), ("--dur-sheet", QBankMotion.sheet),
        ]
        for (name, seconds) in durations {
            #expect(try WebTokens.number(#require(root[name]), unit: "ms") == (seconds * 1000).rounded(), "\(name)")
        }
        let curves: [(String, QBankMotion.Curve)] = [
            ("--ease-standard", QBankMotion.easeStandard), ("--ease-out", QBankMotion.easeOut),
            ("--ease-sheet", QBankMotion.easeSheet),
        ]
        for (name, curve) in curves {
            let points = "cubic-bezier(\(curve.x1), \(curve.y1), \(curve.x2), \(curve.y2))"
                .replacingOccurrences(of: ".0,", with: ",").replacingOccurrences(of: ".0)", with: ")")
            #expect(root[name] == points, "\(name)")
        }
    }

    @Test("Elevation: light shadows and dark rings", arguments: QBankElevation.allCases)
    func elevation(level: QBankElevation) throws {
        let name = "--shadow-\(level.rawValue)"
        let light = try WebTokens.shadows(#require(spacing.blocks[":root"]?[name]))
        #expect(light.allSatisfy { $0.spread == 0 })
        #expect(
            level.shadows(.light)
                == light.map {
                    QBankShadowLayer(color: $0.color, x: CGFloat($0.x), y: CGFloat($0.y), blur: CGFloat($0.blur))
                })
        #expect(level.ring(.light) == nil)

        let dark = try WebTokens.shadows(#require(spacing.blocks["[data-theme=\"dark\"]"]?[name]))
        let rings = dark.filter { $0.spread > 0 }
        #expect(rings.allSatisfy { $0.spread == Double(QBankBorder.hairline) && $0.blur == 0 && $0.x == 0 && $0.y == 0 })
        #expect(level.ring(.dark) == rings.first?.color)
        #expect(
            level.shadows(.dark)
                == dark.filter { $0.spread == 0 }.map {
                    QBankShadowLayer(color: $0.color, x: CGFloat($0.x), y: CGFloat($0.y), blur: CGFloat($0.blur))
                })
    }
}
