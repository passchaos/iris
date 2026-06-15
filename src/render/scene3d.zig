const std = @import("std");
const math = @import("math.zig");
const Color = @import("color.zig").Color;

pub const Triangle3D = struct {
    positions: [3]math.Vec3,
    color: Color,
    colors: ?[3]Color = null,
    uvs: ?[3]math.Vec2 = null,
    texture: ?Texture = null,
    texture_handle: ?TextureHandle = null,
    normal_texture: ?Texture = null,
    normal_texture_handle: ?TextureHandle = null,
    normals: ?[3]math.Vec3 = null,
    material: Material = .{},
    material_handle: ?MaterialHandle = null,

    pub fn vertexColors(self: Triangle3D) [3]Color {
        return self.colors orelse .{ self.color, self.color, self.color };
    }
};

pub const Texture = struct {
    width: u32,
    height: u32,
    pixels: []const Color,
};

pub const TextureHandle = struct {
    index: usize,
};

pub const TriangleHandle = struct {
    index: usize,
};

pub const PointHandle = struct {
    index: usize,
};

pub const LineHandle = struct {
    index: usize,
};

pub const MeshHandle = struct {
    start: usize,
    count: usize,
};

pub const PointCloudHandle = struct {
    start: usize,
    count: usize,
};

pub const MaterialHandle = struct {
    index: usize,
};

pub const TriangleUpdate = struct {
    handle: TriangleHandle,
    triangle: Triangle3D,
};

pub const MaterialUpdate = struct {
    handle: MaterialHandle,
    material: Material,
};

pub const TextureUpdate = struct {
    handle: TextureHandle,
    texture: Texture,
};

pub const Point3D = struct {
    position: math.Vec3,
    color: Color = .white,
    size: f32 = 1.0,
};

pub const PointCloud = struct {
    points: []const Point3D,
};

pub const Line3D = struct {
    start: math.Vec3,
    end: math.Vec3,
    color: Color = .white,
    width: f32 = 1.0,
};

pub const Axis3D = struct {
    origin: math.Vec3 = .{},
    length: f32 = 1.0,
    width: f32 = 2.0,
    x_color: Color = .red,
    y_color: Color = .green,
    z_color: Color = .blue,
};

pub const Grid3D = struct {
    origin: math.Vec3 = .{},
    x_extent: f32 = 1.0,
    z_extent: f32 = 1.0,
    spacing: f32 = 0.25,
    width: f32 = 1.0,
    color: Color = .white,
    major_color: Color = .white,
    major_every: u32 = 4,
};

pub const DebugBox3D = struct {
    min: math.Vec3,
    max: math.Vec3,
    color: Color = .white,
    width: f32 = 1.0,
};

pub const VolumePlaceholder3D = struct {
    min: math.Vec3,
    max: math.Vec3,
    color: Color = .white,
    slice_color: Color = Color.rgba(120, 180, 255, 180),
    width: f32 = 1.0,
    slices: u32 = 3,
};

pub const Ray3D = struct {
    origin: math.Vec3,
    direction: math.Vec3,
};

pub const TrianglePick = struct {
    triangle_index: usize,
    distance: f32,
    position: math.Vec3,
    barycentric: [3]f32,
};

pub const Viewport3D = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32,
    height: f32,
};

