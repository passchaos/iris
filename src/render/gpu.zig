//! Backend-neutral GPU command and batch model.
//!
//! Iris records high-level scenes into compact batches before handing them to a
//! real GPU backend or the software reference backend. The extern structs in
//! this file are the ABI-like contract shared with shaders and platform layers.
const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;
const scene2d = @import("scene2d.zig");
const Scene2D = scene2d.Scene2D;
const Strip = scene2d.Strip;
const Tile = scene2d.Tile;
const scene3d = @import("scene3d.zig");
const Scene3D = scene3d.Scene3D;
const math = @import("math.zig");
const render_graph = @import("render_graph.zig");

pub const BackendKind = enum {
    none,
    external,
};

pub const CommandKind = enum {
    render_2d,
    render_3d,
};

pub const Limits = struct {
    max_2d_primitives: usize = std.math.maxInt(usize),
    max_3d_triangles: usize = std.math.maxInt(usize),
    max_3d_points: usize = std.math.maxInt(usize),
    max_3d_lines: usize = std.math.maxInt(usize),
    max_target_width: u32 = std.math.maxInt(u32),
    max_target_height: u32 = std.math.maxInt(u32),
};

pub const GpuCommand = struct {
    kind: CommandKind,
    primitive_count: usize,
    target_width: u32,
    target_height: u32,
    batch_index: ?usize = null,
};

pub const RenderGraphOptions = struct {
    picking_pass: bool = false,
    debug_pass: bool = false,
};

pub const BackendCapabilities = struct {
    render_2d: bool = true,
    render_3d: bool = true,
    point_cloud_3d: bool = true,
    line_3d: bool = true,
    textured_3d: bool = true,
    normal_mapped_3d: bool = true,
    lit_3d: bool = true,
};

pub const Backend = struct {
    context: *anyopaque,
    submitFn: *const fn (context: *anyopaque, command: GpuCommand, batch: *const GpuBatch) anyerror!void,
    capabilities: BackendCapabilities = .{},

    pub fn submit(self: Backend, command: GpuCommand, batch: *const GpuBatch) !void {
        try self.submitFn(self.context, command, batch);
    }
};

pub const ShaderContract = struct {
    pub const render_strips_path = "shaders/render_strips.wgsl";
    pub const render_triangles_path = "shaders/render_triangles.wgsl";

    pub const strips_binding: u32 = 0;
    pub const target_binding: u32 = 1;

    pub const triangles_binding: u32 = 0;
    pub const textures_binding: u32 = 1;
    pub const texture_pixels_binding: u32 = 2;
    pub const lights_binding: u32 = 3;
    pub const lighting_enabled_binding: u32 = 4;

    pub const strip_size = @sizeOf(GpuStrip);
    pub const vertex3d_size = @sizeOf(GpuVertex3D);
    pub const triangle_size = @sizeOf(GpuTriangle);
    pub const point3d_size = @sizeOf(GpuPoint3D);
    pub const line3d_size = @sizeOf(GpuLine3D);
    pub const texture_size = @sizeOf(GpuTexture);
    pub const light_size = @sizeOf(GpuLight);
};

/// Horizontal pixel run produced by Scene2D. It is already clipped, coverage
/// resolved, and sorted into tile order before backend submission.
pub const GpuStrip = extern struct {
    x: u16,
    y: u16,
    width: u16,
    blend_mode: u16 = 0,
    rgba: u32,
};

pub const GpuVertex3D = extern struct {
    x: f32,
    y: f32,
    z: f32,
    world_x: f32 = 0.0,
    world_y: f32 = 0.0,
    world_z: f32 = 0.0,
    u: f32 = 0.0,
    v: f32 = 0.0,
    nx: f32 = 0.0,
    ny: f32 = 0.0,
    nz: f32 = 1.0,
    base_rgba: u32 = Color.white.toRgba32(),
    rgba: u32,
};

pub const GpuTriangle = extern struct {
    a: GpuVertex3D,
    b: GpuVertex3D,
    c: GpuVertex3D,
    texture_index: u32 = invalid_texture_index,
    normal_texture_index: u32 = invalid_texture_index,
    material_ambient: f32 = 1.0,
    material_diffuse: f32 = 1.0,
    material_roughness: f32 = 1.0,
    material_metallic: f32 = 0.0,
    material_emissive: u32 = Color.black.toRgba32(),
    material_emissive_strength: f32 = 0.0,
};

pub const GpuPoint3D = extern struct {
    x: f32,
    y: f32,
    z: f32,
    world_x: f32,
    world_y: f32,
    world_z: f32,
    size: f32,
    rgba: u32,
};

pub const GpuLine3D = extern struct {
    ax: f32,
    ay: f32,
    az: f32,
    bx: f32,
    by: f32,
    bz: f32,
    world_ax: f32,
    world_ay: f32,
    world_az: f32,
    world_bx: f32,
    world_by: f32,
    world_bz: f32,
    width: f32,
    rgba: u32,
};

pub const invalid_texture_index = std.math.maxInt(u32);

pub const GpuTexture = extern struct {
    width: u32,
    height: u32,
    pixel_start: u32,
    pixel_count: u32,
};

pub const GpuLight = extern struct {
    kind: u32,
    direction_x: f32,
    direction_y: f32,
    direction_z: f32,
    position_x: f32,
    position_y: f32,
    position_z: f32,
    ambient: f32,
    diffuse: f32,
    range: f32,
    attenuation: f32,
    inner_angle: f32,
    outer_angle: f32,
};

pub const GpuTileRange = extern struct {
    tile_x: u16,
    tile_y: u16,
    strip_start: u32,
    strip_count: u32,
};

pub const GpuTileBounds = extern struct {
    x0: u16 = 0,
    y0: u16 = 0,
    x1: u16 = 0,
    y1: u16 = 0,

    pub fn isEmpty(self: GpuTileBounds) bool {
        return self.x0 >= self.x1 or self.y0 >= self.y1;
    }

    pub fn width(self: GpuTileBounds) u16 {
        return if (self.isEmpty()) 0 else self.x1 - self.x0;
    }

    pub fn height(self: GpuTileBounds) u16 {
        return if (self.isEmpty()) 0 else self.y1 - self.y0;
    }
};

pub const GpuBatchDebugDump = struct {
    strips: usize = 0,
    tile_ranges: usize = 0,
    tile_bounds: GpuTileBounds = .{},
    triangles: usize = 0,
    points: usize = 0,
    lines: usize = 0,
    textures: usize = 0,
    texture_pixels: usize = 0,
    lights: usize = 0,
    upload_bytes: usize = 0,
    draw_calls: usize = 0,
    pipeline_switches: usize = 0,
    texture_binds: usize = 0,
    lighting_enabled: bool = false,
};

pub const GpuDeviceDebugDump = struct {
    backend: BackendKind,
    commands: usize = 0,
    render_2d_commands: usize = 0,
    render_3d_commands: usize = 0,
    batches: usize = 0,
    strips: usize = 0,
    tile_ranges: usize = 0,
    triangles: usize = 0,
    points: usize = 0,
    lines: usize = 0,
    textures: usize = 0,
    texture_pixels: usize = 0,
    lights: usize = 0,
    upload_bytes: usize = 0,
    draw_calls: usize = 0,
    pipeline_switches: usize = 0,
    texture_binds: usize = 0,
    lighting_enabled_batches: usize = 0,
};

