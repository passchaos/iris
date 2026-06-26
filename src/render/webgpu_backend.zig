const std = @import("std");
const gpu = @import("gpu.zig");
const profiler = @import("profiler.zig");
const build_options = @import("iris_build_options");
const zgpu = if (build_options.enable_zgpu_backend) @import("zgpu") else struct {};
const zgpu_wgpu = if (build_options.enable_zgpu_backend) zgpu.wgpu else struct {
    pub const BufferMapAsyncStatus = enum(u32) {
        success,
        validation_error,
    };
    pub const BufferUsage = packed struct(u32) {
        map_read: bool = false,
        map_write: bool = false,
        copy_src: bool = false,
        copy_dst: bool = false,
        index: bool = false,
        vertex: bool = false,
        uniform: bool = false,
        storage: bool = false,
        indirect: bool = false,
        query_resolve: bool = false,
        _padding: u22 = 0,
    };
    pub const LoadOp = enum(u32) {
        undef,
        clear,
        load,
    };
    pub const StoreOp = enum(u32) {
        undef,
        store,
        discard,
    };
    pub const ShaderModule = *opaque {};
    pub const CommandEncoder = *opaque {};
    pub const RenderPassEncoder = *opaque {};
    pub const Texture = *opaque {};
    pub const TextureView = *opaque {};
    pub const TextureAspect = enum(u32) {
        all,
    };
    pub const ImageCopyTexture = extern struct {
        texture: Texture,
        mip_level: u32 = 0,
        origin: Origin3D = .{},
        aspect: TextureAspect = .all,
    };
    pub const TextureDataLayout = extern struct {
        offset: u64 = 0,
        bytes_per_row: u32 = 0,
        rows_per_image: u32 = 0,
    };
    pub const Origin3D = extern struct {
        x: u32 = 0,
        y: u32 = 0,
        z: u32 = 0,
    };
    pub const Extent3D = extern struct {
        width: u32 = 1,
        height: u32 = 1,
        depth_or_array_layers: u32 = 1,
    };
    pub const CompareFunction = enum(u32) {
        always,
        less,
    };
    pub const StencilFaceState = extern struct {
        compare: CompareFunction = .always,
    };
    pub const DepthStencilState = extern struct {
        format: TextureFormat,
        depth_write_enabled: bool = false,
        depth_compare: CompareFunction = .always,
        stencil_front: StencilFaceState = .{},
        stencil_back: StencilFaceState = .{},
        stencil_read_mask: u32 = 0xffff_ffff,
        stencil_write_mask: u32 = 0xffff_ffff,
        depth_bias: i32 = 0,
        depth_bias_slope_scale: f32 = 0.0,
        depth_bias_clamp: f32 = 0.0,
    };
    pub const Color = extern struct {
        r: f64,
        g: f64,
        b: f64,
        a: f64,
    };
    const U32Bool = enum(u32) {
        false = 0,
        true = 1,
    };
    pub const RenderPassColorAttachment = extern struct {
        view: ?TextureView,
        resolve_target: ?TextureView = null,
        load_op: LoadOp,
        store_op: StoreOp,
        clear_value: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
    };
    pub const RenderPassDepthStencilAttachment = extern struct {
        view: TextureView,
        depth_load_op: LoadOp = .undef,
        depth_store_op: StoreOp = .undef,
        depth_clear_value: f32 = 0.0,
        depth_read_only: U32Bool = .false,
        stencil_load_op: LoadOp = .undef,
        stencil_store_op: StoreOp = .undef,
        stencil_clear_value: u32 = 0,
        stencil_read_only: U32Bool = .false,
    };
    pub const TextureFormat = enum(u32) {
        rgba8_unorm,
        bgra8_unorm,
        depth32_float,
    };
    pub const VertexFormat = enum(u32) {
        float32,
        float32x2,
        float32x4,
    };
    pub const VertexStepMode = enum(u32) {
        vertex,
    };
    pub const VertexAttribute = extern struct {
        format: VertexFormat,
        offset: u64 = 0,
        shader_location: u32 = 0,
    };
    pub const VertexBufferLayout = extern struct {
        array_stride: u64 = 0,
        step_mode: VertexStepMode = .vertex,
        attribute_count: usize = 0,
        attributes: [*]const VertexAttribute,
    };
    pub const BlendOperation = enum(u32) {
        add,
    };
    pub const BlendFactor = enum(u32) {
        one,
        src_alpha,
        one_minus_src_alpha,
    };
    pub const BlendComponent = extern struct {
        operation: BlendOperation = .add,
        src_factor: BlendFactor = .one,
        dst_factor: BlendFactor = .one_minus_src_alpha,
    };
    pub const BlendState = extern struct {
        color: BlendComponent = .{},
        alpha: BlendComponent = .{},
    };
    pub const ColorWriteMask = enum(u32) {
        all,
    };
    pub const ColorTargetState = extern struct {
        format: TextureFormat,
        blend: ?*const BlendState = null,
        write_mask: ColorWriteMask = .all,
    };
    pub const FragmentState = extern struct {
        module: ShaderModule,
        entry_point: [*:0]const u8,
        target_count: usize = 0,
        targets: [*]const ColorTargetState,
    };
};
const IrisColor = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const Scene2D = @import("scene2d.zig").Scene2D;
const Scene3D = @import("scene3d.zig").Scene3D;

const render_strips_wgsl =
    \\@group(0) @binding(0) var<storage, read> strips: array<u32>;
    \\@group(0) @binding(1) var target_tex: texture_storage_2d<rgba8unorm, write>;
    \\
    \\fn unpack_color(rgba: u32) -> vec4<f32> {
    \\    let r = f32(rgba & 0xffu) / 255.0;
    \\    let g = f32((rgba >> 8u) & 0xffu) / 255.0;
    \\    let b = f32((rgba >> 16u) & 0xffu) / 255.0;
    \\    let a = f32((rgba >> 24u) & 0xffu) / 255.0;
    \\    return vec4<f32>(r, g, b, a);
    \\}
    \\
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    \\    let strip_ix = gid.x * 3u;
    \\    if (strip_ix + 2u >= arrayLength(&strips)) {
    \\        return;
    \\    }
    \\
    \\    let xy = strips[strip_ix];
    \\    let x0 = xy & 0xffffu;
    \\    let y = (xy >> 16u) & 0xffffu;
    \\    let width = strips[strip_ix + 1u] & 0xffffu;
    \\    let color = unpack_color(strips[strip_ix + 2u]);
    \\
    \\    var x = 0u;
    \\    loop {
    \\        if (x >= width) {
    \\            break;
    \\        }
    \\        textureStore(target_tex, vec2<i32>(i32(x0 + x), i32(y)), color);
    \\        x = x + 1u;
    \\    }
    \\}
;

