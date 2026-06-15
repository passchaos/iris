const std = @import("std");
const cpu = @import("cpu.zig");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const scene2d = @import("scene2d.zig");
const window_types = @import("window_types.zig");
const window_draw = @import("window_draw.zig");
const webgpu_backend = @import("webgpu_backend.zig");

pub const NativeHandle = union(enum) {
    windows: WindowsNativeHandle,
    macos: MacOSNativeHandle,
    linux: LinuxNativeHandle,
    web: WebNativeHandle,
};

pub const WindowsNativeHandle = struct {
    hwnd: ?*anyopaque = null,
    hinstance: ?*anyopaque = null,
};

pub const MacOSNativeHandle = struct {
    nswindow: ?*anyopaque = null,
    nsview: ?*anyopaque = null,
    content_view: ?*anyopaque = null,
};

pub const LinuxNativeHandle = struct {
    wayland_display: ?*anyopaque = null,
    wayland_surface: ?*anyopaque = null,
    x11_display: ?*anyopaque = null,
    x11_window: u32 = 0,
};

pub const WebNativeHandle = struct {
    canvas: ?*anyopaque = null,
};

pub const NativeWindowProvider = struct {
    app_window: *anyopaque,
    get_time: *const fn () f64,
    get_framebuffer_size: *const fn (window: *const anyopaque) [2]u32,
    get_native_handle: *const fn (window: *const anyopaque) NativeHandle,

    pub fn webgpuProvider(self: *const NativeWindowProvider) webgpu_backend.WebGpuBackend.WindowProvider {
        return .{
            .window = @constCast(self),
            .fn_getTime = self.get_time,
            .fn_getFramebufferSize = getFramebufferSize,
            .fn_getWin32Window = getWin32Window,
            .fn_getX11Display = getX11Display,
            .fn_getX11Window = getX11Window,
            .fn_getWaylandDisplay = getWaylandDisplay,
            .fn_getWaylandSurface = getWaylandSurface,
            .fn_getCocoaWindow = getCocoaWindow,
        };
    }
};

pub const ProviderCallbacks = struct {
    app_window: *anyopaque,
    get_time: *const fn () f64,
    get_framebuffer_size: *const fn (window: *const anyopaque) [2]u32,
    get_native_handle: *const fn (window: *const anyopaque) NativeHandle,
};

pub const WindowRenderContext = struct {
    allocator: std.mem.Allocator,
    native_provider: *NativeWindowProvider,
    webgpu_context: ?*webgpu_backend.WebGpuBackend.GraphicsContext = null,
    cpu_window_renderer: ?CpuWindowRenderer = null,

    pub fn init(
        allocator: std.mem.Allocator,
        callbacks: ProviderCallbacks,
        backend: window_types.Backend,
        width: u32,
        height: u32,
    ) !WindowRenderContext {
        const native_provider = try allocator.create(NativeWindowProvider);
        errdefer allocator.destroy(native_provider);
        native_provider.* = .{
            .app_window = callbacks.app_window,
            .get_time = callbacks.get_time,
            .get_framebuffer_size = callbacks.get_framebuffer_size,
            .get_native_handle = callbacks.get_native_handle,
        };
        var context = WindowRenderContext{
            .allocator = allocator,
            .native_provider = native_provider,
        };
        errdefer context.deinit();
        switch (backend) {
            .gpu => context.webgpu_context = try createWebGpuContext(allocator, native_provider, .{}),
            .cpu => context.cpu_window_renderer = try CpuWindowRenderer.init(allocator, native_provider, width, height),
        }
        return context;
    }

    pub fn deinit(self: *WindowRenderContext) void {
        if (self.cpu_window_renderer) |*renderer| renderer.deinit();
        if (self.webgpu_context) |context| context.destroy(self.allocator);
        self.allocator.destroy(self.native_provider);
        self.* = undefined;
    }

    pub fn webgpuContext(self: *WindowRenderContext) ?*webgpu_backend.WebGpuBackend.GraphicsContext {
        return self.webgpu_context;
    }

    pub fn cpuWindowRenderer(self: *WindowRenderContext) ?*CpuWindowRenderer {
        if (self.cpu_window_renderer) |*renderer| return renderer;
        return null;
    }
};

fn provider(window: *const anyopaque) NativeWindowProvider {
    const ptr: *const NativeWindowProvider = @ptrCast(@alignCast(window));
    return ptr.*;
}

