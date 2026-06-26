const std = @import("std");
const backend = @import("webgpu_backend.zig").WebGpuBackend;
const window = @import("window_types.zig");
const window_draw = @import("window_draw.zig");
const window_lower = @import("window_lower.zig");
const cangjie = @import("cangjie");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const cpu = @import("cpu.zig");
const scene2d = @import("scene2d.zig");

const wgpu = backend.wgpu;

pub const BatchKind = enum {
    shape,
    paint_quad,
    text,
    line_aa,
    image,
};

pub const Batch = struct {
    kind: BatchKind,
    first: u32,
    count: u32,
    clip: ?window.Rect,
    font_id: ?window.TextFontId,
    image_id: ?window.ImageId,
};

pub const TextureKind = enum {
    rgba,
    alpha,
};

pub const TextureResource = struct {
    width: u32,
    height: u32,
    texture: backend.TextureHandle,
    view: backend.TextureViewHandle,
    sampler: backend.SamplerHandle,
    bind_group: backend.BindGroupHandle,
};

pub const ResolveBatchTextureFn = *const fn (context: *anyopaque, batch: Batch) ?TextureResource;

const ImageResource = struct {
    id: window.ImageId,
    width: u32,
    height: u32,
    pixels: []Color,
    gpu_texture: ?TextureResource,
};

pub const ImageStore = struct {
    allocator: std.mem.Allocator,
    images: std.ArrayList(ImageResource),
    gpu_context: ?*backend.RenderContext = null,
    texture_bind_group_layout: ?backend.BindGroupLayoutHandle = null,

    pub fn init(allocator: std.mem.Allocator) !ImageStore {
        return .{ .allocator = allocator, .images = try std.ArrayList(ImageResource).initCapacity(allocator, 4) };
    }

    pub fn deinit(self: *ImageStore) void {
        if (backend.compiled_with_zgpu) {
            if (self.gpu_context) |ctx| {
                for (self.images.items) |*image| {
                    if (image.gpu_texture) |*texture| destroyTextureResource(ctx, texture);
                }
            }
        }
        for (self.images.items) |*image| {
            self.allocator.free(image.pixels);
        }
        self.images.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setGpuContext(self: *ImageStore, gctx: ?*backend.RenderContext, texture_bind_group_layout: ?backend.BindGroupLayoutHandle) void {
        self.gpu_context = gctx;
        self.texture_bind_group_layout = texture_bind_group_layout;
    }

    pub fn createImage(self: *ImageStore, width: u32, height: u32, rgba_pixels: []const u8) !window.ImageId {
        if (width == 0 or height == 0) return error.InvalidImageSize;
        const required = @as(usize, width) * @as(usize, height) * 4;
        if (rgba_pixels.len != required) return error.InvalidImagePixels;
        const id: window.ImageId = @intCast(self.images.items.len);
        const pixels = try self.allocator.alloc(Color, @as(usize, width) * @as(usize, height));
        errdefer self.allocator.free(pixels);
        copyRgba8ToColors(pixels, rgba_pixels);
        var image = ImageResource{
            .id = id,
            .width = width,
            .height = height,
            .pixels = pixels,
            .gpu_texture = if (backend.compiled_with_zgpu)
                if (self.gpu_context) |ctx| blk: {
                    const layout = self.texture_bind_group_layout orelse return error.InvalidRendererState;
                    break :blk createTextureResource(ctx, layout, width, height, .rgba);
                } else null
            else
                null,
        };
        errdefer if (backend.compiled_with_zgpu) {
            if (self.gpu_context) |ctx| {
                if (image.gpu_texture) |*texture| destroyTextureResource(ctx, texture);
            }
        };
        try self.uploadImagePixels(&image, rgba_pixels);
        try self.images.append(self.allocator, image);
        return id;
    }

    pub fn updateImage(self: *ImageStore, image_id: window.ImageId, width: u32, height: u32, rgba_pixels: []const u8) !void {
        const image = self.imageById(image_id) orelse return error.InvalidImageId;
        try validateImageUpdate(image.width, image.height, width, height, rgba_pixels.len);
        copyRgba8ToColors(image.pixels, rgba_pixels);
        try self.uploadImagePixels(image, rgba_pixels);
    }

    pub fn pushImage(self: *ImageStore, scene: *ImmediateScene, image_id: window.ImageId, rect: window.Rect, tint: [4]f32) !void {
        if (self.imageById(image_id) == null) return error.InvalidImageId;
        const start = scene.text_vertices.items.len;
        try scene.pushImage(image_id, rect, tint);
        try scene.recordBatch(start, null, .image, null, image_id);
    }

    pub fn textureForBatch(self: *ImageStore, batch: Batch) ?TextureResource {
        if (batch.kind != .image) return null;
        const image_id = batch.image_id orelse return null;
        const image = self.imageById(image_id) orelse return null;
        return image.gpu_texture;
    }

    pub fn cpuProvider(self: *ImageStore) window_draw.ImageProvider {
        return .{
            .context = self,
            .imageFn = cpuImageForProvider,
        };
    }

    pub fn cpuImageForId(self: *ImageStore, image_id: window.ImageId) ?Image {
        const image = self.imageById(image_id) orelse return null;
        return Image{
            .allocator = self.allocator,
            .width = image.width,
            .height = image.height,
            .pixels = image.pixels,
        };
    }

    fn imageById(self: *ImageStore, image_id: window.ImageId) ?*ImageResource {
        const idx: usize = @intCast(image_id);
        if (idx >= self.images.items.len) return null;
        return &self.images.items[idx];
    }

    fn uploadImagePixels(self: *ImageStore, image: *ImageResource, rgba_pixels: []const u8) !void {
        if (!backend.compiled_with_zgpu) return;
        const gctx = self.gpu_context orelse return;
        const texture = image.gpu_texture orelse return error.InvalidImageId;
        try uploadRgbaPixels(self.allocator, gctx, texture, rgba_pixels);
    }

    fn copyRgba8ToColors(out: []Color, rgba_pixels: []const u8) void {
        for (out, 0..) |*pixel, i| {
            const base = i * 4;
            pixel.* = Color.rgba(rgba_pixels[base + 0], rgba_pixels[base + 1], rgba_pixels[base + 2], rgba_pixels[base + 3]);
        }
    }

    fn cpuImageForProvider(context: *anyopaque, image_id: window.ImageId) ?Image {
        const store: *ImageStore = @ptrCast(@alignCast(context));
        return store.cpuImageForId(image_id);
    }
};

const RetainedNode = struct {
    id: window.NodeId,
    layer: i32,
    vertices: std.ArrayList(window.Vertex),
};

pub const RetainedStore = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(RetainedNode),
    next_node_id: window.NodeId = 1,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) !RetainedStore {
        return .{ .allocator = allocator, .nodes = try std.ArrayList(RetainedNode).initCapacity(allocator, 32) };
    }

    pub fn deinit(self: *RetainedStore) void {
        for (self.nodes.items) |*node| node.vertices.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendToScene(self: *RetainedStore, scene: *ImmediateScene) !void {
        if (self.dirty) {
            std.sort.insertion(RetainedNode, self.nodes.items, {}, retainedLessThan);
            self.dirty = false;
        }
        for (self.nodes.items) |*node| try scene.appendRetainedVertices(node.vertices.items);
    }

    pub fn createNode(self: *RetainedStore) !window.NodeId {
        const id = self.next_node_id;
        self.next_node_id += 1;
        const verts = try std.ArrayList(window.Vertex).initCapacity(self.allocator, 16);
        try self.nodes.append(self.allocator, .{ .id = id, .layer = 0, .vertices = verts });
        self.dirty = true;
        return id;
    }

    pub fn setNodeLayer(self: *RetainedStore, id: window.NodeId, layer: i32) !void {
        for (self.nodes.items) |*node| {
            if (node.id == id) {
                node.layer = layer;
                self.dirty = true;
                return;
            }
        }
        return error.NodeNotFound;
    }

    pub fn updateNode(self: *RetainedStore, id: window.NodeId, verts: []const window.Vertex) !void {
        for (self.nodes.items) |*node| {
            if (node.id == id) {
                node.vertices.clearRetainingCapacity();
                try node.vertices.appendSlice(self.allocator, verts);
                self.dirty = true;
                return;
            }
        }
        return error.NodeNotFound;
    }

    pub fn removeNode(self: *RetainedStore, id: window.NodeId) !void {
        var index: ?usize = null;
        for (self.nodes.items, 0..) |*node, i| {
            if (node.id == id) {
                index = i;
                node.vertices.deinit(self.allocator);
                break;
            }
        }
        if (index) |i| {
            _ = self.nodes.swapRemove(i);
            self.dirty = true;
            return;
        }
        return error.NodeNotFound;
    }
};

pub const WindowRenderer = struct {
    allocator: std.mem.Allocator,
    backend_kind: window.Backend,
    frame_index: u64 = 0,
    retire_latency: u32 = 3,
    frame_active: bool = false,
    gpu_renderer: ?GpuImmediateRenderer = null,
    scene: ImmediateScene,
    retained_store: RetainedStore,
    text_store: TextAtlasStore,
    image_store: ImageStore,
    last_fb_size: [2]u32,

    pub fn init(
        allocator: std.mem.Allocator,
        backend_kind: window.Backend,
        gctx: ?*backend.RenderContext,
        framebuffer_size: [2]u32,
    ) !WindowRenderer {
        const max_vertices: u32 = 262144;
        const max_paint_quad_vertices: u32 = 262144;
        const max_text_vertices: u32 = 262144;
        const max_line_vertices: u32 = 262144;
        const scene = try ImmediateScene.init(allocator, max_vertices, max_paint_quad_vertices, max_text_vertices, max_line_vertices);
        const retained_store = try RetainedStore.init(allocator);
        const gpu_renderer = if (backend.compiled_with_zgpu)
            if (gctx) |ctx| try GpuImmediateRenderer.init(ctx, max_vertices, max_paint_quad_vertices, max_text_vertices, max_line_vertices) else null
        else
            null;
        var text_store = try TextAtlasStore.init(allocator);
        var image_store = try ImageStore.init(allocator);
        if (backend.compiled_with_zgpu) {
            if (gctx) |ctx| {
                if (gpu_renderer) |gpu| {
                    text_store.setGpuContext(ctx, gpu.texture_bind_group_layout);
                    image_store.setGpuContext(ctx, gpu.texture_bind_group_layout);
                }
            }
        }
        var renderer = WindowRenderer{
            .allocator = allocator,
            .backend_kind = backend_kind,
            .gpu_renderer = gpu_renderer,
            .scene = scene,
            .retained_store = retained_store,
            .text_store = text_store,
            .image_store = image_store,
            .last_fb_size = framebuffer_size,
        };
        try renderer.text_store.initDefaultTextFont();
        return renderer;
    }

    pub fn deinit(self: *WindowRenderer, gctx: ?*backend.RenderContext) void {
        self.text_store.processRetiredFonts(self.frame_index, true);
        self.text_store.deinit();
        self.image_store.deinit();
        if (backend.compiled_with_zgpu) {
            if (gctx) |ctx| {
                if (self.gpu_renderer) |*gpu_renderer| gpu_renderer.deinit(ctx);
            }
        }
        self.retained_store.deinit();
        self.scene.deinit();
        self.* = undefined;
    }

    pub fn beginCpuFrame(self: *WindowRenderer) void {
        self.frame_active = true;
    }

    pub fn cpuTextProvider(self: *WindowRenderer) window_draw.TextAtlasProvider {
        return self.text_store.cpuProvider();
    }

    pub fn cpuImageProvider(self: *WindowRenderer) window_draw.ImageProvider {
        return self.image_store.cpuProvider();
    }

    pub fn endCpuFrame(self: *WindowRenderer) void {
        if (!self.frame_active) return;
        self.frame_index += 1;
    }

    pub fn beginGpuFrame(self: *WindowRenderer, gctx: *backend.RenderContext, logical_size: [2]u32, framebuffer_size: [2]u32) !void {
        self.text_store.processRetiredFonts(self.frame_index, false);
        self.frame_active = false;
        if (backend.compiled_with_zgpu) {
            if (self.gpu_renderer) |*gpu_renderer| {
                self.frame_active = gpu_renderer.beginFrame(gctx, logical_size);
            } else {
                return;
            }
        }
        if (!self.frame_active) return;
        try self.scene.beginFrame(&.{});
        self.last_fb_size = framebuffer_size;
        try self.retained_store.appendToScene(&self.scene);
    }

    pub fn endGpuFrame(self: *WindowRenderer, gctx: *backend.RenderContext, scale_factor: f32) void {
        if (!self.frame_active) return;
        if (backend.compiled_with_zgpu) {
            if (self.gpu_renderer) |*gpu_renderer| {
                gpu_renderer.endFrame(
                    gctx,
                    self.scene.vertices.items,
                    self.scene.paint_quad_vertices.items,
                    self.scene.text_vertices.items,
                    self.scene.line_vertices.items,
                    self.scene.batches.items,
                    self.last_fb_size,
                    scale_factor,
                    self,
                    resolveWindowBatchTexture,
                );
            }
        }
        self.frame_index += 1;
    }

    pub fn pushTriangle(self: *WindowRenderer, a: window.Vertex, b: window.Vertex, c: window.Vertex) !void {
        try self.scene.pushTriangle(a, b, c);
    }

    pub fn pushRect(self: *WindowRenderer, rect: window.Rect, color: [4]f32) !void {
        try self.scene.pushRect(rect, color);
    }

    pub fn pushRoundedRect(self: *WindowRenderer, rect: window.Rect, radius: f32, color: [4]f32) !void {
        try self.scene.pushRoundedRect(rect, radius, color);
    }

    pub fn pushStrokeRoundedRect(self: *WindowRenderer, rect: window.Rect, radius: f32, thickness: f32, color: [4]f32) !void {
        try self.scene.pushStrokeRoundedRect(rect, radius, thickness, color);
    }

    pub fn pushLinearGradientRect(self: *WindowRenderer, gradient: window.LinearGradientRect) !void {
        try self.scene.pushLinearGradientRect(gradient);
    }

    pub fn pushRadialGradientRect(self: *WindowRenderer, gradient: window.RadialGradientRect) !void {
        try self.scene.pushRadialGradientRect(gradient);
    }

    pub fn pushSweepGradientRect(self: *WindowRenderer, gradient: window.SweepGradientRect) !void {
        try self.scene.pushSweepGradientRect(gradient);
    }

    pub fn pushEllipse(self: *WindowRenderer, center: [2]f32, radius: [2]f32, color: [4]f32) !void {
        try self.scene.pushEllipse(center, radius, color);
    }

    pub fn pushCircle(self: *WindowRenderer, center: [2]f32, radius: f32, color: [4]f32) !void {
        try self.scene.pushCircle(center, radius, color);
    }

    pub fn pushStrokeEllipse(self: *WindowRenderer, center: [2]f32, radius: [2]f32, thickness: f32, color: [4]f32) !void {
        try self.scene.pushStrokeEllipse(center, radius, thickness, color);
    }

    pub fn pushFillPath(self: *WindowRenderer, commands: []const window.PathCommand, color: [4]f32) !void {
        try self.scene.pushFillPath(commands, color);
    }

    pub fn pushStrokePath(self: *WindowRenderer, commands: []const window.PathCommand, style: window.StrokeStyle, color: [4]f32) !void {
        try self.scene.pushStrokePath(commands, style, color);
    }

    pub fn pushPoint(self: *WindowRenderer, pos: [2]f32, size: f32, color: [4]f32) !void {
        try self.scene.pushPoint(pos, size, color);
    }

    pub fn pushLineAA(self: *WindowRenderer, a: [2]f32, b: [2]f32, thickness: f32, color: [4]f32) !bool {
        return try self.scene.pushLineAA(a, b, thickness, color);
    }

    pub fn createImage(self: *WindowRenderer, width: u32, height: u32, rgba_pixels: []const u8) !window.ImageId {
        return try self.image_store.createImage(width, height, rgba_pixels);
    }

    pub fn updateImage(self: *WindowRenderer, image_id: window.ImageId, width: u32, height: u32, rgba_pixels: []const u8) !void {
        try self.image_store.updateImage(image_id, width, height, rgba_pixels);
    }

    pub fn pushImage(self: *WindowRenderer, image_id: window.ImageId, rect: window.Rect, tint: [4]f32) !void {
        try self.image_store.pushImage(&self.scene, image_id, rect, tint);
    }

    pub fn pushDrawList(self: *WindowRenderer, cmds: []const window.DrawCmd) !void {
        try self.scene.pushDrawList(cmds, self.text_store.textProvider());
    }

    pub fn pushText(self: *WindowRenderer, cmd: anytype, clip: ?window.Rect) !void {
        try self.scene.pushText(cmd, clip, self.text_store.textProvider());
    }

    pub fn setDefaultTextFontFromFile(self: *WindowRenderer, io: std.Io, path: []const u8, size_px: f32, raster_scale: f32) !window.TextFontId {
        return try self.text_store.setDefaultTextFontFromFile(io, path, size_px, raster_scale);
    }

    pub fn addTextFontFromFile(self: *WindowRenderer, io: std.Io, path: []const u8, size_px: f32, fallback: ?window.TextFontId, raster_scale: f32) !window.TextFontId {
        return try self.text_store.addTextFontFromFile(io, path, size_px, fallback, raster_scale);
    }

    pub fn setDefaultTextFont(self: *WindowRenderer, font_id: window.TextFontId) void {
        self.text_store.setDefaultTextFont(font_id);
    }

    pub fn acquireBitmapFont(self: *WindowRenderer, size_px: f32, fallback: ?window.TextFontId) !window.TextFontId {
        return try self.text_store.acquireBitmapFont(size_px, fallback);
    }

    pub fn releaseTextFont(self: *WindowRenderer, font_id: window.TextFontId) void {
        self.text_store.releaseTextFont(font_id, self.frame_index, self.retire_latency);
    }

    pub fn createBitmapFont(self: *WindowRenderer, size_px: f32, fallback: ?window.TextFontId) !window.TextFontId {
        return try self.text_store.createBitmapFont(size_px, fallback);
    }

    pub fn measureText(self: *WindowRenderer, text: []const u8, font_size: f32, font_id: ?window.TextFontId) window.Size {
        return self.text_store.measureText(text, font_size, font_id);
    }

    pub fn createNode(self: *WindowRenderer) !window.NodeId {
        return try self.retained_store.createNode();
    }

    pub fn setNodeLayer(self: *WindowRenderer, id: window.NodeId, layer: i32) !void {
        try self.retained_store.setNodeLayer(id, layer);
    }

    pub fn updateNode(self: *WindowRenderer, id: window.NodeId, verts: []const window.Vertex) !void {
        try self.retained_store.updateNode(id, verts);
    }

    pub fn removeNode(self: *WindowRenderer, id: window.NodeId) !void {
        try self.retained_store.removeNode(id);
    }
};

fn resolveWindowBatchTexture(context: *anyopaque, batch: Batch) ?TextureResource {
    const renderer: *WindowRenderer = @ptrCast(@alignCast(context));
    return switch (batch.kind) {
        .text => renderer.text_store.textureForBatch(batch),
        .image => renderer.image_store.textureForBatch(batch),
        else => null,
    };
}

pub const TextGlyph = struct {
    uv0: [2]f32,
    uv1: [2]f32,
    size: [2]f32,
    bearing: [2]f32,
    advance: f32,
};

pub const ResolvedTextGlyph = struct {
    font_id: window.TextFontId,
    glyph: TextGlyph,
};

pub const ResolveTextGlyphFn = *const fn (context: *anyopaque, base_font_id: window.TextFontId, codepoint: u21) ?ResolvedTextGlyph;
pub const FontMetricsFn = *const fn (context: *anyopaque, font_id: window.TextFontId) ?FontMetrics;
pub const DefaultFontFn = *const fn (context: *anyopaque) ?window.TextFontId;

pub const FontMetrics = struct {
    size_px: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
};

pub const TextProvider = struct {
    context: *anyopaque,
    defaultFontFn: DefaultFontFn,
    fontMetricsFn: FontMetricsFn,
    resolveGlyphFn: ResolveTextGlyphFn,
};

const FontKind = enum {
    bitmap,
    truetype,
};

const FontState = enum(u2) {
    alive,
    retiring,
    destroyed,
};

const RetiredFont = struct {
    id: window.TextFontId,
    retire_at: u64,
};

const TextFont = struct {
    id: window.TextFontId,
    kind: FontKind,
    ref_count: u32,
    state: FontState,
    size_px: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    atlas_w: u32,
    atlas_h: u32,
    atlas_pixels: []u8,
    cursor_x: u32,
    cursor_y: u32,
    row_h: u32,
    glyphs: std.AutoHashMap(u21, TextGlyph),
    gpu_texture: ?TextureResource,
    fallback: ?window.TextFontId,
    font_data: ?[]u8 = null,
    parsed_font: ?cangjie.Font = null,
    raster_scale: f32 = 1.0,
};