pub const WebGpuBackend = struct {
    context: ?*GraphicsContext = null,
    strips_pipeline: ?StripsPipeline = null,
    triangles_pipeline: ?TrianglesPipeline = null,
    owned_target: ?Texture = null,
    target_view: ?TextureView = null,
    external_target_view: ?RawTextureView = null,
    owns_external_target_view: bool = false,
    owned_msaa_target: ?Texture = null,
    msaa_target_view: ?TextureView = null,
    owned_depth: ?Texture = null,
    depth_view: ?TextureView = null,
    external_depth_view: ?RawTextureView = null,
    owns_external_depth_view: bool = false,
    target_format: wgpu.TextureFormat = .rgba8_unorm,
    depth_format: wgpu.TextureFormat = .depth32_float,
    triangles_pipeline_format: ?wgpu.TextureFormat = null,
    target_width: u32 = 0,
    target_height: u32 = 0,
    depth_width: u32 = 0,
    depth_height: u32 = 0,
    readback_buffer: ?Buffer = null,
    readback_bytes_per_row: u32 = 0,
    readback_size: u64 = 0,
    readback_map_status: ReadbackMapStatus = .idle,
    strips_buffer: ?Buffer = null,
    strips_capacity: usize = 0,
    strips_bind_group: ?BindGroup = null,
    strips_bindings: ?StripsBufferBindings = null,
    triangles_buffer: ?Buffer = null,
    triangles_capacity: usize = 0,
    textures_buffer: ?Buffer = null,
    textures_capacity: usize = 0,
    texture_pixels_buffer: ?Buffer = null,
    texture_pixels_capacity: usize = 0,
    lights_buffer: ?Buffer = null,
    lights_capacity: usize = 0,
    lighting_buffer: ?Buffer = null,
    lighting_capacity: usize = 0,
    triangles_bind_group: ?BindGroup = null,
    triangles_bindings: ?BatchBufferBindings = null,
    submitted_empty_batches: usize = 0,
    pass_options: RenderPassOptions = .{},
    target_options: TargetOptions = .{},
    profiler: ?*profiler.GpuProfiler = null,

    pub const compiled_with_zgpu = build_options.enable_zgpu_backend;
    pub const available = false;
    pub const implementation = "zgpu";
    pub const dependency_url = "https://github.com/zig-gamedev/zgpu";
    pub const wgpu = zgpu_wgpu;
    pub const GraphicsContext = if (compiled_with_zgpu) zgpu.GraphicsContext else opaque {};
    pub const RenderContext = GraphicsContext;
    pub const GraphicsContextOptions = if (compiled_with_zgpu) zgpu.GraphicsContextOptions else struct {};
    pub const WindowProvider = if (compiled_with_zgpu) zgpu.WindowProvider else struct {
        window: *anyopaque,
        fn_getTime: *const fn () f64,
        fn_getFramebufferSize: *const fn (window: *const anyopaque) [2]u32,
        fn_getWin32Window: *const fn (window: *const anyopaque) callconv(.c) *anyopaque = undefined,
        fn_getX11Display: *const fn () callconv(.c) *anyopaque = undefined,
        fn_getX11Window: *const fn (window: *const anyopaque) callconv(.c) u32 = undefined,
        fn_getWaylandDisplay: ?*const fn () callconv(.c) *anyopaque = null,
        fn_getWaylandSurface: ?*const fn (window: *const anyopaque) callconv(.c) *anyopaque = null,
        fn_getCocoaWindow: *const fn (window: *const anyopaque) callconv(.c) ?*anyopaque = undefined,
    };
    pub const Buffer = if (compiled_with_zgpu) zgpu.BufferHandle else *opaque {};
    pub const BufferHandle = Buffer;
    pub const BindGroup = if (compiled_with_zgpu) zgpu.BindGroupHandle else *opaque {};
    pub const BindGroupHandle = BindGroup;
    pub const Texture = if (compiled_with_zgpu) zgpu.TextureHandle else *opaque {};
    pub const TextureHandle = Texture;
    pub const TextureView = if (compiled_with_zgpu) zgpu.TextureViewHandle else *opaque {};
    pub const TextureViewHandle = TextureView;
    pub const SamplerHandle = if (compiled_with_zgpu) zgpu.SamplerHandle else *opaque {};
    pub const RenderPipelineHandle = if (compiled_with_zgpu) zgpu.RenderPipelineHandle else *opaque {};
    pub const ComputePipelineHandle = if (compiled_with_zgpu) zgpu.ComputePipelineHandle else *opaque {};
    pub const BindGroupLayoutHandle = if (compiled_with_zgpu) zgpu.BindGroupLayoutHandle else *opaque {};
    pub const PipelineLayoutHandle = if (compiled_with_zgpu) zgpu.PipelineLayoutHandle else *opaque {};
    pub const RawTextureView = if (compiled_with_zgpu) zgpu.wgpu.TextureView else *opaque {};
    pub const default_target_format = if (compiled_with_zgpu) zgpu.GraphicsContext.swapchain_format else wgpu.TextureFormat.bgra8_unorm;
    pub const PresentStatus = if (compiled_with_zgpu) enum {
        normal_execution,
        swap_chain_resized,
    } else enum {
        normal_execution,
        swap_chain_resized,
    };
    pub const StripsPipeline = if (compiled_with_zgpu) struct {
        bind_group_layout: zgpu.BindGroupLayoutHandle,
        pipeline_layout: zgpu.PipelineLayoutHandle,
        pipeline: zgpu.ComputePipelineHandle,
    } else struct {};
    pub const TrianglesPipeline = if (compiled_with_zgpu) struct {
        bind_group_layout: zgpu.BindGroupLayoutHandle,
        pipeline_layout: zgpu.PipelineLayoutHandle,
        pipeline: zgpu.RenderPipelineHandle,
    } else struct {};
    pub const ReadbackMapStatus = enum {
        idle,
        pending,
        success,
        failed,
    };
    pub const RenderPassOptions = struct {
        color_load_op: wgpu.LoadOp = .clear,
        color_store_op: wgpu.StoreOp = .store,
        color_clear: wgpu.Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
        depth_load_op: wgpu.LoadOp = .clear,
        depth_store_op: wgpu.StoreOp = .store,
        depth_clear: f32 = 1.0,
    };
    pub const TargetOptions = struct {
        color_format: wgpu.TextureFormat = .rgba8_unorm,
        depth_format: wgpu.TextureFormat = .depth32_float,
        sample_count: u32 = 1,
    };
    pub const StripsBufferBindings = struct {
        strips: Buffer,
        strips_size: u64,
        target: TextureView,
    };
    pub const BatchBufferBindings = struct {
        triangles: Buffer,
        triangles_size: u64,
        textures: Buffer,
        textures_size: u64,
        texture_pixels: Buffer,
        texture_pixels_size: u64,
        lights: Buffer,
        lights_size: u64,
        lighting: Buffer,
        lighting_size: u64,
    };

    pub fn init(context: *GraphicsContext) WebGpuBackend {
        return .{ .context = context };
    }

    pub fn createGraphicsContext(allocator: std.mem.Allocator, provider: WindowProvider, options: GraphicsContextOptions) !*GraphicsContext {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        return try zgpu.GraphicsContext.create(allocator, provider, options);
    }

    pub fn syncSwapchainToWindow(gctx: *GraphicsContext) bool {
        if (comptime !compiled_with_zgpu) return false;
        const fb_size = gctx.window_provider.fn_getFramebufferSize(gctx.window_provider.window);
        if (fb_size[0] == 0 or fb_size[1] == 0) return false;
        if (gctx.swapchain_descriptor.width == fb_size[0] and gctx.swapchain_descriptor.height == fb_size[1]) return false;

        gctx.swapchain_descriptor.width = @intCast(fb_size[0]);
        gctx.swapchain_descriptor.height = @intCast(fb_size[1]);
        gctx.swapchain.release();
        gctx.swapchain = gctx.device.createSwapChain(gctx.surface, gctx.swapchain_descriptor);
        std.log.info(
            "[zgpu] Window has been resized to: {d}x{d}.",
            .{ gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height },
        );
        return true;
    }

    pub fn createWgslShaderModule(device: anytype, source: [*:0]const u8, label: ?[*:0]const u8) wgpu.ShaderModule {
        if (!compiled_with_zgpu) @compileError("createWgslShaderModule requires -Denable-zgpu-backend=true");
        return zgpu.createWgslShaderModule(device, source, label);
    }

    pub fn beginRenderPassSimple(
        encoder: anytype,
        load_op: wgpu.LoadOp,
        color_texv: anytype,
        clear_color: ?wgpu.Color,
        depth_texv: ?RawTextureView,
        clear_depth: ?f32,
    ) wgpu.RenderPassEncoder {
        if (!compiled_with_zgpu) @compileError("beginRenderPassSimple requires -Denable-zgpu-backend=true");
        return zgpu.beginRenderPassSimple(encoder, load_op, color_texv, clear_color, depth_texv, clear_depth);
    }

    pub fn endReleasePass(pass: anytype) void {
        if (!compiled_with_zgpu) @compileError("endReleasePass requires -Denable-zgpu-backend=true");
        zgpu.endReleasePass(pass);
    }

    pub fn deinit(self: *WebGpuBackend) void {
        self.clearReadback();
        self.clearBatchBuffers();
        self.clearTarget();
        self.clearPipelines();
        self.context = null;
        self.submitted_empty_batches = 0;
        self.profiler = null;
    }

    pub fn setProfiler(self: *WebGpuBackend, value: ?*profiler.GpuProfiler) void {
        self.profiler = value;
    }

    pub fn recordTimingSample(self: *WebGpuBackend, label: []const u8, elapsed_ns: u64) !void {
        const target = self.profiler orelse return;
        try target.record(label, elapsed_ns);
    }

    pub fn initStripsPipeline(self: *WebGpuBackend) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        self.clearTrianglesBindGroup();
        const bind_group_layout = webgpu_context.createBindGroupLayout(&.{
            zgpu.bufferEntry(gpu.ShaderContract.strips_binding, .{ .compute = true }, .read_only_storage, false, @sizeOf(gpu.GpuStrip)),
            zgpu.storageTextureEntry(gpu.ShaderContract.target_binding, .{ .compute = true }, .write_only, .rgba8_unorm, .tvdim_2d),
        });
        const pipeline_layout = webgpu_context.createPipelineLayout(&.{bind_group_layout});
        const shader = zgpu.createWgslShaderModule(webgpu_context.device, render_strips_wgsl, "iris_render_strips");
        defer shader.release();
        const pipeline = webgpu_context.createComputePipeline(pipeline_layout, .{
            .compute = .{
                .module = shader,
                .entry_point = "main",
            },
        });
        self.strips_pipeline = .{
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
        };
    }

    pub fn initTrianglesPipelineFromSource(self: *WebGpuBackend, shader_source: [:0]const u8) !void {
        try self.initTrianglesPipelineFromSourceAndFormat(shader_source, self.target_options.color_format);
    }

    pub fn initTrianglesPipelineFromSourceAndFormat(self: *WebGpuBackend, shader_source: [:0]const u8, target_format: wgpu.TextureFormat) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        const bind_group_layout = webgpu_context.createBindGroupLayout(&.{
            zgpu.bufferEntry(gpu.ShaderContract.triangles_binding, .{ .vertex = true, .fragment = true }, .read_only_storage, false, @sizeOf(gpu.GpuTriangle)),
            zgpu.bufferEntry(gpu.ShaderContract.textures_binding, .{ .fragment = true }, .read_only_storage, false, @sizeOf(gpu.GpuTexture)),
            zgpu.bufferEntry(gpu.ShaderContract.texture_pixels_binding, .{ .fragment = true }, .read_only_storage, false, 4),
            zgpu.bufferEntry(gpu.ShaderContract.lights_binding, .{ .fragment = true }, .read_only_storage, false, @sizeOf(gpu.GpuLight)),
            zgpu.bufferEntry(gpu.ShaderContract.lighting_enabled_binding, .{ .fragment = true }, .uniform, false, 4),
        });
        const pipeline_layout = webgpu_context.createPipelineLayout(&.{bind_group_layout});
        const shader = zgpu.createWgslShaderModule(webgpu_context.device, shader_source, "iris_render_triangles");
        defer shader.release();
        const color_targets = [_]zgpu_wgpu.ColorTargetState{.{ .format = target_format }};
        const fragment = zgpu_wgpu.FragmentState{
            .module = shader,
            .entry_point = "fragment_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        };
        const depth_stencil = zgpu_wgpu.DepthStencilState{
            .format = self.target_options.depth_format,
            .depth_write_enabled = true,
            .depth_compare = .less,
        };
        const pipeline = webgpu_context.createRenderPipeline(pipeline_layout, .{
            .vertex = .{
                .module = shader,
                .entry_point = "vertex_main",
            },
            .primitive = .{ .topology = .triangle_list },
            .depth_stencil = &depth_stencil,
            .multisample = .{ .count = self.target_options.sample_count },
            .fragment = &fragment,
        });
        self.triangles_pipeline = .{
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
        };
        self.triangles_pipeline_format = target_format;
    }

    pub fn setTargetView(self: *WebGpuBackend, target_view: TextureView, width: u32, height: u32) void {
        self.setTargetViewWithFormat(target_view, width, height, self.target_options.color_format);
    }

    pub fn setTargetViewWithFormat(self: *WebGpuBackend, target_view: TextureView, width: u32, height: u32, format: wgpu.TextureFormat) void {
        self.clearStripsBindGroup();
        self.releaseExternalTargetViews();
        self.target_view = target_view;
        self.external_target_view = null;
        self.owns_external_target_view = false;
        self.target_format = format;
        self.target_width = width;
        self.target_height = height;
    }

    pub fn setExternalTargetViewWithFormat(self: *WebGpuBackend, target_view: RawTextureView, width: u32, height: u32, format: wgpu.TextureFormat) void {
        self.setExternalTargetViewWithFormatOwned(target_view, width, height, format, false);
    }

    fn setExternalTargetViewWithFormatOwned(self: *WebGpuBackend, target_view: RawTextureView, width: u32, height: u32, format: wgpu.TextureFormat, owned: bool) void {
        self.clearStripsBindGroup();
        if (self.external_target_view == null or !rawTextureViewsEqual(self.external_target_view.?, target_view)) self.releaseExternalTargetView();
        self.target_view = null;
        self.external_target_view = target_view;
        self.owns_external_target_view = owned;
        self.target_format = format;
        self.target_width = width;
        self.target_height = height;
    }

    pub fn setDepthView(self: *WebGpuBackend, depth_view: TextureView) void {
        self.setDepthViewWithFormat(depth_view, self.target_options.depth_format);
    }

    pub fn setDepthViewWithFormat(self: *WebGpuBackend, depth_view: TextureView, format: wgpu.TextureFormat) void {
        self.setDepthViewWithFormatAndSize(depth_view, format, self.target_width, self.target_height);
    }

    pub fn setDepthViewWithFormatAndSize(self: *WebGpuBackend, depth_view: TextureView, format: wgpu.TextureFormat, width: u32, height: u32) void {
        self.releaseExternalDepthView();
        self.depth_view = depth_view;
        self.external_depth_view = null;
        self.owns_external_depth_view = false;
        self.depth_format = format;
        self.depth_width = width;
        self.depth_height = height;
    }

    pub fn setExternalDepthViewWithFormat(self: *WebGpuBackend, depth_view: RawTextureView, format: wgpu.TextureFormat) void {
        self.setExternalDepthViewWithFormatAndSize(depth_view, format, self.target_width, self.target_height);
    }

    pub fn setExternalDepthViewWithFormatAndSize(self: *WebGpuBackend, depth_view: RawTextureView, format: wgpu.TextureFormat, width: u32, height: u32) void {
        self.setExternalDepthViewWithFormatOwned(depth_view, format, width, height, false);
    }

    fn setExternalDepthViewWithFormatOwned(self: *WebGpuBackend, depth_view: RawTextureView, format: wgpu.TextureFormat, width: u32, height: u32, owned: bool) void {
        if (self.external_depth_view == null or !rawTextureViewsEqual(self.external_depth_view.?, depth_view)) self.releaseExternalDepthView();
        self.depth_view = null;
        self.external_depth_view = depth_view;
        self.owns_external_depth_view = owned;
        self.depth_format = format;
        self.depth_width = width;
        self.depth_height = height;
    }

    pub fn acquireSwapchainTarget(self: *WebGpuBackend) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        const view = webgpu_context.swapchain.getCurrentTextureView();
        self.setExternalTargetViewWithFormatOwned(
            view,
            webgpu_context.swapchain_descriptor.width,
            webgpu_context.swapchain_descriptor.height,
            GraphicsContext.swapchain_format,
            true,
        );
    }

    pub fn releaseExternalTargetViews(self: *WebGpuBackend) void {
        self.releaseExternalTargetView();
        self.releaseExternalDepthView();
    }

    pub fn ensureDepthTargetForCurrentTarget(self: *WebGpuBackend) !void {
        if (self.target_width == 0 or self.target_height == 0) return error.BackendUnavailable;
        if (self.owned_depth != null and self.depth_width == self.target_width and self.depth_height == self.target_height and self.depth_format == self.target_options.depth_format) return;
        try self.createOwnedDepthTarget(self.target_width, self.target_height);
    }

    pub fn ensureMsaaTargetForCurrentTarget(self: *WebGpuBackend) !void {
        if (self.target_options.sample_count <= 1) {
            self.clearMsaaTarget();
            return;
        }
        if (self.target_width == 0 or self.target_height == 0) return error.BackendUnavailable;
        if (self.owned_msaa_target != null and self.msaa_target_view != null) return;
        try self.createOwnedMsaaTarget(self.target_width, self.target_height);
    }

    pub fn present(self: *WebGpuBackend) !PresentStatus {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        self.releaseExternalTargetViews();
        const status = webgpu_context.present();
        return switch (status) {
            .normal_execution => .normal_execution,
            .swap_chain_resized => .swap_chain_resized,
        };
    }

    pub fn setTargetOptions(self: *WebGpuBackend, options: TargetOptions) void {
        self.target_options = options;
    }

    pub fn resetTargetOptions(self: *WebGpuBackend) void {
        self.target_options = .{};
    }

    pub fn setRenderPassOptions(self: *WebGpuBackend, options: RenderPassOptions) void {
        self.pass_options = options;
    }

    pub fn resetRenderPassOptions(self: *WebGpuBackend) void {
        self.pass_options = .{};
    }

    fn releaseExternalTargetView(self: *WebGpuBackend) void {
        if (compiled_with_zgpu and self.owns_external_target_view) {
            if (self.external_target_view) |view| view.release();
        }
        self.external_target_view = null;
        self.owns_external_target_view = false;
    }

    fn releaseExternalDepthView(self: *WebGpuBackend) void {
        if (compiled_with_zgpu and self.owns_external_depth_view) {
            if (self.external_depth_view) |view| view.release();
        }
        self.external_depth_view = null;
        self.owns_external_depth_view = false;
    }

    pub fn createOwnedTarget(self: *WebGpuBackend, width: u32, height: u32) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        self.clearReadback();
        self.clearTarget();
        const texture = webgpu_context.createTexture(.{
            .usage = .{ .storage_binding = true, .copy_src = true, .copy_dst = true, .render_attachment = true },
            .dimension = .tdim_2d,
            .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
            .format = self.target_options.color_format,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const view = webgpu_context.createTextureView(texture, .{
            .format = self.target_options.color_format,
            .dimension = .tvdim_2d,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
        });
        self.owned_target = texture;
        self.setTargetViewWithFormat(view, width, height, self.target_options.color_format);
        try self.createOwnedDepthTarget(width, height);
    }

    pub fn createOwnedDepthTarget(self: *WebGpuBackend, width: u32, height: u32) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        self.clearDepth();
        const texture = webgpu_context.createTexture(.{
            .usage = .{ .render_attachment = true },
            .dimension = .tdim_2d,
            .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
            .format = self.target_options.depth_format,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const view = webgpu_context.createTextureView(texture, .{
            .format = self.target_options.depth_format,
            .dimension = .tvdim_2d,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
        });
        self.owned_depth = texture;
        self.setDepthViewWithFormatAndSize(view, self.target_options.depth_format, width, height);
    }

    pub fn createOwnedMsaaTarget(self: *WebGpuBackend, width: u32, height: u32) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        if (self.target_options.sample_count <= 1) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        self.clearMsaaTarget();
        const texture = webgpu_context.createTexture(.{
            .usage = .{ .render_attachment = true },
            .dimension = .tdim_2d,
            .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
            .format = self.target_format,
            .mip_level_count = 1,
            .sample_count = self.target_options.sample_count,
        });
        const view = webgpu_context.createTextureView(texture, .{
            .format = self.target_format,
            .dimension = .tvdim_2d,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
        });
        self.owned_msaa_target = texture;
        self.msaa_target_view = view;
    }

    pub fn clearTarget(self: *WebGpuBackend) void {
        self.clearMsaaTarget();
        self.clearDepth();
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.target_view) |view| webgpu_context.releaseResource(view);
                if (self.owned_target) |texture| webgpu_context.releaseResource(texture);
            }
        }
        self.owned_target = null;
        self.target_view = null;
        self.external_target_view = null;
        self.owns_external_target_view = false;
        self.target_format = .rgba8_unorm;
        self.target_width = 0;
        self.target_height = 0;
    }

    pub fn clearMsaaTarget(self: *WebGpuBackend) void {
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.msaa_target_view) |view| webgpu_context.releaseResource(view);
                if (self.owned_msaa_target) |texture| webgpu_context.releaseResource(texture);
            }
        }
        self.msaa_target_view = null;
        self.owned_msaa_target = null;
    }

    pub fn clearDepth(self: *WebGpuBackend) void {
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.depth_view) |view| webgpu_context.releaseResource(view);
                if (self.owned_depth) |texture| webgpu_context.releaseResource(texture);
            }
        }
        self.owned_depth = null;
        self.depth_view = null;
        self.external_depth_view = null;
        self.owns_external_depth_view = false;
        self.depth_format = .depth32_float;
        self.depth_width = 0;
        self.depth_height = 0;
    }

    pub fn createReadbackBuffer(self: *WebGpuBackend) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        if (self.owned_target == null or self.target_width == 0 or self.target_height == 0) return error.BackendUnavailable;
        self.clearReadback();
        const bytes_per_row = alignedBytesPerRow(self.target_width);
        const size = @as(u64, bytes_per_row) * self.target_height;
        const buffer = webgpu_context.createBuffer(.{
            .usage = .{ .copy_dst = true, .map_read = true },
            .size = size,
        });
        self.readback_buffer = buffer;
        self.readback_bytes_per_row = bytes_per_row;
        self.readback_size = size;
    }

    pub fn clearReadback(self: *WebGpuBackend) void {
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.readback_buffer) |buffer| webgpu_context.releaseResource(buffer);
            }
        }
        self.readback_buffer = null;
        self.readback_bytes_per_row = 0;
        self.readback_size = 0;
        self.readback_map_status = .idle;
    }

    pub fn clearBatchBuffers(self: *WebGpuBackend) void {
        self.clearStripsBindGroup();
        self.clearTrianglesBindGroup();
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.strips_buffer) |buffer| webgpu_context.releaseResource(buffer);
                if (self.triangles_buffer) |buffer| webgpu_context.releaseResource(buffer);
                if (self.textures_buffer) |buffer| webgpu_context.releaseResource(buffer);
                if (self.texture_pixels_buffer) |buffer| webgpu_context.releaseResource(buffer);
                if (self.lights_buffer) |buffer| webgpu_context.releaseResource(buffer);
                if (self.lighting_buffer) |buffer| webgpu_context.releaseResource(buffer);
            }
        }
        self.strips_buffer = null;
        self.strips_capacity = 0;
        self.triangles_buffer = null;
        self.triangles_capacity = 0;
        self.textures_buffer = null;
        self.textures_capacity = 0;
        self.texture_pixels_buffer = null;
        self.texture_pixels_capacity = 0;
        self.lights_buffer = null;
        self.lights_capacity = 0;
        self.lighting_buffer = null;
        self.lighting_capacity = 0;
    }

    pub fn clearStripsBindGroup(self: *WebGpuBackend) void {
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.strips_bind_group) |bind_group| webgpu_context.releaseResource(bind_group);
            }
        }
        self.strips_bind_group = null;
        self.strips_bindings = null;
    }

    pub fn clearTrianglesBindGroup(self: *WebGpuBackend) void {
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.triangles_bind_group) |bind_group| webgpu_context.releaseResource(bind_group);
            }
        }
        self.triangles_bind_group = null;
        self.triangles_bindings = null;
    }

    pub fn copyTargetToReadback(self: *WebGpuBackend) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        const texture = self.owned_target orelse return error.BackendUnavailable;
        const buffer = self.readback_buffer orelse return error.BackendUnavailable;
        const encoder = webgpu_context.device.createCommandEncoder(null);
        defer encoder.release();
        encoder.copyTextureToBuffer(
            .{ .texture = webgpu_context.lookupResource(texture).? },
            .{
                .buffer = webgpu_context.lookupResource(buffer).?,
                .layout = .{
                    .offset = 0,
                    .bytes_per_row = self.readback_bytes_per_row,
                    .rows_per_image = self.target_height,
                },
            },
            .{ .width = self.target_width, .height = self.target_height, .depth_or_array_layers = 1 },
        );
        const command_buffer = encoder.finish(null);
        defer command_buffer.release();
        webgpu_context.submit(&.{command_buffer});
    }

    pub fn beginReadbackMap(self: *WebGpuBackend) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        const buffer = self.readback_buffer orelse return error.BackendUnavailable;
        const gpu_buffer = webgpu_context.lookupResource(buffer).?;
        self.readback_map_status = .pending;
        gpu_buffer.mapAsync(.{ .read = true }, 0, @intCast(self.readback_size), readbackMapCallback, self);
    }

    pub fn readbackStatus(self: *const WebGpuBackend) ReadbackMapStatus {
        return self.readback_map_status;
    }

    pub fn pollReadback(self: *WebGpuBackend) !ReadbackMapStatus {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        webgpu_context.device.tick();
        return self.readback_map_status;
    }

    pub fn waitForReadback(self: *WebGpuBackend, max_ticks: usize) !ReadbackMapStatus {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        var ticks: usize = 0;
        while (ticks < max_ticks) : (ticks += 1) {
            const status = try self.pollReadback();
            switch (status) {
                .pending => {},
                else => return status,
            }
        }
        return self.readback_map_status;
    }

    pub fn mappedReadbackBytes(self: *WebGpuBackend) ?[]const u8 {
        if (!compiled_with_zgpu or self.readback_map_status != .success) return null;
        const webgpu_context = self.context orelse return null;
        const buffer = self.readback_buffer orelse return null;
        const gpu_buffer = webgpu_context.lookupResource(buffer).?;
        return gpu_buffer.getConstMappedRange(u8, 0, @intCast(self.readback_size));
    }

    pub fn copyMappedReadbackToImage(self: *WebGpuBackend, image: *Image) !void {
        const bytes = self.mappedReadbackBytes() orelse return error.BackendUnavailable;
        try copyReadbackRowsToImage(bytes, self.target_width, self.target_height, self.readback_bytes_per_row, image);
    }

    pub fn unmapReadback(self: *WebGpuBackend) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        const buffer = self.readback_buffer orelse return error.BackendUnavailable;
        const gpu_buffer = webgpu_context.lookupResource(buffer).?;
        gpu_buffer.unmap();
        self.readback_map_status = .idle;
    }

    pub fn unmapReadbackForTest(self: *WebGpuBackend) void {
        self.readback_map_status = .idle;
    }

    pub fn render2DToReadback(self: *WebGpuBackend, command: gpu.GpuCommand, batch: *const gpu.GpuBatch) !void {
        if (command.kind != .render_2d) return error.BackendUnsupportedFeature;
        if (!self.hasReadbackTarget()) return error.BackendUnavailable;
        if (command.target_width != self.target_width or command.target_height != self.target_height) return error.BackendTargetMismatch;
        try self.validate2DTargetFormat();
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        try render2DToReadbackEnabled(self, batch);
    }

    pub fn render3DToReadback(self: *WebGpuBackend, command: gpu.GpuCommand, batch: *const gpu.GpuBatch) !void {
        if (command.kind != .render_3d) return error.BackendUnsupportedFeature;
        if (!self.hasReadbackTarget()) return error.BackendUnavailable;
        if (command.target_width != self.target_width or command.target_height != self.target_height) return error.BackendTargetMismatch;
        try self.validate3DTargetFormat();
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        try render3DToReadbackEnabled(self, batch);
    }

    pub fn renderScene2DToReadback(self: *WebGpuBackend, allocator: @import("std").mem.Allocator, scene: *const Scene2D) !void {
        var batch: gpu.GpuBatch = .{};
        defer batch.deinit(allocator);
        try batch.build2DFromScene(allocator, scene, self.target_width, self.target_height);
        try self.render2DToReadback(.{
            .kind = .render_2d,
            .primitive_count = scene.primitives.items.len,
            .target_width = self.target_width,
            .target_height = self.target_height,
        }, &batch);
    }

    pub fn renderScene3DToReadback(self: *WebGpuBackend, allocator: @import("std").mem.Allocator, scene: *const Scene3D) !void {
        var batch: gpu.GpuBatch = .{};
        defer batch.deinit(allocator);
        try batch.build3DFromScene(allocator, scene);
        try self.render3DToReadback(.{
            .kind = .render_3d,
            .primitive_count = scene.triangles.items.len,
            .target_width = self.target_width,
            .target_height = self.target_height,
        }, &batch);
    }

    pub fn renderScene3DToCurrentSwapchain(self: *WebGpuBackend, allocator: @import("std").mem.Allocator, scene: *const Scene3D) !PresentStatus {
        try self.acquireSwapchainTarget();
        errdefer self.releaseExternalTargetViews();
        try self.ensureDepthTargetForCurrentTarget();
        try self.ensureMsaaTargetForCurrentTarget();
        var batch: gpu.GpuBatch = .{};
        defer batch.deinit(allocator);
        try batch.build3DFromScene(allocator, scene);
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        try self.validate3DTargetFormat();
        try self.submit3DTriangles(webgpu_context, &batch);
        return try self.present();
    }

    fn render2DToReadbackEnabled(self: *WebGpuBackend, batch: *const gpu.GpuBatch) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        try self.submit2DStrips(webgpu_context, batch);
        try self.copyTargetToReadback();
        try self.beginReadbackMap();
    }

    fn render3DToReadbackEnabled(self: *WebGpuBackend, batch: *const gpu.GpuBatch) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        try self.submit3DTriangles(webgpu_context, batch);
        try self.copyTargetToReadback();
        try self.beginReadbackMap();
    }

    fn readbackMapCallback(status: zgpu_wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
        const self: *WebGpuBackend = @ptrCast(@alignCast(userdata.?));
        self.readback_map_status = if (status == .success) .success else .failed;
    }

    pub fn readyFor2D(self: *const WebGpuBackend) bool {
        return compiled_with_zgpu and self.context != null and self.strips_pipeline != null and self.target_view != null and self.external_target_view == null and self.target_format == .rgba8_unorm and self.target_width > 0 and self.target_height > 0;
    }

    pub fn readyFor3DPipeline(self: *const WebGpuBackend) bool {
        return compiled_with_zgpu and self.context != null and self.triangles_pipeline != null and self.triangles_pipeline_format == self.target_format and self.hasColorTargetView() and self.hasMsaaTargetIfNeeded() and self.hasDepthTargetView() and self.depth_format == self.target_options.depth_format and self.depth_width == self.target_width and self.depth_height == self.target_height and self.target_width > 0 and self.target_height > 0;
    }

    pub fn hasReadbackTarget(self: *const WebGpuBackend) bool {
        return compiled_with_zgpu and self.owned_target != null and self.readback_buffer != null and self.readback_size > 0;
    }

    pub fn capabilities() gpu.BackendCapabilities {
        return .{
            .render_2d = false,
            .render_3d = false,
            .point_cloud_3d = false,
            .line_3d = false,
            .textured_3d = false,
            .normal_mapped_3d = false,
            .lit_3d = false,
        };
    }

    pub fn activeCapabilities(self: *const WebGpuBackend) gpu.BackendCapabilities {
        const ready_3d = self.readyFor3DPipeline();
        return .{
            .render_2d = self.readyFor2D(),
            .render_3d = ready_3d,
            .point_cloud_3d = false,
            .line_3d = false,
            .textured_3d = ready_3d,
            .normal_mapped_3d = ready_3d,
            .lit_3d = ready_3d,
        };
    }

    fn unavailableCapabilities() gpu.BackendCapabilities {
        return .{
            .render_2d = false,
            .render_3d = false,
            .point_cloud_3d = false,
            .line_3d = false,
            .textured_3d = false,
            .normal_mapped_3d = false,
            .lit_3d = false,
        };
    }

    pub fn clearPipelines(self: *WebGpuBackend) void {
        self.clearStripsBindGroup();
        self.clearTrianglesBindGroup();
        if (compiled_with_zgpu) {
            if (self.context) |webgpu_context| {
                if (self.strips_pipeline) |pipeline| {
                    webgpu_context.releaseResource(pipeline.pipeline);
                    webgpu_context.releaseResource(pipeline.pipeline_layout);
                    webgpu_context.releaseResource(pipeline.bind_group_layout);
                }
                if (self.triangles_pipeline) |pipeline| {
                    webgpu_context.releaseResource(pipeline.pipeline);
                    webgpu_context.releaseResource(pipeline.pipeline_layout);
                    webgpu_context.releaseResource(pipeline.bind_group_layout);
                }
            }
        }
        self.strips_pipeline = null;
        self.triangles_pipeline = null;
        self.triangles_pipeline_format = null;
    }

    pub fn backend(self: *WebGpuBackend) gpu.Backend {
        if (self.context == null) return .{
            .context = undefined,
            .submitFn = submitUnavailable,
            .capabilities = unavailableCapabilities(),
        };
        return .{
            .context = self,
            .submitFn = submit,
            .capabilities = self.activeCapabilities(),
        };
    }

    pub fn installOnDevice(self: *WebGpuBackend, device: *gpu.GpuDevice) void {
        device.setBackend(self.backend());
    }

    fn submit(context: *anyopaque, command: gpu.GpuCommand, batch: *const gpu.GpuBatch) !void {
        const self: *WebGpuBackend = @ptrCast(@alignCast(context));
        const webgpu_context = self.context orelse return error.BackendUnavailable;
        if (compiled_with_zgpu and command.kind == .render_2d and batch.strips.items.len > 0) {
            if (command.target_width != self.target_width or command.target_height != self.target_height) {
                return error.BackendTargetMismatch;
            }
            try self.validate2DTargetFormat();
            try self.submit2DStrips(webgpu_context, batch);
            return;
        }
        if (compiled_with_zgpu and command.kind == .render_3d and batch.triangles.items.len > 0) {
            if (command.target_width != self.target_width or command.target_height != self.target_height) {
                return error.BackendTargetMismatch;
            }
            try self.validate3DTargetFormat();
            try self.submit3DTriangles(webgpu_context, batch);
            return;
        }
        if (!batchEmpty(command, batch)) return error.BackendUnsupportedFeature;
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        webgpu_context.submit(&.{});
        self.submitted_empty_batches += 1;
    }

    fn submit2DStrips(self: *WebGpuBackend, webgpu_context: *GraphicsContext, batch: *const gpu.GpuBatch) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        if (!self.readyFor2D()) return error.BackendUnavailable;
        const pipeline = self.strips_pipeline.?;
        const target_view = self.target_view.?;

        const strips_buffer = try self.uploadStripsBuffer(webgpu_context, batch.strips.items);
        const bindings = StripsBufferBindings{
            .strips = strips_buffer,
            .strips_size = @as(u64, @intCast(batch.strips.items.len * @sizeOf(gpu.GpuStrip))),
            .target = target_view,
        };
        const bind_group = try self.stripsBindGroup(webgpu_context, pipeline, bindings);

        const encoder = webgpu_context.device.createCommandEncoder(null);
        defer encoder.release();
        const pass = encoder.beginComputePass(null);
        pass.setPipeline(webgpu_context.lookupResource(pipeline.pipeline).?);
        pass.setBindGroup(0, webgpu_context.lookupResource(bind_group).?, null);
        pass.dispatchWorkgroups(@intCast((batch.strips.items.len + 63) / 64), 1, 1);
        pass.end();
        pass.release();

        const command_buffer = encoder.finish(null);
        defer command_buffer.release();
        webgpu_context.submit(&.{command_buffer});
    }

    fn uploadStripsBuffer(self: *WebGpuBackend, webgpu_context: *GraphicsContext, items: []const gpu.GpuStrip) !Buffer {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const required = bufferElementCapacity(items.len);
        if (self.strips_buffer == null or self.strips_capacity < required) {
            self.clearStripsBindGroup();
            if (self.strips_buffer) |old| webgpu_context.releaseResource(old);
            self.strips_buffer = webgpu_context.createBuffer(.{
                .usage = .{ .storage = true, .copy_dst = true },
                .size = @intCast(required * @sizeOf(gpu.GpuStrip)),
            });
            self.strips_capacity = required;
        }
        const handle = self.strips_buffer.?;
        if (items.len > 0) {
            webgpu_context.queue.writeBuffer(webgpu_context.lookupResource(handle).?, 0, gpu.GpuStrip, items);
        }
        return handle;
    }

    fn stripsBindGroup(self: *WebGpuBackend, webgpu_context: *GraphicsContext, pipeline: StripsPipeline, bindings: StripsBufferBindings) !BindGroup {
        if (self.strips_bind_group) |bind_group| {
            if (self.strips_bindings) |existing| {
                if (stripsBufferBindingsEqual(existing, bindings)) return bind_group;
            }
            self.clearStripsBindGroup();
        }

        const bind_group = webgpu_context.createBindGroup(pipeline.bind_group_layout, &.{
            .{
                .binding = gpu.ShaderContract.strips_binding,
                .buffer_handle = bindings.strips,
                .offset = 0,
                .size = bindings.strips_size,
            },
            .{
                .binding = gpu.ShaderContract.target_binding,
                .texture_view_handle = bindings.target,
            },
        });
        self.strips_bind_group = bind_group;
        self.strips_bindings = bindings;
        return bind_group;
    }

    fn submit3DTriangles(self: *WebGpuBackend, webgpu_context: *GraphicsContext, batch: *const gpu.GpuBatch) !void {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        if (!self.readyFor3DPipeline()) return error.BackendUnavailable;
        const pipeline = self.triangles_pipeline.?;
        const target_view = self.lookupColorTargetView(webgpu_context) orelse return error.BackendUnavailable;
        const render_target_view = self.lookupRenderColorTargetView(webgpu_context) orelse return error.BackendUnavailable;
        const depth_view = self.lookupDepthTargetView(webgpu_context) orelse return error.BackendUnavailable;

        const triangles_buffer = try self.uploadStorageBuffer(webgpu_context, gpu.GpuTriangle, &self.triangles_buffer, &self.triangles_capacity, batch.triangles.items);
        const textures_buffer = try self.uploadStorageBuffer(webgpu_context, gpu.GpuTexture, &self.textures_buffer, &self.textures_capacity, batch.textures.items);
        const texture_pixels_buffer = try self.uploadStorageBuffer(webgpu_context, u32, &self.texture_pixels_buffer, &self.texture_pixels_capacity, batch.texture_pixels.items);
        const lights_buffer = try self.uploadStorageBuffer(webgpu_context, gpu.GpuLight, &self.lights_buffer, &self.lights_capacity, batch.lights.items);
        const lighting_enabled_value = [_]u32{if (batch.lighting_enabled) 1 else 0};
        const lighting_buffer = try self.uploadUniformBuffer(webgpu_context, u32, &self.lighting_buffer, &self.lighting_capacity, &lighting_enabled_value);

        const bindings = BatchBufferBindings{
            .triangles = triangles_buffer,
            .triangles_size = @as(u64, @intCast(batch.triangles.items.len * @sizeOf(gpu.GpuTriangle))),
            .textures = textures_buffer,
            .textures_size = bindingSize(gpu.GpuTexture, batch.textures.items.len),
            .texture_pixels = texture_pixels_buffer,
            .texture_pixels_size = bindingSize(u32, batch.texture_pixels.items.len),
            .lights = lights_buffer,
            .lights_size = bindingSize(gpu.GpuLight, batch.lights.items.len),
            .lighting = lighting_buffer,
            .lighting_size = @sizeOf(u32),
        };
        const bind_group = try self.trianglesBindGroup(webgpu_context, pipeline, bindings);

        const encoder = webgpu_context.device.createCommandEncoder(null);
        defer encoder.release();
        const pass_options = self.pass_options;
        const color_attachments = [_]zgpu_wgpu.RenderPassColorAttachment{.{
            .view = render_target_view,
            .resolve_target = if (self.target_options.sample_count > 1) target_view else null,
            .load_op = pass_options.color_load_op,
            .store_op = pass_options.color_store_op,
            .clear_value = pass_options.color_clear,
        }};
        const depth_attachment = zgpu_wgpu.RenderPassDepthStencilAttachment{
            .view = depth_view,
            .depth_load_op = pass_options.depth_load_op,
            .depth_store_op = pass_options.depth_store_op,
            .depth_clear_value = pass_options.depth_clear,
        };
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
            .depth_stencil_attachment = &depth_attachment,
        });
        pass.setPipeline(webgpu_context.lookupResource(pipeline.pipeline).?);
        pass.setBindGroup(0, webgpu_context.lookupResource(bind_group).?, null);
        pass.draw(@intCast(batch.triangles.items.len * 3), 1, 0, 0);
        pass.end();
        pass.release();

        const command_buffer = encoder.finish(null);
        defer command_buffer.release();
        webgpu_context.submit(&.{command_buffer});
    }

    fn trianglesBindGroup(self: *WebGpuBackend, webgpu_context: *GraphicsContext, pipeline: TrianglesPipeline, bindings: BatchBufferBindings) !BindGroup {
        if (self.triangles_bind_group) |bind_group| {
            if (self.triangles_bindings) |existing| {
                if (batchBufferBindingsEqual(existing, bindings)) return bind_group;
            }
            self.clearTrianglesBindGroup();
        }

        const bind_group = webgpu_context.createBindGroup(pipeline.bind_group_layout, &.{
            .{
                .binding = gpu.ShaderContract.triangles_binding,
                .buffer_handle = bindings.triangles,
                .offset = 0,
                .size = bindings.triangles_size,
            },
            .{
                .binding = gpu.ShaderContract.textures_binding,
                .buffer_handle = bindings.textures,
                .offset = 0,
                .size = bindings.textures_size,
            },
            .{
                .binding = gpu.ShaderContract.texture_pixels_binding,
                .buffer_handle = bindings.texture_pixels,
                .offset = 0,
                .size = bindings.texture_pixels_size,
            },
            .{
                .binding = gpu.ShaderContract.lights_binding,
                .buffer_handle = bindings.lights,
                .offset = 0,
                .size = bindings.lights_size,
            },
            .{
                .binding = gpu.ShaderContract.lighting_enabled_binding,
                .buffer_handle = bindings.lighting,
                .offset = 0,
                .size = bindings.lighting_size,
            },
        });
        self.triangles_bind_group = bind_group;
        self.triangles_bindings = bindings;
        return bind_group;
    }

    fn uploadStorageBuffer(self: *WebGpuBackend, webgpu_context: *GraphicsContext, comptime T: type, slot: *?Buffer, capacity: *usize, items: []const T) !Buffer {
        return try self.uploadBuffer(webgpu_context, T, slot, capacity, items, .{ .storage = true, .copy_dst = true });
    }

    fn uploadUniformBuffer(self: *WebGpuBackend, webgpu_context: *GraphicsContext, comptime T: type, slot: *?Buffer, capacity: *usize, items: []const T) !Buffer {
        return try self.uploadBuffer(webgpu_context, T, slot, capacity, items, .{ .uniform = true, .copy_dst = true });
    }

    fn uploadBuffer(self: *WebGpuBackend, webgpu_context: *GraphicsContext, comptime T: type, slot: *?Buffer, capacity: *usize, items: []const T, usage: zgpu_wgpu.BufferUsage) !Buffer {
        if (!compiled_with_zgpu) return error.BackendUnavailable;
        const required = bufferElementCapacity(items.len);
        if (slot.* == null or capacity.* < required) {
            self.clearTrianglesBindGroup();
            if (slot.*) |old| webgpu_context.releaseResource(old);
            slot.* = webgpu_context.createBuffer(.{
                .usage = usage,
                .size = @intCast(required * @sizeOf(T)),
            });
            capacity.* = required;
        }
        const handle = slot.*.?;
        if (items.len > 0) {
            webgpu_context.queue.writeBuffer(webgpu_context.lookupResource(handle).?, 0, T, items);
        }
        return handle;
    }

    fn bufferElementCapacity(len: usize) usize {
        return @max(len, 1);
    }

    fn bindingSize(comptime T: type, len: usize) u64 {
        return @intCast(@max(len, 1) * @sizeOf(T));
    }

    fn stripsBufferBindingsEqual(a: StripsBufferBindings, b: StripsBufferBindings) bool {
        return bufferHandlesEqual(a.strips, b.strips) and
            a.strips_size == b.strips_size and
            textureViewHandlesEqual(a.target, b.target);
    }

    fn batchBufferBindingsEqual(a: BatchBufferBindings, b: BatchBufferBindings) bool {
        return bufferHandlesEqual(a.triangles, b.triangles) and
            a.triangles_size == b.triangles_size and
            bufferHandlesEqual(a.textures, b.textures) and
            a.textures_size == b.textures_size and
            bufferHandlesEqual(a.texture_pixels, b.texture_pixels) and
            a.texture_pixels_size == b.texture_pixels_size and
            bufferHandlesEqual(a.lights, b.lights) and
            a.lights_size == b.lights_size and
            bufferHandlesEqual(a.lighting, b.lighting) and
            a.lighting_size == b.lighting_size;
    }

    fn bufferHandlesEqual(a: Buffer, b: Buffer) bool {
        if (compiled_with_zgpu) return a.id == b.id;
        return a == b;
    }

    fn textureViewHandlesEqual(a: TextureView, b: TextureView) bool {
        if (compiled_with_zgpu) return a.id == b.id;
        return a == b;
    }

    fn rawTextureViewsEqual(a: RawTextureView, b: RawTextureView) bool {
        return a == b;
    }

    fn batchEmpty(command: gpu.GpuCommand, batch: *const gpu.GpuBatch) bool {
        return switch (command.kind) {
            .render_2d => batch.strips.items.len == 0,
            .render_3d => batch.triangles.items.len == 0,
        };
    }

    pub fn submitEmptyForTest(self: *WebGpuBackend, command: gpu.GpuCommand, batch: *const gpu.GpuBatch) !void {
        if (self.context == null) return error.BackendUnavailable;
        if (!batchEmpty(command, batch)) return error.BackendUnsupportedFeature;
        self.submitted_empty_batches += 1;
    }

    pub fn submitUnsupportedForTest(self: *WebGpuBackend, command: gpu.GpuCommand, batch: *const gpu.GpuBatch) !void {
        return submit(self, command, batch);
    }

    pub fn validateTargetForTest(self: *const WebGpuBackend, command: gpu.GpuCommand) !void {
        if (command.target_width != self.target_width or command.target_height != self.target_height) {
            return error.BackendTargetMismatch;
        }
    }

    fn validate2DTargetFormat(self: *const WebGpuBackend) !void {
        if (self.target_format != .rgba8_unorm) return error.BackendTargetFormatMismatch;
    }

    fn validate3DTargetFormat(self: *const WebGpuBackend) !void {
        if (self.triangles_pipeline_format) |pipeline_format| {
            if (pipeline_format != self.target_format) return error.BackendTargetFormatMismatch;
        }
        if (self.depth_format != self.target_options.depth_format) return error.BackendTargetFormatMismatch;
        if (self.depth_width != self.target_width or self.depth_height != self.target_height) return error.BackendTargetMismatch;
    }

    fn submitUnavailable(_: *anyopaque, _: gpu.GpuCommand, _: *const gpu.GpuBatch) !void {
        return error.BackendUnavailable;
    }

    fn hasColorTargetView(self: *const WebGpuBackend) bool {
        return self.target_view != null or self.external_target_view != null;
    }

    fn hasDepthTargetView(self: *const WebGpuBackend) bool {
        return self.depth_view != null or self.external_depth_view != null;
    }

    fn hasMsaaTargetIfNeeded(self: *const WebGpuBackend) bool {
        return self.target_options.sample_count <= 1 or self.msaa_target_view != null;
    }

    fn lookupColorTargetView(self: *const WebGpuBackend, webgpu_context: *GraphicsContext) ?RawTextureView {
        if (!compiled_with_zgpu) return null;
        if (self.external_target_view) |view| return view;
        if (self.target_view) |view| return webgpu_context.lookupResource(view);
        return null;
    }

    fn lookupRenderColorTargetView(self: *const WebGpuBackend, webgpu_context: *GraphicsContext) ?RawTextureView {
        if (!compiled_with_zgpu) return null;
        if (self.target_options.sample_count > 1) {
            if (self.msaa_target_view) |view| return webgpu_context.lookupResource(view);
            return null;
        }
        return self.lookupColorTargetView(webgpu_context);
    }

    fn lookupDepthTargetView(self: *const WebGpuBackend, webgpu_context: *GraphicsContext) ?RawTextureView {
        if (!compiled_with_zgpu) return null;
        if (self.external_depth_view) |view| return view;
        if (self.depth_view) |view| return webgpu_context.lookupResource(view);
        return null;
    }

    fn alignedBytesPerRow(width: u32) u32 {
        return @intCast((@as(usize, width) * 4 + 255) & ~@as(usize, 255));
    }

    fn copyReadbackRowsToImage(bytes: []const u8, width: u32, height: u32, bytes_per_row: u32, image: *Image) !void {
        if (image.width != width or image.height != height) return error.BackendTargetMismatch;
        if (bytes_per_row < width * 4) return error.BackendTargetMismatch;
        const required = @as(usize, bytes_per_row) * height;
        if (bytes.len < required) return error.BackendTargetMismatch;

        var y: u32 = 0;
        while (y < height) : (y += 1) {
            const row_start = @as(usize, bytes_per_row) * y;
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const i = row_start + @as(usize, x) * 4;
                image.writePixel(x, y, IrisColor.rgba(bytes[i + 0], bytes[i + 1], bytes[i + 2], bytes[i + 3]));
            }
        }
    }
};