fn getFramebufferSize(window: *const anyopaque) [2]u32 {
    const native = provider(window);
    return native.get_framebuffer_size(native.app_window);
}

fn getWin32Window(window: *const anyopaque) callconv(.c) *anyopaque {
    const native = provider(window);
    return switch (native.get_native_handle(native.app_window)) {
        .windows => |w| w.hwnd orelse undefined,
        else => undefined,
    };
}

fn getX11Display() callconv(.c) *anyopaque {
    return undefined;
}

fn getX11Window(window: *const anyopaque) callconv(.c) u32 {
    const native = provider(window);
    return switch (native.get_native_handle(native.app_window)) {
        .linux => |l| l.x11_window,
        else => 0,
    };
}

fn getWaylandDisplay() callconv(.c) *anyopaque {
    return undefined;
}

fn getWaylandSurface(window: *const anyopaque) callconv(.c) *anyopaque {
    const native = provider(window);
    return switch (native.get_native_handle(native.app_window)) {
        .linux => |l| l.wayland_surface orelse undefined,
        else => undefined,
    };
}

fn getCocoaWindow(window: *const anyopaque) callconv(.c) ?*anyopaque {
    const native = provider(window);
    return switch (native.get_native_handle(native.app_window)) {
        .macos => |m| m.nswindow,
        else => null,
    };
}

pub fn createWebGpuContext(
    allocator: std.mem.Allocator,
    native_provider: *const NativeWindowProvider,
    options: webgpu_backend.WebGpuBackend.GraphicsContextOptions,
) !*webgpu_backend.WebGpuBackend.GraphicsContext {
    return try webgpu_backend.WebGpuBackend.createGraphicsContext(allocator, native_provider.webgpuProvider(), options);
}

pub const CpuPresenter = struct {
    ns_window: *anyopaque,
    layer: *anyopaque,
    bitmap: ?*anyopaque = null,
    bitmap_width: u32 = 0,
    bitmap_height: u32 = 0,

    pub fn init(native_provider: *const NativeWindowProvider) !CpuPresenter {
        const handle = native_provider.get_native_handle(native_provider.app_window);
        const ns_window = switch (handle) {
            .macos => |mac| mac.nswindow orelse return error.MissingNativeWindow,
            else => return error.UnsupportedPlatform,
        };
        const ns_view = switch (handle) {
            .macos => |mac| mac.content_view orelse mac.nsview orelse msgSend(ns_window, "contentView", .{}, ?*anyopaque) orelse return error.MissingContentView,
            else => unreachable,
        };
        msgSend(ns_view, "setWantsLayer:", .{true}, void);
        const layer_class = objc.objc_getClass("CALayer") orelse return error.MissingCALayerClass;
        const layer = msgSend(layer_class, "layer", .{}, ?*anyopaque) orelse return error.MissingCALayer;
        msgSend(layer, "setContentsScale:", .{backingScaleFactor(ns_window)}, void);
        msgSend(ns_view, "setLayer:", .{layer}, void);
        return .{ .ns_window = ns_window, .layer = layer };
    }

    pub fn deinit(self: *CpuPresenter) void {
        if (self.bitmap) |bitmap| {
            msgSend(bitmap, "release", .{}, void);
        }
        self.* = undefined;
    }

    pub fn present(self: *CpuPresenter, image: *const Image) !void {
        try self.ensureBitmap(image.width, image.height);
        const bitmap = self.bitmap.?;
        const data = msgSend(bitmap, "bitmapData", .{}, [*]u8);
        for (image.pixels, 0..) |pixel, i| {
            const base = i * 4;
            data[base + 0] = pixel.r;
            data[base + 1] = pixel.g;
            data[base + 2] = pixel.b;
            data[base + 3] = pixel.a;
        }
        const cg_image = msgSend(bitmap, "CGImage", .{}, ?*anyopaque) orelse return error.MissingCGImage;
        msgSend(self.layer, "setContents:", .{cg_image}, void);
        msgSend(self.layer, "setContentsScale:", .{backingScaleFactor(self.ns_window)}, void);
    }

    fn ensureBitmap(self: *CpuPresenter, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidImageSize;
        if (self.bitmap != null and self.bitmap_width == width and self.bitmap_height == height) return;
        if (self.bitmap) |bitmap| {
            msgSend(bitmap, "release", .{}, void);
            self.bitmap = null;
        }
        const bitmap_class = objc.objc_getClass("NSBitmapImageRep") orelse return error.MissingNSBitmapImageRepClass;
        const string_class = objc.objc_getClass("NSString") orelse return error.MissingNSStringClass;
        const bitmap = msgSend(bitmap_class, "alloc", .{}, ?*anyopaque) orelse return error.MissingNSBitmapImageRep;
        const color_space = msgSend(string_class, "stringWithUTF8String:", .{"NSCalibratedRGBColorSpace"}, ?*anyopaque) orelse return error.MissingColorSpaceName;
        _ = msgSend(bitmap, "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:", .{
            @as(?*anyopaque, null),
            @as(i64, @intCast(width)),
            @as(i64, @intCast(height)),
            @as(i64, 8),
            @as(i64, 4),
            true,
            false,
            color_space,
            @as(u64, 1 << 1),
            @as(i64, @intCast(width * 4)),
            @as(i64, 32),
        }, ?*anyopaque) orelse return error.BitmapInitFailed;
        self.bitmap = bitmap;
        self.bitmap_width = width;
        self.bitmap_height = height;
    }
};

