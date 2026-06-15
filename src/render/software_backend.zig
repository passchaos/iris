//! Software implementation of the GPU backend contract.
//!
//! This backend is used as the CPU fallback for queued commands. It receives the
//! same GpuBatch data as an external backend, which makes it a reference path for
//! blending, depth, texture sampling, normal maps, and light/material handling.
const std = @import("std");
const color = @import("color.zig");
const BlendMode = color.BlendMode;
const Image = @import("image.zig").Image;
const math = @import("math.zig");
const gpu = @import("gpu.zig");

pub const SoftwareBackend = struct {
    target: *Image,
    allocator: ?std.mem.Allocator = null,
    depth: std.ArrayList(f32) = .empty,
    submitted: usize = 0,
    pixels_touched: usize = 0,

    pub fn init(target: *Image) SoftwareBackend {
        return .{ .target = target };
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator, target: *Image) SoftwareBackend {
        return .{ .target = target, .allocator = allocator };
    }

    pub fn deinit(self: *SoftwareBackend) void {
        if (self.allocator) |allocator| {
            self.depth.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn backend(self: *SoftwareBackend) gpu.Backend {
        return .{
            .context = self,
            .submitFn = submit,
        };
    }

    fn submit(context: *anyopaque, command: gpu.GpuCommand, batch: *const gpu.GpuBatch) !void {
        const self: *SoftwareBackend = @ptrCast(@alignCast(context));
        switch (command.kind) {
            .render_2d => self.submit2D(batch),
            .render_3d => try self.submit3D(batch),
        }
        self.submitted += 1;
    }

    fn submit2D(self: *SoftwareBackend, batch: *const gpu.GpuBatch) void {
        for (batch.tile_ranges.items) |range| {
            const start: usize = range.strip_start;
            const end = start + range.strip_count;
            for (batch.strips.items[start..end]) |strip| {
                const value = color.Color.fromRgba32(strip.rgba);
                const blend_mode: BlendMode = @enumFromInt(@as(u8, @intCast(strip.blend_mode)));
                if (value.a == 0 and blend_mode == .source_over) continue;
                if (blend_mode == .destination) continue;
                // Source-like strips are already coverage-resolved by Scene2D,
                // so opaque spans can be copied without per-pixel blend work.
                if ((blend_mode == .source_over and value.a == 255) or blend_mode == .copy or blend_mode == .source) {
                    const span = self.target.span(@intCast(strip.x), @intCast(strip.y), strip.width);
                    @memset(span, value);
                    self.pixels_touched += span.len;
                    continue;
                }
                var x: u32 = strip.x;
                const x_end = x + strip.width;
                while (x < x_end) : (x += 1) {
                    self.target.blendPixelMode(x, strip.y, value, blend_mode);
                    self.pixels_touched += 1;
                }
            }
        }
    }

    fn submit3D(self: *SoftwareBackend, batch: *const gpu.GpuBatch) !void {
        const allocator = self.allocator orelse return error.MissingAllocator;
        const count = std.math.mul(u32, self.target.width, self.target.height) catch return error.ImageTooLarge;
        try self.depth.resize(allocator, count);
        @memset(self.depth.items, std.math.inf(f32));

        // Draw order matches the encoded batch order, with one shared depth
        // buffer for triangles, points, and lines so mixed primitive scenes have
        // predictable occlusion.
        for (batch.triangles.items) |triangle| {
            self.rasterTriangle(triangle, batch);
        }
        for (batch.points.items) |point| {
            self.rasterPoint(point);
        }
        for (batch.lines.items) |line| {
            self.rasterLine(line);
        }
    }

    fn rasterLine(self: *SoftwareBackend, line: gpu.GpuLine3D) void {
        const a = ndcLineStartToScreen(line, self.target.width, self.target.height);
        const b = ndcLineEndToScreen(line, self.target.width, self.target.height);
        const dx = b.xy.x - a.xy.x;
        const dy = b.xy.y - a.xy.y;
        const steps_f = @max(@abs(dx), @abs(dy));
        const steps: u32 = @max(1, @as(u32, @intFromFloat(@ceil(steps_f))));
        var i: u32 = 0;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const x = a.xy.x + dx * t;
            const y = a.xy.y + dy * t;
            const z = a.z + (b.z - a.z) * t;
            self.rasterSquare(x, y, z, line.width, color.Color.fromRgba32(line.rgba));
        }
    }

    fn rasterPoint(self: *SoftwareBackend, point: gpu.GpuPoint3D) void {
        const p = ndcPointToScreen(point, self.target.width, self.target.height);
        self.rasterSquare(p.xy.x, p.xy.y, p.z, point.size, color.Color.fromRgba32(point.rgba));
    }

    fn rasterSquare(self: *SoftwareBackend, x_center: f32, y_center: f32, z: f32, size: f32, value: color.Color) void {
        const radius = @max(0, @as(i32, @intFromFloat(@ceil(size * 0.5))) - 1);
        const center_x: i32 = @intFromFloat(@floor(x_center));
        const center_y: i32 = @intFromFloat(@floor(y_center));
        var y = math.clampInt(center_y - radius, 0, @intCast(self.target.height));
        const end_y = math.clampInt(center_y + radius + 1, 0, @intCast(self.target.height));
        while (y < end_y) : (y += 1) {
            var x = math.clampInt(center_x - radius, 0, @intCast(self.target.width));
            const end_x = math.clampInt(center_x + radius + 1, 0, @intCast(self.target.width));
            while (x < end_x) : (x += 1) {
                const idx: usize = @intCast(@as(u32, @intCast(y)) * self.target.width + @as(u32, @intCast(x)));
                if (z < self.depth.items[idx]) {
                    self.depth.items[idx] = z;
                    self.target.blendPixel(@intCast(x), @intCast(y), value);
                    self.pixels_touched += 1;
                }
            }
        }
    }

    fn rasterTriangle(self: *SoftwareBackend, triangle: gpu.GpuTriangle, batch: *const gpu.GpuBatch) void {
        const p = [3]ScreenVertex{
            ndcToScreen(triangle.a, self.target.width, self.target.height),
            ndcToScreen(triangle.b, self.target.width, self.target.height),
            ndcToScreen(triangle.c, self.target.width, self.target.height),
        };
        const xy = [3]math.Vec2{ p[0].xy, p[1].xy, p[2].xy };
        // Restrict work to the triangle bounds, then use barycentric weights for
        // both coverage and interpolation. The same weights feed depth, colors,
        // UVs, normals, and world position for lighting.
        const min_x: i32 = @intFromFloat(@floor(@min(@min(xy[0].x, xy[1].x), xy[2].x)));
        const min_y: i32 = @intFromFloat(@floor(@min(@min(xy[0].y, xy[1].y), xy[2].y)));
        const max_x: i32 = @intFromFloat(@ceil(@max(@max(xy[0].x, xy[1].x), xy[2].x)));
        const max_y: i32 = @intFromFloat(@ceil(@max(@max(xy[0].y, xy[1].y), xy[2].y)));

        var y = math.clampInt(min_y, 0, @intCast(self.target.height));
        const end_y = math.clampInt(max_y, 0, @intCast(self.target.height));
        while (y < end_y) : (y += 1) {
            var x = math.clampInt(min_x, 0, @intCast(self.target.width));
            const end_x = math.clampInt(max_x, 0, @intCast(self.target.width));
            while (x < end_x) : (x += 1) {
                const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
                const bary = barycentric(sample, xy) orelse continue;
                const z = bary[0] * p[0].z + bary[1] * p[1].z + bary[2] * p[2].z;
                const idx: usize = @intCast(@as(u32, @intCast(y)) * self.target.width + @as(u32, @intCast(x)));
                if (z < self.depth.items[idx]) {
                    self.depth.items[idx] = z;
                    self.target.blendPixel(@intCast(x), @intCast(y), shadePixel(bary, triangle, batch));
                    self.pixels_touched += 1;
                }
            }
        }
    }
};

const ScreenVertex = struct {
    xy: math.Vec2,
    z: f32,
};

fn ndcToScreen(vertex: gpu.GpuVertex3D, width: u32, height: u32) ScreenVertex {
    return .{
        .xy = .{
            .x = (vertex.x * 0.5 + 0.5) * @as(f32, @floatFromInt(width)),
            .y = (1.0 - (vertex.y * 0.5 + 0.5)) * @as(f32, @floatFromInt(height)),
        },
        .z = vertex.z,
    };
}

fn ndcPointToScreen(point: gpu.GpuPoint3D, width: u32, height: u32) ScreenVertex {
    return .{
        .xy = .{
            .x = (point.x * 0.5 + 0.5) * @as(f32, @floatFromInt(width)),
            .y = (1.0 - (point.y * 0.5 + 0.5)) * @as(f32, @floatFromInt(height)),
        },
        .z = point.z,
    };
}

fn ndcLineStartToScreen(line: gpu.GpuLine3D, width: u32, height: u32) ScreenVertex {
    return ndcVec3ToScreen(.{ .x = line.ax, .y = line.ay, .z = line.az }, width, height);
}

fn ndcLineEndToScreen(line: gpu.GpuLine3D, width: u32, height: u32) ScreenVertex {
    return ndcVec3ToScreen(.{ .x = line.bx, .y = line.by, .z = line.bz }, width, height);
}

fn ndcVec3ToScreen(point: math.Vec3, width: u32, height: u32) ScreenVertex {
    return .{
        .xy = .{
            .x = (point.x * 0.5 + 0.5) * @as(f32, @floatFromInt(width)),
            .y = (1.0 - (point.y * 0.5 + 0.5)) * @as(f32, @floatFromInt(height)),
        },
        .z = point.z,
    };
}

fn edge(a: math.Vec2, b: math.Vec2, p: math.Vec2) f32 {
    return (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x);
}

fn barycentric(p: math.Vec2, tri: [3]math.Vec2) ?[3]f32 {
    const area = edge(tri[0], tri[1], tri[2]);
    if (@abs(area) < 0.000001) return null;
    const w0 = edge(tri[1], tri[2], p) / area;
    const w1 = edge(tri[2], tri[0], p) / area;
    const w2 = edge(tri[0], tri[1], p) / area;
    if (w0 < 0 or w1 < 0 or w2 < 0) return null;
    return .{ w0, w1, w2 };
}

fn interpolateColor(bary: [3]f32, triangle: gpu.GpuTriangle) color.Color {
    return interpolateVertexColors(bary, triangle, false);
}

fn interpolateBaseColor(bary: [3]f32, triangle: gpu.GpuTriangle) color.Color {
    return interpolateVertexColors(bary, triangle, true);
}

fn interpolateVertexColors(bary: [3]f32, triangle: gpu.GpuTriangle, base: bool) color.Color {
    const a = color.Color.fromRgba32(triangle.a.rgba);
    const b = color.Color.fromRgba32(triangle.b.rgba);
    const c = color.Color.fromRgba32(triangle.c.rgba);
    const ba = color.Color.fromRgba32(triangle.a.base_rgba);
    const bb = color.Color.fromRgba32(triangle.b.base_rgba);
    const bc = color.Color.fromRgba32(triangle.c.base_rgba);
    const ca = if (base) ba else a;
    const cb = if (base) bb else b;
    const cc = if (base) bc else c;
    return .{
        .r = interpChannel(bary, ca.r, cb.r, cc.r),
        .g = interpChannel(bary, ca.g, cb.g, cc.g),
        .b = interpChannel(bary, ca.b, cb.b, cc.b),
        .a = interpChannel(bary, ca.a, cb.a, cc.a),
    };
}

fn shadePixel(bary: [3]f32, triangle: gpu.GpuTriangle, batch: *const gpu.GpuBatch) color.Color {
    if (batch.lighting_enabled) return shadeLitPixel(bary, triangle, batch);
    const value = interpolateColor(bary, triangle);
    const sampled = sampleTriangleTexture(bary, triangle, batch) orelse return value;
    return modulateColor(value, sampled);
}

fn shadeLitPixel(bary: [3]f32, triangle: gpu.GpuTriangle, batch: *const gpu.GpuBatch) color.Color {
    var value = interpolateBaseColor(bary, triangle);
    if (sampleTriangleTexture(bary, triangle, batch)) |sampled| {
        value = modulateColor(value, sampled);
    }
    const normal = sampleTriangleNormal(bary, triangle, batch);
    const position = interpolatePosition(bary, triangle);
    const intensity = lightIntensity(normal, position, triangle, batch);
    return applyMaterialColor(value, intensity, triangle);
}

fn sampleTriangleTexture(bary: [3]f32, triangle: gpu.GpuTriangle, batch: *const gpu.GpuBatch) ?color.Color {
    return sampleTextureAt(interpolateUv(bary, triangle), triangle.texture_index, batch);
}

fn sampleTriangleNormal(bary: [3]f32, triangle: gpu.GpuTriangle, batch: *const gpu.GpuBatch) math.Vec3 {
    if (sampleTextureAt(interpolateUv(bary, triangle), triangle.normal_texture_index, batch)) |value| {
        return decodeNormal(value);
    }
    return interpolateNormal(bary, triangle);
}

fn sampleTextureAt(uv: math.Vec2, texture_index: u32, batch: *const gpu.GpuBatch) ?color.Color {
    if (texture_index == gpu.invalid_texture_index) return null;
    if (texture_index >= batch.textures.items.len) return null;
    const texture = batch.textures.items[texture_index];
    if (texture.width == 0 or texture.height == 0 or texture.pixel_count == 0) return null;

    const x = sampleTextureCoord(uv.x, texture.width);
    const y = sampleTextureCoord(uv.y, texture.height);
    const local_index = @min(texture.pixel_count - 1, y * texture.width + x);
    const pixel_index = texture.pixel_start + local_index;
    if (pixel_index >= batch.texture_pixels.items.len) return null;
    return color.Color.fromRgba32(batch.texture_pixels.items[pixel_index]);
}

fn interpolateUv(bary: [3]f32, triangle: gpu.GpuTriangle) math.Vec2 {
    return .{
        .x = bary[0] * triangle.a.u + bary[1] * triangle.b.u + bary[2] * triangle.c.u,
        .y = bary[0] * triangle.a.v + bary[1] * triangle.b.v + bary[2] * triangle.c.v,
    };
}

fn interpolateNormal(bary: [3]f32, triangle: gpu.GpuTriangle) math.Vec3 {
    return (math.Vec3{
        .x = bary[0] * triangle.a.nx + bary[1] * triangle.b.nx + bary[2] * triangle.c.nx,
        .y = bary[0] * triangle.a.ny + bary[1] * triangle.b.ny + bary[2] * triangle.c.ny,
        .z = bary[0] * triangle.a.nz + bary[1] * triangle.b.nz + bary[2] * triangle.c.nz,
    }).normalize();
}

fn interpolatePosition(bary: [3]f32, triangle: gpu.GpuTriangle) math.Vec3 {
    return .{
        .x = bary[0] * triangle.a.world_x + bary[1] * triangle.b.world_x + bary[2] * triangle.c.world_x,
        .y = bary[0] * triangle.a.world_y + bary[1] * triangle.b.world_y + bary[2] * triangle.c.world_y,
        .z = bary[0] * triangle.a.world_z + bary[1] * triangle.b.world_z + bary[2] * triangle.c.world_z,
    };
}

fn decodeNormal(value: color.Color) math.Vec3 {
    return (math.Vec3{
        .x = @as(f32, @floatFromInt(value.r)) / 127.5 - 1.0,
        .y = @as(f32, @floatFromInt(value.g)) / 127.5 - 1.0,
        .z = @as(f32, @floatFromInt(value.b)) / 127.5 - 1.0,
    }).normalize();
}

fn sampleTextureCoord(t: f32, extent: u32) u32 {
    const scaled = @floor(@min(0.999999, @max(0.0, t)) * @as(f32, @floatFromInt(extent)));
    return @intFromFloat(scaled);
}

fn modulateColor(a: color.Color, b: color.Color) color.Color {
    return .{
        .r = @intCast((@as(u16, a.r) * b.r + 127) / 255),
        .g = @intCast((@as(u16, a.g) * b.g + 127) / 255),
        .b = @intCast((@as(u16, a.b) * b.b + 127) / 255),
        .a = @intCast((@as(u16, a.a) * b.a + 127) / 255),
    };
}

fn lightIntensity(normal: math.Vec3, position: math.Vec3, triangle: gpu.GpuTriangle, batch: *const gpu.GpuBatch) f32 {
    var intensity: f32 = 0.0;
    for (batch.lights.items) |light| {
        var falloff: f32 = 1.0;
        const light_dir = switch (light.kind) {
            0 => (math.Vec3{ .x = light.direction_x, .y = light.direction_y, .z = light.direction_z }).normalize(),
            1, 2 => blk: {
                const light_pos = math.Vec3{ .x = light.position_x, .y = light.position_y, .z = light.position_z };
                const offset = light_pos.sub(position);
                const distance = offset.length();
                if (distance > light.range) {
                    intensity += light.ambient * triangle.material_ambient;
                    continue;
                }
                // Spot lights use the point-light attenuation path after cone
                // falloff is applied, so range and material response stay shared.
                if (light.kind == 2) {
                    const spot_dir = (math.Vec3{ .x = light.direction_x, .y = light.direction_y, .z = light.direction_z }).normalize();
                    const from_light = position.sub(light_pos).normalize();
                    const cone = from_light.dot(spot_dir);
                    const outer = @cos(light.outer_angle);
                    if (cone <= outer) {
                        intensity += light.ambient * triangle.material_ambient;
                        continue;
                    }
                    const inner = @cos(light.inner_angle);
                    if (cone < inner) {
                        const denom = inner - outer;
                        falloff *= if (@abs(denom) > 0.000001) (cone - outer) / denom else 0.0;
                    }
                }
                if (light.attenuation > 0.0) {
                    const t = if (light.range > 0.000001) @min(1.0, distance / light.range) else 1.0;
                    falloff *= @max(0.0, 1.0 - t * t) / (1.0 + light.attenuation * distance * distance);
                }
                break :blk offset.normalize();
            },
            else => (math.Vec3{ .x = light.direction_x, .y = light.direction_y, .z = light.direction_z }).normalize(),
        };
        const ndotl = @max(0.0, normal.normalize().dot(light_dir));
        const specular = triangle.material_metallic * (1.0 - triangle.material_roughness) * ndotl * ndotl;
        intensity += light.ambient * triangle.material_ambient + light.diffuse * (triangle.material_diffuse * ndotl + specular) * falloff;
    }
    return @min(1.0, intensity);
}

fn applyMaterialColor(value: color.Color, intensity: f32, triangle: gpu.GpuTriangle) color.Color {
    const lit = scaleColor(value, intensity);
    const emissive = color.Color.fromRgba32(triangle.material_emissive);
    return .{
        .r = addEmissiveChannel(lit.r, emissive.r, triangle.material_emissive_strength),
        .g = addEmissiveChannel(lit.g, emissive.g, triangle.material_emissive_strength),
        .b = addEmissiveChannel(lit.b, emissive.b, triangle.material_emissive_strength),
        .a = lit.a,
    };
}

fn scaleColor(value: color.Color, intensity: f32) color.Color {
    const clamped = @min(1.0, @max(0.0, intensity));
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(value.r)) * clamped)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(value.g)) * clamped)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(value.b)) * clamped)),
        .a = value.a,
    };
}

