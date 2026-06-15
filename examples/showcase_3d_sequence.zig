const std = @import("std");
const iris = @import("iris");

const width = 640;
const height = 400;
const frame_count = 6;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.Io.Dir.cwd().createDir(init.io, "zig-out", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var renderer = iris.CpuRenderer.init(allocator);
    defer renderer.deinit();

    var frame: usize = 0;
    while (frame < frame_count) : (frame += 1) {
        var image = try iris.Image.init(allocator, width, height, iris.Color.rgba(6, 8, 13, 255));
        defer image.deinit();

        var scene = iris.Scene3D.init(allocator);
        defer scene.deinit();
        try buildFrame(allocator, &scene, frame);
        try renderer.render3D(&scene, &image);

        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "zig-out/showcase_3d_sequence_{d:0>2}.ppm", .{frame});
        try writePpm(init.io, path, &image);
        try printFrame(init.io, path, image.countNonTransparentPixels());
    }
}

fn buildFrame(allocator: std.mem.Allocator, scene: *iris.Scene3D, frame: usize) !void {
    const t = @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(frame_count));
    const orbit = t * std.math.tau;
    scene.setCamera(iris.scene3d.Camera.perspectiveLookAt(
        .{ .x = 2.8 * @cos(orbit * 0.45), .y = 1.55, .z = 3.2 + 0.45 * @sin(orbit * 0.5) },
        .{ .x = 0.0, .y = -0.1, .z = 0.0 },
        .{ .y = 1.0 },
        std.math.pi / 5.0,
        @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)),
        0.1,
        24.0,
    ));
    scene.setLight(.{ .direction = .{ .x = -0.45, .y = 0.62, .z = 1.0 }, .ambient = 0.22, .diffuse = 0.72 });
    try scene.addLight(iris.scene3d.Light.pointRanged(.{ .x = 1.4 * @cos(orbit), .y = 1.05, .z = 1.3 * @sin(orbit) }, 0.02, 0.82, 4.0));
    try scene.addLight(iris.scene3d.Light.spot(.{ .x = -1.7, .y = 1.4, .z = 1.6 }, .{ .x = 1.0, .y = -0.35, .z = -1.0 }, 0.0, 0.42, std.math.pi / 14.0, std.math.pi / 4.5, 4.5));

    const material_floor = try scene.addMaterialHandle(.{
        .ambient = 0.72,
        .diffuse = 0.65,
        .roughness = 0.9,
        .emissive = iris.Color.rgba(8, 16, 26, 255),
        .emissive_strength = 0.08,
    });
    const material_box = try scene.addMaterialHandle(.{
        .ambient = 0.72,
        .diffuse = 0.95,
        .roughness = 0.28,
        .metallic = 0.18,
        .emissive = iris.Color.rgba(0, 16, 36, 255),
        .emissive_strength = 0.12,
    });
    const material_hot = try scene.addMaterialHandle(.{
        .ambient = 0.65,
        .diffuse = 0.9,
        .roughness = 0.46,
        .emissive = iris.Color.rgba(64, 24, 0, 255),
        .emissive_strength = 0.18,
    });
    const material_grid = try scene.addMaterialHandle(.{
        .ambient = 0.9,
        .diffuse = 0.35,
        .roughness = 0.8,
        .emissive = iris.Color.rgba(12, 82, 130, 255),
        .emissive_strength = 0.32,
    });

    const panel_pixels = try makeTexture(allocator, 24, 24, .cool);
    const hot_pixels = try makeTexture(allocator, 24, 24, .warm);
    const normal_pixels = try makeNormals(allocator, 24, 24);
    const panel = try scene.addTextureHandle(.{ .width = 24, .height = 24, .pixels = panel_pixels });
    const hot = try scene.addTextureHandle(.{ .width = 24, .height = 24, .pixels = hot_pixels });
    const normals = try scene.addTextureHandle(.{ .width = 24, .height = 24, .pixels = normal_pixels });

    try addGround(scene, material_floor);
    try addGrid(scene, material_grid);

    var i: i32 = -3;
    while (i <= 3) : (i += 1) {
        const fi = @as(f32, @floatFromInt(i));
        const phase = orbit + fi * 0.8;
        const center = iris.math.Vec3{
            .x = fi * 0.42,
            .y = -0.46 + 0.18 * @sin(phase),
            .z = -0.12 + 0.18 * @cos(phase * 0.7),
        };
        const half = iris.math.Vec3{ .x = 0.18, .y = 0.18 + 0.05 * @cos(phase), .z = 0.18 };
        const transform = iris.math.Mat4.translation(center)
            .mul(iris.math.Mat4.rotationY(phase))
            .mul(iris.math.Mat4.rotationX(phase * 0.33));
        try addBox(scene, transform, half, if (@mod(i, 2) == 0) material_box else material_hot, if (@mod(i, 2) == 0) panel else hot, normals);
    }

    try addPyramid(scene, .{ .x = 0.0, .y = 0.08 + 0.1 * @sin(orbit), .z = -0.95 }, 0.62, material_hot, hot, normals, orbit);
}

