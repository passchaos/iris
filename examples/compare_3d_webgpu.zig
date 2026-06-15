const std = @import("std");
const iris = @import("iris");
const objc = @import("objc");
const zgpu = @import("zgpu");

const Object = objc.Object;

const width = 320;
const height = 220;
const clear_color = iris.Color.rgba(5, 7, 11, 255);

const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

const NSPoint = extern struct {
    x: f64,
    y: f64,
};

const NSSize = extern struct {
    width: f64,
    height: f64,
};

const NSBackingStoreBuffered: i32 = 2;
const NSWindowStyleMaskBorderless: u64 = 0;

const CocoaWindow = struct {
    app: Object,
    window: Object,
    pool: Object,
};

const WindowProvider = struct {
    fn getTime() f64 {
        return 0.0;
    }

    fn getFramebufferSize(window_ptr: *const anyopaque) [2]u32 {
        const window = Object.fromId(@as(?*anyopaque, @ptrFromInt(@intFromPtr(window_ptr))));
        const frame = window.msgSend(NSRect, "frame", .{});
        const scale = window.msgSend(f64, "backingScaleFactor", .{});
        return .{
            @intFromFloat(frame.size.width * scale),
            @intFromFloat(frame.size.height * scale),
        };
    }

    fn getWin32Window(_: *const anyopaque) callconv(.c) *anyopaque {
        return undefined;
    }

    fn getX11Display() callconv(.c) *anyopaque {
        return undefined;
    }

    fn getX11Window(_: *const anyopaque) callconv(.c) u32 {
        return 0;
    }

    fn getCocoaWindow(window_ptr: *const anyopaque) callconv(.c) ?*anyopaque {
        return @ptrFromInt(@intFromPtr(window_ptr));
    }
};

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").target.os.tag != .macos) {
        var buffer: [128]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try out.interface.writeAll("compare-3d-webgpu currently uses native macOS Cocoa window glue\n");
        try out.interface.flush();
        return;
    }

    const allocator = init.arena.allocator();
    var scene = iris.Scene3D.init(allocator);
    defer scene.deinit();
    try buildScene(&scene);

    var cpu_image = try iris.Image.init(allocator, width, height, clear_color);
    defer cpu_image.deinit();
    var cpu_renderer = iris.CpuRenderer.init(allocator);
    defer cpu_renderer.deinit();
    try cpu_renderer.render3D(&scene, &cpu_image);

    var gpu_image = try iris.Image.init(allocator, width, height, .transparent);
    defer gpu_image.deinit();

    var cocoa = try createHiddenWindow();
    defer cocoa.pool.msgSend(void, "drain", .{});

    const provider = zgpu.WindowProvider{
        .window = @ptrFromInt(@intFromPtr(cocoa.window.value)),
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
    backend.setRenderPassOptions(.{
        .color_clear = .{
            .r = @as(f64, @floatFromInt(clear_color.r)) / 255.0,
            .g = @as(f64, @floatFromInt(clear_color.g)) / 255.0,
            .b = @as(f64, @floatFromInt(clear_color.b)) / 255.0,
            .a = @as(f64, @floatFromInt(clear_color.a)) / 255.0,
        },
    });
    try backend.createOwnedTarget(width, height);
    try backend.createReadbackBuffer();
    const shader = try std.Io.Dir.cwd().readFileAllocOptions(init.io, iris.ShaderContract.render_triangles_path, allocator, .limited(64 * 1024), .of(u8), 0);
    defer allocator.free(shader);
    try backend.initTrianglesPipelineFromSource(shader);
    try backend.renderScene3DToReadback(allocator, &scene);
    const status = try backend.waitForReadback(10_000);
    if (status != .success) return error.WebGpuReadbackFailed;
    try backend.copyMappedReadbackToImage(&gpu_image);
    try backend.unmapReadback();

    const comparison = try cpu_image.compare(&gpu_image, 8);
    try printComparison(init.io, comparison);
    if (!comparison.within(512, 32, 4.0)) {
        try writePpm(init.io, "zig-out/compare_3d_webgpu_cpu.ppm", &cpu_image);
        try writePpm(init.io, "zig-out/compare_3d_webgpu_gpu.ppm", &gpu_image);
    }
    if (!comparison.within(512, 32, 4.0)) return error.WebGpuComparisonExceededThreshold;
}

fn buildScene(scene: *iris.Scene3D) !void {
    scene.setCamera(iris.scene3d.Camera.perspectiveLookAt(
        .{ .x = 0.0, .y = 0.0, .z = 2.4 },
        .{},
        .{ .y = 1.0 },
        std.math.pi / 4.8,
        @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)),
        0.1,
        8.0,
    ));
    scene.disableLighting();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.7, .y = -0.55, .z = 0.0 },
            .{ .x = 0.7, .y = -0.55, .z = 0.0 },
            .{ .x = 0.0, .y = 0.65, .z = 0.0 },
        },
        .colors = .{ .red, .green, .blue },
        .color = .white,
        .normals = .{ .{ .z = 1.0 }, .{ .z = 1.0 }, .{ .z = 1.0 } },
    });
}

fn createHiddenWindow() !CocoaWindow {
    const NSAutoreleasePool = objc.getClass("NSAutoreleasePool").?;
    const NSApplication = objc.getClass("NSApplication").?;
    const NSWindow = objc.getClass("NSWindow").?;

    const pool = NSAutoreleasePool.msgSend(Object, "alloc", .{});
    _ = pool.msgSend(Object, "init", .{});

    const app = NSApplication.msgSend(Object, "sharedApplication", .{});
    _ = app.msgSend(void, "setActivationPolicy:", .{@as(i32, 0)});
    _ = app.msgSend(void, "finishLaunching", .{});

    const rect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } };
    const window = NSWindow.msgSend(Object, "alloc", .{});
    _ = window.msgSend(Object, "initWithContentRect:styleMask:backing:defer:", .{
        rect,
        NSWindowStyleMaskBorderless,
        NSBackingStoreBuffered,
        @as(i32, 0),
    });
    return .{ .app = app, .window = window, .pool = pool };
}

fn printComparison(io: std.Io, comparison: iris.ImageComparison) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print(
        "compare-3d-webgpu {d}x{d}: mismatched={d} max_channel_error={d} mean_absolute_error={d:.3}\n",
        .{ comparison.width, comparison.height, comparison.mismatched_pixels, comparison.max_channel_error, comparison.mean_absolute_error },
    );
    try out.interface.flush();
}

fn writePpm(io: std.Io, path: []const u8, image: *const iris.Image) !void {
    std.Io.Dir.cwd().createDir(io, "zig-out", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.print("P6\n{d} {d}\n255\n", .{ image.width, image.height });
    for (image.pixels) |pixel| {
        try writer.interface.writeAll(&.{ pixel.r, pixel.g, pixel.b });
    }
    try writer.interface.flush();
}
