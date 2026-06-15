const std = @import("std");
const iris = @import("iris");
const objc = @import("objc");

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
const NSBitmapFormatAlphaNonpremultiplied: u64 = 1 << 1;
const NSEventTypeApplicationDefined: i64 = 15;

var window_should_close = false;

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").target.os.tag != .macos) {
        var buffer: [128]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try out.interface.writeAll("window-cpu-showcase currently uses native macOS Cocoa window glue\n");
        try out.interface.flush();
        return;
    }

    const allocator = init.arena.allocator();
    var image = try iris.Image.init(allocator, width, height, iris.Color.rgba(8, 10, 14, 255));
    defer image.deinit();
    try renderShowcase(allocator, &image);
    try showImageWindow(&image);
}

fn renderShowcase(allocator: std.mem.Allocator, target: *iris.Image) !void {
    var scene2 = iris.Scene2D.init(allocator);
    defer scene2.deinit();
    try scene2.fillRect(.{ .x = 0, .y = 0, .w = @floatFromInt(width / 2), .h = @floatFromInt(height) }, iris.Color.rgba(14, 18, 28, 255));
    try scene2.fillLinearGradientRect(.{ .x = 34, .y = 34, .w = 380, .h = 140 }, .{
        .start = .{ .x = 34, .y = 34 },
        .end = .{ .x = 414, .y = 174 },
        .start_color = iris.Color.rgba(30, 144, 255, 255),
        .end_color = iris.Color.rgba(255, 94, 98, 255),
    });
    try scene2.fillRadialGradientRect(.{ .x = 72, .y = 220, .w = 180, .h = 180 }, .{
        .center = .{ .x = 162, .y = 310 },
        .radius = 90,
        .inner_color = iris.Color.rgba(255, 226, 96, 245),
        .outer_color = iris.Color.rgba(12, 20, 32, 0),
    });
    try scene2.strokeDashedLine(.{ .x = 36, .y = 468 }, .{ .x = 420, .y = 468 }, 8, 22, 14, iris.Color.rgba(120, 240, 210, 255));
    try scene2.fillEllipse(.{ .x = 368, .y = 304 }, .{ .x = 66, .y = 66 }, iris.Color.rgba(140, 90, 255, 220));

    var cpu = iris.CpuRenderer.init(allocator);
    defer cpu.deinit();
    try cpu.render2D(&scene2, target);

    var scene3 = iris.Scene3D.init(allocator);
    defer scene3.deinit();
    try build3DScene(allocator, &scene3);

    var right = try iris.Image.init(allocator, width / 2, height, iris.Color.rgba(6, 8, 13, 255));
    defer right.deinit();
    try cpu.render3D(&scene3, &right);

    blitImage(&right, target, width / 2, 0);
}

fn build3DScene(allocator: std.mem.Allocator, scene: *iris.Scene3D) !void {
    scene.setCamera(iris.scene3d.Camera.perspectiveLookAt(
        .{ .x = 1.6, .y = 1.05, .z = 2.7 },
        .{ .x = 0.0, .y = -0.08, .z = 0.0 },
        .{ .y = 1.0 },
        std.math.pi / 5.0,
        @as(f32, @floatFromInt(width / 2)) / @as(f32, @floatFromInt(height)),
        0.1,
        16.0,
    ));
    scene.setLight(.{ .direction = .{ .x = -0.4, .y = 0.58, .z = 1.0 }, .ambient = 0.22, .diffuse = 0.78 });
    try scene.addLight(iris.scene3d.Light.pointRanged(.{ .x = 1.2, .y = 0.9, .z = 1.2 }, 0.0, 0.55, 3.6));

    const material = try scene.addMaterialHandle(.{
        .ambient = 0.7,
        .diffuse = 0.95,
        .roughness = 0.34,
        .metallic = 0.18,
        .emissive = iris.Color.rgba(0, 20, 48, 255),
        .emissive_strength = 0.1,
    });
    const floor = try scene.addMaterialHandle(.{ .ambient = 0.72, .diffuse = 0.5, .roughness = 0.9 });

    const pixels = try makeTexture(allocator, 16, 16);
    const normals = try makeNormals(allocator, 16, 16);
    const texture = try scene.addTextureHandle(.{ .width = 16, .height = 16, .pixels = pixels });
    const normal_texture = try scene.addTextureHandle(.{ .width = 16, .height = 16, .pixels = normals });

    try addGround(scene, floor);
    try addBox(scene, .{ .x = -0.35, .y = -0.18, .z = 0.0 }, .{ .x = 0.42, .y = 0.48, .z = 0.42 }, material, texture, normal_texture);
    try addPyramid(scene, .{ .x = 0.58, .y = -0.14, .z = -0.24 }, 0.68, material, texture, normal_texture);
}

