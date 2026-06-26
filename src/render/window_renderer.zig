const std = @import("std");
const native_window = @import("native_window.zig");
const window_gpu = @import("window_gpu.zig");
const window = @import("window_types.zig");
const backend = @import("webgpu_backend.zig").WebGpuBackend;

pub const NativeHandle = native_window.NativeHandle;
pub const ProviderCallbacks = native_window.ProviderCallbacks;
pub const RenderContext = backend.RenderContext;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    backend: window.Backend,
    context: native_window.WindowRenderContext,
    renderer: window_gpu.WindowRenderer,

    pub fn init(
        allocator: std.mem.Allocator,
        callbacks: ProviderCallbacks,
        requested_backend: window.Backend,
        logical_size: [2]u32,
        framebuffer_size: [2]u32,
    ) !Renderer {
        const resolved_backend = resolveBackend(requested_backend);
        var context = try native_window.WindowRenderContext.init(
            allocator,
            callbacks,
            resolved_backend,
            logical_size[0],
            logical_size[1],
        );
        errdefer context.deinit();
        const active_backend: window.Backend = if (resolved_backend == .auto)
            if (context.webgpuContext() != null) .gpu else .cpu
        else
            resolved_backend;
        const renderer = try window_gpu.WindowRenderer.init(
            allocator,
            active_backend,
            context.webgpuContext(),
            framebuffer_size,
        );
        return .{
            .allocator = allocator,
            .backend = active_backend,
            .context = context,
            .renderer = renderer,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.renderer.deinit(self.context.webgpuContext());
        self.context.deinit();
        self.* = undefined;
    }

    pub fn compiledWithGpu() bool {
        return backend.compiled_with_zgpu;
    }

    pub fn beginFrame(self: *Renderer, logical_size: [2]u32, framebuffer_size: [2]u32, scale_factor: f32) !void {
        if (self.backend == .cpu) {
            self.renderer.beginCpuFrame();
            if (self.context.cpuWindowRenderer()) |cpu_renderer| {
                cpu_renderer.setTextAtlasProvider(self.renderer.cpuTextProvider());
                cpu_renderer.setImageProvider(self.renderer.cpuImageProvider());
                cpu_renderer.setScaleFactor(scale_factor);
                try cpu_renderer.beginFrame(framebuffer_size[0], framebuffer_size[1]);
            }
            return;
        }
        if (!backend.compiled_with_zgpu) return error.BackendUnavailable;
        const gctx = self.context.webgpuContext().?;
        try self.renderer.beginGpuFrame(gctx, logical_size, framebuffer_size);
    }

    pub fn endFrame(self: *Renderer, scale_factor: f32) void {
        if (self.backend == .cpu) {
            self.endCpuFrame() catch {};
            self.renderer.endCpuFrame();
            return;
        }
        if (!backend.compiled_with_zgpu) return;
        const gctx = self.context.webgpuContext().?;
        self.renderer.endGpuFrame(gctx, scale_factor);
    }

    fn endCpuFrame(self: *Renderer) !void {
        var cpu_renderer = self.context.cpuWindowRenderer() orelse return;
        try cpu_renderer.endFrame();
    }

    pub fn pushDrawList(self: *Renderer, cmds: []const window.DrawCmd) !void {
        if (self.backend == .cpu) {
            if (self.context.cpuWindowRenderer()) |renderer| try renderer.pushDrawList(cmds);
            return;
        }
        try self.renderer.pushDrawList(cmds);
    }

    pub fn createImage(self: *Renderer, width: u32, height: u32, rgba_pixels: []const u8) !window.ImageId {
        return try self.renderer.createImage(width, height, rgba_pixels);
    }

    pub fn updateImage(self: *Renderer, image_id: window.ImageId, width: u32, height: u32, rgba_pixels: []const u8) !void {
        try self.renderer.updateImage(image_id, width, height, rgba_pixels);
    }

    pub fn setDefaultTextFontFromFile(self: *Renderer, io: std.Io, path: []const u8, size_px: f32, raster_scale: f32) !window.TextFontId {
        return try self.renderer.setDefaultTextFontFromFile(io, path, size_px, raster_scale);
    }

    pub fn addTextFontFromFile(self: *Renderer, io: std.Io, path: []const u8, size_px: f32, fallback: ?window.TextFontId, raster_scale: f32) !window.TextFontId {
        return try self.renderer.addTextFontFromFile(io, path, size_px, fallback, raster_scale);
    }

    pub fn setDefaultTextFont(self: *Renderer, font_id: window.TextFontId) void {
        self.renderer.setDefaultTextFont(font_id);
    }

    pub fn acquireBitmapFont(self: *Renderer, size_px: f32, fallback: ?window.TextFontId) !window.TextFontId {
        return try self.renderer.acquireBitmapFont(size_px, fallback);
    }

    pub fn releaseTextFont(self: *Renderer, font_id: window.TextFontId) void {
        self.renderer.releaseTextFont(font_id);
    }

    pub fn createBitmapFont(self: *Renderer, size_px: f32, fallback: ?window.TextFontId) !window.TextFontId {
        return try self.renderer.createBitmapFont(size_px, fallback);
    }

    pub fn measureText(self: *Renderer, text: []const u8, font_size: f32, font_id: ?window.TextFontId) window.Size {
        return self.renderer.measureText(text, font_size, font_id);
    }

    pub fn createNode(self: *Renderer) !window.NodeId {
        return try self.renderer.createNode();
    }

    pub fn setNodeLayer(self: *Renderer, id: window.NodeId, layer: i32) !void {
        try self.renderer.setNodeLayer(id, layer);
    }

    pub fn updateNode(self: *Renderer, id: window.NodeId, verts: []const window.Vertex) !void {
        try self.renderer.updateNode(id, verts);
    }

    pub fn removeNode(self: *Renderer, id: window.NodeId) !void {
        try self.renderer.removeNode(id);
    }
};

pub fn resolveBackend(backend_value: window.Backend) window.Backend {
    if (backend_value != .auto) return backend_value;
    return if (backend.compiled_with_zgpu) .auto else .cpu;
}