const OwnedTexture = struct {
    width: u32,
    height: u32,
    pixels: []Color,

    fn view(self: *const OwnedTexture) Texture {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }

    fn deinit(self: *OwnedTexture, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const Material = struct {
    ambient: f32 = 1.0,
    diffuse: f32 = 1.0,
    roughness: f32 = 1.0,
    metallic: f32 = 0.0,
    emissive: Color = .black,
    emissive_strength: f32 = 0.0,
};

pub const Mesh = struct {
    triangles: []const Triangle3D,
};

pub const MeshInstances = struct {
    mesh: Mesh,
    transforms: []const math.Mat4,
};

pub const MeshLodLevel = struct {
    max_distance: f32,
    mesh: Mesh,
};

pub const MeshLod = struct {
    levels: []const MeshLodLevel,
};

pub const IndexedMesh = struct {
    positions: []const math.Vec3,
    indices: []const u32,
    color: Color,
    colors: ?[]const Color = null,
    uvs: ?[]const math.Vec2 = null,
    texture: ?Texture = null,
    texture_handle: ?TextureHandle = null,
    normal_texture: ?Texture = null,
    normal_texture_handle: ?TextureHandle = null,
    normals: ?[]const math.Vec3 = null,
    material: Material = .{},
    material_handle: ?MaterialHandle = null,
};

pub const Camera = struct {
    transform: math.Mat4 = .identity,

    pub fn perspectiveLookAt(
        eye: math.Vec3,
        center: math.Vec3,
        up: math.Vec3,
        fovy_radians: f32,
        aspect: f32,
        near: f32,
        far: f32,
    ) Camera {
        return .{
            .transform = math.Mat4.perspective(fovy_radians, aspect, near, far).mul(math.Mat4.lookAt(eye, center, up)),
        };
    }

    pub fn orthographicLookAt(
        eye: math.Vec3,
        center: math.Vec3,
        up: math.Vec3,
        width: f32,
        height: f32,
        near: f32,
        far: f32,
    ) Camera {
        return .{
            .transform = math.Mat4.orthographicCentered(width, height, near, far).mul(math.Mat4.lookAt(eye, center, up)),
        };
    }

    pub fn rayFromScreen(self: Camera, viewport: Viewport3D, screen: math.Vec2) ?Ray3D {
        if (viewport.width <= 0.0 or viewport.height <= 0.0) return null;
        const inv = self.transform.inverse() orelse return null;
        const ndc_x = ((screen.x - viewport.x) / viewport.width) * 2.0 - 1.0;
        const ndc_y = 1.0 - ((screen.y - viewport.y) / viewport.height) * 2.0;
        const near = inv.transformPoint(.{ .x = ndc_x, .y = ndc_y, .z = 0.0 });
        const far = inv.transformPoint(.{ .x = ndc_x, .y = ndc_y, .z = 1.0 });
        return normalizeRay(.{
            .origin = near,
            .direction = far.sub(near),
        });
    }
};

pub const LightKind = enum {
    directional,
    point,
    spot,
};

pub const Light = struct {
    kind: LightKind = .directional,
    direction: math.Vec3 = .{ .x = 0, .y = 0, .z = 1 },
    position: math.Vec3 = .{ .z = 1 },
    ambient: f32 = 0.15,
    diffuse: f32 = 0.85,
    range: f32 = std.math.inf(f32),
    attenuation: f32 = 0.0,
    inner_angle: f32 = 0.0,
    outer_angle: f32 = std.math.pi,

    pub fn point(position: math.Vec3, ambient: f32, diffuse: f32) Light {
        return .{
            .kind = .point,
            .position = position,
            .ambient = ambient,
            .diffuse = diffuse,
        };
    }

    pub fn pointRanged(position: math.Vec3, ambient: f32, diffuse: f32, range: f32) Light {
        return .{
            .kind = .point,
            .position = position,
            .ambient = ambient,
            .diffuse = diffuse,
            .range = range,
            .attenuation = 1.0,
        };
    }

    pub fn spot(position: math.Vec3, direction: math.Vec3, ambient: f32, diffuse: f32, inner_angle: f32, outer_angle: f32, range: f32) Light {
        return .{
            .kind = .spot,
            .direction = direction,
            .position = position,
            .ambient = ambient,
            .diffuse = diffuse,
            .range = range,
            .attenuation = 1.0,
            .inner_angle = inner_angle,
            .outer_angle = outer_angle,
        };
    }
};

pub const CullMode = enum {
    none,
    back,
    front,
};

pub const Scene3D = struct {
    allocator: std.mem.Allocator,
    camera: Camera = .{},
    light: Light = .{},
    lights: std.ArrayList(Light) = .empty,
    lighting_enabled: bool = false,
    cull_mode: CullMode = .none,
    triangles: std.ArrayList(Triangle3D) = .empty,
    points: std.ArrayList(Point3D) = .empty,
    lines: std.ArrayList(Line3D) = .empty,
    textures: std.ArrayList(OwnedTexture) = .empty,
    materials: std.ArrayList(Material) = .empty,

    pub fn init(allocator: std.mem.Allocator) Scene3D {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scene3D) void {
        for (self.textures.items) |*texture| {
            texture.deinit(self.allocator);
        }
        self.textures.deinit(self.allocator);
        self.materials.deinit(self.allocator);
        self.lights.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.points.deinit(self.allocator);
        self.triangles.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Scene3D) void {
        self.triangles.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        self.lights.clearRetainingCapacity();
        for (self.textures.items) |*texture| {
            texture.deinit(self.allocator);
        }
        self.textures.clearRetainingCapacity();
        self.materials.clearRetainingCapacity();
        self.light = .{};
        self.lighting_enabled = false;
    }

    pub fn clearGeometry(self: *Scene3D) void {
        self.triangles.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
    }

    pub fn setLight(self: *Scene3D, light: Light) void {
        self.light = normalizeLight(light);
        self.lights.clearRetainingCapacity();
        self.lighting_enabled = true;
    }

    pub fn addLight(self: *Scene3D, light: Light) !void {
        try self.lights.append(self.allocator, normalizeLight(light));
        self.lighting_enabled = true;
    }

    pub fn disableLighting(self: *Scene3D) void {
        self.lighting_enabled = false;
    }

    pub fn setCamera(self: *Scene3D, camera: Camera) void {
        self.camera = camera;
    }

    pub fn setCullMode(self: *Scene3D, mode: CullMode) void {
        self.cull_mode = mode;
    }

    pub fn addTexture(self: *Scene3D, texture: Texture) !Texture {
        const handle = try self.addTextureHandle(texture);
        return self.textureView(handle) orelse error.InvalidTextureHandle;
    }

    pub fn addTextureHandle(self: *Scene3D, texture: Texture) !TextureHandle {
        const pixels = try self.allocator.dupe(Color, texture.pixels);
        errdefer self.allocator.free(pixels);
        try self.textures.append(self.allocator, .{
            .width = texture.width,
            .height = texture.height,
            .pixels = pixels,
        });
        return .{ .index = self.textures.items.len - 1 };
    }

    pub fn textureView(self: *const Scene3D, handle: TextureHandle) ?Texture {
        if (handle.index >= self.textures.items.len) return null;
        return self.textures.items[handle.index].view();
    }

    pub fn replaceTexture(self: *Scene3D, handle: TextureHandle, texture: Texture) !void {
        if (handle.index >= self.textures.items.len) return error.InvalidTextureHandle;
        const pixels = try self.allocator.dupe(Color, texture.pixels);
        errdefer self.allocator.free(pixels);
        self.textures.items[handle.index].deinit(self.allocator);
        self.textures.items[handle.index] = .{
            .width = texture.width,
            .height = texture.height,
            .pixels = pixels,
        };
    }

    pub fn replaceTextures(self: *Scene3D, updates: []const TextureUpdate) !void {
        for (updates) |update| {
            if (update.handle.index >= self.textures.items.len) return error.InvalidTextureHandle;
        }

        var replacements = try std.ArrayList(OwnedTexture).initCapacity(self.allocator, updates.len);
        defer replacements.deinit(self.allocator);
        errdefer {
            for (replacements.items) |*texture| {
                texture.deinit(self.allocator);
            }
        }

        for (updates) |update| {
            const pixels = try self.allocator.dupe(Color, update.texture.pixels);
            errdefer self.allocator.free(pixels);
            replacements.appendAssumeCapacity(.{
                .width = update.texture.width,
                .height = update.texture.height,
                .pixels = pixels,
            });
        }

        for (updates, replacements.items) |update, replacement| {
            self.textures.items[update.handle.index].deinit(self.allocator);
            self.textures.items[update.handle.index] = replacement;
        }
        replacements.clearRetainingCapacity();
    }

    pub fn addMaterialHandle(self: *Scene3D, material: Material) !MaterialHandle {
        try self.materials.append(self.allocator, normalizeMaterial(material));
        return .{ .index = self.materials.items.len - 1 };
    }

    pub fn materialView(self: *const Scene3D, handle: MaterialHandle) ?Material {
        if (handle.index >= self.materials.items.len) return null;
        return self.materials.items[handle.index];
    }

    pub fn replaceMaterial(self: *Scene3D, handle: MaterialHandle, material: Material) !void {
        if (handle.index >= self.materials.items.len) return error.InvalidMaterialHandle;
        self.materials.items[handle.index] = normalizeMaterial(material);
    }

    pub fn replaceMaterials(self: *Scene3D, updates: []const MaterialUpdate) !void {
        for (updates) |update| {
            if (update.handle.index >= self.materials.items.len) return error.InvalidMaterialHandle;
        }
        for (updates) |update| {
            self.materials.items[update.handle.index] = normalizeMaterial(update.material);
        }
    }

    pub fn addTriangle(self: *Scene3D, triangle: Triangle3D) !void {
        try self.triangles.append(self.allocator, normalizeTriangle(triangle));
    }

    pub fn addTriangleHandle(self: *Scene3D, triangle: Triangle3D) !TriangleHandle {
        try self.addTriangle(triangle);
        return .{ .index = self.triangles.items.len - 1 };
    }

    pub fn triangleView(self: *const Scene3D, handle: TriangleHandle) ?Triangle3D {
        if (handle.index >= self.triangles.items.len) return null;
        return self.triangles.items[handle.index];
    }

    pub fn replaceTriangle(self: *Scene3D, handle: TriangleHandle, triangle: Triangle3D) !void {
        if (handle.index >= self.triangles.items.len) return error.InvalidTriangleHandle;
        self.triangles.items[handle.index] = normalizeTriangle(triangle);
    }

    pub fn replaceTriangles(self: *Scene3D, updates: []const TriangleUpdate) !void {
        for (updates) |update| {
            if (update.handle.index >= self.triangles.items.len) return error.InvalidTriangleHandle;
        }
        for (updates) |update| {
            self.triangles.items[update.handle.index] = normalizeTriangle(update.triangle);
        }
    }

    pub fn addPoint(self: *Scene3D, point: Point3D) !void {
        try self.points.append(self.allocator, normalizePoint(point));
    }

    pub fn addPointHandle(self: *Scene3D, point: Point3D) !PointHandle {
        try self.addPoint(point);
        return .{ .index = self.points.items.len - 1 };
    }

    pub fn pointView(self: *const Scene3D, handle: PointHandle) ?Point3D {
        if (handle.index >= self.points.items.len) return null;
        return self.points.items[handle.index];
    }

    pub fn replacePoint(self: *Scene3D, handle: PointHandle, point: Point3D) !void {
        if (handle.index >= self.points.items.len) return error.InvalidPointHandle;
        self.points.items[handle.index] = normalizePoint(point);
    }

    pub fn addPointCloud(self: *Scene3D, cloud: PointCloud) !void {
        _ = try self.addPointCloudHandle(cloud);
    }

    pub fn addPointCloudHandle(self: *Scene3D, cloud: PointCloud) !PointCloudHandle {
        const handle = PointCloudHandle{ .start = self.points.items.len, .count = cloud.points.len };
        try self.points.ensureUnusedCapacity(self.allocator, cloud.points.len);
        for (cloud.points) |point| {
            self.points.appendAssumeCapacity(normalizePoint(point));
        }
        return handle;
    }

    pub fn addPointCloudTransformed(self: *Scene3D, cloud: PointCloud, transform: math.Mat4) !void {
        _ = try self.addPointCloudTransformedHandle(cloud, transform);
    }

    pub fn addPointCloudTransformedHandle(self: *Scene3D, cloud: PointCloud, transform: math.Mat4) !PointCloudHandle {
        const handle = PointCloudHandle{ .start = self.points.items.len, .count = cloud.points.len };
        try self.points.ensureUnusedCapacity(self.allocator, cloud.points.len);
        for (cloud.points) |point| {
            self.points.appendAssumeCapacity(normalizePoint(.{
                .position = transform.transformPoint(point.position),
                .color = point.color,
                .size = point.size,
            }));
        }
        return handle;
    }

    pub fn pointCloudView(self: *const Scene3D, handle: PointCloudHandle) ?[]const Point3D {
        if (!self.pointCloudHandleValid(handle)) return null;
        return self.points.items[handle.start .. handle.start + handle.count];
    }

    fn pointCloudHandleValid(self: *const Scene3D, handle: PointCloudHandle) bool {
        return handle.start <= self.points.items.len and handle.count <= self.points.items.len - handle.start;
    }

    pub fn addLine(self: *Scene3D, line: Line3D) !void {
        try self.lines.append(self.allocator, normalizeLine(line));
    }

    pub fn addLineHandle(self: *Scene3D, line: Line3D) !LineHandle {
        try self.addLine(line);
        return .{ .index = self.lines.items.len - 1 };
    }

    pub fn lineView(self: *const Scene3D, handle: LineHandle) ?Line3D {
        if (handle.index >= self.lines.items.len) return null;
        return self.lines.items[handle.index];
    }

    pub fn replaceLine(self: *Scene3D, handle: LineHandle, line: Line3D) !void {
        if (handle.index >= self.lines.items.len) return error.InvalidLineHandle;
        self.lines.items[handle.index] = normalizeLine(line);
    }

    pub fn addAxis(self: *Scene3D, axis: Axis3D) !void {
        const normalized = normalizeAxis(axis);
        const origin = normalized.origin;
        try self.addLine(.{
            .start = origin,
            .end = origin.add(.{ .x = normalized.length }),
            .color = normalized.x_color,
            .width = normalized.width,
        });
        try self.addLine(.{
            .start = origin,
            .end = origin.add(.{ .y = normalized.length }),
            .color = normalized.y_color,
            .width = normalized.width,
        });
        try self.addLine(.{
            .start = origin,
            .end = origin.add(.{ .z = normalized.length }),
            .color = normalized.z_color,
            .width = normalized.width,
        });
    }

    pub fn addGrid(self: *Scene3D, grid: Grid3D) !void {
        const normalized = normalizeGrid(grid);
        const x_count: u32 = @intFromFloat(@floor(normalized.x_extent / normalized.spacing));
        const z_count: u32 = @intFromFloat(@floor(normalized.z_extent / normalized.spacing));
        var zi: i32 = -@as(i32, @intCast(z_count));
        while (zi <= @as(i32, @intCast(z_count))) : (zi += 1) {
            const offset = @as(f32, @floatFromInt(zi)) * normalized.spacing;
            try self.addLine(.{
                .start = normalized.origin.add(.{ .x = -normalized.x_extent, .z = offset }),
                .end = normalized.origin.add(.{ .x = normalized.x_extent, .z = offset }),
                .color = gridLineColor(normalized, zi),
                .width = normalized.width,
            });
        }
        var xi: i32 = -@as(i32, @intCast(x_count));
        while (xi <= @as(i32, @intCast(x_count))) : (xi += 1) {
            const offset = @as(f32, @floatFromInt(xi)) * normalized.spacing;
            try self.addLine(.{
                .start = normalized.origin.add(.{ .x = offset, .z = -normalized.z_extent }),
                .end = normalized.origin.add(.{ .x = offset, .z = normalized.z_extent }),
                .color = gridLineColor(normalized, xi),
                .width = normalized.width,
            });
        }
    }

    pub fn addDebugBox(self: *Scene3D, box: DebugBox3D) !void {
        const normalized = normalizeDebugBox(box);
        const min = normalized.min;
        const max = normalized.max;
        const corners = [8]math.Vec3{
            .{ .x = min.x, .y = min.y, .z = min.z },
            .{ .x = max.x, .y = min.y, .z = min.z },
            .{ .x = max.x, .y = max.y, .z = min.z },
            .{ .x = min.x, .y = max.y, .z = min.z },
            .{ .x = min.x, .y = min.y, .z = max.z },
            .{ .x = max.x, .y = min.y, .z = max.z },
            .{ .x = max.x, .y = max.y, .z = max.z },
            .{ .x = min.x, .y = max.y, .z = max.z },
        };
        const edges = [_][2]usize{
            .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 },
            .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 },
            .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
        };
        for (edges) |edge| {
            try self.addLine(.{
                .start = corners[edge[0]],
                .end = corners[edge[1]],
                .color = normalized.color,
                .width = normalized.width,
            });
        }
    }

    pub fn addVolumePlaceholder(self: *Scene3D, volume: VolumePlaceholder3D) !void {
        const normalized = normalizeVolumePlaceholder(volume);
        try self.addDebugBox(.{
            .min = normalized.min,
            .max = normalized.max,
            .color = normalized.color,
            .width = normalized.width,
        });
        if (normalized.slices == 0) return;

        const min = normalized.min;
        const max = normalized.max;
        var slice: u32 = 1;
        while (slice <= normalized.slices) : (slice += 1) {
            const t = @as(f32, @floatFromInt(slice)) / @as(f32, @floatFromInt(normalized.slices + 1));
            const z = min.z + (max.z - min.z) * t;
            const p0 = math.Vec3{ .x = min.x, .y = min.y, .z = z };
            const p1 = math.Vec3{ .x = max.x, .y = min.y, .z = z };
            const p2 = math.Vec3{ .x = max.x, .y = max.y, .z = z };
            const p3 = math.Vec3{ .x = min.x, .y = max.y, .z = z };
            try self.addLine(.{ .start = p0, .end = p1, .color = normalized.slice_color, .width = normalized.width });
            try self.addLine(.{ .start = p1, .end = p2, .color = normalized.slice_color, .width = normalized.width });
            try self.addLine(.{ .start = p2, .end = p3, .color = normalized.slice_color, .width = normalized.width });
            try self.addLine(.{ .start = p3, .end = p0, .color = normalized.slice_color, .width = normalized.width });
        }
    }

    pub fn pickTriangle(self: *const Scene3D, ray: Ray3D) ?TrianglePick {
        const normalized_ray = normalizeRay(ray) orelse return null;
        var best: ?TrianglePick = null;
        for (self.triangles.items, 0..) |triangle, index| {
            const hit = intersectRayTriangle(normalized_ray, triangle) orelse continue;
            if (best == null or hit.distance < best.?.distance) {
                best = .{
                    .triangle_index = index,
                    .distance = hit.distance,
                    .position = normalized_ray.origin.add(normalized_ray.direction.scale(hit.distance)),
                    .barycentric = hit.barycentric,
                };
            }
        }
        return best;
    }

    pub fn addMesh(self: *Scene3D, mesh: Mesh) !void {
        _ = try self.addMeshHandle(mesh);
    }

    pub fn addMeshHandle(self: *Scene3D, mesh: Mesh) !MeshHandle {
        const handle = MeshHandle{ .start = self.triangles.items.len, .count = mesh.triangles.len };
        try self.triangles.ensureUnusedCapacity(self.allocator, mesh.triangles.len);
        for (mesh.triangles) |triangle| {
            self.triangles.appendAssumeCapacity(normalizeTriangle(triangle));
        }
        return handle;
    }

    pub fn addMeshTransformed(self: *Scene3D, mesh: Mesh, transform: math.Mat4) !void {
        _ = try self.addMeshTransformedHandle(mesh, transform);
    }

    pub fn addMeshTransformedHandle(self: *Scene3D, mesh: Mesh, transform: math.Mat4) !MeshHandle {
        const handle = MeshHandle{ .start = self.triangles.items.len, .count = mesh.triangles.len };
        try self.triangles.ensureUnusedCapacity(self.allocator, mesh.triangles.len);
        for (mesh.triangles) |triangle| {
            self.triangles.appendAssumeCapacity(.{
                .positions = .{
                    transform.transformPoint(triangle.positions[0]),
                    transform.transformPoint(triangle.positions[1]),
                    transform.transformPoint(triangle.positions[2]),
                },
                .color = triangle.color,
                .colors = triangleStaticColors(triangle),
                .uvs = triangle.uvs,
                .texture = triangle.texture,
                .texture_handle = triangle.texture_handle,
                .normal_texture = triangle.normal_texture,
                .normal_texture_handle = triangle.normal_texture_handle,
                .normals = transformNormals(triangleStaticNormals(triangle), transform),
                .material = normalizeMaterial(triangle.material),
                .material_handle = triangle.material_handle,
            });
        }
        return handle;
    }

    pub fn addMeshInstances(self: *Scene3D, instances: MeshInstances) !MeshHandle {
        if (instances.transforms.len == 0) return .{ .start = self.triangles.items.len, .count = 0 };
        const triangle_count = try std.math.mul(usize, instances.mesh.triangles.len, instances.transforms.len);
        const handle = MeshHandle{ .start = self.triangles.items.len, .count = triangle_count };
        try self.triangles.ensureUnusedCapacity(self.allocator, triangle_count);
        for (instances.transforms) |transform| {
            for (instances.mesh.triangles) |triangle| {
                self.triangles.appendAssumeCapacity(.{
                    .positions = .{
                        transform.transformPoint(triangle.positions[0]),
                        transform.transformPoint(triangle.positions[1]),
                        transform.transformPoint(triangle.positions[2]),
                    },
                    .color = triangle.color,
                    .colors = triangleStaticColors(triangle),
                    .uvs = triangle.uvs,
                    .texture = triangle.texture,
                    .texture_handle = triangle.texture_handle,
                    .normal_texture = triangle.normal_texture,
                    .normal_texture_handle = triangle.normal_texture_handle,
                    .normals = transformNormals(triangleStaticNormals(triangle), transform),
                    .material = normalizeMaterial(triangle.material),
                    .material_handle = triangle.material_handle,
                });
            }
        }
        return handle;
    }

    pub fn selectMeshLod(lod: MeshLod, distance: f32) ?Mesh {
        if (lod.levels.len == 0) return null;
        const normalized_distance = @max(0.0, distance);
        for (lod.levels) |level| {
            if (normalized_distance <= level.max_distance) return level.mesh;
        }
        return lod.levels[lod.levels.len - 1].mesh;
    }

    pub fn addMeshLod(self: *Scene3D, lod: MeshLod, distance: f32, transform: math.Mat4) !MeshHandle {
        const mesh = selectMeshLod(lod, distance) orelse return error.EmptyLod;
        return try self.addMeshTransformedHandle(mesh, transform);
    }

    pub fn meshView(self: *const Scene3D, handle: MeshHandle) ?[]const Triangle3D {
        if (!self.meshHandleValid(handle)) return null;
        return self.triangles.items[handle.start .. handle.start + handle.count];
    }

    pub fn replaceMesh(self: *Scene3D, handle: MeshHandle, mesh: Mesh) !void {
        try self.replaceMeshTransformed(handle, mesh, .identity);
    }

    pub fn replaceMeshTransformed(self: *Scene3D, handle: MeshHandle, mesh: Mesh, transform: math.Mat4) !void {
        if (!self.meshHandleValid(handle)) return error.InvalidMeshHandle;
        if (mesh.triangles.len != handle.count) return error.InvalidMeshTriangleCount;
        for (mesh.triangles, 0..) |triangle, i| {
            self.triangles.items[handle.start + i] = normalizeTriangle(.{
                .positions = .{
                    transform.transformPoint(triangle.positions[0]),
                    transform.transformPoint(triangle.positions[1]),
                    transform.transformPoint(triangle.positions[2]),
                },
                .color = triangle.color,
                .colors = triangleStaticColors(triangle),
                .uvs = triangle.uvs,
                .texture = triangle.texture,
                .texture_handle = triangle.texture_handle,
                .normal_texture = triangle.normal_texture,
                .normal_texture_handle = triangle.normal_texture_handle,
                .normals = transformNormals(triangleStaticNormals(triangle), transform),
                .material = normalizeMaterial(triangle.material),
                .material_handle = triangle.material_handle,
            });
        }
    }

    fn meshHandleValid(self: *const Scene3D, handle: MeshHandle) bool {
        return handle.start <= self.triangles.items.len and handle.count <= self.triangles.items.len - handle.start;
    }

    pub fn addIndexedMesh(self: *Scene3D, mesh: IndexedMesh) !void {
        _ = try self.addIndexedMeshHandle(mesh);
    }

    pub fn addIndexedMeshHandle(self: *Scene3D, mesh: IndexedMesh) !MeshHandle {
        return try self.addIndexedMeshTransformedHandle(mesh, .identity);
    }

    pub fn addIndexedMeshTransformed(self: *Scene3D, mesh: IndexedMesh, transform: math.Mat4) !void {
        _ = try self.addIndexedMeshTransformedHandle(mesh, transform);
    }

    pub fn addIndexedMeshTransformedHandle(self: *Scene3D, mesh: IndexedMesh, transform: math.Mat4) !MeshHandle {
        if (mesh.indices.len % 3 != 0) return error.InvalidIndexCount;
        if (mesh.colors) |colors| {
            if (colors.len != mesh.positions.len) return error.InvalidColorCount;
        }
        if (mesh.normals) |normals| {
            if (normals.len != mesh.positions.len) return error.InvalidNormalCount;
        }
        if (mesh.uvs) |uvs| {
            if (uvs.len != mesh.positions.len) return error.InvalidUvCount;
        }
        const handle = MeshHandle{ .start = self.triangles.items.len, .count = mesh.indices.len / 3 };
        try self.triangles.ensureUnusedCapacity(self.allocator, mesh.indices.len / 3);

        var i: usize = 0;
        while (i < mesh.indices.len) : (i += 3) {
            const idx0 = mesh.indices[i + 0];
            const idx1 = mesh.indices[i + 1];
            const idx2 = mesh.indices[i + 2];
            if (idx0 >= mesh.positions.len or idx1 >= mesh.positions.len or idx2 >= mesh.positions.len) {
                return error.IndexOutOfBounds;
            }
            const triangle = Triangle3D{
                .positions = .{
                    transform.transformPoint(mesh.positions[idx0]),
                    transform.transformPoint(mesh.positions[idx1]),
                    transform.transformPoint(mesh.positions[idx2]),
                },
                .color = mesh.color,
                .colors = if (mesh.colors) |colors| .{
                    colors[idx0],
                    colors[idx1],
                    colors[idx2],
                } else null,
                .uvs = if (mesh.uvs) |uvs| .{
                    uvs[idx0],
                    uvs[idx1],
                    uvs[idx2],
                } else null,
                .texture = mesh.texture,
                .texture_handle = mesh.texture_handle,
                .normal_texture = mesh.normal_texture,
                .normal_texture_handle = mesh.normal_texture_handle,
                .normals = if (mesh.normals) |normals| .{
                    transformNormal(normals[idx0], transform),
                    transformNormal(normals[idx1], transform),
                    transformNormal(normals[idx2], transform),
                } else null,
                .material = normalizeMaterial(mesh.material),
                .material_handle = mesh.material_handle,
            };
            self.triangles.appendAssumeCapacity(normalizeTriangle(triangle));
        }
        return handle;
    }

    pub fn replaceIndexedMesh(self: *Scene3D, handle: MeshHandle, mesh: IndexedMesh) !void {
        try self.replaceIndexedMeshTransformed(handle, mesh, .identity);
    }

    pub fn replaceIndexedMeshTransformed(self: *Scene3D, handle: MeshHandle, mesh: IndexedMesh, transform: math.Mat4) !void {
        if (!self.meshHandleValid(handle)) return error.InvalidMeshHandle;
        if (mesh.indices.len % 3 != 0) return error.InvalidIndexCount;
        if (mesh.indices.len / 3 != handle.count) return error.InvalidMeshTriangleCount;
        if (mesh.colors) |colors| {
            if (colors.len != mesh.positions.len) return error.InvalidColorCount;
        }
        if (mesh.normals) |normals| {
            if (normals.len != mesh.positions.len) return error.InvalidNormalCount;
        }
        if (mesh.uvs) |uvs| {
            if (uvs.len != mesh.positions.len) return error.InvalidUvCount;
        }

        var i: usize = 0;
        while (i < mesh.indices.len) : (i += 3) {
            const idx0 = mesh.indices[i + 0];
            const idx1 = mesh.indices[i + 1];
            const idx2 = mesh.indices[i + 2];
            if (idx0 >= mesh.positions.len or idx1 >= mesh.positions.len or idx2 >= mesh.positions.len) {
                return error.IndexOutOfBounds;
            }
            self.triangles.items[handle.start + i / 3] = normalizeTriangle(.{
                .positions = .{
                    transform.transformPoint(mesh.positions[idx0]),
                    transform.transformPoint(mesh.positions[idx1]),
                    transform.transformPoint(mesh.positions[idx2]),
                },
                .color = mesh.color,
                .colors = if (mesh.colors) |colors| .{
                    colors[idx0],
                    colors[idx1],
                    colors[idx2],
                } else null,
                .uvs = if (mesh.uvs) |uvs| .{
                    uvs[idx0],
                    uvs[idx1],
                    uvs[idx2],
                } else null,
                .texture = mesh.texture,
                .texture_handle = mesh.texture_handle,
                .normal_texture = mesh.normal_texture,
                .normal_texture_handle = mesh.normal_texture_handle,
                .normals = if (mesh.normals) |normals| .{
                    transformNormal(normals[idx0], transform),
                    transformNormal(normals[idx1], transform),
                    transformNormal(normals[idx2], transform),
                } else null,
                .material = normalizeMaterial(mesh.material),
                .material_handle = mesh.material_handle,
            });
        }
    }
};