fn addEmissiveChannel(base: u8, emissive: u8, strength: f32) u8 {
    return @intFromFloat(@round(@min(255.0, @as(f32, @floatFromInt(base)) + @as(f32, @floatFromInt(emissive)) * @max(0.0, strength))));
}

fn interpChannel(bary: [3]f32, a: u8, b: u8, c: u8) u8 {
    const value =
        bary[0] * @as(f32, @floatFromInt(a)) +
        bary[1] * @as(f32, @floatFromInt(b)) +
        bary[2] * @as(f32, @floatFromInt(c));
    return @intFromFloat(@round(@min(255.0, @max(0.0, value))));
}

test "software backend renders queued 2D GPU strips" {
    const allocator = std.testing.allocator;
    var scene = @import("scene2d.zig").Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, .red);

    var target = try Image.init(allocator, 4, 4, .transparent);
    defer target.deinit();

    var backend = SoftwareBackend.init(&target);
    var device = gpu.GpuDevice.init(allocator, .none);
    defer device.deinit();
    device.setBackend(backend.backend());

    try device.enqueue2D(&scene, &target);
    try device.submitQueued();

    try std.testing.expectEqual(@as(usize, 1), backend.submitted);
    try std.testing.expectEqual(@as(usize, 4), backend.pixels_touched);
    try std.testing.expectEqual(color.Color.red, target.pixel(0, 0).?);
}