pub const TextAtlasStore = struct {
    allocator: std.mem.Allocator,
    fonts: std.ArrayList(TextFont),
    retired_fonts: std.ArrayList(RetiredFont),
    default_font: ?window.TextFontId = null,
    gpu_context: ?*backend.RenderContext = null,
    texture_bind_group_layout: ?backend.BindGroupLayoutHandle = null,

    pub fn init(allocator: std.mem.Allocator) !TextAtlasStore {
        return .{
            .allocator = allocator,
            .fonts = try std.ArrayList(TextFont).initCapacity(allocator, 4),
            .retired_fonts = try std.ArrayList(RetiredFont).initCapacity(allocator, 4),
        };
    }

    pub fn deinit(self: *TextAtlasStore) void {
        self.processRetiredFonts(0, true);
        for (self.fonts.items) |*font| {
            if (font.state != .destroyed) self.destroyFontResources(font);
        }
        self.fonts.deinit(self.allocator);
        self.retired_fonts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setGpuContext(self: *TextAtlasStore, gctx: ?*backend.RenderContext, texture_bind_group_layout: ?backend.BindGroupLayoutHandle) void {
        self.gpu_context = gctx;
        self.texture_bind_group_layout = texture_bind_group_layout;
    }

    pub fn initDefaultTextFont(self: *TextAtlasStore) !void {
        self.default_font = try self.acquireBitmapFont(7.0, null);
    }

    pub fn setDefaultTextFontFromFile(self: *TextAtlasStore, io: std.Io, path: []const u8, size_px: f32, raster_scale: f32) !window.TextFontId {
        const fallback = self.default_font;
        const font_data = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(64 * 1024 * 1024));
        const font_id = try self.createTrueTypeFontUncached(font_data, size_px, fallback, raster_scale);
        self.default_font = font_id;
        return font_id;
    }

    pub fn addTextFontFromFile(self: *TextAtlasStore, io: std.Io, path: []const u8, size_px: f32, fallback: ?window.TextFontId, raster_scale: f32) !window.TextFontId {
        const font_data = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(64 * 1024 * 1024));
        return try self.createTrueTypeFontUncached(font_data, size_px, fallback, raster_scale);
    }

    pub fn setDefaultTextFont(self: *TextAtlasStore, font_id: window.TextFontId) void {
        self.default_font = font_id;
    }

    pub fn acquireBitmapFont(self: *TextAtlasStore, size_px: f32, fallback: ?window.TextFontId) !window.TextFontId {
        for (self.fonts.items) |*font| {
            if (font.state != .alive) continue;
            if (font.kind == .bitmap and font.size_px == size_px and font.fallback == fallback) {
                font.ref_count += 1;
                return font.id;
            }
        }
        return try self.createBitmapFontUncached(size_px, fallback);
    }

    pub fn createBitmapFont(self: *TextAtlasStore, size_px: f32, fallback: ?window.TextFontId) !window.TextFontId {
        return try self.acquireBitmapFont(size_px, fallback);
    }

    pub fn releaseTextFont(self: *TextAtlasStore, font_id: window.TextFontId, frame_index: u64, retire_latency: u32) void {
        if (self.default_font != null and self.default_font.? == font_id) return;
        const idx: usize = @intCast(font_id);
        if (idx >= self.fonts.items.len) return;
        var font = &self.fonts.items[idx];
        if (font.state != .alive) return;
        if (font.ref_count == 0) return;
        font.ref_count -= 1;
        if (font.ref_count == 0) {
            font.state = .retiring;
            self.retired_fonts.append(self.allocator, .{ .id = font_id, .retire_at = frame_index + retire_latency }) catch {};
        }
    }

    pub fn processRetiredFonts(self: *TextAtlasStore, frame_index: u64, force: bool) void {
        var i: usize = 0;
        while (i < self.retired_fonts.items.len) {
            const item = self.retired_fonts.items[i];
            if (!force and item.retire_at > frame_index) {
                i += 1;
                continue;
            }
            const idx: usize = @intCast(item.id);
            if (idx < self.fonts.items.len) {
                const font = &self.fonts.items[idx];
                if (font.state == .retiring) self.destroyFontResources(font);
            }
            _ = self.retired_fonts.swapRemove(i);
        }
    }

    pub fn measureText(self: *TextAtlasStore, text: []const u8, font_size: f32, font_id: ?window.TextFontId) window.Size {
        const base_font_id = font_id orelse self.default_font orelse return .{ .w = 0, .h = font_size };
        const base_font = self.fontById(base_font_id) orelse return .{ .w = 0, .h = font_size };
        const base_scale = font_size / base_font.size_px;
        const line_height = (base_font.ascent - base_font.descent + base_font.line_gap) * base_scale;

        var max_x: f32 = 0;
        var pen_x: f32 = 0;
        var lines: u32 = 1;
        const view = std.unicode.Utf8View.initUnchecked(text);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp == '\n') {
                if (pen_x > max_x) max_x = pen_x;
                pen_x = 0;
                lines += 1;
                continue;
            }
            const resolved = self.resolveGlyph(base_font_id, cp) orelse continue;
            const resolved_font = self.fontById(resolved.font_id) orelse continue;
            const scale = font_size / resolved_font.size_px;
            pen_x += resolved.glyph.advance * scale;
        }
        if (pen_x > max_x) max_x = pen_x;
        return .{ .w = max_x, .h = @as(f32, @floatFromInt(lines)) * line_height };
    }

    pub fn textProvider(self: *TextAtlasStore) TextProvider {
        return .{
            .context = self,
            .defaultFontFn = gpuDefaultFont,
            .fontMetricsFn = gpuFontMetrics,
            .resolveGlyphFn = resolveGpuGlyph,
        };
    }

    pub fn cpuProvider(self: *TextAtlasStore) window_draw.TextAtlasProvider {
        return .{
            .context = self,
            .defaultFontIndexFn = cpuDefaultFontIndex,
            .fontCountFn = cpuFontCount,
            .fontFn = cpuFont,
            .resolveGlyphFn = resolveCpuGlyph,
        };
    }

    pub fn textureForBatch(self: *TextAtlasStore, batch: Batch) ?TextureResource {
        if (batch.kind != .text) return null;
        const font_id = batch.font_id orelse return null;
        const font = self.fontById(font_id) orelse return null;
        return font.gpu_texture;
    }

    pub fn fontCount(self: *const TextAtlasStore) usize {
        return self.fonts.items.len;
    }

    fn fontById(self: *TextAtlasStore, font_id: window.TextFontId) ?*TextFont {
        const idx: usize = @intCast(font_id);
        if (idx >= self.fonts.items.len) return null;
        return &self.fonts.items[idx];
    }

    fn createBitmapFontUncached(self: *TextAtlasStore, size_px: f32, fallback: ?window.TextFontId) !window.TextFontId {
        const atlas_w: u32 = 256;
        const atlas_h: u32 = 256;
        const atlas_pixels = try self.allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h));
        @memset(atlas_pixels, 0);
        const gpu_texture = self.createGpuTexture(atlas_w, atlas_h);
        const glyphs = std.AutoHashMap(u21, TextGlyph).init(self.allocator);
        const id: window.TextFontId = @intCast(self.fonts.items.len);
        var font = TextFont{
            .id = id,
            .kind = .bitmap,
            .ref_count = 1,
            .state = .alive,
            .size_px = size_px,
            .ascent = 7.0,
            .descent = 0.0,
            .line_gap = 1.0,
            .atlas_w = atlas_w,
            .atlas_h = atlas_h,
            .atlas_pixels = atlas_pixels,
            .cursor_x = 1,
            .cursor_y = 1,
            .row_h = 0,
            .glyphs = glyphs,
            .gpu_texture = gpu_texture,
            .fallback = fallback,
        };
        var cp: u21 = 32;
        while (cp < 127) : (cp += 1) try bakeBitmapGlyph(&font, cp);
        if (!font.glyphs.contains('?')) try bakeBitmapGlyph(&font, '?');
        self.uploadAtlas(&font, 0, 0, atlas_w, atlas_h);
        try self.fonts.append(self.allocator, font);
        return id;
    }

    fn createTrueTypeFontUncached(self: *TextAtlasStore, font_data: []u8, size_px: f32, fallback: ?window.TextFontId, raster_scale_value: f32) !window.TextFontId {
        var own_font_data = true;
        errdefer if (own_font_data) self.allocator.free(font_data);

        const raster_scale: f32 = @max(raster_scale_value, 1.0);
        const atlas_w: u32 = if (raster_scale > 1.25) 2048 else 1024;
        const atlas_h: u32 = if (raster_scale > 1.25) 2048 else 1024;
        const atlas_pixels = try self.allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h));
        var own_atlas_pixels = true;
        errdefer if (own_atlas_pixels) self.allocator.free(atlas_pixels);
        @memset(atlas_pixels, 0);

        const gpu_texture = self.createGpuTexture(atlas_w, atlas_h);
        const glyphs = std.AutoHashMap(u21, TextGlyph).init(self.allocator);
        const id: window.TextFontId = @intCast(self.fonts.items.len);
        var parsed_font = try cangjie.Font.parse(self.allocator, font_data);
        var own_parsed_font = true;
        errdefer if (own_parsed_font) parsed_font.deinit();
        var font_value = TextFont{
            .id = id,
            .kind = .truetype,
            .ref_count = 1,
            .state = .alive,
            .size_px = size_px,
            .ascent = @as(f32, @floatFromInt(parsed_font.ascender)) * size_px / @as(f32, @floatFromInt(parsed_font.units_per_em)),
            .descent = @as(f32, @floatFromInt(parsed_font.descender)) * size_px / @as(f32, @floatFromInt(parsed_font.units_per_em)),
            .line_gap = @as(f32, @floatFromInt(parsed_font.line_gap)) * size_px / @as(f32, @floatFromInt(parsed_font.units_per_em)),
            .atlas_w = atlas_w,
            .atlas_h = atlas_h,
            .atlas_pixels = atlas_pixels,
            .cursor_x = 1,
            .cursor_y = 1,
            .row_h = 0,
            .glyphs = glyphs,
            .gpu_texture = gpu_texture,
            .fallback = fallback,
            .font_data = font_data,
            .parsed_font = parsed_font,
            .raster_scale = raster_scale,
        };
        own_font_data = false;
        own_atlas_pixels = false;
        own_parsed_font = false;
        errdefer self.destroyFontResources(&font_value);

        var cp: u21 = 32;
        while (cp < 127) : (cp += 1) {
            bakeTrueTypeGlyph(&font_value, cp) catch |err| switch (err) {
                error.InvalidGlyph, error.UnsupportedGlyph => {},
                else => return err,
            };
        }
        if (font_value.glyphs.count() == 0) return error.InvalidTextFont;
        self.uploadAtlas(&font_value, 0, 0, atlas_w, atlas_h);
        try self.fonts.append(self.allocator, font_value);
        return id;
    }

    fn createGpuTexture(self: *TextAtlasStore, width: u32, height: u32) ?TextureResource {
        if (!backend.compiled_with_zgpu) return null;
        const gctx = self.gpu_context orelse return null;
        const layout = self.texture_bind_group_layout orelse return null;
        return createTextureResource(gctx, layout, width, height, .alpha);
    }

    fn destroyFontResources(self: *TextAtlasStore, font_value: *TextFont) void {
        if (backend.compiled_with_zgpu) {
            if (self.gpu_context) |ctx| {
                if (font_value.gpu_texture) |*texture| destroyTextureResource(ctx, texture);
            }
        }
        if (font_value.parsed_font) |*parsed_font| parsed_font.deinit();
        if (font_value.font_data) |font_data| self.allocator.free(font_data);
        self.allocator.free(font_value.atlas_pixels);
        font_value.glyphs.deinit();
        font_value.state = .destroyed;
    }

    fn resolveGlyph(self: *TextAtlasStore, font_id: window.TextFontId, codepoint: u21) ?ResolvedTextGlyph {
        var current = font_id;
        var guard: u8 = 0;
        while (guard < 8) : (guard += 1) {
            const current_font = self.fontById(current) orelse return null;
            if (current_font.glyphs.get(codepoint)) |glyph| return .{ .font_id = current, .glyph = glyph };
            if (current_font.kind == .truetype) {
                bakeTrueTypeGlyph(current_font, codepoint) catch {};
                if (current_font.glyphs.get(codepoint)) |glyph| {
                    self.uploadAtlas(current_font, 0, 0, current_font.atlas_w, current_font.atlas_h);
                    return .{ .font_id = current, .glyph = glyph };
                }
            }
            if (current_font.fallback) |fb| {
                current = fb;
                continue;
            }
            if (current_font.glyphs.get('?')) |glyph| return .{ .font_id = current, .glyph = glyph };
            break;
        }
        return null;
    }

    fn uploadAtlas(self: *TextAtlasStore, font_value: *const TextFont, x: u32, y: u32, w: u32, h: u32) void {
        if (!backend.compiled_with_zgpu) return;
        const gctx = self.gpu_context orelse return;
        const texture = font_value.gpu_texture orelse return;
        uploadAlphaAtlas(gctx, texture, font_value.atlas_pixels, font_value.atlas_w, font_value.atlas_h, x, y, w, h);
    }
};

fn cpuDefaultFontIndex(context: *anyopaque) ?usize {
    const store: *TextAtlasStore = @ptrCast(@alignCast(context));
    return if (store.default_font) |font_id| @as(usize, @intCast(font_id)) else null;
}

fn cpuFontCount(context: *anyopaque) usize {
    const store: *TextAtlasStore = @ptrCast(@alignCast(context));
    return store.fonts.items.len;
}

fn cpuFont(context: *anyopaque, index: usize) ?window_draw.TextAtlasFont {
    const store: *TextAtlasStore = @ptrCast(@alignCast(context));
    if (index >= store.fonts.items.len) return null;
    const font_value = store.fonts.items[index];
    return .{
        .size_px = font_value.size_px,
        .ascent = font_value.ascent,
        .descent = font_value.descent,
        .line_gap = font_value.line_gap,
        .atlas_w = font_value.atlas_w,
        .atlas_h = font_value.atlas_h,
        .atlas_pixels = font_value.atlas_pixels,
    };
}

fn resolveCpuGlyph(context: *anyopaque, base_font_index: usize, codepoint: u21) ?window_draw.ResolvedGlyph {
    const store: *TextAtlasStore = @ptrCast(@alignCast(context));
    const resolved = store.resolveGlyph(@intCast(base_font_index), codepoint) orelse return null;
    return .{
        .font_index = @intCast(resolved.font_id),
        .glyph = .{
            .uv0 = resolved.glyph.uv0,
            .uv1 = resolved.glyph.uv1,
            .size = resolved.glyph.size,
            .bearing = resolved.glyph.bearing,
            .advance = resolved.glyph.advance,
        },
    };
}

fn gpuDefaultFont(context: *anyopaque) ?window.TextFontId {
    const store: *TextAtlasStore = @ptrCast(@alignCast(context));
    return store.default_font;
}

fn gpuFontMetrics(context: *anyopaque, font_id: window.TextFontId) ?FontMetrics {
    const store: *TextAtlasStore = @ptrCast(@alignCast(context));
    const font_value = store.fontById(font_id) orelse return null;
    return .{
        .size_px = font_value.size_px,
        .ascent = font_value.ascent,
        .descent = font_value.descent,
        .line_gap = font_value.line_gap,
    };
}

fn resolveGpuGlyph(context: *anyopaque, base_font_id: window.TextFontId, codepoint: u21) ?ResolvedTextGlyph {
    const store: *TextAtlasStore = @ptrCast(@alignCast(context));
    return store.resolveGlyph(base_font_id, codepoint);
}

fn allocAtlasRegion(font_value: *TextFont, w: u32, h: u32) ?struct { x: u32, y: u32 } {
    if (font_value.cursor_x + w + 1 > font_value.atlas_w) {
        font_value.cursor_x = 1;
        font_value.cursor_y += font_value.row_h + 1;
        font_value.row_h = 0;
    }
    if (font_value.cursor_y + h + 1 > font_value.atlas_h) return null;
    const x = font_value.cursor_x;
    const y = font_value.cursor_y;
    font_value.cursor_x += w + 1;
    if (h > font_value.row_h) font_value.row_h = h;
    return .{ .x = x, .y = y };
}

fn bakeBitmapGlyph(font_value: *TextFont, codepoint: u21) !void {
    const glyph_bits = getBitmapGlyph(@intCast(codepoint));
    const gw: u32 = 5;
    const gh: u32 = 7;
    const region = allocAtlasRegion(font_value, gw, gh) orelse return error.TextAtlasFull;
    var y: u32 = 0;
    while (y < gh) : (y += 1) {
        const bits = glyph_bits[@intCast(y)];
        var x: u32 = 0;
        while (x < gw) : (x += 1) {
            const shift: u3 = @intCast(gw - 1 - x);
            const bit_on = ((bits >> shift) & 1) == 1;
            if (bit_on) {
                const idx = @as(usize, region.y + y) * @as(usize, font_value.atlas_w) + @as(usize, region.x + x);
                font_value.atlas_pixels[idx] = 255;
            }
        }
    }
    try font_value.glyphs.put(@intCast(codepoint), .{
        .uv0 = .{
            @as(f32, @floatFromInt(region.x)) / @as(f32, @floatFromInt(font_value.atlas_w)),
            @as(f32, @floatFromInt(region.y)) / @as(f32, @floatFromInt(font_value.atlas_h)),
        },
        .uv1 = .{
            @as(f32, @floatFromInt(region.x + gw)) / @as(f32, @floatFromInt(font_value.atlas_w)),
            @as(f32, @floatFromInt(region.y + gh)) / @as(f32, @floatFromInt(font_value.atlas_h)),
        },
        .size = .{ @floatFromInt(gw), @floatFromInt(gh) },
        .bearing = .{ 0.0, 0.0 },
        .advance = 6.0,
    });
}

fn bakeTrueTypeGlyph(font_value: *TextFont, codepoint: u21) !void {
    const parsed_font = &(font_value.parsed_font orelse return error.InvalidTextFont);
    const glyph_id = try parsed_font.glyphIndex(codepoint);
    if (glyph_id == 0) return error.InvalidGlyph;

    var layout_buffer = cangjie.LayoutBuffer.init(font_value.glyphs.allocator);
    defer layout_buffer.deinit();
    var encoded: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(codepoint, &encoded);
    const raster_scale = @max(font_value.raster_scale, 1.0);
    const raster_size = font_value.size_px * raster_scale;
    const run = try cangjie.TextShaper.shapeUtf8(parsed_font, &layout_buffer, encoded[0..len], raster_size);
    if (run.glyphs.len == 0) return error.InvalidGlyph;

    const scale = raster_size / @as(f32, @floatFromInt(parsed_font.units_per_em));
    const ascent = @max(0.0, @as(f32, @floatFromInt(parsed_font.ascender)) * scale);
    const descent = @max(0.0, @as(f32, @floatFromInt(-parsed_font.descender)) * scale);
    const width_f = @max(1.0, @ceil(run.width()) + 4.0);
    const height_f = @max(1.0, @ceil(ascent + descent) + 4.0);
    const gw: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(std.math.maxInt(u32))), width_f));
    const gh: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(std.math.maxInt(u32))), height_f));
    var target = try cangjie.RenderTarget.init(font_value.glyphs.allocator, gw, gh);
    defer target.deinit();
    var rasterizer = cangjie.Rasterizer.init(font_value.glyphs.allocator);
    rasterizer.hint_size_px = font_value.size_px;
    try rasterizer.renderRun(&target, run, 2.0, 2.0 + ascent);

    const ink = glyphInkBounds(&target) orelse GlyphInkBounds{ .x0 = 0, .y0 = 0, .x1 = gw, .y1 = gh };
    const tight_w = ink.x1 - ink.x0;
    const tight_h = ink.y1 - ink.y0;
    const tight_region = allocAtlasRegion(font_value, tight_w, tight_h) orelse return error.TextAtlasFull;

    var y: u32 = 0;
    while (y < tight_h) : (y += 1) {
        var x: u32 = 0;
        while (x < tight_w) : (x += 1) {
            const idx = @as(usize, tight_region.y + y) * @as(usize, font_value.atlas_w) + @as(usize, tight_region.x + x);
            font_value.atlas_pixels[idx] = textCoverageContrastByte(target.at(ink.x0 + x, ink.y0 + y));
        }
    }
    const metrics = try parsed_font.horizontalMetrics(glyph_id);
    const measured_advance = if (run.glyphs.len == 1) run.glyphs[0].x_advance else @as(f32, @floatFromInt(metrics.advance_width)) * scale;
    const advance = @max(measured_advance, width_f * 0.48);
    try font_value.glyphs.put(codepoint, .{
        .uv0 = .{
            @as(f32, @floatFromInt(tight_region.x)) / @as(f32, @floatFromInt(font_value.atlas_w)),
            @as(f32, @floatFromInt(tight_region.y)) / @as(f32, @floatFromInt(font_value.atlas_h)),
        },
        .uv1 = .{
            @as(f32, @floatFromInt(tight_region.x + tight_w)) / @as(f32, @floatFromInt(font_value.atlas_w)),
            @as(f32, @floatFromInt(tight_region.y + tight_h)) / @as(f32, @floatFromInt(font_value.atlas_h)),
        },
        .size = .{ @as(f32, @floatFromInt(tight_w)) / raster_scale, @as(f32, @floatFromInt(tight_h)) / raster_scale },
        .bearing = .{ (@as(f32, @floatFromInt(ink.x0)) - 2.0) / raster_scale, (@as(f32, @floatFromInt(ink.y0)) - 2.0) / raster_scale },
        .advance = advance / raster_scale,
    });
}

