//! CPU execution path for Iris scene batches.
//!
//! 2D scenes are lowered through the same sparse-strip batch format used by GPU
//! backends, then rasterized directly into Image spans. 3D scenes are encoded
//! into GpuBatch and submitted to SoftwareBackend so CPU and GPU paths share the
//! same command contract.
const std = @import("std");
const math = @import("math.zig");
const Image = @import("image.zig").Image;
const Scene2D = @import("scene2d.zig").Scene2D;
const scene3d = @import("scene3d.zig");
const Scene3D = scene3d.Scene3D;
const color_mod = @import("color.zig");
const Color = color_mod.Color;
const BlendMode = color_mod.BlendMode;
const gpu = @import("gpu.zig");
const profiler = @import("profiler.zig");
const SoftwareBackend = @import("software_backend.zig").SoftwareBackend;

pub const PickingBuffer = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    triangle_indices: []?usize,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !PickingBuffer {
        const count = try std.math.mul(u32, width, height);
        const indices = try allocator.alloc(?usize, count);
        @memset(indices, null);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .triangle_indices = indices,
        };
    }

    pub fn deinit(self: *PickingBuffer) void {
        self.allocator.free(self.triangle_indices);
        self.* = undefined;
    }

    pub fn clear(self: *PickingBuffer) void {
        @memset(self.triangle_indices, null);
    }

    pub fn triangleAt(self: *const PickingBuffer, x: u32, y: u32) ?usize {
        if (x >= self.width or y >= self.height) return null;
        return self.triangle_indices[y * self.width + x];
    }

    pub fn debugImage(self: *const PickingBuffer, allocator: std.mem.Allocator) !Image {
        var image = try Image.init(allocator, self.width, self.height, .transparent);
        errdefer image.deinit();
        for (self.triangle_indices, 0..) |maybe_index, i| {
            image.pixels[i] = if (maybe_index) |index| pickingDebugColor(index) else .transparent;
        }
        return image;
    }
};

fn pickingDebugColor(index: usize) Color {
    const value: u32 = @truncate(@as(u64, index) *% 0x9E3779B1 +% 0x85EBCA6B);
    const mixed = value ^ (value >> 16);
    return .{
        .r = @intCast(64 + (mixed & 0x7f)),
        .g = @intCast(96 + ((mixed >> 8) & 0x7f)),
        .b = @intCast(128 + ((mixed >> 16) & 0x7f)),
        .a = 255,
    };
}

pub const CpuStats = struct {
    pixels_touched: usize = 0,
    strips_emitted: usize = 0,
    tiles_touched: usize = 0,
    tile_bounds_width: usize = 0,
    tile_bounds_height: usize = 0,
    triangles_rasterized: usize = 0,
    points_rasterized: usize = 0,
    lines_rasterized: usize = 0,
};

