# XRG Face Lift: Design Direction

Locked in 2026-11-20. This is the target look for the modernized XRG.

## Direction: horizontal Liquid Glass strip

The main window is a single horizontal strip that floats on the desktop. The order and density of the original XRG stay the same, with a modern glass treatment.

### Window
- One rounded glass bar (corner radius ~20pt) using `NSGlassEffectView` on macOS 26+.
- Fallback to `NSVisualEffectView` blur on older macOS.
- Thin vertical "XRG" label on the leading edge (replaces the vertical hostname).
- 6pt inner padding, 6pt gap between modules.

### Modules
- Each module is its own inner card: ~13pt radius, faint white tint, hairline border.
- Header row: module name (small, muted) on the left, headline number (larger, medium weight, tabular figures) on the right.
- Secondary stats underneath as aligned label/value pairs, not cryptic single letters.
- Graph anchored to the bottom of the card: anti-aliased line plus a soft translucent fill.
- Modules with nothing to report (for example, Battery on a desktop Mac) hide automatically.

### Per-module details
| Module | Headline | Secondary stats | Graph |
|---|---|---|---|
| CPU | Total % | Average, load, uptime | Per-core bars, split Performance vs Efficiency cores |
| GPU | Utilization % | VRAM used / total | Line plus fill |
| Memory | Active | Active, Wired, Inactive, Free | Stacked usage bar plus history line |
| Network | Current rate | Total transferred | Mirrored: receive up, transmit down |
| Disk | Current rate | Total transferred | Mirrored: read up, write down |
| Temperature | Hottest sensor | Optional | Line plus fill |

### Color
- One color per metric, consistent everywhere: CPU teal, GPU pink, Memory blue (wired violet), Network receive coral / transmit violet, Disk read teal / write amber, Temperature amber.
- Text is white or a muted white on the glass. Follow system light/dark and accent color where it makes sense.
- Keep user-customizable colors and transparency from the original preferences.

### Typography
- SF Pro for labels, tabular numerals for all values.
- Minimum label size about 11pt.

### Keep from the original
- Existing module order, layout options, and transparency settings.
- A "Classic" appearance option for anyone who wants the old look.

### Order of work
1. Get the project building on the current SDK.
2. Fix sensor readings on Apple Silicon.
3. Then apply this design.