test "WebGPU backend documents zgpu integration point" {
    try @import("std").testing.expect(!WebGpuBackend.available);
    try @import("std").testing.expectEqualStrings("zgpu", WebGpuBackend.implementation);
    try @import("std").testing.expectEqualStrings("https://github.com/zig-gamedev/zgpu", WebGpuBackend.dependency_url);
    try @import("std").testing.expect(!WebGpuBackend.capabilities().render_2d);
    try @import("std").testing.expect(!WebGpuBackend.capabilities().render_3d);
}

test "WebGPU backend compile flag controls zgpu import" {
    if (build_options.enable_zgpu_backend) {
        try @import("std").testing.expect(WebGpuBackend.compiled_with_zgpu);
        try @import("std").testing.expect(@hasDecl(WebGpuBackend.wgpu, "TextureFormat"));
    } else {
        try @import("std").testing.expect(!WebGpuBackend.compiled_with_zgpu);
    }
}

test "WebGPU backend without context is unavailable" {
    var backend = WebGpuBackend{};
    const value = backend.backend();
    try @import("std").testing.expect(!value.capabilities.render_2d);
    try @import("std").testing.expect(!value.capabilities.render_3d);
}

test "WebGPU backend can report timing samples through profiler hook" {
    const allocator = @import("std").testing.allocator;
    var timings = profiler.GpuProfiler.init(allocator);
    defer timings.deinit();
    var backend = WebGpuBackend{};

    try backend.recordTimingSample("ignored", 5);
    backend.setProfiler(&timings);
    try backend.recordTimingSample("webgpu.render3d", 42);

    try @import("std").testing.expectEqual(@as(usize, 1), timings.samples.items.len);
    try @import("std").testing.expectEqualStrings("webgpu.render3d", timings.samples.items[0].label);
    try @import("std").testing.expectEqual(@as(u64, 42), timings.debugDump().total_ns);

    backend.deinit();
    try @import("std").testing.expect(backend.profiler == null);
}