const Palette = enum { cool, warm };

fn makeTexture(allocator: std.mem.Allocator, w: u32, h: u32, palette: Palette) ![]iris.Color {
    const pixels = try allocator.alloc(iris.Color, w * h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const seam = x % 6 == 0 or y % 6 == 0;
            const stripe = (x + y) % 7 == 0;
            pixels[y * w + x] = switch (palette) {
                .cool => if (seam) iris.Color.rgba(20, 32, 52, 255) else if (stripe) iris.Color.rgba(72, 210, 230, 255) else iris.Color.rgba(52, 118, 220, 255),
                .warm => if (seam) iris.Color.rgba(68, 26, 20, 255) else if (stripe) iris.Color.rgba(255, 222, 94, 255) else iris.Color.rgba(226, 88, 54, 255),
            };
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
            pixels[y * w + x] = iris.Color.rgba(if (x % 8 < 4) 164 else 96, if (y % 8 < 4) 154 else 102, 236, 255);
        }
    }
    return pixels;
}

fn addPyramid(
    scene: *iris.Scene3D,
    center: iris.math.Vec3,
    size: f32,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
    rotation: f32,
) !void {
    const h = size * 1.15;
    const s = size * 0.62;
    const transform = iris.math.Mat4.translation(center).mul(iris.math.Mat4.rotationY(rotation));
    const apex = transform.transformPoint(.{ .y = h * 0.55 });
    const p0 = transform.transformPoint(.{ .x = -s, .y = -0.55, .z = -s });
    const p1 = transform.transformPoint(.{ .x = s, .y = -0.55, .z = -s });
    const p2 = transform.transformPoint(.{ .x = s, .y = -0.55, .z = s });
    const p3 = transform.transformPoint(.{ .x = -s, .y = -0.55, .z = s });

    try addTri(scene, .{ p0, p1, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
    try addTri(scene, .{ p1, p2, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
    try addTri(scene, .{ p2, p3, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
    try addTri(scene, .{ p3, p0, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
}

fn addBox(
    scene: *iris.Scene3D,
    transform: iris.math.Mat4,
    half: iris.math.Vec3,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
    const x0 = -half.x;
    const x1 = half.x;
    const y0 = -half.y;
    const y1 = half.y;
    const z0 = -half.z;
    const z1 = half.z;

    try addQuad(scene, transform, .{ .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 } }, material, texture, normal_texture);
    try addQuad(scene, transform, .{ .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 } }, material, texture, normal_texture);
    try addQuad(scene, transform, .{ .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z1 } }, material, texture, normal_texture);
    try addQuad(scene, transform, .{ .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z0 } }, material, texture, normal_texture);
    try addQuad(scene, transform, .{ .{ .x = x0, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 } }, material, texture, normal_texture);
    try addQuad(scene, transform, .{ .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z1 } }, material, texture, normal_texture);
}

fn addQuad(
    scene: *iris.Scene3D,
    transform: iris.math.Mat4,
    positions: [4]iris.math.Vec3,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
    const p = [4]iris.math.Vec3{
        transform.transformPoint(positions[0]),
        transform.transformPoint(positions[1]),
        transform.transformPoint(positions[2]),
        transform.transformPoint(positions[3]),
    };
    const uvs = [4]iris.math.Vec2{ .{}, .{ .x = 1.0 }, .{ .x = 1.0, .y = 1.0 }, .{ .y = 1.0 } };
    try addTri(scene, .{ p[0], p[1], p[2] }, .{ uvs[0], uvs[1], uvs[2] }, material, texture, normal_texture);
    try addTri(scene, .{ p[0], p[2], p[3] }, .{ uvs[0], uvs[2], uvs[3] }, material, texture, normal_texture);
}

fn addTri(
    scene: *iris.Scene3D,
    positions: [3]iris.math.Vec3,
    uvs: [3]iris.math.Vec2,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
    const normal = positions[1].sub(positions[0]).cross(positions[2].sub(positions[0])).normalize();
    try scene.addTriangle(.{
        .positions = positions,
        .color = .white,
        .uvs = uvs,
        .texture_handle = texture,
        .normal_texture_handle = normal_texture,
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
}

fn addGround(scene: *iris.Scene3D, material: iris.scene3d.MaterialHandle) !void {
    const normal = iris.math.Vec3{ .y = 1.0 };
    const y: f32 = -0.78;
    const x0: f32 = -2.6;
    const x1: f32 = 2.6;
    const z0: f32 = -2.1;
    const z1: f32 = 1.7;
    try scene.addTriangle(.{ .positions = .{ .{ .x = x0, .y = y, .z = z0 }, .{ .x = x1, .y = y, .z = z0 }, .{ .x = x1, .y = y, .z = z1 } }, .color = iris.Color.rgba(42, 48, 62, 255), .normals = .{ normal, normal, normal }, .material_handle = material });
    try scene.addTriangle(.{ .positions = .{ .{ .x = x0, .y = y, .z = z0 }, .{ .x = x1, .y = y, .z = z1 }, .{ .x = x0, .y = y, .z = z1 } }, .color = iris.Color.rgba(32, 38, 52, 255), .normals = .{ normal, normal, normal }, .material_handle = material });
}

fn addGrid(scene: *iris.Scene3D, material: iris.scene3d.MaterialHandle) !void {
    const y: f32 = -0.762;
    var i: i32 = -6;
    while (i <= 6) : (i += 1) {
        const p = @as(f32, @floatFromInt(i)) * 0.35;
        try addThinRect(scene, .{ .x = -2.45, .y = y, .z = p }, .{ .x = 2.45, .y = y, .z = p }, 0.008, material);
        try addThinRect(scene, .{ .x = p, .y = y, .z = -1.95 }, .{ .x = p, .y = y, .z = 1.55 }, 0.008, material);
    }
}

fn addThinRect(scene: *iris.Scene3D, a: iris.math.Vec3, b: iris.math.Vec3, half_width: f32, material: iris.scene3d.MaterialHandle) !void {
    const dir = b.sub(a).normalize();
    const side = iris.math.Vec3{ .x = -dir.z * half_width, .z = dir.x * half_width };
    const normal = iris.math.Vec3{ .y = 1.0 };
    try scene.addTriangle(.{ .positions = .{ a.add(side), b.add(side), b.sub(side) }, .color = iris.Color.rgba(26, 150, 230, 190), .normals = .{ normal, normal, normal }, .material_handle = material });
    try scene.addTriangle(.{ .positions = .{ a.add(side), b.sub(side), a.sub(side) }, .color = iris.Color.rgba(26, 150, 230, 190), .normals = .{ normal, normal, normal }, .material_handle = material });
}

fn writePpm(io: std.Io, path: []const u8, image: *const iris.Image) !void {
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

fn printFrame(io: std.Io, path: []const u8, pixels: usize) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print("wrote {s} ({d} non-transparent pixels)\n", .{ path, pixels });
    try out.interface.flush();
}
