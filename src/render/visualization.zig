const std = @import("std");
const cangjie = @import("cangjie");
const color_mod = @import("color.zig");
const Color = @import("color.zig").Color;
const gpu = @import("gpu.zig");
const Image = @import("image.zig").Image;
const math = @import("math.zig");
const scene2d = @import("scene2d.zig");

pub const HeatmapPalette = enum {
    viridis,
    magma,
    grayscale,
};

pub const HeatmapOptions = struct {
    width: u32,
    height: u32,
    min_value: f32 = 0.0,
    max_value: f32 = 1.0,
    palette: HeatmapPalette = .viridis,
    missing_color: Color = .transparent,
};

pub const PolylinePlotOptions = struct {
    rect: math.Rect,
    x_min: f32,
    x_max: f32,
    y_min: f32,
    y_max: f32,
    width: f32 = 2.0,
    color: Color = .white,
};

pub const PlotAxesOptions = struct {
    rect: math.Rect,
    color: Color = Color.rgba(210, 220, 235, 220),
    grid_color: Color = Color.rgba(130, 150, 180, 90),
    width: f32 = 1.0,
    x_ticks: u32 = 4,
    y_ticks: u32 = 4,
};

pub const LegendItem = struct {
    color: Color,
};

pub const LegendOptions = struct {
    rect: math.Rect,
    swatch_size: f32 = 8.0,
    gap: f32 = 4.0,
    background: Color = Color.rgba(8, 12, 18, 170),
};

pub const TimelineEvent = struct {
    start: f32,
    end: f32,
    lane: u32 = 0,
    color: Color = .white,
};

pub const TimelineOptions = struct {
    rect: math.Rect,
    time_min: f32,
    time_max: f32,
    lanes: u32 = 1,
    background: Color = Color.rgba(8, 12, 18, 160),
    lane_color: Color = Color.rgba(130, 150, 180, 90),
    border_color: Color = Color.rgba(210, 220, 235, 180),
    border_width: f32 = 1.0,
    padding: f32 = 3.0,
};

pub const NodeGraphEdge = struct {
    from: math.Vec2,
    to: math.Vec2,
    color: Color = .white,
    width: f32 = 2.0,
};

pub const NodeGraphEdgeOptions = struct {
    curvature: f32 = 0.45,
    arrow_size: f32 = 0.0,
};

pub const FormulaRule = struct {
    rect: math.Rect,
    color: Color = .black,
};

pub const FormulaGlyph = struct {
    font_index: usize,
    text: []const u8,
    origin: math.Vec2,
    size: f32,
    color: Color = .black,
};

pub const FormulaGlyphAssembly = struct {
    parts: []const FormulaGlyph,
};

pub const FormulaPathRequest = struct {
    path: *const scene2d.Path,
    fill: ?Color = null,
    stroke: ?Color = null,
    stroke_width: f32 = 1.0,
};

pub const FormulaAccent = union(enum) {
    glyph: FormulaGlyph,
    path: FormulaPathRequest,
};

pub const FormulaDebugOverlay = struct {
    origin: math.Vec2,
    width: f32,
    baseline_y: ?f32 = null,
    math_axis_y: ?f32 = null,
    baseline_color: Color = Color.rgba(80, 160, 255, 180),
    math_axis_color: Color = Color.rgba(255, 120, 80, 180),
};

pub const FormulaDrawList = struct {
    glyphs: []const FormulaGlyph = &.{},
    glyph_assemblies: []const FormulaGlyphAssembly = &.{},
    path_requests: []const FormulaPathRequest = &.{},
    accents: []const FormulaAccent = &.{},
    rules: []const FormulaRule = &.{},
    debug_overlay: ?FormulaDebugOverlay = null,
};

pub const FormulaDebugDump = struct {
    glyphs: usize = 0,
    glyph_assemblies: usize = 0,
    assembly_parts: usize = 0,
    path_requests: usize = 0,
    accents: usize = 0,
    rules: usize = 0,
    debug_overlays: usize = 0,
    estimated_primitives: usize = 0,
};

pub const VisualizationBatchDebugDump = struct {
    primitives: usize = 0,
    paths: usize = 0,
    images: usize = 0,
    lines: usize = 0,
    rects: usize = 0,
    image_rects: usize = 0,
    path_strokes: usize = 0,
    blend_modes: usize = 0,
};

pub const VolumeAxis = enum {
    x,
    y,
    z,
};

pub const VolumeSliceOptions = struct {
    width: u32,
    height: u32,
    depth: u32,
    axis: VolumeAxis = .z,
    slice: u32 = 0,
    min_value: f32 = 0.0,
    max_value: f32 = 1.0,
    palette: HeatmapPalette = .viridis,
    missing_color: Color = .transparent,
};

pub const VolumeSliceAtlasOptions = struct {
    width: u32,
    height: u32,
    depth: u32,
    axis: VolumeAxis = .z,
    columns: u32,
    min_value: f32 = 0.0,
    max_value: f32 = 1.0,
    palette: HeatmapPalette = .viridis,
    missing_color: Color = .transparent,
};

