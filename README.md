# MG6250 Scanner

A network scanner driver and Mac app for the Canon PIXMA MG6250 (MG6200 series),
which has no AirScan support and no current Canon driver for macOS.

## Build and run

```bash
./build-app.sh
```

```bash
open "build/MG6250 Scanner.app"
```

Needs Xcode's command-line tools (Swift 5.9+). The first time the app talks to
the printer, macOS asks whether it may find devices on your local network —
choose **Allow** (System Settings › Privacy & Security › Local Network).

## The app

- **Preview** does a quick 75 dpi pass of the whole glass.
- Drag on the preview to choose the area: drag a corner to resize, inside the
  box to move it, anywhere else to draw a new one. Or pick a paper size.
- **Scan** adds a page. Scan several pages, rotate or delete them, then
  **Save…** as one PDF, or as PNG / JPEG / TIFF (one file per page).
- Colour or grey, 75–1200 dpi.

## Command line

```bash
build/mg6250scan --dpi 300 -o scan.png
```

```bash
build/mg6250scan --host 192.168.1.249 --dpi 600 --gray --area 0,0,148,210 -o a5.tiff
```

`--area` is `x,y,width,height` in millimetres. `--discover` lists scanners.

## Layout

| Path | What |
| --- | --- |
| `Sources/PixmaKit/BJNP.swift` | Canon BJNP transport (UDP session setup, TCP data channel, port 8612) |
| `Sources/PixmaKit/PixmaScanner.swift` | PIXMA "generation 5" scan protocol, geometry, line reassembly |
| `Sources/PixmaKit/Discovery.swift` | Finding scanners (Bonjour `_scanner._tcp`, BJNP broadcast) |
| `Sources/mg6250scan` | Command-line tool |
| `Sources/MG6250Scanner` | SwiftUI app |

## Notes

- This is an app-level driver: it does not plug into Image Capture or Preview's
  "Import from Scanner".
- Flatbed only (the MG6250 has no document feeder), 8 bits per channel.
- Tested against one MG6250 over Wi-Fi. Other BJNP PIXMA models of the same era
  may work but are untested; the app flags them.
- The wire protocol is undocumented by Canon. The details here were worked out
  with reference to the SANE project's `pixma` backend; the code is an
  independent Swift implementation.
