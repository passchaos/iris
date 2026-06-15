const std = @import("std");
const iris = @import("iris");
const objc = @import("objc");
const zgpu = @import("zgpu");
const skeleton = @import("webgpu_window_skeleton.zig");

const Object = objc.Object;

const width = 960;
const height = 540;

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
const NSWindowStyleMaskTitled: u64 = 1 << 0;
const NSWindowStyleMaskClosable: u64 = 1 << 1;
const NSWindowStyleMaskMiniaturizable: u64 = 1 << 2;
const NSWindowStyleMaskResizable: u64 = 1 << 3;

var window_should_close = false;
const CocoaWindow = struct {
    app: Object,
    window: Object,
    delegate: Object,
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
        try out.interface.writeAll("window-webgpu-showcase currently uses native macOS Cocoa window glue\n");
        try out.interface.flush();
        return;
    }

    const allocator = init.arena.allocator();
    const max_frames = try parseMaxFrames(init);
    var cocoa = try createWindow();
    defer cocoa.pool.msgSend(void, "drain", .{});
    defer cocoa.delegate.msgSend(void, "release", .{});

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

    var rendered_frames: usize = 0;
    while (!window_should_close) {
        try pollEvents(cocoa.app);
        if (!gctx.canRender()) continue;
        try skeleton.runWithContext(allocator, gctx);
        rendered_frames += 1;
        if (max_frames) |limit| {
            if (rendered_frames >= limit) window_should_close = true;
        }
    }
}

fn parseMaxFrames(init: std.process.Init) !?usize {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse return error.MissingFrameCount;
            return try std.fmt.parseInt(usize, value, 10);
        }
    }
    return null;
}

fn createWindow() !CocoaWindow {
    const NSAutoreleasePool = objc.getClass("NSAutoreleasePool").?;
    const NSApplication = objc.getClass("NSApplication").?;
    const NSWindow = objc.getClass("NSWindow").?;
    const NSString = objc.getClass("NSString").?;
    const NSObject = objc.getClass("NSObject").?;

    const pool = NSAutoreleasePool.msgSend(Object, "alloc", .{});
    _ = pool.msgSend(Object, "init", .{});

    const app = NSApplication.msgSend(Object, "sharedApplication", .{});
    _ = app.msgSend(void, "setActivationPolicy:", .{@as(i32, 0)});
    _ = app.msgSend(void, "activateIgnoringOtherApps:", .{@as(i32, 1)});
    _ = app.msgSend(void, "finishLaunching", .{});

    const rect = NSRect{ .origin = .{ .x = 120, .y = 120 }, .size = .{ .width = width, .height = height } };
    const window = NSWindow.msgSend(Object, "alloc", .{});
    _ = window.msgSend(Object, "initWithContentRect:styleMask:backing:defer:", .{
        rect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered,
        @as(i32, 0),
    });
    const title = NSString.msgSend(Object, "stringWithUTF8String:", .{"Iris WebGPU showcase"});
    _ = window.msgSend(void, "setTitle:", .{title});
    const delegate = try createWindowDelegate(NSObject);
    _ = window.msgSend(void, "setDelegate:", .{delegate.value});
    _ = window.msgSend(void, "center", .{});
    _ = window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

    return .{
        .app = app,
        .window = window,
        .delegate = delegate,
        .pool = pool,
    };
}

fn pollEvents(app: Object) !void {
    const NSString = objc.getClass("NSString").?;
    const NSDate = objc.getClass("NSDate").?;
    const event = app.msgSend(Object, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
        @as(u64, std.math.maxInt(u64)),
        NSDate.msgSend(Object, "distantPast", .{}).value,
        NSString.msgSend(Object, "stringWithUTF8String:", .{"kCFRunLoopDefaultMode"}).value,
        @as(i32, 1),
    });
    if (@intFromPtr(event.value) != 0) {
        _ = app.msgSend(void, "sendEvent:", .{event.value});
    }
    _ = app.msgSend(void, "updateWindows", .{});
}

var window_delegate_class: ?objc.Class = null;

fn createWindowDelegate(NSObject: objc.Class) !Object {
    const cls = window_delegate_class orelse blk: {
        var class = objc.allocateClassPair(NSObject, "IrisWindowWebGpuShowcaseDelegate") orelse return error.ObjectiveCClassAllocationFailed;
        _ = class.addMethod("windowWillClose:", windowWillClose);
        objc.registerClassPair(class);
        window_delegate_class = class;
        break :blk class;
    };
    const delegate = cls.msgSend(Object, "alloc", .{});
    return delegate.msgSend(Object, "init", .{});
}

fn windowWillClose(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    window_should_close = true;
}