pub const CpuWindowRenderer = struct {
    allocator: std.mem.Allocator,
    presenter: CpuPresenter,
    target: Image,
    scene: scene2d.Scene2D,
    draw_cmds: std.ArrayList(window_types.DrawCmd),
    renderer: cpu.CpuRenderer,
    text_provider: ?window_draw.TextAtlasProvider = null,

    pub fn init(allocator: std.mem.Allocator, native_provider: *const NativeWindowProvider, width: u32, height: u32) !CpuWindowRenderer {
        return .{
            .allocator = allocator,
            .presenter = try CpuPresenter.init(native_provider),
            .target = try Image.init(allocator, width, height, .transparent),
            .scene = scene2d.Scene2D.init(allocator),
            .draw_cmds = try std.ArrayList(window_types.DrawCmd).initCapacity(allocator, 512),
            .renderer = cpu.CpuRenderer.init(allocator),
        };
    }

    pub fn deinit(self: *CpuWindowRenderer) void {
        self.renderer.deinit();
        self.draw_cmds.deinit(self.allocator);
        self.scene.deinit();
        self.target.deinit();
        self.presenter.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *CpuWindowRenderer, width: u32, height: u32) !void {
        self.scene.clear();
        self.draw_cmds.clearRetainingCapacity();
        try self.ensureTarget(width, height);
        self.target.clear(.{ .r = 20, .g = 25, .b = 33, .a = 255 });
    }

    pub fn pushDrawList(self: *CpuWindowRenderer, draw_list: []const window_types.DrawCmd) !void {
        try self.draw_cmds.appendSlice(self.allocator, draw_list);
    }

    pub fn setTextAtlasProvider(self: *CpuWindowRenderer, text_provider: window_draw.TextAtlasProvider) void {
        self.text_provider = text_provider;
    }

    pub fn endFrame(self: *CpuWindowRenderer) !void {
        drawImmediateCpuCommands(self.draw_cmds.items, &self.target);
        if (self.text_provider) |text_provider| {
            window_draw.drawTextCommandsWithProvider(self.draw_cmds.items, &self.target, text_provider);
        }
        try self.presenter.present(&self.target);
    }

    fn ensureTarget(self: *CpuWindowRenderer, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidImageSize;
        if (self.target.width == width and self.target.height == height) return;
        self.target.deinit();
        self.target = try Image.init(self.allocator, width, height, .transparent);
    }
};