test "software backend renders queued 3D GPU triangles" {
    const allocator = std.testing.allocator;
    var scene = @import("scene3d.zig").Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
    });

    var target = try Image.init(allocator, 4, 4, .transparent);
    defer target.deinit();

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    var device = gpu.GpuDevice.init(allocator, .none);
    defer device.deinit();
    device.setBackend(backend.backend());

    try device.enqueue3D(&scene, &target);
    try device.submitQueued();

    try std.testing.expectEqual(@as(usize, 1), backend.submitted);
    try std.testing.expect(target.countNonTransparentPixels() > 0);
}

test "software backend renders queued orthographic 3D triangles" {
    const allocator = std.testing.allocator;
    const scene3d = @import("scene3d.zig");
    var scene = scene3d.Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCamera(scene3d.Camera.orthographicLookAt(
        .{ .z = 3 },
        .{},
        .{ .y = 1 },
        4.0,
        4.0,
        0.1,
        100.0,
    ));
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.0 },
            .{ .x = 0.5, .y = -0.5, .z = 0.0 },
            .{ .x = 0.0, .y = 0.5, .z = 0.0 },
        },
        .color = .white,
    });

    var target = try Image.init(allocator, 16, 16, .transparent);
    defer target.deinit();

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    var device = gpu.GpuDevice.init(allocator, .none);
    defer device.deinit();
    device.setBackend(backend.backend());

    try device.enqueue3D(&scene, &target);
    try device.submitQueued();

    try std.testing.expectEqual(@as(usize, 1), backend.submitted);
    try std.testing.expect(target.countNonTransparentPixels() > 0);
}