test "WebGPU backend cleanup resets public state without context" {
    var backend = WebGpuBackend{};
    backend.target_width = 16;
    backend.target_height = 8;
    backend.readback_bytes_per_row = 256;
    backend.readback_size = 2048;
    backend.readback_map_status = .success;

    backend.clearReadback();
    try @import("std").testing.expectEqual(@as(u32, 0), backend.readback_bytes_per_row);
    try @import("std").testing.expectEqual(@as(u64, 0), backend.readback_size);
    try @import("std").testing.expectEqual(WebGpuBackend.ReadbackMapStatus.idle, backend.readbackStatus());

    backend.triangles_capacity = 4;
    backend.strips_capacity = 5;
    backend.textures_capacity = 3;
    backend.texture_pixels_capacity = 2;
    backend.lights_capacity = 1;
    backend.lighting_capacity = 1;
    backend.triangles_bindings = null;
    backend.clearBatchBuffers();
    try @import("std").testing.expectEqual(@as(usize, 0), backend.strips_capacity);
    try @import("std").testing.expectEqual(@as(usize, 0), backend.triangles_capacity);
    try @import("std").testing.expectEqual(@as(usize, 0), backend.textures_capacity);
    try @import("std").testing.expectEqual(@as(usize, 0), backend.texture_pixels_capacity);
    try @import("std").testing.expectEqual(@as(usize, 0), backend.lights_capacity);
    try @import("std").testing.expectEqual(@as(usize, 0), backend.lighting_capacity);
    try @import("std").testing.expect(backend.triangles_bind_group == null);
    try @import("std").testing.expect(backend.triangles_bindings == null);
    try @import("std").testing.expect(backend.strips_bind_group == null);
    try @import("std").testing.expect(backend.strips_bindings == null);

    backend.clearTarget();
    try @import("std").testing.expectEqual(@as(u32, 0), backend.target_width);
    try @import("std").testing.expectEqual(@as(u32, 0), backend.target_height);
    try @import("std").testing.expect(backend.msaa_target_view == null);
    try @import("std").testing.expect(backend.owned_msaa_target == null);
    try @import("std").testing.expectEqual(@as(u32, 0), backend.depth_width);
    try @import("std").testing.expectEqual(@as(u32, 0), backend.depth_height);
    try @import("std").testing.expect(backend.depth_view == null);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.rgba8_unorm, backend.target_format);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.depth32_float, backend.depth_format);

    backend.deinit();
    try @import("std").testing.expect(backend.context == null);
    try @import("std").testing.expect(!backend.readyFor2D());
}