fn drawImmediateCpuCommands(draw_cmds: []const window_types.DrawCmd, target: *Image) void {
    for (draw_cmds) |cmd| {
        switch (cmd) {
            .rect => |r| fillRectDirect(target, r.rect, toCpuColor(r.color)),
            .rounded_rect => |r| fillRoundedRectDirect(target, r.rect, r.radius, toCpuColor(r.color)),
            .stroke_rounded_rect => |r| strokeRoundedRectDirect(target, r.rect, r.radius, r.thickness, toCpuColor(r.color)),
            .paint_quad => |q| {
                fillRoundedRectDirect(target, q.rect, q.radius, toCpuColor(q.background));
                if (q.border_width > 0.0 and q.border_color[3] > 0.0) {
                    strokeRoundedRectDirect(target, q.rect, q.radius, q.border_width, toCpuColor(q.border_color));
                }
            },
            .linear_gradient_rect => |g| fillLinearGradientRectDirect(target, g.rect, g.start, g.end, g.start_color, g.end_color),
            .radial_gradient_rect => |g| fillRadialGradientRectDirect(target, g.rect, g.center, g.radius, g.inner_color, g.outer_color),
            .sweep_gradient_rect => |g| fillLinearGradientRectDirect(target, g.rect, .{ g.rect.x, g.rect.y }, .{ g.rect.x + g.rect.w, g.rect.y + g.rect.h }, g.start_color, g.end_color),
            .line => |l| strokeLineDirect(target, l.a, l.b, l.thickness, toCpuColor(l.color)),
            .styled_line => |l| strokeLineDirect(target, l.a, l.b, l.style.width, toCpuColor(l.color)),
            .polyline => |pl| {
                var i: usize = 0;
                while (i + 1 < pl.points.len) : (i += 1) strokeLineDirect(target, pl.points[i], pl.points[i + 1], pl.thickness, toCpuColor(pl.color));
            },
            .styled_polyline => |pl| {
                var i: usize = 0;
                while (i + 1 < pl.points.len) : (i += 1) strokeLineDirect(target, pl.points[i], pl.points[i + 1], pl.style.width, toCpuColor(pl.color));
            },
            .point => |p| fillRoundedRectDirect(target, .{ .x = p.pos[0] - p.size * 0.5, .y = p.pos[1] - p.size * 0.5, .w = p.size, .h = p.size }, p.size * 0.5, toCpuColor(p.color)),
            .bars => |b| {
                for (b.values, 0..) |value, i| {
                    const x = b.origin[0] + @as(f32, @floatFromInt(i)) * b.bar_width;
                    fillRectDirect(target, .{ .x = x, .y = b.origin[1] + b.base, .w = b.bar_width, .h = value }, toCpuColor(b.color));
                }
            },
            .scatter => |s| {
                for (s.points) |point| {
                    fillRoundedRectDirect(target, .{ .x = point[0] - s.size * 0.5, .y = point[1] - s.size * 0.5, .w = s.size, .h = s.size }, s.size * 0.5, toCpuColor(s.color));
                }
            },
            .triangle => |t| {
                strokeLineDirect(target, t.points[0], t.points[1], 1.0, toCpuColor(t.color));
                strokeLineDirect(target, t.points[1], t.points[2], 1.0, toCpuColor(t.color));
                strokeLineDirect(target, t.points[2], t.points[0], 1.0, toCpuColor(t.color));
            },
            .ellipse => |e| fillEllipseDirect(target, e.center, e.radius, toCpuColor(e.color)),
            .stroke_ellipse => |e| strokeEllipseDirect(target, e.center, e.radius, e.thickness, toCpuColor(e.color)),
            .fill_path, .stroke_path, .image, .text, .clip_begin, .clip_end => {},
        }
    }
}

fn fillRectDirect(target: *Image, rect: window_types.Rect, color: Color) void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    const x0 = clampFloor(rect.x, target.width);
    const y0 = clampFloor(rect.y, target.height);
    const x1 = clampCeil(rect.x + rect.w, target.width);
    const y1 = clampCeil(rect.y + rect.h, target.height);
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) target.blendPixel(x, y, color);
    }
}

fn fillRoundedRectDirect(target: *Image, rect: window_types.Rect, radius: f32, color: Color) void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    if (radius <= 0.5) return fillRectDirect(target, rect, color);
    const x0 = clampFloor(rect.x, target.width);
    const y0 = clampFloor(rect.y, target.height);
    const x1 = clampCeil(rect.x + rect.w, target.width);
    const y1 = clampCeil(rect.y + rect.h, target.height);
    const r = @min(radius, @min(rect.w, rect.h) * 0.5);
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            if (insideRoundedRect(@floatFromInt(x), @floatFromInt(y), rect, r)) target.blendPixel(x, y, color);
        }
    }
}

fn strokeRoundedRectDirect(target: *Image, rect: window_types.Rect, radius: f32, thickness: f32, color: Color) void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    const t = @max(1.0, thickness);
    fillRoundedRectDirect(target, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t }, radius, color);
    fillRoundedRectDirect(target, .{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t }, radius, color);
    fillRoundedRectDirect(target, .{ .x = rect.x, .y = rect.y, .w = t, .h = rect.h }, radius, color);
    fillRoundedRectDirect(target, .{ .x = rect.x + rect.w - t, .y = rect.y, .w = t, .h = rect.h }, radius, color);
}

