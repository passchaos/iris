//! CPU/GPU scheduler for Iris render jobs.
//!
//! HybridRenderer is intentionally policy-only: it decides where a scene should
//! run, then delegates actual encoding/rasterization to GpuDevice or CpuRenderer.
//! This keeps caller-facing backend selection independent from platform-specific
//! GPU setup.
const std = @import("std");
const CpuRenderer = @import("cpu.zig").CpuRenderer;
const Color = @import("color.zig").Color;
const GpuDevice = @import("gpu.zig").GpuDevice;
const Image = @import("image.zig").Image;
const Scene2D = @import("scene2d.zig").Scene2D;
const Scene3D = @import("scene3d.zig").Scene3D;

pub const Options = struct {
    prefer_gpu: bool = true,
    gpu_device: ?*GpuDevice = null,
    /// Small jobs stay on CPU even when a GPU exists. The threshold avoids
    /// command encoding and upload overhead for UI-scale scenes while still
    /// letting large batches move to an external GPU backend.
    cpu_fallback_threshold: usize = 4096,
};

pub const HybridStats = struct {
    cpu_jobs: usize = 0,
    gpu_jobs: usize = 0,
    fallback_jobs: usize = 0,
};

pub const HybridRenderer = struct {
    allocator: std.mem.Allocator,
    options: Options,
    cpu_renderer: CpuRenderer,
    stats: HybridStats = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) HybridRenderer {
        return .{
            .allocator = allocator,
            .options = options,
            .cpu_renderer = CpuRenderer.init(allocator),
        };
    }

    pub fn deinit(self: *HybridRenderer) void {
        self.cpu_renderer.deinit();
        self.* = undefined;
    }

    pub fn render2D(self: *HybridRenderer, scene: *const Scene2D, target: *Image) !void {
        if (self.shouldUseGpu2D(scene, target)) {
            try self.options.gpu_device.?.enqueue2D(scene, target);
            self.stats.gpu_jobs += 1;
            return;
        }

        // The CPU path is the semantic fallback for unavailable GPUs, rejected
        // backend limits, and intentionally-small batches.
        try self.cpu_renderer.render2D(scene, target);
        self.stats.cpu_jobs += 1;
        if (self.options.prefer_gpu) self.stats.fallback_jobs += 1;
    }

    pub fn render3D(self: *HybridRenderer, scene: *const Scene3D, target: *Image) !void {
        if (self.shouldUseGpu3D(scene, target)) {
            try self.options.gpu_device.?.enqueue3D(scene, target);
            self.stats.gpu_jobs += 1;
            return;
        }

        try self.cpu_renderer.render3D(scene, target);
        self.stats.cpu_jobs += 1;
        if (self.options.prefer_gpu) self.stats.fallback_jobs += 1;
    }

    pub fn flushGpu(self: *HybridRenderer) !void {
        const gpu_device = self.options.gpu_device orelse return error.BackendUnavailable;
        try gpu_device.submitQueued();
    }

    fn shouldUseGpu2D(self: *const HybridRenderer, scene: *const Scene2D, target: *const Image) bool {
        const gpu_device = self.options.gpu_device orelse return false;
        if (!self.options.prefer_gpu or !gpu_device.canAccept2D(scene, target)) return false;
        // Use primitive count as the cheap scheduling signal. The full strip
        // count is only known after batch construction, which would duplicate
        // work if the scheduler later chose the CPU.
        return scene.primitives.items.len >= self.options.cpu_fallback_threshold;
    }

    fn shouldUseGpu3D(self: *const HybridRenderer, scene: *const Scene3D, target: *const Image) bool {
        const gpu_device = self.options.gpu_device orelse return false;
        if (!self.options.prefer_gpu or !gpu_device.canAccept3D(scene, target)) return false;
        return scene.triangles.items.len + scene.points.items.len + scene.lines.items.len >= self.options.cpu_fallback_threshold;
    }
};

test "hybrid renderer falls back to CPU when GPU is absent" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, .white);

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var renderer = HybridRenderer.init(allocator, .{ .prefer_gpu = true });
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.cpu_jobs);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.fallback_jobs);
}

test "hybrid renderer can enqueue large jobs to GPU" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, .white);

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    var renderer = HybridRenderer.init(allocator, .{
        .prefer_gpu = true,
        .gpu_device = &gpu,
        .cpu_fallback_threshold = 1,
    });
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.gpu_jobs);
    try std.testing.expectEqual(@as(usize, 1), gpu.commands.items.len);
}

test "hybrid renderer can enqueue 3D jobs to GPU" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
    });

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    var renderer = HybridRenderer.init(allocator, .{
        .prefer_gpu = true,
        .gpu_device = &gpu,
        .cpu_fallback_threshold = 1,
    });
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.gpu_jobs);
    try std.testing.expectEqual(@as(usize, 1), gpu.commands.items.len);
    try std.testing.expectEqual(@import("gpu.zig").CommandKind.render_3d, gpu.commands.items[0].kind);
    try std.testing.expectEqual(@as(usize, 1), gpu.batches.items[0].triangles.items.len);
}