pub const GpuBatch = struct {
    strips: std.ArrayList(GpuStrip) = .empty,
    tile_ranges: std.ArrayList(GpuTileRange) = .empty,
    tile_bounds: GpuTileBounds = .{},
    triangles: std.ArrayList(GpuTriangle) = .empty,
    points: std.ArrayList(GpuPoint3D) = .empty,
    lines: std.ArrayList(GpuLine3D) = .empty,
    textures: std.ArrayList(GpuTexture) = .empty,
    texture_pixels: std.ArrayList(u32) = .empty,
    lights: std.ArrayList(GpuLight) = .empty,
    lighting_enabled: bool = false,

    pub fn deinit(self: *GpuBatch, allocator: std.mem.Allocator) void {
        self.lights.deinit(allocator);
        self.texture_pixels.deinit(allocator);
        self.textures.deinit(allocator);
        self.lines.deinit(allocator);
        self.points.deinit(allocator);
        self.triangles.deinit(allocator);
        self.tile_ranges.deinit(allocator);
        self.strips.deinit(allocator);
        self.* = undefined;
    }

    pub fn debugDump(self: *const GpuBatch) GpuBatchDebugDump {
        return .{
            .strips = self.strips.items.len,
            .tile_ranges = self.tile_ranges.items.len,
            .tile_bounds = self.tile_bounds,
            .triangles = self.triangles.items.len,
            .points = self.points.items.len,
            .lines = self.lines.items.len,
            .textures = self.textures.items.len,
            .texture_pixels = self.texture_pixels.items.len,
            .lights = self.lights.items.len,
            .upload_bytes = self.uploadBytes(),
            .draw_calls = self.drawCallEstimate(),
            .pipeline_switches = self.pipelineSwitchEstimate(),
            .texture_binds = self.textures.items.len,
            .lighting_enabled = self.lighting_enabled,
        };
    }

    pub fn uploadBytes(self: *const GpuBatch) usize {
        return self.strips.items.len * ShaderContract.strip_size +
            self.tile_ranges.items.len * @sizeOf(GpuTileRange) +
            self.triangles.items.len * ShaderContract.triangle_size +
            self.points.items.len * ShaderContract.point3d_size +
            self.lines.items.len * ShaderContract.line3d_size +
            self.textures.items.len * ShaderContract.texture_size +
            self.texture_pixels.items.len * @sizeOf(u32) +
            self.lights.items.len * ShaderContract.light_size;
    }

    pub fn drawCallEstimate(self: *const GpuBatch) usize {
        var count: usize = 0;
        if (self.strips.items.len != 0) count += 1;
        if (self.triangles.items.len != 0) count += 1;
        if (self.points.items.len != 0) count += 1;
        if (self.lines.items.len != 0) count += 1;
        return count;
    }

    pub fn pipelineSwitchEstimate(self: *const GpuBatch) usize {
        var count: usize = 0;
        if (self.strips.items.len != 0) count += 1;
        if (self.triangles.items.len != 0 or self.points.items.len != 0 or self.lines.items.len != 0) count += 1;
        return count;
    }

    fn appendTexture(self: *GpuBatch, allocator: std.mem.Allocator, texture: scene3d.Texture) !u32 {
        const texture_index: u32 = @intCast(self.textures.items.len);
        const pixel_start: u32 = @intCast(self.texture_pixels.items.len);
        try self.texture_pixels.ensureUnusedCapacity(allocator, texture.pixels.len);
        for (texture.pixels) |pixel| {
            self.texture_pixels.appendAssumeCapacity(pixel.toRgba32());
        }
        try self.textures.append(allocator, .{
            .width = texture.width,
            .height = texture.height,
            .pixel_start = pixel_start,
            .pixel_count = @intCast(texture.pixels.len),
        });
        return texture_index;
    }

    fn buildLightsFromScene(self: *GpuBatch, allocator: std.mem.Allocator, scene: *const Scene3D) !void {
        self.lights.clearRetainingCapacity();
        self.lighting_enabled = scene.lighting_enabled;
        if (!scene.lighting_enabled) return;
        try self.lights.ensureUnusedCapacity(allocator, 1 + scene.lights.items.len);
        self.lights.appendAssumeCapacity(gpuLightFromSceneLight(scene.light));
        for (scene.lights.items) |light| {
            self.lights.appendAssumeCapacity(gpuLightFromSceneLight(light));
        }
    }

    pub fn buildTileRanges(self: *GpuBatch, allocator: std.mem.Allocator) !void {
        self.tile_ranges.clearRetainingCapacity();
        self.tile_bounds = .{};
        if (self.strips.items.len == 0) return;

        // Strips must already be in tile order. Tile ranges point into the strip
        // array without copying, giving backends a cheap outer loop over touched
        // tiles and an inner loop over the spans that belong to that tile.
        var start: usize = 0;
        var current_x = self.strips.items[0].x / Tile.width;
        var current_y = self.strips.items[0].y / Tile.height;
        self.tile_bounds = .{
            .x0 = @intCast(current_x),
            .y0 = @intCast(current_y),
            .x1 = @intCast(current_x + 1),
            .y1 = @intCast(current_y + 1),
        };

        var i: usize = 1;
        while (i < self.strips.items.len) : (i += 1) {
            const tile_x = self.strips.items[i].x / Tile.width;
            const tile_y = self.strips.items[i].y / Tile.height;
            self.includeTile(tile_x, tile_y);
            if (tile_x != current_x or tile_y != current_y) {
                try self.tile_ranges.append(allocator, .{
                    .tile_x = @intCast(current_x),
                    .tile_y = @intCast(current_y),
                    .strip_start = @intCast(start),
                    .strip_count = @intCast(i - start),
                });
                start = i;
                current_x = tile_x;
                current_y = tile_y;
            }
        }

        try self.tile_ranges.append(allocator, .{
            .tile_x = @intCast(current_x),
            .tile_y = @intCast(current_y),
            .strip_start = @intCast(start),
            .strip_count = @intCast(self.strips.items.len - start),
        });
    }

    fn includeTile(self: *GpuBatch, tile_x: u32, tile_y: u32) void {
        self.tile_bounds.x0 = @min(self.tile_bounds.x0, @as(u16, @intCast(tile_x)));
        self.tile_bounds.y0 = @min(self.tile_bounds.y0, @as(u16, @intCast(tile_y)));
        self.tile_bounds.x1 = @max(self.tile_bounds.x1, @as(u16, @intCast(tile_x + 1)));
        self.tile_bounds.y1 = @max(self.tile_bounds.y1, @as(u16, @intCast(tile_y + 1)));
    }

    pub fn build2DFromScene(
        self: *GpuBatch,
        allocator: std.mem.Allocator,
        scene: *const Scene2D,
        target_width: u32,
        target_height: u32,
    ) !void {
        self.strips.clearRetainingCapacity();
        self.tile_ranges.clearRetainingCapacity();
        self.tile_bounds = .{};

        var strips = try scene.buildSparseStrips(allocator, target_width, target_height);
        defer strips.deinit(allocator);
        try orderStripsByTile(allocator, strips.items);

        // Convert Scene2D strips into the packed backend representation. Blend
        // modes are stored as integers because this batch is also consumed by
        // extern shader-facing structs.
        try self.strips.ensureTotalCapacity(allocator, strips.items.len);
        for (strips.items) |strip| {
            self.strips.appendAssumeCapacity(.{
                .x = strip.x,
                .y = strip.y,
                .width = strip.width,
                .blend_mode = @intFromEnum(strip.blend_mode),
                .rgba = strip.color.toRgba32(),
            });
        }
        try self.buildTileRanges(allocator);
    }

    pub fn build3DFromScene(
        self: *GpuBatch,
        allocator: std.mem.Allocator,
        scene: *const Scene3D,
    ) !void {
        self.triangles.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        self.textures.clearRetainingCapacity();
        self.texture_pixels.clearRetainingCapacity();
        self.lights.clearRetainingCapacity();

        try self.buildLightsFromScene(allocator, scene);
        try self.triangles.ensureTotalCapacity(allocator, scene.triangles.items.len);
        try self.points.ensureTotalCapacity(allocator, scene.points.items.len);
        try self.lines.ensureTotalCapacity(allocator, scene.lines.items.len);
        // 3D encoding performs camera projection and capability-neutral resource
        // packing up front. Backends receive only visible primitives in normalized
        // device coordinates plus enough world-space data for lighting.
        for (scene.triangles.items) |tri| {
            if (!scene3d.projectedTriangleVisible(tri, scene.camera, scene.cull_mode)) continue;
            const colors = scene3d.shadeTriangleColors(tri, scene);
            const base_colors = tri.vertexColors();
            const projected = scene3d.projectTriangle(tri, scene.camera);
            const uvs = tri.uvs orelse [3]math.Vec2{ .{}, .{}, .{} };
            const normals = triangleNormals(tri);
            const material = triangleMaterial(tri, scene);
            const texture_index = try appendTriangleTexture(self, allocator, tri, scene);
            const normal_texture_index = try appendTriangleNormalTexture(self, allocator, tri, scene);
            self.triangles.appendAssumeCapacity(.{
                .a = .{ .x = projected[0].x, .y = projected[0].y, .z = projected[0].z, .world_x = tri.positions[0].x, .world_y = tri.positions[0].y, .world_z = tri.positions[0].z, .u = uvs[0].x, .v = uvs[0].y, .nx = normals[0].x, .ny = normals[0].y, .nz = normals[0].z, .base_rgba = base_colors[0].toRgba32(), .rgba = colors[0].toRgba32() },
                .b = .{ .x = projected[1].x, .y = projected[1].y, .z = projected[1].z, .world_x = tri.positions[1].x, .world_y = tri.positions[1].y, .world_z = tri.positions[1].z, .u = uvs[1].x, .v = uvs[1].y, .nx = normals[1].x, .ny = normals[1].y, .nz = normals[1].z, .base_rgba = base_colors[1].toRgba32(), .rgba = colors[1].toRgba32() },
                .c = .{ .x = projected[2].x, .y = projected[2].y, .z = projected[2].z, .world_x = tri.positions[2].x, .world_y = tri.positions[2].y, .world_z = tri.positions[2].z, .u = uvs[2].x, .v = uvs[2].y, .nx = normals[2].x, .ny = normals[2].y, .nz = normals[2].z, .base_rgba = base_colors[2].toRgba32(), .rgba = colors[2].toRgba32() },
                .texture_index = texture_index,
                .normal_texture_index = normal_texture_index,
                .material_ambient = material.ambient,
                .material_diffuse = material.diffuse,
                .material_roughness = material.roughness,
                .material_metallic = material.metallic,
                .material_emissive = material.emissive.toRgba32(),
                .material_emissive_strength = material.emissive_strength,
            });
        }
        for (scene.points.items) |point| {
            if (!scene3d.projectedPointVisible(point, scene.camera)) continue;
            const projected = scene3d.projectPoint(point, scene.camera);
            self.points.appendAssumeCapacity(.{
                .x = projected.x,
                .y = projected.y,
                .z = projected.z,
                .world_x = point.position.x,
                .world_y = point.position.y,
                .world_z = point.position.z,
                .size = point.size,
                .rgba = point.color.toRgba32(),
            });
        }
        for (scene.lines.items) |line| {
            const projected = scene3d.projectLine(line, scene.camera);
            const clipped = clipLineToNdc(projected[0], projected[1]) orelse continue;
            self.lines.appendAssumeCapacity(.{
                .ax = clipped[0].x,
                .ay = clipped[0].y,
                .az = clipped[0].z,
                .bx = clipped[1].x,
                .by = clipped[1].y,
                .bz = clipped[1].z,
                .world_ax = line.start.x,
                .world_ay = line.start.y,
                .world_az = line.start.z,
                .world_bx = line.end.x,
                .world_by = line.end.y,
                .world_bz = line.end.z,
                .width = line.width,
                .rgba = line.color.toRgba32(),
            });
        }
    }
};