pub const CpuRenderer = struct {
    allocator: std.mem.Allocator,
    stats: CpuStats = .{},

    pub fn init(allocator: std.mem.Allocator) CpuRenderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CpuRenderer) void {
        self.* = undefined;
    }

    pub fn render2D(self: *CpuRenderer, scene: *const Scene2D, target: *Image) !void {
        self.stats = .{};

        // Build the backend-neutral strip batch first. Keeping CPU rasterization
        // on the GPU batch format makes statistics and correctness comparisons
        // line up with external backends.
        var batch: gpu.GpuBatch = .{};
        defer batch.deinit(self.allocator);
        try batch.build2DFromScene(self.allocator, scene, target.width, target.height);
        self.stats.strips_emitted = batch.strips.items.len;
        self.stats.tiles_touched = batch.tile_ranges.items.len;
        self.stats.tile_bounds_width = batch.tile_bounds.width();
        self.stats.tile_bounds_height = batch.tile_bounds.height();
        self.render2DBatch(&batch, target);
    }

    pub fn render2DProfiled(self: *CpuRenderer, io: std.Io, profiler_: *profiler.CpuProfiler, scene: *const Scene2D, target: *Image) !void {
        self.stats = .{};

        const build_handle = try profiler_.begin(io, "cpu.render2d.build_batch");
        var batch: gpu.GpuBatch = .{};
        defer batch.deinit(self.allocator);
        try batch.build2DFromScene(self.allocator, scene, target.width, target.height);
        try profiler_.end(io, build_handle);

        self.stats.strips_emitted = batch.strips.items.len;
        self.stats.tiles_touched = batch.tile_ranges.items.len;
        self.stats.tile_bounds_width = batch.tile_bounds.width();
        self.stats.tile_bounds_height = batch.tile_bounds.height();

        const raster_handle = try profiler_.begin(io, "cpu.render2d.raster");
        self.render2DBatch(&batch, target);
        try profiler_.end(io, raster_handle);
    }

    pub fn render3D(self: *CpuRenderer, scene: *const Scene3D, target: *Image) !void {
        self.stats = .{};
        // The software backend implements the same submit interface as a real
        // GPU backend. CpuRenderer uses it here to keep 3D shading, texture, and
        // depth behavior consistent with queued GPU commands.
        var backend = SoftwareBackend.initWithAllocator(self.allocator, target);
        defer backend.deinit();
        var device = gpu.GpuDevice.init(self.allocator, .none);
        defer device.deinit();
        device.setBackend(backend.backend());

        try device.enqueue3D(scene, target);
        if (device.batches.items.len > 0) {
            self.stats.triangles_rasterized = device.batches.items[0].triangles.items.len;
            self.stats.points_rasterized = device.batches.items[0].points.items.len;
            self.stats.lines_rasterized = device.batches.items[0].lines.items.len;
        }
        try device.submitQueued();
        self.stats.pixels_touched = backend.pixels_touched;
    }

    pub fn render3DProfiled(self: *CpuRenderer, io: std.Io, profiler_: *profiler.CpuProfiler, scene: *const Scene3D, target: *Image) !void {
        self.stats = .{};
        var backend = SoftwareBackend.initWithAllocator(self.allocator, target);
        defer backend.deinit();
        var device = gpu.GpuDevice.init(self.allocator, .none);
        defer device.deinit();
        device.setBackend(backend.backend());

        const build_handle = try profiler_.begin(io, "cpu.render3d.build_batch");
        try device.enqueue3D(scene, target);
        try profiler_.end(io, build_handle);

        if (device.batches.items.len > 0) {
            self.stats.triangles_rasterized = device.batches.items[0].triangles.items.len;
            self.stats.points_rasterized = device.batches.items[0].points.items.len;
            self.stats.lines_rasterized = device.batches.items[0].lines.items.len;
        }

        const raster_handle = try profiler_.begin(io, "cpu.render3d.raster");
        try device.submitQueued();
        try profiler_.end(io, raster_handle);
        self.stats.pixels_touched = backend.pixels_touched;
    }

    pub fn buildPickingBuffer3D(self: *CpuRenderer, scene: *const Scene3D, target_width: u32, target_height: u32) !PickingBuffer {
        self.stats = .{};
        var buffer = try PickingBuffer.init(self.allocator, target_width, target_height);
        errdefer buffer.deinit();

        var batch: gpu.GpuBatch = .{};
        defer batch.deinit(self.allocator);
        try batch.build3DFromScene(self.allocator, scene);
        self.stats.triangles_rasterized = batch.triangles.items.len;
        self.stats.points_rasterized = batch.points.items.len;
        self.stats.lines_rasterized = batch.lines.items.len;
        try rasterPickingTriangles(self.allocator, &batch, &buffer);
        return buffer;
    }

    fn render2DBatch(self: *CpuRenderer, batch: *const gpu.GpuBatch, target: *Image) void {
        for (batch.tile_ranges.items) |range| {
            const start: usize = range.strip_start;
            const end = start + range.strip_count;
            for (batch.strips.items[start..end]) |strip| {
                const color = Color.fromRgba32(strip.rgba);
                const blend_mode: BlendMode = @enumFromInt(@as(u8, @intCast(strip.blend_mode)));
                if (color.a == 0 and blend_mode == .source_over) continue;
                if (blend_mode == .destination) continue;
                // Opaque source-like strips can overwrite whole spans. Blended
                // strips still visit pixels individually so Image owns the blend
                // equation for every supported BlendMode.
                if ((blend_mode == .source_over and color.a == 255) or blend_mode == .copy or blend_mode == .source) {
                    const span = target.span(@intCast(strip.x), @intCast(strip.y), strip.width);
                    @memset(span, color);
                    self.stats.pixels_touched += span.len;
                    continue;
                }
                var x: u32 = strip.x;
                const x_end = x + strip.width;
                while (x < x_end) : (x += 1) {
                    target.blendPixelMode(x, strip.y, color, blend_mode);
                    self.stats.pixels_touched += 1;
                }
            }
        }
    }
};

