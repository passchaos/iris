//! Iris is a small high-throughput rendering toolkit skeleton.
//!
//! The public surface is split around the intended execution model:
//! 2D vector scenes are prepared into sparse strips for CPU rasterization or GPU
//! batches, 3D scenes are encoded into backend-ready triangle batches, and the
//! hybrid scheduler can choose between CPU execution, software backend fallback,
//! and external GPU backend queues.
const std = @import("std");

pub const math = @import("render/math.zig");
pub const color = @import("render/color.zig");
pub const image = @import("render/image.zig");
pub const scene2d = @import("render/scene2d.zig");
pub const scene3d = @import("render/scene3d.zig");
pub const cpu = @import("render/cpu.zig");
pub const gpu = @import("render/gpu.zig");
pub const render_graph = @import("render/render_graph.zig");
pub const resource = @import("render/resource.zig");
pub const profiler = @import("render/profiler.zig");
pub const visualization = @import("render/visualization.zig");
pub const native_window = @import("render/native_window.zig");
pub const window_types = @import("render/window_types.zig");
pub const window_lower = @import("render/window_lower.zig");
pub const window_renderer = @import("render/window_renderer.zig");
pub const window_draw = @import("render/window_draw.zig");
pub const window_gpu = @import("render/window_gpu.zig");
pub const hybrid = @import("render/hybrid.zig");
pub const software_backend = @import("render/software_backend.zig");
pub const webgpu_backend = @import("render/webgpu_backend.zig");

