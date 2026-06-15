const std = @import("std");
const iris = @import("iris");

pub const window_integration_note =
    \\For a real window app, follow the Zion-style boundary: create or receive a
    \\platform window, expose its NativeHandle and framebuffer size through a
    \\zgpu.WindowProvider, create zgpu.GraphicsContext, then call
    \\runWithContext(allocator, gctx).
;

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    if (!iris.WebGpuBackend.compiled_with_zgpu) {
        try out.interface.writeAll("webgpu-window-skeleton requires -Denable-zgpu-backend=true\n");
        try out.interface.flush();
        return;
    }

    try out.interface.writeAll(
        \\webgpu-window-skeleton:
        \\  create a native window using a Zion-style NativeHandle boundary,
        \\  expose its framebuffer size and platform handle to zgpu.WindowProvider,
        \\  then pass it to runWithContext(allocator, &graphics_context).
        \\
    );
    try out.interface.flush();
}

pub fn runWithContext(allocator: std.mem.Allocator, graphics_context: *iris.WebGpuBackend.GraphicsContext) !void {
    var backend = iris.WebGpuBackend.init(graphics_context);
    defer backend.deinit();

    backend.setTargetOptions(.{ .color_format = .bgra8_unorm });
    try backend.initTrianglesPipelineFromSourceAndFormat(triangle_shader_source, .bgra8_unorm);

    var scene = iris.Scene3D.init(allocator);
    defer scene.deinit();
    try buildScene(&scene);

    _ = try backend.renderScene3DToCurrentSwapchain(allocator, &scene);
}

fn buildScene(scene: *iris.Scene3D) !void {
    scene.setCamera(iris.scene3d.Camera.perspectiveLookAt(
        .{ .x = 0.0, .y = 0.7, .z = 2.4 },
        .{},
        .{ .y = 1.0 },
        std.math.pi / 4.5,
        16.0 / 9.0,
        0.1,
        16.0,
    ));
    scene.setLight(.{ .direction = .{ .x = -0.25, .y = 0.55, .z = 1.0 }, .ambient = 0.2, .diffuse = 0.8 });
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

const triangle_shader_source =
    \\struct Vertex3D {
    \\    x: f32,
    \\    y: f32,
    \\    z: f32,
    \\    world_x: f32,
    \\    world_y: f32,
    \\    world_z: f32,
    \\    u: f32,
    \\    v: f32,
    \\    nx: f32,
    \\    ny: f32,
    \\    nz: f32,
    \\    base_rgba: u32,
    \\    rgba: u32,
    \\};
    \\
    \\struct Triangle {
    \\    a: Vertex3D,
    \\    b: Vertex3D,
    \\    c: Vertex3D,
    \\    texture_index: u32,
    \\    normal_texture_index: u32,
    \\    material_ambient: f32,
    \\    material_diffuse: f32,
    \\    material_roughness: f32,
    \\    material_metallic: f32,
    \\    material_emissive: u32,
    \\    material_emissive_strength: f32,
    \\};
    \\
    \\struct TextureInfo {
    \\    width: u32,
    \\    height: u32,
    \\    pixel_start: u32,
    \\    pixel_count: u32,
    \\};
    \\
    \\struct Light {
    \\    kind: u32,
    \\    direction_x: f32,
    \\    direction_y: f32,
    \\    direction_z: f32,
    \\    position_x: f32,
    \\    position_y: f32,
    \\    position_z: f32,
    \\    ambient: f32,
    \\    diffuse: f32,
    \\    range: f32,
    \\    attenuation: f32,
    \\    inner_angle: f32,
    \\    outer_angle: f32,
    \\};
    \\
    \\@group(0) @binding(0) var<storage, read> triangles: array<Triangle>;
    \\@group(0) @binding(1) var<storage, read> textures: array<TextureInfo>;
    \\@group(0) @binding(2) var<storage, read> texture_pixels: array<u32>;
    \\@group(0) @binding(3) var<storage, read> lights: array<Light>;
    \\@group(0) @binding(4) var<uniform> lighting_enabled: u32;
    \\
    \\fn unpack_color(rgba: u32) -> vec4<f32> {
    \\    return vec4<f32>(
    \\        f32(rgba & 0xffu) / 255.0,
    \\        f32((rgba >> 8u) & 0xffu) / 255.0,
    \\        f32((rgba >> 16u) & 0xffu) / 255.0,
    \\        f32((rgba >> 24u) & 0xffu) / 255.0,
    \\    );
    \\}
    \\
    \\struct VertexOut {
    \\    @builtin(position) clip_position: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn vertex_main(@builtin(vertex_index) vertex_index: u32) -> VertexOut {
    \\    let triangle = triangles[vertex_index / 3u];
    \\    let local = vertex_index % 3u;
    \\    var vertex = triangle.a;
    \\    if (local == 1u) {
    \\        vertex = triangle.b;
    \\    }
    \\    if (local == 2u) {
    \\        vertex = triangle.c;
    \\    }
    \\    var out: VertexOut;
    \\    out.clip_position = vec4<f32>(vertex.x, vertex.y, vertex.z, 1.0);
    \\    out.color = unpack_color(vertex.rgba);
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fragment_main(in: VertexOut) -> @location(0) vec4<f32> {
    \\    return in.color;
    \\}
;
