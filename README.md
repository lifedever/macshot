# macshot

> [!NOTE]
> 这是 [sw33tLie/macshot](https://github.com/sw33tLie/macshot) 的分支版本，改动见 [Releases](https://github.com/lifedever/macshot/releases)。下文的介绍和安装方式说的是上游官方版。
>
> **下载**：Apple 芯片（M1、M2 等）的 Mac 下载 [MacShot-Apple-Silicon.dmg](https://github.com/lifedever/macshot/releases/latest/download/MacShot-Apple-Silicon.dmg)，Intel 芯片的 Mac 下载 [MacShot-Intel.dmg](https://github.com/lifedever/macshot/releases/latest/download/MacShot-Intel.dmg)。需要 macOS 13 或更新。不确定是哪种：点左上角苹果菜单 › 关于本机，「芯片」一行写着 Apple 就是 Apple 芯片，「处理器」一行写着 Intel 就是 Intel。
>
> **第一次打开**：这个版本没有经过 Apple 公证，macOS 会拦下它。关掉弹出的提示，然后打开「系统设置 › 隐私与安全性」，往下翻到「安全性」，点 MacShot 那一行的「仍要打开」。之后有新版本时会收到系统通知，在 MacShot 的设置里更新。
>
> 装过官方版 macshot 的话，拖进「应用程序」会替换掉它；两者的设置和截图历史不共用。

> [!IMPORTANT]
> **Updating to 4.4.0 from 4.3.x or earlier?** macshot's developer signature changed in 4.4.0, so macOS may require you to grant permissions again. If Screen Recording looks enabled but capture fails, remove macshot with the minus button (−) in System Settings, then add it back from Applications with the plus button (+). Re-enable Accessibility or Input Monitoring if prompted. Your settings, history and recordings are preserved. If you already restored permissions on a 4.4.0 beta (beta.3 or later), you don't need to do this again.

<p align="center">
  <img src="assets/logo.svg" alt="macshot logo" width="200"/>
</p>

<p align="center">
  <b>The most feature-rich open-source screenshot tool on macOS.</b><br>
  <br>
  19+ annotation tools, screen recording with a full video editor, OCR + translation,<br>
  auto-redact PII, scroll capture, beautify — all native, all free.
</p>

<p align="center">
  <a href="https://github.com/sw33tLie/macshot/releases/latest">Download</a> · <a href="https://github.com/sw33tLie/macshot/blob/main/CHANGELOG.md">Changelog</a> · <a href="https://github.com/sw33tLie/macshot/blob/main/PRIVACY.md">Privacy</a> · <a href="https://github.com/sw33tLie/macshot/blob/main/SECURITY.md">Security</a>
</p>

<p align="center">
  <img src="assets/preview.png" alt="macshot demo" width="700"/>
</p>

<p align="center">
  <img src="assets/preview-studio.png" alt="macshot Studio video editor — background, pointer, zoom, keystrokes, camera and captions, with a timeline for zooms, cuts and titles" width="700"/>
</p>

---

### Why macshot?

- **Capture & annotate in one flow** — select a region, draw arrows/text/shapes/blur, copy to clipboard. One hotkey, zero friction.
- **Screen recording with built-in editor** — record any area or full screen as MP4/GIF with system audio + microphone. Audio merge dialog with per-track volume control. Trim and export without leaving the app.
- **Scroll capture** — select a region and scroll. macshot stitches it into one seamless tall (or wide) image automatically.
- **Upload anywhere** — one-click upload to Google Drive, imgbb, or any S3-compatible service (Cloudflare R2, AWS S3, MinIO, etc.). Link copied to clipboard instantly.
- **Lightweight & native** — lives in your menu bar. Built with Swift and AppKit, not a web browser in disguise.
- **40 languages** — English, 中文, 日本語, 한국어, Deutsch, Français, Español, Italiano, Português, العربية, हिन्दी, and 29 more. Auto-detects your system language.

---

## Install

**Homebrew:**
```bash
brew install --cask macshot
```

**Manual:** Download the latest `.dmg` from [Releases](https://github.com/sw33tLie/macshot/releases), open it, drag to `/Applications`.

---

## Quick Start

1. Launch macshot — it appears in your menu bar
2. Press `Cmd+Shift+X` to capture
3. Drag to select, annotate with the toolbar, press `Cmd+C` to copy
4. Press `Esc` to cancel

---

<details>
<summary><b>All Features</b></summary>

### Capture
- **Instant capture** — global hotkey freezes your screen, select any region
- **Window snap** — hover over a window and click to capture it exactly; `Tab` toggles snap, `F` for full screen
- **Resolution & aspect presets** — set an exact pixel size or lock an aspect ratio (1:1, 4:3, 16:9, 9:16, …) before or after selecting; editable width/height fields
- **Boundary snap** — selection edges snap to strong color edges (UI lines, window borders) while dragging or resizing; hold `Option` to bypass
- **Scroll capture** — auto-detects vertical or horizontal scrolling, stitches with Apple Vision, live preview panel beside the capture region
- **Capture delay** — 3/5/10/30 second countdown before capture, set via menu bar. Escape to cancel.
- **Multi-monitor** — captures all screens simultaneously; drag a selection across screens for a stitched image
- **Quick save** — `Cmd+Shift+S` to select and save/copy instantly without annotation. Enter key also saves/copies based on preference.
- **Quick OCR** — `Cmd+Shift+T` to select and extract text instantly
- **Move mode (optional)** — turn on **Settings → General → Start captures in move mode** and dragging inside a new selection repositions it until you pick an annotation tool; Space and the Move Selection button move the area at any time

### Annotation Tools
- **Arrow** — 5 styles: single, thick/banner, double, open, tail; flip direction toggle; right-click to add anchor points for complex curves
- **Shapes** — rectangle and ellipse with 3 fill modes (stroke, stroke+fill, fill), corner radius slider
- **Text** — rich formatting (bold/italic/underline/strikethrough), resizable text box, left/center/right alignment, background fill & outline colors, click to re-edit
- **Pencil & Marker** — freeform drawing with optional smoothing; smart marker mode snaps to text lines via OCR
- **Numbered markers** — auto-incrementing (1/I/A/a formats), with optional pointer cone
- **Stamp / Emoji** — 21 quick emojis, 100+ in categorized picker, or load any image
- **Censor (Pixelate / Blur / Solid / Erase)** — unified redaction tool with 4 modes: pixelate, Gaussian blur, solid color fill, or smart erase that samples surrounding colors for invisible content removal. Auto-redact PII (emails, phones, credit cards, SSNs, API keys), auto-detect faces and people, or draw in "Text Only" mode to censor just the text in a region
- **Measure** — pixel ruler with px/pt toggle; hold `1` or `2` for auto-measure
- **Loupe** — 2x magnifier
- **Highlight (spotlight)** — drag a region to keep it bright while dimming the rest; adjustable dim strength and solid/dashed border
- **Color sampler** — eyedropper to pick any color; right-click to copy hex; auto-saves to custom palette slots
- **Space to reposition** — hold Space while drawing to move the shape without changing its size
- **Rotation** — rotate shapes via handle, Shift for 90° snaps
- **Click-to-select** — click any annotation to select it, then edit properties (stroke, style, fill), drag to move, resize via handles, rotate, or delete — all without switching tools

### Screen Recording
- **MP4 (H.264)** up to 120fps or **GIF** (5/10/15fps)
- **System audio capture** — toggle on/off, excludes macshot's own sounds
- **Microphone recording** — record voice narration alongside screen capture (permission requested on first use)
- **Mouse click highlights** — visual ripple on clicks during recording
- **Selection border** — visible capture region outline during recording
- **Menu bar stop button** — stop recording from the menu bar icon (appears even if icon is hidden)
- **Quick settings popover** — change format, FPS, and post-recording action on the fly without opening Preferences
- **Video editor** — trim timeline, mute/strip audio, play/pause, save (with Save As), upload, reveal in Finder

### Output & Upload
- **Formats** — PNG, JPEG, HEIC, WebP, AVIF with quality slider
- **Google Drive** — sign in once, uploads to a private folder (defaults to "macshot", configurable in Settings)
- **imgbb** — anonymous image hosting with shareable links
- **S3-compatible** — upload to Cloudflare R2, AWS S3, MinIO, DigitalOcean Spaces, Backblaze B2, etc.
- **Retina downscale** — optional 1x export for smaller files
- **sRGB color profile** — optional embedding for cross-display consistency

### Editor Window
- Standalone resizable window with full annotation tools, beautify preview
- **Add Capture** — capture additional screen regions and compose them into a single image, drag to reposition
- **Paste image** — `Cmd+V` drops a clipboard image into the canvas as a draggable layer
- Crop (with rule-of-thirds grid), flip H/V, zoom 0.1x–8x
- Top bar with pixel dimensions, zoom dropdown (presets, fit canvas, zoom in/out)

### Beautify
- macOS window frame with traffic lights, shadow, and gradient background
- 30 gradient styles including 7 mesh gradients (macOS 15+), adjustable padding/corner radius/shadow

### Image Effects (Adjust)
- Non-destructive CIFilter adjustments: Brightness, Contrast, Saturation, Sharpness
- 8 presets: Noir, Mono, Sepia, Chrome, Fade, Instant, Vivid
- Works independently or combined with Beautify
- Live preview in the overlay

### Other
- **OCR & QR** — extract text with Apple Vision (auto-detects all languages on macOS 13+), auto-copy to clipboard, translate to 30+ languages, Google AI Search; also reads QR codes with open/copy/scan actions
- **Invert colors** — one-click color inversion, apply twice to revert
- **Background removal** — Apple Vision foreground mask (macOS 14+)
- **Pin to screen** — floating always-on-top window
- **Floating thumbnail** — auto-dismiss preview with Copy/Save/Pin/Edit/Upload
- **Screenshot history with editable annotations** — menu bar submenu + drop-down history panel (`Cmd+Shift+H`). Re-open any capture in the editor with live annotations preserved — edit, then press Done to save back. Drag-and-drop, Quick Look, and right-click actions
- **QR & barcode detection** — inline Open/Copy actions
- **Snap alignment guides** — annotations snap to midlines and edges
- **Liquid Glass theme** (macOS 26 Tahoe) — render toolbars, popovers, and HUDs as Apple's translucent Liquid Glass material
- **Custom menu bar icon** — use the default, a built-in preset, or any SF Symbol
- **Auto-updates** via Sparkle

</details>

<details>
<summary><b>Keyboard Shortcuts</b></summary>

**Global hotkeys** (configurable in Preferences)

| Shortcut | Action |
|---|---|
| `Cmd+Shift+X` | Capture Area |
| `Cmd+Shift+F` | Capture Full Screen |
| `Cmd+Shift+S` | Quick Capture (instant save) |
| `Cmd+Shift+T` | Capture OCR (instant text extraction) |
| `Cmd+Shift+R` | Record Area |
| `Cmd+Shift+H` | Show History Panel |

**General** (during capture)

| Shortcut | Action |
|---|---|
| `Enter` | Confirm (save or copy based on preference) |
| `Cmd+C` | Copy to clipboard |
| `Cmd+S` | Save to file |
| `Cmd+Z` / `Cmd+Shift+Z` | Undo / Redo |
| `Cmd+0` | Reset zoom to 1x |
| `Esc` | Cancel / close popover |
| `Delete` | Remove selected annotation |
| `Tab` | Toggle window snap mode |
| `F` | Capture full screen (snap mode) |
| `Shift` (while drawing) | Constrain to straight lines / perfect shapes |
| `Space` (while drawing) | Reposition shape without changing size |
| `Right-click` on line/arrow | Add anchor point for multi-point curves |

**Tool shortcuts** (active after selecting a region — customizable in Preferences > Shortcuts)

| Key | Tool |
|---|---|
| `A` | Arrow |
| `L` | Line |
| `P` | Pencil |
| `M` | Marker |
| `R` | Rectangle |
| `O` | Ellipse |
| `T` | Text |
| `N` | Number |
| `B` | Censor (Pixelate/Blur) |
| `H` | Highlight (spotlight) |
| `I` | Color Sampler |
| `G` | Stamp / Emoji |
| `S` | Select & Edit |
| `E` | Open in Editor |

</details>

---

## Permissions

macshot requires **Screen Recording** permission. On first launch, click **Open Screen Recording Settings** in macshot and enable it in System Settings. If macOS asks, choose **Quit & Reopen** before trying to capture again.

If captures stop working after an update even though macshot is switched on, macshot shows a **Turn Screen Recording back on** window: remove macshot from the list and add it again. If that doesn't help, run the Terminal command shown in that window, which resets macshot's privacy entries, and restart macshot.

---

## Donations

Thanks for thinking about it, but macshot doesn't take donations. I make this in my free time and I'm happy to keep it that way, so there's no "buy me a coffee" or sponsorship link.

If you'd like to help out, starring the repo, reporting bugs, or contributing is more than enough. Thank you! 🙏

---

## Requirements

macOS 13.0 (Ventura) or later.

## License

[GPLv3](LICENSE)