pub const GpuDevice = struct {
    allocator: std.mem.Allocator,
    backend: BackendKind,
    submit_backend: ?Backend = null,
    limits: Limits = .{},
    commands: std.ArrayList(GpuCommand) = .empty,
    batches: std.ArrayList(GpuBatch) = .empty,

    pub fn init(allocator: std.mem.Allocator, backend: BackendKind) GpuDevice {
        return initWithLimits(allocator, backend, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, backend: BackendKind, limits: Limits) GpuDevice {
        return .{ .allocator = allocator, .backend = backend, .limits = limits };
    }

    pub fn setBackend(self: *GpuDevice, backend: Backend) void {
        self.submit_backend = backend;
        self.backend = .external;
    }

    pub fn deinit(self: *GpuDevice) void {
        for (self.batches.items) |*batch| {
            batch.deinit(self.allocator);
        }
        self.batches.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn isAvailable(self: *const GpuDevice) bool {
        return self.backend != .none;
    }

    pub fn debugDump(self: *const GpuDevice) GpuDeviceDebugDump {
        var dump = GpuDeviceDebugDump{
            .backend = self.backend,
            .commands = self.commands.items.len,
            .batches = self.batches.items.len,
        };
        for (self.commands.items) |command| {
            switch (command.kind) {
                .render_2d => dump.render_2d_commands += 1,
                .render_3d => dump.render_3d_commands += 1,
            }
        }
        for (self.batches.items) |*batch| {
            const batch_dump = batch.debugDump();
            dump.strips += batch_dump.strips;
            dump.tile_ranges += batch_dump.tile_ranges;
            dump.triangles += batch_dump.triangles;
            dump.points += batch_dump.points;
            dump.lines += batch_dump.lines;
            dump.textures += batch_dump.textures;
            dump.texture_pixels += batch_dump.texture_pixels;
            dump.lights += batch_dump.lights;
            dump.upload_bytes += batch_dump.upload_bytes;
            dump.draw_calls += batch_dump.draw_calls;
            dump.pipeline_switches += batch_dump.pipeline_switches;
            dump.texture_binds += batch_dump.texture_binds;
            if (batch_dump.lighting_enabled) dump.lighting_enabled_batches += 1;
        }
        return dump;
    }

    pub fn buildRenderGraph(self: *const GpuDevice, allocator: std.mem.Allocator) !render_graph.RenderGraph {
        return try self.buildRenderGraphWithOptions(allocator, .{});
    }

    pub fn buildRenderGraphWithOptions(self: *const GpuDevice, allocator: std.mem.Allocator, options: RenderGraphOptions) !render_graph.RenderGraph {
        var graph = render_graph.RenderGraph.init(allocator);
        errdefer graph.deinit();

        // Commands are modeled as a target chain: each queued render reads the
        // previous target and writes a fresh transient target, then the final pass
        // copies into the external target. This exposes transient reuse and
        // synchronization points without requiring backend-specific resources.
        const external_target = try graph.addResource(.{
            .label = "external-target",
            .kind = .texture,
            .transient = false,
            .external = true,
        });
        var previous_target = external_target;

        for (self.commands.items) |command| {
            const batch_index = command.batch_index orelse return error.MissingBatch;
            if (batch_index >= self.batches.items.len) return error.MissingBatch;
            const batch = &self.batches.items[batch_index];

            var reads: std.ArrayList(render_graph.ResourceHandle) = .empty;
            defer reads.deinit(allocator);
            try reads.append(allocator, previous_target);
            try appendBatchResourcesToGraph(&graph, allocator, &reads, command.kind, batch);

            const pass_target = try graph.addResource(.{
                .label = "queued-target",
                .kind = .texture,
            });
            _ = try graph.addPass(.{
                .label = switch (command.kind) {
                    .render_2d => "queued-2d-render",
                    .render_3d => "queued-3d-render",
                },
                .kind = .render,
                .reads = reads.items,
                .writes = &.{pass_target},
            });
            previous_target = pass_target;
        }

        if (self.commands.items.len != 0 and options.picking_pass) {
            const picking_buffer = try graph.addResource(.{
                .label = "picking-buffer",
                .kind = .texture,
            });
            _ = try graph.addPass(.{
                .label = "picking-pass",
                .kind = .render,
                .reads = &.{previous_target},
                .writes = &.{picking_buffer},
            });
        }

        if (self.commands.items.len != 0 and options.debug_pass) {
            const debug_overlay = try graph.addResource(.{
                .label = "debug-overlay",
                .kind = .texture,
            });
            _ = try graph.addPass(.{
                .label = "debug-pass",
                .kind = .debug,
                .reads = &.{previous_target},
                .writes = &.{debug_overlay},
            });
            previous_target = debug_overlay;
        }

        if (self.commands.items.len != 0) {
            _ = try graph.addPass(.{
                .label = "present",
                .kind = .copy,
                .reads = &.{previous_target},
                .writes = &.{external_target},
                .side_effect = true,
            });
        }

        return graph;
    }

    pub fn canAccept2D(self: *const GpuDevice, scene: *const Scene2D, target: *const Image) bool {
        const caps = self.capabilities();
        return self.isAvailable() and
            caps.render_2d and
            scene.primitives.items.len <= self.limits.max_2d_primitives and
            target.width <= self.limits.max_target_width and
            target.height <= self.limits.max_target_height;
    }

    pub fn canAccept3D(self: *const GpuDevice, scene: *const Scene3D, target: *const Image) bool {
        const caps = self.capabilities();
        return self.isAvailable() and
            caps.render_3d and
            self.sceneFits3DCapabilities(scene, caps) and
            scene.triangles.items.len <= self.limits.max_3d_triangles and
            scene.points.items.len <= self.limits.max_3d_points and
            scene.lines.items.len <= self.limits.max_3d_lines and
            target.width <= self.limits.max_target_width and
            target.height <= self.limits.max_target_height;
    }

    fn capabilities(self: *const GpuDevice) BackendCapabilities {
        if (self.submit_backend) |backend| return backend.capabilities;
        return switch (self.backend) {
            .none => .{ .render_2d = false, .render_3d = false, .point_cloud_3d = false, .line_3d = false, .textured_3d = false, .normal_mapped_3d = false, .lit_3d = false },
            .external => .{},
        };
    }

    fn sceneFits3DCapabilities(self: *const GpuDevice, scene: *const Scene3D, caps: BackendCapabilities) bool {
        _ = self;
        if (scene.lighting_enabled and !caps.lit_3d) return false;
        if (scene.points.items.len != 0 and !caps.point_cloud_3d) return false;
        if (scene.lines.items.len != 0 and !caps.line_3d) return false;
        if (caps.textured_3d and caps.normal_mapped_3d) return true;
        for (scene.triangles.items) |triangle| {
            if (!caps.textured_3d and (triangle.texture != null or triangle.texture_handle != null)) return false;
            if (!caps.normal_mapped_3d and (triangle.normal_texture != null or triangle.normal_texture_handle != null)) return false;
        }
        return true;
    }

    pub fn enqueue2D(self: *GpuDevice, scene: *const Scene2D, target: *const Image) !void {
        const batch_index = self.batches.items.len;
        try self.batches.append(self.allocator, .{});
        errdefer {
            var batch = self.batches.pop().?;
            batch.deinit(self.allocator);
        }

        try self.batches.items[batch_index].build2DFromScene(self.allocator, scene, target.width, target.height);

        try self.commands.append(self.allocator, .{
            .kind = .render_2d,
            .primitive_count = scene.primitives.items.len,
            .target_width = target.width,
            .target_height = target.height,
            .batch_index = batch_index,
        });
    }

    pub fn enqueue3D(self: *GpuDevice, scene: *const Scene3D, target: *const Image) !void {
        const batch_index = self.batches.items.len;
        try self.batches.append(self.allocator, .{});
        errdefer {
            var batch = self.batches.pop().?;
            batch.deinit(self.allocator);
        }

        try self.batches.items[batch_index].build3DFromScene(self.allocator, scene);

        try self.commands.append(self.allocator, .{
            .kind = .render_3d,
            .primitive_count = scene.triangles.items.len + scene.points.items.len + scene.lines.items.len,
            .target_width = target.width,
            .target_height = target.height,
            .batch_index = batch_index,
        });
    }

    pub fn clearCommands(self: *GpuDevice) void {
        for (self.batches.items) |*batch| {
            batch.deinit(self.allocator);
        }
        self.batches.clearRetainingCapacity();
        self.commands.clearRetainingCapacity();
    }

    pub fn submitQueued(self: *GpuDevice) !void {
        const backend = self.submit_backend orelse return error.BackendUnavailable;
        for (self.commands.items) |command| {
            const batch_index = command.batch_index orelse return error.MissingBatch;
            if (batch_index >= self.batches.items.len) return error.MissingBatch;
            const batch = &self.batches.items[batch_index];
            // Recheck capabilities at submit time as a guard against manual batch
            // mutation or backend swaps after enqueue.
            if (!batchFitsCapabilities(command, batch, backend.capabilities)) return error.BackendUnsupportedFeature;
            try backend.submit(command, batch);
        }
        self.clearCommands();
    }
};

fn batchFitsCapabilities(command: GpuCommand, batch: *const GpuBatch, caps: BackendCapabilities) bool {
    return switch (command.kind) {
        .render_2d => caps.render_2d,
        .render_3d => caps.render_3d and batchFits3DCapabilities(batch, caps),
    };
}

fn batchFits3DCapabilities(batch: *const GpuBatch, caps: BackendCapabilities) bool {
    if (batch.lighting_enabled and !caps.lit_3d) return false;
    if (batch.points.items.len != 0 and !caps.point_cloud_3d) return false;
    if (batch.lines.items.len != 0 and !caps.line_3d) return false;
    if (caps.textured_3d and caps.normal_mapped_3d) return true;
    for (batch.triangles.items) |triangle| {
        if (!caps.textured_3d and triangle.texture_index != invalid_texture_index) return false;
        if (!caps.normal_mapped_3d and triangle.normal_texture_index != invalid_texture_index) return false;
    }
    return true;
}

fn appendTriangleTexture(batch: *GpuBatch, allocator: std.mem.Allocator, triangle: scene3d.Triangle3D, scene: *const Scene3D) !u32 {
    if (triangle.texture_handle) |handle| {
        if (scene.textureView(handle)) |texture| {
            return try batch.appendTexture(allocator, texture);
        }
    }
    if (triangle.texture) |texture| {
        return try batch.appendTexture(allocator, texture);
    }
    return invalid_texture_index;
}

fn appendTriangleNormalTexture(batch: *GpuBatch, allocator: std.mem.Allocator, triangle: scene3d.Triangle3D, scene: *const Scene3D) !u32 {
    if (triangle.normal_texture_handle) |handle| {
        if (scene.textureView(handle)) |texture| {
            return try batch.appendTexture(allocator, texture);
        }
    }
    if (triangle.normal_texture) |texture| {
        return try batch.appendTexture(allocator, texture);
    }
    return invalid_texture_index;
}

fn clipLineToNdc(a: math.Vec3, b: math.Vec3) ?[2]math.Vec3 {
    var t0: f32 = 0.0;
    var t1: f32 = 1.0;
    const d = b.sub(a);
    if (!clipLinePlane(-d.x, a.x + 1.0, &t0, &t1)) return null;
    if (!clipLinePlane(d.x, 1.0 - a.x, &t0, &t1)) return null;
    if (!clipLinePlane(-d.y, a.y + 1.0, &t0, &t1)) return null;
    if (!clipLinePlane(d.y, 1.0 - a.y, &t0, &t1)) return null;
    if (!clipLinePlane(-d.z, a.z, &t0, &t1)) return null;
    if (!clipLinePlane(d.z, 1.0 - a.z, &t0, &t1)) return null;
    return .{
        a.add(d.scale(t0)),
        a.add(d.scale(t1)),
    };
}

fn clipLinePlane(p: f32, q: f32, t0: *f32, t1: *f32) bool {
    const epsilon: f32 = 0.000001;
    if (@abs(p) <= epsilon) return q >= 0.0;
    const r = q / p;
    if (p < 0.0) {
        if (r > t1.*) return false;
        if (r > t0.*) t0.* = r;
    } else {
        if (r < t0.*) return false;
        if (r < t1.*) t1.* = r;
    }
    return true;
}

fn triangleNormals(triangle: scene3d.Triangle3D) [3]math.Vec3 {
    if (triangle.normals) |normals| return .{
        normals[0].normalize(),
        normals[1].normalize(),
        normals[2].normalize(),
    };
    const normal = faceNormal(triangle);
    return .{ normal, normal, normal };
}

fn faceNormal(triangle: scene3d.Triangle3D) math.Vec3 {
    const a = triangle.positions[0];
    const b = triangle.positions[1];
    const c = triangle.positions[2];
    return b.sub(a).cross(c.sub(a)).normalize();
}

fn triangleMaterial(triangle: scene3d.Triangle3D, scene: *const Scene3D) scene3d.Material {
    if (triangle.material_handle) |handle| {
        if (scene.materialView(handle)) |material| return normalizeMaterial(material);
    }
    return normalizeMaterial(triangle.material);
}

fn normalizeMaterial(material: scene3d.Material) scene3d.Material {
    return .{
        .ambient = @max(0.0, material.ambient),
        .diffuse = @max(0.0, material.diffuse),
        .roughness = @min(1.0, @max(0.0, material.roughness)),
        .metallic = @min(1.0, @max(0.0, material.metallic)),
        .emissive = material.emissive,
        .emissive_strength = @max(0.0, material.emissive_strength),
    };
}

fn gpuLightFromSceneLight(light: scene3d.Light) GpuLight {
    const normalized = normalizeLight(light);
    return .{
        .kind = switch (normalized.kind) {
            .directional => 0,
            .point => 1,
            .spot => 2,
        },
        .direction_x = normalized.direction.x,
        .direction_y = normalized.direction.y,
        .direction_z = normalized.direction.z,
        .position_x = normalized.position.x,
        .position_y = normalized.position.y,
        .position_z = normalized.position.z,
        .ambient = normalized.ambient,
        .diffuse = normalized.diffuse,
        .range = normalized.range,
        .attenuation = normalized.attenuation,
        .inner_angle = normalized.inner_angle,
        .outer_angle = normalized.outer_angle,
    };
}

fn normalizeLight(light: scene3d.Light) scene3d.Light {
    return .{
        .kind = light.kind,
        .direction = switch (light.kind) {
            .directional, .spot => light.direction.normalize(),
            .point => light.direction,
        },
        .position = light.position,
        .ambient = @max(0.0, light.ambient),
        .diffuse = @max(0.0, light.diffuse),
        .range = @max(0.0, light.range),
        .attenuation = @max(0.0, light.attenuation),
        .inner_angle = @max(0.0, @min(light.inner_angle, std.math.pi)),
        .outer_angle = @max(0.0, @min(@max(light.inner_angle, light.outer_angle), std.math.pi)),
    };
}

fn appendBatchResourcesToGraph(
    graph: *render_graph.RenderGraph,
    allocator: std.mem.Allocator,
    reads: *std.ArrayList(render_graph.ResourceHandle),
    kind: CommandKind,
    batch: *const GpuBatch,
) !void {
    switch (kind) {
        .render_2d => {
            if (batch.strips.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "2d-strips", .kind = .buffer }));
            }
            if (batch.tile_ranges.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "2d-tile-ranges", .kind = .buffer }));
            }
        },
        .render_3d => {
            if (batch.triangles.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "3d-triangles", .kind = .buffer }));
            }
            if (batch.points.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "3d-points", .kind = .buffer }));
            }
            if (batch.lines.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "3d-lines", .kind = .buffer }));
            }
            if (batch.textures.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "3d-textures", .kind = .buffer }));
            }
            if (batch.texture_pixels.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "3d-texture-pixels", .kind = .buffer }));
            }
            if (batch.lights.items.len != 0) {
                try reads.append(allocator, try graph.addResource(.{ .label = "3d-lights", .kind = .buffer }));
            }
        },
    }
}

pub fn stripLessThanTileOrder(_: void, lhs: Strip, rhs: Strip) bool {
    const lhs_tile_y = lhs.y / Tile.height;
    const rhs_tile_y = rhs.y / Tile.height;
    if (lhs_tile_y != rhs_tile_y) return lhs_tile_y < rhs_tile_y;
    const lhs_tile_x = lhs.x / Tile.width;
    const rhs_tile_x = rhs.x / Tile.width;
    if (lhs_tile_x != rhs_tile_x) return lhs_tile_x < rhs_tile_x;
    if (lhs.y != rhs.y) return lhs.y < rhs.y;
    return lhs.x < rhs.x;
}