const GlyphInkBounds = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
};

fn glyphInkBounds(target: *const cangjie.RenderTarget) ?GlyphInkBounds {
    var x0: u32 = target.width;
    var y0: u32 = target.height;
    var x1: u32 = 0;
    var y1: u32 = 0;
    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        var x: u32 = 0;
        while (x < target.width) : (x += 1) {
            if (target.at(x, y) == 0) continue;
            x0 = @min(x0, x);
            y0 = @min(y0, y);
            x1 = @max(x1, x + 1);
            y1 = @max(y1, y + 1);
        }
    }
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn textCoverageContrastByte(value: u8) u8 {
    const c = @as(f32, @floatFromInt(value)) / 255.0;
    const adjusted = if (c >= 0.82)
        1.0
    else if (c <= 0.08)
        0.0
    else blk: {
        const t = (c - 0.08) / 0.74;
        break :blk t * t * (3.0 - 2.0 * t);
    };
    return @intFromFloat(@round(adjusted * 255.0));
}

fn getBitmapGlyph(c: u8) [7]u8 {
    if (c >= 'a' and c <= 'z') return getBitmapGlyph(@as(u8, c - 32));
    return switch (c) {
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
        'A' => .{ 0b00100, 0b01010, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D' => .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
        '_' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 },
        '.' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 },
        ':' => .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 },
        '/' => .{ 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000, 0b00000 },
        ' ' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
        else => .{ 0b11111, 0b10001, 0b10101, 0b10001, 0b10101, 0b10001, 0b11111 },
    };
}