fn rasterPickingTriangles(allocator: std.mem.Allocator, batch: *const gpu.GpuBatch, buffer: *PickingBuffer) !void {
    const count = try std.math.mul(u32, buffer.width, buffer.height);
    var depth = try std.ArrayList(f32).initCapacity(allocator, count);
    defer depth.deinit(allocator);
    try depth.resize(allocator, count);
    @memset(depth.items, std.math.inf(f32));
    buffer.clear();

    // Picking mirrors the color rasterizer's depth test but stores triangle
    // indices instead of shaded pixels. This keeps hit-testing stable when
    // triangles overlap in screen space.
    for (batch.triangles.items, 0..) |triangle, index| {
        rasterPickingTriangle(triangle, index, buffer, depth.items);
    }
}

fn rasterPickingTriangle(triangle: gpu.GpuTriangle, triangle_index: usize, buffer: *PickingBuffer, depth: []f32) void {
    const p = [3]ScreenVertex{
        ndcVertexToScreen(triangle.a, buffer.width, buffer.height),
        ndcVertexToScreen(triangle.b, buffer.width, buffer.height),
        ndcVertexToScreen(triangle.c, buffer.width, buffer.height),
    };
    const xy = [3]math.Vec2{ p[0].xy, p[1].xy, p[2].xy };
    const min_x: i32 = @intFromFloat(@floor(@min(@min(xy[0].x, xy[1].x), xy[2].x)));
    const min_y: i32 = @intFromFloat(@floor(@min(@min(xy[0].y, xy[1].y), xy[2].y)));
    const max_x: i32 = @intFromFloat(@ceil(@max(@max(xy[0].x, xy[1].x), xy[2].x)));
    const max_y: i32 = @intFromFloat(@ceil(@max(@max(xy[0].y, xy[1].y), xy[2].y)));

    var y = math.clampInt(min_y, 0, @intCast(buffer.height));
    const end_y = math.clampInt(max_y, 0, @intCast(buffer.height));
    while (y < end_y) : (y += 1) {
        var x = math.clampInt(min_x, 0, @intCast(buffer.width));
        const end_x = math.clampInt(max_x, 0, @intCast(buffer.width));
        while (x < end_x) : (x += 1) {
            const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
            const bary = barycentric(sample, xy) orelse continue;
            const z = bary[0] * p[0].z + bary[1] * p[1].z + bary[2] * p[2].z;
            const idx: usize = @intCast(@as(u32, @intCast(y)) * buffer.width + @as(u32, @intCast(x)));
            if (z < depth[idx]) {
                depth[idx] = z;
                buffer.triangle_indices[idx] = triangle_index;
            }
        }
    }
}

const ScreenVertex = struct {
    xy: math.Vec2,
    z: f32,
};

fn ndcVertexToScreen(vertex: gpu.GpuVertex3D, width: u32, height: u32) ScreenVertex {
    return .{
        .xy = .{
            .x = (vertex.x * 0.5 + 0.5) * @as(f32, @floatFromInt(width)),
            .y = (1.0 - (vertex.y * 0.5 + 0.5)) * @as(f32, @floatFromInt(height)),
        },
        .z = vertex.z,
    };
}

fn edge(a: math.Vec2, b: math.Vec2, p: math.Vec2) f32 {
    return (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x);
}

fn barycentric(p: math.Vec2, tri: [3]math.Vec2) ?[3]f32 {
    const area = edge(tri[0], tri[1], tri[2]);
    if (@abs(area) < 0.000001) return null;
    const w0 = edge(tri[1], tri[2], p) / area;
    const w1 = edge(tri[2], tri[0], p) / area;
    const w2 = edge(tri[0], tri[1], p) / area;
    if (w0 < 0 or w1 < 0 or w2 < 0) return null;
    return .{ w0, w1, w2 };
}

test "CPU renderer fills 2D rectangles through sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 1, .y = 1, .w = 3, .h = 2 }, .white);

    var img = try Image.init(allocator, 8, 8, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 6), img.countNonTransparentPixels());
    try std.testing.expectEqual(@as(usize, 6), renderer.stats.pixels_touched);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.tiles_touched);
}

test "CPU renderer records tile-local 2D work" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 14, .y = 0, .w = 6, .h = 1 }, .white);

    var img = try Image.init(allocator, 32, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 2), renderer.stats.tiles_touched);
    try std.testing.expectEqual(@as(usize, 2), renderer.stats.tile_bounds_width);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.tile_bounds_height);
    try std.testing.expectEqual(@as(usize, 6), renderer.stats.pixels_touched);
}

test "CPU renderer records profiled 2D render phases" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 1, .y = 1, .w = 2, .h = 2 }, .white);

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    var prof = profiler.CpuProfiler.init(allocator);
    defer prof.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();

    try renderer.render2DProfiled(io, &prof, &scene, &img);

    try std.testing.expectEqual(@as(usize, 2), prof.samples.items.len);
    try std.testing.expectEqualStrings("cpu.render2d.build_batch", prof.samples.items[0].label);
    try std.testing.expectEqualStrings("cpu.render2d.raster", prof.samples.items[1].label);
    try std.testing.expect(img.countNonTransparentPixels() > 0);
}

