# CadMac — open-source 2D CAD for macOS

**CadMac** is a fast, native **2D CAD application for macOS** with real **DWG and DXF** support, GPU (Metal) rendering, and a built-in automation / **MCP** server so AI assistants and scripts can drive the drawing. It is free and open source (GPL-3.0).

> Native Swift · Metal-accelerated · DWG/DXF read & write · scriptable via MCP — a lightweight CAD / DWG viewer and editor alternative for Mac.

![version](https://img.shields.io/badge/version-0.2.0-eb5e28) ![platform](https://img.shields.io/badge/macOS-14%2B-1e1c1a) ![license](https://img.shields.io/badge/license-GPL--3.0-40916c)

## Download

**[⬇ Download the latest CadMac.dmg](https://github.com/nsroot/CadMac/releases/latest/download/CadMac.dmg)** — macOS 14 (Sonoma) or newer, Apple Silicon & Intel.

Open the `.dmg`, drag **CadMac** to Applications, and launch. On first run macOS Gatekeeper may ask you to confirm opening an app from an unidentified developer (right-click → Open).

## Features

- **Drawing** — line, polyline, rectangle, circle, arc, ellipse, point, text & multiline text (MText), splines.
- **Dimensions** — linear, aligned, radius, diameter, angular.
- **Hatching** — solid and pattern fills, boundary detection from closed areas.
- **Blocks** — block definitions, inserts and attributes (ATTDEF).
- **Modify** — move, copy, trim, extend, fillet, chamfer, offset, array, join, align, overkill, groups.
- **Precision** — object snap (OSnap), grid, ortho & polar tracking, undo/redo.
- **Layers** — full layer management with colors and linetypes; paper-space layouts & viewports.
- **File formats** — open & save **DWG** (native reader/writer, no external converter) and **DXF**; **PDF** / print output.
- **GPU rendering** — Metal-accelerated canvas that stays smooth on large drawings.
- **Automation / MCP** — a built-in [Model Context Protocol](https://modelcontextprotocol.io) server (`cadmac-mcp`) lets Claude and other AI tools read the drawing, add and modify entities, measure, count blocks, and extract quantities — ideal for **BOQ / takeoff** workflows.

## Automate with AI (MCP)

CadMac ships a companion `cadmac-mcp` executable that exposes tools such as `get_drawing_info`, `list_entities`, `add_entities`, `modify_entities`, `measure`, `find_closed_areas`, `screenshot` and `zoom`. Point any MCP client (e.g. Claude Desktop / Claude Code) at it to script CAD work. Every change is previewed in the app and only applied when you approve it.

## Build from source

Requirements: macOS 14+, Swift 5.10+ (Xcode or Command Line Tools).

```bash
git clone https://github.com/nsroot/CadMac.git
cd CadMac
swift build -c release        # or: ./build-app.sh  to produce CadMac.app
swift test                    # run the test suite (DXF/DWG/modify/tools)
```

The project is a Swift Package with three products:

| Target | What it is |
|---|---|
| `CadMac` | the macOS app (AppKit + Metal UI) |
| `cadmac-mcp` | the automation / MCP server executable |
| `CadCore` | the geometry, DXF & DWG engine (reusable library) |

## Contributing

Issues and pull requests are welcome. The core geometry, DXF and DWG code lives in `Sources/CadCore` and is covered by tests in `Tests/`; please add or update tests with changes.

## License

CadMac is released under the **GNU General Public License v3.0**. See [LICENSE](LICENSE). This means you are free to use, study, share and modify it, but derivative works must also remain open source under the same license.

---

*Keywords: open source 2D CAD for macOS, free DWG viewer Mac, DWG editor macOS, DXF editor Mac, native Swift CAD, Metal CAD app, AutoCAD alternative for Mac, scriptable CAD, MCP CAD automation, quantity takeoff / BOQ from DWG.*