fn fillLinearGradientRectDirect(target: *Image, rect: window_types.Rect, start: [2]f32, end: [2]f32, start_color: [4]f32, end_color: [4]f32) void {
    const x0 = clampFloor(rect.x, target.width);
    const y0 = clampFloor(rect.y, target.height);
    const x1 = clampCeil(rect.x + rect.w, target.width);
    const y1 = clampCeil(rect.y + rect.h, target.height);
    const dx = end[0] - start[0];
    const dy = end[1] - start[1];
    const denom = dx * dx + dy * dy;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const px: f32 = @floatFromInt(x);
            const py: f32 = @floatFromInt(y);
            const t = if (denom > 0.000001) std.math.clamp(((px - start[0]) * dx + (py - start[1]) * dy) / denom, 0.0, 1.0) else 0.0;
            target.blendPixel(x, y, lerpCpuColor(start_color, end_color, t));
        }
    }
}

fn fillRadialGradientRectDirect(target: *Image, rect: window_types.Rect, center: [2]f32, radius: f32, inner_color: [4]f32, outer_color: [4]f32) void {
    const x0 = clampFloor(rect.x, target.width);
    const y0 = clampFloor(rect.y, target.height);
    const x1 = clampCeil(rect.x + rect.w, target.width);
    const y1 = clampCeil(rect.y + rect.h, target.height);
    const r = @max(radius, 0.000001);
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - center[0];
            const dy = @as(f32, @floatFromInt(y)) - center[1];
            const t = std.math.clamp(@sqrt(dx * dx + dy * dy) / r, 0.0, 1.0);
            target.blendPixel(x, y, lerpCpuColor(inner_color, outer_color, t));
        }
    }
}

fn strokeLineDirect(target: *Image, a: [2]f32, b: [2]f32, thickness: f32, color: Color) void {
    const steps: u32 = @intFromFloat(@max(1.0, @ceil(@max(@abs(b[0] - a[0]), @abs(b[1] - a[1])))));
    const radius = @max(0.5, thickness * 0.5);
    var i: u32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const x = a[0] + (b[0] - a[0]) * t;
        const y = a[1] + (b[1] - a[1]) * t;
        fillEllipseDirect(target, .{ x, y }, .{ radius, radius }, color);
    }
}

fn fillEllipseDirect(target: *Image, center: [2]f32, radius: [2]f32, color: Color) void {
    const rx = @max(radius[0], 0.5);
    const ry = @max(radius[1], 0.5);
    const x0 = clampFloor(center[0] - rx, target.width);
    const y0 = clampFloor(center[1] - ry, target.height);
    const x1 = clampCeil(center[0] + rx, target.width);
    const y1 = clampCeil(center[1] + ry, target.height);
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const nx = (@as(f32, @floatFromInt(x)) - center[0]) / rx;
            const ny = (@as(f32, @floatFromInt(y)) - center[1]) / ry;
            if (nx * nx + ny * ny <= 1.0) target.blendPixel(x, y, color);
        }
    }
}

fn strokeEllipseDirect(target: *Image, center: [2]f32, radius: [2]f32, thickness: f32, color: Color) void {
    const rx = @max(radius[0], 0.5);
    const ry = @max(radius[1], 0.5);
    const inner_rx = @max(0.0, rx - thickness);
    const inner_ry = @max(0.0, ry - thickness);
    const x0 = clampFloor(center[0] - rx, target.width);
    const y0 = clampFloor(center[1] - ry, target.height);
    const x1 = clampCeil(center[0] + rx, target.width);
    const y1 = clampCeil(center[1] + ry, target.height);
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const outer_x = (fx - center[0]) / rx;
            const outer_y = (fy - center[1]) / ry;
            if (outer_x * outer_x + outer_y * outer_y > 1.0) continue;
            if (inner_rx > 0.0 and inner_ry > 0.0) {
                const inner_x = (fx - center[0]) / inner_rx;
                const inner_y = (fy - center[1]) / inner_ry;
                if (inner_x * inner_x + inner_y * inner_y < 1.0) continue;
            }
            target.blendPixel(x, y, color);
        }
    }
}

fn insideRoundedRect(x: f32, y: f32, rect: window_types.Rect, radius: f32) bool {
    const min_x = @min(rect.x + radius, rect.x + rect.w - radius);
    const max_x = @max(rect.x + radius, rect.x + rect.w - radius);
    const min_y = @min(rect.y + radius, rect.y + rect.h - radius);
    const max_y = @max(rect.y + radius, rect.y + rect.h - radius);
    const cx = std.math.clamp(x, min_x, max_x);
    const cy = std.math.clamp(y, min_y, max_y);
    const dx = x - cx;
    const dy = y - cy;
    return dx * dx + dy * dy <= radius * radius;
}