pub fn heatmapImage(allocator: std.mem.Allocator, values: []const f32, options: HeatmapOptions) !Image {
    const count = try std.math.mul(u32, options.width, options.height);
    if (values.len < count) return error.HeatmapDataTooSmall;

    var image = try Image.init(allocator, options.width, options.height, .transparent);
    errdefer image.deinit();

    const denom = options.max_value - options.min_value;
    for (image.pixels, values[0..count]) |*pixel, value| {
        if (std.math.isNan(value)) {
            pixel.* = options.missing_color;
            continue;
        }
        const t = if (@abs(denom) <= 0.000001) 0.0 else (value - options.min_value) / denom;
        pixel.* = samplePalette(options.palette, @min(1.0, @max(0.0, t)));
    }
    return image;
}

pub fn debugScene2DVisualizationBatch(scene: *const scene2d.Scene2D) VisualizationBatchDebugDump {
    var dump = VisualizationBatchDebugDump{
        .primitives = scene.primitives.items.len,
        .paths = scene.paths.items.len,
        .images = scene.images.items.len,
    };
    var blend_modes = [_]bool{false} ** @typeInfo(color_mod.BlendMode).@"enum".fields.len;
    for (scene.primitives.items) |primitive| {
        if (primitiveBlendMode(primitive)) |mode| {
            blend_modes[@intFromEnum(mode)] = true;
        }
        switch (primitive) {
            .line => dump.lines += 1,
            .fill_rect, .fill_linear_gradient_rect, .fill_radial_gradient_rect, .fill_sweep_gradient_rect, .drop_shadow_rect, .masked_rect => dump.rects += 1,
            .fill_image_rect => dump.image_rects += 1,
            .stroke_path, .stroke_linear_gradient_path, .stroke_radial_gradient_path, .stroke_sweep_gradient_path => dump.path_strokes += 1,
            else => {},
        }
    }
    for (blend_modes) |seen| {
        if (seen) dump.blend_modes += 1;
    }
    return dump;
}

fn primitiveBlendMode(primitive: scene2d.Primitive2D) ?color_mod.BlendMode {
    return switch (primitive) {
        .fill_rect => |p| p.blend_mode,
        .drop_shadow_rect => |p| p.blend_mode,
        .fill_linear_gradient_rect => |p| p.blend_mode,
        .fill_radial_gradient_rect => |p| p.blend_mode,
        .fill_sweep_gradient_rect => |p| p.blend_mode,
        .fill_image_rect => |p| p.blend_mode,
        .masked_rect => |p| p.blend_mode,
        .fill_text => |p| p.blend_mode,
        .line => |p| p.blend_mode,
        .ellipse => |p| p.blend_mode,
        .triangle => |p| p.blend_mode,
        .fill_path => |p| p.blend_mode,
        .fill_linear_gradient_path => |p| p.blend_mode,
        .fill_radial_gradient_path => |p| p.blend_mode,
        .fill_sweep_gradient_path => |p| p.blend_mode,
        .stroke_path => |p| p.blend_mode,
        .stroke_linear_gradient_path => |p| p.blend_mode,
        .stroke_radial_gradient_path => |p| p.blend_mode,
        .stroke_sweep_gradient_path => |p| p.blend_mode,
        .push_clip_path, .pop_clip_path => null,
    };
}

pub fn debugScene2DGpuBatch(allocator: std.mem.Allocator, scene: *const scene2d.Scene2D, width: u32, height: u32) !gpu.GpuBatchDebugDump {
    var batch: gpu.GpuBatch = .{};
    defer batch.deinit(allocator);
    try batch.build2DFromScene(allocator, scene, width, height);
    return batch.debugDump();
}

pub fn volumeSliceImage(allocator: std.mem.Allocator, values: []const f32, options: VolumeSliceOptions) !Image {
    const voxel_count = try std.math.mul(u32, try std.math.mul(u32, options.width, options.height), options.depth);
    if (values.len < voxel_count) return error.VolumeDataTooSmall;

    const out_width = switch (options.axis) {
        .x => options.depth,
        .y, .z => options.width,
    };
    const out_height = switch (options.axis) {
        .x, .z => options.height,
        .y => options.depth,
    };
    const max_slice = switch (options.axis) {
        .x => options.width,
        .y => options.height,
        .z => options.depth,
    };
    if (options.slice >= max_slice) return error.InvalidVolumeSlice;

    var image = try Image.init(allocator, out_width, out_height, .transparent);
    errdefer image.deinit();
    const denom = options.max_value - options.min_value;
    var y: u32 = 0;
    while (y < out_height) : (y += 1) {
        var x: u32 = 0;
        while (x < out_width) : (x += 1) {
            const value = values[volumeIndex(options, x, y)];
            const pixel = &image.pixels[y * out_width + x];
            if (std.math.isNan(value)) {
                pixel.* = options.missing_color;
                continue;
            }
            const t = if (@abs(denom) <= 0.000001) 0.0 else (value - options.min_value) / denom;
            pixel.* = samplePalette(options.palette, @min(1.0, @max(0.0, t)));
        }
    }
    return image;
}