fn showImageWindow(image: *const iris.Image) !void {
    const NSAutoreleasePool = objc.getClass("NSAutoreleasePool").?;
    const NSApplication = objc.getClass("NSApplication").?;
    const NSWindow = objc.getClass("NSWindow").?;
    const NSImage = objc.getClass("NSImage").?;
    const NSBitmapImageRep = objc.getClass("NSBitmapImageRep").?;
    const NSImageView = objc.getClass("NSImageView").?;
    const NSString = objc.getClass("NSString").?;
    const NSDate = objc.getClass("NSDate").?;
    const NSObject = objc.getClass("NSObject").?;

    const pool = NSAutoreleasePool.msgSend(Object, "alloc", .{});
    _ = pool.msgSend(Object, "init", .{});
    defer pool.msgSend(void, "drain", .{});

    const app = NSApplication.msgSend(Object, "sharedApplication", .{});
    _ = app.msgSend(void, "setActivationPolicy:", .{@as(i32, 0)});
    _ = app.msgSend(void, "activateIgnoringOtherApps:", .{@as(i32, 1)});
    _ = app.msgSend(void, "finishLaunching", .{});

    const rect = NSRect{ .origin = .{ .x = 120, .y = 120 }, .size = .{ .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) } };
    const window = NSWindow.msgSend(Object, "alloc", .{});
    _ = window.msgSend(Object, "initWithContentRect:styleMask:backing:defer:", .{
        rect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered,
        @as(i32, 0),
    });
    const title = NSString.msgSend(Object, "stringWithUTF8String:", .{"Iris 2D + 3D CPU showcase"});
    _ = window.msgSend(void, "setTitle:", .{title});
    const delegate = try createWindowDelegate(NSObject);
    _ = window.msgSend(void, "setDelegate:", .{delegate.value});
    defer delegate.msgSend(void, "release", .{});

    const bitmap = NSBitmapImageRep.msgSend(Object, "alloc", .{});
    _ = bitmap.msgSend(Object, "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null),
        @as(i64, @intCast(image.width)),
        @as(i64, @intCast(image.height)),
        @as(i64, 8),
        @as(i64, 4),
        true,
        false,
        NSString.msgSend(Object, "stringWithUTF8String:", .{"NSCalibratedRGBColorSpace"}),
        @as(u64, NSBitmapFormatAlphaNonpremultiplied),
        @as(i64, @intCast(image.width * 4)),
        @as(i64, 32),
    });
    const data = bitmap.msgSend([*]u8, "bitmapData", .{});
    for (image.pixels, 0..) |pixel, i| {
        const j = i * 4;
        data[j + 0] = pixel.r;
        data[j + 1] = pixel.g;
        data[j + 2] = pixel.b;
        data[j + 3] = pixel.a;
    }

    const ns_image = NSImage.msgSend(Object, "alloc", .{});
    _ = ns_image.msgSend(Object, "initWithSize:", .{NSSize{ .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) }});
    _ = ns_image.msgSend(void, "addRepresentation:", .{bitmap});

    const image_view = NSImageView.msgSend(Object, "alloc", .{});
    _ = image_view.msgSend(Object, "initWithFrame:", .{rect});
    _ = image_view.msgSend(void, "setImage:", .{ns_image});
    _ = image_view.msgSend(void, "setImageScaling:", .{@as(i64, 2)});
    _ = window.msgSend(void, "setContentView:", .{image_view});
    _ = window.msgSend(void, "center", .{});
    _ = window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

    while (!window_should_close) {
        const event = app.msgSend(Object, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            @as(u64, std.math.maxInt(u64)),
            NSDate.msgSend(Object, "distantFuture", .{}).value,
            NSString.msgSend(Object, "stringWithUTF8String:", .{"kCFRunLoopDefaultMode"}).value,
            @as(i32, 1),
        });
        if (@intFromPtr(event.value) != 0) {
            _ = app.msgSend(void, "sendEvent:", .{event.value});
        }
        _ = app.msgSend(void, "updateWindows", .{});
    }
}

var window_delegate_class: ?objc.Class = null;