test "CPU 3D renderer depth tests overlapping triangles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [3]math.Vec3{
        .{ .x = -0.8, .y = -0.8, .z = 0.8 },
        .{ .x = 0.8, .y = -0.8, .z = 0.8 },
        .{ .x = 0.0, .y = 0.8, .z = 0.8 },
    };
    try scene.addTriangle(.{ .positions = positions, .color = .red });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.0, .y = 0.8, .z = 0.1 },
        },
        .color = .blue,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    const center = img.pixel(8, 8).?;
    try std.testing.expectEqual(Color.blue, center);
}

test "CPU renderer records profiled 3D render phases" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .green,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    var prof = profiler.CpuProfiler.init(allocator);
    defer prof.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();

    try renderer.render3DProfiled(io, &prof, &scene, &img);

    try std.testing.expectEqual(@as(usize, 2), prof.samples.items.len);
    try std.testing.expectEqualStrings("cpu.render3d.build_batch", prof.samples.items[0].label);
    try std.testing.expectEqualStrings("cpu.render3d.raster", prof.samples.items[1].label);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.triangles_rasterized);
    try std.testing.expect(img.countNonTransparentPixels() > 0);
}

test "CPU 3D picking buffer stores nearest triangle indices" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.8, .y = -0.8, .z = 0.8 },
            .{ .x = 0.8, .y = -0.8, .z = 0.8 },
            .{ .x = 0.0, .y = 0.8, .z = 0.8 },
        },
        .color = .red,
    });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.0, .y = 0.8, .z = 0.1 },
        },
        .color = .blue,
    });

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    var picks = try renderer.buildPickingBuffer3D(&scene, 16, 16);
    defer picks.deinit();

    try std.testing.expectEqual(@as(usize, 1), picks.triangleAt(8, 8).?);
    try std.testing.expect(picks.triangleAt(0, 0) == null);
    try std.testing.expect(picks.triangleAt(99, 99) == null);
    try std.testing.expectEqual(@as(usize, 2), renderer.stats.triangles_rasterized);

    var debug = try picks.debugImage(allocator);
    defer debug.deinit();
    try std.testing.expectEqual(Color.transparent, debug.pixel(0, 0).?);
    const center = debug.pixel(8, 8).?;
    try std.testing.expect(center.a == 255);
    try std.testing.expect(center != Color.transparent);
    try std.testing.expectEqual(center, debug.pixel(8, 9).?);
}

test "CPU 3D renderer applies Lambert face lighting" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.25, .diffuse = 0.75 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.0, .y = 0.8, .z = 0.1 },
        },
        .color = .white,
    });

    var lit = try Image.init(allocator, 16, 16, .transparent);
    defer lit.deinit();
    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &lit);

    scene.light.direction = .{ .z = -1 };
    var dark = try Image.init(allocator, 16, 16, .transparent);
    defer dark.deinit();
    try renderer.render3D(&scene, &dark);

    try std.testing.expect((lit.pixel(8, 8) orelse Color.transparent).r > (dark.pixel(8, 8) orelse Color.transparent).r);
    try std.testing.expectEqual(@as(u8, 64), (dark.pixel(8, 8) orelse Color.transparent).r);
}

test "CPU 3D renderer accepts perspective camera world coordinates" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCamera(@import("scene3d.zig").Camera.perspectiveLookAt(
        .{ .z = 3 },
        .{},
        .{ .y = 1 },
        std.math.pi / 2.0,
        1.0,
        0.1,
        100.0,
    ));
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.0 },
            .{ .x = 0.5, .y = -0.5, .z = 0.0 },
            .{ .x = 0.0, .y = 0.5, .z = 0.0 },
        },
        .color = .green,
    });

    var img = try Image.init(allocator, 32, 32, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expect(img.countNonTransparentPixels() > 0);
}

test "CPU 3D renderer accepts orthographic camera world coordinates" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCamera(@import("scene3d.zig").Camera.orthographicLookAt(
        .{ .z = 3 },
        .{},
        .{ .y = 1 },
        4.0,
        4.0,
        0.1,
        100.0,
    ));
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.0 },
            .{ .x = 0.5, .y = -0.5, .z = 0.0 },
            .{ .x = 0.0, .y = 0.5, .z = 0.0 },
        },
        .color = .green,
    });

    var img = try Image.init(allocator, 32, 32, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.triangles_rasterized);
    try std.testing.expect(img.countNonTransparentPixels() > 0);
}