test "software backend interpolates 3D vertex colors" {
    const allocator = std.testing.allocator;
    var scene = @import("scene3d.zig").Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.0, .y = 0.9, .z = 0.1 },
        },
        .color = .white,
        .colors = .{ .red, .green, .blue },
    });

    var target = try Image.init(allocator, 24, 24, .transparent);
    defer target.deinit();

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    var device = gpu.GpuDevice.init(allocator, .none);
    defer device.deinit();
    device.setBackend(backend.backend());

    try device.enqueue3D(&scene, &target);
    try device.submitQueued();

    const center = target.pixel(12, 12).?;
    try std.testing.expect(center.r > 0 and center.g > 0 and center.b > 0);
    try std.testing.expect(center.r < 255 and center.g < 255 and center.b < 255);
}

test "software backend interpolates indexed mesh vertex colors" {
    const allocator = std.testing.allocator;
    var scene = @import("scene3d.zig").Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{
        .{ .x = -0.9, .y = -0.9, .z = 0.1 },
        .{ .x = 0.9, .y = -0.9, .z = 0.1 },
        .{ .x = 0.0, .y = 0.9, .z = 0.1 },
    };
    const colors = [_]color.Color{ .red, .green, .blue };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMesh(.{ .positions = &positions, .indices = &indices, .color = .white, .colors = &colors });

    var target = try Image.init(allocator, 24, 24, .transparent);
    defer target.deinit();

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    var device = gpu.GpuDevice.init(allocator, .none);
    defer device.deinit();
    device.setBackend(backend.backend());

    try device.enqueue3D(&scene, &target);
    try device.submitQueued();

    const center = target.pixel(12, 12).?;
    try std.testing.expect(center.r > 0 and center.g > 0 and center.b > 0);
}