fn normalizePoint(point: Point3D) Point3D {
    var out = point;
    out.size = @max(1.0, point.size);
    return out;
}

fn normalizeLine(line: Line3D) Line3D {
    var out = line;
    out.width = @max(1.0, line.width);
    return out;
}

fn normalizeAxis(axis: Axis3D) Axis3D {
    var out = axis;
    out.length = @max(0.000001, axis.length);
    out.width = @max(1.0, axis.width);
    return out;
}

fn normalizeGrid(grid: Grid3D) Grid3D {
    var out = grid;
    out.x_extent = @max(0.000001, grid.x_extent);
    out.z_extent = @max(0.000001, grid.z_extent);
    out.spacing = @max(0.000001, grid.spacing);
    out.width = @max(1.0, grid.width);
    return out;
}

fn gridLineColor(grid: Grid3D, index: i32) Color {
    if (grid.major_every == 0) return grid.color;
    const major_every: i32 = @intCast(grid.major_every);
    return if (@mod(index, major_every) == 0) grid.major_color else grid.color;
}

fn normalizeDebugBox(box: DebugBox3D) DebugBox3D {
    return .{
        .min = .{
            .x = @min(box.min.x, box.max.x),
            .y = @min(box.min.y, box.max.y),
            .z = @min(box.min.z, box.max.z),
        },
        .max = .{
            .x = @max(box.min.x, box.max.x),
            .y = @max(box.min.y, box.max.y),
            .z = @max(box.min.z, box.max.z),
        },
        .color = box.color,
        .width = @max(1.0, box.width),
    };
}

fn normalizeVolumePlaceholder(volume: VolumePlaceholder3D) VolumePlaceholder3D {
    const normalized_box = normalizeDebugBox(.{
        .min = volume.min,
        .max = volume.max,
        .color = volume.color,
        .width = volume.width,
    });
    return .{
        .min = normalized_box.min,
        .max = normalized_box.max,
        .color = normalized_box.color,
        .slice_color = volume.slice_color,
        .width = normalized_box.width,
        .slices = volume.slices,
    };
}