pub const Color = color.Color;
pub const Image = image.Image;
pub const ImageComparison = image.ImageComparison;
pub const Scene2D = scene2d.Scene2D;
pub const TextFont = scene2d.TextFont;
pub const TextMetrics = scene2d.TextMetrics;
pub const Scene3D = scene3d.Scene3D;
pub const PickingBuffer = cpu.PickingBuffer;
pub const Point3D = scene3d.Point3D;
pub const PointCloud = scene3d.PointCloud;
pub const PointHandle = scene3d.PointHandle;
pub const PointCloudHandle = scene3d.PointCloudHandle;
pub const Line3D = scene3d.Line3D;
pub const LineHandle = scene3d.LineHandle;
pub const Axis3D = scene3d.Axis3D;
pub const Grid3D = scene3d.Grid3D;
pub const DebugBox3D = scene3d.DebugBox3D;
pub const VolumePlaceholder3D = scene3d.VolumePlaceholder3D;
pub const Ray3D = scene3d.Ray3D;
pub const TrianglePick = scene3d.TrianglePick;
pub const Viewport3D = scene3d.Viewport3D;
pub const MeshInstances = scene3d.MeshInstances;
pub const MeshLod = scene3d.MeshLod;
pub const MeshLodLevel = scene3d.MeshLodLevel;
pub const CpuRenderer = cpu.CpuRenderer;
pub const HybridRenderer = hybrid.HybridRenderer;
pub const GpuDevice = gpu.GpuDevice;
pub const NativeHandle = native_window.NativeHandle;
pub const NativeWindowProvider = native_window.NativeWindowProvider;
pub const WindowRenderer = window_renderer.Renderer;
pub const WindowRendererProviderCallbacks = window_renderer.ProviderCallbacks;
pub const WindowRendererBackend = webgpu_backend.WebGpuBackend;
pub const WindowRenderBackend = window_types.Backend;
pub const WindowDrawCmd = window_types.DrawCmd;
pub const WindowVertex = window_types.Vertex;
pub const WindowTextVertex = window_types.TextVertex;
pub const WindowLineVertex = window_types.LineVertex;
pub const WindowNodeId = window_types.NodeId;
pub const WindowImageId = window_types.ImageId;
pub const WindowTextFontId = window_types.TextFontId;
pub const WebGpuCompat = webgpu_backend.WebGpuBackend;
pub const Backend = gpu.Backend;
pub const BackendCapabilities = gpu.BackendCapabilities;
pub const RenderGraphOptions = gpu.RenderGraphOptions;
pub const ShaderContract = gpu.ShaderContract;
pub const GpuCommand = gpu.GpuCommand;
pub const GpuBatch = gpu.GpuBatch;
pub const GpuStrip = gpu.GpuStrip;
pub const stripLessThanTileOrder = gpu.stripLessThanTileOrder;
pub const orderStripsByTile = gpu.orderStripsByTile;
pub const GpuVertex3D = gpu.GpuVertex3D;
pub const GpuTriangle = gpu.GpuTriangle;
pub const GpuPoint3D = gpu.GpuPoint3D;
pub const GpuLine3D = gpu.GpuLine3D;
pub const GpuTexture = gpu.GpuTexture;
pub const GpuLight = gpu.GpuLight;
pub const GpuBatchDebugDump = gpu.GpuBatchDebugDump;
pub const GpuDeviceDebugDump = gpu.GpuDeviceDebugDump;
pub const RenderGraph = render_graph.RenderGraph;
pub const RenderGraphDebugDump = render_graph.RenderGraphDebugDump;
pub const RenderGraphResourceHandle = render_graph.ResourceHandle;
pub const RenderGraphPassHandle = render_graph.PassHandle;
pub const RenderGraphResourceKind = render_graph.ResourceKind;
pub const RenderGraphPassKind = render_graph.PassKind;
pub const RenderGraphAccessKind = render_graph.AccessKind;
pub const RenderGraphResourceDebugDump = render_graph.ResourceDebugDump;
pub const RenderGraphPassDebugDump = render_graph.PassDebugDump;
pub const RenderGraphPassAccessDebugDump = render_graph.PassAccessDebugDump;
pub const RenderGraphReusePair = render_graph.ReusePair;
pub const RenderGraphTransientAllocation = render_graph.TransientAllocation;
pub const RenderGraphTransientPoolStats = render_graph.TransientPoolStats;
pub const RenderGraphHazard = render_graph.Hazard;
pub const RenderGraphHazardKind = render_graph.HazardKind;
pub const ResourcePool = resource.ResourcePool;
pub const ResourceHandle = resource.ResourceHandle;
pub const ResourcePoolStats = resource.ResourcePoolStats;
pub const ResourceDebugDump = resource.ResourceDebugDump;
pub const ResourceCache = resource.ResourceCache;
pub const ResourceCacheStats = resource.ResourceCacheStats;
pub const ResourceCacheDebugDump = resource.ResourceCacheDebugDump;
pub const CpuProfiler = profiler.CpuProfiler;
pub const CpuTimingSample = profiler.CpuTimingSample;
pub const CpuTimingDebugDump = profiler.CpuTimingDebugDump;
pub const CpuProfilerOverlayOptions = profiler.CpuProfilerOverlayOptions;
pub const GpuProfiler = profiler.GpuProfiler;
pub const GpuTimingSample = profiler.GpuTimingSample;
pub const GpuTimingDebugDump = profiler.GpuTimingDebugDump;
pub const RenderGraphGpuTiming = profiler.RenderGraphGpuTiming;
pub const recordRenderGraphGpuTimings = profiler.recordRenderGraphGpuTimings;
pub const HeatmapOptions = visualization.HeatmapOptions;
pub const HeatmapPalette = visualization.HeatmapPalette;
pub const heatmapImage = visualization.heatmapImage;
pub const VisualizationBatchDebugDump = visualization.VisualizationBatchDebugDump;
pub const debugScene2DVisualizationBatch = visualization.debugScene2DVisualizationBatch;
pub const debugScene2DGpuBatch = visualization.debugScene2DGpuBatch;
pub const VolumeAxis = visualization.VolumeAxis;
pub const VolumeSliceOptions = visualization.VolumeSliceOptions;
pub const volumeSliceImage = visualization.volumeSliceImage;
pub const VolumeSliceAtlasOptions = visualization.VolumeSliceAtlasOptions;
pub const volumeSliceAtlasImage = visualization.volumeSliceAtlasImage;
pub const PolylinePlotOptions = visualization.PolylinePlotOptions;
pub const appendPolylinePlot = visualization.appendPolylinePlot;
pub const PlotAxesOptions = visualization.PlotAxesOptions;
pub const appendPlotAxes = visualization.appendPlotAxes;
pub const LegendItem = visualization.LegendItem;
pub const LegendOptions = visualization.LegendOptions;
pub const appendLegend = visualization.appendLegend;
pub const TimelineEvent = visualization.TimelineEvent;
pub const TimelineOptions = visualization.TimelineOptions;
pub const appendTimeline = visualization.appendTimeline;
pub const NodeGraphEdge = visualization.NodeGraphEdge;
pub const NodeGraphEdgeOptions = visualization.NodeGraphEdgeOptions;
pub const appendNodeGraphEdges = visualization.appendNodeGraphEdges;
pub const FormulaRule = visualization.FormulaRule;
pub const FormulaGlyph = visualization.FormulaGlyph;
pub const FormulaGlyphAssembly = visualization.FormulaGlyphAssembly;
pub const FormulaPathRequest = visualization.FormulaPathRequest;
pub const FormulaAccent = visualization.FormulaAccent;
pub const FormulaDebugOverlay = visualization.FormulaDebugOverlay;
pub const FormulaDrawList = visualization.FormulaDrawList;
pub const FormulaDebugDump = visualization.FormulaDebugDump;
pub const appendFormulaRules = visualization.appendFormulaRules;
pub const appendFormulaGlyphs = visualization.appendFormulaGlyphs;
pub const appendFormulaGlyphAssembly = visualization.appendFormulaGlyphAssembly;
pub const appendFormulaPathRequests = visualization.appendFormulaPathRequests;
pub const appendFormulaAccents = visualization.appendFormulaAccents;
pub const appendFormulaDebugOverlay = visualization.appendFormulaDebugOverlay;
pub const appendFormulaDrawList = visualization.appendFormulaDrawList;
pub const debugFormulaDrawList = visualization.debugFormulaDrawList;
pub const SoftwareBackend = software_backend.SoftwareBackend;
pub const WebGpuBackend = webgpu_backend.WebGpuBackend;