fn clampFloor(value: f32, limit: u32) u32 {
    if (value <= 0.0) return 0;
    return @min(@as(u32, @intFromFloat(@floor(value))), limit);
}

fn clampCeil(value: f32, limit: u32) u32 {
    if (value <= 0.0) return 0;
    return @min(@as(u32, @intFromFloat(@ceil(value))), limit);
}

fn toCpuColor(color: [4]f32) Color {
    return .{
        .r = channelToByte(color[0]),
        .g = channelToByte(color[1]),
        .b = channelToByte(color[2]),
        .a = channelToByte(color[3]),
    };
}

fn lerpCpuColor(a: [4]f32, b: [4]f32, t: f32) Color {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return toCpuColor(.{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
        a[3] + (b[3] - a[3]) * clamped,
    });
}

fn channelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}

fn backingScaleFactor(ns_window: *anyopaque) f64 {
    return msgSend(ns_window, "backingScaleFactor", .{}, f64);
}

const objc = struct {
    const SEL = ?*opaque {};
    const Class = ?*opaque {};

    extern fn sel_getUid(str: [*:0]const u8) SEL;
    extern fn objc_getClass(name: [*:0]const u8) Class;
    extern fn objc_msgSend() void;
};

fn msgSend(obj: anytype, sel_name: [:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
    const args_meta = @typeInfo(@TypeOf(args)).@"struct".fields;
    const FnType = switch (args_meta.len) {
        0 => *const fn (@TypeOf(obj), objc.SEL) callconv(.c) ReturnType,
        1 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type) callconv(.c) ReturnType,
        2 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type) callconv(.c) ReturnType,
        3 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type) callconv(.c) ReturnType,
        4 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type) callconv(.c) ReturnType,
        5 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type, args_meta[4].type) callconv(.c) ReturnType,
        6 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type, args_meta[4].type, args_meta[5].type) callconv(.c) ReturnType,
        7 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type, args_meta[4].type, args_meta[5].type, args_meta[6].type) callconv(.c) ReturnType,
        8 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type, args_meta[4].type, args_meta[5].type, args_meta[6].type, args_meta[7].type) callconv(.c) ReturnType,
        9 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type, args_meta[4].type, args_meta[5].type, args_meta[6].type, args_meta[7].type, args_meta[8].type) callconv(.c) ReturnType,
        10 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type, args_meta[4].type, args_meta[5].type, args_meta[6].type, args_meta[7].type, args_meta[8].type, args_meta[9].type) callconv(.c) ReturnType,
        11 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type, args_meta[1].type, args_meta[2].type, args_meta[3].type, args_meta[4].type, args_meta[5].type, args_meta[6].type, args_meta[7].type, args_meta[8].type, args_meta[9].type, args_meta[10].type) callconv(.c) ReturnType,
        else => @compileError("unsupported Objective-C argument count"),
    };
    const func = @as(FnType, @ptrCast(&objc.objc_msgSend));
    return @call(.never_inline, func, .{ obj, objc.sel_getUid(sel_name.ptr) } ++ args);
}

test "native provider maps macOS NSWindow without objc dependency" {
    const window_value: *anyopaque = @ptrFromInt(0x1000);
    const AppWindow = struct {
        fn time() f64 {
            return 1.0;
        }

        fn framebuffer(_: *const anyopaque) [2]u32 {
            return .{ 800, 600 };
        }

        fn handle(_: *const anyopaque) NativeHandle {
            return .{ .macos = .{ .nswindow = window_value, .nsview = @ptrFromInt(0x2000), .content_view = @ptrFromInt(0x2000) } };
        }
    };

    var native = NativeWindowProvider{
        .app_window = @ptrFromInt(0x3000),
        .get_time = AppWindow.time,
        .get_framebuffer_size = AppWindow.framebuffer,
        .get_native_handle = AppWindow.handle,
    };
    const webgpu = native.webgpuProvider();
    try std.testing.expectEqual(window_value, webgpu.fn_getCocoaWindow(webgpu.window));
    try std.testing.expectEqual(@as(f64, 1.0), webgpu.fn_getTime());
    try std.testing.expectEqual([2]u32{ 800, 600 }, webgpu.fn_getFramebufferSize(webgpu.window));
}