test "WebGPU render pass options can be configured and reset" {
    var backend = WebGpuBackend{};
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.LoadOp.clear, backend.pass_options.color_load_op);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.StoreOp.store, backend.pass_options.depth_store_op);
    try @import("std").testing.expectEqual(@as(f32, 1.0), backend.pass_options.depth_clear);

    backend.setRenderPassOptions(.{
        .color_load_op = .load,
        .color_store_op = .store,
        .color_clear = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1.0 },
        .depth_load_op = .load,
        .depth_store_op = .discard,
        .depth_clear = 0.5,
    });
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.LoadOp.load, backend.pass_options.color_load_op);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.StoreOp.discard, backend.pass_options.depth_store_op);
    try @import("std").testing.expectEqual(@as(f32, 0.5), backend.pass_options.depth_clear);

    backend.resetRenderPassOptions();
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.LoadOp.clear, backend.pass_options.color_load_op);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.StoreOp.store, backend.pass_options.depth_store_op);
    try @import("std").testing.expectEqual(@as(f32, 1.0), backend.pass_options.depth_clear);
}

test "WebGPU depth target ensure requires a bound target" {
    var backend = WebGpuBackend{};
    try @import("std").testing.expectError(error.BackendUnavailable, backend.ensureDepthTargetForCurrentTarget());
}