fn createWindowDelegate(NSObject: objc.Class) !Object {
    const cls = window_delegate_class orelse blk: {
        var class = objc.allocateClassPair(NSObject, "IrisWindowCpuShowcaseDelegate") orelse return error.ObjectiveCClassAllocationFailed;
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

fn blitImage(src: *const iris.Image, dst: *iris.Image, dst_x: u32, dst_y: u32) void {
    var y: u32 = 0;
    while (y < src.height) : (y += 1) {
        var x: u32 = 0;
        while (x < src.width) : (x += 1) {
            dst.writePixel(dst_x + x, dst_y + y, src.pixel(x, y).?);
        }
    }
}

fn makeTexture(allocator: std.mem.Allocator, w: u32, h: u32) ![]iris.Color {
    const pixels = try allocator.alloc(iris.Color, w * h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const seam = x % 4 == 0 or y % 4 == 0;
            pixels[y * w + x] = if (seam) iris.Color.rgba(22, 34, 56, 255) else iris.Color.rgba(58, 146, 230, 255);
        }
    }
    return pixels;
}

fn makeNormals(allocator: std.mem.Allocator, w: u32, h: u32) ![]iris.Color {
    const pixels = try allocator.alloc(iris.Color, w * h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            pixels[y * w + x] = iris.Color.rgba(if (x % 6 < 3) 158 else 104, if (y % 6 < 3) 150 else 106, 236, 255);
        }
    }
    return pixels;
}

fn addGround(scene: *iris.Scene3D, material: iris.scene3d.MaterialHandle) !void {
    const normal = iris.math.Vec3{ .y = 1.0 };
    const y: f32 = -0.72;
    try scene.addTriangle(.{ .positions = .{ .{ .x = -1.8, .y = y, .z = -1.4 }, .{ .x = 1.8, .y = y, .z = -1.4 }, .{ .x = 1.8, .y = y, .z = 1.2 } }, .color = iris.Color.rgba(42, 48, 62, 255), .normals = .{ normal, normal, normal }, .material_handle = material });
    try scene.addTriangle(.{ .positions = .{ .{ .x = -1.8, .y = y, .z = -1.4 }, .{ .x = 1.8, .y = y, .z = 1.2 }, .{ .x = -1.8, .y = y, .z = 1.2 } }, .color = iris.Color.rgba(34, 40, 54, 255), .normals = .{ normal, normal, normal }, .material_handle = material });
}

fn addPyramid(scene: *iris.Scene3D, center: iris.math.Vec3, size: f32, material: iris.scene3d.MaterialHandle, texture: iris.scene3d.TextureHandle, normal_texture: iris.scene3d.TextureHandle) !void {
    const h = size * 1.1;
    const s = size * 0.48;
    const y0 = center.y - 0.42;
    const apex = iris.math.Vec3{ .x = center.x, .y = center.y + h * 0.55, .z = center.z };
    const p0 = iris.math.Vec3{ .x = center.x - s, .y = y0, .z = center.z - s };
    const p1 = iris.math.Vec3{ .x = center.x + s, .y = y0, .z = center.z - s };
    const p2 = iris.math.Vec3{ .x = center.x + s, .y = y0, .z = center.z + s };
    const p3 = iris.math.Vec3{ .x = center.x - s, .y = y0, .z = center.z + s };
    try addTri(scene, .{ p0, p1, apex }, material, texture, normal_texture);
    try addTri(scene, .{ p1, p2, apex }, material, texture, normal_texture);
    try addTri(scene, .{ p2, p3, apex }, material, texture, normal_texture);
    try addTri(scene, .{ p3, p0, apex }, material, texture, normal_texture);
}

fn addBox(scene: *iris.Scene3D, center: iris.math.Vec3, half: iris.math.Vec3, material: iris.scene3d.MaterialHandle, texture: iris.scene3d.TextureHandle, normal_texture: iris.scene3d.TextureHandle) !void {
    const x0 = center.x - half.x;
    const x1 = center.x + half.x;
    const y0 = center.y - half.y;
    const y1 = center.y + half.y;
    const z0 = center.z - half.z;
    const z1 = center.z + half.z;
    try addQuad(scene, .{ .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 } }, material, texture, normal_texture);
    try addQuad(scene, .{ .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 } }, material, texture, normal_texture);
    try addQuad(scene, .{ .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z1 } }, material, texture, normal_texture);
    try addQuad(scene, .{ .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z0 } }, material, texture, normal_texture);
}

fn addQuad(scene: *iris.Scene3D, positions: [4]iris.math.Vec3, material: iris.scene3d.MaterialHandle, texture: iris.scene3d.TextureHandle, normal_texture: iris.scene3d.TextureHandle) !void {
    try addTri(scene, .{ positions[0], positions[1], positions[2] }, material, texture, normal_texture);
    try addTri(scene, .{ positions[0], positions[2], positions[3] }, material, texture, normal_texture);
}

fn addTri(scene: *iris.Scene3D, positions: [3]iris.math.Vec3, material: iris.scene3d.MaterialHandle, texture: iris.scene3d.TextureHandle, normal_texture: iris.scene3d.TextureHandle) !void {
    const normal = positions[1].sub(positions[0]).cross(positions[2].sub(positions[0])).normalize();
    try scene.addTriangle(.{
        .positions = positions,
        .color = .white,
        .uvs = .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } },
        .texture_handle = texture,
        .normal_texture_handle = normal_texture,
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
}