pub fn orderStripsByTile(allocator: std.mem.Allocator, strips: []Strip) !void {
    if (strips.len < 2 or stripsInTileOrder(strips)) return;
    // Stable bucket ordering keeps pixels deterministic for strips in the same
    // tile while avoiding a full comparison sort for large vector scenes.
    var max_tile_x: u32 = 0;
    var max_tile_y: u32 = 0;
    for (strips) |strip| {
        max_tile_x = @max(max_tile_x, strip.x / Tile.width);
        max_tile_y = @max(max_tile_y, strip.y / Tile.height);
    }
    const tiles_w = max_tile_x + 1;
    const tiles_h = max_tile_y + 1;
    const tile_count = try std.math.mul(u32, tiles_w, tiles_h);
    var counts = try allocator.alloc(usize, tile_count);
    defer allocator.free(counts);
    @memset(counts, 0);

    for (strips) |strip| {
        counts[tileIndex(strip, tiles_w)] += 1;
    }

    var offsets = try allocator.alloc(usize, tile_count);
    defer allocator.free(offsets);
    var sum: usize = 0;
    for (counts, 0..) |count, i| {
        offsets[i] = sum;
        sum += count;
    }

    var write_offsets = try allocator.dupe(usize, offsets);
    defer allocator.free(write_offsets);
    var ordered = try allocator.alloc(Strip, strips.len);
    defer allocator.free(ordered);
    for (strips) |strip| {
        const index = tileIndex(strip, tiles_w);
        ordered[write_offsets[index]] = strip;
        write_offsets[index] += 1;
    }

    for (counts, 0..) |count, i| {
        if (count > 1) {
            std.sort.pdq(Strip, ordered[offsets[i] .. offsets[i] + count], {}, stripLessThanTileOrder);
        }
    }
    @memcpy(strips, ordered);
}

fn tileIndex(strip: Strip, tiles_w: u32) usize {
    const tile_x = strip.x / Tile.width;
    const tile_y = strip.y / Tile.height;
    return @as(usize, tile_y) * tiles_w + tile_x;
}

fn stripsInTileOrder(strips: []const Strip) bool {
    if (strips.len < 2) return true;
    var i: usize = 1;
    while (i < strips.len) : (i += 1) {
        if (stripLessThanTileOrder({}, strips[i], strips[i - 1])) return false;
    }
    return true;
}

test "GPU device records render commands without owning scene data" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    try std.testing.expectEqual(@as(usize, 1), gpu.commands.items.len);
    try std.testing.expectEqual(CommandKind.render_2d, gpu.commands.items[0].kind);
    try std.testing.expectEqual(@as(usize, 1), gpu.batches.items.len);
    try std.testing.expect(gpu.batches.items[0].strips.items.len > 0);
}

test "GPU device respects backend render capabilities" {
    const allocator = std.testing.allocator;
    var scene2 = Scene2D.init(allocator);
    defer scene2.deinit();
    try scene2.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);

    var scene3 = Scene3D.init(allocator);
    defer scene3.deinit();
    try scene3.addTriangle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .white });

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    const Sink = struct {
        fn submit(_: *anyopaque, _: GpuCommand, _: *const GpuBatch) !void {}
    };
    var sink: u8 = 0;
    var gpu = GpuDevice.init(allocator, .none);
    defer gpu.deinit();
    gpu.setBackend(.{
        .context = &sink,
        .submitFn = Sink.submit,
        .capabilities = .{ .render_2d = false, .render_3d = true },
    });
    try std.testing.expect(!gpu.canAccept2D(&scene2, &img));
    try std.testing.expect(gpu.canAccept3D(&scene3, &img));

    gpu.setBackend(.{
        .context = &sink,
        .submitFn = Sink.submit,
        .capabilities = .{ .render_2d = true, .render_3d = false },
    });
    try std.testing.expect(gpu.canAccept2D(&scene2, &img));
    try std.testing.expect(!gpu.canAccept3D(&scene3, &img));
}

test "GPU device rejects unsupported 3D scene features" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    const pixels = [_]Color{.white};
    const texture = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &pixels });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = texture,
        .normal_texture_handle = texture,
    });
    scene.setLight(.{ .direction = .{ .z = 1 } });

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    const Sink = struct {
        fn submit(_: *anyopaque, _: GpuCommand, _: *const GpuBatch) !void {}
    };
    var sink: u8 = 0;
    var gpu = GpuDevice.init(allocator, .none);
    defer gpu.deinit();

    gpu.setBackend(.{ .context = &sink, .submitFn = Sink.submit, .capabilities = .{ .textured_3d = false } });
    try std.testing.expect(!gpu.canAccept3D(&scene, &img));
    gpu.setBackend(.{ .context = &sink, .submitFn = Sink.submit, .capabilities = .{ .normal_mapped_3d = false } });
    try std.testing.expect(!gpu.canAccept3D(&scene, &img));
    gpu.setBackend(.{ .context = &sink, .submitFn = Sink.submit, .capabilities = .{ .lit_3d = false } });
    try std.testing.expect(!gpu.canAccept3D(&scene, &img));

    var points = Scene3D.init(allocator);
    defer points.deinit();
    try points.addPoint(.{ .position = .{ .z = 0.2 }, .color = .red });
    gpu.setBackend(.{ .context = &sink, .submitFn = Sink.submit, .capabilities = .{ .point_cloud_3d = false } });
    try std.testing.expect(!gpu.canAccept3D(&points, &img));

    var lines = Scene3D.init(allocator);
    defer lines.deinit();
    try lines.addLine(.{ .start = .{}, .end = .{ .x = 0.5, .z = 0.2 }, .color = .red });
    gpu.setBackend(.{ .context = &sink, .submitFn = Sink.submit, .capabilities = .{ .line_3d = false } });
    try std.testing.expect(!gpu.canAccept3D(&lines, &img));
}

test "GPU device rejects unsupported queued batches at submit boundary" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    const pixels = [_]Color{.white};
    const texture = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &pixels });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = texture,
    });

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    const Sink = struct {
        called: bool = false,

        fn submit(context: *anyopaque, _: GpuCommand, _: *const GpuBatch) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
        }
    };
    var sink = Sink{};
    var gpu = GpuDevice.init(allocator, .none);
    defer gpu.deinit();
    gpu.setBackend(.{
        .context = &sink,
        .submitFn = Sink.submit,
        .capabilities = .{ .textured_3d = false },
    });

    try gpu.enqueue3D(&scene, &img);
    try std.testing.expectError(error.BackendUnsupportedFeature, gpu.submitQueued());
    try std.testing.expect(!sink.called);
}

test "GPU 2D batches include strokes and triangles" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeLine(.{ .x = 1, .y = 1 }, .{ .x = 7, .y = 1 }, 2, .white);
    try scene.fillTriangle(.{
        .{ .x = 2, .y = 2 },
        .{ .x = 8, .y = 2 },
        .{ .x = 2, .y = 8 },
    }, .blue);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    try std.testing.expect(gpu.batches.items[0].strips.items.len > 2);
}

test "GPU 2D batches include anti-aliased line alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeLine(.{ .x = 1, .y = 2 }, .{ .x = 7, .y = 2 }, 2, .white);

    var img = try Image.init(allocator, 10, 6, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    var has_partial = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
    }
    try std.testing.expect(has_partial);
}

test "GPU 2D batches encode dashed line gaps" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedLine(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .white);

    var img = try Image.init(allocator, 16, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_first_dash = false;
    var has_gap = false;
    var has_second_dash = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) has_first_dash = true;
        if (strip.y == 4 and strip.x <= 5 and strip.x + strip.width > 5) has_gap = true;
        if (strip.y == 4 and strip.x <= 8 and strip.x + strip.width > 8) has_second_dash = true;
    }
    try std.testing.expect(has_first_dash);
    try std.testing.expect(!has_gap);
    try std.testing.expect(has_second_dash);
}

test "GPU 2D batches encode dashed line cap modes" {
    const allocator = std.testing.allocator;
    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeDashedLineCap(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .butt, .white);

    var img = try Image.init(allocator, 16, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&butt_scene, &img);

    var butt_gap_edge = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) butt_gap_edge = true;
    }

    gpu.clearCommands();
    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeDashedLineCap(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .square, .white);
    try gpu.enqueue2D(&square_scene, &img);

    var square_gap_edge = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) square_gap_edge = true;
    }

    try std.testing.expect(!butt_gap_edge);
    try std.testing.expect(square_gap_edge);
}

test "GPU 2D batches encode line cap modes" {
    const allocator = std.testing.allocator;
    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 12, .y = 4 }, 2, .butt, .white);

    var img = try Image.init(allocator, 16, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&butt_scene, &img);

    var butt_before_start = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) butt_before_start = true;
    }

    gpu.clearCommands();
    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 12, .y = 4 }, 2, .square, .white);
    try gpu.enqueue2D(&square_scene, &img);

    var square_before_start = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) square_before_start = true;
    }

    try std.testing.expect(!butt_before_start);
    try std.testing.expect(square_before_start);
}

test "GPU 2D batches include anti-aliased path alpha" {
    const allocator = std.testing.allocator;
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2.25, .y = 2.25 });
    try path.lineTo(.{ .x = 8.25, .y = 2.25 });
    try path.lineTo(.{ .x = 2.25, .y = 8.25 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .green, .non_zero);

    var img = try Image.init(allocator, 12, 12, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    var has_partial = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
    }
    try std.testing.expect(has_partial);
}

test "GPU 2D batches include anti-aliased stroked path alpha" {
    const allocator = std.testing.allocator;
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 10 });
    try path.quadTo(.{ .x = 8, .y = 2 }, .{ .x = 14, .y = 10 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePath(&path, 2, .white);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_partial = false;
    var has_full = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
        if (alpha == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "GPU 2D batches encode dashed stroked path gaps" {
    const allocator = std.testing.allocator;
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 13, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedPath(&path, 2, 3, 3, .white);

    var img = try Image.init(allocator, 16, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_first_dash = false;
    var has_gap = false;
    var has_second_dash = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) has_first_dash = true;
        if (strip.y == 4 and strip.x <= 5 and strip.x + strip.width > 5) has_gap = true;
        if (strip.y == 4 and strip.x <= 8 and strip.x + strip.width > 8) has_second_dash = true;
    }
    try std.testing.expect(has_first_dash);
    try std.testing.expect(!has_gap);
    try std.testing.expect(has_second_dash);
}

test "GPU 2D batches encode dashed stroked path cap modes" {
    const allocator = std.testing.allocator;
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 13, .y = 4 });

    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeDashedPathCap(&path, 2, 3, 3, .butt, .white);

    var img = try Image.init(allocator, 16, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&butt_scene, &img);

    var butt_gap_edge = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) butt_gap_edge = true;
    }

    gpu.clearCommands();
    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeDashedPathCap(&path, 2, 3, 3, .square, .white);
    try gpu.enqueue2D(&square_scene, &img);

    var square_gap_edge = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) square_gap_edge = true;
    }

    try std.testing.expect(!butt_gap_edge);
    try std.testing.expect(square_gap_edge);
}

test "GPU 2D batches encode stroked path cap modes" {
    const allocator = std.testing.allocator;
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 4 });
    try path.lineTo(.{ .x = 12, .y = 4 });

    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokePathCap(&path, 2, .butt, .white);

    var img = try Image.init(allocator, 16, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&butt_scene, &img);

    var butt_before_start = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) butt_before_start = true;
    }

    gpu.clearCommands();
    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokePathCap(&path, 2, .square, .white);
    try gpu.enqueue2D(&square_scene, &img);

    var square_before_start = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) square_before_start = true;
    }

    try std.testing.expect(!butt_before_start);
    try std.testing.expect(square_before_start);
}