pub const ImmediateScene = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(window.Vertex),
    paint_quad_vertices: std.ArrayList(window.PaintQuadVertex),
    text_vertices: std.ArrayList(window.TextVertex),
    line_vertices: std.ArrayList(window.LineVertex),
    batches: std.ArrayList(Batch),
    max_vertices: u32,
    max_paint_quad_vertices: u32,
    max_text_vertices: u32,
    max_line_vertices: u32,

    pub fn init(allocator: std.mem.Allocator, max_vertices: u32, max_paint_quad_vertices: u32, max_text_vertices: u32, max_line_vertices: u32) !ImmediateScene {
        return .{
            .allocator = allocator,
            .vertices = try std.ArrayList(window.Vertex).initCapacity(allocator, max_vertices),
            .paint_quad_vertices = try std.ArrayList(window.PaintQuadVertex).initCapacity(allocator, max_paint_quad_vertices),
            .text_vertices = try std.ArrayList(window.TextVertex).initCapacity(allocator, max_text_vertices),
            .line_vertices = try std.ArrayList(window.LineVertex).initCapacity(allocator, max_line_vertices),
            .batches = try std.ArrayList(Batch).initCapacity(allocator, 64),
            .max_vertices = max_vertices,
            .max_paint_quad_vertices = max_paint_quad_vertices,
            .max_text_vertices = max_text_vertices,
            .max_line_vertices = max_line_vertices,
        };
    }

    pub fn deinit(self: *ImmediateScene) void {
        self.vertices.deinit(self.allocator);
        self.paint_quad_vertices.deinit(self.allocator);
        self.text_vertices.deinit(self.allocator);
        self.line_vertices.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginFrame(self: *ImmediateScene, retained_vertices: []const window.Vertex) !void {
        self.vertices.clearRetainingCapacity();
        self.paint_quad_vertices.clearRetainingCapacity();
        self.text_vertices.clearRetainingCapacity();
        self.line_vertices.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        if (retained_vertices.len > self.max_vertices) return error.VertexBufferOverflow;
        try self.vertices.appendSlice(self.allocator, retained_vertices);
        if (retained_vertices.len > 0) {
            self.addBatch(0, @intCast(retained_vertices.len), null, .shape, null, null);
        }
    }

    pub fn appendRetainedVertices(self: *ImmediateScene, retained_vertices: []const window.Vertex) !void {
        if (retained_vertices.len == 0) return;
        const start = self.vertices.items.len;
        if (start + retained_vertices.len > self.max_vertices) return error.VertexBufferOverflow;
        try self.vertices.appendSlice(self.allocator, retained_vertices);
        self.addBatch(@intCast(start), @intCast(retained_vertices.len), null, .shape, null, null);
    }

    pub fn pushDrawList(self: *ImmediateScene, cmds: []const window.DrawCmd, text_provider: TextProvider) !void {
        var sink = ImmediateSceneSink{ .scene = self, .text_provider = text_provider };
        try window_lower.lowerDrawList(ImmediateSceneSink, &sink, self.allocator, cmds);
    }

    pub fn pushTriangle(self: *ImmediateScene, a: window.Vertex, b: window.Vertex, c: window.Vertex) !void {
        if (self.vertices.items.len + 3 > self.max_vertices) return error.VertexBufferOverflow;
        try self.vertices.append(self.allocator, a);
        try self.vertices.append(self.allocator, b);
        try self.vertices.append(self.allocator, c);
    }

    pub fn pushRect(self: *ImmediateScene, rect: window.Rect, color: [4]f32) !void {
        const x0 = rect.x;
        const y0 = rect.y;
        const x1 = rect.x + rect.w;
        const y1 = rect.y + rect.h;
        const v0 = window.Vertex{ .pos = .{ x0, y0 }, .color = color };
        const v1 = window.Vertex{ .pos = .{ x1, y0 }, .color = color };
        const v2 = window.Vertex{ .pos = .{ x1, y1 }, .color = color };
        const v3 = window.Vertex{ .pos = .{ x0, y1 }, .color = color };
        try self.pushTriangle(v0, v1, v2);
        try self.pushTriangle(v0, v2, v3);
    }

    pub fn pushRoundedRect(self: *ImmediateScene, rect: window.Rect, radius: f32, color: [4]f32) !void {
        const r = roundedRectRadius(rect, radius);
        if (r <= 0.0) return self.pushRect(rect, color);
        const segments = roundedRectCornerSegments(r);
        const vertex_count = 1 + (segments + 1) * 4;
        if (self.vertices.items.len + vertex_count * 3 > self.max_vertices) return error.VertexBufferOverflow;

        const center = [2]f32{ rect.x + rect.w * 0.5, rect.y + rect.h * 0.5 };
        const center_vertex = window.Vertex{ .pos = center, .color = color };
        var prev = roundedRectPoint(rect, r, 0.0);
        var corner: usize = 0;
        while (corner < 4) : (corner += 1) {
            var i: usize = 0;
            while (i <= segments) : (i += 1) {
                if (corner == 0 and i == 0) continue;
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
                const angle = @as(f32, @floatFromInt(corner)) * (std.math.pi * 0.5) + t * (std.math.pi * 0.5);
                const next = roundedRectPoint(rect, r, angle);
                try self.pushTriangle(center_vertex, .{ .pos = prev, .color = color }, .{ .pos = next, .color = color });
                prev = next;
            }
        }
        try self.pushTriangle(center_vertex, .{ .pos = prev, .color = color }, .{ .pos = roundedRectPoint(rect, r, 0.0), .color = color });
    }

    pub fn pushPaintQuad(self: *ImmediateScene, quad: window.PaintQuad) !void {
        if (quad.rect.w <= 0.0 or quad.rect.h <= 0.0) return;
        if (self.paint_quad_vertices.items.len + 6 > self.max_paint_quad_vertices) return error.VertexBufferOverflow;
        const x0 = quad.rect.x;
        const y0 = quad.rect.y;
        const x1 = quad.rect.x + quad.rect.w;
        const y1 = quad.rect.y + quad.rect.h;
        const rect_origin = [2]f32{ quad.rect.x, quad.rect.y };
        const rect_size = [2]f32{ quad.rect.w, quad.rect.h };
        const radius = roundedRectRadius(quad.rect, quad.radius);
        const bw = @max(0.0, quad.border_width);
        const v0 = window.PaintQuadVertex{ .pos = .{ x0, y0 }, .rect_origin = rect_origin, .rect_size = rect_size, .radius = radius, .background = quad.background, .border_color = quad.border_color, .border_width = bw };
        const v1 = window.PaintQuadVertex{ .pos = .{ x1, y0 }, .rect_origin = rect_origin, .rect_size = rect_size, .radius = radius, .background = quad.background, .border_color = quad.border_color, .border_width = bw };
        const v2 = window.PaintQuadVertex{ .pos = .{ x1, y1 }, .rect_origin = rect_origin, .rect_size = rect_size, .radius = radius, .background = quad.background, .border_color = quad.border_color, .border_width = bw };
        const v3 = window.PaintQuadVertex{ .pos = .{ x0, y1 }, .rect_origin = rect_origin, .rect_size = rect_size, .radius = radius, .background = quad.background, .border_color = quad.border_color, .border_width = bw };
        try self.paint_quad_vertices.append(self.allocator, v0);
        try self.paint_quad_vertices.append(self.allocator, v1);
        try self.paint_quad_vertices.append(self.allocator, v2);
        try self.paint_quad_vertices.append(self.allocator, v0);
        try self.paint_quad_vertices.append(self.allocator, v2);
        try self.paint_quad_vertices.append(self.allocator, v3);
    }

    pub fn pushStrokeRoundedRect(self: *ImmediateScene, rect: window.Rect, radius: f32, thickness: f32, color: [4]f32) !void {
        if (thickness <= 0.0) return;
        const r = roundedRectRadius(rect, radius);
        if (r <= 0.0) {
            const points = [_][2]f32{
                .{ rect.x, rect.y },
                .{ rect.x + rect.w, rect.y },
                .{ rect.x + rect.w, rect.y + rect.h },
                .{ rect.x, rect.y + rect.h },
            };
            try self.pushFeatheredPolyline(&points, thickness, color, true);
            return;
        }
        const segments = roundedRectCornerSegments(r);
        var points = try std.ArrayList([2]f32).initCapacity(self.allocator, (segments + 1) * 4);
        defer points.deinit(self.allocator);
        try points.append(self.allocator, roundedRectPoint(rect, r, 0.0));
        var corner: usize = 0;
        while (corner < 4) : (corner += 1) {
            var i: usize = 0;
            while (i <= segments) : (i += 1) {
                if (corner == 0 and i == 0) continue;
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
                const angle = @as(f32, @floatFromInt(corner)) * (std.math.pi * 0.5) + t * (std.math.pi * 0.5);
                try points.append(self.allocator, roundedRectPoint(rect, r, angle));
            }
        }
        try self.pushFeatheredPolyline(points.items, thickness, color, true);
    }

    pub fn pushLinearGradientRect(self: *ImmediateScene, gradient: window.LinearGradientRect) !void {
        if (gradient.radius > 0.0) {
            try self.pushRoundedGradientRect(gradient.rect, gradient.radius, linearGradientColorAt, gradient);
            return;
        }
        const x0 = gradient.rect.x;
        const y0 = gradient.rect.y;
        const x1 = gradient.rect.x + gradient.rect.w;
        const y1 = gradient.rect.y + gradient.rect.h;
        try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = linearGradientColorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y0 }, .color = linearGradientColorAt(gradient, .{ x1, y0 }) }, .{ .pos = .{ x1, y1 }, .color = linearGradientColorAt(gradient, .{ x1, y1 }) });
        try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = linearGradientColorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y1 }, .color = linearGradientColorAt(gradient, .{ x1, y1 }) }, .{ .pos = .{ x0, y1 }, .color = linearGradientColorAt(gradient, .{ x0, y1 }) });
    }

    pub fn pushRadialGradientRect(self: *ImmediateScene, gradient: window.RadialGradientRect) !void {
        if (gradient.radius_px > 0.0) {
            try self.pushRoundedGradientRect(gradient.rect, gradient.radius_px, radialGradientColorAt, gradient);
            return;
        }
        const x0 = gradient.rect.x;
        const y0 = gradient.rect.y;
        const x1 = gradient.rect.x + gradient.rect.w;
        const y1 = gradient.rect.y + gradient.rect.h;
        try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = radialGradientColorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y0 }, .color = radialGradientColorAt(gradient, .{ x1, y0 }) }, .{ .pos = .{ x1, y1 }, .color = radialGradientColorAt(gradient, .{ x1, y1 }) });
        try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = radialGradientColorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y1 }, .color = radialGradientColorAt(gradient, .{ x1, y1 }) }, .{ .pos = .{ x0, y1 }, .color = radialGradientColorAt(gradient, .{ x0, y1 }) });
    }

    pub fn pushSweepGradientRect(self: *ImmediateScene, gradient: window.SweepGradientRect) !void {
        if (gradient.radius > 0.0) {
            try self.pushRoundedGradientRect(gradient.rect, gradient.radius, sweepGradientColorAt, gradient);
            return;
        }
        const x0 = gradient.rect.x;
        const y0 = gradient.rect.y;
        const x1 = gradient.rect.x + gradient.rect.w;
        const y1 = gradient.rect.y + gradient.rect.h;
        try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = sweepGradientColorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y0 }, .color = sweepGradientColorAt(gradient, .{ x1, y0 }) }, .{ .pos = .{ x1, y1 }, .color = sweepGradientColorAt(gradient, .{ x1, y1 }) });
        try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = sweepGradientColorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y1 }, .color = sweepGradientColorAt(gradient, .{ x1, y1 }) }, .{ .pos = .{ x0, y1 }, .color = sweepGradientColorAt(gradient, .{ x0, y1 }) });
    }

    fn pushRoundedGradientRect(self: *ImmediateScene, rect: window.Rect, radius: f32, comptime colorAt: anytype, gradient: anytype) !void {
        const r = roundedRectRadius(rect, radius);
        if (r <= 0.0) {
            const x0 = rect.x;
            const y0 = rect.y;
            const x1 = rect.x + rect.w;
            const y1 = rect.y + rect.h;
            try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = colorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y0 }, .color = colorAt(gradient, .{ x1, y0 }) }, .{ .pos = .{ x1, y1 }, .color = colorAt(gradient, .{ x1, y1 }) });
            try self.pushTriangle(.{ .pos = .{ x0, y0 }, .color = colorAt(gradient, .{ x0, y0 }) }, .{ .pos = .{ x1, y1 }, .color = colorAt(gradient, .{ x1, y1 }) }, .{ .pos = .{ x0, y1 }, .color = colorAt(gradient, .{ x0, y1 }) });
            return;
        }
        const segments = roundedRectCornerSegments(r);
        const vertex_count = 1 + (segments + 1) * 4;
        if (self.vertices.items.len + vertex_count * 3 > self.max_vertices) return error.VertexBufferOverflow;

        const center = [2]f32{ rect.x + rect.w * 0.5, rect.y + rect.h * 0.5 };
        const center_vertex = window.Vertex{ .pos = center, .color = colorAt(gradient, center) };
        var prev = roundedRectPoint(rect, r, 0.0);
        var corner: usize = 0;
        while (corner < 4) : (corner += 1) {
            var i: usize = 0;
            while (i <= segments) : (i += 1) {
                if (corner == 0 and i == 0) continue;
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
                const angle = @as(f32, @floatFromInt(corner)) * (std.math.pi * 0.5) + t * (std.math.pi * 0.5);
                const next = roundedRectPoint(rect, r, angle);
                try self.pushTriangle(center_vertex, .{ .pos = prev, .color = colorAt(gradient, prev) }, .{ .pos = next, .color = colorAt(gradient, next) });
                prev = next;
            }
        }
        const first = roundedRectPoint(rect, r, 0.0);
        try self.pushTriangle(center_vertex, .{ .pos = prev, .color = colorAt(gradient, prev) }, .{ .pos = first, .color = colorAt(gradient, first) });
    }

    pub fn pushEllipse(self: *ImmediateScene, center: [2]f32, radius: [2]f32, color: [4]f32) !void {
        if (radius[0] <= 0.0 or radius[1] <= 0.0) return;
        const segments = ellipseSegmentCount(radius);
        if (self.vertices.items.len + segments * 3 > self.max_vertices) return error.VertexBufferOverflow;
        const center_vertex = window.Vertex{ .pos = center, .color = color };
        var prev = ellipsePoint(center, radius, 0.0);
        var i: usize = 1;
        while (i <= segments) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const next = ellipsePoint(center, radius, t * std.math.tau);
            try self.pushTriangle(center_vertex, .{ .pos = prev, .color = color }, .{ .pos = next, .color = color });
            prev = next;
        }
    }

    pub fn pushCircle(self: *ImmediateScene, center: [2]f32, radius: f32, color: [4]f32) !void {
        try self.pushEllipse(center, .{ radius, radius }, color);
    }

    pub fn pushStrokeEllipse(self: *ImmediateScene, center: [2]f32, radius: [2]f32, thickness: f32, color: [4]f32) !void {
        if (radius[0] <= 0.0 or radius[1] <= 0.0 or thickness <= 0.0) return;
        const segments = ellipseSegmentCount(radius);
        var points = try std.ArrayList([2]f32).initCapacity(self.allocator, segments);
        defer points.deinit(self.allocator);
        var i: usize = 0;
        while (i < segments) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            try points.append(self.allocator, ellipsePoint(center, radius, t * std.math.tau));
        }
        try self.pushFeatheredPolyline(points.items, thickness, color, true);
    }

    pub fn pushFillPath(self: *ImmediateScene, commands: []const window.PathCommand, color: [4]f32) !void {
        var subpaths = try flattenPathSubpaths(self.allocator, commands);
        defer {
            for (subpaths.items) |*subpath| subpath.deinit(self.allocator);
            subpaths.deinit(self.allocator);
        }
        for (subpaths.items) |subpath| {
            if (subpath.items.len < 3) continue;
            try self.pushTriangulatedPolygon(subpath.items, color);
        }
    }

    fn pushTriangulatedPolygon(self: *ImmediateScene, raw_points: []const [2]f32, color: [4]f32) !void {
        const points = trimClosedDuplicate(raw_points);
        if (points.len < 3) return;
        if (self.vertices.items.len + (points.len - 2) * 3 > self.max_vertices) return error.VertexBufferOverflow;
        if (points.len == 3) {
            try self.pushTriangle(.{ .pos = points[0], .color = color }, .{ .pos = points[1], .color = color }, .{ .pos = points[2], .color = color });
            return;
        }

        var indices = try std.ArrayList(usize).initCapacity(self.allocator, points.len);
        defer indices.deinit(self.allocator);
        if (polygonSignedArea(points) >= 0.0) {
            for (points, 0..) |_, i| try indices.append(self.allocator, i);
        } else {
            var i = points.len;
            while (i > 0) {
                i -= 1;
                try indices.append(self.allocator, i);
            }
        }

        var guard: usize = 0;
        while (indices.items.len > 3 and guard < points.len * points.len) : (guard += 1) {
            var clipped = false;
            var i: usize = 0;
            while (i < indices.items.len) : (i += 1) {
                const prev_i = if (i == 0) indices.items.len - 1 else i - 1;
                const next_i = if (i + 1 == indices.items.len) 0 else i + 1;
                const a_index = indices.items[prev_i];
                const b_index = indices.items[i];
                const c_index = indices.items[next_i];
                const a = points[a_index];
                const b = points[b_index];
                const c = points[c_index];
                if (!isConvexEar(a, b, c)) continue;
                if (triangleContainsAnyPoint(points, indices.items, a_index, b_index, c_index, a, b, c)) continue;
                try self.pushTriangle(.{ .pos = a, .color = color }, .{ .pos = b, .color = color }, .{ .pos = c, .color = color });
                _ = indices.orderedRemove(i);
                clipped = true;
                break;
            }
            if (!clipped) break;
        }

        if (indices.items.len == 3) {
            try self.pushTriangle(
                .{ .pos = points[indices.items[0]], .color = color },
                .{ .pos = points[indices.items[1]], .color = color },
                .{ .pos = points[indices.items[2]], .color = color },
            );
        } else {
            try self.pushTriangleFan(points, color);
        }
    }

    fn pushTriangleFan(self: *ImmediateScene, points: []const [2]f32, color: [4]f32) !void {
        if (points.len < 3) return;
        const anchor = window.Vertex{ .pos = points[0], .color = color };
        var i: usize = 1;
        while (i + 1 < points.len) : (i += 1) {
            try self.pushTriangle(anchor, .{ .pos = points[i], .color = color }, .{ .pos = points[i + 1], .color = color });
        }
    }

    pub fn pushStrokePath(self: *ImmediateScene, commands: []const window.PathCommand, style: window.StrokeStyle, color: [4]f32) !void {
        var points = try std.ArrayList([2]f32).initCapacity(self.allocator, commands.len * 4 + 8);
        defer points.deinit(self.allocator);
        try flattenPath(self.allocator, commands, &points);
        if (points.items.len < 2) return;
        if (style.dash.count > 0) {
            try self.pushDashedPolyline(points.items, style, color, pathClosed(points.items));
            return;
        }
        if (strokeQualityUsesFastSegments(style.quality)) {
            var i: usize = 0;
            while (i + 1 < points.items.len) : (i += 1) {
                _ = try self.pushLineAA(points.items[i], points.items[i + 1], style.width, color);
            }
            return;
        }
        if (style.quality == .vector) {
            try self.pushVectorPolyline(points.items, style, color, pathClosed(points.items));
            return;
        }
        try self.pushFeatheredPolyline(points.items, style.width, color, pathClosed(points.items));
    }

    pub fn pushPoint(self: *ImmediateScene, pos: [2]f32, size: f32, color: [4]f32) !void {
        const half = size * 0.5;
        try self.pushRect(.{ .x = pos[0] - half, .y = pos[1] - half, .w = size, .h = size }, color);
    }

    pub fn pushLineAA(self: *ImmediateScene, a: [2]f32, b: [2]f32, thickness: f32, color: [4]f32) !bool {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len_sq = dx * dx + dy * dy;
        if (len_sq == 0) {
            try self.pushPoint(a, thickness, color);
            return false;
        }
        if (self.line_vertices.items.len + 6 > self.max_line_vertices) return error.VertexBufferOverflow;
        const len = std.math.sqrt(len_sq);
        const tx = dx / len;
        const ty = dy / len;
        const nx = -ty;
        const ny = tx;
        const aa_edge: f32 = 0.75;
        const cap_extend: f32 = aa_edge;
        const a_ext = [2]f32{ a[0] - tx * cap_extend, a[1] - ty * cap_extend };
        const b_ext = [2]f32{ b[0] + tx * cap_extend, b[1] + ty * cap_extend };
        const half = thickness * 0.5 + aa_edge;
        const ax = a_ext[0] + nx * half;
        const ay = a_ext[1] + ny * half;
        const bx = b_ext[0] + nx * half;
        const by = b_ext[1] + ny * half;
        const cx = b_ext[0] - nx * half;
        const cy = b_ext[1] - ny * half;
        const dx2 = a_ext[0] - nx * half;
        const dy2 = a_ext[1] - ny * half;
        const v0 = window.LineVertex{ .pos = .{ ax, ay }, .color = color, .seg_a = a_ext, .seg_b = b_ext, .thickness = thickness, .side = 1.0 };
        const v1 = window.LineVertex{ .pos = .{ bx, by }, .color = color, .seg_a = a_ext, .seg_b = b_ext, .thickness = thickness, .side = 1.0 };
        const v2 = window.LineVertex{ .pos = .{ cx, cy }, .color = color, .seg_a = a_ext, .seg_b = b_ext, .thickness = thickness, .side = -1.0 };
        const v3 = window.LineVertex{ .pos = .{ dx2, dy2 }, .color = color, .seg_a = a_ext, .seg_b = b_ext, .thickness = thickness, .side = -1.0 };
        try self.line_vertices.append(self.allocator, v0);
        try self.line_vertices.append(self.allocator, v1);
        try self.line_vertices.append(self.allocator, v2);
        try self.line_vertices.append(self.allocator, v0);
        try self.line_vertices.append(self.allocator, v2);
        try self.line_vertices.append(self.allocator, v3);
        return true;
    }

    pub fn pushFeatheredPolyline(self: *ImmediateScene, points: []const [2]f32, width: f32, color: [4]f32, closed: bool) !void {
        if (points.len < 2 or width <= 0.0 or color[3] <= 0.0) return;
        const point_count = if (closed and pointsEqual(points[0], points[points.len - 1])) points.len - 1 else points.len;
        if (point_count < 2) return;

        const feather: f32 = 1.0;
        const thin_line = width <= feather;
        const alpha_scale = if (thin_line) std.math.clamp(width / feather, 0.0, 1.0) else 1.0;
        const center_color = scaleColorAlpha(color, alpha_scale);
        const outer_color = [4]f32{ color[0], color[1], color[2], 0.0 };

        const segment_count = if (closed) point_count else point_count - 1;
        var segment_index: usize = 0;
        while (segment_index < segment_count) : (segment_index += 1) {
            const start_index = segment_index;
            const end_index = (segment_index + 1) % point_count;
            const p0 = points[start_index];
            const p1 = points[end_index];
            if (!pointFinite(p0) or !pointFinite(p1) or pointsEqual(p0, p1)) continue;

            const outer0 = strokeOffsetAt(points, point_count, start_index, closed, if (thin_line) feather else (width + feather) * 0.5);
            const outer1 = strokeOffsetAt(points, point_count, end_index, closed, if (thin_line) feather else (width + feather) * 0.5);

            if (thin_line) {
                try self.pushGradientTriangle(add2(p0, outer0), outer_color, p0, center_color, add2(p1, outer1), outer_color);
                try self.pushGradientTriangle(p0, center_color, p1, center_color, add2(p1, outer1), outer_color);
                try self.pushGradientTriangle(p0, center_color, sub2(p0, outer0), outer_color, p1, center_color);
                try self.pushGradientTriangle(sub2(p0, outer0), outer_color, sub2(p1, outer1), outer_color, p1, center_color);
            } else {
                const inner0 = strokeOffsetAt(points, point_count, start_index, closed, (width - feather) * 0.5);
                const inner1 = strokeOffsetAt(points, point_count, end_index, closed, (width - feather) * 0.5);

                try self.pushQuadGradient(add2(p0, outer0), outer_color, add2(p1, outer1), outer_color, add2(p1, inner1), color, add2(p0, inner0), color);
                try self.pushQuadGradient(add2(p0, inner0), color, add2(p1, inner1), color, sub2(p1, inner1), color, sub2(p0, inner0), color);
                try self.pushQuadGradient(sub2(p0, inner0), color, sub2(p1, inner1), color, sub2(p1, outer1), outer_color, sub2(p0, outer0), outer_color);
            }
        }
    }

    pub fn pushVectorPolyline(self: *ImmediateScene, points: []const [2]f32, style: window.StrokeStyle, color: [4]f32, closed: bool) !void {
        if (points.len < 2 or style.width <= 0.0 or color[3] <= 0.0) return;
        const point_count = if (closed and pointsEqual(points[0], points[points.len - 1])) points.len - 1 else points.len;
        if (point_count < 2) return;

        const half_width = style.width * 0.5;
        const aa: f32 = 0.5;
        const segment_count = if (closed) point_count else point_count - 1;
        var segment_index: usize = 0;
        while (segment_index < segment_count) : (segment_index += 1) {
            const start_index = segment_index;
            const end_index = (segment_index + 1) % point_count;
            const p0 = points[start_index];
            const p1 = points[end_index];
            if (!pointFinite(p0) or !pointFinite(p1) or pointsEqual(p0, p1)) continue;

            var start_center = p0;
            var end_center = p1;
            const dir = normalize2(.{ p1[0] - p0[0], p1[1] - p0[1] });
            if (!closed and style.cap == .square) {
                if (start_index == 0) start_center = sub2(start_center, scale2(dir, half_width));
                if (end_index == point_count - 1) end_center = add2(end_center, scale2(dir, half_width));
            }

            const outer0 = strokeOffsetAt(points, point_count, start_index, closed, half_width + aa);
            const outer1 = strokeOffsetAt(points, point_count, end_index, closed, half_width + aa);
            const inner0 = strokeOffsetAt(points, point_count, start_index, closed, half_width);
            const inner1 = strokeOffsetAt(points, point_count, end_index, closed, half_width);

            try self.pushQuadGradient(add2(start_center, outer0), transparentColor(color), add2(end_center, outer1), transparentColor(color), add2(end_center, inner1), color, add2(start_center, inner0), color);
            try self.pushQuadGradient(add2(start_center, inner0), color, add2(end_center, inner1), color, sub2(end_center, inner1), color, sub2(start_center, inner0), color);
            try self.pushQuadGradient(sub2(start_center, inner0), color, sub2(end_center, inner1), color, sub2(end_center, outer1), transparentColor(color), sub2(start_center, outer0), transparentColor(color));
        }

        if (!closed and style.cap == .round) {
            try self.pushRoundCap(points[0], points[1], half_width, aa, color, true);
            try self.pushRoundCap(points[point_count - 1], points[point_count - 2], half_width, aa, color, false);
        }
    }

    fn pushQuadGradient(
        self: *ImmediateScene,
        p0: [2]f32,
        c0: [4]f32,
        p1: [2]f32,
        c1: [4]f32,
        p2: [2]f32,
        c2: [4]f32,
        p3: [2]f32,
        c3: [4]f32,
    ) !void {
        try self.pushGradientTriangle(p0, c0, p1, c1, p2, c2);
        try self.pushGradientTriangle(p0, c0, p2, c2, p3, c3);
    }

    fn pushGradientTriangle(
        self: *ImmediateScene,
        p0: [2]f32,
        c0: [4]f32,
        p1: [2]f32,
        c1: [4]f32,
        p2: [2]f32,
        c2: [4]f32,
    ) !void {
        try self.pushTriangle(
            .{ .pos = p0, .color = c0 },
            .{ .pos = p1, .color = c1 },
            .{ .pos = p2, .color = c2 },
        );
    }

    fn pushRoundCap(self: *ImmediateScene, center: [2]f32, neighbor: [2]f32, radius: f32, aa: f32, color: [4]f32, start_cap: bool) !void {
        if (radius <= 0.0) return;
        const dir = normalize2(.{ center[0] - neighbor[0], center[1] - neighbor[1] });
        const base_angle = std.math.atan2(dir[1], dir[0]);
        const start_angle = if (start_cap) base_angle - std.math.pi * 0.5 else base_angle + std.math.pi * 0.5;
        const sign: f32 = if (start_cap) 1.0 else -1.0;
        const segments: usize = 10;
        var prev_inner = add2(center, polar2(start_angle, radius));
        var prev_outer = add2(center, polar2(start_angle, radius + aa));
        var i: usize = 1;
        while (i <= segments) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const angle = start_angle + sign * std.math.pi * t;
            const inner = add2(center, polar2(angle, radius));
            const outer = add2(center, polar2(angle, radius + aa));
            try self.pushGradientTriangle(center, color, prev_inner, color, inner, color);
            try self.pushQuadGradient(prev_inner, color, inner, color, outer, transparentColor(color), prev_outer, transparentColor(color));
            prev_inner = inner;
            prev_outer = outer;
        }
    }

    pub fn pushImage(self: *ImmediateScene, image_id: window.ImageId, rect: window.Rect, tint: [4]f32) !void {
        _ = image_id;
        try self.pushTextQuad(rect.x, rect.y, rect.w, rect.h, .{ 0.0, 0.0 }, .{ 1.0, 1.0 }, tint);
    }

    pub fn pushText(self: *ImmediateScene, cmd: anytype, clip: ?window.Rect, provider: TextProvider) !void {
        const base_font_id = cmd.font_id orelse provider.defaultFontFn(provider.context) orelse return;
        const base_font = provider.fontMetricsFn(provider.context, base_font_id) orelse return;
        var pen_x = cmd.pos[0];
        var pen_y = cmd.pos[1];
        const line_start_x = pen_x;
        const base_scale = cmd.size / base_font.size_px;
        const line_height = (base_font.ascent - base_font.descent + base_font.line_gap) * base_scale;
        const view = std.unicode.Utf8View.initUnchecked(cmd.text);
        var it = view.iterator();
        var batch_start = self.text_vertices.items.len;
        var batch_font_id = base_font_id;
        const rotation = cmd.rotation;
        const rotate = @abs(rotation) > 0.0001;
        const cos_r = @cos(rotation);
        const sin_r = @sin(rotation);
        const origin = cmd.pos;
        while (it.nextCodepoint()) |cp| {
            if (cp == '\n') {
                pen_x = line_start_x;
                pen_y += line_height;
                continue;
            }
            const resolved = provider.resolveGlyphFn(provider.context, base_font_id, cp) orelse continue;
            if (resolved.font_id != batch_font_id and self.text_vertices.items.len > batch_start) {
                try self.recordBatch(batch_start, clip, .text, batch_font_id, null);
                batch_start = self.text_vertices.items.len;
                batch_font_id = resolved.font_id;
            }
            const font = provider.fontMetricsFn(provider.context, resolved.font_id) orelse continue;
            const scale = cmd.size / font.size_px;
            const gx = pen_x + resolved.glyph.bearing[0] * scale;
            const gy = pen_y + resolved.glyph.bearing[1] * scale;
            const gw = resolved.glyph.size[0] * scale;
            const gh = resolved.glyph.size[1] * scale;
            if (gw > 0.0 and gh > 0.0) {
                if (rotate) {
                    try self.pushTextQuadRotated(gx, gy, gw, gh, resolved.glyph.uv0, resolved.glyph.uv1, cmd.color, origin, cos_r, sin_r);
                } else {
                    try self.pushTextQuad(gx, gy, gw, gh, resolved.glyph.uv0, resolved.glyph.uv1, cmd.color);
                }
            }
            pen_x += resolved.glyph.advance * scale;
        }
        if (self.text_vertices.items.len > batch_start) {
            try self.recordBatch(batch_start, clip, .text, batch_font_id, null);
        }
    }

    pub fn pushTextQuad(self: *ImmediateScene, x: f32, y: f32, w: f32, h: f32, uv0: [2]f32, uv1: [2]f32, color: [4]f32) !void {
        if (self.text_vertices.items.len + 6 > self.max_text_vertices) return error.VertexBufferOverflow;
        const x0 = x;
        const y0 = y;
        const x1 = x + w;
        const y1 = y + h;
        const v0 = window.TextVertex{ .pos = .{ x0, y0 }, .uv = .{ uv0[0], uv0[1] }, .color = color };
        const v1 = window.TextVertex{ .pos = .{ x1, y0 }, .uv = .{ uv1[0], uv0[1] }, .color = color };
        const v2 = window.TextVertex{ .pos = .{ x1, y1 }, .uv = .{ uv1[0], uv1[1] }, .color = color };
        const v3 = window.TextVertex{ .pos = .{ x0, y1 }, .uv = .{ uv0[0], uv1[1] }, .color = color };
        try self.text_vertices.append(self.allocator, v0);
        try self.text_vertices.append(self.allocator, v1);
        try self.text_vertices.append(self.allocator, v2);
        try self.text_vertices.append(self.allocator, v0);
        try self.text_vertices.append(self.allocator, v2);
        try self.text_vertices.append(self.allocator, v3);
    }

    pub fn pushTextQuadRotated(self: *ImmediateScene, x: f32, y: f32, w: f32, h: f32, uv0: [2]f32, uv1: [2]f32, color: [4]f32, origin: [2]f32, cos_r: f32, sin_r: f32) !void {
        if (self.text_vertices.items.len + 6 > self.max_text_vertices) return error.VertexBufferOverflow;
        const p0 = rotateTextPoint(.{ x, y }, origin, cos_r, sin_r);
        const p1 = rotateTextPoint(.{ x + w, y }, origin, cos_r, sin_r);
        const p2 = rotateTextPoint(.{ x + w, y + h }, origin, cos_r, sin_r);
        const p3 = rotateTextPoint(.{ x, y + h }, origin, cos_r, sin_r);
        const v0 = window.TextVertex{ .pos = p0, .uv = .{ uv0[0], uv0[1] }, .color = color };
        const v1 = window.TextVertex{ .pos = p1, .uv = .{ uv1[0], uv0[1] }, .color = color };
        const v2 = window.TextVertex{ .pos = p2, .uv = .{ uv1[0], uv1[1] }, .color = color };
        const v3 = window.TextVertex{ .pos = p3, .uv = .{ uv0[0], uv1[1] }, .color = color };
        try self.text_vertices.append(self.allocator, v0);
        try self.text_vertices.append(self.allocator, v1);
        try self.text_vertices.append(self.allocator, v2);
        try self.text_vertices.append(self.allocator, v0);
        try self.text_vertices.append(self.allocator, v2);
        try self.text_vertices.append(self.allocator, v3);
    }

    fn rotateTextPoint(point: [2]f32, origin: [2]f32, cos_r: f32, sin_r: f32) [2]f32 {
        const dx = point[0] - origin[0];
        const dy = point[1] - origin[1];
        return .{
            origin[0] + dx * cos_r - dy * sin_r,
            origin[1] + dx * sin_r + dy * cos_r,
        };
    }

    pub fn recordBatch(self: *ImmediateScene, start: usize, clip: ?window.Rect, kind: BatchKind, font_id: ?window.TextFontId, image_id: ?window.ImageId) !void {
        const end_len = switch (kind) {
            .shape => self.vertices.items.len,
            .paint_quad => self.paint_quad_vertices.items.len,
            .text, .image => self.text_vertices.items.len,
            .line_aa => self.line_vertices.items.len,
        };
        const count = end_len - start;
        if (count == 0) return;
        self.addOrAppendBatch(@intCast(start), @intCast(count), clip, kind, font_id, image_id) catch |err| return err;
    }

    pub fn addBatch(self: *ImmediateScene, first: u32, count: u32, clip: ?window.Rect, kind: BatchKind, font_id: ?window.TextFontId, image_id: ?window.ImageId) void {
        if (count == 0) return;
        _ = self.addOrAppendBatch(first, count, clip, kind, font_id, image_id) catch {};
    }

    fn addOrAppendBatch(self: *ImmediateScene, first: u32, count: u32, clip: ?window.Rect, kind: BatchKind, font_id: ?window.TextFontId, image_id: ?window.ImageId) !void {
        if (self.batches.items.len > 0) {
            var last = &self.batches.items[self.batches.items.len - 1];
            if (last.kind == kind and last.font_id == font_id and last.image_id == image_id and clipEqual(last.clip, clip) and last.first + last.count == first) {
                last.count += count;
                return;
            }
        }
        try self.batches.append(self.allocator, .{ .kind = kind, .first = first, .count = count, .clip = clip, .font_id = font_id, .image_id = image_id });
    }

    fn pushBatchedLine(self: *ImmediateScene, a: [2]f32, b: [2]f32, thickness: f32, color: [4]f32, clip: ?window.Rect) !void {
        try self.pushBatchedStyledLine(a, b, .{ .width = thickness }, color, clip);
    }

    fn pushBatchedStyledLine(self: *ImmediateScene, a: [2]f32, b: [2]f32, style: window.StrokeStyle, color: [4]f32, clip: ?window.Rect) !void {
        if (style.dash.count > 0) {
            const points = [_][2]f32{ a, b };
            const shape_start = self.vertices.items.len;
            const line_start = self.line_vertices.items.len;
            try self.pushDashedPolyline(&points, style, color, false);
            if (self.vertices.items.len > shape_start) try self.recordBatch(shape_start, clip, .shape, null, null);
            if (self.line_vertices.items.len > line_start) try self.recordBatch(line_start, clip, .line_aa, null, null);
            return;
        }
        if (style.quality == .vector and style.dash.count == 0) {
            const points = [_][2]f32{ a, b };
            const start = self.vertices.items.len;
            try self.pushVectorPolyline(&points, style, color, false);
            try self.recordBatch(start, clip, .shape, null, null);
            return;
        }
        if (!strokeQualityUsesFastSegments(style.quality) and style.dash.count == 0) {
            const points = [_][2]f32{ a, b };
            const start = self.vertices.items.len;
            try self.pushFeatheredPolyline(&points, style.width, color, false);
            try self.recordBatch(start, clip, .shape, null, null);
            return;
        }

        const start = self.line_vertices.items.len;
        if (try self.pushLineAA(a, b, style.width, color)) {
            try self.recordBatch(start, clip, .line_aa, null, null);
        } else {
            try self.recordBatch(self.vertices.items.len - 6, clip, .shape, null, null);
        }
    }

    fn pushBatchedPolyline(self: *ImmediateScene, points: []const [2]f32, style: window.StrokeStyle, color: [4]f32, clip: ?window.Rect) !void {
        if (points.len < 2) return;
        if (style.dash.count > 0) {
            const shape_start = self.vertices.items.len;
            const line_start = self.line_vertices.items.len;
            try self.pushDashedPolyline(points, style, color, false);
            if (self.vertices.items.len > shape_start) try self.recordBatch(shape_start, clip, .shape, null, null);
            if (self.line_vertices.items.len > line_start) try self.recordBatch(line_start, clip, .line_aa, null, null);
            return;
        }
        if (style.quality == .vector and style.dash.count == 0) {
            const start = self.vertices.items.len;
            try self.pushVectorPolyline(points, style, color, false);
            try self.recordBatch(start, clip, .shape, null, null);
            return;
        }
        if (!strokeQualityUsesFastSegments(style.quality) and style.dash.count == 0) {
            const start = self.vertices.items.len;
            try self.pushFeatheredPolyline(points, style.width, color, false);
            try self.recordBatch(start, clip, .shape, null, null);
            return;
        }

        const start = self.line_vertices.items.len;
        var shape_start: ?usize = null;
        var i: usize = 0;
        while (i + 1 < points.len) : (i += 1) {
            if (!(try self.pushLineAA(points[i], points[i + 1], style.width, color)) and shape_start == null) {
                shape_start = self.vertices.items.len - 6;
            }
        }
        try self.recordBatch(start, clip, .line_aa, null, null);
        if (shape_start) |fallback_start| try self.recordBatch(fallback_start, clip, .shape, null, null);
    }

    fn pushDashedPolyline(self: *ImmediateScene, points: []const [2]f32, style: window.StrokeStyle, color: [4]f32, closed: bool) !void {
        if (points.len < 2 or style.dash.count == 0) return;
        const point_count = if (closed and pointsEqual(points[0], points[points.len - 1])) points.len - 1 else points.len;
        if (point_count < 2) return;
        var dash_state = DashState.init(style.dash);
        const segment_count = if (closed) point_count else point_count - 1;
        var segment_index: usize = 0;
        while (segment_index < segment_count) : (segment_index += 1) {
            const a = points[segment_index];
            const b = points[(segment_index + 1) % point_count];
            if (!pointFinite(a) or !pointFinite(b) or pointsEqual(a, b)) continue;
            const dx = b[0] - a[0];
            const dy = b[1] - a[1];
            const len = @sqrt(dx * dx + dy * dy);
            if (len <= 0.000001) continue;
            const dir = [2]f32{ dx / len, dy / len };
            var consumed: f32 = 0.0;
            while (consumed < len - 0.0001) {
                const step = @min(dash_state.remaining, len - consumed);
                if (dash_state.on and step > 0.0001) {
                    const p0 = add2(a, scale2(dir, consumed));
                    const p1 = add2(a, scale2(dir, consumed + step));
                    if (strokeQualityUsesFastSegments(style.quality)) {
                        _ = try self.pushLineAA(p0, p1, style.width, color);
                    } else {
                        const dash_points = [_][2]f32{ p0, p1 };
                        if (style.quality == .vector) {
                            try self.pushVectorPolyline(&dash_points, style, color, false);
                        } else {
                            try self.pushFeatheredPolyline(&dash_points, style.width, color, false);
                        }
                    }
                }
                consumed += step;
                dash_state.advance(step);
            }
        }
    }
};