test "software backend samples 3D textures from interpolated UVs" {
    const allocator = std.testing.allocator;
    var target = try Image.init(allocator, 4, 4, .transparent);
    defer target.deinit();

    var batch: gpu.GpuBatch = .{};
    defer batch.deinit(allocator);
    try batch.texture_pixels.appendSlice(allocator, &.{
        color.Color.red.toRgba32(),
        color.Color.blue.toRgba32(),
    });
    try batch.textures.append(allocator, .{
        .width = 2,
        .height = 1,
        .pixel_start = 0,
        .pixel_count = 2,
    });
    try batch.triangles.append(allocator, .{
        .a = .{ .x = -1.0, .y = -1.0, .z = 0.1, .u = 0.0, .v = 0.0, .rgba = color.Color.white.toRgba32() },
        .b = .{ .x = 3.0, .y = -1.0, .z = 0.1, .u = 2.0, .v = 0.0, .rgba = color.Color.white.toRgba32() },
        .c = .{ .x = -1.0, .y = 3.0, .z = 0.1, .u = 0.0, .v = 2.0, .rgba = color.Color.white.toRgba32() },
        .texture_index = 0,
    });

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    try backend.submit3D(&batch);

    try std.testing.expectEqual(color.Color.red, target.pixel(0, 2).?);
    try std.testing.expectEqual(color.Color.blue, target.pixel(3, 2).?);
}