test "GPU 2D batches include anti-aliased triangle alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillTriangle(.{
        .{ .x = 2.25, .y = 2.25 },
        .{ .x = 8.25, .y = 2.25 },
        .{ .x = 2.25, .y = 8.25 },
    }, .blue);

    var img = try Image.init(allocator, 12, 12, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    var has_partial = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
    }
    try std.testing.expect(has_partial);
}

test "GPU 2D batches receive clipped sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushClipRect(.{ .x = 2, .y = 2, .w = 2, .h = 2 });
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, .red);
    scene.popClip();

    var img = try Image.init(allocator, 8, 8, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    var pixels: usize = 0;
    for (gpu.batches.items[0].strips.items) |strip| {
        pixels += strip.width;
        try std.testing.expect(strip.x >= 2 and strip.x + strip.width <= 4);
        try std.testing.expect(strip.y >= 2 and strip.y < 4);
    }
    try std.testing.expectEqual(@as(usize, 4), pixels);
}

test "GPU 2D batches encode blend mode per strip" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushBlendMode(.multiply);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .red);
    scene.popBlendMode();

    var img = try Image.init(allocator, 2, 2, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    try std.testing.expectEqual(@as(u16, 3), gpu.batches.items[0].strips.items[0].blend_mode);
}

test "GPU 2D batches encode opacity-scaled alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushOpacity(0.5);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);

    var img = try Image.init(allocator, 2, 2, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    const alpha = (gpu.batches.items[0].strips.items[0].rgba >> 24) & 0xff;
    try std.testing.expectEqual(@as(u32, 128), alpha);
}

test "GPU 2D batches encode linear gradient colors" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 3, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    });

    var img = try Image.init(allocator, 4, 2, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    const strips = gpu.batches.items[0].strips.items;
    try std.testing.expectEqual(@as(usize, 3), strips.len);
    try std.testing.expect(strips[0].rgba != strips[2].rgba);
}

test "GPU 2D batches encode radial gradient colors" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRadialGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .center = .{ .x = 0.5, .y = 0.5 },
        .radius = 3,
        .inner_color = .red,
        .outer_color = .blue,
    });

    var img = try Image.init(allocator, 4, 2, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    const strips = gpu.batches.items[0].strips.items;
    try std.testing.expectEqual(@as(usize, 3), strips.len);
    try std.testing.expect(strips[0].rgba != strips[2].rgba);
}

test "GPU 2D batches encode sweep gradient colors" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillSweepGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .center = .{ .x = 1.5, .y = 1.5 },
        .start_color = .red,
        .end_color = .blue,
    });

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    const strips = gpu.batches.items[0].strips.items;
    try std.testing.expectEqual(@as(usize, 3), strips.len);
    try std.testing.expect(strips[0].rgba != strips[1].rgba);
    try std.testing.expect(strips[1].rgba != strips[2].rgba);
}

test "GPU 2D batches encode sampled image colors" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 2, 1, .transparent);
    defer src.deinit();
    src.writePixel(0, 0, .red);
    src.writePixel(1, 0, .blue);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillImageRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &src);

    var dst = try Image.init(allocator, 2, 1, .transparent);
    defer dst.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &dst);
    const strips = gpu.batches.items[0].strips.items;
    try std.testing.expectEqual(@as(usize, 2), strips.len);
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), strips[0].rgba);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), strips[1].rgba);
}

test "GPU 2D batches encode image atlas sub-rectangles" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 4, 1, .transparent);
    defer src.deinit();
    src.writePixel(0, 0, .red);
    src.writePixel(1, 0, .green);
    src.writePixel(2, 0, .blue);
    src.writePixel(3, 0, .white);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillImageSubRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &src, .{ .x = 1, .y = 0, .w = 2, .h = 1 });

    var img = try Image.init(allocator, 2, 1, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    const strips = gpu.batches.items[0].strips.items;
    try std.testing.expectEqual(@as(usize, 2), strips.len);
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), strips[0].rgba);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), strips[1].rgba);
}

test "GPU 2D batches encode masked rectangle alpha" {
    const allocator = std.testing.allocator;
    var mask = try Image.init(allocator, 2, 1, .transparent);
    defer mask.deinit();
    mask.writePixel(0, 0, Color.rgba(0, 0, 0, 128));
    mask.writePixel(1, 0, .transparent);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillMaskedRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .white, &mask);

    var img = try Image.init(allocator, 2, 1, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    const strips = gpu.batches.items[0].strips.items;
    try std.testing.expectEqual(@as(usize, 1), strips.len);
    const alpha = (strips[0].rgba >> 24) & 0xff;
    try std.testing.expectEqual(@as(u32, 128), alpha);
}

test "GPU 2D batches encode drop shadow alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.dropShadowRect(.{ .x = 4, .y = 4, .w = 4, .h = 4 }, .{ .x = 2, .y = 1 }, 2, .black);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_partial = false;
    var has_full = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
        if (alpha == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "GPU 2D batches encode ellipse alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, .blue);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_partial = false;
    var has_full = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
        if (alpha == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "GPU 2D batches encode stroked ellipse alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, 2, .blue);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_partial = false;
    var has_full = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
        if (alpha == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "GPU 2D batches encode arc sector coverage" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillArcSector(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, -std.math.pi / 2.0, std.math.pi / 2.0, .green);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_partial = false;
    var has_right = false;
    var has_left = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
        if (strip.y == 8 and strip.x <= 11 and strip.x + strip.width > 11) has_right = true;
        if (strip.y == 8 and strip.x <= 4 and strip.x + strip.width > 4) has_left = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_right);
    try std.testing.expect(!has_left);
}

test "GPU 2D batches encode stroked arc coverage" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeArc(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, 2, -std.math.pi / 2.0, std.math.pi / 2.0, .green);

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene, &img);

    var has_partial = false;
    var has_right = false;
    var has_left = false;
    var center_hit = false;
    for (gpu.batches.items[0].strips.items) |strip| {
        const alpha = (strip.rgba >> 24) & 0xff;
        if (alpha > 0 and alpha < 255) has_partial = true;
        if (strip.y == 8 and strip.x <= 12 and strip.x + strip.width > 12) has_right = true;
        if (strip.y == 8 and strip.x <= 4 and strip.x + strip.width > 4) has_left = true;
        if (strip.y == 8 and strip.x <= 8 and strip.x + strip.width > 8) center_hit = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_right);
    try std.testing.expect(!has_left);
    try std.testing.expect(!center_hit);
}

test "GPU 2D batches build tile-local strip ranges" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 14, .y = 0, .w = 6, .h = 1 }, .white);

    var img = try Image.init(allocator, 32, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue2D(&scene, &img);
    const batch = &gpu.batches.items[0];
    try std.testing.expectEqual(@as(usize, 2), batch.tile_ranges.items.len);
    try std.testing.expectEqual(@as(u16, 0), batch.tile_ranges.items[0].tile_x);
    try std.testing.expectEqual(@as(u16, 1), batch.tile_ranges.items[1].tile_x);
    try std.testing.expectEqual(@as(u16, 0), batch.tile_bounds.x0);
    try std.testing.expectEqual(@as(u16, 0), batch.tile_bounds.y0);
    try std.testing.expectEqual(@as(u16, 2), batch.tile_bounds.x1);
    try std.testing.expectEqual(@as(u16, 1), batch.tile_bounds.y1);

    for (batch.tile_ranges.items) |range| {
        const start: usize = range.strip_start;
        const end = start + range.strip_count;
        for (batch.strips.items[start..end]) |strip| {
            try std.testing.expectEqual(range.tile_x, strip.x / Tile.width);
            try std.testing.expectEqual(range.tile_y, strip.y / Tile.height);
        }
    }
}

test "GPU 2D batch builder matches queued device batch" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 14, .y = 0, .w = 6, .h = 1 }, .white);

    var img = try Image.init(allocator, 32, 16, .transparent);
    defer img.deinit();

    var manual: GpuBatch = .{};
    defer manual.deinit(allocator);
    try manual.build2DFromScene(allocator, &scene, img.width, img.height);

    var device = GpuDevice.init(allocator, .external);
    defer device.deinit();
    try device.enqueue2D(&scene, &img);
    const queued = &device.batches.items[0];

    try std.testing.expectEqual(manual.strips.items.len, queued.strips.items.len);
    try std.testing.expectEqual(manual.tile_ranges.items.len, queued.tile_ranges.items.len);
    try std.testing.expectEqual(manual.tile_bounds, queued.tile_bounds);
}

test "GPU device encodes 3D triangles into upload batches" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .blue,
    });

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue3D(&scene, &img);
    try std.testing.expectEqual(@as(usize, 1), gpu.commands.items.len);
    try std.testing.expectEqual(CommandKind.render_3d, gpu.commands.items[0].kind);
    try std.testing.expectEqual(@as(usize, 1), gpu.batches.items[0].triangles.items.len);
}

test "GPU 3D batch builder can be used without queueing a device command" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var batch = GpuBatch{};
    defer batch.deinit(allocator);
    try batch.build3DFromScene(allocator, &scene);

    try std.testing.expectEqual(@as(usize, 1), batch.triangles.items.len);
    try std.testing.expectEqual(@as(usize, 0), batch.textures.items.len);
}

test "GPU device encodes 3D point clouds into upload batches" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addPointCloud(.{ .points = &.{
        .{ .position = .{ .x = -0.25, .y = -0.25, .z = 0.2 }, .color = .red, .size = 2.0 },
        .{ .position = .{ .x = 0.25, .y = 0.25, .z = 0.3 }, .color = .green, .size = 3.0 },
        .{ .position = .{ .x = 2.0, .z = 0.2 }, .color = .blue, .size = 1.0 },
    } });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue3D(&scene, &img);
    try std.testing.expectEqual(@as(usize, 1), gpu.commands.items.len);
    try std.testing.expectEqual(@as(usize, 3), gpu.commands.items[0].primitive_count);
    try std.testing.expectEqual(@as(usize, 0), gpu.batches.items[0].triangles.items.len);
    try std.testing.expectEqual(@as(usize, 2), gpu.batches.items[0].points.items.len);
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), gpu.batches.items[0].points.items[0].rgba);
    try std.testing.expectEqual(@as(f32, 3.0), gpu.batches.items[0].points.items[1].size);
}

test "GPU device encodes 3D lines into upload batches" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addLine(.{
        .start = .{ .x = -0.4, .y = -0.25, .z = 0.2 },
        .end = .{ .x = 0.4, .y = 0.25, .z = 0.3 },
        .color = .blue,
        .width = 2.0,
    });
    try scene.addLine(.{
        .start = .{ .x = 2.0, .z = 0.2 },
        .end = .{ .x = 2.2, .z = 0.2 },
        .color = .red,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue3D(&scene, &img);
    try std.testing.expectEqual(@as(usize, 2), gpu.commands.items[0].primitive_count);
    try std.testing.expectEqual(@as(usize, 0), gpu.batches.items[0].triangles.items.len);
    try std.testing.expectEqual(@as(usize, 0), gpu.batches.items[0].points.items.len);
    try std.testing.expectEqual(@as(usize, 1), gpu.batches.items[0].lines.items.len);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), gpu.batches.items[0].lines.items[0].rgba);
    try std.testing.expectEqual(@as(f32, 2.0), gpu.batches.items[0].lines.items[0].width);
}

test "GPU 3D line batches clip lines to the NDC volume" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addLine(.{
        .start = .{ .x = -2.0, .z = 0.2 },
        .end = .{ .x = 0.5, .z = 0.2 },
        .color = .blue,
    });
    try scene.addLine(.{
        .start = .{ .x = -2.0, .y = 2.0, .z = 0.2 },
        .end = .{ .x = -1.5, .y = 2.0, .z = 0.2 },
        .color = .red,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();

    try gpu.enqueue3D(&scene, &img);
    try std.testing.expectEqual(@as(usize, 2), gpu.commands.items[0].primitive_count);
    try std.testing.expectEqual(@as(usize, 1), gpu.batches.items[0].lines.items.len);
    const line = gpu.batches.items[0].lines.items[0];
    try std.testing.expect(@abs(line.ax + 1.0) < 0.0001);
    try std.testing.expect(@abs(line.bx - 0.5) < 0.0001);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), line.rgba);
}