const ImmediateSceneSink = struct {
    scene: *ImmediateScene,
    text_provider: TextProvider,

    pub fn fillPath(self: *ImmediateSceneSink, p: window.FillPath, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushFillPath(p.path.commands, p.color);
        if (self.scene.vertices.items.len > start) try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn strokePath(self: *ImmediateSceneSink, p: window.StrokePath, clip: ?window.Rect) !void {
        const shape_start = self.scene.vertices.items.len;
        const start = self.scene.line_vertices.items.len;
        try self.scene.pushStrokePath(p.path.commands, p.style, p.color);
        if (self.scene.vertices.items.len > shape_start) try self.scene.recordBatch(shape_start, clip, .shape, null, null);
        if (self.scene.line_vertices.items.len > start) try self.scene.recordBatch(start, clip, .line_aa, null, null);
    }

    pub fn rect(self: *ImmediateSceneSink, r: anytype, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushRect(r.rect, r.color);
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn roundedRect(self: *ImmediateSceneSink, r: window.RoundedRect, clip: ?window.Rect) !void {
        const start = self.scene.paint_quad_vertices.items.len;
        try self.scene.pushPaintQuad(.{ .rect = r.rect, .radius = r.radius, .background = r.color, .border_width = 0.0, .border_color = .{ 0.0, 0.0, 0.0, 0.0 }, .layer = r.layer });
        if (self.scene.paint_quad_vertices.items.len > start) try self.scene.recordBatch(start, clip, .paint_quad, null, null);
    }

    pub fn strokeRoundedRect(self: *ImmediateSceneSink, r: window.StrokeRoundedRect, clip: ?window.Rect) !void {
        const start = self.scene.paint_quad_vertices.items.len;
        try self.scene.pushPaintQuad(.{ .rect = r.rect, .radius = r.radius, .background = .{ 0.0, 0.0, 0.0, 0.0 }, .border_width = r.thickness, .border_color = r.color, .layer = r.layer });
        if (self.scene.paint_quad_vertices.items.len > start) try self.scene.recordBatch(start, clip, .paint_quad, null, null);
    }

    pub fn paintQuad(self: *ImmediateSceneSink, q: window.PaintQuad, clip: ?window.Rect) !void {
        const start = self.scene.paint_quad_vertices.items.len;
        try self.scene.pushPaintQuad(q);
        if (self.scene.paint_quad_vertices.items.len > start) try self.scene.recordBatch(start, clip, .paint_quad, null, null);
    }

    pub fn triangle(self: *ImmediateSceneSink, t: window.Triangle, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushTriangle(.{ .pos = t.points[0], .color = t.color }, .{ .pos = t.points[1], .color = t.color }, .{ .pos = t.points[2], .color = t.color });
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn linearGradientRect(self: *ImmediateSceneSink, g: window.LinearGradientRect, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushLinearGradientRect(g);
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn radialGradientRect(self: *ImmediateSceneSink, g: window.RadialGradientRect, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushRadialGradientRect(g);
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn sweepGradientRect(self: *ImmediateSceneSink, g: window.SweepGradientRect, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushSweepGradientRect(g);
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn ellipse(self: *ImmediateSceneSink, e: window.Ellipse, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushEllipse(e.center, e.radius, e.color);
        if (self.scene.vertices.items.len > start) try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn strokeEllipse(self: *ImmediateSceneSink, e: window.StrokeEllipse, clip: ?window.Rect) !void {
        const shape_start = self.scene.vertices.items.len;
        const start = self.scene.line_vertices.items.len;
        try self.scene.pushStrokeEllipse(e.center, e.radius, e.thickness, e.color);
        if (self.scene.vertices.items.len > shape_start) try self.scene.recordBatch(shape_start, clip, .shape, null, null);
        if (self.scene.line_vertices.items.len > start) try self.scene.recordBatch(start, clip, .line_aa, null, null);
    }

    pub fn line(self: *ImmediateSceneSink, l: anytype, clip: ?window.Rect) !void {
        try self.scene.pushBatchedLine(l.a, l.b, l.thickness, l.color, clip);
    }

    pub fn styledLine(self: *ImmediateSceneSink, l: window.StyledLine, clip: ?window.Rect) !void {
        try self.scene.pushBatchedStyledLine(l.a, l.b, l.style, l.color, clip);
    }

    pub fn point(self: *ImmediateSceneSink, p: anytype, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        try self.scene.pushPoint(p.pos, p.size, p.color);
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn polyline(self: *ImmediateSceneSink, p: anytype, clip: ?window.Rect) !void {
        try self.scene.pushBatchedPolyline(p.points, .{ .width = p.thickness }, p.color, clip);
    }

    pub fn styledPolyline(self: *ImmediateSceneSink, p: window.StyledPolyline, clip: ?window.Rect) !void {
        try self.scene.pushBatchedPolyline(p.points, p.style, p.color, clip);
    }

    pub fn bars(self: *ImmediateSceneSink, b: anytype, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        if (b.values.len == 0) return;
        for (b.values, 0..) |val, i| {
            const x = b.origin[0] + @as(f32, @floatFromInt(i)) * b.bar_width;
            try self.scene.pushRect(.{ .x = x, .y = b.origin[1] + b.base, .w = b.bar_width, .h = val }, b.color);
        }
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn scatter(self: *ImmediateSceneSink, s: anytype, clip: ?window.Rect) !void {
        const start = self.scene.vertices.items.len;
        for (s.points) |p| try self.scene.pushCircle(p, s.size * 0.5, s.color);
        try self.scene.recordBatch(start, clip, .shape, null, null);
    }

    pub fn image(self: *ImmediateSceneSink, i: anytype, clip: ?window.Rect) !void {
        const start = self.scene.text_vertices.items.len;
        try self.scene.pushImage(i.image_id, i.rect, i.tint);
        if (self.scene.text_vertices.items.len > start) try self.scene.recordBatch(start, clip, .image, null, i.image_id);
    }

    pub fn text(self: *ImmediateSceneSink, t: anytype, clip: ?window.Rect) !void {
        try self.scene.pushText(t, clip, self.text_provider);
    }
};

pub const GpuImmediateRenderer = struct {
    vertex_buffer: backend.BufferHandle,
    paint_quad_vertex_buffer: backend.BufferHandle,
    text_vertex_buffer: backend.BufferHandle,
    line_vertex_buffer: backend.BufferHandle,
    uniform_buffer: backend.BufferHandle,
    uniform_bind_group: backend.BindGroupHandle,
    shape_pipeline: backend.RenderPipelineHandle,
    paint_quad_pipeline: backend.RenderPipelineHandle,
    text_pipeline: backend.RenderPipelineHandle,
    image_pipeline: backend.RenderPipelineHandle,
    line_pipeline: backend.RenderPipelineHandle,
    texture_bind_group_layout: backend.BindGroupLayoutHandle,
    encoder: ?wgpu.CommandEncoder = null,
    swap_view: ?wgpu.TextureView = null,
    max_vertices: u32,
    max_paint_quad_vertices: u32,
    max_text_vertices: u32,
    max_line_vertices: u32,

    pub fn init(
        gctx: *backend.RenderContext,
        max_vertices: u32,
        max_paint_quad_vertices: u32,
        max_text_vertices: u32,
        max_line_vertices: u32,
    ) !GpuImmediateRenderer {
        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @as(u64, max_vertices) * @sizeOf(window.Vertex),
        });
        errdefer gctx.destroyResource(vertex_buffer);

        const paint_quad_vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @as(u64, max_paint_quad_vertices) * @sizeOf(window.PaintQuadVertex),
        });
        errdefer gctx.destroyResource(paint_quad_vertex_buffer);

        const text_vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @as(u64, max_text_vertices) * @sizeOf(window.TextVertex),
        });
        errdefer gctx.destroyResource(text_vertex_buffer);

        const line_vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @as(u64, max_line_vertices) * @sizeOf(window.LineVertex),
        });
        errdefer gctx.destroyResource(line_vertex_buffer);

        const uniform_buffer = gctx.createBuffer(.{
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = 256,
        });
        errdefer gctx.destroyResource(uniform_buffer);

        const uniform_bind_group_layout = gctx.createBindGroupLayout(&.{
            .{
                .binding = 0,
                .visibility = .{ .vertex = true },
                .buffer = .{ .binding_type = .uniform, .min_binding_size = 8 },
            },
        });

        const uniform_bind_group = gctx.createBindGroup(uniform_bind_group_layout, &.{
            .{ .binding = 0, .buffer_handle = uniform_buffer, .offset = 0, .size = 8 },
        });
        errdefer gctx.releaseResource(uniform_bind_group);

        const texture_bind_group_layout = gctx.createBindGroupLayout(&.{
            .{
                .binding = 0,
                .visibility = .{ .fragment = true },
                .sampler = .{ .binding_type = .filtering },
            },
            .{
                .binding = 1,
                .visibility = .{ .fragment = true },
                .texture = .{ .sample_type = .float, .view_dimension = .tvdim_2d, .multisampled = false },
            },
        });

        const shape_pipeline_layout = gctx.createPipelineLayout(&.{uniform_bind_group_layout});
        const texture_pipeline_layout = gctx.createPipelineLayout(&.{ uniform_bind_group_layout, texture_bind_group_layout });

        const shape_pipeline = try createShapePipeline(gctx, shape_pipeline_layout);
        const paint_quad_pipeline = try createPaintQuadPipeline(gctx, shape_pipeline_layout);
        const text_pipeline = try createTextPipeline(gctx, texture_pipeline_layout);
        const image_pipeline = try createImagePipeline(gctx, texture_pipeline_layout);
        const line_pipeline = try createLinePipeline(gctx, shape_pipeline_layout);

        return .{
            .vertex_buffer = vertex_buffer,
            .paint_quad_vertex_buffer = paint_quad_vertex_buffer,
            .text_vertex_buffer = text_vertex_buffer,
            .line_vertex_buffer = line_vertex_buffer,
            .uniform_buffer = uniform_buffer,
            .uniform_bind_group = uniform_bind_group,
            .shape_pipeline = shape_pipeline,
            .paint_quad_pipeline = paint_quad_pipeline,
            .text_pipeline = text_pipeline,
            .image_pipeline = image_pipeline,
            .line_pipeline = line_pipeline,
            .texture_bind_group_layout = texture_bind_group_layout,
            .max_vertices = max_vertices,
            .max_paint_quad_vertices = max_paint_quad_vertices,
            .max_text_vertices = max_text_vertices,
            .max_line_vertices = max_line_vertices,
        };
    }

    pub fn deinit(self: *GpuImmediateRenderer, gctx: *backend.RenderContext) void {
        if (self.swap_view) |view| view.release();
        if (self.encoder) |encoder| encoder.release();
        gctx.destroyResource(self.vertex_buffer);
        gctx.destroyResource(self.paint_quad_vertex_buffer);
        gctx.destroyResource(self.text_vertex_buffer);
        gctx.destroyResource(self.line_vertex_buffer);
        gctx.destroyResource(self.uniform_buffer);
        gctx.releaseResource(self.uniform_bind_group);
        self.* = undefined;
    }

    pub fn beginFrame(self: *GpuImmediateRenderer, gctx: *backend.RenderContext, logical_size: [2]u32) bool {
        if (!gctx.canRender()) return false;
        _ = backend.syncSwapchainToWindow(gctx);
        const screen_size = [2]f32{ @floatFromInt(logical_size[0]), @floatFromInt(logical_size[1]) };
        const ubuf = gctx.lookupResource(self.uniform_buffer) orelse return false;
        gctx.queue.writeBuffer(ubuf, 0, f32, screen_size[0..]);
        self.encoder = gctx.device.createCommandEncoder(null);
        self.swap_view = gctx.swapchain.getCurrentTextureView();
        return true;
    }

    pub fn endFrame(
        self: *GpuImmediateRenderer,
        gctx: *backend.RenderContext,
        vertices: []const window.Vertex,
        paint_quad_vertices: []const window.PaintQuadVertex,
        text_vertices: []const window.TextVertex,
        line_vertices: []const window.LineVertex,
        batches: []const Batch,
        framebuffer_size: [2]u32,
        scale_factor: f32,
        texture_context: *anyopaque,
        resolve_texture: ResolveBatchTextureFn,
    ) void {
        const encoder = self.encoder orelse return;
        const view = self.swap_view orelse return;
        const vbuf = gctx.lookupResource(self.vertex_buffer).?;
        if (vertices.len > 0) {
            encoder.writeBuffer(vbuf, 0, window.Vertex, vertices);
        }
        const pqbuf = gctx.lookupResource(self.paint_quad_vertex_buffer).?;
        if (paint_quad_vertices.len > 0) {
            encoder.writeBuffer(pqbuf, 0, window.PaintQuadVertex, paint_quad_vertices);
        }
        const tbuf = gctx.lookupResource(self.text_vertex_buffer).?;
        if (text_vertices.len > 0) {
            encoder.writeBuffer(tbuf, 0, window.TextVertex, text_vertices);
        }
        const lbuf = gctx.lookupResource(self.line_vertex_buffer).?;
        if (line_vertices.len > 0) {
            encoder.writeBuffer(lbuf, 0, window.LineVertex, line_vertices);
        }

        const pass = backend.beginRenderPassSimple(
            encoder,
            .clear,
            view,
            .{ .r = 0.08, .g = 0.1, .b = 0.13, .a = 1.0 },
            null,
            null,
        );
        if (batches.len > 0) {
            const shape_pipeline = gctx.lookupResource(self.shape_pipeline).?;
            const paint_quad_pipeline = gctx.lookupResource(self.paint_quad_pipeline).?;
            const text_pipeline = gctx.lookupResource(self.text_pipeline).?;
            const image_pipeline = gctx.lookupResource(self.image_pipeline).?;
            const line_pipeline = gctx.lookupResource(self.line_pipeline).?;
            const shape_size: u64 = @intCast(@sizeOf(window.Vertex) * vertices.len);
            const paint_quad_size: u64 = @intCast(@sizeOf(window.PaintQuadVertex) * paint_quad_vertices.len);
            const text_size: u64 = @intCast(@sizeOf(window.TextVertex) * text_vertices.len);
            const line_size: u64 = @intCast(@sizeOf(window.LineVertex) * line_vertices.len);
            const uniform_bg = gctx.lookupResource(self.uniform_bind_group).?;
            var last_clip: ?window.Rect = null;
            var current_kind: ?BatchKind = null;
            var current_font: ?window.TextFontId = null;
            var current_image: ?window.ImageId = null;
            for (batches) |batch| {
                if (!clipEqual(last_clip, batch.clip)) {
                    const scissor = rectToScissorScaled(batch.clip, framebuffer_size[0], framebuffer_size[1], scale_factor);
                    pass.setScissorRect(scissor.x, scissor.y, scissor.w, scissor.h);
                    last_clip = batch.clip;
                }
                if (current_kind != batch.kind) {
                    current_kind = batch.kind;
                    current_font = null;
                    current_image = null;
                    switch (batch.kind) {
                        .shape => {
                            pass.setPipeline(shape_pipeline);
                            pass.setVertexBuffer(0, vbuf, 0, shape_size);
                            pass.setBindGroup(0, uniform_bg, &.{});
                        },
                        .paint_quad => {
                            pass.setPipeline(paint_quad_pipeline);
                            pass.setVertexBuffer(0, pqbuf, 0, paint_quad_size);
                            pass.setBindGroup(0, uniform_bg, &.{});
                        },
                        .text => {
                            pass.setPipeline(text_pipeline);
                            pass.setVertexBuffer(0, tbuf, 0, text_size);
                            pass.setBindGroup(0, uniform_bg, &.{});
                        },
                        .image => {
                            pass.setPipeline(image_pipeline);
                            pass.setVertexBuffer(0, tbuf, 0, text_size);
                            pass.setBindGroup(0, uniform_bg, &.{});
                        },
                        .line_aa => {
                            pass.setPipeline(line_pipeline);
                            pass.setVertexBuffer(0, lbuf, 0, line_size);
                            pass.setBindGroup(0, uniform_bg, &.{});
                        },
                    }
                }
                switch (batch.kind) {
                    .text => {
                        if (batch.font_id) |font_id| {
                            if (current_font == null or current_font.? != font_id) {
                                current_font = font_id;
                                if (resolve_texture(texture_context, batch)) |texture| {
                                    const bind_group = gctx.lookupResource(texture.bind_group).?;
                                    pass.setBindGroup(1, bind_group, &.{});
                                }
                            }
                        }
                    },
                    .image => {
                        if (batch.image_id) |image_id| {
                            if (current_image == null or current_image.? != image_id) {
                                current_image = image_id;
                                if (resolve_texture(texture_context, batch)) |texture| {
                                    const bind_group = gctx.lookupResource(texture.bind_group).?;
                                    pass.setBindGroup(1, bind_group, &.{});
                                }
                            }
                        }
                    },
                    else => {},
                }
                pass.draw(batch.count, 1, batch.first, 0);
            }
        }
        backend.endReleasePass(pass);

        const cmd = encoder.finish(null);
        gctx.submit(&.{cmd});
        cmd.release();
        encoder.release();
        view.release();

        _ = gctx.present();
        self.encoder = null;
        self.swap_view = null;
    }
};

pub fn createTextureResource(
    gctx: *backend.RenderContext,
    layout: backend.BindGroupLayoutHandle,
    width: u32,
    height: u32,
    kind: TextureKind,
) TextureResource {
    if (!backend.compiled_with_zgpu) @compileError("createTextureResource requires -Denable-zgpu-backend=true");
    const texture = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        .format = switch (kind) {
            .rgba => .rgba8_unorm,
            .alpha => .r8_unorm,
        },
        .mip_level_count = 1,
        .sample_count = 1,
        .dimension = .tdim_2d,
    });
    const view = gctx.createTextureView(texture, .{});
    const sampler = gctx.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
    });
    const bind_group = gctx.createBindGroup(layout, &.{
        .{ .binding = 0, .sampler_handle = sampler },
        .{ .binding = 1, .texture_view_handle = view },
    });
    return .{
        .width = width,
        .height = height,
        .texture = texture,
        .view = view,
        .sampler = sampler,
        .bind_group = bind_group,
    };
}

pub fn destroyTextureResource(gctx: *backend.RenderContext, texture: *TextureResource) void {
    if (!backend.compiled_with_zgpu) @compileError("destroyTextureResource requires -Denable-zgpu-backend=true");
    gctx.releaseResource(texture.bind_group);
    gctx.releaseResource(texture.sampler);
    gctx.releaseResource(texture.view);
    gctx.destroyResource(texture.texture);
}

