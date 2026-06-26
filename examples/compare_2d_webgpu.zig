const std = @import("std");
const builtin = @import("builtin");
const iris = @import("iris");
const zgpu = @import("zgpu");

const width = 96;
const height = 64;

const c = if (builtin.os.tag == .linux) @cImport({
    @cInclude("X11/Xlib.h");
}) else struct {};

const X11Window = if (builtin.os.tag == .linux) struct {
    display: *c.Display,
    window: c.Window,

    fn init() !X11Window {
        const display = c.XOpenDisplay(null) orelse return error.X11DisplayUnavailable;
        errdefer _ = c.XCloseDisplay(display);
        const screen = c.XDefaultScreen(display);
        const root = c.XRootWindow(display, screen);
        const window = c.XCreateSimpleWindow(
            display,
            root,
            0,
            0,
            width,
            height,
            0,
            c.XBlackPixel(display, screen),
            c.XWhitePixel(display, screen),
        );
        if (window == 0) return error.X11CreateWindowFailed;
        _ = c.XMapWindow(display, window);
        _ = c.XFlush(display);
        return .{ .display = display, .window = window };
    }

    fn deinit(self: *X11Window) void {
        _ = c.XDestroyWindow(self.display, self.window);
        _ = c.XCloseDisplay(self.display);
        self.* = undefined;
    }
} else struct {};

const WindowProvider = struct {
    fn getTime() f64 {
        return 0.0;
    }

    fn getFramebufferSize(_: *const anyopaque) [2]u32 {
        return .{ width, height };
    }

    fn getWin32Window(_: *const anyopaque) callconv(.c) *anyopaque {
        return undefined;
    }

    fn getX11Display() callconv(.c) *anyopaque {
        if (builtin.os.tag != .linux) return undefined;
        return @ptrCast(g_x11.?.display);
    }

    fn getX11Window(_: *const anyopaque) callconv(.c) u32 {
        if (builtin.os.tag != .linux) return 0;
        return @intCast(g_x11.?.window);
    }

    fn getCocoaWindow(_: *const anyopaque) callconv(.c) ?*anyopaque {
        return null;
    }
};

var g_x11: ?X11Window = null;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) {
        var buffer: [128]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try out.interface.writeAll("compare-2d-webgpu requires a native desktop window provider\n");
        try out.interface.flush();
        return;
    }
    if (builtin.os.tag != .linux) {
        var buffer: [128]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try out.interface.writeAll("compare-2d-webgpu currently uses Linux X11 window glue\n");
        try out.interface.flush();
        return;
    }

    const allocator = init.arena.allocator();
    var scene = iris.Scene2D.init(allocator);
    defer scene.deinit();
    try buildScene(&scene);

    var cpu_image = try iris.Image.init(allocator, width, height, .transparent);
    defer cpu_image.deinit();
    var cpu_renderer = iris.CpuRenderer.init(allocator);
    defer cpu_renderer.deinit();
    try cpu_renderer.render2D(&scene, &cpu_image);

    var gpu_image = try iris.Image.init(allocator, width, height, .transparent);
    defer gpu_image.deinit();

    g_x11 = try X11Window.init();
    defer if (g_x11) |*window| window.deinit();

    const provider = zgpu.WindowProvider{
        .window = @ptrFromInt(1),
        .fn_getTime = WindowProvider.getTime,
        .fn_getFramebufferSize = WindowProvider.getFramebufferSize,
        .fn_getWin32Window = WindowProvider.getWin32Window,
        .fn_getX11Display = WindowProvider.getX11Display,
        .fn_getX11Window = WindowProvider.getX11Window,
        .fn_getWaylandDisplay = null,
        .fn_getWaylandSurface = null,
        .fn_getCocoaWindow = WindowProvider.getCocoaWindow,
    };

    const gctx = try zgpu.GraphicsContext.create(allocator, provider, .{});
    defer gctx.destroy(allocator);

    var backend = iris.WebGpuBackend.init(gctx);
    defer backend.deinit();
    try backend.createOwnedTarget(width, height);
    try backend.createReadbackBuffer();
    try backend.initStripsPipeline();
    try backend.renderScene2DToReadback(allocator, &scene);
    const status = try backend.waitForReadback(10_000);
    if (status != .success) return error.WebGpuReadbackFailed;
    try backend.copyMappedReadbackToImage(&gpu_image);
    try backend.unmapReadback();

    const comparison = try cpu_image.compare(&gpu_image, 0);
    try printComparison(init.io, comparison);
    if (comparison.mismatched_pixels != 0) return error.WebGpuComparisonExceededThreshold;
}

fn buildScene(scene: *iris.Scene2D) !void {
    try scene.fillRect(.{ .x = 2, .y = 2, .w = 22, .h = 12 }, iris.Color.red);
    try scene.fillRect(.{ .x = 28, .y = 4, .w = 18, .h = 18 }, iris.Color.green);
    try scene.fillTriangle(.{
        .{ .x = 12, .y = 36 },
        .{ .x = 42, .y = 30 },
        .{ .x = 20, .y = 56 },
    }, iris.Color.blue);
    try scene.fillRect(.{ .x = 54, .y = 10, .w = 28, .h = 36 }, iris.Color.white);
}

fn printComparison(io: std.Io, comparison: iris.ImageComparison) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print(
        "compare-2d-webgpu {d}x{d}: mismatched={d} max_channel_error={d} mean_absolute_error={d:.3}\n",
        .{ comparison.width, comparison.height, comparison.mismatched_pixels, comparison.max_channel_error, comparison.mean_absolute_error },
    );
    try out.interface.flush();
}