pub fn volumeSliceAtlasImage(allocator: std.mem.Allocator, values: []const f32, options: VolumeSliceAtlasOptions) !Image {
    if (options.columns == 0) return error.InvalidVolumeAtlasColumns;
    const slice_count = switch (options.axis) {
        .x => options.width,
        .y => options.height,
        .z => options.depth,
    };
    const tile_w = switch (options.axis) {
        .x => options.depth,
        .y, .z => options.width,
    };
    const tile_h = switch (options.axis) {
        .x, .z => options.height,
        .y => options.depth,
    };
    const rows = (slice_count + options.columns - 1) / options.columns;
    var atlas = try Image.init(
        allocator,
        try std.math.mul(u32, tile_w, options.columns),
        try std.math.mul(u32, tile_h, rows),
        .transparent,
    );
    errdefer atlas.deinit();

    var slice: u32 = 0;
    while (slice < slice_count) : (slice += 1) {
        var tile = try volumeSliceImage(allocator, values, .{
            .width = options.width,
            .height = options.height,
            .depth = options.depth,
            .axis = options.axis,
            .slice = slice,
            .min_value = options.min_value,
            .max_value = options.max_value,
            .palette = options.palette,
            .missing_color = options.missing_color,
        });

        const ox = (slice % options.columns) * tile_w;
        const oy = (slice / options.columns) * tile_h;
        var y: u32 = 0;
        while (y < tile_h) : (y += 1) {
            var x: u32 = 0;
            while (x < tile_w) : (x += 1) {
                atlas.writePixel(ox + x, oy + y, tile.pixel(x, y).?);
            }
        }
        tile.deinit();
    }
    return atlas;
}

fn volumeIndex(options: VolumeSliceOptions, out_x: u32, out_y: u32) usize {
    const x = switch (options.axis) {
        .x => options.slice,
        .y, .z => out_x,
    };
    const y = switch (options.axis) {
        .x, .z => out_y,
        .y => options.slice,
    };
    const z = switch (options.axis) {
        .x => out_x,
        .y => out_y,
        .z => options.slice,
    };
    return @as(usize, z) * options.width * options.height + @as(usize, y) * options.width + x;
}

pub fn appendPolylinePlot(scene: *scene2d.Scene2D, points: []const math.Vec2, options: PolylinePlotOptions) !void {
    if (points.len < 2) return;
    const x_span = options.x_max - options.x_min;
    const y_span = options.y_max - options.y_min;
    if (@abs(x_span) <= 0.000001 or @abs(y_span) <= 0.000001) return error.InvalidPlotRange;

    var previous: ?math.Vec2 = null;
    for (points) |point| {
        if (std.math.isNan(point.x) or std.math.isNan(point.y)) {
            previous = null;
            continue;
        }
        const mapped = mapPlotPoint(point, options, x_span, y_span);
        if (previous) |prev| {
            try scene.strokeLine(prev, mapped, options.width, options.color);
        }
        previous = mapped;
    }
}

pub fn appendPlotAxes(scene: *scene2d.Scene2D, options: PlotAxesOptions) !void {
    const left = options.rect.x;
    const right = options.rect.x + options.rect.w;
    const top = options.rect.y;
    const bottom = options.rect.y + options.rect.h;

    var x_tick: u32 = 0;
    while (x_tick <= options.x_ticks) : (x_tick += 1) {
        const t = if (options.x_ticks == 0) 0.0 else @as(f32, @floatFromInt(x_tick)) / @as(f32, @floatFromInt(options.x_ticks));
        const x = left + options.rect.w * t;
        try scene.strokeHairline(.{ .x = x, .y = top }, .{ .x = x, .y = bottom }, options.grid_color);
    }

    var y_tick: u32 = 0;
    while (y_tick <= options.y_ticks) : (y_tick += 1) {
        const t = if (options.y_ticks == 0) 0.0 else @as(f32, @floatFromInt(y_tick)) / @as(f32, @floatFromInt(options.y_ticks));
        const y = top + options.rect.h * t;
        try scene.strokeHairline(.{ .x = left, .y = y }, .{ .x = right, .y = y }, options.grid_color);
    }

    try scene.strokeLine(.{ .x = left, .y = bottom }, .{ .x = right, .y = bottom }, options.width, options.color);
    try scene.strokeLine(.{ .x = left, .y = top }, .{ .x = left, .y = bottom }, options.width, options.color);
}

pub fn appendLegend(scene: *scene2d.Scene2D, items: []const LegendItem, options: LegendOptions) !void {
    try scene.fillRect(options.rect, options.background);
    var x = options.rect.x + options.gap;
    const y = options.rect.y + (options.rect.h - options.swatch_size) * 0.5;
    for (items) |item| {
        if (x + options.swatch_size > options.rect.x + options.rect.w) break;
        try scene.fillRect(.{
            .x = x,
            .y = y,
            .w = options.swatch_size,
            .h = options.swatch_size,
        }, item.color);
        x += options.swatch_size + options.gap;
    }
}