pub fn uploadRgbaPixels(allocator: std.mem.Allocator, gctx: *backend.RenderContext, texture_resource: TextureResource, rgba_pixels: []const u8) !void {
    if (!backend.compiled_with_zgpu) @compileError("uploadRgbaPixels requires -Denable-zgpu-backend=true");
    const src_stride = texture_resource.width * 4;
    const dst_stride = alignUpU32(src_stride, 256);
    const upload_pixels = if (dst_stride == src_stride)
        rgba_pixels
    else
        try padTextureRows(allocator, rgba_pixels, texture_resource.width, texture_resource.height, src_stride, dst_stride);
    defer if (dst_stride != src_stride) allocator.free(upload_pixels);

    uploadTextureBytes(gctx, texture_resource, upload_pixels, dst_stride, texture_resource.height, 0, 0, texture_resource.width, texture_resource.height);
}

pub fn uploadAlphaAtlas(
    gctx: *backend.RenderContext,
    texture_resource: TextureResource,
    atlas_pixels: []const u8,
    atlas_width: u32,
    atlas_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) void {
    if (!backend.compiled_with_zgpu) @compileError("uploadAlphaAtlas requires -Denable-zgpu-backend=true");
    uploadTextureBytes(gctx, texture_resource, atlas_pixels, atlas_width, atlas_height, x, y, width, height);
}

fn uploadTextureBytes(
    gctx: *backend.RenderContext,
    texture_resource: TextureResource,
    pixels: []const u8,
    bytes_per_row: u32,
    rows_per_image: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) void {
    if (!backend.compiled_with_zgpu) @compileError("uploadTextureBytes requires -Denable-zgpu-backend=true");
    const texture = gctx.lookupResource(texture_resource.texture).?;
    const copy = wgpu.ImageCopyTexture{
        .texture = texture,
        .mip_level = 0,
        .origin = .{ .x = x, .y = y, .z = 0 },
        .aspect = .all,
    };
    const layout = wgpu.TextureDataLayout{
        .bytes_per_row = bytes_per_row,
        .rows_per_image = rows_per_image,
        .offset = 0,
    };
    const extent = wgpu.Extent3D{ .width = width, .height = height, .depth_or_array_layers = 1 };
    gctx.queue.writeTexture(copy, layout, extent, u8, pixels);
}

fn createShapePipeline(gctx: *backend.RenderContext, pipeline_layout: backend.PipelineLayoutHandle) !backend.RenderPipelineHandle {
    const shader_src: [:0]const u8 =
        \\struct Uniforms {
        \\    screen_size: vec2<f32>,
        \\};
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\struct VSIn {
        \\    @location(0) pos: vec2<f32>,
        \\    @location(1) color: vec4<f32>,
        \\};
        \\struct VSOut {
        \\    @builtin(position) position: vec4<f32>,
        \\    @location(0) color: vec4<f32>,
        \\};
        \\@vertex
        \\fn vs_main(in: VSIn) -> VSOut {
        \\    var out: VSOut;
        \\    let ndc_x = (in.pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
        \\    let ndc_y = 1.0 - (in.pos.y / uniforms.screen_size.y) * 2.0;
        \\    out.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
        \\    out.color = in.color;
        \\    return out;
        \\}
        \\@fragment
        \\fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
        \\    return in.color;
        \\}
    ;
    const shader_module = backend.createWgslShaderModule(gctx.device, shader_src, null);
    defer shader_module.release();

    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(window.Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x4, .offset = @offsetOf(window.Vertex, "color"), .shader_location = 1 },
    };
    const vertex_layout = wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(window.Vertex),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };
    const vertex_layouts = [_]wgpu.VertexBufferLayout{vertex_layout};
    const color_targets = [_]wgpu.ColorTargetState{blendColorTarget()};
    return gctx.createRenderPipeline(pipeline_layout, .{
        .vertex = .{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &vertex_layouts,
        },
        .fragment = &wgpu.FragmentState{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
        .primitive = .{},
    });
}

fn createPaintQuadPipeline(gctx: *backend.RenderContext, pipeline_layout: backend.PipelineLayoutHandle) !backend.RenderPipelineHandle {
    const shader_src: [:0]const u8 =
        \\struct Uniforms {
        \\    screen_size: vec2<f32>,
        \\};
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\struct VSIn {
        \\    @location(0) pos: vec2<f32>,
        \\    @location(1) rect_origin: vec2<f32>,
        \\    @location(2) rect_size: vec2<f32>,
        \\    @location(3) radius: f32,
        \\    @location(4) background: vec4<f32>,
        \\    @location(5) border_color: vec4<f32>,
        \\    @location(6) border_width: f32,
        \\};
        \\struct VSOut {
        \\    @builtin(position) position: vec4<f32>,
        \\    @location(0) logical_pos: vec2<f32>,
        \\    @location(1) rect_origin: vec2<f32>,
        \\    @location(2) rect_size: vec2<f32>,
        \\    @location(3) radius: f32,
        \\    @location(4) background: vec4<f32>,
        \\    @location(5) border_color: vec4<f32>,
        \\    @location(6) border_width: f32,
        \\};
        \\@vertex
        \\fn vs_main(in: VSIn) -> VSOut {
        \\    var out: VSOut;
        \\    let ndc_x = (in.pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
        \\    let ndc_y = 1.0 - (in.pos.y / uniforms.screen_size.y) * 2.0;
        \\    out.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
        \\    out.logical_pos = in.pos;
        \\    out.rect_origin = in.rect_origin;
        \\    out.rect_size = in.rect_size;
        \\    out.radius = in.radius;
        \\    out.background = in.background;
        \\    out.border_color = in.border_color;
        \\    out.border_width = in.border_width;
        \\    return out;
        \\}
        \\fn rounded_rect_sdf(p: vec2<f32>, origin: vec2<f32>, size: vec2<f32>, radius: f32) -> f32 {
        \\    let half_size = size * 0.5;
        \\    let center = origin + half_size;
        \\    let q = abs(p - center) - (half_size - vec2<f32>(radius, radius));
        \\    return length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - radius;
        \\}
        \\@fragment
        \\fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
        \\    let outer_d = rounded_rect_sdf(in.logical_pos, in.rect_origin, in.rect_size, in.radius);
        \\    let aa = max(fwidth(outer_d), 0.75);
        \\    let outer_alpha = 1.0 - smoothstep(-aa, aa, outer_d);
        \\    if (outer_alpha <= 0.0) {
        \\        discard;
        \\    }
        \\    let bw = max(in.border_width, 0.0);
        \\    if (bw <= 0.0 || in.border_color.a <= 0.0) {
        \\        return vec4<f32>(in.background.rgb, in.background.a * outer_alpha);
        \\    }
        \\    let inner_sdf = -(outer_d + bw);
        \\    let border_sdf = max(inner_sdf, outer_d);
        \\    var color = in.background;
        \\    if (border_sdf < aa) {
        \\        let out_a = in.border_color.a + in.background.a * (1.0 - in.border_color.a);
        \\        let out_rgb = (in.border_color.rgb * in.border_color.a + in.background.rgb * in.background.a * (1.0 - in.border_color.a)) / max(out_a, 0.0001);
        \\        let blended_border = vec4<f32>(out_rgb, out_a);
        \\        color = mix(in.background, blended_border, 1.0 - smoothstep(-aa, aa, inner_sdf));
        \\    }
        \\    return vec4<f32>(color.rgb, color.a * outer_alpha);
        \\}
    ;
    const shader_module = backend.createWgslShaderModule(gctx.device, shader_src, null);
    defer shader_module.release();
    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(window.PaintQuadVertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(window.PaintQuadVertex, "rect_origin"), .shader_location = 1 },
        .{ .format = .float32x2, .offset = @offsetOf(window.PaintQuadVertex, "rect_size"), .shader_location = 2 },
        .{ .format = .float32, .offset = @offsetOf(window.PaintQuadVertex, "radius"), .shader_location = 3 },
        .{ .format = .float32x4, .offset = @offsetOf(window.PaintQuadVertex, "background"), .shader_location = 4 },
        .{ .format = .float32x4, .offset = @offsetOf(window.PaintQuadVertex, "border_color"), .shader_location = 5 },
        .{ .format = .float32, .offset = @offsetOf(window.PaintQuadVertex, "border_width"), .shader_location = 6 },
    };
    const vertex_layout = wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(window.PaintQuadVertex),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };
    const vertex_layouts = [_]wgpu.VertexBufferLayout{vertex_layout};
    const color_targets = [_]wgpu.ColorTargetState{blendColorTarget()};
    return gctx.createRenderPipeline(pipeline_layout, .{
        .vertex = .{ .module = shader_module, .entry_point = "vs_main", .buffer_count = 1, .buffers = &vertex_layouts },
        .fragment = &wgpu.FragmentState{ .module = shader_module, .entry_point = "fs_main", .target_count = color_targets.len, .targets = &color_targets },
        .primitive = .{},
    });
}

fn createTextPipeline(gctx: *backend.RenderContext, pipeline_layout: backend.PipelineLayoutHandle) !backend.RenderPipelineHandle {
    const shader_src: [:0]const u8 =
        \\struct Uniforms {
        \\    screen_size: vec2<f32>,
        \\};
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\struct VSIn {
        \\    @location(0) pos: vec2<f32>,
        \\    @location(1) uv: vec2<f32>,
        \\    @location(2) color: vec4<f32>,
        \\};
        \\struct VSOut {
        \\    @builtin(position) position: vec4<f32>,
        \\    @location(0) uv: vec2<f32>,
        \\    @location(1) color: vec4<f32>,
        \\};
        \\@vertex
        \\fn vs_main(in: VSIn) -> VSOut {
        \\    var out: VSOut;
        \\    let ndc_x = (in.pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
        \\    let ndc_y = 1.0 - (in.pos.y / uniforms.screen_size.y) * 2.0;
        \\    out.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
        \\    out.uv = in.uv;
        \\    out.color = in.color;
        \\    return out;
        \\}
        \\@group(1) @binding(0) var font_sampler: sampler;
        \\@group(1) @binding(1) var font_tex: texture_2d<f32>;
        \\@fragment
        \\fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
        \\    let a = textureSample(font_tex, font_sampler, in.uv).r;
        \\    return vec4<f32>(in.color.rgb, in.color.a * a);
        \\}
    ;
    return createTexturePipeline(gctx, pipeline_layout, shader_src);
}

fn createImagePipeline(gctx: *backend.RenderContext, pipeline_layout: backend.PipelineLayoutHandle) !backend.RenderPipelineHandle {
    const shader_src: [:0]const u8 =
        \\struct Uniforms {
        \\    screen_size: vec2<f32>,
        \\};
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\struct VSIn {
        \\    @location(0) pos: vec2<f32>,
        \\    @location(1) uv: vec2<f32>,
        \\    @location(2) color: vec4<f32>,
        \\};
        \\struct VSOut {
        \\    @builtin(position) position: vec4<f32>,
        \\    @location(0) uv: vec2<f32>,
        \\    @location(1) color: vec4<f32>,
        \\};
        \\@vertex
        \\fn vs_main(in: VSIn) -> VSOut {
        \\    var out: VSOut;
        \\    let ndc_x = (in.pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
        \\    let ndc_y = 1.0 - (in.pos.y / uniforms.screen_size.y) * 2.0;
        \\    out.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
        \\    out.uv = in.uv;
        \\    out.color = in.color;
        \\    return out;
        \\}
        \\@group(1) @binding(0) var image_sampler: sampler;
        \\@group(1) @binding(1) var image_tex: texture_2d<f32>;
        \\@fragment
        \\fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
        \\    return textureSample(image_tex, image_sampler, in.uv) * in.color;
        \\}
    ;
    return createTexturePipeline(gctx, pipeline_layout, shader_src);
}

fn createTexturePipeline(gctx: *backend.RenderContext, pipeline_layout: backend.PipelineLayoutHandle, shader_src: [:0]const u8) !backend.RenderPipelineHandle {
    const shader_module = backend.createWgslShaderModule(gctx.device, shader_src, null);
    defer shader_module.release();
    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(window.TextVertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(window.TextVertex, "uv"), .shader_location = 1 },
        .{ .format = .float32x4, .offset = @offsetOf(window.TextVertex, "color"), .shader_location = 2 },
    };
    const vertex_layout = wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(window.TextVertex),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };
    const vertex_layouts = [_]wgpu.VertexBufferLayout{vertex_layout};
    const color_targets = [_]wgpu.ColorTargetState{blendColorTarget()};
    return gctx.createRenderPipeline(pipeline_layout, .{
        .vertex = .{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &vertex_layouts,
        },
        .fragment = &wgpu.FragmentState{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
        .primitive = .{},
    });
}

fn createLinePipeline(gctx: *backend.RenderContext, pipeline_layout: backend.PipelineLayoutHandle) !backend.RenderPipelineHandle {
    const shader_src: [:0]const u8 =
        \\struct Uniforms {
        \\    screen_size: vec2<f32>,
        \\};
        \\ @group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\ struct VSIn {
        \\    @location(0) pos: vec2<f32>,
        \\    @location(1) color: vec4<f32>,
        \\    @location(2) seg_a: vec2<f32>,
        \\    @location(3) seg_b: vec2<f32>,
        \\    @location(4) thickness: f32,
        \\    @location(5) side: f32,
        \\ };
        \\ struct VSOut {
        \\    @builtin(position) position: vec4<f32>,
        \\    @location(0) color: vec4<f32>,
        \\    @location(1) seg_a: vec2<f32>,
        \\    @location(2) seg_b: vec2<f32>,
        \\    @location(3) thickness: f32,
        \\    @location(4) @interpolate(flat) side: f32,
        \\    @location(5) logical_pos: vec2<f32>,
        \\ };
        \\ @vertex
        \\ fn vs_main(in: VSIn) -> VSOut {
        \\    var out: VSOut;
        \\    let ndc_x = (in.pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
        \\    let ndc_y = 1.0 - (in.pos.y / uniforms.screen_size.y) * 2.0;
        \\    out.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
        \\    out.color = in.color;
        \\    out.seg_a = in.seg_a;
        \\    out.seg_b = in.seg_b;
        \\    out.thickness = in.thickness;
        \\    out.side = in.side;
        \\    out.logical_pos = in.pos;
        \\    return out;
        \\ }
        \\ fn dist_to_segment(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
        \\    let ab = b - a;
        \\    let ap = p - a;
        \\    let t = clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0);
        \\    let closest = a + ab * t;
        \\    return distance(p, closest);
        \\ }
        \\ @fragment
        \\ fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
        \\    let px = in.logical_pos;
        \\    let d = dist_to_segment(px, in.seg_a, in.seg_b);
        \\    let half_thick = in.thickness * 0.5;
        \\    let edge = 0.75;
        \\    let alpha = 1.0 - smoothstep(half_thick, half_thick + edge, d);
        \\    return vec4<f32>(in.color.rgb, in.color.a * alpha);
        \\ }
    ;
    const shader_module = backend.createWgslShaderModule(gctx.device, shader_src, null);
    defer shader_module.release();
    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(window.LineVertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x4, .offset = @offsetOf(window.LineVertex, "color"), .shader_location = 1 },
        .{ .format = .float32x2, .offset = @offsetOf(window.LineVertex, "seg_a"), .shader_location = 2 },
        .{ .format = .float32x2, .offset = @offsetOf(window.LineVertex, "seg_b"), .shader_location = 3 },
        .{ .format = .float32, .offset = @offsetOf(window.LineVertex, "thickness"), .shader_location = 4 },
        .{ .format = .float32, .offset = @offsetOf(window.LineVertex, "side"), .shader_location = 5 },
    };
    const vertex_layout = wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(window.LineVertex),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };
    const vertex_layouts = [_]wgpu.VertexBufferLayout{vertex_layout};
    const color_targets = [_]wgpu.ColorTargetState{blendColorTarget()};
    return gctx.createRenderPipeline(pipeline_layout, .{
        .vertex = .{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &vertex_layouts,
        },
        .fragment = &wgpu.FragmentState{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
        .primitive = .{},
    });
}

fn blendColorTarget() wgpu.ColorTargetState {
    return .{
        .format = backend.default_target_format,
        .blend = &wgpu.BlendState{
            .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        },
        .write_mask = .all,
    };
}

fn clipEqual(a: ?window.Rect, b: ?window.Rect) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.x == b.?.x and a.?.y == b.?.y and a.?.w == b.?.w and a.?.h == b.?.h;
}

fn currentClip(stack: []const window.Rect) ?window.Rect {
    if (stack.len == 0) return null;
    return stack[stack.len - 1];
}

fn effectiveClip(current: ?window.Rect, next: window.Rect) window.Rect {
    if (current) |clip| {
        const x0 = @max(clip.x, next.x);
        const y0 = @max(clip.y, next.y);
        const x1 = @min(clip.x + clip.w, next.x + next.w);
        const y1 = @min(clip.y + clip.h, next.y + next.h);
        return .{ .x = x0, .y = y0, .w = @max(0.0, x1 - x0), .h = @max(0.0, y1 - y0) };
    }
    return next;
}

fn emptyDefaultFont(_: *anyopaque) ?window.TextFontId {
    return null;
}

fn emptyFontMetrics(_: *anyopaque, _: window.TextFontId) ?FontMetrics {
    return null;
}

fn emptyResolveGlyph(_: *anyopaque, _: window.TextFontId, _: u21) ?ResolvedTextGlyph {
    return null;
}

fn emptyTextProvider() TextProvider {
    return .{
        .context = undefined,
        .defaultFontFn = emptyDefaultFont,
        .fontMetricsFn = emptyFontMetrics,
        .resolveGlyphFn = emptyResolveGlyph,
    };
}

fn retainedLessThan(_: void, lhs: RetainedNode, rhs: RetainedNode) bool {
    if (lhs.layer == rhs.layer) return lhs.id < rhs.id;
    return lhs.layer < rhs.layer;
}

fn validateImageUpdate(existing_width: u32, existing_height: u32, width: u32, height: u32, pixel_len: usize) !void {
    if (width == 0 or height == 0) return error.InvalidImageSize;
    if (existing_width != width or existing_height != height) return error.ImageSizeMismatch;
    const required = @as(usize, width) * @as(usize, height) * 4;
    if (pixel_len != required) return error.InvalidImagePixels;
}

fn ellipseSegmentCount(radius: [2]f32) usize {
    const max_radius = @max(@abs(radius[0]), @abs(radius[1]));
    if (max_radius <= 8.0) return 24;
    if (max_radius <= 32.0) return 40;
    if (max_radius <= 128.0) return 64;
    return 96;
}

fn ellipsePoint(center: [2]f32, radius: [2]f32, radians: f32) [2]f32 {
    return .{
        center[0] + std.math.cos(radians) * radius[0],
        center[1] + std.math.sin(radians) * radius[1],
    };
}

fn roundedRectRadius(rect: window.Rect, radius: f32) f32 {
    if (rect.w <= 0.0 or rect.h <= 0.0) return 0.0;
    return @min(@max(0.0, radius), @min(rect.w, rect.h) * 0.5);
}

fn roundedRectCornerSegments(radius: f32) usize {
    if (radius <= 8.0) return 6;
    if (radius <= 32.0) return 8;
    return 12;
}

fn roundedRectPoint(rect: window.Rect, radius: f32, angle: f32) [2]f32 {
    const cx = if (std.math.cos(angle) >= 0.0)
        rect.x + rect.w - radius
    else
        rect.x + radius;
    const cy = if (std.math.sin(angle) >= 0.0)
        rect.y + rect.h - radius
    else
        rect.y + radius;
    return .{
        cx + std.math.cos(angle) * radius,
        cy + std.math.sin(angle) * radius,
    };
}

fn linearGradientColorAt(gradient: window.LinearGradientRect, point: [2]f32) [4]f32 {
    const axis = [2]f32{ gradient.end[0] - gradient.start[0], gradient.end[1] - gradient.start[1] };
    const len_sq = axis[0] * axis[0] + axis[1] * axis[1];
    const t = if (len_sq <= 0.000001)
        0.0
    else
        std.math.clamp(((point[0] - gradient.start[0]) * axis[0] + (point[1] - gradient.start[1]) * axis[1]) / len_sq, 0.0, 1.0);
    return .{
        gradient.start_color[0] + (gradient.end_color[0] - gradient.start_color[0]) * t,
        gradient.start_color[1] + (gradient.end_color[1] - gradient.start_color[1]) * t,
        gradient.start_color[2] + (gradient.end_color[2] - gradient.start_color[2]) * t,
        gradient.start_color[3] + (gradient.end_color[3] - gradient.start_color[3]) * t,
    };
}

fn radialGradientColorAt(gradient: window.RadialGradientRect, point: [2]f32) [4]f32 {
    const dx = point[0] - gradient.center[0];
    const dy = point[1] - gradient.center[1];
    const t = if (gradient.radius <= 0.000001)
        0.0
    else
        std.math.clamp(std.math.sqrt(dx * dx + dy * dy) / gradient.radius, 0.0, 1.0);
    return lerpColor(gradient.inner_color, gradient.outer_color, t);
}

fn sweepGradientColorAt(gradient: window.SweepGradientRect, point: [2]f32) [4]f32 {
    const angle = std.math.atan2(point[1] - gradient.center[1], point[0] - gradient.center[0]) - gradient.start_angle;
    const wrapped = @mod(angle, std.math.tau);
    return lerpColor(gradient.start_color, gradient.end_color, wrapped / std.math.tau);
}