test "GPU 3D batches encode projected and shaded triangles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = -1 }, .ambient = 0.25, .diffuse = 0.75 });
    scene.setCamera(scene3d.Camera.perspectiveLookAt(
        .{ .z = 3 },
        .{},
        .{ .y = 1 },
        std.math.pi / 2.0,
        1.0,
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

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expect(tri.a.x > -1.0 and tri.a.x < 1.0);
    try std.testing.expect(tri.a.z > 0.0 and tri.a.z < 1.0);
    try std.testing.expectEqual(@as(u32, Color.rgba(64, 64, 64, 255).toRgba32()), tri.a.rgba);
}

test "GPU 3D triangle shader mirrors batch data contract" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const shader = try std.Io.Dir.cwd().readFileAlloc(io, "shaders/render_triangles.wgsl", allocator, .limited(64 * 1024));
    defer allocator.free(shader);
    inline for (.{
        "x: f32",
        "world_x: f32",
        "u: f32",
        "nx: f32",
        "base_rgba: u32",
        "texture_index: u32",
        "normal_texture_index: u32",
        "material_ambient: f32",
        "material_diffuse: f32",
        "material_roughness: f32",
        "material_metallic: f32",
        "material_emissive: u32",
        "material_emissive_strength: f32",
        "struct TextureInfo",
        "struct Light",
        "direction_x: f32",
        "position_x: f32",
        "@group(0) @binding(1) var<storage, read> textures",
        "@group(0) @binding(2) var<storage, read> texture_pixels",
        "@group(0) @binding(3) var<storage, read> lights",
        "@group(0) @binding(4) var<uniform> lighting_enabled",
        "fn sample_texture",
        "fn sample_normal",
        "fn light_intensity",
        "fn apply_material_color",
        "lighting_enabled == 0u",
        "sample_texture(in.texture_index, in.uv)",
        "sample_normal(in.normal_texture_index, in.uv, in.normal)",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, shader, needle) != null);
    }
}

test "README documents current backend contract" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const readme = try std.Io.Dir.cwd().readFileAlloc(io, "README.md", allocator, .limited(64 * 1024));
    defer allocator.free(readme);

    inline for (.{
        "backend capability declarations",
        "3D UV/world-position/normal/material/light/texture",
        "software backend consumes 3D batch UV",
        "normal-map",
        "raster-time shading",
        "CpuRenderer.render3D` builds the same 3D GPU batch",
        "The optional WebGPU backend is",
        "TargetOptions",
        "RenderPassOptions",
        "Backend Errors",
        "BackendUnavailable",
        "BackendUnsupportedFeature",
        "BackendTargetMismatch",
        "BackendTargetFormatMismatch",
        "MissingBatch",
        "Backend Integration",
        "WindowProvider",
        "setTargetViewWithFormat",
        "setDepthViewWithFormat",
        "setExternalTargetViewWithFormat",
        "setExternalDepthViewWithFormat",
        "acquireSwapchainTarget",
        "ensureDepthTargetForCurrentTarget",
        "present",
        "initStripsPipeline",
        "initTrianglesPipelineFromSource",
        "render3DToReadback",
        "renderScene3DToReadback",
        "renderScene3DToCurrentSwapchain",
        "waitForReadback",
        "Image.compare",
        "HybridRenderer",
        "Completion Status",
        "The AGENTS.md scope is covered by implementation, tests, and runnable examples",
        "Future enhancements outside the current completion gate",
        "Dawn/Metal",
        "CPU-vs-WebGPU image comparison",
        "max channel error 1",
        "ImageComparison",
        "compare-2d-webgpu",
        "compare-3d-backends",
        "webgpu-window-skeleton",
        "window-cpu-showcase",
        "window-webgpu-showcase",
        "smoke-window-webgpu-showcase",
        "native macOS Cocoa window",
        "Zion-style external window boundary",
        "NativeHandle",
        "runWithContext",
        "automatic window/surface",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, readme, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, readme, "optionally shades faces with Lambert lighting") == null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "uses a depth buffer for overlap") == null);
}

test "GPU 3D batches mark disabled lighting" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const batch = &gpu.batches.items[0];
    try std.testing.expect(!batch.lighting_enabled);
    try std.testing.expectEqual(@as(usize, 0), batch.lights.items.len);
}

test "GPU 3D batches encode scene lights" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    scene.setLight(.{ .direction = .{ .z = 5 }, .ambient = -1.0, .diffuse = 0.5 });
    try scene.addLight(scene3d.Light.spot(
        .{ .x = 1, .y = 2, .z = 3 },
        .{ .x = 0, .y = 0, .z = -2 },
        0.25,
        0.75,
        std.math.pi / 3.0,
        std.math.pi / 6.0,
        4.0,
    ));
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const batch = &gpu.batches.items[0];
    try std.testing.expect(batch.lighting_enabled);
    try std.testing.expectEqual(@as(usize, 2), batch.lights.items.len);

    const primary = batch.lights.items[0];
    try std.testing.expectEqual(@as(u32, 0), primary.kind);
    try std.testing.expectEqual(@as(f32, 0.0), primary.ambient);
    try std.testing.expectEqual(@as(f32, 0.5), primary.diffuse);
    try std.testing.expect(@abs(primary.direction_z - 1.0) < 0.0001);

    const spot = batch.lights.items[1];
    try std.testing.expectEqual(@as(u32, 2), spot.kind);
    try std.testing.expectEqual(@as(f32, 1.0), spot.position_x);
    try std.testing.expectEqual(@as(f32, 2.0), spot.position_y);
    try std.testing.expectEqual(@as(f32, 3.0), spot.position_z);
    try std.testing.expect(@abs(spot.direction_z + 1.0) < 0.0001);
    try std.testing.expectEqual(@as(f32, std.math.pi / 3.0), spot.inner_angle);
    try std.testing.expectEqual(@as(f32, std.math.pi / 3.0), spot.outer_angle);
}

test "GPU 3D batches encode orthographic camera projection" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
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
            .{ .x = -1.0, .y = -1.0, .z = 0.0 },
            .{ .x = 1.0, .y = -1.0, .z = 0.0 },
            .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expect(@abs(tri.a.x + 0.5) < 0.0001);
    try std.testing.expect(@abs(tri.b.x - 0.5) < 0.0001);
    try std.testing.expect(@abs(tri.c.y - 0.5) < 0.0001);
}

test "GPU 3D batches encode indexed meshes" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]@import("math.zig").Vec3{
        .{ .x = -0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.0, .y = 0.5, .z = 0.1 },
    };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMesh(.{ .positions = &positions, .indices = &indices, .color = .green });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), gpu.batches.items[0].triangles.items.len);
}

test "GPU 3D batches encode indexed mesh vertex colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]@import("math.zig").Vec3{
        .{ .x = -0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.0, .y = 0.5, .z = 0.1 },
    };
    const colors = [_]Color{ .red, .green, .blue };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMesh(.{ .positions = &positions, .indices = &indices, .color = .white, .colors = &colors });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), tri.a.rgba);
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.b.rgba);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), tri.c.rgba);
}

test "GPU 3D batches encode textured triangle colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const pixels = [_]Color{ .red, .green, .blue, .white };
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .texture = .{ .width = 2, .height = 2, .pixels = &pixels },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), tri.a.rgba);
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.b.rgba);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), tri.c.rgba);
}

test "GPU 3D batches preserve triangle UVs" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{ .x = 0.125, .y = 0.25 }, .{ .x = 0.5, .y = 0.75 }, .{ .x = 1.0, .y = 0.0 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(f32, 0.125), tri.a.u);
    try std.testing.expectEqual(@as(f32, 0.25), tri.a.v);
    try std.testing.expectEqual(@as(f32, 0.5), tri.b.u);
    try std.testing.expectEqual(@as(f32, 0.75), tri.b.v);
    try std.testing.expectEqual(@as(f32, 1.0), tri.c.u);
    try std.testing.expectEqual(@as(f32, 0.0), tri.c.v);
}

test "GPU 3D batches clear missing triangle UVs" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(f32, 0.0), tri.a.u);
    try std.testing.expectEqual(@as(f32, 0.0), tri.a.v);
    try std.testing.expectEqual(@as(f32, 0.0), tri.b.u);
    try std.testing.expectEqual(@as(f32, 0.0), tri.b.v);
    try std.testing.expectEqual(@as(f32, 0.0), tri.c.u);
    try std.testing.expectEqual(@as(f32, 0.0), tri.c.v);
}

test "GPU 3D batches preserve per-vertex normals" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .y = 1 }, .{ .z = 1 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(f32, 1.0), tri.a.nx);
    try std.testing.expectEqual(@as(f32, 0.0), tri.a.ny);
    try std.testing.expectEqual(@as(f32, 0.0), tri.a.nz);
    try std.testing.expectEqual(@as(f32, 0.0), tri.b.nx);
    try std.testing.expectEqual(@as(f32, 1.0), tri.b.ny);
    try std.testing.expectEqual(@as(f32, 0.0), tri.b.nz);
    try std.testing.expectEqual(@as(f32, 0.0), tri.c.nx);
    try std.testing.expectEqual(@as(f32, 0.0), tri.c.ny);
    try std.testing.expectEqual(@as(f32, 1.0), tri.c.nz);
}

test "GPU 3D batches derive missing normals from face normal" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expect(@abs(tri.a.nx) < 0.0001);
    try std.testing.expect(@abs(tri.a.ny) < 0.0001);
    try std.testing.expect(@abs(tri.a.nz - 1.0) < 0.0001);
    try std.testing.expectEqual(tri.a.nx, tri.b.nx);
    try std.testing.expectEqual(tri.a.ny, tri.b.ny);
    try std.testing.expectEqual(tri.a.nz, tri.b.nz);
    try std.testing.expectEqual(tri.a.nx, tri.c.nx);
    try std.testing.expectEqual(tri.a.ny, tri.c.ny);
    try std.testing.expectEqual(tri.a.nz, tri.c.nz);
}

test "GPU 3D batches preserve material parameters" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .material = .{
            .ambient = 0.25,
            .diffuse = 0.5,
            .roughness = 0.75,
            .metallic = 0.5,
            .emissive = .blue,
            .emissive_strength = 0.25,
        },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(f32, 0.25), tri.material_ambient);
    try std.testing.expectEqual(@as(f32, 0.5), tri.material_diffuse);
    try std.testing.expectEqual(@as(f32, 0.75), tri.material_roughness);
    try std.testing.expectEqual(@as(f32, 0.5), tri.material_metallic);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), tri.material_emissive);
    try std.testing.expectEqual(@as(f32, 0.25), tri.material_emissive_strength);
}

test "GPU 3D batches encode replaced material handle parameters" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addMaterialHandle(.{ .ambient = 0.1 });
    try scene.replaceMaterial(handle, .{
        .ambient = 0.4,
        .diffuse = 0.6,
        .roughness = 2.0,
        .metallic = -1.0,
        .emissive = .green,
        .emissive_strength = 0.75,
    });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .material_handle = handle,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(f32, 0.4), tri.material_ambient);
    try std.testing.expectEqual(@as(f32, 0.6), tri.material_diffuse);
    try std.testing.expectEqual(@as(f32, 1.0), tri.material_roughness);
    try std.testing.expectEqual(@as(f32, 0.0), tri.material_metallic);
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.material_emissive);
    try std.testing.expectEqual(@as(f32, 0.75), tri.material_emissive_strength);
}

