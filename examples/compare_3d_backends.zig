const std = @import("std");
const iris = @import("iris");

const width = 320;
const height = 220;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var scene = iris.Scene3D.init(allocator);
    defer scene.deinit();
    try buildScene(allocator, &scene);

    var cpu_image = try iris.Image.init(allocator, width, height, iris.Color.rgba(5, 7, 11, 255));
    defer cpu_image.deinit();
    var software_image = try iris.Image.init(allocator, width, height, iris.Color.rgba(5, 7, 11, 255));
    defer software_image.deinit();

    var cpu_renderer = iris.CpuRenderer.init(allocator);
    defer cpu_renderer.deinit();
    try cpu_renderer.render3D(&scene, &cpu_image);

    var batch = iris.GpuBatch{};
    defer batch.deinit(allocator);
    try batch.build3DFromScene(allocator, &scene);
    var backend = iris.SoftwareBackend.initWithAllocator(allocator, &software_image);
    defer backend.deinit();
    try backend.backend().submit(.{
        .kind = .render_3d,
        .primitive_count = scene.triangles.items.len,
        .target_width = software_image.width,
        .target_height = software_image.height,
    }, &batch);

    const comparison = try cpu_image.compare(&software_image, 0);
    try printComparison(init.io, comparison);
}

pub fn buildScene(allocator: std.mem.Allocator, scene: *iris.Scene3D) !void {
    scene.setCamera(iris.scene3d.Camera.perspectiveLookAt(
        .{ .x = 1.7, .y = 1.05, .z = 2.8 },
        .{ .x = 0.0, .y = -0.08, .z = 0.0 },
        .{ .y = 1.0 },
        std.math.pi / 5.2,
        @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)),
        0.1,
        12.0,
    ));
    scene.setLight(.{ .direction = .{ .x = -0.35, .y = 0.55, .z = 1.0 }, .ambient = 0.2, .diffuse = 0.82 });
    try scene.addLight(iris.scene3d.Light.pointRanged(.{ .x = 1.1, .y = 0.85, .z = 1.2 }, 0.0, 0.55, 3.5));

    const material = try scene.addMaterialHandle(.{
        .ambient = 0.72,
        .diffuse = 0.92,
        .roughness = 0.34,
        .metallic = 0.14,
        .emissive = iris.Color.rgba(0, 18, 48, 255),
        .emissive_strength = 0.08,
    });
    const floor_material = try scene.addMaterialHandle(.{
        .ambient = 0.75,
        .diffuse = 0.55,
        .roughness = 0.88,
    });

    const pixels = try makeTexture(allocator, 16, 16);
    const normals = try makeNormals(allocator, 16, 16);
    const texture = try scene.addTextureHandle(.{ .width = 16, .height = 16, .pixels = pixels });
    const normal_texture = try scene.addTextureHandle(.{ .width = 16, .height = 16, .pixels = normals });

    try addGround(scene, floor_material);
    try addBox(scene, .{ .x = -0.38, .y = -0.18, .z = 0.0 }, .{ .x = 0.42, .y = 0.48, .z = 0.42 }, material, texture, normal_texture);
    try addPyramid(scene, .{ .x = 0.58, .y = -0.14, .z = -0.22 }, 0.68, material, texture, normal_texture);
}

fn makeTexture(allocator: std.mem.Allocator, w: u32, h: u32) ![]iris.Color {
    const pixels = try allocator.alloc(iris.Color, w * h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const seam = x % 4 == 0 or y % 4 == 0;
            pixels[y * w + x] = if (seam) iris.Color.rgba(24, 36, 58, 255) else iris.Color.rgba(62, 150, 232, 255);
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
    const y: f32 = -0.7;
    try scene.addTriangle(.{
        .positions = .{ .{ .x = -1.8, .y = y, .z = -1.4 }, .{ .x = 1.8, .y = y, .z = -1.4 }, .{ .x = 1.8, .y = y, .z = 1.2 } },
        .color = iris.Color.rgba(44, 48, 62, 255),
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
    try scene.addTriangle(.{
        .positions = .{ .{ .x = -1.8, .y = y, .z = -1.4 }, .{ .x = 1.8, .y = y, .z = 1.2 }, .{ .x = -1.8, .y = y, .z = 1.2 } },
        .color = iris.Color.rgba(34, 40, 54, 255),
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
}

fn addPyramid(
    scene: *iris.Scene3D,
    center: iris.math.Vec3,
    size: f32,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
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

fn addBox(
    scene: *iris.Scene3D,
    center: iris.math.Vec3,
    half: iris.math.Vec3,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
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
    try addQuad(scene, .{ .{ .x = x0, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 } }, material, texture, normal_texture);
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

fn printComparison(io: std.Io, comparison: iris.ImageComparison) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print(
        "compare-3d-backends {d}x{d}: mismatched={d} max_channel_error={d} mean_absolute_error={d:.3}\n",
        .{ comparison.width, comparison.height, comparison.mismatched_pixels, comparison.max_channel_error, comparison.mean_absolute_error },
    );
    try out.interface.flush();
}