pub fn appendTimeline(scene: *scene2d.Scene2D, events: []const TimelineEvent, options: TimelineOptions) !void {
    const time_span = options.time_max - options.time_min;
    if (@abs(time_span) <= 0.000001) return error.InvalidTimelineRange;
    const lanes = @max(1, options.lanes);
    try scene.fillRect(options.rect, options.background);

    const lane_h = options.rect.h / @as(f32, @floatFromInt(lanes));
    var lane: u32 = 1;
    while (lane < lanes) : (lane += 1) {
        const y = options.rect.y + lane_h * @as(f32, @floatFromInt(lane));
        try scene.strokeHairline(.{ .x = options.rect.x, .y = y }, .{ .x = options.rect.x + options.rect.w, .y = y }, options.lane_color);
    }

    for (events) |event| {
        if (event.lane >= lanes) continue;
        const start_t = @min(1.0, @max(0.0, (event.start - options.time_min) / time_span));
        const end_t = @min(1.0, @max(0.0, (event.end - options.time_min) / time_span));
        const left_t = @min(start_t, end_t);
        const right_t = @max(start_t, end_t);
        if (right_t <= 0.0 or left_t >= 1.0) continue;
        const x0 = options.rect.x + left_t * options.rect.w;
        const x1 = options.rect.x + right_t * options.rect.w;
        const y0 = options.rect.y + lane_h * @as(f32, @floatFromInt(event.lane)) + options.padding;
        try scene.fillRect(.{
            .x = x0,
            .y = y0,
            .w = @max(1.0, x1 - x0),
            .h = @max(1.0, lane_h - options.padding * 2.0),
        }, event.color);
    }

    const x0 = options.rect.x;
    const x1 = options.rect.x + options.rect.w;
    const y0 = options.rect.y;
    const y1 = options.rect.y + options.rect.h;
    try scene.strokeLine(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, options.border_width, options.border_color);
    try scene.strokeLine(.{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, options.border_width, options.border_color);
    try scene.strokeLine(.{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 }, options.border_width, options.border_color);
    try scene.strokeLine(.{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 }, options.border_width, options.border_color);
}

pub fn appendNodeGraphEdges(scene: *scene2d.Scene2D, edges: []const NodeGraphEdge, options: NodeGraphEdgeOptions) !void {
    for (edges) |edge| {
        var path = scene2d.Path.init(scene.allocator);
        defer path.deinit();
        const dx = edge.to.x - edge.from.x;
        const c0 = math.Vec2{ .x = edge.from.x + dx * options.curvature, .y = edge.from.y };
        const c1 = math.Vec2{ .x = edge.to.x - dx * options.curvature, .y = edge.to.y };
        try path.moveTo(edge.from);
        try path.cubicTo(c0, c1, edge.to);
        try scene.strokePathCap(&path, edge.width, .round, edge.color);
        if (options.arrow_size > 0.0) {
            try appendArrowHead(scene, edge, options.arrow_size);
        }
    }
}

pub fn appendFormulaRules(scene: *scene2d.Scene2D, rules: []const FormulaRule) !void {
    for (rules) |rule| {
        try scene.fillRect(rule.rect, rule.color);
    }
}

pub fn appendFormulaGlyphs(scene: *scene2d.Scene2D, glyphs: []const FormulaGlyph) !void {
    for (glyphs) |glyph| {
        try scene.fillText(glyph.font_index, glyph.text, glyph.origin, glyph.size, glyph.color);
    }
}

pub fn appendFormulaGlyphAssembly(scene: *scene2d.Scene2D, assembly: FormulaGlyphAssembly) !void {
    try appendFormulaGlyphs(scene, assembly.parts);
}

pub fn appendFormulaPathRequests(scene: *scene2d.Scene2D, requests: []const FormulaPathRequest) !void {
    for (requests) |request| {
        if (request.fill) |fill_color| {
            try scene.fillPath(request.path, fill_color, .non_zero);
        }
        if (request.stroke) |stroke_color| {
            try scene.strokePath(request.path, request.stroke_width, stroke_color);
        }
    }
}

pub fn appendFormulaAccents(scene: *scene2d.Scene2D, accents: []const FormulaAccent) !void {
    for (accents) |accent| {
        switch (accent) {
            .glyph => |glyph| try appendFormulaGlyphs(scene, &.{glyph}),
            .path => |path| try appendFormulaPathRequests(scene, &.{path}),
        }
    }
}

pub fn appendFormulaDebugOverlay(scene: *scene2d.Scene2D, overlay: FormulaDebugOverlay) !void {
    const x0 = overlay.origin.x;
    const x1 = overlay.origin.x + overlay.width;
    if (overlay.baseline_y) |baseline_y| {
        try scene.strokeHairline(.{ .x = x0, .y = baseline_y }, .{ .x = x1, .y = baseline_y }, overlay.baseline_color);
    }
    if (overlay.math_axis_y) |axis_y| {
        try scene.strokeHairline(.{ .x = x0, .y = axis_y }, .{ .x = x1, .y = axis_y }, overlay.math_axis_color);
    }
}

pub fn appendFormulaDrawList(scene: *scene2d.Scene2D, draw_list: FormulaDrawList) !void {
    try appendFormulaGlyphs(scene, draw_list.glyphs);
    for (draw_list.glyph_assemblies) |assembly| {
        try appendFormulaGlyphAssembly(scene, assembly);
    }
    try appendFormulaPathRequests(scene, draw_list.path_requests);
    try appendFormulaAccents(scene, draw_list.accents);
    try appendFormulaRules(scene, draw_list.rules);
    if (draw_list.debug_overlay) |overlay| {
        try appendFormulaDebugOverlay(scene, overlay);
    }
}

pub fn debugFormulaDrawList(draw_list: FormulaDrawList) FormulaDebugDump {
    var dump = FormulaDebugDump{
        .glyphs = draw_list.glyphs.len,
        .glyph_assemblies = draw_list.glyph_assemblies.len,
        .path_requests = draw_list.path_requests.len,
        .accents = draw_list.accents.len,
        .rules = draw_list.rules.len,
        .debug_overlays = if (draw_list.debug_overlay != null) 1 else 0,
    };
    dump.estimated_primitives += dump.glyphs;
    for (draw_list.glyph_assemblies) |assembly| {
        dump.assembly_parts += assembly.parts.len;
        dump.estimated_primitives += assembly.parts.len;
    }
    for (draw_list.path_requests) |request| {
        if (request.fill != null) dump.estimated_primitives += 1;
        if (request.stroke != null) dump.estimated_primitives += 1;
    }
    for (draw_list.accents) |accent| {
        switch (accent) {
            .glyph => dump.estimated_primitives += 1,
            .path => |request| {
                if (request.fill != null) dump.estimated_primitives += 1;
                if (request.stroke != null) dump.estimated_primitives += 1;
            },
        }
    }
    dump.estimated_primitives += dump.rules;
    if (draw_list.debug_overlay) |overlay| {
        if (overlay.baseline_y != null) dump.estimated_primitives += 1;
        if (overlay.math_axis_y != null) dump.estimated_primitives += 1;
    }
    return dump;
}

fn appendArrowHead(scene: *scene2d.Scene2D, edge: NodeGraphEdge, size: f32) !void {
    const dir = normalizeVec2(edge.to.sub(edge.from));
    if (dir.x == 0.0 and dir.y == 0.0) return;
    const normal = math.Vec2{ .x = -dir.y, .y = dir.x };
    const back = edge.to.sub(dir.scale(size));
    try scene.strokeLine(edge.to, back.add(normal.scale(size * 0.45)), edge.width, edge.color);
    try scene.strokeLine(edge.to, back.sub(normal.scale(size * 0.45)), edge.width, edge.color);
}

fn normalizeVec2(v: math.Vec2) math.Vec2 {
    const len = @sqrt(v.x * v.x + v.y * v.y);
    if (len <= 0.000001) return .{};
    return .{ .x = v.x / len, .y = v.y / len };
}

fn mapPlotPoint(point: math.Vec2, options: PolylinePlotOptions, x_span: f32, y_span: f32) math.Vec2 {
    const tx = (point.x - options.x_min) / x_span;
    const ty = (point.y - options.y_min) / y_span;
    return .{
        .x = options.rect.x + @min(1.0, @max(0.0, tx)) * options.rect.w,
        .y = options.rect.y + (1.0 - @min(1.0, @max(0.0, ty))) * options.rect.h,
    };
}

pub fn samplePalette(palette: HeatmapPalette, t: f32) Color {
    const clamped = @min(1.0, @max(0.0, t));
    return switch (palette) {
        .viridis => sampleStops(clamped, &.{
            Color.rgba(68, 1, 84, 255),
            Color.rgba(59, 82, 139, 255),
            Color.rgba(33, 145, 140, 255),
            Color.rgba(94, 201, 98, 255),
            Color.rgba(253, 231, 37, 255),
        }),
        .magma => sampleStops(clamped, &.{
            Color.rgba(0, 0, 4, 255),
            Color.rgba(80, 18, 123, 255),
            Color.rgba(182, 54, 121, 255),
            Color.rgba(251, 136, 97, 255),
            Color.rgba(252, 253, 191, 255),
        }),
        .grayscale => {
            const c: u8 = @intFromFloat(@round(clamped * 255.0));
            return Color.rgba(c, c, c, 255);
        },
    };
}

fn sampleStops(t: f32, stops: []const Color) Color {
    if (stops.len == 0) return .transparent;
    if (stops.len == 1) return stops[0];
    const scaled = t * @as(f32, @floatFromInt(stops.len - 1));
    const index_float = @floor(@min(scaled, @as(f32, @floatFromInt(stops.len - 1))));
    const index: usize = @intFromFloat(index_float);
    if (index >= stops.len - 1) return stops[stops.len - 1];
    return Color.lerpLinearRgb(stops[index], stops[index + 1], scaled - index_float);
}

test "heatmap image maps scalar values through palette" {
    const allocator = std.testing.allocator;
    const values = [_]f32{ 0.0, 0.5, 1.0, std.math.nan(f32) };
    var image = try heatmapImage(allocator, &values, .{
        .width = 2,
        .height = 2,
        .min_value = 0.0,
        .max_value = 1.0,
        .palette = .grayscale,
        .missing_color = Color.rgba(1, 2, 3, 4),
    });
    defer image.deinit();

    try std.testing.expectEqual(Color.black, image.pixel(0, 0).?);
    try std.testing.expectEqual(Color.rgba(128, 128, 128, 255), image.pixel(1, 0).?);
    try std.testing.expectEqual(Color.white, image.pixel(0, 1).?);
    try std.testing.expectEqual(Color.rgba(1, 2, 3, 4), image.pixel(1, 1).?);
}

test "heatmap image clamps values and validates length" {
    const allocator = std.testing.allocator;
    const values = [_]f32{ -1.0, 2.0 };
    var image = try heatmapImage(allocator, &values, .{
        .width = 2,
        .height = 1,
        .palette = .grayscale,
    });
    defer image.deinit();

    try std.testing.expectEqual(Color.black, image.pixel(0, 0).?);
    try std.testing.expectEqual(Color.white, image.pixel(1, 0).?);
    try std.testing.expectError(error.HeatmapDataTooSmall, heatmapImage(allocator, values[0..1], .{ .width = 2, .height = 1 }));
}

test "volume slice image extracts z slices through palette" {
    const allocator = std.testing.allocator;
    const values = [_]f32{
        0.0,  0.25,
        0.5,  0.75,
        1.0,  std.math.nan(f32),
        0.25, 0.5,
    };
    var image = try volumeSliceImage(allocator, &values, .{
        .width = 2,
        .height = 2,
        .depth = 2,
        .axis = .z,
        .slice = 1,
        .palette = .grayscale,
        .missing_color = Color.rgba(1, 2, 3, 4),
    });
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqual(Color.white, image.pixel(0, 0).?);
    try std.testing.expectEqual(Color.rgba(1, 2, 3, 4), image.pixel(1, 0).?);
    try std.testing.expectEqual(Color.rgba(128, 128, 128, 255), image.pixel(1, 1).?);
}

test "volume slice image validates data length and slice bounds" {
    const allocator = std.testing.allocator;
    const values = [_]f32{ 0.0, 1.0, 0.5, 0.25 };
    try std.testing.expectError(error.VolumeDataTooSmall, volumeSliceImage(allocator, values[0..3], .{
        .width = 2,
        .height = 2,
        .depth = 1,
    }));
    try std.testing.expectError(error.InvalidVolumeSlice, volumeSliceImage(allocator, &values, .{
        .width = 2,
        .height = 2,
        .depth = 1,
        .slice = 1,
    }));
}

test "volume slice atlas packs all slices into tiles" {
    const allocator = std.testing.allocator;
    const values = [_]f32{
        0.0, 0.25,
        0.5, 0.75,
        1.0, 0.75,
        0.5, 0.25,
    };
    var atlas = try volumeSliceAtlasImage(allocator, &values, .{
        .width = 2,
        .height = 2,
        .depth = 2,
        .axis = .z,
        .columns = 2,
        .palette = .grayscale,
    });
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u32, 4), atlas.width);
    try std.testing.expectEqual(@as(u32, 2), atlas.height);
    try std.testing.expectEqual(Color.black, atlas.pixel(0, 0).?);
    try std.testing.expectEqual(Color.white, atlas.pixel(2, 0).?);
    try std.testing.expectError(error.InvalidVolumeAtlasColumns, volumeSliceAtlasImage(allocator, &values, .{
        .width = 2,
        .height = 2,
        .depth = 2,
        .columns = 0,
    }));
}

