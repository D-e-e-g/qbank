# QBankDesign

The QBank design system for SwiftUI, ported from the web app's tokens so the iPhone app looks like the web: warm paper neutrals, one accent, calm motion, and states that never rely on color alone.

iOS 18 and later. macOS 15 is supported only so `swift test` runs on a Mac.

## Tokens

| Token | Swift | Web |
|---|---|---|
| Semantic colors | `QBankColorToken` (`.bg`, `.surface`, `.text1`, `.tint`, `.correct`, ...) | `--bg`, `--surface`, `--text-1`, `--tint`, `--correct`, ... |
| Palettes | `QBankPalette` (`.dusk` default, `.pink`, `.ink`, `.earth`, `.slate`) | `data-palette` |
| Light and dark | `QBankAppearance`, from the view's color scheme | `data-theme` |
| Raw ramps | `QBankBaseColors` (`paper100`, `dusk600`, ...) | `--paper-100`, `--dusk-600`, ... |
| Type scale | `QBankTextStyle` | `--size-*`, `--lh-*`, `--text-*` |
| Spacing, radii, borders, layout | `QBankSpacing`, `QBankRadius`, `QBankBorder`, `QBankLayout` | `--space-*`, `--radius-*`, `--border-*` |
| Elevation | `QBankElevation` | `--shadow-*` |
| Motion | `QBankMotion` | `--dur-*`, `--ease-*` |

Use semantic colors in screens, never the raw ramps, so the palette and dark mode keep working:

```swift
Text("Mental Health")
    .qbankFont(.headline)
    .foregroundStyle(.qbank(.text1))

ContentView()
    .qbankPalette(.dusk)   // set once near the root
```

`.qbank(_:)` is a `ShapeStyle` that resolves against the view's palette and color scheme, so it works anywhere a shape style does (`foregroundStyle`, `fill`, `background`, `tint`). `QBankRGBA.color` gives a fixed `Color` where an API needs one.

`qbankFont(_:)` sets size, weight, face, tracking and the web's line height, all scaled with Dynamic Type. Sizes are Apple's "Large" sizes, so every style follows a `Font.TextStyle`. Footnote and captions are SF Mono, as on the web. The reading styles (`.reading`, `.readingLarge`, `.readingSmall`) are for question stems and rationales.

## Components

Picked from the approved iPhone wireframes:

| Component | Use |
|---|---|
| `.buttonStyle(.qbank(.primary, size: .large, fullWidth: true))` | Buttons: primary, secondary, quiet, plain, destructive; large, medium, small |
| `QBankCard`, `.buttonStyle(.qbankCard)`, `.qbankCardBackground()` | Cards such as the course card |
| `QBankTintedLabel` | Pills: "12 to review", "Exam bank · 17 questions", "No exam bank yet" |
| `QBankStatusMark` | Icon plus word for an answer status: Correct, Partly right, Missed, Guessed, Not answered |
| `QBankListGroup`, `QBankListRow`, `.buttonStyle(.qbankRow)`, `QBankSectionHeader` | Inset grouped lists: pages with their badge tags, folders and their sets, Review, Settings |
| `QBankDetailText` | A row's detail line, such as "2 sets · 9 of 26 answered", that breaks at its separators |
| `QBankProgressBar`, `QBankProgressPill` | The progress track, and the course card's track with its percentage |
| `QBankTimerPill` | The exam countdown, with its low-time state |
| `QBankSegmentedControl` | One choice of a few, such as Look in Settings (Match device, Light, Dark) |
| `QBankMark`, `QBankMarkShape` | The app icon's Q on its Dusk tile, over the sign-in and lock screens; the same in every palette and in dark mode, as the icon is |

Every component file has SwiftUI previews, and `QBankGallery` shows them all together in light, dark and every palette.

## Tests

```sh
swift test
```

The tests read unmodified copies of the web's token stylesheets (`Tests/QBankDesignTests/Fixtures/web-tokens`), resolve them the way a browser does, and check every Swift token against them for every palette in light and dark. When the web tokens change, copy the new files in and the failures name each token that drifted.

To render the gallery to PNGs for a visual check:

```sh
QBANK_DESIGN_RENDER_DIR=/tmp/qbank-gallery swift test --filter GalleryRender
```

On the iOS Simulator, from this folder (Dynamic Type scaling only shows in these renders):

```sh
TEST_RUNNER_QBANK_DESIGN_RENDER_DIR=/tmp/qbank-gallery ../../test/sim.sh -- \
  xcodebuild test -scheme QBankDesign -destination 'platform=iOS Simulator,id={{UDID}}'
```

The tokens build without SwiftUI; the components and their tests build only on Apple platforms.