test "WebGPU target options can be configured and reset" {
    var backend = WebGpuBackend{};
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.rgba8_unorm, backend.target_options.color_format);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.depth32_float, backend.target_options.depth_format);
    try @import("std").testing.expectEqual(@as(u32, 1), backend.target_options.sample_count);

    backend.setTargetOptions(.{
        .color_format = .bgra8_unorm,
        .depth_format = .depth32_float,
        .sample_count = 4,
    });
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.bgra8_unorm, backend.target_options.color_format);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.depth32_float, backend.target_options.depth_format);
    try @import("std").testing.expectEqual(@as(u32, 4), backend.target_options.sample_count);

    backend.resetTargetOptions();
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.rgba8_unorm, backend.target_options.color_format);
    try @import("std").testing.expectEqual(WebGpuBackend.wgpu.TextureFormat.depth32_float, backend.target_options.depth_format);
    try @import("std").testing.expectEqual(@as(u32, 1), backend.target_options.sample_count);
}

test "WebGPU strips pipeline requires compiled zgpu context" {
    var backend = WebGpuBackend{};
    try @import("std").testing.expectError(error.BackendUnavailable, backend.initStripsPipeline());
    try @import("std").testing.expectError(error.BackendUnavailable, backend.initTrianglesPipelineFromSource(""));
    try @import("std").testing.expectError(error.BackendUnavailable, backend.initTrianglesPipelineFromSourceAndFormat("", .rgba8_unorm));
    try @import("std").testing.expectError(error.BackendUnavailable, backend.createOwnedTarget(1, 1));
    try @import("std").testing.expectError(error.BackendUnavailable, backend.createReadbackBuffer());
    try @import("std").testing.expectError(error.BackendUnavailable, backend.copyTargetToReadback());
    try @import("std").testing.expectError(error.BackendUnavailable, backend.beginReadbackMap());
    try @import("std").testing.expectError(error.BackendUnavailable, backend.unmapReadback());
    try @import("std").testing.expectEqual(WebGpuBackend.ReadbackMapStatus.idle, backend.readbackStatus());
    try @import("std").testing.expect(!backend.readyFor2D());
    try @import("std").testing.expect(!backend.hasReadbackTarget());
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
}