test "polyline plot lowers data points to scene lines" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const points = [_]math.Vec2{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 0.5, .y = 1.0 },
        .{ .x = 1.0, .y = 0.0 },
    };

    try appendPolylinePlot(&scene, &points, .{
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 50 },
        .x_min = 0.0,
        .x_max = 1.0,
        .y_min = 0.0,
        .y_max = 1.0,
        .width = 3.0,
        .color = .green,
    });

    try std.testing.expectEqual(@as(usize, 2), scene.primitives.items.len);
    try std.testing.expectEqual(@as(f32, 10), scene.primitives.items[0].line.a.x);
    try std.testing.expectEqual(@as(f32, 70), scene.primitives.items[0].line.a.y);
    try std.testing.expectEqual(@as(f32, 60), scene.primitives.items[0].line.b.x);
    try std.testing.expectEqual(@as(f32, 20), scene.primitives.items[0].line.b.y);
    try std.testing.expectEqual(@as(f32, 3), scene.primitives.items[0].line.width);
    try std.testing.expectEqual(Color.green, scene.primitives.items[0].line.color);
}

test "polyline plot skips gaps and validates ranges" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const points = [_]math.Vec2{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = std.math.nan(f32), .y = 1.0 },
        .{ .x = 1.0, .y = 0.0 },
    };

    try appendPolylinePlot(&scene, &points, .{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .x_min = 0.0,
        .x_max = 1.0,
        .y_min = 0.0,
        .y_max = 1.0,
    });
    try std.testing.expectEqual(@as(usize, 0), scene.primitives.items.len);
    try std.testing.expectError(error.InvalidPlotRange, appendPolylinePlot(&scene, points[0..2], .{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .x_min = 1.0,
        .x_max = 1.0,
        .y_min = 0.0,
        .y_max = 1.0,
    }));
}

