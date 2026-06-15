const std = @import("std");
const color = @import("color.zig");
const math = @import("math.zig");
const render_graph = @import("render_graph.zig");
const scene2d = @import("scene2d.zig");

pub const CpuTimingSample = struct {
    label: []const u8,
    elapsed_ns: u64,
};

pub const CpuTimingDebugDump = struct {
    samples: usize = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
};

pub const GpuTimingSample = struct {
    label: []const u8,
    elapsed_ns: u64,
};

pub const GpuTimingDebugDump = struct {
    samples: usize = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
};

pub const CpuProfilerOverlayOptions = struct {
    rect: math.Rect,
    background: color.Color = color.Color.rgba(8, 12, 18, 210),
    bar_color: color.Color = color.Color.rgba(82, 174, 255, 230),
    empty_color: color.Color = color.Color.rgba(38, 48, 64, 180),
    row_height: f32 = 4.0,
    gap: f32 = 2.0,
    padding: f32 = 4.0,
};

pub const RenderGraphGpuTiming = struct {
    pass: render_graph.PassHandle,
    elapsed_ns: u64,
};

const ActiveSample = struct {
    label: []u8,
    started: std.Io.Timestamp,
};

pub const CpuProfiler = struct {
    allocator: std.mem.Allocator,
    active: std.ArrayList(ActiveSample) = .empty,
    samples: std.ArrayList(CpuTimingSample) = .empty,

    pub fn init(allocator: std.mem.Allocator) CpuProfiler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CpuProfiler) void {
        self.clear();
        self.samples.deinit(self.allocator);
        self.active.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *CpuProfiler) void {
        for (self.active.items) |sample| {
            self.allocator.free(sample.label);
        }
        self.active.clearRetainingCapacity();
        for (self.samples.items) |sample| {
            self.allocator.free(sample.label);
        }
        self.samples.clearRetainingCapacity();
    }

    pub fn begin(self: *CpuProfiler, io: std.Io, label: []const u8) !usize {
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        try self.active.append(self.allocator, .{
            .label = owned_label,
            .started = std.Io.Clock.awake.now(io),
        });
        return self.active.items.len - 1;
    }

    pub fn end(self: *CpuProfiler, io: std.Io, handle: usize) !void {
        if (handle >= self.active.items.len) return error.InvalidTimingHandle;
        var active_sample = self.active.swapRemove(handle);
        errdefer self.allocator.free(active_sample.label);
        try self.samples.append(self.allocator, .{
            .label = active_sample.label,
            .elapsed_ns = durationToU64(active_sample.started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()),
        });
    }

    pub fn debugDump(self: *const CpuProfiler) CpuTimingDebugDump {
        var dump = CpuTimingDebugDump{ .samples = self.samples.items.len };
        for (self.samples.items) |sample| {
            dump.total_ns += sample.elapsed_ns;
            dump.max_ns = @max(dump.max_ns, sample.elapsed_ns);
        }
        return dump;
    }

    pub fn appendDebugOverlay(self: *const CpuProfiler, scene: *scene2d.Scene2D, options: CpuProfilerOverlayOptions) !void {
        try scene.fillRect(options.rect, options.background);
        const content_x = options.rect.x + options.padding;
        const content_y = options.rect.y + options.padding;
        const content_w = @max(0.0, options.rect.w - options.padding * 2.0);
        const max_ns = @max(1, self.debugDump().max_ns);
        var y = content_y;
        for (self.samples.items) |sample| {
            if (y + options.row_height > options.rect.y + options.rect.h - options.padding) break;
            try scene.fillRect(.{
                .x = content_x,
                .y = y,
                .w = content_w,
                .h = options.row_height,
            }, options.empty_color);
            const ratio = @as(f32, @floatFromInt(sample.elapsed_ns)) / @as(f32, @floatFromInt(max_ns));
            try scene.fillRect(.{
                .x = content_x,
                .y = y,
                .w = content_w * @min(1.0, @max(0.0, ratio)),
                .h = options.row_height,
            }, options.bar_color);
            y += options.row_height + options.gap;
        }
    }
};

pub const GpuProfiler = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(GpuTimingSample) = .empty,

    pub fn init(allocator: std.mem.Allocator) GpuProfiler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GpuProfiler) void {
        self.clear();
        self.samples.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *GpuProfiler) void {
        for (self.samples.items) |sample| {
            self.allocator.free(sample.label);
        }
        self.samples.clearRetainingCapacity();
    }

    pub fn record(self: *GpuProfiler, label: []const u8, elapsed_ns: u64) !void {
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        try self.samples.append(self.allocator, .{
            .label = owned_label,
            .elapsed_ns = elapsed_ns,
        });
    }

    pub fn debugDump(self: *const GpuProfiler) GpuTimingDebugDump {
        var dump = GpuTimingDebugDump{ .samples = self.samples.items.len };
        for (self.samples.items) |sample| {
            dump.total_ns += sample.elapsed_ns;
            dump.max_ns = @max(dump.max_ns, sample.elapsed_ns);
        }
        return dump;
    }
};