test "iris renders 2D and 3D scenes through the hybrid path" {
    const allocator = std.testing.allocator;

    var target = try Image.init(allocator, 32, 32, .transparent);
    defer target.deinit();

    var s2 = Scene2D.init(allocator);
    defer s2.deinit();
    try s2.fillRect(.{ .x = 2, .y = 2, .w = 10, .h = 8 }, .red);

    var s3 = Scene3D.init(allocator);
    defer s3.deinit();
    try s3.addTriangle(.{
        .positions = .{
            .{ .x = -0.7, .y = -0.7, .z = 0.2 },
            .{ .x = 0.7, .y = -0.7, .z = 0.2 },
            .{ .x = 0.0, .y = 0.7, .z = 0.2 },
        },
        .color = .green,
    });

    var renderer = HybridRenderer.init(allocator, .{ .prefer_gpu = false });
    defer renderer.deinit();

    try renderer.render2D(&s2, &target);
    try renderer.render3D(&s3, &target);

    try std.testing.expectEqual(@as(usize, 2), renderer.stats.cpu_jobs);
    try std.testing.expect(target.countNonTransparentPixels() > 0);
}

test "iris root exposes backend integration contract" {
    try std.testing.expectEqual(gpu.Backend, Backend);
    try std.testing.expectEqual(gpu.BackendCapabilities, BackendCapabilities);
    try std.testing.expectEqual(gpu.RenderGraphOptions, RenderGraphOptions);
    try std.testing.expectEqual(gpu.ShaderContract, ShaderContract);
    try std.testing.expectEqual(cpu.PickingBuffer, PickingBuffer);
    try std.testing.expectEqual(gpu.GpuCommand, GpuCommand);
    try std.testing.expectEqual(gpu.GpuBatch, GpuBatch);
    try std.testing.expectEqual(gpu.GpuTriangle, GpuTriangle);
    try std.testing.expectEqual(gpu.GpuPoint3D, GpuPoint3D);
    try std.testing.expectEqual(gpu.GpuLine3D, GpuLine3D);
    try std.testing.expectEqual(gpu.GpuTexture, GpuTexture);
    try std.testing.expectEqual(gpu.GpuLight, GpuLight);
    try std.testing.expectEqual(gpu.GpuBatchDebugDump, GpuBatchDebugDump);
    try std.testing.expectEqual(gpu.GpuDeviceDebugDump, GpuDeviceDebugDump);
    try std.testing.expectEqual(render_graph.RenderGraph, RenderGraph);
    try std.testing.expectEqual(render_graph.RenderGraphDebugDump, RenderGraphDebugDump);
    try std.testing.expectEqual(render_graph.PassAccessDebugDump, RenderGraphPassAccessDebugDump);
    try std.testing.expectEqual(render_graph.TransientAllocation, RenderGraphTransientAllocation);
    try std.testing.expectEqual(render_graph.TransientPoolStats, RenderGraphTransientPoolStats);
    try std.testing.expectEqual(render_graph.Hazard, RenderGraphHazard);
    try std.testing.expectEqual(render_graph.HazardKind, RenderGraphHazardKind);
    try std.testing.expectEqual(resource.ResourcePool, ResourcePool);
    try std.testing.expectEqual(resource.ResourceHandle, ResourceHandle);
    try std.testing.expectEqual(resource.ResourcePoolStats, ResourcePoolStats);
    try std.testing.expectEqual(resource.ResourceCache, ResourceCache);
    try std.testing.expectEqual(resource.ResourceCacheStats, ResourceCacheStats);
    try std.testing.expectEqual(profiler.CpuProfiler, CpuProfiler);
    try std.testing.expectEqual(profiler.CpuTimingDebugDump, CpuTimingDebugDump);
    try std.testing.expectEqual(profiler.CpuProfilerOverlayOptions, CpuProfilerOverlayOptions);
    try std.testing.expectEqual(profiler.GpuProfiler, GpuProfiler);
    try std.testing.expectEqual(profiler.GpuTimingDebugDump, GpuTimingDebugDump);
    try std.testing.expectEqual(profiler.RenderGraphGpuTiming, RenderGraphGpuTiming);
    try std.testing.expectEqual(visualization.HeatmapOptions, HeatmapOptions);
    try std.testing.expectEqual(visualization.VisualizationBatchDebugDump, VisualizationBatchDebugDump);
    try std.testing.expectEqual(@TypeOf(visualization.debugScene2DGpuBatch), @TypeOf(debugScene2DGpuBatch));
    try std.testing.expectEqual(visualization.VolumeSliceOptions, VolumeSliceOptions);
    try std.testing.expectEqual(visualization.VolumeSliceAtlasOptions, VolumeSliceAtlasOptions);
    try std.testing.expectEqual(visualization.PolylinePlotOptions, PolylinePlotOptions);
    try std.testing.expectEqual(visualization.PlotAxesOptions, PlotAxesOptions);
    try std.testing.expectEqual(visualization.TimelineOptions, TimelineOptions);
    try std.testing.expectEqual(visualization.NodeGraphEdgeOptions, NodeGraphEdgeOptions);
    try std.testing.expectEqual(visualization.FormulaGlyph, FormulaGlyph);
    try std.testing.expectEqual(visualization.FormulaGlyphAssembly, FormulaGlyphAssembly);
    try std.testing.expectEqual(visualization.FormulaPathRequest, FormulaPathRequest);
    try std.testing.expectEqual(visualization.FormulaDebugOverlay, FormulaDebugOverlay);
    try std.testing.expectEqual(visualization.FormulaDrawList, FormulaDrawList);
    try std.testing.expectEqual(visualization.FormulaDebugDump, FormulaDebugDump);
    try std.testing.expect(ShaderContract.triangle_size > 0);
    try std.testing.expect(ShaderContract.point3d_size > 0);
    try std.testing.expect(ShaderContract.line3d_size > 0);
    try std.testing.expect(ShaderContract.lights_binding > ShaderContract.triangles_binding);
}

test "iris root exposes image comparison stats for backend smoke tests" {
    try std.testing.expectEqual(image.ImageComparison, ImageComparison);
}

test "iris root exposes WebGPU backend integration point" {
    try std.testing.expectEqual(webgpu_backend.WebGpuBackend, WebGpuBackend);
    try std.testing.expect(!WebGpuBackend.available);
    try std.testing.expectEqualStrings("zgpu", WebGpuBackend.implementation);
}