fn lerpColor(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    };
}

fn flattenPath(allocator: std.mem.Allocator, commands: []const window.PathCommand, out: *std.ArrayList([2]f32)) !void {
    var current: ?[2]f32 = null;
    var start: ?[2]f32 = null;
    for (commands) |command| {
        switch (command) {
            .move_to => |p| {
                try appendPathPoint(allocator, out, p);
                current = p;
                start = p;
            },
            .line_to => |p| {
                try appendPathPoint(allocator, out, p);
                current = p;
            },
            .quad_to => |q| {
                const p0 = current orelse q.end;
                var i: usize = 1;
                while (i <= 12) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / 12.0;
                    try appendPathPoint(allocator, out, quadPathPoint(p0, q.control, q.end, t));
                }
                current = q.end;
            },
            .cubic_to => |c| {
                const p0 = current orelse c.end;
                var i: usize = 1;
                while (i <= 16) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / 16.0;
                    try appendPathPoint(allocator, out, cubicPathPoint(p0, c.c0, c.c1, c.end, t));
                }
                current = c.end;
            },
            .arc => |a| {
                try flattenArc(allocator, out, current, a.center, a.radius, a.start_angle, a.end_angle, false);
                current = .{ a.center[0] + std.math.cos(a.end_angle) * a.radius, a.center[1] + std.math.sin(a.end_angle) * a.radius };
            },
            .arc_negative => |a| {
                try flattenArc(allocator, out, current, a.center, a.radius, a.start_angle, a.end_angle, true);
                current = .{ a.center[0] + std.math.cos(a.end_angle) * a.radius, a.center[1] + std.math.sin(a.end_angle) * a.radius };
            },
            .close => {
                if (start) |p| {
                    try appendPathPoint(allocator, out, p);
                    current = p;
                }
            },
        }
    }
}

fn flattenPathSubpaths(allocator: std.mem.Allocator, commands: []const window.PathCommand) !std.ArrayList(std.ArrayList([2]f32)) {
    var subpaths: std.ArrayList(std.ArrayList([2]f32)) = .empty;
    errdefer {
        for (subpaths.items) |*subpath| subpath.deinit(allocator);
        subpaths.deinit(allocator);
    }
    var current_path = try std.ArrayList([2]f32).initCapacity(allocator, commands.len + 4);
    errdefer current_path.deinit(allocator);
    var current: ?[2]f32 = null;
    var start: ?[2]f32 = null;
    for (commands) |command| {
        switch (command) {
            .move_to => |p| {
                if (current_path.items.len >= 3) {
                    try subpaths.append(allocator, current_path);
                    current_path = try std.ArrayList([2]f32).initCapacity(allocator, commands.len + 4);
                } else {
                    current_path.clearRetainingCapacity();
                }
                try appendPathPoint(allocator, &current_path, p);
                current = p;
                start = p;
            },
            .line_to => |p| {
                try appendPathPoint(allocator, &current_path, p);
                current = p;
            },
            .quad_to => |q| {
                const p0 = current orelse q.end;
                var i: usize = 1;
                while (i <= 12) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / 12.0;
                    try appendPathPoint(allocator, &current_path, quadPathPoint(p0, q.control, q.end, t));
                }
                current = q.end;
            },
            .cubic_to => |c| {
                const p0 = current orelse c.end;
                var i: usize = 1;
                while (i <= 16) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / 16.0;
                    try appendPathPoint(allocator, &current_path, cubicPathPoint(p0, c.c0, c.c1, c.end, t));
                }
                current = c.end;
            },
            .arc => |a| {
                try flattenArc(allocator, &current_path, current, a.center, a.radius, a.start_angle, a.end_angle, false);
                current = .{ a.center[0] + std.math.cos(a.end_angle) * a.radius, a.center[1] + std.math.sin(a.end_angle) * a.radius };
            },
            .arc_negative => |a| {
                try flattenArc(allocator, &current_path, current, a.center, a.radius, a.start_angle, a.end_angle, true);
                current = .{ a.center[0] + std.math.cos(a.end_angle) * a.radius, a.center[1] + std.math.sin(a.end_angle) * a.radius };
            },
            .close => {
                if (start) |p| {
                    try appendPathPoint(allocator, &current_path, p);
                    current = p;
                }
                if (current_path.items.len >= 3) {
                    try subpaths.append(allocator, current_path);
                    current_path = try std.ArrayList([2]f32).initCapacity(allocator, commands.len + 4);
                } else {
                    current_path.clearRetainingCapacity();
                }
                current = null;
                start = null;
            },
        }
    }
    if (current_path.items.len >= 3) {
        try subpaths.append(allocator, current_path);
    } else {
        current_path.deinit(allocator);
    }
    return subpaths;
}

fn appendPathPoint(allocator: std.mem.Allocator, out: *std.ArrayList([2]f32), p: [2]f32) !void {
    if (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (@abs(last[0] - p[0]) < 0.001 and @abs(last[1] - p[1]) < 0.001) return;
    }
    try out.append(allocator, p);
}

fn trimClosedDuplicate(points: []const [2]f32) []const [2]f32 {
    if (points.len < 2) return points;
    const first = points[0];
    const last = points[points.len - 1];
    if (@abs(first[0] - last[0]) < 0.001 and @abs(first[1] - last[1]) < 0.001) return points[0 .. points.len - 1];
    return points;
}

fn polygonSignedArea(points: []const [2]f32) f32 {
    var area: f32 = 0.0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    return area * 0.5;
}

fn isConvexEar(a: [2]f32, b: [2]f32, c: [2]f32) bool {
    return cross2(a, b, c) > 0.000001;
}

fn triangleContainsAnyPoint(points: []const [2]f32, indices: []const usize, a_index: usize, b_index: usize, c_index: usize, a: [2]f32, b: [2]f32, c: [2]f32) bool {
    for (indices) |index| {
        if (index == a_index or index == b_index or index == c_index) continue;
        if (pointInTriangle(points[index], a, b, c)) return true;
    }
    return false;
}

fn pointInTriangle(p: [2]f32, a: [2]f32, b: [2]f32, c: [2]f32) bool {
    const ab = cross2(a, b, p);
    const bc = cross2(b, c, p);
    const ca = cross2(c, a, p);
    return ab >= -0.000001 and bc >= -0.000001 and ca >= -0.000001;
}

fn cross2(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn trianglesContainPoint(vertices: []const window.Vertex, p: [2]f32) bool {
    var i: usize = 0;
    while (i + 2 < vertices.len) : (i += 3) {
        if (pointInTriangleAnyWinding(p, vertices[i].pos, vertices[i + 1].pos, vertices[i + 2].pos)) return true;
    }
    return false;
}

fn pointInTriangleAnyWinding(p: [2]f32, a: [2]f32, b: [2]f32, c: [2]f32) bool {
    const ab = cross2(a, b, p);
    const bc = cross2(b, c, p);
    const ca = cross2(c, a, p);
    return (ab >= -0.000001 and bc >= -0.000001 and ca >= -0.000001) or
        (ab <= 0.000001 and bc <= 0.000001 and ca <= 0.000001);
}

fn rasterizeShapeBatchesForTest(target: *Image, vertices: []const window.Vertex, batches: []const Batch) void {
    for (batches) |batch| {
        if (batch.kind != .shape) continue;
        const clip = batch.clip orelse .{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(target.width)), .h = @as(f32, @floatFromInt(target.height)) };
        var i: usize = batch.first;
        const end = batch.first + batch.count;
        while (i + 2 < end) : (i += 3) {
            rasterizeTriangleForTest(target, vertices[i], vertices[i + 1], vertices[i + 2], clip);
        }
    }
}

fn rasterizePaintQuadBatchesForTest(target: *Image, vertices: []const window.PaintQuadVertex, batches: []const Batch) void {
    for (batches) |batch| {
        if (batch.kind != .paint_quad) continue;
        const clip = batch.clip orelse .{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(target.width)), .h = @as(f32, @floatFromInt(target.height)) };
        var i: usize = batch.first;
        const end = batch.first + batch.count;
        while (i + 2 < end) : (i += 3) {
            rasterizePaintQuadTriangleForTest(target, vertices[i], vertices[i + 1], vertices[i + 2], clip);
        }
    }
}

fn expectGpuLoweringMatchesCpuPixels(draw_list: []const window.DrawCmd, width: u32, height: u32) !void {
    var cpu_scene = scene2d.Scene2D.init(std.testing.allocator);
    defer cpu_scene.deinit();
    var cpu_renderer = cpu.CpuRenderer.init(std.testing.allocator);
    var cpu_image = try Image.init(std.testing.allocator, width, height, .transparent);
    defer cpu_image.deinit();
    try window_draw.renderDrawListCpu(draw_list, &cpu_scene, &cpu_renderer, &cpu_image, null, null, 1.0);

    var gpu_scene = try ImmediateScene.init(std.testing.allocator, 512, 64, 16, 64);
    defer gpu_scene.deinit();
    try gpu_scene.beginFrame(&.{});
    try gpu_scene.pushDrawList(draw_list, emptyTextProvider());
    var lowered_image = try Image.init(std.testing.allocator, width, height, .transparent);
    defer lowered_image.deinit();
    rasterizeShapeBatchesForTest(&lowered_image, gpu_scene.vertices.items, gpu_scene.batches.items);
    rasterizePaintQuadBatchesForTest(&lowered_image, gpu_scene.paint_quad_vertices.items, gpu_scene.batches.items);

    const comparison = try cpu_image.compare(&lowered_image, 0);
    try std.testing.expectEqual(@as(usize, 0), comparison.mismatched_pixels);
}

fn rasterizeTriangleForTest(target: *Image, a: window.Vertex, b: window.Vertex, c: window.Vertex, clip: window.Rect) void {
    const min_x = @min(@min(a.pos[0], b.pos[0]), c.pos[0]);
    const min_y = @min(@min(a.pos[1], b.pos[1]), c.pos[1]);
    const max_x = @max(@max(a.pos[0], b.pos[0]), c.pos[0]);
    const max_y = @max(@max(a.pos[1], b.pos[1]), c.pos[1]);
    const x0: i32 = @intFromFloat(@floor(@max(min_x, clip.x)));
    const y0: i32 = @intFromFloat(@floor(@max(min_y, clip.y)));
    const x1: i32 = @intFromFloat(@ceil(@min(max_x, clip.x + clip.w)));
    const y1: i32 = @intFromFloat(@ceil(@min(max_y, clip.y + clip.h)));
    var y = @max(0, y0);
    while (y < @min(y1, @as(i32, @intCast(target.height)))) : (y += 1) {
        var x = @max(0, x0);
        while (x < @min(x1, @as(i32, @intCast(target.width)))) : (x += 1) {
            const p = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
            if (pointInTriangleAnyWinding(p, a.pos, b.pos, c.pos)) {
                target.blendPixel(@intCast(x), @intCast(y), vertexColor(a.color));
            }
        }
    }
}

fn rasterizePaintQuadTriangleForTest(target: *Image, a: window.PaintQuadVertex, b: window.PaintQuadVertex, c: window.PaintQuadVertex, clip: window.Rect) void {
    const min_x = @min(@min(a.pos[0], b.pos[0]), c.pos[0]);
    const min_y = @min(@min(a.pos[1], b.pos[1]), c.pos[1]);
    const max_x = @max(@max(a.pos[0], b.pos[0]), c.pos[0]);
    const max_y = @max(@max(a.pos[1], b.pos[1]), c.pos[1]);
    const x0: i32 = @intFromFloat(@floor(@max(min_x - 1.0, clip.x)));
    const y0: i32 = @intFromFloat(@floor(@max(min_y - 1.0, clip.y)));
    const x1: i32 = @intFromFloat(@ceil(@min(max_x + 1.0, clip.x + clip.w)));
    const y1: i32 = @intFromFloat(@ceil(@min(max_y + 1.0, clip.y + clip.h)));
    var y = @max(0, y0);
    while (y < @min(y1, @as(i32, @intCast(target.height)))) : (y += 1) {
        var x = @max(0, x0);
        while (x < @min(x1, @as(i32, @intCast(target.width)))) : (x += 1) {
            const p = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
            if (!pointInTriangleAnyWinding(p, a.pos, b.pos, c.pos)) continue;
            const color = paintQuadColorForTest(a, p) orelse continue;
            target.blendPixel(@intCast(x), @intCast(y), color);
        }
    }
}

fn paintQuadColorForTest(v: window.PaintQuadVertex, p: [2]f32) ?Color {
    const rect = window.Rect{ .x = v.rect_origin[0], .y = v.rect_origin[1], .w = v.rect_size[0], .h = v.rect_size[1] };
    const d = paintQuadRoundedRectSdf(p[0], p[1], rect, v.radius);
    const aa: f32 = 0.75;
    const outer_alpha = 1.0 - paintQuadSmoothstep(-aa, aa, d);
    if (outer_alpha <= 0.0) return null;
    var color = vertexColor(v.background);
    const border = vertexColor(v.border_color);
    if (v.border_width > 0.0 and border.a > 0) {
        const inner_sdf = -(d + v.border_width);
        const border_sdf = @max(inner_sdf, d);
        if (border_sdf < aa) {
            const blended = blendPaintQuadBorderOverBackground(border, color);
            color = mixPaintQuadColor(color, blended, 1.0 - paintQuadSmoothstep(-aa, aa, inner_sdf));
        }
    }
    return color.withAlphaScale(outer_alpha);
}

fn paintQuadRoundedRectSdf(px: f32, py: f32, rect: window.Rect, radius: f32) f32 {
    const half_w = rect.w * 0.5;
    const half_h = rect.h * 0.5;
    const cx = rect.x + half_w;
    const cy = rect.y + half_h;
    const qx = @abs(px - cx) - (half_w - radius);
    const qy = @abs(py - cy) - (half_h - radius);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - radius;
}

fn paintQuadSmoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn blendPaintQuadBorderOverBackground(border: Color, background: Color) Color {
    const ba = @as(f32, @floatFromInt(border.a)) / 255.0;
    const bga = @as(f32, @floatFromInt(background.a)) / 255.0;
    const out_a = ba + bga * (1.0 - ba);
    if (out_a <= 0.0001) return .transparent;
    return Color.rgba(
        @intFromFloat(@round(((@as(f32, @floatFromInt(border.r)) / 255.0 * ba + @as(f32, @floatFromInt(background.r)) / 255.0 * bga * (1.0 - ba)) / out_a) * 255.0)),
        @intFromFloat(@round(((@as(f32, @floatFromInt(border.g)) / 255.0 * ba + @as(f32, @floatFromInt(background.g)) / 255.0 * bga * (1.0 - ba)) / out_a) * 255.0)),
        @intFromFloat(@round(((@as(f32, @floatFromInt(border.b)) / 255.0 * ba + @as(f32, @floatFromInt(background.b)) / 255.0 * bga * (1.0 - ba)) / out_a) * 255.0)),
        @intFromFloat(@round(out_a * 255.0)),
    );
}

fn mixPaintQuadColor(a: Color, b: Color, t: f32) Color {
    return Color.rgba(
        mixPaintQuadByte(a.r, b.r, t),
        mixPaintQuadByte(a.g, b.g, t),
        mixPaintQuadByte(a.b, b.b, t),
        mixPaintQuadByte(a.a, b.a, t),
    );
}

fn mixPaintQuadByte(a: u8, b: u8, t: f32) u8 {
    const value = @as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * std.math.clamp(t, 0.0, 1.0);
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 255.0)));
}

fn vertexColor(color: [4]f32) Color {
    return Color.rgba(
        @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[3], 0.0, 1.0) * 255.0)),
    );
}

fn strokeQualityUsesFastSegments(quality: window.StrokeQuality) bool {
    return quality == .fast;
}

const DashState = struct {
    pattern: window.DashPattern,
    index: usize = 0,
    remaining: f32 = 0.0,
    on: bool = true,

    fn init(pattern: window.DashPattern) DashState {
        var state = DashState{ .pattern = pattern };
        const total = pattern.totalLength();
        var offset = if (total > 0.000001) @mod(pattern.offset, total) else 0.0;
        while (offset > 0.000001 and state.pattern.count > 0) {
            const segment = @max(state.pattern.segments[state.index], 0.000001);
            if (offset < segment) {
                state.remaining = segment - offset;
                state.on = (state.index % 2) == 0;
                return state;
            }
            offset -= segment;
            state.index = (state.index + 1) % state.pattern.count;
        }
        state.remaining = if (state.pattern.count > 0) @max(state.pattern.segments[state.index], 0.000001) else 0.0;
        state.on = (state.index % 2) == 0;
        return state;
    }

    fn advance(self: *DashState, distance: f32) void {
        if (self.pattern.count == 0) return;
        self.remaining -= distance;
        while (self.remaining <= 0.0001) {
            self.index = (self.index + 1) % self.pattern.count;
            self.remaining += @max(self.pattern.segments[self.index], 0.000001);
            self.on = (self.index % 2) == 0;
        }
    }
};

fn pathClosed(points: []const [2]f32) bool {
    return points.len > 2 and pointsEqual(points[0], points[points.len - 1]);
}

fn pointsEqual(a: [2]f32, b: [2]f32) bool {
    return @abs(a[0] - b[0]) < 0.001 and @abs(a[1] - b[1]) < 0.001;
}

fn pointFinite(p: [2]f32) bool {
    return std.math.isFinite(p[0]) and std.math.isFinite(p[1]);
}

fn scaleColorAlpha(color: [4]f32, alpha_scale: f32) [4]f32 {
    return .{ color[0], color[1], color[2], color[3] * std.math.clamp(alpha_scale, 0.0, 1.0) };
}

fn transparentColor(color: [4]f32) [4]f32 {
    return .{ color[0], color[1], color[2], 0.0 };
}

fn polar2(angle: f32, radius: f32) [2]f32 {
    return .{ @cos(angle) * radius, @sin(angle) * radius };
}

fn add2(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn sub2(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn scale2(a: [2]f32, factor: f32) [2]f32 {
    return .{ a[0] * factor, a[1] * factor };
}

fn length2(a: [2]f32) f32 {
    return @sqrt(a[0] * a[0] + a[1] * a[1]);
}

fn normalize2(a: [2]f32) [2]f32 {
    const len = length2(a);
    if (len <= 0.000001 or !std.math.isFinite(len)) return .{ 0.0, 0.0 };
    return .{ a[0] / len, a[1] / len };
}

fn segmentNormal(a: [2]f32, b: [2]f32) [2]f32 {
    const dir = normalize2(.{ b[0] - a[0], b[1] - a[1] });
    return .{ -dir[1], dir[0] };
}

fn strokeOffsetAt(points: []const [2]f32, point_count: usize, index: usize, closed: bool, radius: f32) [2]f32 {
    if (point_count < 2 or radius <= 0.0) return .{ 0.0, 0.0 };

    const current = points[index];
    const has_prev = closed or index > 0;
    const has_next = closed or index + 1 < point_count;

    if (!has_prev and has_next) return scale2(segmentNormal(current, points[index + 1]), radius);
    if (has_prev and !has_next) return scale2(segmentNormal(points[index - 1], current), radius);

    const prev_index = if (index == 0) point_count - 1 else index - 1;
    const next_index = if (index + 1 == point_count) 0 else index + 1;
    const prev_n = segmentNormal(points[prev_index], current);
    const next_n = segmentNormal(current, points[next_index]);
    const miter = normalize2(add2(prev_n, next_n));
    if (length2(miter) <= 0.000001) return scale2(next_n, radius);

    const denom = miter[0] * next_n[0] + miter[1] * next_n[1];
    if (@abs(denom) <= 0.2) return scale2(next_n, radius);
    const miter_len = std.math.clamp(radius / denom, -radius * 3.0, radius * 3.0);
    return scale2(miter, miter_len);
}

fn quadPathPoint(a: [2]f32, b: [2]f32, c: [2]f32, t: f32) [2]f32 {
    const mt = 1.0 - t;
    return .{
        mt * mt * a[0] + 2.0 * mt * t * b[0] + t * t * c[0],
        mt * mt * a[1] + 2.0 * mt * t * b[1] + t * t * c[1],
    };
}

fn cubicPathPoint(a: [2]f32, b: [2]f32, c: [2]f32, d: [2]f32, t: f32) [2]f32 {
    const mt = 1.0 - t;
    return .{
        mt * mt * mt * a[0] + 3.0 * mt * mt * t * b[0] + 3.0 * mt * t * t * c[0] + t * t * t * d[0],
        mt * mt * mt * a[1] + 3.0 * mt * mt * t * b[1] + 3.0 * mt * t * t * c[1] + t * t * t * d[1],
    };
}

fn flattenArc(allocator: std.mem.Allocator, out: *std.ArrayList([2]f32), current: ?[2]f32, center: [2]f32, radius: f32, start_angle: f32, end_angle: f32, negative: bool) !void {
    if (radius <= 0.0) return;
    const start_point = .{ center[0] + std.math.cos(start_angle) * radius, center[1] + std.math.sin(start_angle) * radius };
    if (current == null) try appendPathPoint(allocator, out, start_point);
    var delta = end_angle - start_angle;
    if (negative and delta > 0.0) delta -= std.math.tau;
    if (!negative and delta < 0.0) delta += std.math.tau;
    const segments: usize = @max(4, @as(usize, @intFromFloat(@ceil(@abs(delta) / (std.math.pi / 12.0)))));
    var i: usize = 1;
    while (i <= segments) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const angle = start_angle + delta * t;
        try appendPathPoint(allocator, out, .{ center[0] + std.math.cos(angle) * radius, center[1] + std.math.sin(angle) * radius });
    }
}

const ScissorRect = struct { x: u32, y: u32, w: u32, h: u32 };

fn rectToScissorScaled(rect: ?window.Rect, width: u32, height: u32, scale: f32) ScissorRect {
    if (rect == null) return .{ .x = 0, .y = 0, .w = width, .h = height };
    const r = rect.?;
    const pixel_scale = @max(scale, 1.0);
    const max_x: f32 = @floatFromInt(width);
    const max_y: f32 = @floatFromInt(height);
    const x0 = std.math.clamp(r.x * pixel_scale, 0.0, max_x);
    const y0 = std.math.clamp(r.y * pixel_scale, 0.0, max_y);
    const x1 = std.math.clamp((r.x + r.w) * pixel_scale, 0.0, max_x);
    const y1 = std.math.clamp((r.y + r.h) * pixel_scale, 0.0, max_y);
    const raw_w = @as(u32, @intFromFloat(@max(0.0, x1 - x0)));
    const raw_h = @as(u32, @intFromFloat(@max(0.0, y1 - y0)));
    const x = @as(u32, @intFromFloat(x0));
    const y = @as(u32, @intFromFloat(y0));
    const w = if (raw_w == 0 and x < width) 1 else raw_w;
    const h = if (raw_h == 0 and y < height) 1 else raw_h;
    return .{
        .x = if (x == width and w > 0) width - 1 else x,
        .y = if (y == height and h > 0) height - 1 else y,
        .w = if (x + w > width) width - x else w,
        .h = if (y + h > height) height - y else h,
    };
}

fn padTextureRows(allocator: std.mem.Allocator, rgba_pixels: []const u8, width: u32, height: u32, src_stride: u32, dst_stride: u32) ![]u8 {
    const required = @as(usize, src_stride) * @as(usize, height);
    if (rgba_pixels.len != required) return error.InvalidImagePixels;
    const out = try allocator.alloc(u8, @as(usize, dst_stride) * @as(usize, height));
    @memset(out, 0);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_start = @as(usize, y) * @as(usize, src_stride);
        const dst_start = @as(usize, y) * @as(usize, dst_stride);
        const row_len = @as(usize, width) * 4;
        @memcpy(out[dst_start .. dst_start + row_len], rgba_pixels[src_start .. src_start + row_len]);
    }
    return out;
}