test "plot axes lower to grid and axis lines" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();

    try appendPlotAxes(&scene, .{
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 50 },
        .x_ticks = 2,
        .y_ticks = 1,
        .width = 2.0,
    });

    try std.testing.expectEqual(@as(usize, 7), scene.primitives.items.len);
    try std.testing.expectEqual(@as(f32, 10), scene.primitives.items[0].line.a.x);
    try std.testing.expectEqual(@as(f32, 20), scene.primitives.items[0].line.a.y);
    try std.testing.expectEqual(@as(f32, 70), scene.primitives.items[0].line.b.y);
    try std.testing.expectEqual(@as(f32, 2), scene.primitives.items[5].line.width);
    try std.testing.expectEqual(@as(f32, 2), scene.primitives.items[6].line.width);
}

test "legend lowers items to background and swatches" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const items = [_]LegendItem{
        .{ .color = .red },
        .{ .color = .green },
    };

    try appendLegend(&scene, &items, .{
        .rect = .{ .x = 4, .y = 6, .w = 30, .h = 14 },
        .swatch_size = 5,
        .gap = 3,
    });

    try std.testing.expectEqual(@as(usize, 3), scene.primitives.items.len);
    try std.testing.expectEqual(Color.red, scene.primitives.items[1].fill_rect.color);
    try std.testing.expectEqual(Color.green, scene.primitives.items[2].fill_rect.color);
    try std.testing.expectEqual(@as(f32, 7), scene.primitives.items[1].fill_rect.rect.x);
}