test "hybrid renderer GPU path encodes updated 3D resource handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const red = [_]Color{.red};
    const blue = [_]Color{.blue};
    const texture = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &red });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = texture,
    });
    try scene.replaceTextures(&.{
        .{ .handle = texture, .texture = .{ .width = 1, .height = 1, .pixels = &blue } },
    });

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    var renderer = HybridRenderer.init(allocator, .{
        .prefer_gpu = true,
        .gpu_device = &gpu,
        .cpu_fallback_threshold = 1,
    });
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.gpu_jobs);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), gpu.batches.items[0].triangles.items[0].a.rgba);
}

test "hybrid renderer falls back when GPU limits reject a target" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, .white);

    var img = try Image.init(allocator, 8, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.initWithLimits(allocator, .external, .{
        .max_target_width = 4,
        .max_target_height = 4,
    });
    defer gpu.deinit();

    var renderer = HybridRenderer.init(allocator, .{
        .prefer_gpu = true,
        .gpu_device = &gpu,
        .cpu_fallback_threshold = 1,
    });
    defer renderer.deinit();
    try renderer.render2D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.cpu_jobs);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.fallback_jobs);
    try std.testing.expectEqual(@as(usize, 0), gpu.commands.items.len);
}

test "hybrid renderer falls back for 3D when GPU limits reject a target" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    const red = [_]Color{.red};
    const blue = [_]Color{.blue};
    const texture = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &red });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = texture,
    });
    try scene.replaceTextures(&.{
        .{ .handle = texture, .texture = .{ .width = 1, .height = 1, .pixels = &blue } },
    });

    var img = try Image.init(allocator, 8, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.initWithLimits(allocator, .external, .{
        .max_target_width = 4,
        .max_target_height = 4,
    });
    defer gpu.deinit();

    var renderer = HybridRenderer.init(allocator, .{
        .prefer_gpu = true,
        .gpu_device = &gpu,
        .cpu_fallback_threshold = 1,
    });
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.cpu_jobs);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.fallback_jobs);
    try std.testing.expectEqual(@as(usize, 0), gpu.commands.items.len);
    try std.testing.expect(img.countNonTransparentPixels() > 0);
    var has_blue = false;
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if ((img.pixel(x, y) orelse Color.transparent).b == 255) has_blue = true;
        }
    }
    try std.testing.expect(has_blue);
}

test "hybrid renderer falls back when backend lacks 3D feature support" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    const pixels = [_]Color{.blue};
    const texture = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &pixels });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = texture,
    });

    var img = try Image.init(allocator, 8, 8, .transparent);
    defer img.deinit();

    const Sink = struct {
        fn submit(_: *anyopaque, _: @import("gpu.zig").GpuCommand, _: *const @import("gpu.zig").GpuBatch) !void {}
    };
    var sink: u8 = 0;
    var gpu = GpuDevice.init(allocator, .none);
    defer gpu.deinit();
    gpu.setBackend(.{
        .context = &sink,
        .submitFn = Sink.submit,
        .capabilities = .{ .textured_3d = false },
    });

    var renderer = HybridRenderer.init(allocator, .{
        .prefer_gpu = true,
        .gpu_device = &gpu,
        .cpu_fallback_threshold = 1,
    });
    defer renderer.deinit();
    try renderer.render3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), renderer.stats.cpu_jobs);
    try std.testing.expectEqual(@as(usize, 1), renderer.stats.fallback_jobs);
    try std.testing.expectEqual(@as(usize, 0), gpu.commands.items.len);
}

test "hybrid renderer flushes queued GPU work" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, .white);

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    const Sink = struct {
        submitted: usize = 0,

        fn submit(context: *anyopaque, command: @import("gpu.zig").GpuCommand, batch: *const @import("gpu.zig").GpuBatch) !void {
            _ = command;
            _ = batch;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.submitted += 1;
        }
    };

    var sink = Sink{};
    var gpu = GpuDevice.init(allocator, .none);
    defer gpu.deinit();
    gpu.setBackend(.{ .context = &sink, .submitFn = Sink.submit });

    var renderer = HybridRenderer.init(allocator, .{
        .prefer_gpu = true,
        .gpu_device = &gpu,
        .cpu_fallback_threshold = 1,
    });
    defer renderer.deinit();

    try renderer.render2D(&scene, &img);
    try renderer.flushGpu();

    try std.testing.expectEqual(@as(usize, 1), sink.submitted);
    try std.testing.expectEqual(@as(usize, 0), gpu.commands.items.len);
}