fn alignUpU32(value: u32, alignment: u32) u32 {
    return ((value + alignment - 1) / alignment) * alignment;
}

test "window gpu scissor maps logical clips to high-DPI framebuffer" {
    const scissor = rectToScissorScaled(.{ .x = 10, .y = 20, .w = 30, .h = 40 }, 200, 160, 2.0);
    try std.testing.expectEqual(@as(u32, 20), scissor.x);
    try std.testing.expectEqual(@as(u32, 40), scissor.y);
    try std.testing.expectEqual(@as(u32, 60), scissor.w);
    try std.testing.expectEqual(@as(u32, 80), scissor.h);
}

test "window gpu pads texture upload rows" {
    const pixels = [_]u8{
        1,  2,  3,  4,  5,  6,  7,  8,
        9,  10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24,
    };
    const padded = try padTextureRows(std.testing.allocator, &pixels, 3, 2, 12, 16);
    defer std.testing.allocator.free(padded);
    try std.testing.expectEqual(@as(usize, 32), padded.len);
    try std.testing.expectEqualSlices(u8, pixels[0..12], padded[0..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, padded[12..16]);
    try std.testing.expectEqualSlices(u8, pixels[12..24], padded[16..28]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, padded[28..32]);
    try std.testing.expectEqual(@as(u32, 256), alignUpU32(800, 256));
    try std.testing.expectEqual(@as(u32, 1024), alignUpU32(801, 256));
}

test "window image update validation rejects mismatched inputs" {
    try validateImageUpdate(2, 2, 2, 2, 16);
    try std.testing.expectError(error.InvalidImageSize, validateImageUpdate(2, 2, 0, 2, 0));
    try std.testing.expectError(error.ImageSizeMismatch, validateImageUpdate(2, 2, 3, 2, 24));
    try std.testing.expectError(error.InvalidImagePixels, validateImageUpdate(2, 2, 2, 2, 12));
}

test "retained store appends sorted retained vertices" {
    var store = try RetainedStore.init(std.testing.allocator);
    defer store.deinit();
    const high = try store.createNode();
    const low = try store.createNode();
    try store.setNodeLayer(high, 10);
    try store.setNodeLayer(low, -1);
    try store.updateNode(high, &.{.{ .pos = .{ 10, 0 }, .color = .{ 1, 0, 0, 1 } }});
    try store.updateNode(low, &.{.{ .pos = .{ 1, 0 }, .color = .{ 0, 1, 0, 1 } }});

    var scene = try ImmediateScene.init(std.testing.allocator, 16, 16, 16, 16);
    defer scene.deinit();
    try scene.beginFrame(&.{});
    try store.appendToScene(&scene);
    try std.testing.expectEqual(@as(usize, 2), scene.vertices.items.len);
    try std.testing.expectEqual(@as(f32, 1), scene.vertices.items[0].pos[0]);
    try std.testing.expectEqual(@as(f32, 10), scene.vertices.items[1].pos[0]);
}

test "window gpu polylines can use continuous feathered mesh" {
    var scene = try ImmediateScene.init(std.testing.allocator, 512, 16, 16, 64);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    const points = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 8.0, 8.0 },
        .{ 16.0, 0.0 },
    };
    const start = scene.vertices.items.len;
    try scene.pushFeatheredPolyline(&points, 1.5, .{ 1.0, 0.0, 0.0, 1.0 }, false);
    try scene.recordBatch(start, null, .shape, null, null);

    try std.testing.expect(scene.vertices.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), scene.line_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.shape, scene.batches.items[0].kind);
}

test "window gpu fast polylines keep segment shader path" {
    var scene = try ImmediateScene.init(std.testing.allocator, 512, 16, 16, 64);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    const points = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 8.0, 8.0 },
        .{ 16.0, 0.0 },
    };
    const start = scene.line_vertices.items.len;
    var i: usize = 0;
    while (i + 1 < points.len) : (i += 1) {
        _ = try scene.pushLineAA(points[i], points[i + 1], 1.5, .{ 1.0, 0.0, 0.0, 1.0 });
    }
    try scene.recordBatch(start, null, .line_aa, null, null);

    try std.testing.expectEqual(@as(usize, 0), scene.vertices.items.len);
    try std.testing.expect(scene.line_vertices.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.line_aa, scene.batches.items[0].kind);
}

test "window gpu styled lines can opt into fast or feathered quality" {
    var scene = try ImmediateScene.init(std.testing.allocator, 512, 16, 16, 64);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    try scene.pushDrawList(&.{.{ .styled_line = .{
        .a = .{ 0.0, 0.0 },
        .b = .{ 12.0, 0.0 },
        .style = .{ .width = 1.5, .quality = .feathered },
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .layer = 0,
    } }}, emptyTextProvider());
    try std.testing.expect(scene.vertices.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), scene.line_vertices.items.len);
    try std.testing.expectEqual(BatchKind.shape, scene.batches.items[0].kind);

    try scene.beginFrame(&.{});
    try scene.pushDrawList(&.{.{ .styled_line = .{
        .a = .{ 0.0, 0.0 },
        .b = .{ 12.0, 0.0 },
        .style = .{ .width = 1.5, .quality = .fast },
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .layer = 0,
    } }}, emptyTextProvider());
    try std.testing.expectEqual(@as(usize, 0), scene.vertices.items.len);
    try std.testing.expect(scene.line_vertices.items.len > 0);
    try std.testing.expectEqual(BatchKind.line_aa, scene.batches.items[0].kind);
}

test "window gpu vector polylines use independent stroke mesh" {
    var scene = try ImmediateScene.init(std.testing.allocator, 1024, 16, 16, 64);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    const points = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 8.0, 8.0 },
        .{ 16.0, 0.0 },
    };
    try scene.pushDrawList(&.{.{ .styled_polyline = .{
        .points = &points,
        .style = .{ .width = 2.0, .quality = .vector, .cap = .round, .join = .round },
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .layer = 0,
    } }}, emptyTextProvider());

    try std.testing.expect(scene.vertices.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), scene.line_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.shape, scene.batches.items[0].kind);
}

test "window gpu bars match CPU draw-list geometry" {
    var scene = try ImmediateScene.init(std.testing.allocator, 128, 16, 16, 16);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    const values = [_]f32{ 4.0, 6.0 };
    try scene.pushDrawList(&.{.{ .bars = .{
        .values = &values,
        .base = 2.0,
        .bar_width = 5.0,
        .origin = .{ 10.0, 20.0 },
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .layer = 0,
    } }}, emptyTextProvider());

    try std.testing.expectEqual(@as(usize, 12), scene.vertices.items.len);
    try std.testing.expectEqual([2]f32{ 10.0, 22.0 }, scene.vertices.items[0].pos);
    try std.testing.expectEqual([2]f32{ 15.0, 26.0 }, scene.vertices.items[2].pos);
    try std.testing.expectEqual([2]f32{ 15.0, 26.0 }, scene.vertices.items[4].pos);
    try std.testing.expectEqual([2]f32{ 15.0, 22.0 }, scene.vertices.items[6].pos);
    try std.testing.expectEqual([2]f32{ 20.0, 28.0 }, scene.vertices.items[8].pos);
    try std.testing.expectEqual([2]f32{ 20.0, 28.0 }, scene.vertices.items[10].pos);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.shape, scene.batches.items[0].kind);
}

test "window gpu nested clips use intersection stack" {
    var scene = try ImmediateScene.init(std.testing.allocator, 128, 16, 16, 16);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    try scene.pushDrawList(&.{
        .{ .clip_begin = .{ .x = 0, .y = 0, .w = 10, .h = 10 } },
        .{ .clip_begin = .{ .x = 4, .y = 2, .w = 8, .h = 5 } },
        .{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 12, .h = 12 }, .color = .{ 1, 0, 0, 1 }, .layer = 0 } },
        .{ .clip_end = {} },
        .{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 12, .h = 12 }, .color = .{ 0, 1, 0, 1 }, .layer = 0 } },
        .{ .clip_end = {} },
    }, emptyTextProvider());

    try std.testing.expectEqual(@as(usize, 2), scene.batches.items.len);
    try std.testing.expectEqual(window.Rect{ .x = 4, .y = 2, .w = 6, .h = 5 }, scene.batches.items[0].clip.?);
    try std.testing.expectEqual(window.Rect{ .x = 0, .y = 0, .w = 10, .h = 10 }, scene.batches.items[1].clip.?);
}

test "window gpu lowering matches CPU pixels for nested clips and bars" {
    const draw_list = [_]window.DrawCmd{
        .{ .clip_begin = .{ .x = 0, .y = 0, .w = 10, .h = 10 } },
        .{ .clip_begin = .{ .x = 4, .y = 2, .w = 8, .h = 5 } },
        .{ .bars = .{
            .values = &.{4},
            .base = 0,
            .bar_width = 10,
            .origin = .{ 0, 0 },
            .color = .{ 1, 0, 0, 1 },
            .layer = 0,
        } },
        .{ .clip_end = {} },
        .{ .bars = .{
            .values = &.{10},
            .base = 0,
            .bar_width = 10,
            .origin = .{ 0, 0 },
            .color = .{ 0, 1, 0, 1 },
            .layer = 0,
        } },
        .{ .clip_end = {} },
    };

    try expectGpuLoweringMatchesCpuPixels(&draw_list, 12, 12);
}

test "window gpu lowering matches CPU pixels for mixed filled shapes" {
    const path = [_]window.PathCommand{
        .{ .move_to = .{ 0, 6 } },
        .{ .line_to = .{ 5, 6 } },
        .{ .line_to = .{ 5, 11 } },
        .{ .line_to = .{ 2, 8 } },
        .{ .line_to = .{ 0, 11 } },
        .close,
    };
    const draw_list = [_]window.DrawCmd{
        .{ .rect = .{ .rect = .{ .x = 1, .y = 1, .w = 4, .h = 3 }, .color = .{ 1, 0, 0, 1 }, .layer = 0 } },
        .{ .point = .{ .pos = .{ 8, 2 }, .size = 4, .color = .{ 0, 1, 0, 1 }, .layer = 0 } },
        .{ .triangle = .{ .points = .{ .{ 10, 6 }, .{ 15, 6 }, .{ 10, 11 } }, .color = .{ 0, 0, 1, 1 }, .layer = 0 } },
        .{ .fill_path = .{ .path = .{ .commands = &path }, .color = .{ 1, 1, 0, 1 }, .layer = 0 } },
    };

    try expectGpuLoweringMatchesCpuPixels(&draw_list, 16, 12);
}

test "window gpu lowering matches CPU pixels for paint quads" {
    const draw_list = [_]window.DrawCmd{
        .{ .rounded_rect = .{
            .rect = .{ .x = 2, .y = 2, .w = 8, .h = 8 },
            .radius = 3,
            .color = .{ 1, 0, 0, 1 },
            .layer = 0,
        } },
        .{ .stroke_rounded_rect = .{
            .rect = .{ .x = 12, .y = 2, .w = 8, .h = 8 },
            .radius = 3,
            .thickness = 2,
            .color = .{ 0, 1, 0, 1 },
            .layer = 0,
        } },
        .{ .paint_quad = .{
            .rect = .{ .x = 22, .y = 2, .w = 8, .h = 8 },
            .radius = 3,
            .background = .{ 0, 0, 1, 1 },
            .border_width = 1.5,
            .border_color = .{ 1, 1, 1, 0.75 },
            .layer = 0,
        } },
    };

    try expectGpuLoweringMatchesCpuPixels(&draw_list, 32, 12);
}

test "window gpu fill paths triangulate concave polygons" {
    var scene = try ImmediateScene.init(std.testing.allocator, 128, 16, 16, 16);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    const commands = [_]window.PathCommand{
        .{ .move_to = .{ 0.0, 0.0 } },
        .{ .line_to = .{ 10.0, 0.0 } },
        .{ .line_to = .{ 10.0, 10.0 } },
        .{ .line_to = .{ 5.0, 5.0 } },
        .{ .line_to = .{ 0.0, 10.0 } },
        .close,
    };
    try scene.pushDrawList(&.{.{ .fill_path = .{
        .path = .{ .commands = &commands },
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .layer = 0,
    } }}, emptyTextProvider());

    try std.testing.expectEqual(@as(usize, 9), scene.vertices.items.len);
    try std.testing.expect(!trianglesContainPoint(scene.vertices.items, .{ 5.0, 7.5 }));
    try std.testing.expect(trianglesContainPoint(scene.vertices.items, .{ 5.0, 2.0 }));
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.shape, scene.batches.items[0].kind);
}

test "window gpu fill paths keep independent subpaths separate" {
    var scene = try ImmediateScene.init(std.testing.allocator, 128, 16, 16, 16);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    const commands = [_]window.PathCommand{
        .{ .move_to = .{ 0.0, 0.0 } },
        .{ .line_to = .{ 3.0, 0.0 } },
        .{ .line_to = .{ 3.0, 3.0 } },
        .{ .line_to = .{ 0.0, 3.0 } },
        .close,
        .{ .move_to = .{ 7.0, 0.0 } },
        .{ .line_to = .{ 10.0, 0.0 } },
        .{ .line_to = .{ 10.0, 3.0 } },
        .{ .line_to = .{ 7.0, 3.0 } },
        .close,
    };
    try scene.pushDrawList(&.{.{ .fill_path = .{
        .path = .{ .commands = &commands },
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .layer = 0,
    } }}, emptyTextProvider());

    try std.testing.expectEqual(@as(usize, 12), scene.vertices.items.len);
    try std.testing.expect(trianglesContainPoint(scene.vertices.items, .{ 1.5, 1.5 }));
    try std.testing.expect(trianglesContainPoint(scene.vertices.items, .{ 8.5, 1.5 }));
    try std.testing.expect(!trianglesContainPoint(scene.vertices.items, .{ 5.0, 1.5 }));
}

test "window gpu rounded gradient rects use clipped rounded geometry" {
    var scene = try ImmediateScene.init(std.testing.allocator, 2048, 16, 16, 16);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    try scene.pushDrawList(&.{
        .{ .linear_gradient_rect = .{
            .rect = .{ .x = 0, .y = 0, .w = 20, .h = 12 },
            .radius = 4,
            .start = .{ 0, 0 },
            .end = .{ 20, 0 },
            .start_color = .{ 1, 0, 0, 1 },
            .end_color = .{ 0, 0, 1, 1 },
            .layer = 0,
        } },
        .{ .radial_gradient_rect = .{
            .rect = .{ .x = 24, .y = 0, .w = 20, .h = 12 },
            .radius_px = 4,
            .center = .{ 34, 6 },
            .radius = 12,
            .inner_color = .{ 1, 1, 1, 1 },
            .outer_color = .{ 0, 0, 0, 1 },
            .layer = 0,
        } },
        .{ .sweep_gradient_rect = .{
            .rect = .{ .x = 48, .y = 0, .w = 20, .h = 12 },
            .radius = 4,
            .center = .{ 58, 6 },
            .start_angle = 0,
            .start_color = .{ 1, 0, 0, 1 },
            .end_color = .{ 0, 1, 0, 1 },
            .layer = 0,
        } },
    }, emptyTextProvider());

    try std.testing.expect(scene.vertices.items.len > 18);
    try std.testing.expectEqual(@as(usize, 0), scene.line_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.shape, scene.batches.items[0].kind);
}

test "window gpu rounded rect commands use paint-quad SDF path" {
    var scene = try ImmediateScene.init(std.testing.allocator, 64, 64, 16, 16);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    try scene.pushDrawList(&.{
        .{ .rounded_rect = .{
            .rect = .{ .x = 1, .y = 2, .w = 10, .h = 8 },
            .radius = 3,
            .color = .{ 1, 0, 0, 1 },
            .layer = 0,
        } },
        .{ .stroke_rounded_rect = .{
            .rect = .{ .x = 14, .y = 2, .w = 10, .h = 8 },
            .radius = 3,
            .thickness = 1.5,
            .color = .{ 0, 1, 0, 1 },
            .layer = 0,
        } },
    }, emptyTextProvider());

    try std.testing.expectEqual(@as(usize, 0), scene.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 0), scene.line_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), scene.paint_quad_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.paint_quad, scene.batches.items[0].kind);
    try std.testing.expectEqual(@as(f32, 3), scene.paint_quad_vertices.items[0].radius);
    try std.testing.expectEqual(@as(f32, 1.5), scene.paint_quad_vertices.items[6].border_width);
}

test "window gpu dashed lines preserve gaps before batching" {
    var scene = try ImmediateScene.init(std.testing.allocator, 512, 16, 16, 64);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    try scene.pushDrawList(&.{.{ .styled_line = .{
        .a = .{ 0.0, 0.0 },
        .b = .{ 10.0, 0.0 },
        .style = .{ .width = 1.5, .dash = window.DashPattern.fromPair(2.0, 2.0, 0.0), .quality = .fast },
        .color = .{ 1.0, 0.0, 0.0, 1.0 },
        .layer = 0,
    } }}, emptyTextProvider());

    try std.testing.expectEqual(@as(usize, 0), scene.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 18), scene.line_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.line_aa, scene.batches.items[0].kind);
}

test "window gpu stroked closed primitives use continuous feathered mesh" {
    var scene = try ImmediateScene.init(std.testing.allocator, 2048, 16, 16, 256);
    defer scene.deinit();
    try scene.beginFrame(&.{});

    try scene.pushDrawList(&.{
        .{ .stroke_ellipse = .{
            .center = .{ 16.0, 16.0 },
            .radius = .{ 8.0, 6.0 },
            .thickness = 1.5,
            .color = .{ 1.0, 0.0, 0.0, 1.0 },
            .layer = 0,
        } },
        .{ .stroke_rounded_rect = .{
            .rect = .{ .x = 24.0, .y = 8.0, .w = 24.0, .h = 16.0 },
            .radius = 4.0,
            .thickness = 1.5,
            .color = .{ 0.0, 1.0, 0.0, 1.0 },
            .layer = 0,
        } },
    }, emptyTextProvider());

    try std.testing.expect(scene.vertices.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), scene.line_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.batches.items.len);
    try std.testing.expectEqual(BatchKind.shape, scene.batches.items[0].kind);
}