test "CPU 3D renderer renders indexed meshes" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{
        .{ .x = -0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.0, .y = 0.5, .z = 0.1 },
    };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMesh(.{ .positions = &positions, .indices = &indices, .color = .green });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.triangles_rasterized);
    try std.testing.expect(img.countNonTransparentPixels() > 0);
}

test "CPU 3D renderer interpolates per-vertex colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.0, .y = 0.9, .z = 0.1 },
        },
        .color = .white,
        .colors = .{ .red, .green, .blue },
    });

    var img = try Image.init(allocator, 24, 24, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    const center = img.pixel(12, 12).?;
    try std.testing.expect(center.r > 0 and center.g > 0 and center.b > 0);
    try std.testing.expect(center.r < 255 and center.g < 255 and center.b < 255);
}

test "CPU 3D renderer interpolates indexed mesh vertex colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{
        .{ .x = -0.9, .y = -0.9, .z = 0.1 },
        .{ .x = 0.9, .y = -0.9, .z = 0.1 },
        .{ .x = 0.0, .y = 0.9, .z = 0.1 },
    };
    const colors = [_]Color{ .red, .green, .blue };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMesh(.{ .positions = &positions, .indices = &indices, .color = .white, .colors = &colors });

    var img = try Image.init(allocator, 24, 24, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    const center = img.pixel(12, 12).?;
    try std.testing.expect(center.r > 0 and center.g > 0 and center.b > 0);
}

test "CPU 3D renderer applies per-vertex normals" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 1.0 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.0, .y = 0.9, .z = 0.1 },
        },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = -1 }, .{ .z = 1 } },
    });

    var img = try Image.init(allocator, 24, 24, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    const lit = img.pixel(4, 20).?;
    const dark = img.pixel(20, 20).?;
    try std.testing.expect(lit.r > dark.r);
}

test "CPU 3D renderer uses batch-updated texture handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const red = [_]Color{.red};
    const blue = [_]Color{.blue};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &red });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.0, .y = 0.8, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = handle,
    });
    try scene.replaceTextures(&.{
        .{ .handle = handle, .texture = .{ .width = 1, .height = 1, .pixels = &blue } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(Color.blue, img.pixel(8, 8).?);
}

test "CPU 3D renderer uses batch-updated material handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addMaterialHandle(.{ .emissive = .red, .emissive_strength = 1.0 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.8, .y = -0.8, .z = 0.1 },
            .{ .x = 0.0, .y = 0.8, .z = 0.1 },
        },
        .color = .black,
        .material_handle = handle,
    });
    try scene.replaceMaterials(&.{
        .{ .handle = handle, .material = .{ .emissive = .green, .emissive_strength = 1.0 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(Color.green, img.pixel(8, 8).?);
}

test "CPU 3D renderer applies cull mode" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCullMode(.back);
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .green,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 0), renderer.stats.triangles_rasterized);
    try std.testing.expectEqual(@as(usize, 0), img.countNonTransparentPixels());
}

test "CPU 3D renderer rejects triangles outside clip volume" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = 2.0, .y = 0.0, .z = 0.5 },
            .{ .x = 3.0, .y = 0.0, .z = 0.5 },
            .{ .x = 2.5, .y = 1.0, .z = 0.5 },
        },
        .color = .green,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 0), renderer.stats.triangles_rasterized);
}

test "CPU 3D renderer draws point cloud splats with depth" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.4, .y = -0.4, .z = 0.5 },
            .{ .x = 0.4, .y = -0.4, .z = 0.5 },
            .{ .x = 0.0, .y = 0.4, .z = 0.5 },
        },
        .color = .blue,
    });
    try scene.addPoint(.{ .position = .{ .z = 0.1 }, .color = .red, .size = 3.0 });
    try scene.addPoint(.{ .position = .{ .x = 2.0, .z = 0.1 }, .color = .green, .size = 3.0 });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.triangles_rasterized);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.points_rasterized);
    try std.testing.expectEqual(Color.red, img.pixel(8, 8).?);
    try std.testing.expect(img.countNonTransparentPixels() > 1);
}