test "GPU 3D batches carry bound texture resources" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const pixels = [_]Color{ .red, .green, .blue, .white };
    const handle = try scene.addTextureHandle(.{ .width = 2, .height = 2, .pixels = &pixels });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .texture_handle = handle,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const batch = &gpu.batches.items[0];
    const tri = batch.triangles.items[0];
    try std.testing.expectEqual(@as(u32, 0), tri.texture_index);
    try std.testing.expectEqual(@as(usize, 1), batch.textures.items.len);
    try std.testing.expectEqual(@as(u32, 2), batch.textures.items[0].width);
    try std.testing.expectEqual(@as(u32, 2), batch.textures.items[0].height);
    try std.testing.expectEqual(@as(u32, 0), batch.textures.items[0].pixel_start);
    try std.testing.expectEqual(@as(u32, 4), batch.textures.items[0].pixel_count);
    try std.testing.expectEqual(@as(usize, 4), batch.texture_pixels.items.len);
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), batch.texture_pixels.items[0]);
    try std.testing.expectEqual(@as(u32, Color.white.toRgba32()), batch.texture_pixels.items[3]);
}

test "GPU 3D batches accept volume slice atlas images as textures" {
    const allocator = std.testing.allocator;
    const values = [_]f32{
        0.0, 0.25,
        0.5, 0.75,
        1.0, 0.75,
        0.5, 0.25,
    };
    var atlas = try @import("visualization.zig").volumeSliceAtlasImage(allocator, &values, .{
        .width = 2,
        .height = 2,
        .depth = 2,
        .axis = .z,
        .columns = 2,
        .palette = .grayscale,
    });
    defer atlas.deinit();

    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    const handle = try scene.addTextureHandle(.{
        .width = atlas.width,
        .height = atlas.height,
        .pixels = atlas.pixels,
    });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .texture_handle = handle,
    });

    var batch: GpuBatch = .{};
    defer batch.deinit(allocator);
    try batch.build3DFromScene(allocator, &scene);

    try std.testing.expectEqual(@as(usize, 1), batch.textures.items.len);
    try std.testing.expectEqual(atlas.width, batch.textures.items[0].width);
    try std.testing.expectEqual(atlas.height, batch.textures.items[0].height);
    try std.testing.expectEqual(atlas.pixels.len, batch.texture_pixels.items.len);
    try std.testing.expectEqual(Color.black.toRgba32(), batch.texture_pixels.items[0]);
    try std.testing.expect(Color.fromRgba32(batch.texture_pixels.items[4]).r > Color.fromRgba32(batch.texture_pixels.items[0]).r);
}

test "GPU 3D batches mark missing texture resources" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const batch = &gpu.batches.items[0];
    try std.testing.expectEqual(invalid_texture_index, batch.triangles.items[0].texture_index);
    try std.testing.expectEqual(@as(usize, 0), batch.textures.items.len);
    try std.testing.expectEqual(@as(usize, 0), batch.texture_pixels.items.len);
}

test "GPU 3D batches carry bound normal texture resources" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const pixels = [_]Color{Color.rgba(128, 128, 255, 255)};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &pixels });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .normal_texture_handle = handle,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const batch = &gpu.batches.items[0];
    const tri = batch.triangles.items[0];
    try std.testing.expectEqual(invalid_texture_index, tri.texture_index);
    try std.testing.expectEqual(@as(u32, 0), tri.normal_texture_index);
    try std.testing.expectEqual(@as(usize, 1), batch.textures.items.len);
    try std.testing.expectEqual(@as(u32, 1), batch.textures.items[0].width);
    try std.testing.expectEqual(@as(u32, 1), batch.textures.items[0].height);
    try std.testing.expectEqual(@as(u32, Color.rgba(128, 128, 255, 255).toRgba32()), batch.texture_pixels.items[0]);
}

test "GPU 3D batches mark missing normal texture resources" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(invalid_texture_index, tri.normal_texture_index);
}

test "GPU 3D batches encode scene-owned texture colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    var pixels = [_]Color{ .red, .green, .blue, .white };
    const texture = try scene.addTexture(.{ .width = 2, .height = 2, .pixels = &pixels });
    pixels[0] = .black;
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .texture = texture,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode texture handle views" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const pixels = [_]Color{ .red, .green, .blue, .white };
    const handle = try scene.addTextureHandle(.{ .width = 2, .height = 2, .pixels = &pixels });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .texture = scene.textureView(handle).?,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode replaced texture handle views" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Color{.red};
    const replacement = [_]Color{.blue};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &original });
    try scene.replaceTexture(handle, .{ .width = 1, .height = 1, .pixels = &replacement });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture = scene.textureView(handle).?,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode replaced bound texture handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Color{.red};
    const replacement = [_]Color{.green};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &original });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = handle,
    });
    try scene.replaceTexture(handle, .{ .width = 1, .height = 1, .pixels = &replacement });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode batch-updated texture handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const red = [_]Color{.red};
    const blue = [_]Color{.blue};
    const green = [_]Color{.green};
    const white = [_]Color{.white};
    const first = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &red });
    const second = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &blue });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = first,
    });
    try scene.replaceTextures(&.{
        .{ .handle = first, .texture = .{ .width = 1, .height = 1, .pixels = &green } },
        .{ .handle = second, .texture = .{ .width = 1, .height = 1, .pixels = &white } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode replaced triangle handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Color{.red};
    const replacement = [_]Color{.green};
    const texture_handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &original });
    const triangle_handle = try scene.addTriangleHandle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture = scene.textureView(texture_handle).?,
    });
    try scene.replaceTexture(texture_handle, .{ .width = 1, .height = 1, .pixels = &replacement });
    try scene.replaceTriangle(triangle_handle, .{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture = scene.textureView(texture_handle).?,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode replaced mesh handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]scene3d.Triangle3D{.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .red,
    }};
    const handle = try scene.addMeshHandle(.{ .triangles = &original });
    const replacement = [_]scene3d.Triangle3D{.{
        .positions = original[0].positions,
        .color = .blue,
    }};
    try scene.replaceMesh(handle, .{ .triangles = &replacement });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode replaced indexed mesh handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]@import("math.zig").Vec3{
        .{ .x = -0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.5, .y = -0.5, .z = 0.1 },
        .{ .x = 0.0, .y = 0.5, .z = 0.1 },
    };
    const indices = [_]u32{ 0, 1, 2 };
    const handle = try scene.addIndexedMeshHandle(.{ .positions = &positions, .indices = &indices, .color = .red });
    const colors = [_]Color{ .green, .blue, .white };
    try scene.replaceIndexedMesh(handle, .{ .positions = &positions, .indices = &indices, .color = .white, .colors = &colors });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.a.rgba);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), tri.b.rgba);
    try std.testing.expectEqual(@as(u32, Color.white.toRgba32()), tri.c.rgba);
}

test "GPU 3D batches encode geometry after resource-preserving clear" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const pixels = [_]Color{.green};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &pixels });
    try scene.addTriangle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .white });
    scene.clearGeometry();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture = scene.textureView(handle).?,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 1), gpu.batches.items[0].triangles.items.len);
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), gpu.batches.items[0].triangles.items[0].a.rgba);
}

test "GPU 3D batches encode normal map lighting" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .x = 1 }, .ambient = 0.0, .diffuse = 1.0 });

    const normals = [_]Color{
        Color.rgba(255, 128, 128, 255),
        Color.rgba(128, 128, 255, 255),
        Color.rgba(128, 255, 128, 255),
        Color.rgba(128, 128, 255, 255),
    };
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .normal_texture = .{ .width = 2, .height = 2, .pixels = &normals },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.white.toRgba32()), tri.a.rgba);
    try std.testing.expect(Color.fromRgba32(tri.b.rgba).r <= 2);
}

test "GPU 3D batches encode scene-owned normal map lighting" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .x = 1 }, .ambient = 0.0, .diffuse = 1.0 });

    var normals = [_]Color{
        Color.rgba(255, 128, 128, 255),
        Color.rgba(128, 128, 255, 255),
        Color.rgba(128, 255, 128, 255),
        Color.rgba(128, 128, 255, 255),
    };
    const normal_texture = try scene.addTexture(.{ .width = 2, .height = 2, .pixels = &normals });
    normals[0] = Color.rgba(128, 128, 255, 255);
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .normal_texture = normal_texture,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.white.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode per-vertex colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .colors = .{ .red, .green, .blue },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.red.toRgba32()), tri.a.rgba);
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.b.rgba);
    try std.testing.expectEqual(@as(u32, Color.blue.toRgba32()), tri.c.rgba);
}

test "GPU 3D batches encode per-vertex normal lighting" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 1.0 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = -1 }, .{ .z = 1 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.white.toRgba32()), tri.a.rgba);
    try std.testing.expectEqual(@as(u32, Color.black.toRgba32()), tri.b.rgba);
}

test "GPU 3D batches encode point light shading" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(scene3d.Light.point(.{ .x = 1 }, 0.0, 1.0));
    try scene.addTriangle(.{
        .positions = .{
            .{},
            .{ .x = 2 },
            .{ .y = 1 },
        },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.white.toRgba32()), tri.a.rgba);
    try std.testing.expectEqual(@as(u32, Color.black.toRgba32()), tri.b.rgba);
    try std.testing.expect(Color.fromRgba32(tri.c.rgba).r > 175);
}

test "GPU 3D batches encode ranged point light attenuation" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(scene3d.Light.pointRanged(.{ .x = 1 }, 0.0, 1.0, 4.0));
    try scene.addTriangle(.{
        .positions = .{
            .{},
            .{ .x = -2 },
            .{ .x = -5 },
        },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    const near = Color.fromRgba32(tri.a.rgba);
    const far = Color.fromRgba32(tri.b.rgba);
    try std.testing.expect(near.r > far.r);
    try std.testing.expectEqual(@as(u32, Color.black.toRgba32()), tri.c.rgba);
}

test "GPU 3D batches encode spot light cone attenuation" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(scene3d.Light.spot(
        .{},
        .{ .x = 1 },
        0.0,
        1.0,
        std.math.pi / 12.0,
        std.math.pi / 4.0,
        8.0,
    ));
    try scene.addTriangle(.{
        .positions = .{ .{ .x = 1 }, .{ .x = 1, .y = 2 }, .{ .x = -1 } },
        .color = .white,
        .normals = .{ .{ .x = -1 }, .{ .x = -1 }, .{ .x = -1 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expect(Color.fromRgba32(tri.a.rgba).r > 40);
    try std.testing.expectEqual(@as(u32, Color.black.toRgba32()), tri.b.rgba);
    try std.testing.expectEqual(@as(u32, Color.black.toRgba32()), tri.c.rgba);
}

test "GPU 3D batches encode accumulated lights" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 0.25 });
    try scene.addLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 0.25 });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.rgba(128, 128, 128, 255).toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode material lighting factors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.25, .diffuse = 0.75 });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
        .material = .{ .ambient = 0.5, .diffuse = 0.5 },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.rgba(128, 128, 128, 255).toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode metallic roughness response" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 0.5 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
        .material = .{ .roughness = 0.0, .metallic = 1.0 },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.white.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode emissive material colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .black,
        .material = .{ .emissive = .blue, .emissive_strength = 0.5 },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.rgba(0, 0, 128, 255).toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode replaced material handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addMaterialHandle(.{ .emissive = .red, .emissive_strength = 1.0 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .black,
        .material_handle = handle,
    });
    try scene.replaceMaterial(handle, .{ .emissive = .green, .emissive_strength = 1.0 });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches encode batch-updated material handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const first = try scene.addMaterialHandle(.{ .emissive = .red, .emissive_strength = 1.0 });
    const second = try scene.addMaterialHandle(.{ .emissive = .blue, .emissive_strength = 1.0 });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .black,
        .material_handle = first,
    });
    try scene.replaceMaterials(&.{
        .{ .handle = first, .material = .{ .emissive = .green, .emissive_strength = 1.0 } },
        .{ .handle = second, .material = .{ .emissive = .white, .emissive_strength = 1.0 } },
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    const tri = gpu.batches.items[0].triangles.items[0];
    try std.testing.expectEqual(@as(u32, Color.green.toRgba32()), tri.a.rgba);
}

test "GPU 3D batches apply cull mode" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCullMode(.back);
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .green,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 0), gpu.batches.items[0].triangles.items.len);
}