test "software backend samples normal maps from interpolated UVs" {
    const allocator = std.testing.allocator;
    var batch: gpu.GpuBatch = .{};
    defer batch.deinit(allocator);
    try batch.texture_pixels.appendSlice(allocator, &.{
        color.Color.rgba(128, 128, 255, 255).toRgba32(),
        color.Color.rgba(255, 128, 128, 255).toRgba32(),
    });
    try batch.textures.append(allocator, .{
        .width = 2,
        .height = 1,
        .pixel_start = 0,
        .pixel_count = 2,
    });

    const triangle = gpu.GpuTriangle{
        .a = .{ .x = 0.0, .y = 0.0, .z = 0.0, .u = 0.0, .v = 0.0, .nx = 0.0, .ny = 0.0, .nz = 1.0, .rgba = color.Color.white.toRgba32() },
        .b = .{ .x = 0.0, .y = 0.0, .z = 0.0, .u = 2.0, .v = 0.0, .nx = 0.0, .ny = 0.0, .nz = 1.0, .rgba = color.Color.white.toRgba32() },
        .c = .{ .x = 0.0, .y = 0.0, .z = 0.0, .u = 0.0, .v = 2.0, .nx = 0.0, .ny = 0.0, .nz = 1.0, .rgba = color.Color.white.toRgba32() },
        .normal_texture_index = 0,
    };

    const left = sampleTriangleNormal(.{ 0.8, 0.1, 0.1 }, triangle, &batch);
    try std.testing.expect(left.z > 0.99);
    try std.testing.expect(@abs(left.x) < 0.01);

    const right = sampleTriangleNormal(.{ 0.1, 0.8, 0.1 }, triangle, &batch);
    try std.testing.expect(right.x > 0.99);
    try std.testing.expect(@abs(right.z) < 0.01);
}