test "CPU 3D renderer draws line splats with depth" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.6, .y = -0.6, .z = 0.6 },
            .{ .x = 0.6, .y = -0.6, .z = 0.6 },
            .{ .x = 0.0, .y = 0.6, .z = 0.6 },
        },
        .color = .blue,
    });
    try scene.addLine(.{
        .start = .{ .x = -0.45, .y = -0.45, .z = 0.2 },
        .end = .{ .x = 0.45, .y = 0.45, .z = 0.2 },
        .color = .red,
        .width = 2.0,
    });
    try scene.addLine(.{
        .start = .{ .x = -2.0, .z = 0.2 },
        .end = .{ .x = -1.5, .z = 0.2 },
        .color = .green,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.triangles_rasterized);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.lines_rasterized);
    try std.testing.expectEqual(Color.red, img.pixel(8, 8).?);
    try std.testing.expect(img.countNonTransparentPixels() > 4);
}

test "CPU renderer fills quadratic paths" {
    const allocator = std.testing.allocator;

    var path = @import("scene2d.zig").Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 14 });
    try path.quadTo(.{ .x = 8, .y = 0 }, .{ .x = 14, .y = 14 });
    try path.lineTo(.{ .x = 2, .y = 14 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .green, .non_zero);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expect(img.countNonTransparentPixels() > 20);
}

test "CPU renderer strokes quadratic paths" {
    const allocator = std.testing.allocator;

    var path = @import("scene2d.zig").Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 10 });
    try path.quadTo(.{ .x = 8, .y = 2 }, .{ .x = 14, .y = 10 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePath(&path, 2, .white);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    var has_partial = false;
    var has_full = false;
    for (img.pixels) |pixel| {
        if (pixel.a > 0 and pixel.a < 255) has_partial = true;
        if (pixel.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "CPU renderer draws dashed stroked paths with gaps" {
    const allocator = std.testing.allocator;

    var path = @import("scene2d.zig").Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 13, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedPath(&path, 2, 3, 3, .white);

    var img = try Image.init(allocator, 16, 8, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expect((img.pixel(2, 4) orelse Color.transparent).a > 0);
    try std.testing.expectEqual(Color.transparent, img.pixel(5, 4).?);
    try std.testing.expect((img.pixel(8, 4) orelse Color.transparent).a > 0);
}

test "CPU renderer applies dashed stroked path cap modes" {
    const allocator = std.testing.allocator;

    var path = @import("scene2d.zig").Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 13, .y = 4 });

    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeDashedPathCap(&path, 2, 3, 3, .butt, .white);

    var butt = try Image.init(allocator, 16, 8, .transparent);
    defer butt.deinit();
    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&butt_scene, &butt);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeDashedPathCap(&path, 2, 3, 3, .square, .white);

    var square = try Image.init(allocator, 16, 8, .transparent);
    defer square.deinit();
    try renderer.render2D(&square_scene, &square);

    try std.testing.expectEqual(Color.transparent, butt.pixel(4, 4).?);
    try std.testing.expect((square.pixel(4, 4) orelse Color.transparent).a > 0);
}

test "CPU renderer applies stroked path cap modes" {
    const allocator = std.testing.allocator;

    var path = @import("scene2d.zig").Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 4 });
    try path.lineTo(.{ .x = 12, .y = 4 });

    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokePathCap(&path, 2, .butt, .white);

    var butt = try Image.init(allocator, 16, 8, .transparent);
    defer butt.deinit();
    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&butt_scene, &butt);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokePathCap(&path, 2, .square, .white);

    var square = try Image.init(allocator, 16, 8, .transparent);
    defer square.deinit();
    try renderer.render2D(&square_scene, &square);

    try std.testing.expectEqual(Color.transparent, butt.pixel(3, 4).?);
    try std.testing.expect((square.pixel(3, 4) orelse Color.transparent).a > 0);
}

test "CPU renderer applies 2D blend modes from sparse strips" {
    const allocator = std.testing.allocator;
    var add_scene = Scene2D.init(allocator);
    defer add_scene.deinit();

    try add_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .red);
    try add_scene.pushBlendMode(.add);
    try add_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .blue);
    add_scene.popBlendMode();

    var add_img = try Image.init(allocator, 1, 1, .transparent);
    defer add_img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&add_scene, &add_img);

    try std.testing.expectEqual(Color.rgba(255, 0, 255, 255), add_img.pixel(0, 0).?);

    var screen_scene = Scene2D.init(allocator);
    defer screen_scene.deinit();
    try screen_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.rgba(20, 80, 220, 255));
    try screen_scene.pushBlendMode(.screen);
    try screen_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.rgba(200, 40, 20, 255));
    screen_scene.popBlendMode();

    var screen_img = try Image.init(allocator, 1, 1, .transparent);
    defer screen_img.deinit();
    try renderer.render2D(&screen_scene, &screen_img);

    try std.testing.expectEqual(Color.rgba(204, 107, 223, 255), screen_img.pixel(0, 0).?);

    var dodge_scene = Scene2D.init(allocator);
    defer dodge_scene.deinit();
    try dodge_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.rgba(20, 80, 220, 255));
    try dodge_scene.pushBlendMode(.color_dodge);
    try dodge_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.rgba(200, 40, 20, 255));
    dodge_scene.popBlendMode();

    var dodge_img = try Image.init(allocator, 1, 1, .transparent);
    defer dodge_img.deinit();
    try renderer.render2D(&dodge_scene, &dodge_img);

    try std.testing.expectEqual(Color.rgba(93, 95, 239, 255), dodge_img.pixel(0, 0).?);

    var hue_scene = Scene2D.init(allocator);
    defer hue_scene.deinit();
    try hue_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.rgba(176, 59, 54, 255));
    try hue_scene.pushBlendMode(.hue);
    try hue_scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.rgba(143, 128, 227, 255));
    hue_scene.popBlendMode();

    var hue_img = try Image.init(allocator, 1, 1, .transparent);
    defer hue_img.deinit();
    try renderer.render2D(&hue_scene, &hue_img);

    try std.testing.expectEqual(Color.rgba(93, 75, 197, 255), hue_img.pixel(0, 0).?);
}