fn normalizeRay(ray: Ray3D) ?Ray3D {
    const direction = ray.direction.normalize();
    if (direction.length() <= 0.000001) return null;
    return .{ .origin = ray.origin, .direction = direction };
}

const RayTriangleHit = struct {
    distance: f32,
    barycentric: [3]f32,
};

fn intersectRayTriangle(ray: Ray3D, triangle: Triangle3D) ?RayTriangleHit {
    const epsilon: f32 = 0.000001;
    const a = triangle.positions[0];
    const b = triangle.positions[1];
    const c = triangle.positions[2];
    const edge1 = b.sub(a);
    const edge2 = c.sub(a);
    const h = ray.direction.cross(edge2);
    const det = edge1.dot(h);
    if (@abs(det) <= epsilon) return null;
    const inv_det = 1.0 / det;
    const s = ray.origin.sub(a);
    const u = inv_det * s.dot(h);
    if (u < 0.0 or u > 1.0) return null;
    const q = s.cross(edge1);
    const v = inv_det * ray.direction.dot(q);
    if (v < 0.0 or u + v > 1.0) return null;
    const distance = inv_det * edge2.dot(q);
    if (distance <= epsilon) return null;
    return .{
        .distance = distance,
        .barycentric = .{ 1.0 - u - v, u, v },
    };
}

fn normalizeTriangle(triangle: Triangle3D) Triangle3D {
    var out = triangle;
    out.colors = triangleStaticColors(triangle);
    out.normals = triangleStaticNormals(triangle);
    out.material = normalizeMaterial(triangle.material);
    return out;
}

fn triangleStaticColors(triangle: Triangle3D) ?[3]Color {
    const base = triangle.colors orelse .{ triangle.color, triangle.color, triangle.color };
    if (triangle.texture) |texture| {
        if (triangle.uvs) |uvs| {
            return .{
                modulateColor(base[0], sampleTexture(texture, uvs[0])),
                modulateColor(base[1], sampleTexture(texture, uvs[1])),
                modulateColor(base[2], sampleTexture(texture, uvs[2])),
            };
        }
    }
    return triangle.colors;
}

fn triangleStaticNormals(triangle: Triangle3D) ?[3]math.Vec3 {
    if (triangle.normal_texture) |texture| {
        if (triangle.uvs) |uvs| {
            return .{
                decodeNormal(sampleTexture(texture, uvs[0])),
                decodeNormal(sampleTexture(texture, uvs[1])),
                decodeNormal(sampleTexture(texture, uvs[2])),
            };
        }
    }
    return triangle.normals;
}

fn triangleColors(triangle: Triangle3D, scene: *const Scene3D) [3]Color {
    const base = triangle.colors orelse .{ triangle.color, triangle.color, triangle.color };
    if (triangle.texture_handle) |handle| {
        if (scene.textureView(handle)) |texture| {
            if (triangle.uvs) |uvs| {
                return .{
                    modulateColor(base[0], sampleTexture(texture, uvs[0])),
                    modulateColor(base[1], sampleTexture(texture, uvs[1])),
                    modulateColor(base[2], sampleTexture(texture, uvs[2])),
                };
            }
        }
    }
    return base;
}

fn triangleNormals(triangle: Triangle3D, scene: *const Scene3D) ?[3]math.Vec3 {
    if (triangle.normal_texture_handle) |handle| {
        if (scene.textureView(handle)) |texture| {
            if (triangle.uvs) |uvs| {
                return .{
                    decodeNormal(sampleTexture(texture, uvs[0])),
                    decodeNormal(sampleTexture(texture, uvs[1])),
                    decodeNormal(sampleTexture(texture, uvs[2])),
                };
            }
        }
    }
    return triangle.normals;
}

fn decodeNormal(value: Color) math.Vec3 {
    return (math.Vec3{
        .x = @as(f32, @floatFromInt(value.r)) / 127.5 - 1.0,
        .y = @as(f32, @floatFromInt(value.g)) / 127.5 - 1.0,
        .z = @as(f32, @floatFromInt(value.b)) / 127.5 - 1.0,
    }).normalize();
}

fn sampleTexture(texture: Texture, uv: math.Vec2) Color {
    if (texture.width == 0 or texture.height == 0 or texture.pixels.len == 0) return .white;
    const x = sampleTextureCoord(uv.x, texture.width);
    const y = sampleTextureCoord(uv.y, texture.height);
    const index = @min(texture.pixels.len - 1, @as(usize, y) * texture.width + x);
    return texture.pixels[index];
}

fn sampleTextureCoord(t: f32, extent: u32) u32 {
    const scaled = @floor(@min(0.999999, @max(0.0, t)) * @as(f32, @floatFromInt(extent)));
    return @intFromFloat(scaled);
}

fn modulateColor(a: Color, b: Color) Color {
    return .{
        .r = @intCast((@as(u16, a.r) * b.r + 127) / 255),
        .g = @intCast((@as(u16, a.g) * b.g + 127) / 255),
        .b = @intCast((@as(u16, a.b) * b.b + 127) / 255),
        .a = @intCast((@as(u16, a.a) * b.a + 127) / 255),
    };
}

fn normalizeMaterial(material: Material) Material {
    return .{
        .ambient = @max(0.0, material.ambient),
        .diffuse = @max(0.0, material.diffuse),
        .roughness = @min(1.0, @max(0.0, material.roughness)),
        .metallic = @min(1.0, @max(0.0, material.metallic)),
        .emissive = material.emissive,
        .emissive_strength = @max(0.0, material.emissive_strength),
    };
}

fn normalizeLight(light: Light) Light {
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

fn transformNormals(normals: ?[3]math.Vec3, transform: math.Mat4) ?[3]math.Vec3 {
    const values = normals orelse return null;
    return .{
        transformNormal(values[0], transform),
        transformNormal(values[1], transform),
        transformNormal(values[2], transform),
    };
}

fn transformNormal(normal: math.Vec3, transform: math.Mat4) math.Vec3 {
    return transform.transformNormal(normal);
}

pub fn projectedTriangleVisible(triangle: Triangle3D, camera: Camera, cull_mode: CullMode) bool {
    const p0 = camera.transform.transformPoint(triangle.positions[0]);
    const p1 = camera.transform.transformPoint(triangle.positions[1]);
    const p2 = camera.transform.transformPoint(triangle.positions[2]);
    if (!clipTriangleVisible(.{ p0, p1, p2 })) return false;
    if (cull_mode == .none) return true;

    const area = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x);
    const front_facing = area < 0.0;
    return switch (cull_mode) {
        .none => true,
        .back => front_facing,
        .front => !front_facing,
    };
}

pub fn projectTriangle(triangle: Triangle3D, camera: Camera) [3]math.Vec3 {
    return .{
        camera.transform.transformPoint(triangle.positions[0]),
        camera.transform.transformPoint(triangle.positions[1]),
        camera.transform.transformPoint(triangle.positions[2]),
    };
}

pub fn projectedPointVisible(point: Point3D, camera: Camera) bool {
    const projected = projectPoint(point, camera);
    return projected.x >= -1.0 and projected.x <= 1.0 and
        projected.y >= -1.0 and projected.y <= 1.0 and
        projected.z >= 0.0 and projected.z <= 1.0;
}

pub fn projectPoint(point: Point3D, camera: Camera) math.Vec3 {
    return camera.transform.transformPoint(point.position);
}

pub fn projectedLineVisible(line: Line3D, camera: Camera) bool {
    return clipPointVisible(camera.transform.transformPoint(line.start)) and
        clipPointVisible(camera.transform.transformPoint(line.end));
}

pub fn projectLine(line: Line3D, camera: Camera) [2]math.Vec3 {
    return .{
        camera.transform.transformPoint(line.start),
        camera.transform.transformPoint(line.end),
    };
}

pub fn shadeTriangle(triangle: Triangle3D, scene: *const Scene3D) Color {
    return shadeTriangleColors(triangle, scene)[0];
}

pub fn shadeTriangleColors(triangle: Triangle3D, scene: *const Scene3D) [3]Color {
    const colors = triangleColors(triangle, scene);
    const material = triangleMaterial(scene, triangle);
    if (!scene.lighting_enabled) return .{
        applyMaterialColor(colors[0], 1.0, .{ .ambient = 0.0, .diffuse = 0.0, .emissive = material.emissive, .emissive_strength = material.emissive_strength }),
        applyMaterialColor(colors[1], 1.0, .{ .ambient = 0.0, .diffuse = 0.0, .emissive = material.emissive, .emissive_strength = material.emissive_strength }),
        applyMaterialColor(colors[2], 1.0, .{ .ambient = 0.0, .diffuse = 0.0, .emissive = material.emissive, .emissive_strength = material.emissive_strength }),
    };

    if (triangleNormals(triangle, scene)) |normals| {
        return .{
            shadeColor(colors[0], normals[0], triangle.positions[0], material, scene),
            shadeColor(colors[1], normals[1], triangle.positions[1], material, scene),
            shadeColor(colors[2], normals[2], triangle.positions[2], material, scene),
        };
    }

    const normal = faceNormal(triangle);
    const center = triangle.positions[0].add(triangle.positions[1]).add(triangle.positions[2]).scale(1.0 / 3.0);
    const intensity = lightIntensity(normal, center, material, scene);
    return .{
        applyMaterialColor(colors[0], intensity, material),
        applyMaterialColor(colors[1], intensity, material),
        applyMaterialColor(colors[2], intensity, material),
    };
}

fn triangleMaterial(self: *const Scene3D, triangle: Triangle3D) Material {
    if (triangle.material_handle) |handle| {
        return self.materialView(handle) orelse normalizeMaterial(triangle.material);
    }
    return normalizeMaterial(triangle.material);
}

fn shadeColor(value: Color, normal: math.Vec3, position: math.Vec3, material: Material, scene: *const Scene3D) Color {
    return applyMaterialColor(value, lightIntensity(normal.normalize(), position, material, scene), material);
}

fn faceNormal(triangle: Triangle3D) math.Vec3 {
    const a = triangle.positions[0];
    const b = triangle.positions[1];
    const c = triangle.positions[2];
    return b.sub(a).cross(c.sub(a)).normalize();
}

fn lightIntensity(normal: math.Vec3, position: math.Vec3, material: Material, scene: *const Scene3D) f32 {
    const mat = normalizeMaterial(material);
    var intensity = singleLightIntensity(normal, position, mat, scene.light);
    for (scene.lights.items) |light| {
        intensity += singleLightIntensity(normal, position, mat, light);
    }
    return @min(1.0, intensity);
}

fn singleLightIntensity(normal: math.Vec3, position: math.Vec3, material: Material, light: Light) f32 {
    var falloff: f32 = 1.0;
    const light_dir = switch (light.kind) {
        .directional => light.direction,
        .point, .spot => blk: {
            const offset = light.position.sub(position);
            const distance = offset.length();
            if (distance > light.range) return light.ambient;
            if (light.kind == .spot) {
                const from_light = position.sub(light.position).normalize();
                const cone = from_light.dot(light.direction);
                const outer = @cos(light.outer_angle);
                if (cone <= outer) return light.ambient;
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
    };
    const ndotl = @max(0.0, normal.dot(light_dir));
    const specular = material.metallic * (1.0 - material.roughness) * ndotl * ndotl;
    return light.ambient * material.ambient + light.diffuse * (material.diffuse * ndotl + specular) * falloff;
}

fn scaleColor(value: Color, intensity: f32) Color {
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(value.r)) * intensity)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(value.g)) * intensity)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(value.b)) * intensity)),
        .a = value.a,
    };
}