test "timeline lowers events to lanes and rectangles" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const events = [_]TimelineEvent{
        .{ .start = 0.0, .end = 2.0, .lane = 0, .color = .red },
        .{ .start = 1.0, .end = 4.0, .lane = 1, .color = .green },
        .{ .start = 3.0, .end = 5.0, .lane = 9, .color = .blue },
    };

    try appendTimeline(&scene, &events, .{
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 40 },
        .time_min = 0.0,
        .time_max = 5.0,
        .lanes = 2,
        .padding = 2.0,
    });

    try std.testing.expectEqual(@as(usize, 8), scene.primitives.items.len);
    try std.testing.expectEqual(Color.rgba(8, 12, 18, 160), scene.primitives.items[0].fill_rect.color);
    try std.testing.expectEqual(Color.red, scene.primitives.items[2].fill_rect.color);
    try std.testing.expectEqual(@as(f32, 40), scene.primitives.items[2].fill_rect.rect.w);
    try std.testing.expectEqual(Color.green, scene.primitives.items[3].fill_rect.color);
    try std.testing.expectEqual(@as(f32, 60), scene.primitives.items[3].fill_rect.rect.w);
    try std.testing.expectError(error.InvalidTimelineRange, appendTimeline(&scene, events[0..1], .{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .time_min = 1.0,
        .time_max = 1.0,
    }));
}

test "node graph edges lower to bezier strokes and arrows" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const edges = [_]NodeGraphEdge{
        .{
            .from = .{ .x = 0, .y = 0 },
            .to = .{ .x = 20, .y = 10 },
            .color = .blue,
            .width = 3.0,
        },
    };

    try appendNodeGraphEdges(&scene, &edges, .{ .curvature = 0.5, .arrow_size = 4.0 });

    try std.testing.expectEqual(@as(usize, 3), scene.primitives.items.len);
    try std.testing.expectEqual(Color.blue, scene.primitives.items[0].stroke_path.color);
    try std.testing.expectEqual(@as(f32, 3), scene.primitives.items[0].stroke_path.width);
    try std.testing.expectEqual(Color.blue, scene.primitives.items[1].line.color);
    try std.testing.expectEqual(Color.blue, scene.primitives.items[2].line.color);
}

test "formula rules and debug overlay lower to 2D primitives" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();

    try appendFormulaRules(&scene, &.{
        .{ .rect = .{ .x = 2, .y = 8, .w = 24, .h = 2 }, .color = .black },
        .{ .rect = .{ .x = 6, .y = 18, .w = 18, .h = 1 }, .color = .blue },
    });
    try appendFormulaDebugOverlay(&scene, .{
        .origin = .{ .x = 0, .y = 0 },
        .width = 32,
        .baseline_y = 20,
        .math_axis_y = 10,
    });

    try std.testing.expectEqual(@as(usize, 4), scene.primitives.items.len);
    try std.testing.expectEqual(Color.black, scene.primitives.items[0].fill_rect.color);
    try std.testing.expectEqual(Color.blue, scene.primitives.items[1].fill_rect.color);
    try std.testing.expectEqual(@as(f32, 1.0), scene.primitives.items[2].line.width);
    try std.testing.expectEqual(@as(f32, 20), scene.primitives.items[2].line.a.y);
    try std.testing.expectEqual(@as(f32, 10), scene.primitives.items[3].line.a.y);
}

test "formula glyphs lower to existing text primitives" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const font_bytes = try cangjie.testing.test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);
    const font_index = try scene.addTextFont(font_bytes);

    try appendFormulaGlyphs(&scene, &.{
        .{ .font_index = font_index, .text = "x", .origin = .{ .x = 2, .y = 16 }, .size = 18, .color = .black },
        .{ .font_index = font_index, .text = "2", .origin = .{ .x = 14, .y = 8 }, .size = 10, .color = .blue },
    });

    try std.testing.expectEqual(@as(usize, 2), scene.primitives.items.len);
    try std.testing.expectEqualStrings("x", scene.primitives.items[0].fill_text.text);
    try std.testing.expectEqual(@as(f32, 18), scene.primitives.items[0].fill_text.size);
    try std.testing.expectEqualStrings("2", scene.primitives.items[1].fill_text.text);
    try std.testing.expectEqual(Color.blue, scene.primitives.items[1].fill_text.color);
}

test "formula glyph assembly lowers ordered delimiter parts" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const font_bytes = try cangjie.testing.test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);
    const font_index = try scene.addTextFont(font_bytes);

    const parts = [_]FormulaGlyph{
        .{ .font_index = font_index, .text = "(", .origin = .{ .x = 0, .y = 12 }, .size = 12, .color = .black },
        .{ .font_index = font_index, .text = "|", .origin = .{ .x = 0, .y = 24 }, .size = 12, .color = .black },
        .{ .font_index = font_index, .text = ")", .origin = .{ .x = 0, .y = 36 }, .size = 12, .color = .black },
    };
    try appendFormulaGlyphAssembly(&scene, .{ .parts = &parts });

    try std.testing.expectEqual(@as(usize, 3), scene.primitives.items.len);
    try std.testing.expectEqualStrings("(", scene.primitives.items[0].fill_text.text);
    try std.testing.expectEqualStrings("|", scene.primitives.items[1].fill_text.text);
    try std.testing.expectEqualStrings(")", scene.primitives.items[2].fill_text.text);
    try std.testing.expectEqual(@as(f32, 36), scene.primitives.items[2].fill_text.origin.y);
}