test "WebGPU render2DToReadback requires readback target and 2D command" {
    var backend = WebGpuBackend{};
    var batch = gpu.GpuBatch{};
    try @import("std").testing.expectError(error.BackendUnsupportedFeature, backend.render2DToReadback(.{ .kind = .render_3d, .primitive_count = 0, .target_width = 1, .target_height = 1 }, &batch));
    try @import("std").testing.expectError(error.BackendUnavailable, backend.render2DToReadback(.{ .kind = .render_2d, .primitive_count = 0, .target_width = 1, .target_height = 1 }, &batch));
}

test "WebGPU render3DToReadback requires readback target and 3D command" {
    var backend = WebGpuBackend{};
    var batch = gpu.GpuBatch{};
    try @import("std").testing.expectError(error.BackendUnsupportedFeature, backend.render3DToReadback(.{ .kind = .render_2d, .primitive_count = 0, .target_width = 1, .target_height = 1 }, &batch));
    try @import("std").testing.expectError(error.BackendUnavailable, backend.render3DToReadback(.{ .kind = .render_3d, .primitive_count = 0, .target_width = 1, .target_height = 1 }, &batch));
}

test "WebGPU renderScene2DToReadback builds batches for callers" {
    const allocator = @import("std").testing.allocator;
    var backend = WebGpuBackend{};
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);
    try @import("std").testing.expectError(error.BackendUnavailable, backend.renderScene2DToReadback(allocator, &scene));
}

test "WebGPU renderScene3DToReadback builds batches for callers" {
    const allocator = @import("std").testing.allocator;
    var backend = WebGpuBackend{};
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .white });
    try @import("std").testing.expectError(error.BackendUnavailable, backend.renderScene3DToReadback(allocator, &scene));
}

test "WebGPU renderScene3DToCurrentSwapchain requires compiled context" {
    const allocator = @import("std").testing.allocator;
    var backend = WebGpuBackend{};
    var scene = Scene3D.init(allocator);
    defer scene.deinit();
    try scene.addTriangle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .white });
    try @import("std").testing.expectError(error.BackendUnavailable, backend.renderScene3DToCurrentSwapchain(allocator, &scene));
}

test "WebGPU backend submit boundary accepts empty batches only with context" {
    if (!WebGpuBackend.compiled_with_zgpu) return;

    var backend = WebGpuBackend{ .context = @ptrFromInt(@alignOf(WebGpuBackend.GraphicsContext)) };
    var empty = gpu.GpuBatch{};
    try backend.submitEmptyForTest(.{ .kind = .render_3d, .primitive_count = 0, .target_width = 1, .target_height = 1 }, &empty);
    try @import("std").testing.expectEqual(@as(usize, 1), backend.submitted_empty_batches);

    try empty.triangles.append(@import("std").testing.allocator, .{
        .a = .{ .x = 0, .y = 0, .z = 0, .rgba = 0 },
        .b = .{ .x = 0, .y = 0, .z = 0, .rgba = 0 },
        .c = .{ .x = 0, .y = 0, .z = 0, .rgba = 0 },
    });
    defer empty.deinit(@import("std").testing.allocator);
    try @import("std").testing.expectError(error.BackendTargetMismatch, backend.submitUnsupportedForTest(.{ .kind = .render_3d, .primitive_count = 1, .target_width = 1, .target_height = 1 }, &empty));
    backend.target_width = 1;
    backend.target_height = 1;
    try @import("std").testing.expectError(error.BackendTargetMismatch, backend.submitUnsupportedForTest(.{ .kind = .render_3d, .primitive_count = 1, .target_width = 1, .target_height = 1 }, &empty));
    backend.depth_width = 1;
    backend.depth_height = 1;
    try @import("std").testing.expectError(error.BackendUnavailable, backend.submitUnsupportedForTest(.{ .kind = .render_3d, .primitive_count = 1, .target_width = 1, .target_height = 1 }, &empty));
}

