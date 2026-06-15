const std = @import("std");
const iris = @import("iris");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var image = try iris.Image.init(allocator, 1280, 800, iris.Color.rgba(7, 9, 14, 255));
    defer image.deinit();

    var scene = iris.Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCamera(iris.scene3d.Camera.perspectiveLookAt(
        .{ .x = 2.45, .y = 1.55, .z = 3.55 },
        .{ .x = 0.0, .y = -0.12, .z = -0.08 },
        .{ .y = 1.0 },
        std.math.pi / 5.1,
        @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(image.height)),
        0.1,
        20.0,
    ));
    scene.setLight(.{ .direction = .{ .x = -0.42, .y = 0.58, .z = 1.0 }, .ambient = 0.26, .diffuse = 0.82 });
    try scene.addLight(iris.scene3d.Light.pointRanged(.{ .x = 1.45, .y = 1.1, .z = 1.35 }, 0.02, 0.72, 4.0));
    try scene.addLight(iris.scene3d.Light.spot(.{ .x = -1.75, .y = 1.35, .z = 1.85 }, .{ .x = 0.95, .y = -0.35, .z = -1.0 }, 0.02, 0.5, std.math.pi / 13.0, std.math.pi / 4.5, 4.5));

    const material_pbr = try scene.addMaterialHandle(.{
        .ambient = 0.76,
        .diffuse = 0.95,
        .roughness = 0.22,
        .metallic = 0.45,
        .emissive = iris.Color.rgba(12, 40, 90, 255),
        .emissive_strength = 0.1,
    });
    const material_floor = try scene.addMaterialHandle(.{
        .ambient = 0.65,
        .diffuse = 0.78,
        .roughness = 0.88,
        .emissive = iris.Color.rgba(10, 18, 30, 255),
        .emissive_strength = 0.08,
    });
    const material_cube = try scene.addMaterialHandle(.{
        .ambient = 0.7,
        .diffuse = 0.92,
        .roughness = 0.32,
        .metallic = 0.16,
        .emissive = iris.Color.rgba(0, 12, 36, 255),
        .emissive_strength = 0.08,
    });
    const material_grid = try scene.addMaterialHandle(.{
        .ambient = 0.9,
        .diffuse = 0.38,
        .roughness = 0.8,
        .emissive = iris.Color.rgba(20, 70, 120, 255),
        .emissive_strength = 0.3,
    });
    const material_warm = try scene.addMaterialHandle(.{
        .ambient = 0.74,
        .diffuse = 0.9,
        .roughness = 0.58,
        .metallic = 0.0,
        .emissive = iris.Color.rgba(55, 16, 0, 255),
        .emissive_strength = 0.08,
    });
    const material_cool = try scene.addMaterialHandle(.{
        .ambient = 0.72,
        .diffuse = 0.9,
        .roughness = 0.4,
        .metallic = 0.08,
        .emissive = iris.Color.rgba(0, 28, 64, 255),
        .emissive_strength = 0.16,
    });
    const albedo_pixels = try makePanelTexture(allocator, 32, 32);
    const normal_pixels = try makeNormalTexture(allocator, 32, 32);
    const warm_pixels = try makeWarmTexture(allocator, 24, 24);
    const albedo = try scene.addTextureHandle(.{ .width = 32, .height = 32, .pixels = albedo_pixels });
    const normals = try scene.addTextureHandle(.{ .width = 32, .height = 32, .pixels = normal_pixels });
    const warm_albedo = try scene.addTextureHandle(.{ .width = 24, .height = 24, .pixels = warm_pixels });

    try addGround(&scene, material_floor);
    try addGrid(&scene);
    try addAxes(&scene);
    try addBackPanel(&scene, material_cool);
    try addPyramid(&scene, .{ .x = -0.68, .y = -0.03, .z = -0.18 }, 1.25, material_pbr, albedo, normals);
    try addBox(&scene, .{ .x = 0.82, .y = -0.08, .z = 0.22 }, .{ .x = 0.54, .y = 0.66, .z = 0.54 }, material_cube, albedo, normals);
    try addSphere(&scene, .{ .x = 0.05, .y = -0.3, .z = -0.92 }, 0.42, 26, 14, material_warm, warm_albedo, normals);
    try addColumn(&scene, .{ .x = -1.38, .y = -0.42, .z = 0.64 }, 0.24, 0.82, 24, material_cool, albedo, normals);
    try addColumn(&scene, .{ .x = 1.45, .y = -0.47, .z = -0.5 }, 0.18, 0.54, 20, material_grid, warm_albedo, normals);
    try addPointCloud(&scene, allocator);
    try addVolumePlaceholder(&scene);
    try addDebugBoxes(&scene);

    var renderer = iris.CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render3D(&scene, &image);

    std.Io.Dir.cwd().createDir(init.io, "zig-out", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writePpm(init.io, "zig-out/showcase_3d.ppm", &image);
    try printDone(init.io, "zig-out/showcase_3d.ppm", image.countNonTransparentPixels());
}