test "GPU 3D batches reject triangles outside clip volume" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = 2.0, .y = 0.0, .z = 0.5 },
            .{ .x = 3.0, .y = 0.0, .z = 0.5 },
            .{ .x = 2.5, .y = 1.0, .z = 0.5 },
        },
        .color = .green,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    try std.testing.expectEqual(@as(usize, 0), gpu.batches.items[0].triangles.items.len);
}

test "GPU batch debug dump reports encoded 2D and 3D resources" {
    const allocator = std.testing.allocator;
    var scene2 = Scene2D.init(allocator);
    defer scene2.deinit();
    try scene2.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .red);

    var scene3 = Scene3D.init(allocator);
    defer scene3.deinit();
    const pixels = [_]Color{ .white, .red, .green, .blue };
    const texture = try scene3.addTextureHandle(.{ .width = 2, .height = 2, .pixels = &pixels });
    scene3.setLight(scene3d.Light.point(.{ .x = 0, .y = 0, .z = 1 }, 0.1, 0.9));
    try scene3.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .texture_handle = texture,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
    });
    try scene3.addPoint(.{ .position = .{ .x = 0.25, .y = 0.25, .z = 0.2 }, .color = .red, .size = 2.0 });
    try scene3.addLine(.{ .start = .{ .x = -0.4, .y = 0.35, .z = 0.2 }, .end = .{ .x = 0.4, .y = 0.35, .z = 0.2 }, .color = .blue, .width = 2.0 });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene2, &img);
    try gpu.enqueue3D(&scene3, &img);

    const batch2 = gpu.batches.items[0].debugDump();
    try std.testing.expect(batch2.strips > 0);
    try std.testing.expect(batch2.tile_ranges > 0);
    try std.testing.expect(!batch2.tile_bounds.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), batch2.triangles);
    try std.testing.expect(batch2.upload_bytes >= batch2.strips * ShaderContract.strip_size);
    try std.testing.expectEqual(@as(usize, 1), batch2.draw_calls);
    try std.testing.expectEqual(@as(usize, 1), batch2.pipeline_switches);
    try std.testing.expectEqual(@as(usize, 0), batch2.texture_binds);

    const batch3 = gpu.batches.items[1].debugDump();
    try std.testing.expectEqual(@as(usize, 1), batch3.triangles);
    try std.testing.expectEqual(@as(usize, 1), batch3.points);
    try std.testing.expectEqual(@as(usize, 1), batch3.lines);
    try std.testing.expectEqual(@as(usize, 1), batch3.textures);
    try std.testing.expectEqual(@as(usize, pixels.len), batch3.texture_pixels);
    try std.testing.expectEqual(@as(usize, 1), batch3.lights);
    try std.testing.expect(batch3.lighting_enabled);
    try std.testing.expect(batch3.upload_bytes >= ShaderContract.triangle_size + ShaderContract.point3d_size + ShaderContract.line3d_size);
    try std.testing.expectEqual(@as(usize, 3), batch3.draw_calls);
    try std.testing.expectEqual(@as(usize, 1), batch3.pipeline_switches);
    try std.testing.expectEqual(@as(usize, 1), batch3.texture_binds);

    const device_dump = gpu.debugDump();
    try std.testing.expectEqual(BackendKind.external, device_dump.backend);
    try std.testing.expectEqual(@as(usize, 2), device_dump.commands);
    try std.testing.expectEqual(@as(usize, 1), device_dump.render_2d_commands);
    try std.testing.expectEqual(@as(usize, 1), device_dump.render_3d_commands);
    try std.testing.expectEqual(@as(usize, 2), device_dump.batches);
    try std.testing.expectEqual(batch2.strips, device_dump.strips);
    try std.testing.expectEqual(batch2.tile_ranges, device_dump.tile_ranges);
    try std.testing.expectEqual(batch3.triangles, device_dump.triangles);
    try std.testing.expectEqual(batch3.points, device_dump.points);
    try std.testing.expectEqual(batch3.lines, device_dump.lines);
    try std.testing.expectEqual(batch3.textures, device_dump.textures);
    try std.testing.expectEqual(batch3.texture_pixels, device_dump.texture_pixels);
    try std.testing.expectEqual(batch3.lights, device_dump.lights);
    try std.testing.expectEqual(batch2.upload_bytes + batch3.upload_bytes, device_dump.upload_bytes);
    try std.testing.expectEqual(batch2.draw_calls + batch3.draw_calls, device_dump.draw_calls);
    try std.testing.expectEqual(batch2.pipeline_switches + batch3.pipeline_switches, device_dump.pipeline_switches);
    try std.testing.expectEqual(batch2.texture_binds + batch3.texture_binds, device_dump.texture_binds);
    try std.testing.expectEqual(@as(usize, 1), device_dump.lighting_enabled_batches);

    gpu.clearCommands();
    const empty_dump = gpu.debugDump();
    try std.testing.expectEqual(@as(usize, 0), empty_dump.commands);
    try std.testing.expectEqual(@as(usize, 0), empty_dump.batches);
}

test "GPU device builds render graph from queued 2D and 3D commands" {
    const allocator = std.testing.allocator;
    var scene2 = Scene2D.init(allocator);
    defer scene2.deinit();
    try scene2.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .red);

    var scene3 = Scene3D.init(allocator);
    defer scene3.deinit();
    const pixels = [_]Color{ .white, .blue, .red, .green };
    const texture = try scene3.addTextureHandle(.{ .width = 2, .height = 2, .pixels = &pixels });
    scene3.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.2, .diffuse = 0.8 });
    try scene3.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .texture_handle = texture,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
    });
    try scene3.addPoint(.{ .position = .{ .x = 0.25, .y = 0.25, .z = 0.2 }, .color = .red, .size = 2.0 });
    try scene3.addLine(.{ .start = .{ .x = -0.4, .y = 0.35, .z = 0.2 }, .end = .{ .x = 0.4, .y = 0.35, .z = 0.2 }, .color = .blue, .width = 2.0 });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue2D(&scene2, &img);
    try gpu.enqueue3D(&scene3, &img);

    var graph = try gpu.buildRenderGraph(allocator);
    defer graph.deinit();

    const dump = try graph.debugDump(allocator);
    try std.testing.expectEqual(@as(usize, 3), dump.passes);
    try std.testing.expectEqual(@as(usize, 3), dump.active_passes);
    try std.testing.expectEqual(@as(usize, 0), dump.culled_passes);
    try std.testing.expectEqual(@as(usize, 1), dump.external_resources);
    try std.testing.expect(dump.resources >= 9);
    try std.testing.expect(dump.read_edges >= 8);
    try std.testing.expectEqual(@as(usize, 3), dump.write_edges);
    try std.testing.expect(dump.hazards >= 2);
    try std.testing.expect(dump.read_after_write_hazards >= 1);
    try std.testing.expect(dump.write_after_read_hazards >= 1);

    var passes = try graph.passDebugDump(allocator);
    defer passes.deinit(allocator);
    try std.testing.expectEqualStrings("queued-2d-render", passes.items[0].label);
    try std.testing.expectEqual(render_graph.PassKind.render, passes.items[0].kind);
    try std.testing.expectEqualStrings("queued-3d-render", passes.items[1].label);
    try std.testing.expectEqual(render_graph.PassKind.render, passes.items[1].kind);
    try std.testing.expectEqualStrings("present", passes.items[2].label);
    try std.testing.expectEqual(render_graph.PassKind.copy, passes.items[2].kind);

    var resources = try graph.resourceDebugDump(allocator);
    defer resources.deinit(allocator);
    var has_external = false;
    var has_2d_strips = false;
    var has_3d_triangles = false;
    var has_3d_points = false;
    var has_3d_lines = false;
    var has_3d_texture_pixels = false;
    var has_3d_lights = false;
    for (resources.items) |resource| {
        if (resource.external) has_external = true;
        if (std.mem.eql(u8, resource.label, "2d-strips")) has_2d_strips = true;
        if (std.mem.eql(u8, resource.label, "3d-triangles")) has_3d_triangles = true;
        if (std.mem.eql(u8, resource.label, "3d-points")) has_3d_points = true;
        if (std.mem.eql(u8, resource.label, "3d-lines")) has_3d_lines = true;
        if (std.mem.eql(u8, resource.label, "3d-texture-pixels")) has_3d_texture_pixels = true;
        if (std.mem.eql(u8, resource.label, "3d-lights")) has_3d_lights = true;
    }
    try std.testing.expect(has_external);
    try std.testing.expect(has_2d_strips);
    try std.testing.expect(has_3d_triangles);
    try std.testing.expect(has_3d_points);
    try std.testing.expect(has_3d_lines);
    try std.testing.expect(has_3d_texture_pixels);
    try std.testing.expect(has_3d_lights);
}

test "GPU device render graph can include picking and debug passes" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.5, .y = -0.5, .z = 0.1 },
            .{ .x = 0.0, .y = 0.5, .z = 0.1 },
        },
        .color = .white,
    });

    var img = try Image.init(allocator, 16, 16, .transparent);
    defer img.deinit();

    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.enqueue3D(&scene, &img);

    var graph = try gpu.buildRenderGraphWithOptions(allocator, .{ .picking_pass = true, .debug_pass = true });
    defer graph.deinit();

    var passes = try graph.passDebugDump(allocator);
    defer passes.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), passes.items.len);
    try std.testing.expectEqualStrings("queued-3d-render", passes.items[0].label);
    try std.testing.expectEqualStrings("picking-pass", passes.items[1].label);
    try std.testing.expectEqual(render_graph.PassKind.render, passes.items[1].kind);
    try std.testing.expectEqualStrings("debug-pass", passes.items[2].label);
    try std.testing.expectEqual(render_graph.PassKind.debug, passes.items[2].kind);
    try std.testing.expectEqualStrings("present", passes.items[3].label);

    var resources = try graph.resourceDebugDump(allocator);
    defer resources.deinit(allocator);
    var has_picking = false;
    var has_debug = false;
    for (resources.items) |resource| {
        if (std.mem.eql(u8, resource.label, "picking-buffer")) has_picking = true;
        if (std.mem.eql(u8, resource.label, "debug-overlay")) has_debug = true;
    }
    try std.testing.expect(has_picking);
    try std.testing.expect(has_debug);
}

test "GPU device render graph reports missing queued batch" {
    const allocator = std.testing.allocator;
    var gpu = GpuDevice.init(allocator, .external);
    defer gpu.deinit();
    try gpu.commands.append(allocator, .{
        .kind = .render_2d,
        .primitive_count = 1,
        .target_width = 4,
        .target_height = 4,
        .batch_index = 0,
    });
    try std.testing.expectError(error.MissingBatch, gpu.buildRenderGraph(allocator));
}

test "GPU device submits queued batches to backend" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, .white);

    var img = try Image.init(allocator, 4, 4, .transparent);
    defer img.deinit();

    const Sink = struct {
        submitted: usize = 0,
        strips: usize = 0,

        fn submit(context: *anyopaque, command: GpuCommand, batch: *const GpuBatch) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(CommandKind.render_2d, command.kind);
            self.submitted += 1;
            self.strips += batch.strips.items.len;
        }
    };

    var sink = Sink{};
    var gpu = GpuDevice.init(allocator, .none);
    defer gpu.deinit();
    gpu.setBackend(.{ .context = &sink, .submitFn = Sink.submit });

    try gpu.enqueue2D(&scene, &img);
    try gpu.submitQueued();

    try std.testing.expectEqual(@as(usize, 1), sink.submitted);
    try std.testing.expect(sink.strips > 0);
    try std.testing.expectEqual(@as(usize, 0), gpu.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), gpu.batches.items.len);
}