test "software backend falls back to interpolated normals without normal maps" {
    const batch = gpu.GpuBatch{};
    const triangle = gpu.GpuTriangle{
        .a = .{ .x = 0.0, .y = 0.0, .z = 0.0, .nx = 1.0, .ny = 0.0, .nz = 0.0, .rgba = color.Color.white.toRgba32() },
        .b = .{ .x = 0.0, .y = 0.0, .z = 0.0, .nx = 1.0, .ny = 0.0, .nz = 0.0, .rgba = color.Color.white.toRgba32() },
        .c = .{ .x = 0.0, .y = 0.0, .z = 0.0, .nx = 1.0, .ny = 0.0, .nz = 0.0, .rgba = color.Color.white.toRgba32() },
    };

    const normal = sampleTriangleNormal(.{ 0.2, 0.3, 0.5 }, triangle, &batch);
    try std.testing.expect(normal.x > 0.99);
    try std.testing.expect(@abs(normal.y) < 0.0001);
    try std.testing.expect(@abs(normal.z) < 0.0001);
}

test "software backend shades lit pixels from base color and batch lights" {
    const allocator = std.testing.allocator;
    var target = try Image.init(allocator, 4, 4, .transparent);
    defer target.deinit();

    var batch: gpu.GpuBatch = .{ .lighting_enabled = true };
    defer batch.deinit(allocator);
    try batch.lights.append(allocator, .{
        .kind = 0,
        .direction_x = 0.0,
        .direction_y = 0.0,
        .direction_z = 1.0,
        .position_x = 0.0,
        .position_y = 0.0,
        .position_z = 0.0,
        .ambient = 0.0,
        .diffuse = 1.0,
        .range = std.math.inf(f32),
        .attenuation = 0.0,
        .inner_angle = 0.0,
        .outer_angle = std.math.pi,
    });
    try batch.triangles.append(allocator, .{
        .a = .{ .x = -1.0, .y = -1.0, .z = 0.1, .nx = 0.0, .ny = 0.0, .nz = 1.0, .base_rgba = color.Color.red.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .b = .{ .x = 3.0, .y = -1.0, .z = 0.1, .nx = 0.0, .ny = 0.0, .nz = 1.0, .base_rgba = color.Color.red.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .c = .{ .x = -1.0, .y = 3.0, .z = 0.1, .nx = 0.0, .ny = 0.0, .nz = 1.0, .base_rgba = color.Color.red.toRgba32(), .rgba = color.Color.black.toRgba32() },
    });

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    try backend.submit3D(&batch);

    try std.testing.expectEqual(color.Color.red, target.pixel(1, 1).?);
}

test "software backend normal maps affect lit pixel shading" {
    const allocator = std.testing.allocator;
    var target = try Image.init(allocator, 4, 4, .transparent);
    defer target.deinit();

    var batch: gpu.GpuBatch = .{ .lighting_enabled = true };
    defer batch.deinit(allocator);
    try batch.texture_pixels.appendSlice(allocator, &.{
        color.Color.rgba(255, 128, 128, 255).toRgba32(),
        color.Color.rgba(128, 128, 255, 255).toRgba32(),
    });
    try batch.textures.append(allocator, .{ .width = 2, .height = 1, .pixel_start = 0, .pixel_count = 2 });
    try batch.lights.append(allocator, .{
        .kind = 0,
        .direction_x = 0.0,
        .direction_y = 0.0,
        .direction_z = 1.0,
        .position_x = 0.0,
        .position_y = 0.0,
        .position_z = 0.0,
        .ambient = 0.0,
        .diffuse = 1.0,
        .range = std.math.inf(f32),
        .attenuation = 0.0,
        .inner_angle = 0.0,
        .outer_angle = std.math.pi,
    });
    try batch.triangles.append(allocator, .{
        .a = .{ .x = -1.0, .y = -1.0, .z = 0.1, .u = 0.0, .v = 0.0, .nx = 0.0, .ny = 0.0, .nz = 1.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .b = .{ .x = 3.0, .y = -1.0, .z = 0.1, .u = 2.0, .v = 0.0, .nx = 0.0, .ny = 0.0, .nz = 1.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .c = .{ .x = -1.0, .y = 3.0, .z = 0.1, .u = 0.0, .v = 2.0, .nx = 0.0, .ny = 0.0, .nz = 1.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .normal_texture_index = 0,
    });

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    try backend.submit3D(&batch);

    try std.testing.expect((target.pixel(0, 2) orelse color.Color.transparent).r <= 2);
    try std.testing.expectEqual(color.Color.white, target.pixel(3, 2).?);
}

test "software backend point lights shade from pixel position" {
    const allocator = std.testing.allocator;
    var batch: gpu.GpuBatch = .{ .lighting_enabled = true };
    defer batch.deinit(allocator);
    try batch.lights.append(allocator, .{
        .kind = 1,
        .direction_x = 0.0,
        .direction_y = 0.0,
        .direction_z = 0.0,
        .position_x = 1.0,
        .position_y = 0.0,
        .position_z = 1.0,
        .ambient = 0.0,
        .diffuse = 1.0,
        .range = std.math.inf(f32),
        .attenuation = 0.0,
        .inner_angle = 0.0,
        .outer_angle = std.math.pi,
    });
    const triangle = gpu.GpuTriangle{
        .a = .{ .x = -1.0, .y = -1.0, .z = 0.1, .world_x = 0.0, .world_y = 0.0, .world_z = 0.0, .nx = 1.0, .ny = 0.0, .nz = 0.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .b = .{ .x = 3.0, .y = -1.0, .z = 0.1, .world_x = 2.0, .world_y = 0.0, .world_z = 0.0, .nx = 1.0, .ny = 0.0, .nz = 0.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .c = .{ .x = -1.0, .y = 3.0, .z = 0.1, .world_x = 0.0, .world_y = 2.0, .world_z = 0.0, .nx = 1.0, .ny = 0.0, .nz = 0.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
    };

    const near = shadePixel(.{ 1.0, 0.0, 0.0 }, triangle, &batch);
    const far = shadePixel(.{ 0.0, 1.0, 0.0 }, triangle, &batch);
    try std.testing.expect(near.r > far.r);
    try std.testing.expect(near.r > 150);
}

test "software backend spot lights shade only inside cone" {
    const allocator = std.testing.allocator;
    var batch: gpu.GpuBatch = .{ .lighting_enabled = true };
    defer batch.deinit(allocator);
    try batch.lights.append(allocator, .{
        .kind = 2,
        .direction_x = 1.0,
        .direction_y = 0.0,
        .direction_z = 0.0,
        .position_x = 0.0,
        .position_y = 0.0,
        .position_z = 0.0,
        .ambient = 0.0,
        .diffuse = 1.0,
        .range = 8.0,
        .attenuation = 0.0,
        .inner_angle = std.math.pi / 16.0,
        .outer_angle = std.math.pi / 8.0,
    });
    const triangle = gpu.GpuTriangle{
        .a = .{ .x = -1.0, .y = -1.0, .z = 0.1, .world_x = 0.0, .world_y = 0.0, .world_z = 0.0, .nx = -1.0, .ny = 0.0, .nz = 0.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .b = .{ .x = 3.0, .y = -1.0, .z = 0.1, .world_x = 2.0, .world_y = 0.0, .world_z = 0.0, .nx = -1.0, .ny = 0.0, .nz = 0.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
        .c = .{ .x = -1.0, .y = 3.0, .z = 0.1, .world_x = 0.0, .world_y = 2.0, .world_z = 0.0, .nx = -1.0, .ny = 0.0, .nz = 0.0, .base_rgba = color.Color.white.toRgba32(), .rgba = color.Color.black.toRgba32() },
    };

    const inside = shadePixel(.{ 0.0, 1.0, 0.0 }, triangle, &batch);
    const outside = shadePixel(.{ 0.0, 0.0, 1.0 }, triangle, &batch);
    try std.testing.expect(inside.r > 150);
    try std.testing.expect(outside.r <= 2);
}

test "software backend interpolates per-vertex normal lighting" {
    const allocator = std.testing.allocator;
    var scene = @import("scene3d.zig").Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 1.0 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.9, .y = -0.9, .z = 0.1 },
            .{ .x = 0.0, .y = 0.9, .z = 0.1 },
        },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = -1 }, .{ .z = 1 } },
    });

    var target = try Image.init(allocator, 24, 24, .transparent);
    defer target.deinit();

    var backend = SoftwareBackend.initWithAllocator(allocator, &target);
    defer backend.deinit();
    var device = gpu.GpuDevice.init(allocator, .none);
    defer device.deinit();
    device.setBackend(backend.backend());

    try device.enqueue3D(&scene, &target);
    try device.submitQueued();

    const lit = target.pixel(4, 20).?;
    const dark = target.pixel(20, 20).?;
    try std.testing.expect(lit.r > dark.r);
}