fn makePanelTexture(allocator: std.mem.Allocator, width: u32, height: u32) ![]iris.Color {
    const pixels = try allocator.alloc(iris.Color, width * height);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const panel = ((x / 4) + (y / 4)) % 2;
            const seam = x % 8 == 0 or y % 8 == 0;
            const idx = y * width + x;
            pixels[idx] = if (seam)
                iris.Color.rgba(24, 36, 56, 255)
            else if (panel == 0)
                iris.Color.rgba(228, 66, 58, 255)
            else
                iris.Color.rgba(46, 132, 232, 255);
        }
    }
    return pixels;
}

fn makeWarmTexture(allocator: std.mem.Allocator, width: u32, height: u32) ![]iris.Color {
    const pixels = try allocator.alloc(iris.Color, width * height);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const ring = (x + y) % 6 == 0;
            const stripe = x % 5 == 0;
            const idx = y * width + x;
            pixels[idx] = if (ring)
                iris.Color.rgba(255, 218, 94, 255)
            else if (stripe)
                iris.Color.rgba(174, 58, 42, 255)
            else
                iris.Color.rgba(244, 136, 66, 255);
        }
    }
    return pixels;
}

fn makeNormalTexture(allocator: std.mem.Allocator, width: u32, height: u32) ![]iris.Color {
    const pixels = try allocator.alloc(iris.Color, width * height);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const ridge_x: u8 = if (x % 8 < 4) 158 else 98;
            const ridge_y: u8 = if (y % 8 < 4) 150 else 106;
            pixels[y * width + x] = iris.Color.rgba(ridge_x, ridge_y, 236, 255);
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
) !void {
    const h = size * 1.15;
    const s = size * 0.62;
    const y0 = center.y - 0.55;
    const apex = iris.math.Vec3{ .x = center.x, .y = center.y + h * 0.55, .z = center.z };
    const p0 = iris.math.Vec3{ .x = center.x - s, .y = y0, .z = center.z - s };
    const p1 = iris.math.Vec3{ .x = center.x + s, .y = y0, .z = center.z - s };
    const p2 = iris.math.Vec3{ .x = center.x + s, .y = y0, .z = center.z + s };
    const p3 = iris.math.Vec3{ .x = center.x - s, .y = y0, .z = center.z + s };

    try addTri(scene, .{ p0, p1, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
    try addTri(scene, .{ p1, p2, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
    try addTri(scene, .{ p2, p3, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
    try addTri(scene, .{ p3, p0, apex }, .{ .{}, .{ .x = 1.0 }, .{ .x = 0.5, .y = 1.0 } }, material, texture, normal_texture);
}

fn addSphere(
    scene: *iris.Scene3D,
    center: iris.math.Vec3,
    radius: f32,
    slices: u32,
    stacks: u32,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
    var stack: u32 = 0;
    while (stack < stacks) : (stack += 1) {
        const v0 = @as(f32, @floatFromInt(stack)) / @as(f32, @floatFromInt(stacks));
        const v1 = @as(f32, @floatFromInt(stack + 1)) / @as(f32, @floatFromInt(stacks));
        const phi0 = -std.math.pi / 2.0 + v0 * std.math.pi;
        const phi1 = -std.math.pi / 2.0 + v1 * std.math.pi;
        var slice: u32 = 0;
        while (slice < slices) : (slice += 1) {
            const uv0 = @as(f32, @floatFromInt(slice)) / @as(f32, @floatFromInt(slices));
            const uv1 = @as(f32, @floatFromInt(slice + 1)) / @as(f32, @floatFromInt(slices));
            const p00 = spherePoint(center, radius, uv0, phi0);
            const p10 = spherePoint(center, radius, uv1, phi0);
            const p11 = spherePoint(center, radius, uv1, phi1);
            const p01 = spherePoint(center, radius, uv0, phi1);
            try addTri(scene, .{ p00, p10, p11 }, .{ .{ .x = uv0, .y = v0 }, .{ .x = uv1, .y = v0 }, .{ .x = uv1, .y = v1 } }, material, texture, normal_texture);
            try addTri(scene, .{ p00, p11, p01 }, .{ .{ .x = uv0, .y = v0 }, .{ .x = uv1, .y = v1 }, .{ .x = uv0, .y = v1 } }, material, texture, normal_texture);
        }
    }
}

fn spherePoint(center: iris.math.Vec3, radius: f32, u: f32, phi: f32) iris.math.Vec3 {
    const theta = u * std.math.tau;
    const cp = @cos(phi);
    return .{
        .x = center.x + radius * cp * @cos(theta),
        .y = center.y + radius * @sin(phi),
        .z = center.z + radius * cp * @sin(theta),
    };
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
    const y: f32 = -0.78;
    const z0: f32 = -2.35;
    const z1: f32 = 1.9;
    const x0: f32 = -2.65;
    const x1: f32 = 2.65;
    const normal = iris.math.Vec3{ .y = 1.0 };
    try scene.addTriangle(.{
        .positions = .{ .{ .x = x0, .y = y, .z = z0 }, .{ .x = x1, .y = y, .z = z0 }, .{ .x = x1, .y = y, .z = z1 } },
        .color = iris.Color.rgba(48, 52, 66, 255),
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
    try scene.addTriangle(.{
        .positions = .{ .{ .x = x0, .y = y, .z = z0 }, .{ .x = x1, .y = y, .z = z1 }, .{ .x = x0, .y = y, .z = z1 } },
        .color = iris.Color.rgba(38, 43, 58, 255),
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
}

fn addBackPanel(scene: *iris.Scene3D, material: iris.scene3d.MaterialHandle) !void {
    const normal = iris.math.Vec3{ .z = 1.0 };
    const z: f32 = -1.9;
    const y0: f32 = -0.78;
    const y1: f32 = 1.25;
    const x0: f32 = -2.65;
    const x1: f32 = 2.65;
    try scene.addTriangle(.{
        .positions = .{ .{ .x = x0, .y = y0, .z = z }, .{ .x = x1, .y = y0, .z = z }, .{ .x = x1, .y = y1, .z = z } },
        .color = iris.Color.rgba(20, 30, 48, 255),
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
    try scene.addTriangle(.{
        .positions = .{ .{ .x = x0, .y = y0, .z = z }, .{ .x = x1, .y = y1, .z = z }, .{ .x = x0, .y = y1, .z = z } },
        .color = iris.Color.rgba(13, 22, 38, 255),
        .normals = .{ normal, normal, normal },
        .material_handle = material,
    });
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
    try addQuad(scene, .{ .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z1 } }, material, texture, normal_texture);
}

fn addColumn(
    scene: *iris.Scene3D,
    center: iris.math.Vec3,
    radius: f32,
    height: f32,
    sides: u32,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
    const y0 = center.y - height * 0.5;
    const y1 = center.y + height * 0.5;
    const top_center = iris.math.Vec3{ .x = center.x, .y = y1, .z = center.z };
    const bottom_center = iris.math.Vec3{ .x = center.x, .y = y0, .z = center.z };
    var side: u32 = 0;
    while (side < sides) : (side += 1) {
        const uv0 = @as(f32, @floatFromInt(side)) / @as(f32, @floatFromInt(sides));
        const uv1 = @as(f32, @floatFromInt(side + 1)) / @as(f32, @floatFromInt(sides));
        const a0 = uv0 * std.math.tau;
        const a1 = uv1 * std.math.tau;
        const b0 = iris.math.Vec3{ .x = center.x + radius * @cos(a0), .y = y0, .z = center.z + radius * @sin(a0) };
        const b1 = iris.math.Vec3{ .x = center.x + radius * @cos(a1), .y = y0, .z = center.z + radius * @sin(a1) };
        const t0 = iris.math.Vec3{ .x = b0.x, .y = y1, .z = b0.z };
        const t1 = iris.math.Vec3{ .x = b1.x, .y = y1, .z = b1.z };
        try addTri(scene, .{ b0, b1, t1 }, .{ .{ .x = uv0, .y = 1.0 }, .{ .x = uv1, .y = 1.0 }, .{ .x = uv1 } }, material, texture, normal_texture);
        try addTri(scene, .{ b0, t1, t0 }, .{ .{ .x = uv0, .y = 1.0 }, .{ .x = uv1 }, .{ .x = uv0 } }, material, texture, normal_texture);
        try addTri(scene, .{ t0, t1, top_center }, .{ .{ .x = uv0 }, .{ .x = uv1 }, .{ .x = 0.5, .y = 0.5 } }, material, texture, normal_texture);
        try addTri(scene, .{ b1, b0, bottom_center }, .{ .{ .x = uv1, .y = 1.0 }, .{ .x = uv0, .y = 1.0 }, .{ .x = 0.5, .y = 0.5 } }, material, texture, normal_texture);
    }
}

fn addQuad(
    scene: *iris.Scene3D,
    positions: [4]iris.math.Vec3,
    material: iris.scene3d.MaterialHandle,
    texture: iris.scene3d.TextureHandle,
    normal_texture: iris.scene3d.TextureHandle,
) !void {
    const uvs = [4]iris.math.Vec2{ .{}, .{ .x = 1.0 }, .{ .x = 1.0, .y = 1.0 }, .{ .y = 1.0 } };
    try addTri(scene, .{ positions[0], positions[1], positions[2] }, .{ uvs[0], uvs[1], uvs[2] }, material, texture, normal_texture);
    try addTri(scene, .{ positions[0], positions[2], positions[3] }, .{ uvs[0], uvs[2], uvs[3] }, material, texture, normal_texture);
}

fn addGrid(scene: *iris.Scene3D) !void {
    try scene.addGrid(.{
        .origin = .{ .y = -0.762 },
        .x_extent = 2.55,
        .z_extent = 2.15,
        .spacing = 0.36,
        .width = 2.0,
        .color = iris.Color.rgba(30, 170, 255, 150),
        .major_color = iris.Color.rgba(42, 200, 255, 220),
        .major_every = 3,
    });
}

fn addAxes(scene: *iris.Scene3D) !void {
    try scene.addAxis(.{
        .origin = .{ .x = -2.32, .y = -0.735, .z = -1.86 },
        .length = 0.72,
        .width = 3.0,
        .x_color = iris.Color.rgba(248, 82, 82, 255),
        .y_color = iris.Color.rgba(88, 218, 132, 255),
        .z_color = iris.Color.rgba(90, 156, 255, 255),
    });
}

fn addDebugBoxes(scene: *iris.Scene3D) !void {
    const color = iris.Color.rgba(255, 238, 128, 210);
    try scene.addDebugBox(.{
        .min = .{ .x = -1.46, .y = -0.58, .z = -0.96 },
        .max = .{ .x = 0.1, .y = 0.68, .z = 0.6 },
        .color = color,
        .width = 2.0,
    });
    try scene.addDebugBox(.{
        .min = .{ .x = 0.28, .y = -0.74, .z = -0.32 },
        .max = .{ .x = 1.36, .y = 0.58, .z = 0.76 },
        .color = color,
        .width = 2.0,
    });
    try scene.addDebugBox(.{
        .min = .{ .x = -0.37, .y = -0.72, .z = -1.34 },
        .max = .{ .x = 0.47, .y = 0.12, .z = -0.5 },
        .color = color,
        .width = 2.0,
    });
}

fn addVolumePlaceholder(scene: *iris.Scene3D) !void {
    try scene.addVolumePlaceholder(.{
        .min = .{ .x = -2.18, .y = -0.7, .z = 0.96 },
        .max = .{ .x = -1.42, .y = 0.42, .z = 1.62 },
        .color = iris.Color.rgba(180, 220, 255, 210),
        .slice_color = iris.Color.rgba(86, 190, 255, 145),
        .width = 2.0,
        .slices = 4,
    });
}

fn addPointCloud(scene: *iris.Scene3D, allocator: std.mem.Allocator) !void {
    const columns: u32 = 15;
    const rows: u32 = 6;
    var points = try allocator.alloc(iris.Point3D, columns * rows);
    var index: usize = 0;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < columns) : (col += 1) {
            const u = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(columns - 1));
            const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(rows - 1));
            const wave = @sin(u * std.math.tau * 1.5) * 0.12 + @cos(v * std.math.tau) * 0.06;
            points[index] = .{
                .position = .{
                    .x = -1.65 + u * 3.3,
                    .y = -0.3 + v * 0.78 + wave,
                    .z = 0.92 + 0.18 * @sin((u + v) * std.math.tau),
                },
                .color = pointCloudColor(u, v),
                .size = if ((col + row) % 5 == 0) 4.0 else 3.0,
            };
            index += 1;
        }
    }
    try scene.addPointCloud(.{ .points = points });
}

fn pointCloudColor(u: f32, v: f32) iris.Color {
    const r = colorChannel(80.0 + 120.0 * u);
    const g = colorChannel(140.0 + 90.0 * v);
    const b = colorChannel(230.0 - 90.0 * u + 35.0 * v);
    return iris.Color.rgba(r, g, b, 235);
}

fn colorChannel(value: f32) u8 {
    return @intFromFloat(@round(@min(255.0, @max(0.0, value))));
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

fn printDone(io: std.Io, path: []const u8, pixels: usize) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print("wrote {s} ({d} non-transparent pixels)\n", .{ path, pixels });
    try out.interface.flush();
}