test "formula path requests lower to fill and stroke primitives" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 8, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 6 });
    try path.close();

    try appendFormulaPathRequests(&scene, &.{.{
        .path = &path,
        .fill = .green,
        .stroke = .blue,
        .stroke_width = 2.0,
    }});

    try std.testing.expectEqual(@as(usize, 2), scene.primitives.items.len);
    try std.testing.expectEqual(Color.green, scene.primitives.items[0].fill_path.color);
    try std.testing.expectEqual(Color.blue, scene.primitives.items[1].stroke_path.color);
    try std.testing.expectEqual(@as(f32, 2), scene.primitives.items[1].stroke_path.width);
}

test "formula accents lower glyph and path accents" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const font_bytes = try cangjie.testing.test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);
    const font_index = try scene.addTextFont(font_bytes);
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 4 });
    try path.lineTo(.{ .x = 10, .y = 0 });

    try appendFormulaAccents(&scene, &.{
        .{ .glyph = .{ .font_index = font_index, .text = "^", .origin = .{ .x = 4, .y = 6 }, .size = 8, .color = .black } },
        .{ .path = .{ .path = &path, .stroke = .red, .stroke_width = 1.5 } },
    });

    try std.testing.expectEqual(@as(usize, 2), scene.primitives.items.len);
    try std.testing.expectEqualStrings("^", scene.primitives.items[0].fill_text.text);
    try std.testing.expectEqual(Color.red, scene.primitives.items[1].stroke_path.color);
}

test "formula draw list lowers mixed precomputed records" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const font_bytes = try cangjie.testing.test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);
    const font_index = try scene.addTextFont(font_bytes);
    var path = scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 6, .y = 0 });

    const glyphs = [_]FormulaGlyph{
        .{ .font_index = font_index, .text = "E", .origin = .{ .x = 0, .y = 18 }, .size = 16, .color = .black },
    };
    const rules = [_]FormulaRule{
        .{ .rect = .{ .x = 2, .y = 10, .w = 18, .h = 1 }, .color = .black },
    };
    const paths = [_]FormulaPathRequest{
        .{ .path = &path, .stroke = .blue, .stroke_width = 1.0 },
    };
    const draw_list = FormulaDrawList{
        .glyphs = &glyphs,
        .path_requests = &paths,
        .rules = &rules,
        .debug_overlay = .{ .origin = .{}, .width = 24, .baseline_y = 18 },
    };
    try appendFormulaDrawList(&scene, draw_list);

    try std.testing.expectEqual(@as(usize, 4), scene.primitives.items.len);
    try std.testing.expectEqualStrings("E", scene.primitives.items[0].fill_text.text);
    try std.testing.expectEqual(Color.blue, scene.primitives.items[1].stroke_path.color);
    try std.testing.expectEqual(Color.black, scene.primitives.items[2].fill_rect.color);
    try std.testing.expectEqual(@as(f32, 18), scene.primitives.items[3].line.a.y);

    const dump = debugFormulaDrawList(draw_list);
    try std.testing.expectEqual(@as(usize, 1), dump.glyphs);
    try std.testing.expectEqual(@as(usize, 1), dump.path_requests);
    try std.testing.expectEqual(@as(usize, 1), dump.rules);
    try std.testing.expectEqual(@as(usize, 1), dump.debug_overlays);
    try std.testing.expectEqual(scene.primitives.items.len, dump.estimated_primitives);
}

test "visualization batch debug dump summarizes scene primitives" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();

    const points = [_]math.Vec2{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 1.0 },
    };
    try appendPolylinePlot(&scene, &points, .{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .x_min = 0,
        .x_max = 1,
        .y_min = 0,
        .y_max = 1,
    });
    try appendLegend(&scene, &.{.{ .color = .red }}, .{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 8 }, .swatch_size = 4, .gap = 2 });

    const dump = debugScene2DVisualizationBatch(&scene);
    try std.testing.expectEqual(@as(usize, scene.primitives.items.len), dump.primitives);
    try std.testing.expectEqual(@as(usize, 1), dump.lines);
    try std.testing.expectEqual(@as(usize, 2), dump.rects);
    try std.testing.expectEqual(@as(usize, 1), dump.blend_modes);
}

test "visualization scene can build GPU batch debug summaries" {
    const allocator = std.testing.allocator;
    var scene = scene2d.Scene2D.init(allocator);
    defer scene.deinit();
    const points = [_]math.Vec2{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 1.0 },
    };
    try appendPolylinePlot(&scene, &points, .{
        .rect = .{ .x = 1, .y = 1, .w = 8, .h = 8 },
        .x_min = 0,
        .x_max = 1,
        .y_min = 0,
        .y_max = 1,
        .width = 2,
    });

    const dump = try debugScene2DGpuBatch(allocator, &scene, 12, 12);
    try std.testing.expect(dump.strips > 0);
    try std.testing.expect(dump.tile_ranges > 0);
    try std.testing.expect(dump.upload_bytes >= dump.strips * gpu.ShaderContract.strip_size);
}