fn applyMaterialColor(value: Color, intensity: f32, material: Material) Color {
    const lit = scaleColor(value, intensity);
    const mat = normalizeMaterial(material);
    return .{
        .r = addEmissiveChannel(lit.r, mat.emissive.r, mat.emissive_strength),
        .g = addEmissiveChannel(lit.g, mat.emissive.g, mat.emissive_strength),
        .b = addEmissiveChannel(lit.b, mat.emissive.b, mat.emissive_strength),
        .a = lit.a,
    };
}

fn addEmissiveChannel(base: u8, emissive: u8, strength: f32) u8 {
    return @intFromFloat(@round(@min(255.0, @as(f32, @floatFromInt(base)) + @as(f32, @floatFromInt(emissive)) * strength)));
}

fn clipTriangleVisible(points: [3]math.Vec3) bool {
    var all_left = true;
    var all_right = true;
    var all_above = true;
    var all_below = true;
    var all_behind_near = true;
    var all_beyond_far = true;

    for (points) |p| {
        all_left = all_left and p.x < -1.0;
        all_right = all_right and p.x > 1.0;
        all_above = all_above and p.y < -1.0;
        all_below = all_below and p.y > 1.0;
        all_behind_near = all_behind_near and p.z < 0.0;
        all_beyond_far = all_beyond_far and p.z > 1.0;
    }

    return !(all_left or all_right or all_above or all_below or all_behind_near or all_beyond_far);
}

fn clipPointVisible(point: math.Vec3) bool {
    return point.x >= -1.0 and point.x <= 1.0 and
        point.y >= -1.0 and point.y <= 1.0 and
        point.z >= 0.0 and point.z <= 1.0;
}

test "3D scene owns appended mesh triangles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const tris = [_]Triangle3D{.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
    }};
    try scene.addMesh(.{ .triangles = &tris });

    try std.testing.expectEqual(@as(usize, 1), scene.triangles.items.len);
}

test "3D scene can append transformed meshes" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const tris = [_]Triangle3D{.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
    }};
    try scene.addMeshTransformed(.{ .triangles = &tris }, math.Mat4.translation(.{ .x = 2, .y = 3, .z = 4 }));

    try std.testing.expectEqual(@as(f32, 2), scene.triangles.items[0].positions[0].x);
    try std.testing.expectEqual(@as(f32, 3), scene.triangles.items[0].positions[0].y);
    try std.testing.expectEqual(@as(f32, 4), scene.triangles.items[0].positions[0].z);
}

test "3D scene lowers mesh instances to transformed triangles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const tris = [_]Triangle3D{.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } },
    }};
    const transforms = [_]math.Mat4{
        math.Mat4.translation(.{ .x = 1 }),
        math.Mat4.translation(.{ .x = 3 }).mul(math.Mat4.rotationZ(std.math.pi / 2.0)),
    };
    const handle = try scene.addMeshInstances(.{
        .mesh = .{ .triangles = &tris },
        .transforms = &transforms,
    });

    const view = scene.meshView(handle).?;
    try std.testing.expectEqual(@as(usize, 2), view.len);
    try std.testing.expectEqual(@as(f32, 1), view[0].positions[0].x);
    try std.testing.expectEqual(@as(f32, 3), view[1].positions[0].x);
    try std.testing.expect(@abs(view[1].normals.?[0].x) < 0.0001);
    try std.testing.expect(@abs(view[1].normals.?[0].y - 1.0) < 0.0001);

    const empty = try scene.addMeshInstances(.{
        .mesh = .{ .triangles = &tris },
        .transforms = &.{},
    });
    try std.testing.expectEqual(@as(usize, 0), empty.count);
}

test "3D scene selects and lowers mesh LOD levels" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const near_tris = [_]Triangle3D{
        .{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .red },
        .{ .positions = .{ .{}, .{ .x = -1 }, .{ .y = -1 } }, .color = .green },
    };
    const far_tris = [_]Triangle3D{
        .{ .positions = .{ .{}, .{ .x = 2 }, .{ .y = 2 } }, .color = .blue },
    };
    const levels = [_]MeshLodLevel{
        .{ .max_distance = 2.0, .mesh = .{ .triangles = &near_tris } },
        .{ .max_distance = 8.0, .mesh = .{ .triangles = &far_tris } },
    };
    const lod = MeshLod{ .levels = &levels };

    try std.testing.expectEqual(@as(usize, near_tris.len), Scene3D.selectMeshLod(lod, 1.0).?.triangles.len);
    try std.testing.expectEqual(@as(usize, far_tris.len), Scene3D.selectMeshLod(lod, 4.0).?.triangles.len);
    try std.testing.expectEqual(@as(usize, far_tris.len), Scene3D.selectMeshLod(lod, 40.0).?.triangles.len);
    try std.testing.expect(Scene3D.selectMeshLod(.{ .levels = &.{} }, 1.0) == null);

    const handle = try scene.addMeshLod(lod, 4.0, math.Mat4.translation(.{ .x = 5 }));
    const view = scene.meshView(handle).?;
    try std.testing.expectEqual(@as(usize, far_tris.len), view.len);
    try std.testing.expectEqual(Color.blue, view[0].color);
    try std.testing.expectEqual(@as(f32, 5), view[0].positions[0].x);
    try std.testing.expectError(error.EmptyLod, scene.addMeshLod(.{ .levels = &.{} }, 1.0, .identity));
}

test "3D scene stores point clouds with handles and transforms" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const points = [_]Point3D{
        .{ .position = .{ .x = 1 }, .color = .red, .size = 0.25 },
        .{ .position = .{ .y = 1 }, .color = .green, .size = 3.0 },
    };
    const handle = try scene.addPointCloudTransformedHandle(.{ .points = &points }, math.Mat4.translation(.{ .x = 2, .y = 3, .z = 4 }));
    const single = try scene.addPointHandle(.{ .position = .{}, .color = .blue, .size = 2.0 });

    const view = scene.pointCloudView(handle).?;
    try std.testing.expectEqual(@as(usize, 2), view.len);
    try std.testing.expectEqual(@as(f32, 3), view[0].position.x);
    try std.testing.expectEqual(@as(f32, 3), view[0].position.y);
    try std.testing.expectEqual(@as(f32, 4), view[0].position.z);
    try std.testing.expectEqual(@as(f32, 1), view[0].size);
    try std.testing.expectEqual(@as(f32, 3), view[1].size);
    try std.testing.expectEqual(Color.blue, scene.pointView(single).?.color);
    try std.testing.expect(scene.pointCloudView(.{ .start = 99, .count = 1 }) == null);
    try std.testing.expectError(error.InvalidPointHandle, scene.replacePoint(.{ .index = 99 }, .{ .position = .{} }));
}

test "3D scene stores line handles and normalizes width" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addLineHandle(.{
        .start = .{ .x = -1 },
        .end = .{ .x = 1 },
        .color = .red,
        .width = 0.2,
    });
    try std.testing.expectEqual(@as(usize, 1), scene.lines.items.len);
    try std.testing.expectEqual(@as(f32, 1), scene.lineView(handle).?.width);

    try scene.replaceLine(handle, .{
        .start = .{ .y = -1 },
        .end = .{ .y = 1 },
        .color = .blue,
        .width = 3.0,
    });
    try std.testing.expectEqual(Color.blue, scene.lineView(handle).?.color);
    try std.testing.expectEqual(@as(f32, 3), scene.lineView(handle).?.width);
    try std.testing.expect(scene.lineView(.{ .index = 99 }) == null);
    try std.testing.expectError(error.InvalidLineHandle, scene.replaceLine(.{ .index = 99 }, .{ .start = .{}, .end = .{ .x = 1 } }));
}

test "3D scene lowers axis primitive to colored lines" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addAxis(.{
        .origin = .{ .x = 1, .y = 2, .z = 3 },
        .length = 0.0,
        .width = 0.5,
    });

    try std.testing.expectEqual(@as(usize, 3), scene.lines.items.len);
    try std.testing.expectEqual(Color.red, scene.lines.items[0].color);
    try std.testing.expectEqual(Color.green, scene.lines.items[1].color);
    try std.testing.expectEqual(Color.blue, scene.lines.items[2].color);
    try std.testing.expectEqual(@as(f32, 1), scene.lines.items[0].width);
    try std.testing.expect(scene.lines.items[0].end.x > scene.lines.items[0].start.x);
    try std.testing.expect(scene.lines.items[1].end.y > scene.lines.items[1].start.y);
    try std.testing.expect(scene.lines.items[2].end.z > scene.lines.items[2].start.z);
}

test "3D scene lowers grid primitive to xz plane lines" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addGrid(.{
        .origin = .{ .y = -1 },
        .x_extent = 1.0,
        .z_extent = 0.5,
        .spacing = 0.5,
        .width = 0.25,
        .color = .blue,
        .major_color = .white,
        .major_every = 2,
    });

    try std.testing.expectEqual(@as(usize, 8), scene.lines.items.len);
    var has_major = false;
    var has_minor = false;
    for (scene.lines.items) |line| {
        has_major = has_major or line.color == Color.white;
        has_minor = has_minor or line.color == Color.blue;
    }
    try std.testing.expect(has_major);
    try std.testing.expect(has_minor);
    try std.testing.expectEqual(@as(f32, 1), scene.lines.items[0].width);
    try std.testing.expectEqual(@as(f32, -1), scene.lines.items[0].start.y);
    try std.testing.expect(scene.lines.items[0].start.x < scene.lines.items[0].end.x);
    try std.testing.expect(scene.lines.items[3].start.z < scene.lines.items[3].end.z);
}

test "3D scene lowers debug boxes to twelve lines" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addDebugBox(.{
        .min = .{ .x = 1, .y = 2, .z = 3 },
        .max = .{ .x = -1, .y = 0, .z = 2 },
        .color = .green,
        .width = 0.25,
    });

    try std.testing.expectEqual(@as(usize, 12), scene.lines.items.len);
    for (scene.lines.items) |line| {
        try std.testing.expectEqual(Color.green, line.color);
        try std.testing.expectEqual(@as(f32, 1), line.width);
    }
    try std.testing.expectEqual(@as(f32, -1), scene.lines.items[0].start.x);
    try std.testing.expectEqual(@as(f32, 1), scene.lines.items[0].end.x);
    try std.testing.expectEqual(@as(f32, 3), scene.lines.items[8].end.z);
}

test "3D scene lowers volume placeholders to bounds and slices" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addVolumePlaceholder(.{
        .min = .{ .x = 1, .y = 1, .z = 1 },
        .max = .{ .x = -1, .y = -1, .z = -1 },
        .color = .white,
        .slice_color = .blue,
        .width = 0.25,
        .slices = 2,
    });

    try std.testing.expectEqual(@as(usize, 20), scene.lines.items.len);
    try std.testing.expectEqual(Color.white, scene.lines.items[0].color);
    try std.testing.expectEqual(Color.blue, scene.lines.items[12].color);
    try std.testing.expectEqual(@as(f32, 1), scene.lines.items[12].width);
    try std.testing.expect(scene.lines.items[12].start.z > -1.0);
    try std.testing.expect(scene.lines.items[12].start.z < 1.0);
}

test "3D scene picks nearest triangle with world-space ray" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 2.0 },
            .{ .x = 0.5, .y = -0.5, .z = 2.0 },
            .{ .x = 0.0, .y = 0.5, .z = 2.0 },
        },
        .color = .blue,
    });
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 1.0 },
            .{ .x = 0.5, .y = -0.5, .z = 1.0 },
            .{ .x = 0.0, .y = 0.5, .z = 1.0 },
        },
        .color = .red,
    });

    const hit = scene.pickTriangle(.{ .origin = .{}, .direction = .{ .z = 2.0 } }).?;
    try std.testing.expectEqual(@as(usize, 1), hit.triangle_index);
    try std.testing.expect(@abs(hit.distance - 1.0) < 0.0001);
    try std.testing.expect(@abs(hit.position.z - 1.0) < 0.0001);
    try std.testing.expect(@abs(hit.barycentric[0] + hit.barycentric[1] + hit.barycentric[2] - 1.0) < 0.0001);
}