test "WebGPU backend tracks target view prerequisite" {
    if (!WebGpuBackend.compiled_with_zgpu) return;

    var backend = WebGpuBackend{ .context = @ptrFromInt(@alignOf(WebGpuBackend.GraphicsContext)) };
    try @import("std").testing.expect(!backend.readyFor2D());
    backend.strips_pipeline = .{
        .bind_group_layout = .{ .id = 1 },
        .pipeline_layout = .{ .id = 1 },
        .pipeline = .{ .id = 1 },
    };
    try @import("std").testing.expect(!backend.readyFor2D());
    backend.setTargetView(.{ .id = 1 }, 16, 8);
    try @import("std").testing.expect(backend.readyFor2D());
    try @import("std").testing.expect(backend.activeCapabilities().render_2d);
    try @import("std").testing.expect(!backend.activeCapabilities().render_3d);
    backend.setTargetViewWithFormat(.{ .id = 2 }, 16, 8, .bgra8_unorm);
    try @import("std").testing.expect(!backend.readyFor2D());
    try @import("std").testing.expectError(error.BackendTargetFormatMismatch, backend.validate2DTargetFormat());
    backend.setTargetView(.{ .id = 1 }, 16, 8);
    try @import("std").testing.expect(backend.readyFor2D());
    try backend.validate2DTargetFormat();
    var device = gpu.GpuDevice.init(@import("std").testing.allocator, .none);
    defer device.deinit();
    backend.installOnDevice(&device);
    try @import("std").testing.expect(device.isAvailable());
    const allocator = @import("std").testing.allocator;
    var scene2 = Scene2D.init(allocator);
    defer scene2.deinit();
    try scene2.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);
    var scene3 = Scene3D.init(allocator);
    defer scene3.deinit();
    try scene3.addTriangle(.{ .positions = .{ .{}, .{ .x = 1 }, .{ .y = 1 } }, .color = .white });
    var image = try Image.init(allocator, 16, 8, .transparent);
    defer image.deinit();
    try @import("std").testing.expect(device.canAccept2D(&scene2, &image));
    try @import("std").testing.expect(!device.canAccept3D(&scene3, &image));
    try backend.validateTargetForTest(.{ .kind = .render_2d, .primitive_count = 0, .target_width = 16, .target_height = 8 });
    try @import("std").testing.expectError(error.BackendTargetMismatch, backend.validateTargetForTest(.{ .kind = .render_2d, .primitive_count = 0, .target_width = 8, .target_height = 16 }));
}

test "WebGPU backend tracks 3D pipeline prerequisite" {
    if (!WebGpuBackend.compiled_with_zgpu) return;

    var backend = WebGpuBackend{ .context = @ptrFromInt(@alignOf(WebGpuBackend.GraphicsContext)) };
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    backend.triangles_pipeline = .{
        .bind_group_layout = .{ .id = 1 },
        .pipeline_layout = .{ .id = 1 },
        .pipeline = .{ .id = 1 },
    };
    backend.triangles_pipeline_format = .rgba8_unorm;
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    backend.setTargetView(.{ .id = 1 }, 16, 8);
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    backend.setDepthView(.{ .id = 1 });
    try @import("std").testing.expectEqual(@as(u32, 16), backend.depth_width);
    try @import("std").testing.expectEqual(@as(u32, 8), backend.depth_height);
    try @import("std").testing.expect(backend.readyFor3DPipeline());
    try @import("std").testing.expect(backend.activeCapabilities().render_3d);
    try @import("std").testing.expect(backend.activeCapabilities().textured_3d);
    try @import("std").testing.expect(backend.activeCapabilities().normal_mapped_3d);
    try @import("std").testing.expect(backend.activeCapabilities().lit_3d);
    backend.setTargetViewWithFormat(.{ .id = 2 }, 16, 8, .bgra8_unorm);
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    try @import("std").testing.expectError(error.BackendTargetFormatMismatch, backend.validate3DTargetFormat());
    backend.triangles_pipeline_format = .bgra8_unorm;
    try @import("std").testing.expect(backend.readyFor3DPipeline());
    try backend.validate3DTargetFormat();
    backend.target_options.sample_count = 4;
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    backend.msaa_target_view = .{ .id = 3 };
    try @import("std").testing.expect(backend.readyFor3DPipeline());
    backend.target_options.sample_count = 1;
    backend.msaa_target_view = null;
    backend.setExternalTargetViewWithFormat(@ptrFromInt(1), 16, 8, .bgra8_unorm);
    backend.setExternalDepthViewWithFormatAndSize(@ptrFromInt(2), .depth32_float, 16, 7);
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    try @import("std").testing.expectError(error.BackendTargetMismatch, backend.validate3DTargetFormat());
    backend.setExternalDepthViewWithFormat(@ptrFromInt(2), .depth32_float);
    try @import("std").testing.expect(backend.readyFor3DPipeline());
    try @import("std").testing.expect(!backend.readyFor2D());
    backend.releaseExternalTargetViews();
    try @import("std").testing.expect(backend.external_target_view == null);
    try @import("std").testing.expect(backend.external_depth_view == null);
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    backend.context = null;
    backend.clearDepth();
    try @import("std").testing.expect(!backend.readyFor3DPipeline());
    try @import("std").testing.expect(!backend.activeCapabilities().render_3d);
}

test "WebGPU backend computes padded readback row sizes" {
    try @import("std").testing.expectEqual(@as(u32, 256), WebGpuBackend.alignedBytesPerRow(1));
    try @import("std").testing.expectEqual(@as(u32, 256), WebGpuBackend.alignedBytesPerRow(64));
    try @import("std").testing.expectEqual(@as(u32, 512), WebGpuBackend.alignedBytesPerRow(65));
}

test "WebGPU backend computes reusable upload buffer capacities" {
    try @import("std").testing.expectEqual(@as(usize, 1), WebGpuBackend.bufferElementCapacity(0));
    try @import("std").testing.expectEqual(@as(usize, 1), WebGpuBackend.bufferElementCapacity(1));
    try @import("std").testing.expectEqual(@as(usize, 7), WebGpuBackend.bufferElementCapacity(7));
}

test "WebGPU backend compares cached 3D bind group signatures" {
    if (!WebGpuBackend.compiled_with_zgpu) return;

    const a = WebGpuBackend.BatchBufferBindings{
        .triangles = .{ .id = 1 },
        .triangles_size = 12,
        .textures = .{ .id = 2 },
        .textures_size = 4,
        .texture_pixels = .{ .id = 3 },
        .texture_pixels_size = 4,
        .lights = .{ .id = 4 },
        .lights_size = 4,
        .lighting = .{ .id = 5 },
        .lighting_size = 4,
    };
    try @import("std").testing.expect(WebGpuBackend.batchBufferBindingsEqual(a, a));
    var b = a;
    b.triangles_size += 1;
    try @import("std").testing.expect(!WebGpuBackend.batchBufferBindingsEqual(a, b));
    b = a;
    b.texture_pixels = .{ .id = 99 };
    try @import("std").testing.expect(!WebGpuBackend.batchBufferBindingsEqual(a, b));
}

test "WebGPU backend compares cached 2D bind group signatures" {
    if (!WebGpuBackend.compiled_with_zgpu) return;

    const a = WebGpuBackend.StripsBufferBindings{
        .strips = .{ .id = 1 },
        .strips_size = 12,
        .target = .{ .id = 2 },
    };
    try @import("std").testing.expect(WebGpuBackend.stripsBufferBindingsEqual(a, a));
    var b = a;
    b.strips_size += 1;
    try @import("std").testing.expect(!WebGpuBackend.stripsBufferBindingsEqual(a, b));
    b = a;
    b.target = .{ .id = 3 };
    try @import("std").testing.expect(!WebGpuBackend.stripsBufferBindingsEqual(a, b));
}

test "WebGPU backend copies padded readback rows into images" {
    const allocator = @import("std").testing.allocator;
    var image = try Image.init(allocator, 2, 2, .transparent);
    defer image.deinit();

    var bytes = [_]u8{0} ** 512;
    bytes[0] = 255;
    bytes[3] = 255;
    bytes[4 + 1] = 255;
    bytes[4 + 3] = 255;
    bytes[256 + 2] = 255;
    bytes[256 + 3] = 255;
    bytes[256 + 4] = 255;
    bytes[256 + 4 + 1] = 255;
    bytes[256 + 4 + 2] = 255;
    bytes[256 + 4 + 3] = 255;

    try WebGpuBackend.copyReadbackRowsToImage(&bytes, 2, 2, 256, &image);
    try @import("std").testing.expectEqual(IrisColor.red, image.pixel(0, 0).?);
    try @import("std").testing.expectEqual(IrisColor.green, image.pixel(1, 0).?);
    try @import("std").testing.expectEqual(IrisColor.blue, image.pixel(0, 1).?);
    try @import("std").testing.expectEqual(IrisColor.white, image.pixel(1, 1).?);
}

test "WebGPU readback callback records map status" {
    var backend = WebGpuBackend{};
    WebGpuBackend.readbackMapCallback(.success, &backend);
    try @import("std").testing.expectEqual(WebGpuBackend.ReadbackMapStatus.success, backend.readbackStatus());
    WebGpuBackend.readbackMapCallback(.validation_error, &backend);
    try @import("std").testing.expectEqual(WebGpuBackend.ReadbackMapStatus.failed, backend.readbackStatus());
    backend.unmapReadbackForTest();
    try @import("std").testing.expectEqual(WebGpuBackend.ReadbackMapStatus.idle, backend.readbackStatus());
}

test "WebGPU readback polling requires compiled context" {
    var backend = WebGpuBackend{};
    try @import("std").testing.expectError(error.BackendUnavailable, backend.pollReadback());
    try @import("std").testing.expectError(error.BackendUnavailable, backend.waitForReadback(1));
}

test "WebGPU swapchain helpers require compiled context" {
    var backend = WebGpuBackend{};
    try @import("std").testing.expectError(error.BackendUnavailable, backend.acquireSwapchainTarget());
    try @import("std").testing.expectError(error.BackendUnavailable, backend.present());
}