pub fn recordRenderGraphGpuTimings(
    profiler: *GpuProfiler,
    graph: *const render_graph.RenderGraph,
    allocator: std.mem.Allocator,
    timings: []const RenderGraphGpuTiming,
) !void {
    var passes = try graph.passDebugDump(allocator);
    defer passes.deinit(allocator);

    for (timings) |timing| {
        if (timing.pass.index >= passes.items.len) return error.InvalidTimingPass;
        try profiler.record(passes.items[timing.pass.index].label, timing.elapsed_ns);
    }
}

fn durationToU64(value: anytype) u64 {
    if (value <= 0) return 0;
    const max_u64 = std.math.maxInt(u64);
    if (value > max_u64) return max_u64;
    return @intCast(value);
}

test "CPU profiler records named timing samples" {
    const allocator = std.testing.allocator;
    var profiler = CpuProfiler.init(allocator);
    defer profiler.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();

    const handle = try profiler.begin(io, "build-batch");
    try profiler.end(io, handle);

    try std.testing.expectEqual(@as(usize, 1), profiler.samples.items.len);
    try std.testing.expectEqualStrings("build-batch", profiler.samples.items[0].label);
    const dump = profiler.debugDump();
    try std.testing.expectEqual(@as(usize, 1), dump.samples);
    try std.testing.expect(dump.total_ns >= dump.max_ns);
    try std.testing.expectError(error.InvalidTimingHandle, profiler.end(io, 99));
}

test "CPU profiler appends 2D debug overlay bars" {
    const allocator = std.testing.allocator;
    var profiler = CpuProfiler.init(allocator);
    defer profiler.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();

    const first = try profiler.begin(io, "first");
    try profiler.end(io, first);
    const second = try profiler.begin(io, "second");
    try profiler.end(io, second);

    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    try profiler.appendDebugOverlay(&scene, .{
        .rect = .{ .x = 1, .y = 2, .w = 20, .h = 18 },
        .row_height = 3,
        .gap = 1,
        .padding = 2,
    });

    try std.testing.expectEqual(@as(usize, 5), scene.primitives.items.len);
    try std.testing.expectEqual(color.Color.rgba(8, 12, 18, 210), scene.primitives.items[0].fill_rect.color);
    try std.testing.expectEqual(color.Color.rgba(38, 48, 64, 180), scene.primitives.items[1].fill_rect.color);
    try std.testing.expectEqual(color.Color.rgba(82, 174, 255, 230), scene.primitives.items[2].fill_rect.color);
}

test "GPU profiler records backend timing samples" {
    const allocator = std.testing.allocator;
    var profiler = GpuProfiler.init(allocator);
    defer profiler.deinit();

    try profiler.record("queued-3d-render", 120);
    try profiler.record("present", 40);

    try std.testing.expectEqual(@as(usize, 2), profiler.samples.items.len);
    try std.testing.expectEqualStrings("queued-3d-render", profiler.samples.items[0].label);
    const dump = profiler.debugDump();
    try std.testing.expectEqual(@as(usize, 2), dump.samples);
    try std.testing.expectEqual(@as(u64, 160), dump.total_ns);
    try std.testing.expectEqual(@as(u64, 120), dump.max_ns);

    profiler.clear();
    try std.testing.expectEqual(@as(usize, 0), profiler.samples.items.len);
}

test "GPU profiler records render graph pass timing labels" {
    const allocator = std.testing.allocator;
    var graph = render_graph.RenderGraph.init(allocator);
    defer graph.deinit();
    const color_target = try graph.addResource(.{ .label = "color", .kind = .texture });
    const swapchain = try graph.addResource(.{ .label = "swapchain", .kind = .texture, .transient = false, .external = true });
    const render = try graph.addPass(.{ .label = "queued-3d-render", .kind = .render, .writes = &.{color_target} });
    const present = try graph.addPass(.{ .label = "present", .kind = .copy, .reads = &.{color_target}, .writes = &.{swapchain}, .side_effect = true });

    var timings = GpuProfiler.init(allocator);
    defer timings.deinit();
    try recordRenderGraphGpuTimings(&timings, &graph, allocator, &.{
        .{ .pass = render, .elapsed_ns = 100 },
        .{ .pass = present, .elapsed_ns = 25 },
    });

    try std.testing.expectEqual(@as(usize, 2), timings.samples.items.len);
    try std.testing.expectEqualStrings("queued-3d-render", timings.samples.items[0].label);
    try std.testing.expectEqualStrings("present", timings.samples.items[1].label);
    try std.testing.expectEqual(@as(u64, 125), timings.debugDump().total_ns);
    try std.testing.expectError(error.InvalidTimingPass, recordRenderGraphGpuTimings(&timings, &graph, allocator, &.{
        .{ .pass = .{ .index = 99 }, .elapsed_ns = 1 },
    }));
}