test "3D camera builds world ray from screen coordinates" {
    const camera = Camera.perspectiveLookAt(
        .{ .z = 3 },
        .{},
        .{ .y = 1 },
        std.math.pi / 2.0,
        1.0,
        0.1,
        100.0,
    );
    const ray = camera.rayFromScreen(.{ .width = 100, .height = 100 }, .{ .x = 50, .y = 50 }).?;

    try std.testing.expect(@abs(ray.origin.x) < 0.0001);
    try std.testing.expect(@abs(ray.origin.y) < 0.0001);
    try std.testing.expect(ray.origin.z < 3.0);
    try std.testing.expect(@abs(ray.direction.x) < 0.0001);
    try std.testing.expect(@abs(ray.direction.y) < 0.0001);
    try std.testing.expect(ray.direction.z < -0.999);
    try std.testing.expect(camera.rayFromScreen(.{ .width = 0, .height = 100 }, .{}) == null);
}

test "3D scene picks triangle from camera screen ray" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCamera(Camera.perspectiveLookAt(
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
        .color = .red,
    });

    const ray = scene.camera.rayFromScreen(.{ .width = 100, .height = 100 }, .{ .x = 50, .y = 50 }).?;
    const hit = scene.pickTriangle(ray).?;
    try std.testing.expectEqual(@as(usize, 0), hit.triangle_index);
    try std.testing.expect(@abs(hit.position.x) < 0.0001);
    try std.testing.expect(@abs(hit.position.y) < 0.0001);
    try std.testing.expect(@abs(hit.position.z) < 0.0001);
}

test "3D scene picking rejects misses and degenerate rays" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 1.0 },
            .{ .x = 0.5, .y = -0.5, .z = 1.0 },
            .{ .x = 0.0, .y = 0.5, .z = 1.0 },
        },
        .color = .red,
    });

    try std.testing.expect(scene.pickTriangle(.{ .origin = .{ .x = 2 }, .direction = .{ .z = 1 } }) == null);
    try std.testing.expect(scene.pickTriangle(.{ .origin = .{}, .direction = .{} }) == null);
}

test "3D scene replaces mesh handle storage" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Triangle3D{ .{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .red,
    }, .{
        .positions = .{ .{}, .{ .x = -1 }, .{ .y = -1 } },
        .color = .green,
    } };
    const handle = try scene.addMeshHandle(.{ .triangles = &original });
    const replacement = [_]Triangle3D{ .{
        .positions = .{ .{}, .{ .x = 2 }, .{ .y = 2 } },
        .color = .blue,
    }, .{
        .positions = .{ .{}, .{ .x = -2 }, .{ .y = -2 } },
        .color = .white,
    } };

    try scene.replaceMesh(handle, .{ .triangles = &replacement });

    const view = scene.meshView(handle).?;
    try std.testing.expectEqual(@as(usize, 2), view.len);
    try std.testing.expectEqual(Color.blue, view[0].color);
    try std.testing.expectEqual(Color.white, view[1].color);
    try std.testing.expectEqual(@as(f32, 2), view[0].positions[1].x);
    try std.testing.expect(scene.meshView(.{ .start = 99, .count = 1 }) == null);
    try std.testing.expectError(error.InvalidMeshHandle, scene.replaceMesh(.{ .start = 99, .count = 1 }, .{ .triangles = &replacement }));
    try std.testing.expectError(error.InvalidMeshTriangleCount, scene.replaceMesh(handle, .{ .triangles = replacement[0..1] }));
}

test "3D scene replaces transformed mesh handle storage" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Triangle3D{.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } },
    }};
    const handle = try scene.addMeshHandle(.{ .triangles = &original });
    try scene.replaceMeshTransformed(handle, .{ .triangles = &original }, math.Mat4.translation(.{ .x = 2, .y = 3, .z = 4 }).mul(math.Mat4.rotationZ(std.math.pi / 2.0)));

    const triangle = scene.meshView(handle).?[0];
    try std.testing.expectEqual(@as(f32, 2), triangle.positions[0].x);
    try std.testing.expectEqual(@as(f32, 3), triangle.positions[0].y);
    try std.testing.expectEqual(@as(f32, 4), triangle.positions[0].z);
    try std.testing.expect(@abs(triangle.normals.?[0].x) < 0.0001);
    try std.testing.expect(@abs(triangle.normals.?[0].y - 1.0) < 0.0001);
}

test "3D triangles sample texture colors at UVs" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const pixels = [_]Color{ .red, .green, .blue, .white };
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .texture = .{ .width = 2, .height = 2, .pixels = &pixels },
    });

    const colors = scene.triangles.items[0].vertexColors();
    try std.testing.expectEqual(Color.red, colors[0]);
    try std.testing.expectEqual(Color.green, colors[1]);
    try std.testing.expectEqual(Color.blue, colors[2]);
}

test "3D scene owns added texture pixels" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    var pixels = [_]Color{ .red, .green, .blue, .white };
    const texture = try scene.addTexture(.{ .width = 2, .height = 2, .pixels = &pixels });
    pixels[0] = .black;

    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .texture = texture,
    });

    const colors = scene.triangles.items[0].vertexColors();
    try std.testing.expectEqual(Color.red, colors[0]);
    try std.testing.expectEqual(@as(usize, 1), scene.textures.items.len);
}

test "3D scene exposes texture handles" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    var pixels = [_]Color{ .red, .green, .blue, .white };
    const handle = try scene.addTextureHandle(.{ .width = 2, .height = 2, .pixels = &pixels });
    pixels[0] = .black;

    const view = scene.textureView(handle).?;
    try std.testing.expectEqual(Color.red, view.pixels[0]);
    try std.testing.expect(scene.textureView(.{ .index = 99 }) == null);
}

test "3D scene replaces texture handle storage" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Color{.red};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &original });
    const replacement = [_]Color{.blue};
    try scene.replaceTexture(handle, .{ .width = 1, .height = 1, .pixels = &replacement });
    try std.testing.expectEqual(Color.blue, scene.textureView(handle).?.pixels[0]);
    try std.testing.expectError(error.InvalidTextureHandle, scene.replaceTexture(.{ .index = 99 }, .{ .width = 1, .height = 1, .pixels = &replacement }));
}

test "3D scene replaces texture handles in batches" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const red = [_]Color{.red};
    const green = [_]Color{.green};
    const blue = [_]Color{.blue};
    const white = [_]Color{.white};
    const first = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &red });
    const second = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &green });

    try scene.replaceTextures(&.{
        .{ .handle = first, .texture = .{ .width = 1, .height = 1, .pixels = &blue } },
        .{ .handle = second, .texture = .{ .width = 1, .height = 1, .pixels = &white } },
    });

    try std.testing.expectEqual(Color.blue, scene.textureView(first).?.pixels[0]);
    try std.testing.expectEqual(Color.white, scene.textureView(second).?.pixels[0]);
}

test "3D scene batch texture replacement validates before writing" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const red = [_]Color{.red};
    const blue = [_]Color{.blue};
    const white = [_]Color{.white};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &red });

    try std.testing.expectError(error.InvalidTextureHandle, scene.replaceTextures(&.{
        .{ .handle = handle, .texture = .{ .width = 1, .height = 1, .pixels = &blue } },
        .{ .handle = .{ .index = 99 }, .texture = .{ .width = 1, .height = 1, .pixels = &white } },
    }));

    try std.testing.expectEqual(Color.red, scene.textureView(handle).?.pixels[0]);
}

test "3D scene replaces material handle storage" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addMaterialHandle(.{ .ambient = 0.25, .diffuse = 0.5, .roughness = 2.0, .metallic = -1.0 });
    var material = scene.materialView(handle).?;
    try std.testing.expectEqual(@as(f32, 0.25), material.ambient);
    try std.testing.expectEqual(@as(f32, 1.0), material.roughness);
    try std.testing.expectEqual(@as(f32, 0.0), material.metallic);

    try scene.replaceMaterial(handle, .{ .ambient = 0.5, .diffuse = 0.25, .emissive = .blue, .emissive_strength = 0.5 });
    material = scene.materialView(handle).?;
    try std.testing.expectEqual(@as(f32, 0.5), material.ambient);
    try std.testing.expectEqual(Color.blue, material.emissive);
    try std.testing.expect(scene.materialView(.{ .index = 99 }) == null);
    try std.testing.expectError(error.InvalidMaterialHandle, scene.replaceMaterial(.{ .index = 99 }, .{}));
}

test "3D scene replaces material handles in batches" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const first = try scene.addMaterialHandle(.{ .emissive = .red, .emissive_strength = 1.0 });
    const second = try scene.addMaterialHandle(.{ .emissive = .green, .emissive_strength = 1.0 });
    try scene.replaceMaterials(&.{
        .{ .handle = first, .material = .{ .emissive = .blue, .emissive_strength = 1.0 } },
        .{ .handle = second, .material = .{ .emissive = .white, .emissive_strength = 0.5 } },
    });

    try std.testing.expectEqual(Color.blue, scene.materialView(first).?.emissive);
    try std.testing.expectEqual(Color.white, scene.materialView(second).?.emissive);
    try std.testing.expectEqual(@as(f32, 0.5), scene.materialView(second).?.emissive_strength);
}

test "3D scene batch material replacement validates before writing" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addMaterialHandle(.{ .emissive = .red, .emissive_strength = 1.0 });
    try std.testing.expectError(error.InvalidMaterialHandle, scene.replaceMaterials(&.{
        .{ .handle = handle, .material = .{ .emissive = .blue, .emissive_strength = 1.0 } },
        .{ .handle = .{ .index = 99 }, .material = .{ .emissive = .white, .emissive_strength = 1.0 } },
    }));

    try std.testing.expectEqual(Color.red, scene.materialView(handle).?.emissive);
}

test "3D material handles update shading without replacing geometry" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addMaterialHandle(.{ .emissive = .red, .emissive_strength = 1.0 });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .black,
        .material_handle = handle,
    });

    var colors = shadeTriangleColors(scene.triangles.items[0], &scene);
    try std.testing.expectEqual(Color.red, colors[0]);

    try scene.replaceMaterial(handle, .{ .emissive = .blue, .emissive_strength = 1.0 });
    colors = shadeTriangleColors(scene.triangles.items[0], &scene);
    try std.testing.expectEqual(Color.blue, colors[0]);
}

test "3D texture handles update shading without replacing geometry" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Color{.red};
    const replacement = [_]Color{.blue};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &original });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = handle,
    });

    var colors = shadeTriangleColors(scene.triangles.items[0], &scene);
    try std.testing.expectEqual(Color.red, colors[0]);

    try scene.replaceTexture(handle, .{ .width = 1, .height = 1, .pixels = &replacement });
    colors = shadeTriangleColors(scene.triangles.items[0], &scene);
    try std.testing.expectEqual(Color.blue, colors[0]);
}

test "3D batch texture replacement updates bound geometry shading" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const red = [_]Color{.red};
    const green = [_]Color{.green};
    const blue = [_]Color{.blue};
    const white = [_]Color{.white};
    const first = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &red });
    const second = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &green });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture_handle = first,
    });

    try scene.replaceTextures(&.{
        .{ .handle = first, .texture = .{ .width = 1, .height = 1, .pixels = &blue } },
        .{ .handle = second, .texture = .{ .width = 1, .height = 1, .pixels = &white } },
    });

    const colors = shadeTriangleColors(scene.triangles.items[0], &scene);
    try std.testing.expectEqual(Color.blue, colors[0]);
}

