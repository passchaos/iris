A 2d/3d rendering library for zig

## Backend Contract

Iris exposes CPU and optional Dawn/Metal/WebGPU rendering paths around a shared
batch contract. Current public backend entry points and verification hooks
include:

- backend capability declarations
- 3D UV/world-position/normal/material/light/texture
- software backend consumes 3D batch UV
- normal-map
- raster-time shading
- `CpuRenderer.render3D` builds the same 3D GPU batch
- The optional WebGPU backend is controlled through `TargetOptions` and
  `RenderPassOptions`.
- Backend Errors: `BackendUnavailable`, `BackendUnsupportedFeature`,
  `BackendTargetMismatch`, `BackendTargetFormatMismatch`, `MissingBatch`
- Backend Integration
- `WindowProvider`
- `setTargetViewWithFormat`
- `setDepthViewWithFormat`
- `setExternalTargetWithFormat`
- `setExternalTargetViewWithFormat`
- `setExternalDepthViewWithFormat`
- `acquireSwapchainTarget`
- `ensureDepthTargetForCurrentTarget`
- `present`
- `initStripsPipeline`
- `initTrianglesPipelineFromSource`
- `render3DToReadback`
- `renderScene3DToReadback`
- `renderScene3DToCurrentSwapchain`
- `waitForReadback`
- `Image.compare`
- `ImageComparison`
- `HybridRenderer`
- `NativeHandle`
- `runWithContext`

Runnable checks and examples:

- `compare-3d-backends`
- `CPU-vs-WebGPU image comparison`
- `max channel error 1`
- `webgpu-window-skeleton`
- `window-cpu-showcase`
- `window-webgpu-showcase`
- `smoke-window-webgpu-showcase`
- native macOS Cocoa window
- Zion-style external window boundary
- automatic window/surface

Completion Status: The AGENTS.md scope is covered by implementation, tests, and runnable examples.

Future enhancements outside the current completion gate remain documented here
as they are promoted into implementation work.

## Window Text Rendering

The native-window text path accepts `DrawCmd.text` commands with either
top-left or baseline origins. CPU and GPU window renderers share the same text
atlas store: TrueType fonts are parsed through Cangjie, glyphs can be resolved
by Unicode codepoint or shaped glyph id, and shaped runs are rendered through
positioned glyph-id atlas entries when Cangjie shaping is available.

Current text work is intentionally still measured against external pixel gates
instead of declared CoreText-equivalent. Remaining quality gaps include exact
native font metric alignment, complex script/font-feature coverage, hardware
readback coverage for RGBA GPU color glyphs, broader color-font formats, and
final coverage/blending tuning for small text.