test "CPU renderer draws linear gradient rectangles" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 4, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    });

    var img = try Image.init(allocator, 4, 1, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expect(img.pixel(0, 0).?.r > img.pixel(3, 0).?.r);
    try std.testing.expect(img.pixel(0, 0).?.b < img.pixel(3, 0).?.b);
}

test "CPU renderer draws radial gradient rectangles" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRadialGradientRect(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{
        .center = .{ .x = 0.5, .y = 0.5 },
        .radius = 4,
        .inner_color = .red,
        .outer_color = .blue,
    });

    var img = try Image.init(allocator, 4, 1, .transparent);
    defer img.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expect(img.pixel(0, 0).?.r > img.pixel(3, 0).?.r);
    try std.testing.expect(img.pixel(0, 0).?.b < img.pixel(3, 0).?.b);
}

test "CPU renderer draws image rectangles" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 2, 1, .transparent);
    defer src.deinit();
    src.writePixel(0, 0, .red);
    src.writePixel(1, 0, .blue);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillImageRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &src);

    var dst = try Image.init(allocator, 2, 1, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    try std.testing.expectEqual(Color.red, dst.pixel(0, 0).?);
    try std.testing.expectEqual(Color.blue, dst.pixel(1, 0).?);
}

test "CPU renderer draws image atlas sub-rectangles" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 4, 1, .transparent);
    defer src.deinit();
    src.writePixel(0, 0, .red);
    src.writePixel(1, 0, .green);
    src.writePixel(2, 0, .blue);
    src.writePixel(3, 0, .white);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillImageSubRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &src, .{ .x = 1, .y = 0, .w = 2, .h = 1 });

    var dst = try Image.init(allocator, 2, 1, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    try std.testing.expectEqual(Color.green, dst.pixel(0, 0).?);
    try std.testing.expectEqual(Color.blue, dst.pixel(1, 0).?);
}

test "CPU renderer draws masked rectangles" {
    const allocator = std.testing.allocator;
    var mask = try Image.init(allocator, 2, 1, .transparent);
    defer mask.deinit();
    mask.writePixel(0, 0, Color.rgba(0, 0, 0, 128));
    mask.writePixel(1, 0, .transparent);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillMaskedRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .white, &mask);

    var dst = try Image.init(allocator, 2, 1, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    try std.testing.expectEqual(@as(u8, 128), dst.pixel(0, 0).?.a);
    try std.testing.expectEqual(Color.transparent, dst.pixel(1, 0).?);
}

test "CPU renderer applies 2D opacity state" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushOpacity(0.5);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);

    var dst = try Image.init(allocator, 1, 1, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    try std.testing.expectEqual(@as(u8, 128), dst.pixel(0, 0).?.a);
}