test "3D normal texture handles update shading without replacing geometry" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 1.0 });
    const dark_normal = [_]Color{Color.rgba(255, 128, 128, 255)};
    const lit_normal = [_]Color{Color.rgba(128, 128, 255, 255)};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &dark_normal });
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .normal_texture_handle = handle,
    });

    var colors = shadeTriangleColors(scene.triangles.items[0], &scene);
    try std.testing.expect(colors[0].r <= 2);

    try scene.replaceTexture(handle, .{ .width = 1, .height = 1, .pixels = &lit_normal });
    colors = shadeTriangleColors(scene.triangles.items[0], &scene);
    try std.testing.expect(colors[0].r > 250);
}

test "3D scene replaces triangle handles in batches" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const first = try scene.addTriangleHandle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .red });
    const second = try scene.addTriangleHandle(.{ .positions = .{ .{}, .{ .x = -1 }, .{ .y = -1 } }, .color = .green });
    try scene.replaceTriangles(&.{
        .{ .handle = first, .triangle = .{ .positions = .{ .{}, .{ .x = 2 }, .{ .y = 2 } }, .color = .blue } },
        .{ .handle = second, .triangle = .{ .positions = .{ .{}, .{ .x = -2 }, .{ .y = -2 } }, .color = .white } },
    });

    try std.testing.expectEqual(Color.blue, scene.triangleView(first).?.color);
    try std.testing.expectEqual(Color.white, scene.triangleView(second).?.color);
    try std.testing.expectEqual(@as(f32, 2), scene.triangleView(first).?.positions[1].x);
}

test "3D scene batch triangle replacement validates before writing" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addTriangleHandle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .red });
    try std.testing.expectError(error.InvalidTriangleHandle, scene.replaceTriangles(&.{
        .{ .handle = handle, .triangle = .{ .positions = .{ .{}, .{ .x = 2 }, .{ .y = 2 } }, .color = .blue } },
        .{ .handle = .{ .index = 99 }, .triangle = .{ .positions = .{ .{}, .{ .x = 3 }, .{ .y = 3 } }, .color = .white } },
    }));

    try std.testing.expectEqual(Color.red, scene.triangleView(handle).?.color);
}

test "3D material handles are preserved across geometry clears" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const handle = try scene.addMaterialHandle(.{ .emissive = .green, .emissive_strength = 1.0 });
    try scene.addTriangle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .white });

    scene.clearGeometry();

    try std.testing.expectEqual(@as(usize, 0), scene.triangles.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.materials.items.len);
    try std.testing.expectEqual(Color.green, scene.materialView(handle).?.emissive);
}

test "3D scene replaces triangle handle storage" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const original = [_]Color{.red};
    const replacement = [_]Color{.blue};
    const texture_handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &original });
    const triangle_handle = try scene.addTriangleHandle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture = scene.textureView(texture_handle).?,
    });

    try scene.replaceTexture(texture_handle, .{ .width = 1, .height = 1, .pixels = &replacement });
    try scene.replaceTriangle(triangle_handle, .{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{}, .{} },
        .texture = scene.textureView(texture_handle).?,
    });

    try std.testing.expectEqual(Color.blue, scene.triangleView(triangle_handle).?.vertexColors()[0]);
    try std.testing.expect(scene.triangleView(.{ .index = 99 }) == null);
    try std.testing.expectError(error.InvalidTriangleHandle, scene.replaceTriangle(.{ .index = 99 }, .{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
    }));
}

test "3D scene clears geometry without dropping resources or state" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const pixels = [_]Color{.red};
    const handle = try scene.addTextureHandle(.{ .width = 1, .height = 1, .pixels = &pixels });
    scene.setCullMode(.back);
    scene.setLight(.{ .direction = .{ .z = 1 } });
    try scene.addTriangle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .white });

    scene.clearGeometry();

    try std.testing.expectEqual(@as(usize, 0), scene.triangles.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.textures.items.len);
    try std.testing.expect(scene.lighting_enabled);
    try std.testing.expectEqual(CullMode.back, scene.cull_mode);
    try std.testing.expectEqual(Color.red, scene.textureView(handle).?.pixels[0]);
}

test "3D scene owns added normal map pixels" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    var normals = [_]Color{
        Color.rgba(128, 128, 255, 255),
        Color.rgba(255, 128, 128, 255),
        Color.rgba(128, 255, 128, 255),
        Color.rgba(128, 128, 255, 255),
    };
    const normal_texture = try scene.addTexture(.{ .width = 2, .height = 2, .pixels = &normals });
    normals[0] = Color.rgba(255, 128, 128, 255);

    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .normal_texture = normal_texture,
    });

    const sampled = scene.triangles.items[0].normals.?;
    try std.testing.expect(sampled[0].z > 0.99);
    try std.testing.expectEqual(@as(usize, 1), scene.textures.items.len);
}

test "3D scene transforms mesh normals" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const tris = [_]Triangle3D{.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } },
    }};
    try scene.addMeshTransformed(.{ .triangles = &tris }, math.Mat4.rotationZ(std.math.pi / 2.0));

    const normals = scene.triangles.items[0].normals.?;
    try std.testing.expect(@abs(normals[0].x) < 0.0001);
    try std.testing.expect(@abs(normals[0].y - 1.0) < 0.0001);
    try std.testing.expect(@abs(normals[0].length() - 1.0) < 0.0001);
}

test "3D scene transforms mesh positions and normals around x and y axes" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const tris = [_]Triangle3D{.{
        .positions = .{ .{}, .{ .y = 1 }, .{ .z = 1 } },
        .color = .white,
        .normals = .{ .{ .y = 1 }, .{ .y = 1 }, .{ .y = 1 } },
    }};
    const transform = math.Mat4.rotationY(std.math.pi / 2.0).mul(math.Mat4.rotationX(std.math.pi / 2.0));
    try scene.addMeshTransformed(.{ .triangles = &tris }, transform);

    const triangle = scene.triangles.items[0];
    try std.testing.expect(@abs(triangle.positions[1].x - 1.0) < 0.0001);
    try std.testing.expect(@abs(triangle.positions[2].y + 1.0) < 0.0001);

    const normals = triangle.normals.?;
    try std.testing.expect(@abs(normals[0].x - 1.0) < 0.0001);
    try std.testing.expect(@abs(normals[0].y) < 0.0001);
    try std.testing.expect(@abs(normals[0].z) < 0.0001);
}

test "3D scene transforms normals with inverse transpose under non-uniform scale" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const tris = [_]Triangle3D{.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 } },
    }};
    try scene.addMeshTransformed(.{ .triangles = &tris }, math.Mat4.scale(.{ .x = 2, .y = 1, .z = 1 }));

    const normal = scene.triangles.items[0].normals.?[0];
    try std.testing.expect(@abs(normal.length() - 1.0) < 0.0001);
    try std.testing.expect(@abs(normal.x - 0.4472136) < 0.0001);
    try std.testing.expect(@abs(normal.y - 0.8944272) < 0.0001);
}

test "3D scene expands indexed meshes" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 }, .{ .x = 1, .y = 1 } };
    const indices = [_]u32{ 0, 1, 2, 1, 3, 2 };
    try scene.addIndexedMesh(.{ .positions = &positions, .indices = &indices, .color = .white });

    try std.testing.expectEqual(@as(usize, 2), scene.triangles.items.len);
    try std.testing.expectEqual(@as(f32, 1), scene.triangles.items[1].positions[1].x);
    try std.testing.expectEqual(@as(f32, 1), scene.triangles.items[1].positions[1].y);
}

test "3D scene expands indexed mesh vertex colors" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 } };
    const colors = [_]Color{ .red, .green, .blue };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMesh(.{
        .positions = &positions,
        .indices = &indices,
        .color = .white,
        .colors = &colors,
    });

    const vertex_colors = scene.triangles.items[0].vertexColors();
    try std.testing.expectEqual(Color.red, vertex_colors[0]);
    try std.testing.expectEqual(Color.green, vertex_colors[1]);
    try std.testing.expectEqual(Color.blue, vertex_colors[2]);
}

test "3D indexed meshes sample texture colors at UVs" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 } };
    const uvs = [_]math.Vec2{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } };
    const indices = [_]u32{ 0, 1, 2 };
    const pixels = [_]Color{ .red, .green, .blue, .white };
    try scene.addIndexedMesh(.{
        .positions = &positions,
        .indices = &indices,
        .color = .white,
        .uvs = &uvs,
        .texture = .{ .width = 2, .height = 2, .pixels = &pixels },
    });

    const colors = scene.triangles.items[0].vertexColors();
    try std.testing.expectEqual(Color.red, colors[0]);
    try std.testing.expectEqual(Color.green, colors[1]);
    try std.testing.expectEqual(Color.blue, colors[2]);
}

test "3D triangles sample object-space normal maps at UVs" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const normals = [_]Color{
        Color.rgba(128, 128, 255, 255),
        Color.rgba(255, 128, 128, 255),
        Color.rgba(128, 255, 128, 255),
        Color.rgba(128, 128, 255, 255),
    };
    try scene.addTriangle(.{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .uvs = .{ .{}, .{ .x = 0.75 }, .{ .y = 0.75 } },
        .normal_texture = .{ .width = 2, .height = 2, .pixels = &normals },
    });

    const sampled = scene.triangles.items[0].normals.?;
    try std.testing.expect(sampled[0].z > 0.99);
    try std.testing.expect(sampled[1].x > 0.99);
    try std.testing.expect(sampled[2].y > 0.99);
}

test "3D triangles can carry per-vertex colors" {
    const tri = Triangle3D{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .colors = .{ .red, .green, .blue },
    };
    const colors = tri.vertexColors();
    try std.testing.expectEqual(Color.red, colors[0]);
    try std.testing.expectEqual(Color.green, colors[1]);
    try std.testing.expectEqual(Color.blue, colors[2]);
}

test "3D triangles can carry per-vertex normals for lighting" {
    var scene = Scene3D.init(std.testing.allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 1.0 });

    const tri = Triangle3D{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = -1 }, .{ .z = 1 } },
    };
    const colors = shadeTriangleColors(tri, &scene);
    try std.testing.expectEqual(Color.white, colors[0]);
    try std.testing.expectEqual(Color.black, colors[1]);
    try std.testing.expectEqual(Color.white, colors[2]);
}

test "3D point lights shade vertices from light position" {
    var scene = Scene3D.init(std.testing.allocator);
    defer scene.deinit();
    scene.setLight(Light.point(.{ .x = 1 }, 0.0, 1.0));

    const tri = Triangle3D{
        .positions = .{ .{}, .{ .x = 2 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } },
    };
    const colors = shadeTriangleColors(tri, &scene);
    try std.testing.expectEqual(Color.white, colors[0]);
    try std.testing.expectEqual(Color.black, colors[1]);
    try std.testing.expect(colors[2].r > 175 and colors[2].r < 185);
}

test "3D ranged point lights attenuate with distance" {
    var scene = Scene3D.init(std.testing.allocator);
    defer scene.deinit();
    scene.setLight(Light.pointRanged(.{ .x = 1 }, 0.0, 1.0, 4.0));

    const tri = Triangle3D{
        .positions = .{ .{}, .{ .x = -2 }, .{ .x = -5 } },
        .color = .white,
        .normals = .{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } },
    };
    const colors = shadeTriangleColors(tri, &scene);
    try std.testing.expect(colors[0].r > colors[1].r);
    try std.testing.expectEqual(@as(u8, 0), colors[2].r);
}

test "3D spot lights shade only inside the cone" {
    var scene = Scene3D.init(std.testing.allocator);
    defer scene.deinit();
    scene.setLight(Light.spot(
        .{},
        .{ .x = 1 },
        0.0,
        1.0,
        std.math.pi / 12.0,
        std.math.pi / 4.0,
        8.0,
    ));

    const tri = Triangle3D{
        .positions = .{ .{ .x = 1 }, .{ .x = 1, .y = 2 }, .{ .x = -1 } },
        .color = .white,
        .normals = .{ .{ .x = -1 }, .{ .x = -1 }, .{ .x = -1 } },
    };
    const colors = shadeTriangleColors(tri, &scene);
    try std.testing.expect(colors[0].r > 40);
    try std.testing.expectEqual(@as(u8, 0), colors[1].r);
    try std.testing.expectEqual(@as(u8, 0), colors[2].r);
}