test "CPU renderer draws soft drop shadow rectangles" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.dropShadowRect(.{ .x = 4, .y = 4, .w = 4, .h = 4 }, .{ .x = 2, .y = 1 }, 2, .black);

    var dst = try Image.init(allocator, 16, 16, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    var has_partial = false;
    var has_full = false;
    for (dst.pixels) |pixel| {
        if (pixel.a > 0 and pixel.a < 255) has_partial = true;
        if (pixel.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "CPU renderer draws anti-aliased ellipses" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, .blue);

    var dst = try Image.init(allocator, 16, 16, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    var has_partial = false;
    var has_full = false;
    for (dst.pixels) |pixel| {
        if (pixel.a > 0 and pixel.a < 255) has_partial = true;
        if (pixel.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "CPU renderer draws stroked ellipses" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, 2, .blue);

    var dst = try Image.init(allocator, 16, 16, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    var has_partial = false;
    var has_full = false;
    for (dst.pixels) |pixel| {
        if (pixel.a > 0 and pixel.a < 255) has_partial = true;
        if (pixel.a == 255) has_full = true;
    }
    try std.testing.expectEqual(Color.transparent, dst.pixel(8, 8).?);
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "CPU renderer draws arc sectors" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillArcSector(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, -std.math.pi / 2.0, std.math.pi / 2.0, .green);

    var dst = try Image.init(allocator, 16, 16, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    try std.testing.expect((dst.pixel(11, 8) orelse Color.transparent).a > 0);
    try std.testing.expectEqual(Color.transparent, dst.pixel(4, 8).?);
}

test "CPU renderer draws stroked arcs" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeArc(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, 2, -std.math.pi / 2.0, std.math.pi / 2.0, .green);

    var dst = try Image.init(allocator, 16, 16, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    try std.testing.expect((dst.pixel(12, 8) orelse Color.transparent).a > 0);
    try std.testing.expectEqual(Color.transparent, dst.pixel(8, 8).?);
    try std.testing.expectEqual(Color.transparent, dst.pixel(4, 8).?);
}

test "CPU renderer draws dashed lines with gaps" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedLine(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .white);

    var dst = try Image.init(allocator, 16, 8, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    try std.testing.expect((dst.pixel(2, 4) orelse Color.transparent).a > 0);
    try std.testing.expectEqual(Color.transparent, dst.pixel(5, 4).?);
    try std.testing.expect((dst.pixel(8, 4) orelse Color.transparent).a > 0);
}

test "CPU renderer applies dashed line cap modes" {
    const allocator = std.testing.allocator;
    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeDashedLineCap(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .butt, .white);

    var butt = try Image.init(allocator, 16, 8, .transparent);
    defer butt.deinit();
    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&butt_scene, &butt);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeDashedLineCap(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .square, .white);

    var square = try Image.init(allocator, 16, 8, .transparent);
    defer square.deinit();
    try renderer.render2D(&square_scene, &square);

    try std.testing.expectEqual(Color.transparent, butt.pixel(4, 4).?);
    try std.testing.expect((square.pixel(4, 4) orelse Color.transparent).a > 0);
}

test "CPU renderer applies line cap modes" {
    const allocator = std.testing.allocator;
    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 12, .y = 4 }, 2, .butt, .white);

    var butt = try Image.init(allocator, 16, 8, .transparent);
    defer butt.deinit();
    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&butt_scene, &butt);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 12, .y = 4 }, 2, .square, .white);

    var square = try Image.init(allocator, 16, 8, .transparent);
    defer square.deinit();
    try renderer.render2D(&square_scene, &square);

    try std.testing.expectEqual(Color.transparent, butt.pixel(3, 4).?);
    try std.testing.expect((square.pixel(3, 4) orelse Color.transparent).a > 0);
}

test "CPU renderer preserves anti-aliased line edge alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeLine(.{ .x = 1, .y = 2 }, .{ .x = 7, .y = 2 }, 2, .white);

    var dst = try Image.init(allocator, 10, 6, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    var has_partial = false;
    var has_full = false;
    for (dst.pixels) |pixel| {
        if (pixel.a > 0 and pixel.a < 255) has_partial = true;
        if (pixel.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "CPU renderer preserves anti-aliased path edge alpha" {
    const allocator = std.testing.allocator;
    var path = @import("scene2d.zig").Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2.25, .y = 2.25 });
    try path.lineTo(.{ .x = 8.25, .y = 2.25 });
    try path.lineTo(.{ .x = 2.25, .y = 8.25 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .green, .non_zero);

    var dst = try Image.init(allocator, 12, 12, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    var has_partial = false;
    var has_full = false;
    for (dst.pixels) |pixel| {
        if (pixel.a > 0 and pixel.a < 255) has_partial = true;
        if (pixel.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "CPU renderer preserves anti-aliased triangle edge alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillTriangle(.{
        .{ .x = 2.25, .y = 2.25 },
        .{ .x = 8.25, .y = 2.25 },
        .{ .x = 2.25, .y = 8.25 },
    }, .blue);

    var dst = try Image.init(allocator, 12, 12, .transparent);
    defer dst.deinit();

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &dst);

    var has_partial = false;
    var has_full = false;
    for (dst.pixels) |pixel| {
        if (pixel.a > 0 and pixel.a < 255) has_partial = true;
        if (pixel.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}