test "3D scenes accumulate multiple lights" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 0.25 });
    try scene.addLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 0.25 });

    const tri = Triangle3D{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
    };
    const colors = shadeTriangleColors(tri, &scene);
    try std.testing.expectEqual(@as(usize, 1), scene.lights.items.len);
    try std.testing.expectEqual(@as(u8, 128), colors[0].r);
}

test "3D material scales ambient and diffuse lighting" {
    var scene = Scene3D.init(std.testing.allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.25, .diffuse = 0.75 });

    const tri = Triangle3D{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
        .material = .{ .ambient = 0.5, .diffuse = 0.5 },
    };
    const colors = shadeTriangleColors(tri, &scene);
    try std.testing.expectEqual(@as(u8, 128), colors[0].r);
}

test "3D material emits color without lighting" {
    var scene = Scene3D.init(std.testing.allocator);
    defer scene.deinit();

    const tri = Triangle3D{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .black,
        .material = .{ .emissive = .blue, .emissive_strength = 0.5 },
    };
    const colors = shadeTriangleColors(tri, &scene);
    try std.testing.expectEqual(Color.rgba(0, 0, 128, 255), colors[0]);
}

test "3D metallic roughness adds specular response" {
    var scene = Scene3D.init(std.testing.allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 }, .ambient = 0.0, .diffuse = 0.5 });

    const matte = Triangle3D{
        .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } },
        .color = .white,
        .normals = .{ .{ .z = 1 }, .{ .z = 1 }, .{ .z = 1 } },
        .material = .{ .roughness = 1.0, .metallic = 0.0 },
    };
    const metal = Triangle3D{
        .positions = matte.positions,
        .color = .white,
        .normals = matte.normals,
        .material = .{ .roughness = 0.0, .metallic = 1.0 },
    };
    const matte_colors = shadeTriangleColors(matte, &scene);
    const metal_colors = shadeTriangleColors(metal, &scene);
    try std.testing.expect(metal_colors[0].r > matte_colors[0].r);
    try std.testing.expectEqual(@as(u8, 255), metal_colors[0].r);
}

test "3D setLight replaces additional lights" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setLight(.{ .direction = .{ .z = 1 } });
    try scene.addLight(Light.point(.{ .x = 1 }, 0.0, 1.0));
    scene.setLight(.{ .direction = .{ .z = -1 }, .ambient = 0.0, .diffuse = 1.0 });

    try std.testing.expectEqual(@as(usize, 0), scene.lights.items.len);
    try std.testing.expectEqual(LightKind.directional, scene.light.kind);
    try std.testing.expect(@abs(scene.light.direction.z + 1.0) < 0.0001);
}

test "3D scene transforms indexed meshes" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 } };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMeshTransformed(
        .{ .positions = &positions, .indices = &indices, .color = .white },
        math.Mat4.translation(.{ .x = 2 }),
    );

    try std.testing.expectEqual(@as(f32, 2), scene.triangles.items[0].positions[0].x);
    try std.testing.expectEqual(@as(f32, 3), scene.triangles.items[0].positions[1].x);
}

test "3D scene transforms indexed mesh normals" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 } };
    const normals = [_]math.Vec3{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMeshTransformed(
        .{ .positions = &positions, .indices = &indices, .color = .white, .normals = &normals },
        math.Mat4.rotationZ(std.math.pi / 2.0),
    );

    const transformed = scene.triangles.items[0].normals.?;
    try std.testing.expect(@abs(transformed[1].x) < 0.0001);
    try std.testing.expect(@abs(transformed[1].y - 1.0) < 0.0001);
    try std.testing.expect(@abs(transformed[1].length() - 1.0) < 0.0001);
}

test "3D scene propagates indexed mesh material" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 } };
    const indices = [_]u32{ 0, 1, 2 };
    try scene.addIndexedMesh(.{
        .positions = &positions,
        .indices = &indices,
        .color = .white,
        .material = .{ .ambient = 0.25, .diffuse = 0.5 },
    });

    try std.testing.expectEqual(@as(f32, 0.25), scene.triangles.items[0].material.ambient);
    try std.testing.expectEqual(@as(f32, 0.5), scene.triangles.items[0].material.diffuse);
}

test "3D scene replaces indexed mesh handle storage" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 }, .{ .x = 1, .y = 1 } };
    const original_indices = [_]u32{ 0, 1, 2 };
    const handle = try scene.addIndexedMeshHandle(.{
        .positions = &positions,
        .indices = &original_indices,
        .color = .red,
    });
    const replacement_indices = [_]u32{ 1, 3, 2 };
    const colors = [_]Color{ .white, .blue, .green, .red };

    try scene.replaceIndexedMesh(handle, .{
        .positions = &positions,
        .indices = &replacement_indices,
        .color = .white,
        .colors = &colors,
    });

    const view = scene.meshView(handle).?;
    try std.testing.expectEqual(@as(usize, 1), view.len);
    try std.testing.expectEqual(@as(f32, 1), view[0].positions[0].x);
    const vertex_colors = view[0].vertexColors();
    try std.testing.expectEqual(Color.blue, vertex_colors[0]);
    try std.testing.expectEqual(Color.red, vertex_colors[1]);
    try std.testing.expectEqual(Color.green, vertex_colors[2]);
    try std.testing.expectError(error.InvalidMeshHandle, scene.replaceIndexedMesh(.{ .start = 99, .count = 1 }, .{
        .positions = &positions,
        .indices = &replacement_indices,
        .color = .white,
    }));
}

test "3D scene replaces transformed indexed mesh handle storage" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 } };
    const normals = [_]math.Vec3{ .{ .x = 1 }, .{ .x = 1 }, .{ .x = 1 } };
    const indices = [_]u32{ 0, 1, 2 };
    const handle = try scene.addIndexedMeshHandle(.{
        .positions = &positions,
        .indices = &indices,
        .color = .white,
        .normals = &normals,
    });

    try scene.replaceIndexedMeshTransformed(handle, .{
        .positions = &positions,
        .indices = &indices,
        .color = .blue,
        .normals = &normals,
    }, math.Mat4.translation(.{ .x = 2, .y = 3, .z = 4 }).mul(math.Mat4.rotationZ(std.math.pi / 2.0)));

    const triangle = scene.meshView(handle).?[0];
    try std.testing.expectEqual(Color.blue, triangle.color);
    try std.testing.expectEqual(@as(f32, 2), triangle.positions[0].x);
    try std.testing.expectEqual(@as(f32, 3), triangle.positions[0].y);
    try std.testing.expectEqual(@as(f32, 4), triangle.positions[0].z);
    try std.testing.expect(@abs(triangle.normals.?[0].x) < 0.0001);
    try std.testing.expect(@abs(triangle.normals.?[0].y - 1.0) < 0.0001);
}

test "3D indexed mesh handle replacement validates input" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{ .{}, .{ .x = 1 }, .{ .y = 1 }, .{ .x = 1, .y = 1 } };
    const indices = [_]u32{ 0, 1, 2 };
    const handle = try scene.addIndexedMeshHandle(.{ .positions = &positions, .indices = &indices, .color = .white });

    const invalid_count = [_]u32{ 0, 1 };
    try std.testing.expectError(error.InvalidIndexCount, scene.replaceIndexedMesh(handle, .{
        .positions = &positions,
        .indices = &invalid_count,
        .color = .white,
    }));

    const two_triangles = [_]u32{ 0, 1, 2, 1, 3, 2 };
    try std.testing.expectError(error.InvalidMeshTriangleCount, scene.replaceIndexedMesh(handle, .{
        .positions = &positions,
        .indices = &two_triangles,
        .color = .white,
    }));

    const out_of_bounds = [_]u32{ 0, 1, 9 };
    try std.testing.expectError(error.IndexOutOfBounds, scene.replaceIndexedMesh(handle, .{
        .positions = &positions,
        .indices = &out_of_bounds,
        .color = .white,
    }));
}

test "3D indexed meshes validate index input" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    const positions = [_]math.Vec3{.{}};
    const bad_count = [_]u32{ 0, 0 };
    try std.testing.expectError(error.InvalidIndexCount, scene.addIndexedMesh(.{
        .positions = &positions,
        .indices = &bad_count,
        .color = .white,
    }));

    const bad_index = [_]u32{ 0, 1, 0 };
    try std.testing.expectError(error.IndexOutOfBounds, scene.addIndexedMesh(.{
        .positions = &positions,
        .indices = &bad_index,
        .color = .white,
    }));

    const indices = [_]u32{ 0, 0, 0 };
    const bad_colors = [_]Color{ .red, .green };
    try std.testing.expectError(error.InvalidColorCount, scene.addIndexedMesh(.{
        .positions = &positions,
        .indices = &indices,
        .color = .white,
        .colors = &bad_colors,
    }));

    const bad_normals = [_]math.Vec3{ .{}, .{} };
    try std.testing.expectError(error.InvalidNormalCount, scene.addIndexedMesh(.{
        .positions = &positions,
        .indices = &indices,
        .color = .white,
        .normals = &bad_normals,
    }));
}

test "3D scene normalizes configured light direction" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();

    scene.setLight(.{ .direction = .{ .z = 5 }, .ambient = 0.2, .diffuse = 0.8 });
    try std.testing.expect(scene.lighting_enabled);
    try std.testing.expect(@abs(scene.light.direction.length() - 1.0) < 0.0001);
}

test "3D camera builds perspective look-at transform" {
    const camera = Camera.perspectiveLookAt(.{ .z = 3 }, .{}, .{ .y = 1 }, std.math.pi / 2.0, 1.0, 0.1, 100.0);
    const out = camera.transform.transformPoint(.{});
    try std.testing.expect(@abs(out.x) < 0.0001);
    try std.testing.expect(@abs(out.y) < 0.0001);
}

test "3D camera builds orthographic look-at transform" {
    const camera = Camera.orthographicLookAt(.{ .z = 3 }, .{}, .{ .y = 1 }, 4.0, 4.0, 0.1, 100.0);
    const center = camera.transform.transformPoint(.{});
    const right = camera.transform.transformPoint(.{ .x = 2 });
    try std.testing.expect(@abs(center.x) < 0.0001);
    try std.testing.expect(@abs(center.y) < 0.0001);
    try std.testing.expect(center.z > 0.0 and center.z < 1.0);
    try std.testing.expect(@abs(right.x - 1.0) < 0.0001);
}

test "3D scene stores cull mode" {
    const allocator = std.testing.allocator;
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    scene.setCullMode(.back);
    try std.testing.expectEqual(CullMode.back, scene.cull_mode);
}

test "3D projected culling classifies triangle winding" {
    const tri = Triangle3D{
        .positions = .{
            .{ .x = -0.5, .y = -0.5, .z = 0 },
            .{ .x = 0.5, .y = -0.5, .z = 0 },
            .{ .x = 0.0, .y = 0.5, .z = 0 },
        },
        .color = .white,
    };
    try std.testing.expect(!projectedTriangleVisible(tri, .{}, .back));
    try std.testing.expect(projectedTriangleVisible(tri, .{}, .front));
}

test "3D projected visibility rejects triangles outside clip volume" {
    const tri = Triangle3D{
        .positions = .{
            .{ .x = 2.0, .y = 0.0, .z = 0.5 },
            .{ .x = 3.0, .y = 0.0, .z = 0.5 },
            .{ .x = 2.5, .y = 1.0, .z = 0.5 },
        },
        .color = .white,
    };
    try std.testing.expect(!projectedTriangleVisible(tri, .{}, .none));
}
