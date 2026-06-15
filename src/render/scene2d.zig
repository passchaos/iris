//! Retained 2D scene model and sparse-strip raster preparation.
//!
//! Scene2D records drawing commands plus their resolved style state. Rendering
//! lowers those commands into horizontal strips: compact pixel spans that can be
//! copied by the CPU path or uploaded to GPU-style backends without exposing the
//! high-level path/text/image data to every backend.
const std = @import("std");
const math = @import("math.zig");
const color_mod = @import("color.zig");
const Color = color_mod.Color;
const BlendMode = color_mod.BlendMode;
const Image = @import("image.zig").Image;
const cangjie = @import("cangjie");

pub const Tile = struct {
    pub const width: u32 = 16;
    pub const height: u32 = 16;
};

pub const Strip = struct {
    x: u16,
    y: u16,
    width: u16,
    color: Color,
    blend_mode: BlendMode = .source_over,
};

pub const Primitive2D = union(enum) {
    fill_rect: FillRect,
    drop_shadow_rect: DropShadowRect,
    fill_linear_gradient_rect: FillLinearGradientRect,
    fill_radial_gradient_rect: FillRadialGradientRect,
    fill_sweep_gradient_rect: FillSweepGradientRect,
    fill_image_rect: FillImageRect,
    masked_rect: MaskedRect,
    fill_text: FillText,
    line: Line,
    ellipse: Ellipse,
    triangle: Triangle2D,
    fill_path: FillPath,
    fill_linear_gradient_path: FillLinearGradientPath,
    fill_radial_gradient_path: FillRadialGradientPath,
    fill_sweep_gradient_path: FillSweepGradientPath,
    stroke_path: StrokePath,
    stroke_linear_gradient_path: StrokeLinearGradientPath,
    stroke_radial_gradient_path: StrokeRadialGradientPath,
    stroke_sweep_gradient_path: StrokeSweepGradientPath,
    push_clip_path: ClipPath,
    pop_clip_path,
};

pub const FillRule = enum {
    non_zero,
    even_odd,
};

pub const FillRect = struct {
    rect: math.Rect,
    color: Color,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const DropShadowRect = struct {
    area: TransformedRect,
    offset: math.Vec2,
    blur_radius: f32 = 0.0,
    color: Color,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const TransformedRect = struct {
    rect: math.Rect,
    transform: math.Affine2D = .identity,

    fn bounds(self: TransformedRect, target_width: u32, target_height: u32) BoundsU32 {
        const b = self.floatBounds();
        return .{
            .x0 = clampFloor(b.x, 0, target_width),
            .y0 = clampFloor(b.y, 0, target_height),
            .x1 = clampCeil(b.right(), 0, target_width),
            .y1 = clampCeil(b.bottom(), 0, target_height),
        };
    }

    fn floatBounds(self: TransformedRect) math.Rect {
        if (self.transform.isIdentity()) return self.rect;
        const p0 = self.transform.transformPoint(.{ .x = self.rect.x, .y = self.rect.y });
        const p1 = self.transform.transformPoint(.{ .x = self.rect.right(), .y = self.rect.y });
        const p2 = self.transform.transformPoint(.{ .x = self.rect.right(), .y = self.rect.bottom() });
        const p3 = self.transform.transformPoint(.{ .x = self.rect.x, .y = self.rect.bottom() });
        const min_x = @min(@min(p0.x, p1.x), @min(p2.x, p3.x));
        const min_y = @min(@min(p0.y, p1.y), @min(p2.y, p3.y));
        const max_x = @max(@max(p0.x, p1.x), @max(p2.x, p3.x));
        const max_y = @max(@max(p0.y, p1.y), @max(p2.y, p3.y));
        return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
    }

    fn inverse(self: TransformedRect) ?math.Affine2D {
        return self.transform.inverse();
    }
};

pub const LinearGradient = struct {
    start: math.Vec2,
    end: math.Vec2,
    start_color: Color,
    end_color: Color,
    stops: [max_gradient_stops]GradientStop = empty_gradient_stops,
    stop_count: u8 = 0,
    spread: GradientSpread = .pad,
    interpolation: GradientInterpolation = .srgb,
    dither: DitherMode = .none,

    pub fn sampleAt(self: LinearGradient, point: math.Vec2) Color {
        const t = self.offsetAt(point);
        return if (t < 0.0) .transparent else sampleLinearGradient(self, t);
    }

    pub fn offsetAt(self: LinearGradient, point: math.Vec2) f32 {
        const axis = self.end.sub(self.start);
        const axis_len_sq = axis.dot(axis);
        if (axis_len_sq <= 0.000001) return -1.0;
        return @min(1.0, @max(0.0, point.sub(self.start).dot(axis) / axis_len_sq));
    }

    pub fn addStop(self: *LinearGradient, offset: f32, color: Color) !void {
        try addGradientStop(&self.stops, &self.stop_count, offset, color);
    }

    pub fn addStopAssumeCapacity(self: *LinearGradient, offset: f32, color: Color) void {
        addGradientStopAssumeCapacity(&self.stops, &self.stop_count, offset, color);
    }
};

pub const FillLinearGradientRect = struct {
    area: TransformedRect,
    gradient: LinearGradient,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const RadialGradient = struct {
    center: math.Vec2,
    radius: f32,
    inner_center: ?math.Vec2 = null,
    inner_radius: f32 = 0.0,
    inner_color: Color,
    outer_color: Color,
    stops: [max_gradient_stops]GradientStop = empty_gradient_stops,
    stop_count: u8 = 0,
    spread: GradientSpread = .pad,
    interpolation: GradientInterpolation = .srgb,
    dither: DitherMode = .none,

    pub fn sampleAt(self: RadialGradient, point: math.Vec2) Color {
        const t = self.offsetAt(point);
        if (t < 0.0) return .transparent;
        return sampleRadialGradient(self, t);
    }

    pub fn offsetAt(self: RadialGradient, point: math.Vec2) f32 {
        return radialGradientT(self, point) orelse -1.0;
    }

    pub fn addStop(self: *RadialGradient, offset: f32, color: Color) !void {
        try addGradientStop(&self.stops, &self.stop_count, offset, color);
    }

    pub fn addStopAssumeCapacity(self: *RadialGradient, offset: f32, color: Color) void {
        addGradientStopAssumeCapacity(&self.stops, &self.stop_count, offset, color);
    }
};

pub const FillRadialGradientRect = struct {
    area: TransformedRect,
    gradient: RadialGradient,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const max_gradient_stops = 8;

pub const GradientStop = struct {
    offset: f32 = 0.0,
    color: Color = .transparent,
};

pub const GradientInterpolation = enum {
    srgb,
    linear_rgb,
};

pub const DitherMode = enum {
    none,
    bayer,
    blue_noise,
};

pub const GradientSpread = enum {
    pad,
    repeat,
    reflect,
};

const empty_gradient_stops = [_]GradientStop{.{}} ** max_gradient_stops;

pub const SweepGradient = struct {
    center: math.Vec2,
    start_angle: f32 = 0.0,
    start_color: Color,
    end_color: Color,
    stops: [max_gradient_stops]GradientStop = empty_gradient_stops,
    stop_count: u8 = 0,
    spread: GradientSpread = .pad,
    interpolation: GradientInterpolation = .srgb,
    dither: DitherMode = .none,

    pub fn sampleAt(self: SweepGradient, point: math.Vec2) Color {
        return sampleSweepGradient(self, self.offsetAt(point));
    }

    pub fn offsetAt(self: SweepGradient, point: math.Vec2) f32 {
        return sweepGradientT(point, self.center, self.start_angle);
    }

    pub fn addStop(self: *SweepGradient, offset: f32, color: Color) !void {
        try addGradientStop(&self.stops, &self.stop_count, offset, color);
    }

    pub fn addStopAssumeCapacity(self: *SweepGradient, offset: f32, color: Color) void {
        addGradientStopAssumeCapacity(&self.stops, &self.stop_count, offset, color);
    }
};

pub const FillSweepGradientRect = struct {
    area: TransformedRect,
    gradient: SweepGradient,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const ImageSource = struct {
    width: u32,
    height: u32,
    pixels: []Color,

    pub fn deinit(self: *ImageSource, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const FillImageRect = struct {
    area: TransformedRect,
    image_index: usize,
    source_rect: ?math.Rect = null,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const MaskedRect = struct {
    area: TransformedRect,
    color: Color,
    mask_index: usize,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
};

pub const TextFont = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    font: cangjie.Font,

    pub fn parse(allocator: std.mem.Allocator, font_data: []const u8) !TextFont {
        const owned = try allocator.dupe(u8, font_data);
        errdefer allocator.free(owned);
        var font = try cangjie.Font.parse(allocator, owned);
        errdefer font.deinit();
        return .{
            .allocator = allocator,
            .data = owned,
            .font = font,
        };
    }

    pub fn deinit(self: *TextFont) void {
        self.font.deinit();
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

pub const FillText = struct {
    font_index: usize,
    text: []const u8,
    origin: math.Vec2,
    size: f32,
    transform: math.Affine2D = .identity,
    color: Color,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
    raster_samples_per_axis: u8 = 4,
};

pub const TextMetrics = struct {
    advance: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,

    pub fn height(self: TextMetrics) f32 {
        return self.ascent + self.descent + self.line_gap;
    }
};

pub const max_dash_segments = 8;

pub const DashPattern = struct {
    segments: [max_dash_segments]f32 = [_]f32{0.0} ** max_dash_segments,
    count: u8 = 0,
    offset: f32 = 0.0,

    pub fn fromPair(on: f32, off: f32, offset: f32) DashPattern {
        if (on <= 0.000001 or off <= 0.000001) return .{};
        var pattern = DashPattern{ .count = 2, .offset = offset };
        pattern.segments[0] = on;
        pattern.segments[1] = off;
        return pattern;
    }

    pub fn fromSlice(segments: []const f32, offset: f32) DashPattern {
        var pattern = DashPattern{ .offset = offset };
        const limit = @min(segments.len, max_dash_segments);
        for (segments[0..limit]) |segment| {
            if (segment < 0.0) return .{};
            pattern.segments[pattern.count] = segment;
            pattern.count += 1;
        }
        if (pattern.totalLength() <= 0.000001) return .{};
        return pattern;
    }

    fn totalLength(self: DashPattern) f32 {
        var total: f32 = 0.0;
        for (self.segments[0..self.count]) |segment| total += segment;
        return total;
    }
};

pub const Line = struct {
    a: math.Vec2,
    b: math.Vec2,
    width: f32 = 1,
    cap: LineCap = .round,
    dash_on: f32 = 0.0,
    dash_off: f32 = 0.0,
    dash_offset: f32 = 0.0,
    dash_pattern: DashPattern = .{},
    color: Color,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const LineCap = enum {
    butt,
    square,
    round,
};

pub const AntiAliasMode = enum {
    default,
    none,
};

pub const LineJoin = enum {
    miter,
    round,
    bevel,
};

pub const StrokeStyle = struct {
    width: f32 = 2.0,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    miter_limit: f32 = 4.0,
    dash: DashPattern = .{},
    hairline: bool = false,
};

pub const Ellipse = struct {
    mode: EllipseMode = .fill,
    center: math.Vec2,
    radius: math.Vec2,
    stroke_width: f32 = 1.0,
    start_angle: f32 = 0.0,
    end_angle: f32 = 2.0 * std.math.pi,
    color: Color,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const EllipseMode = enum {
    fill,
    stroke,
    sector,
    arc,
};

pub const Triangle2D = struct {
    positions: [3]math.Vec2,
    color: Color,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const FillPath = struct {
    path_index: usize,
    color: Color,
    fill_rule: FillRule,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const FillLinearGradientPath = struct {
    path_index: usize,
    gradient: LinearGradient,
    fill_rule: FillRule,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const FillRadialGradientPath = struct {
    path_index: usize,
    gradient: RadialGradient,
    fill_rule: FillRule,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const FillSweepGradientPath = struct {
    path_index: usize,
    gradient: SweepGradient,
    fill_rule: FillRule,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const ClipPath = struct {
    path_index: usize,
    fill_rule: FillRule = .non_zero,
};

pub const StrokePath = struct {
    path_index: usize,
    width: f32 = 1.0,
    cap: LineCap = .round,
    join: LineJoin = .miter,
    miter_limit: f32 = 4.0,
    dash_on: f32 = 0.0,
    dash_off: f32 = 0.0,
    dash_offset: f32 = 0.0,
    dash_pattern: DashPattern = .{},
    color: Color,
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const StrokeLinearGradientPath = struct {
    path_index: usize,
    gradient: LinearGradient,
    width: f32 = 1.0,
    cap: LineCap = .round,
    join: LineJoin = .miter,
    miter_limit: f32 = 4.0,
    dash_pattern: DashPattern = .{},
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const StrokeRadialGradientPath = struct {
    path_index: usize,
    gradient: RadialGradient,
    width: f32 = 1.0,
    cap: LineCap = .round,
    join: LineJoin = .miter,
    miter_limit: f32 = 4.0,
    dash_pattern: DashPattern = .{},
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const StrokeSweepGradientPath = struct {
    path_index: usize,
    gradient: SweepGradient,
    width: f32 = 1.0,
    cap: LineCap = .round,
    join: LineJoin = .miter,
    miter_limit: f32 = 4.0,
    dash_pattern: DashPattern = .{},
    clip: ?math.Rect = null,
    blend_mode: BlendMode = .source_over,
    opacity: f32 = 1.0,
    anti_alias: AntiAliasMode = .default,
};

pub const PathCommand = union(enum) {
    move_to: math.Vec2,
    line_to: math.Vec2,
    quad_to: struct { control: math.Vec2, end: math.Vec2 },
    cubic_to: struct { c0: math.Vec2, c1: math.Vec2, end: math.Vec2 },
    close,
};

pub const Path = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(PathCommand) = .empty,
    tolerance: f32 = 0.25,
    owns_commands: bool = true,

    pub fn init(allocator: std.mem.Allocator) Path {
        return .{ .allocator = allocator };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Path {
        return .{
            .allocator = allocator,
            .commands = try std.ArrayList(PathCommand).initCapacity(allocator, capacity),
        };
    }

    pub fn initBuffer(buffer: []PathCommand) Path {
        return .{
            .allocator = std.heap.smp_allocator,
            .commands = std.ArrayList(PathCommand).initBuffer(buffer),
            .owns_commands = false,
        };
    }

    pub fn setTolerance(self: *Path, tolerance: f32) void {
        self.tolerance = @max(0.001, tolerance);
    }

    pub fn getTolerance(self: *const Path) f32 {
        return self.tolerance;
    }

    pub fn clone(self: *const Path, allocator: std.mem.Allocator) !Path {
        var cloned = Path.init(allocator);
        errdefer cloned.deinit();
        try cloned.commands.appendSlice(allocator, self.commands.items);
        return cloned;
    }

    pub fn cloneTransformed(self: *const Path, allocator: std.mem.Allocator, transform: math.Affine2D) !Path {
        var cloned = Path.init(allocator);
        errdefer cloned.deinit();
        for (self.commands.items) |command| {
            try cloned.commands.append(allocator, switch (command) {
                .move_to => |p| .{ .move_to = transform.transformPoint(p) },
                .line_to => |p| .{ .line_to = transform.transformPoint(p) },
                .quad_to => |q| .{ .quad_to = .{
                    .control = transform.transformPoint(q.control),
                    .end = transform.transformPoint(q.end),
                } },
                .cubic_to => |c| .{ .cubic_to = .{
                    .c0 = transform.transformPoint(c.c0),
                    .c1 = transform.transformPoint(c.c1),
                    .end = transform.transformPoint(c.end),
                } },
                .close => .close,
            });
        }
        return cloned;
    }

    pub fn simplify(self: *const Path, allocator: std.mem.Allocator) !Path {
        if (try simplifyBowTie(self, allocator)) |bow_tie| return bow_tie;
        if (try simplifySelfIntersectingPolygonLoops(self, allocator)) |loops| return loops;
        if (try simplifySelfIntersectingPolygonHull(self, allocator)) |hull| return hull;

        var simplified = Path.init(allocator);
        errdefer simplified.deinit();
        var current: ?math.Vec2 = null;
        var start: ?math.Vec2 = null;

        for (self.commands.items) |command| {
            switch (command) {
                .move_to => |p| {
                    try simplified.commands.append(allocator, .{ .move_to = p });
                    current = p;
                    start = p;
                },
                .line_to => |p| {
                    if (current) |c| {
                        if (pointsNear(c, p)) continue;
                    }
                    if (simplified.commands.items.len >= 2) {
                        const last = simplified.commands.items[simplified.commands.items.len - 1];
                        const prev = simplified.commands.items[simplified.commands.items.len - 2];
                        if (commandPoint(last)) |last_point| {
                            if (commandPoint(prev)) |prev_point| {
                                if (pointsCollinear(prev_point, last_point, p)) {
                                    simplified.commands.items[simplified.commands.items.len - 1] = .{ .line_to = p };
                                    current = p;
                                    continue;
                                }
                            }
                        }
                    }
                    try simplified.commands.append(allocator, .{ .line_to = p });
                    current = p;
                },
                .quad_to => |q| {
                    if (current) |c| {
                        if (pointsNear(c, q.control) and pointsNear(c, q.end)) continue;
                    }
                    try simplified.commands.append(allocator, command);
                    current = q.end;
                },
                .cubic_to => |cubic| {
                    if (current) |c| {
                        if (pointsNear(c, cubic.c0) and pointsNear(c, cubic.c1) and pointsNear(c, cubic.end)) continue;
                    }
                    try simplified.commands.append(allocator, command);
                    current = cubic.end;
                },
                .close => {
                    if (start) |s| {
                        if (current) |c| {
                            if (pointsNear(c, s) and simplified.commands.items.len > 0) {
                                switch (simplified.commands.items[simplified.commands.items.len - 1]) {
                                    .line_to => _ = simplified.commands.pop(),
                                    else => {},
                                }
                            }
                        }
                    }
                    try simplified.commands.append(allocator, .close);
                    current = start;
                },
            }
        }

        return simplified;
    }

    pub fn offset(self: *const Path, allocator: std.mem.Allocator, amount: f32) !Path {
        if (@abs(amount) <= 0.000001) return self.clone(allocator);

        var simplified_source = try self.simplify(allocator);
        defer simplified_source.deinit();

        var result = Path.init(allocator);
        errdefer result.deinit();
        var points: std.ArrayList(math.Vec2) = .empty;
        defer points.deinit(allocator);
        var has_contour = false;
        var closed = false;
        for (simplified_source.commands.items) |command| {
            switch (command) {
                .move_to => |p| {
                    if (has_contour) {
                        try appendOffsetContour(allocator, &result, points.items, closed, amount);
                        points.clearRetainingCapacity();
                        closed = false;
                    }
                    has_contour = true;
                    try points.append(allocator, p);
                },
                .line_to => |p| try points.append(allocator, p),
                .close => closed = true,
                .quad_to => |q| {
                    const from = points.items[points.items.len - 1];
                    const steps = self.curveSteps(from, q.end);
                    var i: u32 = 1;
                    while (i <= steps) : (i += 1) {
                        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                        try points.append(allocator, evalQuad(from, q.control, q.end, t));
                    }
                },
                .cubic_to => |c| {
                    const from = points.items[points.items.len - 1];
                    const steps = self.curveSteps(from, c.end);
                    var i: u32 = 1;
                    while (i <= steps) : (i += 1) {
                        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                        try points.append(allocator, evalCubic(from, c.c0, c.c1, c.end, t));
                    }
                },
            }
        }
        if (!has_contour) return error.UnsupportedPathOffset;
        try appendOffsetContour(allocator, &result, points.items, closed, amount);
        return result;
    }

    pub fn deinit(self: *Path) void {
        if (self.owns_commands) self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Path) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn moveTo(self: *Path, p: math.Vec2) !void {
        try self.commands.append(self.allocator, .{ .move_to = p });
    }

    pub fn moveToAssumeCapacity(self: *Path, p: math.Vec2) void {
        self.commands.appendAssumeCapacity(.{ .move_to = p });
    }

    pub fn relMoveTo(self: *Path, delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.moveTo(current.add(delta));
    }

    pub fn relMoveToAssumeCapacity(self: *Path, delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        self.moveToAssumeCapacity(current.add(delta));
    }

    pub fn lineTo(self: *Path, p: math.Vec2) !void {
        if (self.currentPoint() == null) {
            try self.moveTo(p);
            return;
        }
        try self.commands.append(self.allocator, .{ .line_to = p });
    }

    pub fn lineToAssumeCapacity(self: *Path, p: math.Vec2) void {
        if (self.currentPoint() == null) {
            self.moveToAssumeCapacity(p);
            return;
        }
        self.commands.appendAssumeCapacity(.{ .line_to = p });
    }

    pub fn relLineTo(self: *Path, delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.lineTo(current.add(delta));
    }

    pub fn relLineToAssumeCapacity(self: *Path, delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        self.lineToAssumeCapacity(current.add(delta));
    }

    pub fn quadTo(self: *Path, control: math.Vec2, end: math.Vec2) !void {
        _ = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.commands.append(self.allocator, .{ .quad_to = .{ .control = control, .end = end } });
    }

    pub fn quadToAssumeCapacity(self: *Path, control: math.Vec2, end: math.Vec2) !void {
        _ = self.currentPoint() orelse return error.NoCurrentPoint;
        self.commands.appendAssumeCapacity(.{ .quad_to = .{ .control = control, .end = end } });
    }

    pub fn relQuadTo(self: *Path, control_delta: math.Vec2, end_delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.quadTo(current.add(control_delta), current.add(end_delta));
    }

    pub fn relQuadToAssumeCapacity(self: *Path, control_delta: math.Vec2, end_delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.quadToAssumeCapacity(current.add(control_delta), current.add(end_delta));
    }

    pub fn cubicTo(self: *Path, c0: math.Vec2, c1: math.Vec2, end: math.Vec2) !void {
        _ = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.commands.append(self.allocator, .{ .cubic_to = .{ .c0 = c0, .c1 = c1, .end = end } });
    }

    pub fn cubicToAssumeCapacity(self: *Path, c0: math.Vec2, c1: math.Vec2, end: math.Vec2) !void {
        _ = self.currentPoint() orelse return error.NoCurrentPoint;
        self.commands.appendAssumeCapacity(.{ .cubic_to = .{ .c0 = c0, .c1 = c1, .end = end } });
    }

    pub fn curveTo(self: *Path, c0: math.Vec2, c1: math.Vec2, end: math.Vec2) !void {
        try self.cubicTo(c0, c1, end);
    }

    pub fn curveToAssumeCapacity(self: *Path, c0: math.Vec2, c1: math.Vec2, end: math.Vec2) !void {
        try self.cubicToAssumeCapacity(c0, c1, end);
    }

    pub fn relCubicTo(self: *Path, c0_delta: math.Vec2, c1_delta: math.Vec2, end_delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.cubicTo(current.add(c0_delta), current.add(c1_delta), current.add(end_delta));
    }

    pub fn relCubicToAssumeCapacity(self: *Path, c0_delta: math.Vec2, c1_delta: math.Vec2, end_delta: math.Vec2) !void {
        const current = self.currentPoint() orelse return error.NoCurrentPoint;
        try self.cubicToAssumeCapacity(current.add(c0_delta), current.add(c1_delta), current.add(end_delta));
    }

    pub fn relCurveTo(self: *Path, c0_delta: math.Vec2, c1_delta: math.Vec2, end_delta: math.Vec2) !void {
        try self.relCubicTo(c0_delta, c1_delta, end_delta);
    }

    pub fn relCurveToAssumeCapacity(self: *Path, c0_delta: math.Vec2, c1_delta: math.Vec2, end_delta: math.Vec2) !void {
        try self.relCubicToAssumeCapacity(c0_delta, c1_delta, end_delta);
    }

    pub fn arc(self: *Path, center: math.Vec2, radius: f32, start_angle: f32, end_angle: f32) !void {
        var effective_end = end_angle;
        while (effective_end < start_angle) effective_end += 2.0 * std.math.pi;
        try self.arcInDirection(center, radius, start_angle, effective_end);
    }

    pub fn arcNegative(self: *Path, center: math.Vec2, radius: f32, start_angle: f32, end_angle: f32) !void {
        var effective_end = end_angle;
        while (effective_end > start_angle) effective_end -= 2.0 * std.math.pi;
        try self.arcInDirection(center, radius, start_angle, effective_end);
    }

    pub fn close(self: *Path) !void {
        const current = self.currentPoint() orelse return;
        if (self.subpathStart()) |start| {
            if (pointsNear(current, start) and self.commands.items.len > 0) {
                switch (self.commands.items[self.commands.items.len - 1]) {
                    .close => return,
                    else => {},
                }
            }
        }
        try self.commands.append(self.allocator, .close);
    }

    pub fn closeAssumeCapacity(self: *Path) void {
        const current = self.currentPoint() orelse return;
        if (self.subpathStart()) |start| {
            if (pointsNear(current, start) and self.commands.items.len > 0) {
                switch (self.commands.items[self.commands.items.len - 1]) {
                    .close => return,
                    else => {},
                }
            }
        }
        self.commands.appendAssumeCapacity(.close);
    }

    pub fn currentPoint(self: *const Path) ?math.Vec2 {
        var current: ?math.Vec2 = null;
        var start: ?math.Vec2 = null;
        for (self.commands.items) |command| {
            switch (command) {
                .move_to => |p| {
                    current = p;
                    start = p;
                },
                .line_to => |p| current = p,
                .quad_to => |q| current = q.end,
                .cubic_to => |c| current = c.end,
                .close => current = start,
            }
        }
        return current;
    }

    pub fn isClosed(self: *const Path) bool {
        if (self.commands.items.len == 0) return false;
        var has_subpath = false;
        var current_closed = false;
        for (self.commands.items) |command| {
            switch (command) {
                .move_to => {
                    if (has_subpath and !current_closed) return false;
                    has_subpath = true;
                    current_closed = false;
                },
                .line_to, .quad_to, .cubic_to => {
                    if (!has_subpath) return false;
                    current_closed = false;
                },
                .close => {
                    if (has_subpath) current_closed = true;
                },
            }
        }
        return has_subpath and current_closed;
    }

    fn subpathStart(self: *const Path) ?math.Vec2 {
        var start: ?math.Vec2 = null;
        for (self.commands.items) |command| {
            switch (command) {
                .move_to => |p| start = p,
                else => {},
            }
        }
        return start;
    }

    fn arcInDirection(self: *Path, center: math.Vec2, radius: f32, start_angle: f32, end_angle: f32) !void {
        if (radius <= 0.000001) return;
        const sweep = end_angle - start_angle;
        const steps: u32 = @max(2, @as(u32, @intFromFloat(@ceil(@abs(sweep) / @max(0.001, self.tolerance)))));
        var i: u32 = 0;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const angle = start_angle + sweep * t;
            const point = math.Vec2{
                .x = center.x + @cos(angle) * radius,
                .y = center.y + @sin(angle) * radius,
            };
            if (i == 0 and self.currentPoint() == null) {
                try self.moveTo(point);
            } else if (i > 0 or !pointsNear(self.currentPoint().?, point)) {
                try self.lineTo(point);
            }
        }
    }

    fn curveSteps(self: *const Path, a: math.Vec2, b: math.Vec2) u32 {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        return @max(2, @min(128, @as(u32, @intFromFloat(@ceil(len / @max(0.001, self.tolerance))))));
    }
};

pub const Scene2D = struct {
    allocator: std.mem.Allocator,
    primitives: std.ArrayList(Primitive2D) = .empty,
    paths: std.ArrayList(Path) = .empty,
    images: std.ArrayList(ImageSource) = .empty,
    fonts: std.ArrayList(TextFont) = .empty,
    current_font_index: ?usize = null,
    current_font_size: f32 = 16.0,
    current_source_color: Color = .black,
    clip_stack: std.ArrayList(?math.Rect) = .empty,
    current_clip: ?math.Rect = null,
    blend_stack: std.ArrayList(BlendMode) = .empty,
    current_blend_mode: BlendMode = .source_over,
    fill_rule_stack: std.ArrayList(FillRule) = .empty,
    current_fill_rule: FillRule = .non_zero,
    stroke_style_stack: std.ArrayList(StrokeStyle) = .empty,
    current_stroke_style: StrokeStyle = .{},
    anti_alias_stack: std.ArrayList(AntiAliasMode) = .empty,
    current_anti_alias: AntiAliasMode = .default,
    current_text_raster_samples_per_axis: u8 = 4,
    current_dither: DitherMode = .none,
    opacity_stack: std.ArrayList(f32) = .empty,
    current_opacity: f32 = 1.0,
    transform_stack: std.ArrayList(math.Affine2D) = .empty,
    current_transform: math.Affine2D = .identity,
    current_path: Path,

    pub fn init(allocator: std.mem.Allocator) Scene2D {
        return .{
            .allocator = allocator,
            .current_path = Path.init(allocator),
        };
    }

    pub fn deinit(self: *Scene2D) void {
        self.current_path.deinit();
        self.deinitPrimitives();
        for (self.paths.items) |*path| {
            path.deinit();
        }
        for (self.images.items) |*image| {
            image.deinit(self.allocator);
        }
        for (self.fonts.items) |*font| {
            font.deinit();
        }
        self.fonts.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.clip_stack.deinit(self.allocator);
        self.blend_stack.deinit(self.allocator);
        self.fill_rule_stack.deinit(self.allocator);
        self.stroke_style_stack.deinit(self.allocator);
        self.anti_alias_stack.deinit(self.allocator);
        self.opacity_stack.deinit(self.allocator);
        self.transform_stack.deinit(self.allocator);
        self.primitives.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Scene2D) void {
        self.deinitPrimitives();
        for (self.paths.items) |*path| {
            path.deinit();
        }
        for (self.images.items) |*image| {
            image.deinit(self.allocator);
        }
        for (self.fonts.items) |*font| {
            font.deinit();
        }
        self.fonts.clearRetainingCapacity();
        self.current_font_index = null;
        self.current_font_size = 16.0;
        self.current_source_color = .black;
        self.images.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
        self.current_clip = null;
        self.blend_stack.clearRetainingCapacity();
        self.current_blend_mode = .source_over;
        self.fill_rule_stack.clearRetainingCapacity();
        self.current_fill_rule = .non_zero;
        self.stroke_style_stack.clearRetainingCapacity();
        self.current_stroke_style = .{};
        self.anti_alias_stack.clearRetainingCapacity();
        self.current_anti_alias = .default;
        self.current_dither = .none;
        self.opacity_stack.clearRetainingCapacity();
        self.current_opacity = 1.0;
        self.transform_stack.clearRetainingCapacity();
        self.current_transform = .identity;
        self.current_path.reset();
        self.primitives.clearRetainingCapacity();
    }

    fn deinitPrimitives(self: *Scene2D) void {
        for (self.primitives.items) |prim| {
            switch (prim) {
                .fill_text => |text| self.allocator.free(text.text),
                else => {},
            }
        }
    }

    pub fn fillRect(self: *Scene2D, rect: math.Rect, color: Color) !void {
        if (!self.current_transform.isIdentity()) {
            var path = Path.init(self.allocator);
            defer path.deinit();
            try rectPath(&path, rect);
            try self.fillPath(&path, color, .non_zero);
            return;
        }
        try self.primitives.append(self.allocator, .{ .fill_rect = .{
            .rect = rect,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn resetPath(self: *Scene2D) void {
        self.current_path.reset();
    }

    pub fn moveTo(self: *Scene2D, p: math.Vec2) !void {
        try self.current_path.moveTo(self.current_transform.transformPoint(p));
    }

    pub fn relMoveTo(self: *Scene2D, delta: math.Vec2) !void {
        const current = self.current_path.currentPoint() orelse return error.NoCurrentPoint;
        try self.current_path.moveTo(current.add(self.current_transform.transformVector(delta)));
    }

    pub fn lineTo(self: *Scene2D, p: math.Vec2) !void {
        try self.current_path.lineTo(self.current_transform.transformPoint(p));
    }

    pub fn relLineTo(self: *Scene2D, delta: math.Vec2) !void {
        const current = self.current_path.currentPoint() orelse return error.NoCurrentPoint;
        try self.current_path.lineTo(current.add(self.current_transform.transformVector(delta)));
    }

    pub fn quadTo(self: *Scene2D, control: math.Vec2, end: math.Vec2) !void {
        try self.current_path.quadTo(self.current_transform.transformPoint(control), self.current_transform.transformPoint(end));
    }

    pub fn relQuadTo(self: *Scene2D, control_delta: math.Vec2, end_delta: math.Vec2) !void {
        const current = self.current_path.currentPoint() orelse return error.NoCurrentPoint;
        try self.current_path.quadTo(
            current.add(self.current_transform.transformVector(control_delta)),
            current.add(self.current_transform.transformVector(end_delta)),
        );
    }

    pub fn curveTo(self: *Scene2D, c0: math.Vec2, c1: math.Vec2, end: math.Vec2) !void {
        try self.current_path.curveTo(
            self.current_transform.transformPoint(c0),
            self.current_transform.transformPoint(c1),
            self.current_transform.transformPoint(end),
        );
    }

    pub fn relCurveTo(self: *Scene2D, c0_delta: math.Vec2, c1_delta: math.Vec2, end_delta: math.Vec2) !void {
        const current = self.current_path.currentPoint() orelse return error.NoCurrentPoint;
        try self.current_path.curveTo(
            current.add(self.current_transform.transformVector(c0_delta)),
            current.add(self.current_transform.transformVector(c1_delta)),
            current.add(self.current_transform.transformVector(end_delta)),
        );
    }

    pub fn arc(self: *Scene2D, center: math.Vec2, radius: f32, start_angle: f32, end_angle: f32) !void {
        if (self.current_transform.isIdentity()) return self.current_path.arc(center, radius, start_angle, end_angle);
        var arc_path = Path.init(self.allocator);
        defer arc_path.deinit();
        try arc_path.arc(center, radius, start_angle, end_angle);
        var transformed = try arc_path.cloneTransformed(self.allocator, self.current_transform);
        defer transformed.deinit();
        try self.current_path.commands.appendSlice(self.allocator, transformed.commands.items);
    }

    pub fn arcNegative(self: *Scene2D, center: math.Vec2, radius: f32, start_angle: f32, end_angle: f32) !void {
        if (self.current_transform.isIdentity()) return self.current_path.arcNegative(center, radius, start_angle, end_angle);
        var arc_path = Path.init(self.allocator);
        defer arc_path.deinit();
        try arc_path.arcNegative(center, radius, start_angle, end_angle);
        var transformed = try arc_path.cloneTransformed(self.allocator, self.current_transform);
        defer transformed.deinit();
        try self.current_path.commands.appendSlice(self.allocator, transformed.commands.items);
    }

    pub fn closePath(self: *Scene2D) !void {
        try self.current_path.close();
    }

    pub fn isPathClosed(self: *const Scene2D) bool {
        return self.current_path.isClosed();
    }

    pub fn simplifyPath(self: *Scene2D) !void {
        const simplified = try self.current_path.simplify(self.allocator);
        self.current_path.deinit();
        self.current_path = simplified;
    }

    pub fn offsetPath(self: *Scene2D, amount: f32) !void {
        const offset_path = try self.current_path.offset(self.allocator, amount);
        self.current_path.deinit();
        self.current_path = offset_path;
    }

    pub fn fill(self: *Scene2D) !void {
        try self.fillPathSource(&self.current_path);
    }

    pub fn stroke(self: *Scene2D) !void {
        try self.strokePathSource(&self.current_path);
    }

    pub fn fillRectCurrent(self: *Scene2D, rect: math.Rect) !void {
        try self.fillRect(rect, self.current_source_color);
    }

    pub fn dropShadowRect(self: *Scene2D, rect: math.Rect, offset: math.Vec2, blur_radius: f32, color: Color) !void {
        const transform_scale = self.current_transform.scaleMagnitude();
        try self.primitives.append(self.allocator, .{ .drop_shadow_rect = .{
            .area = .{ .rect = rect, .transform = self.current_transform },
            .offset = self.current_transform.transformVector(offset),
            .blur_radius = @max(0.0, blur_radius * @max(transform_scale.x, transform_scale.y)),
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillRoundedRect(self: *Scene2D, rect: math.Rect, radius: f32, color: Color) !void {
        const r = @min(@max(0.0, radius), @min(rect.w, rect.h) * 0.5);
        if (r <= 0.000001) {
            try self.fillRect(rect, color);
            return;
        }

        var buffer: [10]PathCommand = undefined;
        var path = Path.initBuffer(&buffer);
        defer path.deinit();
        try roundedRectPath(&path, rect, r);
        try self.fillPath(&path, color, .non_zero);
    }

    pub fn strokeRoundedRect(self: *Scene2D, rect: math.Rect, radius: f32, width: f32, color: Color) !void {
        if (width <= 0.000001) return;
        const r = @min(@max(0.0, radius), @min(rect.w, rect.h) * 0.5);

        var buffer: [10]PathCommand = undefined;
        var path = Path.initBuffer(&buffer);
        defer path.deinit();
        if (r <= 0.000001) {
            try rectPath(&path, rect);
            try self.strokePathCapJoin(&path, width, .butt, .miter, color);
        } else {
            try roundedRectPath(&path, rect, r);
            try self.strokePathCapJoin(&path, width, .butt, .round, color);
        }
    }

    pub fn fillLinearGradientRect(self: *Scene2D, rect: math.Rect, gradient: LinearGradient) !void {
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        try self.primitives.append(self.allocator, .{ .fill_linear_gradient_rect = .{
            .area = .{ .rect = rect, .transform = self.current_transform },
            .gradient = g,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillLinearGradientRoundedRect(self: *Scene2D, rect: math.Rect, radius: f32, gradient: LinearGradient) !void {
        const r = @min(@max(0.0, radius), @min(rect.w, rect.h) * 0.5);
        if (r <= 0.000001) {
            try self.fillLinearGradientRect(rect, gradient);
            return;
        }

        var path = Path.init(self.allocator);
        defer path.deinit();
        try roundedRectPath(&path, rect, r);
        try self.fillLinearGradientPath(&path, gradient, .non_zero);
    }

    pub fn fillRadialGradientRect(self: *Scene2D, rect: math.Rect, gradient: RadialGradient) !void {
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        try self.primitives.append(self.allocator, .{ .fill_radial_gradient_rect = .{
            .area = .{ .rect = rect, .transform = self.current_transform },
            .gradient = g,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillRadialGradientRoundedRect(self: *Scene2D, rect: math.Rect, radius: f32, gradient: RadialGradient) !void {
        const r = @min(@max(0.0, radius), @min(rect.w, rect.h) * 0.5);
        if (r <= 0.000001) {
            try self.fillRadialGradientRect(rect, gradient);
            return;
        }

        var path = Path.init(self.allocator);
        defer path.deinit();
        try roundedRectPath(&path, rect, r);
        try self.fillRadialGradientPath(&path, gradient, .non_zero);
    }

    pub fn fillSweepGradientRect(self: *Scene2D, rect: math.Rect, gradient: SweepGradient) !void {
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        try self.primitives.append(self.allocator, .{ .fill_sweep_gradient_rect = .{
            .area = .{ .rect = rect, .transform = self.current_transform },
            .gradient = g,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillSweepGradientRoundedRect(self: *Scene2D, rect: math.Rect, radius: f32, gradient: SweepGradient) !void {
        const r = @min(@max(0.0, radius), @min(rect.w, rect.h) * 0.5);
        if (r <= 0.000001) {
            try self.fillSweepGradientRect(rect, gradient);
            return;
        }

        var path = Path.init(self.allocator);
        defer path.deinit();
        try roundedRectPath(&path, rect, r);
        try self.fillSweepGradientPath(&path, gradient, .non_zero);
    }

    pub fn fillImageRect(self: *Scene2D, rect: math.Rect, image: *const Image) !void {
        try self.fillImageSubRect(rect, image, null);
    }

    pub fn fillImageSubRect(self: *Scene2D, rect: math.Rect, image: *const Image, source_rect: ?math.Rect) !void {
        const image_index = self.images.items.len;
        const pixels = try self.allocator.dupe(Color, image.pixels);
        errdefer self.allocator.free(pixels);
        try self.images.append(self.allocator, .{
            .width = image.width,
            .height = image.height,
            .pixels = pixels,
        });
        errdefer {
            var stored = self.images.pop().?;
            stored.deinit(self.allocator);
        }

        try self.primitives.append(self.allocator, .{ .fill_image_rect = .{
            .area = .{ .rect = rect, .transform = self.current_transform },
            .image_index = image_index,
            .source_rect = source_rect,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
        } });
    }

    pub fn fillMaskedRect(self: *Scene2D, rect: math.Rect, color: Color, mask: *const Image) !void {
        const mask_index = self.images.items.len;
        const pixels = try self.allocator.dupe(Color, mask.pixels);
        errdefer self.allocator.free(pixels);
        try self.images.append(self.allocator, .{
            .width = mask.width,
            .height = mask.height,
            .pixels = pixels,
        });
        errdefer {
            var stored = self.images.pop().?;
            stored.deinit(self.allocator);
        }

        try self.primitives.append(self.allocator, .{ .masked_rect = .{
            .area = .{ .rect = rect, .transform = self.current_transform },
            .color = color,
            .mask_index = mask_index,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
        } });
    }

    pub fn addTextFont(self: *Scene2D, font_data: []const u8) !usize {
        const font_index = self.fonts.items.len;
        var font = try TextFont.parse(self.allocator, font_data);
        errdefer font.deinit();
        try self.fonts.append(self.allocator, font);
        if (self.current_font_index == null) self.current_font_index = font_index;
        return font_index;
    }

    pub fn setFont(self: *Scene2D, font_index: usize) !void {
        if (font_index >= self.fonts.items.len) return error.InvalidTextFont;
        self.current_font_index = font_index;
    }

    pub fn setFontSize(self: *Scene2D, size: f32) void {
        self.current_font_size = @max(0.0, size);
    }

    pub fn getFontSize(self: *const Scene2D) f32 {
        return self.current_font_size;
    }

    pub fn fillText(self: *Scene2D, font_index: usize, text: []const u8, origin: math.Vec2, size: f32, color: Color) !void {
        if (font_index >= self.fonts.items.len) return error.InvalidTextFont;
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        try self.primitives.append(self.allocator, .{ .fill_text = .{
            .font_index = font_index,
            .text = owned_text,
            .origin = origin,
            .size = @max(0.0, size),
            .transform = self.current_transform,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
            .raster_samples_per_axis = self.current_text_raster_samples_per_axis,
        } });
    }

    pub fn setTextRasterSamplesPerAxis(self: *Scene2D, samples: u8) void {
        self.current_text_raster_samples_per_axis = @max(1, samples);
    }

    pub fn measureText(self: *Scene2D, font_index: usize, text: []const u8, size: f32) !TextMetrics {
        if (font_index >= self.fonts.items.len) return error.InvalidTextFont;
        const font = &self.fonts.items[font_index].font;
        var layout_buffer = cangjie.LayoutBuffer.init(self.allocator);
        defer layout_buffer.deinit();
        const run = try cangjie.TextShaper.shapeUtf8(font, &layout_buffer, text, size);
        const text_scale = size / @as(f32, @floatFromInt(font.units_per_em));
        return .{
            .advance = run.width(),
            .ascent = @max(0.0, @as(f32, @floatFromInt(font.ascender)) * text_scale),
            .descent = @max(0.0, @as(f32, @floatFromInt(-font.descender)) * text_scale),
            .line_gap = @max(0.0, @as(f32, @floatFromInt(font.line_gap)) * text_scale),
        };
    }

    pub fn showText(self: *Scene2D, text: []const u8, origin: math.Vec2, color: Color) !void {
        const font_index = self.current_font_index orelse return error.InvalidTextFont;
        try self.fillText(font_index, text, origin, self.current_font_size, color);
    }

    pub fn showTextCurrent(self: *Scene2D, text: []const u8, origin: math.Vec2) !void {
        try self.showText(text, origin, self.current_source_color);
    }

    pub fn measureTextCurrent(self: *Scene2D, text: []const u8) !TextMetrics {
        const font_index = self.current_font_index orelse return error.InvalidTextFont;
        return self.measureText(font_index, text, self.current_font_size);
    }

    pub fn strokeLine(self: *Scene2D, a: math.Vec2, b: math.Vec2, width: f32, color: Color) !void {
        const transformed_a = self.current_transform.transformPoint(a);
        const transformed_b = self.current_transform.transformPoint(b);
        const stroke_scale = self.strokeScale();
        try self.primitives.append(self.allocator, .{ .line = .{
            .a = transformed_a,
            .b = transformed_b,
            .width = width * stroke_scale,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeHairline(self: *Scene2D, a: math.Vec2, b: math.Vec2, color: Color) !void {
        const transformed_a = self.current_transform.transformPoint(a);
        const transformed_b = self.current_transform.transformPoint(b);
        try self.primitives.append(self.allocator, .{ .line = .{
            .a = transformed_a,
            .b = transformed_b,
            .width = 1.0,
            .cap = .butt,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeDashedLine(self: *Scene2D, a: math.Vec2, b: math.Vec2, width: f32, dash_on: f32, dash_off: f32, color: Color) !void {
        try self.strokeDashedLineOffset(a, b, width, dash_on, dash_off, 0.0, color);
    }

    pub fn strokeDashedLineOffset(self: *Scene2D, a: math.Vec2, b: math.Vec2, width: f32, dash_on: f32, dash_off: f32, dash_offset: f32, color: Color) !void {
        try self.strokeLinePattern(a, b, width, DashPattern.fromPair(dash_on, dash_off, dash_offset), .round, color);
    }

    pub fn strokeLinePattern(self: *Scene2D, a: math.Vec2, b: math.Vec2, width: f32, pattern: DashPattern, cap: LineCap, color: Color) !void {
        const transformed_a = self.current_transform.transformPoint(a);
        const transformed_b = self.current_transform.transformPoint(b);
        const stroke_scale = self.strokeScale();
        const scaled_pattern = scaleDashPattern(pattern, stroke_scale);
        try self.primitives.append(self.allocator, .{ .line = .{
            .a = transformed_a,
            .b = transformed_b,
            .width = width * stroke_scale,
            .cap = cap,
            .dash_on = if (scaled_pattern.count >= 1) scaled_pattern.segments[0] else 0.0,
            .dash_off = if (scaled_pattern.count >= 2) scaled_pattern.segments[1] else 0.0,
            .dash_offset = scaled_pattern.offset,
            .dash_pattern = scaled_pattern,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeDashedLineCap(self: *Scene2D, a: math.Vec2, b: math.Vec2, width: f32, dash_on: f32, dash_off: f32, cap: LineCap, color: Color) !void {
        try self.strokeDashedLineCapOffset(a, b, width, dash_on, dash_off, 0.0, cap, color);
    }

    pub fn strokeDashedLineCapOffset(self: *Scene2D, a: math.Vec2, b: math.Vec2, width: f32, dash_on: f32, dash_off: f32, dash_offset: f32, cap: LineCap, color: Color) !void {
        try self.strokeLinePattern(a, b, width, DashPattern.fromPair(dash_on, dash_off, dash_offset), cap, color);
    }

    pub fn strokeLineCap(self: *Scene2D, a: math.Vec2, b: math.Vec2, width: f32, cap: LineCap, color: Color) !void {
        const transformed_a = self.current_transform.transformPoint(a);
        const transformed_b = self.current_transform.transformPoint(b);
        const stroke_scale = self.strokeScale();
        try self.primitives.append(self.allocator, .{ .line = .{
            .a = transformed_a,
            .b = transformed_b,
            .width = width * stroke_scale,
            .cap = cap,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeLineCurrent(self: *Scene2D, a: math.Vec2, b: math.Vec2, color: Color) !void {
        const style = self.current_stroke_style;
        if (style.hairline) return self.strokeHairline(a, b, color);
        if (style.dash.count > 0) return self.strokeLinePattern(a, b, style.width, style.dash, style.cap, color);
        try self.strokeLineCap(a, b, style.width, style.cap, color);
    }

    pub fn strokeLineSource(self: *Scene2D, a: math.Vec2, b: math.Vec2) !void {
        try self.strokeLineCurrent(a, b, self.current_source_color);
    }

    pub fn fillEllipse(self: *Scene2D, center: math.Vec2, radius: math.Vec2, color: Color) !void {
        if (!self.current_transform.isIdentity()) {
            var path = Path.init(self.allocator);
            defer path.deinit();
            try ellipsePath(&path, center, radius);
            try self.fillPath(&path, color, .non_zero);
            return;
        }
        try self.primitives.append(self.allocator, .{ .ellipse = .{
            .mode = .fill,
            .center = center,
            .radius = .{ .x = @max(0.0, radius.x), .y = @max(0.0, radius.y) },
            .stroke_width = 0.0,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeEllipse(self: *Scene2D, center: math.Vec2, radius: math.Vec2, width: f32, color: Color) !void {
        if (!self.current_transform.isIdentity()) {
            var path = Path.init(self.allocator);
            defer path.deinit();
            try ellipsePath(&path, center, radius);
            try self.strokePathCapJoin(&path, width, .butt, .round, color);
            return;
        }
        try self.primitives.append(self.allocator, .{ .ellipse = .{
            .mode = .stroke,
            .center = center,
            .radius = .{ .x = @max(0.0, radius.x), .y = @max(0.0, radius.y) },
            .stroke_width = @max(0.0, width),
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillArcSector(self: *Scene2D, center: math.Vec2, radius: math.Vec2, start_angle: f32, end_angle: f32, color: Color) !void {
        if (!self.current_transform.isIdentity()) {
            var path = Path.init(self.allocator);
            defer path.deinit();
            try arcSectorPath(&path, center, radius, start_angle, end_angle);
            try self.fillPath(&path, color, .non_zero);
            return;
        }
        try self.primitives.append(self.allocator, .{ .ellipse = .{
            .mode = .sector,
            .center = center,
            .radius = .{ .x = @max(0.0, radius.x), .y = @max(0.0, radius.y) },
            .stroke_width = 0.0,
            .start_angle = start_angle,
            .end_angle = end_angle,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeArc(self: *Scene2D, center: math.Vec2, radius: math.Vec2, width: f32, start_angle: f32, end_angle: f32, color: Color) !void {
        if (!self.current_transform.isIdentity()) {
            var path = Path.init(self.allocator);
            defer path.deinit();
            try arcPath(&path, center, radius, start_angle, end_angle);
            try self.strokePathCapJoin(&path, width, .butt, .round, color);
            return;
        }
        try self.primitives.append(self.allocator, .{ .ellipse = .{
            .mode = .arc,
            .center = center,
            .radius = .{ .x = @max(0.0, radius.x), .y = @max(0.0, radius.y) },
            .stroke_width = @max(0.0, width),
            .start_angle = start_angle,
            .end_angle = end_angle,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillTriangle(self: *Scene2D, positions: [3]math.Vec2, color: Color) !void {
        const transformed_positions = [3]math.Vec2{
            self.current_transform.transformPoint(positions[0]),
            self.current_transform.transformPoint(positions[1]),
            self.current_transform.transformPoint(positions[2]),
        };
        try self.primitives.append(self.allocator, .{ .triangle = .{
            .positions = transformed_positions,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillPath(self: *Scene2D, path: *const Path, color: Color, fill_rule: FillRule) !void {
        const path_index = self.paths.items.len;
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .fill_path = .{
            .path_index = path_index,
            .color = color,
            .fill_rule = fill_rule,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillPathCurrent(self: *Scene2D, path: *const Path, color: Color) !void {
        try self.fillPath(path, color, self.current_fill_rule);
    }

    pub fn fillLinearGradientPath(self: *Scene2D, path: *const Path, gradient: LinearGradient, fill_rule: FillRule) !void {
        const path_index = self.paths.items.len;
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .fill_linear_gradient_path = .{
            .path_index = path_index,
            .gradient = g,
            .fill_rule = fill_rule,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillRadialGradientPath(self: *Scene2D, path: *const Path, gradient: RadialGradient, fill_rule: FillRule) !void {
        const path_index = self.paths.items.len;
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .fill_radial_gradient_path = .{
            .path_index = path_index,
            .gradient = g,
            .fill_rule = fill_rule,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillSweepGradientPath(self: *Scene2D, path: *const Path, gradient: SweepGradient, fill_rule: FillRule) !void {
        const path_index = self.paths.items.len;
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .fill_sweep_gradient_path = .{
            .path_index = path_index,
            .gradient = g,
            .fill_rule = fill_rule,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn fillPathSource(self: *Scene2D, path: *const Path) !void {
        try self.fillPath(path, self.current_source_color, self.current_fill_rule);
    }

    pub fn strokePath(self: *Scene2D, path: *const Path, width: f32, color: Color) !void {
        const path_index = self.paths.items.len;
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .stroke_path = .{
            .path_index = path_index,
            .width = @max(0.0, width),
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeHairlinePath(self: *Scene2D, path: *const Path, color: Color) !void {
        const path_index = self.paths.items.len;
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .stroke_path = .{
            .path_index = path_index,
            .width = 1.0,
            .cap = .butt,
            .join = .bevel,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokePathCap(self: *Scene2D, path: *const Path, width: f32, cap: LineCap, color: Color) !void {
        try self.strokePathCapJoin(path, width, cap, .miter, color);
    }

    pub fn strokePathCapJoin(self: *Scene2D, path: *const Path, width: f32, cap: LineCap, join: LineJoin, color: Color) !void {
        try self.strokePathCapJoinMiterLimit(path, width, cap, join, 4.0, color);
    }

    pub fn strokePathCapJoinMiterLimit(self: *Scene2D, path: *const Path, width: f32, cap: LineCap, join: LineJoin, miter_limit: f32, color: Color) !void {
        const path_index = self.paths.items.len;
        const stroke_scale = self.strokeScale();
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .stroke_path = .{
            .path_index = path_index,
            .width = @max(0.0, width * stroke_scale),
            .cap = cap,
            .join = join,
            .miter_limit = @max(1.0, miter_limit),
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
        } });
    }

    pub fn strokePathCurrent(self: *Scene2D, path: *const Path, color: Color) !void {
        const style = self.current_stroke_style;
        if (style.hairline) return self.strokeHairlinePath(path, color);
        if (style.dash.count > 0) return self.strokePathPattern(path, style.width, style.dash, style.cap, color);
        try self.strokePathCapJoinMiterLimit(path, style.width, style.cap, style.join, style.miter_limit, color);
    }

    pub fn strokeLinearGradientPath(self: *Scene2D, path: *const Path, gradient: LinearGradient, style: StrokeStyle) !void {
        const path_index = self.paths.items.len;
        const stroke_scale = self.strokeScale();
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        const scaled_pattern = scaleDashPattern(style.dash, stroke_scale);
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .stroke_linear_gradient_path = .{
            .path_index = path_index,
            .gradient = g,
            .width = @max(0.0, style.width * stroke_scale),
            .cap = style.cap,
            .join = style.join,
            .miter_limit = @max(1.0, style.miter_limit),
            .dash_pattern = scaled_pattern,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeRadialGradientPath(self: *Scene2D, path: *const Path, gradient: RadialGradient, style: StrokeStyle) !void {
        const path_index = self.paths.items.len;
        const stroke_scale = self.strokeScale();
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        const scaled_pattern = scaleDashPattern(style.dash, stroke_scale);
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .stroke_radial_gradient_path = .{
            .path_index = path_index,
            .gradient = g,
            .width = @max(0.0, style.width * stroke_scale),
            .cap = style.cap,
            .join = style.join,
            .miter_limit = @max(1.0, style.miter_limit),
            .dash_pattern = scaled_pattern,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokeSweepGradientPath(self: *Scene2D, path: *const Path, gradient: SweepGradient, style: StrokeStyle) !void {
        const path_index = self.paths.items.len;
        const stroke_scale = self.strokeScale();
        var g = gradient;
        if (g.dither == .none) g.dither = self.current_dither;
        const scaled_pattern = scaleDashPattern(style.dash, stroke_scale);
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .stroke_sweep_gradient_path = .{
            .path_index = path_index,
            .gradient = g,
            .width = @max(0.0, style.width * stroke_scale),
            .cap = style.cap,
            .join = style.join,
            .miter_limit = @max(1.0, style.miter_limit),
            .dash_pattern = scaled_pattern,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
            .anti_alias = self.current_anti_alias,
        } });
    }

    pub fn strokePathSource(self: *Scene2D, path: *const Path) !void {
        try self.strokePathCurrent(path, self.current_source_color);
    }

    pub fn strokeDashedPath(self: *Scene2D, path: *const Path, width: f32, dash_on: f32, dash_off: f32, color: Color) !void {
        try self.strokeDashedPathOffset(path, width, dash_on, dash_off, 0.0, color);
    }

    pub fn strokeDashedPathOffset(self: *Scene2D, path: *const Path, width: f32, dash_on: f32, dash_off: f32, dash_offset: f32, color: Color) !void {
        try self.strokePathPattern(path, width, DashPattern.fromPair(dash_on, dash_off, dash_offset), .round, color);
    }

    pub fn strokePathPattern(self: *Scene2D, path: *const Path, width: f32, pattern: DashPattern, cap: LineCap, color: Color) !void {
        const path_index = self.paths.items.len;
        const stroke_scale = self.strokeScale();
        const scaled_pattern = scaleDashPattern(pattern, stroke_scale);
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .stroke_path = .{
            .path_index = path_index,
            .width = @max(0.0, width * stroke_scale),
            .cap = cap,
            .dash_on = if (scaled_pattern.count >= 1) scaled_pattern.segments[0] else 0.0,
            .dash_off = if (scaled_pattern.count >= 2) scaled_pattern.segments[1] else 0.0,
            .dash_offset = scaled_pattern.offset,
            .dash_pattern = scaled_pattern,
            .color = color,
            .clip = self.current_clip,
            .blend_mode = self.current_blend_mode,
            .opacity = self.current_opacity,
        } });
    }

    pub fn strokeDashedPathCap(self: *Scene2D, path: *const Path, width: f32, dash_on: f32, dash_off: f32, cap: LineCap, color: Color) !void {
        try self.strokeDashedPathCapOffset(path, width, dash_on, dash_off, 0.0, cap, color);
    }

    pub fn strokeDashedPathCapOffset(self: *Scene2D, path: *const Path, width: f32, dash_on: f32, dash_off: f32, dash_offset: f32, cap: LineCap, color: Color) !void {
        try self.strokePathPattern(path, width, DashPattern.fromPair(dash_on, dash_off, dash_offset), cap, color);
    }

    pub fn pushClipRect(self: *Scene2D, rect: math.Rect) !void {
        try self.clip_stack.append(self.allocator, self.current_clip);
        const transformed = transformRectBounds(rect, self.current_transform);
        self.current_clip = if (self.current_clip) |current| intersectRect(current, transformed) else transformed;
    }

    pub fn popClip(self: *Scene2D) void {
        self.current_clip = self.clip_stack.pop() orelse null;
    }

    pub fn pushClipPath(self: *Scene2D, path: *const Path, fill_rule: FillRule) !void {
        const path_index = self.paths.items.len;
        try self.paths.append(self.allocator, if (self.current_transform.isIdentity())
            try path.clone(self.allocator)
        else
            try path.cloneTransformed(self.allocator, self.current_transform));
        errdefer {
            var stored = self.paths.pop().?;
            stored.deinit();
        }
        try self.primitives.append(self.allocator, .{ .push_clip_path = .{
            .path_index = path_index,
            .fill_rule = fill_rule,
        } });
    }

    pub fn pushClipPathCurrent(self: *Scene2D, path: *const Path) !void {
        try self.pushClipPath(path, self.current_fill_rule);
    }

    pub fn popClipPath(self: *Scene2D) !void {
        try self.primitives.append(self.allocator, .pop_clip_path);
    }

    pub fn pushBlendMode(self: *Scene2D, mode: BlendMode) !void {
        try self.blend_stack.append(self.allocator, self.current_blend_mode);
        self.current_blend_mode = mode;
    }

    pub fn getBlendMode(self: *const Scene2D) BlendMode {
        return self.current_blend_mode;
    }

    pub fn popBlendMode(self: *Scene2D) void {
        self.current_blend_mode = self.blend_stack.pop() orelse .source_over;
    }

    pub fn pushFillRule(self: *Scene2D, fill_rule: FillRule) !void {
        try self.fill_rule_stack.append(self.allocator, self.current_fill_rule);
        self.current_fill_rule = fill_rule;
    }

    pub fn getFillRule(self: *const Scene2D) FillRule {
        return self.current_fill_rule;
    }

    pub fn popFillRule(self: *Scene2D) void {
        self.current_fill_rule = self.fill_rule_stack.pop() orelse .non_zero;
    }

    pub fn pushStrokeStyle(self: *Scene2D, style: StrokeStyle) !void {
        try self.stroke_style_stack.append(self.allocator, self.current_stroke_style);
        self.current_stroke_style = style;
    }

    pub fn getStrokeStyle(self: *const Scene2D) StrokeStyle {
        return self.current_stroke_style;
    }

    pub fn popStrokeStyle(self: *Scene2D) void {
        self.current_stroke_style = self.stroke_style_stack.pop() orelse .{};
    }

    pub fn pushAntiAlias(self: *Scene2D, mode: AntiAliasMode) !void {
        try self.anti_alias_stack.append(self.allocator, self.current_anti_alias);
        self.current_anti_alias = mode;
    }

    pub fn getAntiAlias(self: *const Scene2D) AntiAliasMode {
        return self.current_anti_alias;
    }

    pub fn popAntiAlias(self: *Scene2D) void {
        self.current_anti_alias = self.anti_alias_stack.pop() orelse .default;
    }

    pub fn setDither(self: *Scene2D, dither: DitherMode) void {
        self.current_dither = dither;
    }

    pub fn getDither(self: *const Scene2D) DitherMode {
        return self.current_dither;
    }

    pub fn setSourceColor(self: *Scene2D, color: Color) void {
        self.current_source_color = color;
    }

    pub fn getSourceColor(self: *const Scene2D) Color {
        return self.current_source_color;
    }

    pub fn getTransform(self: *const Scene2D) math.Affine2D {
        return self.current_transform;
    }

    pub fn getTransformation(self: *const Scene2D) math.Affine2D {
        return self.getTransform();
    }

    pub fn setTransform(self: *Scene2D, transform: math.Affine2D) void {
        self.current_transform = transform;
    }

    pub fn setTransformation(self: *Scene2D, transform: math.Affine2D) void {
        self.setTransform(transform);
    }

    pub fn setIdentityTransform(self: *Scene2D) void {
        self.current_transform = .identity;
    }

    pub fn setIdentity(self: *Scene2D) void {
        self.setIdentityTransform();
    }

    pub fn mulTransform(self: *Scene2D, transform: math.Affine2D) void {
        self.current_transform = self.current_transform.mul(transform);
    }

    pub fn mul(self: *Scene2D, transform: math.Affine2D) void {
        self.mulTransform(transform);
    }

    pub fn translate(self: *Scene2D, tx: f32, ty: f32) void {
        self.current_transform = self.current_transform.translate(tx, ty);
    }

    pub fn scaleTransform(self: *Scene2D, sx: f32, sy: f32) void {
        self.current_transform = self.current_transform.scale(sx, sy);
    }

    pub fn scale(self: *Scene2D, sx: f32, sy: f32) void {
        self.scaleTransform(sx, sy);
    }

    pub fn rotate(self: *Scene2D, radians: f32) void {
        self.current_transform = self.current_transform.rotate(radians);
    }

    pub fn userToDevice(self: *const Scene2D, point: math.Vec2) math.Vec2 {
        return self.current_transform.transformPoint(point);
    }

    pub fn userToDeviceDistance(self: *const Scene2D, distance: math.Vec2) math.Vec2 {
        return self.current_transform.transformVector(distance);
    }

    pub fn deviceToUser(self: *const Scene2D, point: math.Vec2) ?math.Vec2 {
        const inverse = self.current_transform.inverse() orelse return null;
        return inverse.transformPoint(point);
    }

    pub fn deviceToUserDistance(self: *const Scene2D, distance: math.Vec2) ?math.Vec2 {
        const inverse = self.current_transform.inverse() orelse return null;
        return inverse.transformVector(distance);
    }

    pub fn setLineWidth(self: *Scene2D, width: f32) void {
        self.current_stroke_style.width = @max(0.0, width);
    }

    pub fn getLineWidth(self: *const Scene2D) f32 {
        return self.current_stroke_style.width;
    }

    pub fn setLineCap(self: *Scene2D, cap: LineCap) void {
        self.current_stroke_style.cap = cap;
    }

    pub fn getLineCap(self: *const Scene2D) LineCap {
        return self.current_stroke_style.cap;
    }

    pub fn setLineJoin(self: *Scene2D, join: LineJoin) void {
        self.current_stroke_style.join = join;
    }

    pub fn getLineJoin(self: *const Scene2D) LineJoin {
        return self.current_stroke_style.join;
    }

    pub fn setMiterLimit(self: *Scene2D, limit: f32) void {
        self.current_stroke_style.miter_limit = @max(1.0, limit);
    }

    pub fn getMiterLimit(self: *const Scene2D) f32 {
        return self.current_stroke_style.miter_limit;
    }

    pub fn setDashes(self: *Scene2D, dashes: []const f32) void {
        self.current_stroke_style.dash = DashPattern.fromSlice(dashes, self.current_stroke_style.dash.offset);
    }

    pub fn setDashOffset(self: *Scene2D, offset: f32) void {
        self.current_stroke_style.dash.offset = offset;
    }

    pub fn getDashes(self: *const Scene2D) []const f32 {
        return self.current_stroke_style.dash.segments[0..self.current_stroke_style.dash.count];
    }

    pub fn getDashOffset(self: *const Scene2D) f32 {
        return self.current_stroke_style.dash.offset;
    }

    pub fn setHairline(self: *Scene2D, enabled: bool) void {
        self.current_stroke_style.hairline = enabled;
    }

    pub fn getHairline(self: *const Scene2D) bool {
        return self.current_stroke_style.hairline;
    }

    pub fn pushOpacity(self: *Scene2D, opacity: f32) !void {
        try self.opacity_stack.append(self.allocator, self.current_opacity);
        self.current_opacity *= @min(1.0, @max(0.0, opacity));
    }

    pub fn popOpacity(self: *Scene2D) void {
        self.current_opacity = self.opacity_stack.pop() orelse 1.0;
    }

    pub fn pushTransform(self: *Scene2D, transform: math.Affine2D) !void {
        try self.transform_stack.append(self.allocator, self.current_transform);
        self.current_transform = self.current_transform.mul(transform);
    }

    pub fn popTransform(self: *Scene2D) void {
        self.current_transform = self.transform_stack.pop() orelse .identity;
    }

    fn strokeScale(self: *const Scene2D) f32 {
        const transform_scale = self.current_transform.scaleMagnitude();
        return @max(transform_scale.x, transform_scale.y);
    }

    pub fn buildSparseStrips(self: *const Scene2D, allocator: std.mem.Allocator, width: u32, height: u32) !std.ArrayList(Strip) {
        var strips: std.ArrayList(Strip) = .empty;
        errdefer strips.deinit(allocator);
        var clip_paths: std.ArrayList(ClipPath) = .empty;
        defer clip_paths.deinit(allocator);

        // Each primitive appends fully coverage-resolved horizontal spans. Clip
        // path commands update a small state stack; after a primitive emits spans,
        // only the newly-added region is filtered through active clip paths.
        for (self.primitives.items) |prim| {
            switch (prim) {
                .push_clip_path => |clip| {
                    try clip_paths.append(allocator, clip);
                    continue;
                },
                .pop_clip_path => {
                    _ = clip_paths.pop();
                    continue;
                },
                else => {},
            }
            const start = strips.items.len;
            switch (prim) {
                .fill_rect => |rect| try appendRectStrips(allocator, &strips, rect, width, height),
                .drop_shadow_rect => |rect| try appendDropShadowRectStrips(allocator, &strips, rect, width, height),
                .fill_linear_gradient_rect => |rect| try appendLinearGradientRectStrips(allocator, &strips, rect, width, height),
                .fill_radial_gradient_rect => |rect| try appendRadialGradientRectStrips(allocator, &strips, rect, width, height),
                .fill_sweep_gradient_rect => |rect| try appendSweepGradientRectStrips(allocator, &strips, rect, width, height),
                .fill_image_rect => |rect| try appendImageRectStrips(allocator, &strips, rect, &self.images.items[rect.image_index], width, height),
                .masked_rect => |rect| try appendMaskedRectStrips(allocator, &strips, rect, &self.images.items[rect.mask_index], width, height),
                .fill_text => |text| try appendTextStrips(allocator, &strips, text, &self.fonts.items[text.font_index].font, width, height),
                .line => |line| try appendLineStrips(allocator, &strips, line, width, height),
                .ellipse => |ellipse| try appendEllipseStrips(allocator, &strips, ellipse, width, height),
                .triangle => |tri| try appendTriangleStrips(allocator, &strips, tri, width, height),
                .fill_path => |fill_prim| try appendPathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[fill_prim.path_index],
                    fill_prim,
                    width,
                    height,
                ),
                .fill_linear_gradient_path => |fill_prim| try appendLinearGradientPathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[fill_prim.path_index],
                    fill_prim,
                    width,
                    height,
                ),
                .fill_radial_gradient_path => |fill_prim| try appendRadialGradientPathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[fill_prim.path_index],
                    fill_prim,
                    width,
                    height,
                ),
                .fill_sweep_gradient_path => |fill_prim| try appendSweepGradientPathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[fill_prim.path_index],
                    fill_prim,
                    width,
                    height,
                ),
                .stroke_path => |stroke_prim| try appendStrokePathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[stroke_prim.path_index],
                    stroke_prim,
                    width,
                    height,
                ),
                .stroke_linear_gradient_path => |stroke_prim| try appendLinearGradientStrokePathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[stroke_prim.path_index],
                    stroke_prim,
                    width,
                    height,
                ),
                .stroke_radial_gradient_path => |stroke_prim| try appendRadialGradientStrokePathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[stroke_prim.path_index],
                    stroke_prim,
                    width,
                    height,
                ),
                .stroke_sweep_gradient_path => |stroke_prim| try appendSweepGradientStrokePathStrips(
                    allocator,
                    &strips,
                    &self.paths.items[stroke_prim.path_index],
                    stroke_prim,
                    width,
                    height,
                ),
                .push_clip_path, .pop_clip_path => unreachable,
            }
            if (clip_paths.items.len > 0) {
                try applyClipPathsToNewStrips(allocator, &strips, start, clip_paths.items, self.paths.items);
            }
        }

        return strips;
    }
};

fn appendRectStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillRect,
    target_width: u32,
    target_height: u32,
) !void {
    var bounds = rectBounds(fill.rect, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) {
            const tile_end = @min(bounds.x1, alignForward(x + 1, Tile.width));
            try appendStrip(allocator, strips, x, y, tile_end - x, applyOpacity(fill.color, fill.opacity), fill.blend_mode);
            x = tile_end;
        }
    }
}

fn appendDropShadowRectStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    shadow: DropShadowRect,
    target_width: u32,
    target_height: u32,
) !void {
    const offset_transform = (math.Affine2D{ .tx = shadow.offset.x, .ty = shadow.offset.y }).mul(shadow.area.transform);
    const base = TransformedRect{ .rect = shadow.area.rect, .transform = offset_transform };
    const base_bounds = base.floatBounds();
    const expanded = math.Rect{
        .x = base_bounds.x - shadow.blur_radius,
        .y = base_bounds.y - shadow.blur_radius,
        .w = base_bounds.w + shadow.blur_radius * 2.0,
        .h = base_bounds.h + shadow.blur_radius * 2.0,
    };
    var bounds = rectBounds(expanded, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(shadow.clip, target_width, target_height)) orelse return;
    const inverse = base.inverse() orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) {
            const alpha_scale = shadowAlphaAtLocal(localSamplePoint(inverse, x, y), shadow.area.rect, shadow.blur_radius);
            if (alpha_scale <= 0.0) {
                x += 1;
                continue;
            }

            const color = applyOpacity(shadow.color, shadow.opacity * alpha_scale);
            const start = x;
            x += 1;
            while (x < bounds.x1 and @abs(shadowAlphaAtLocal(localSamplePoint(inverse, x, y), shadow.area.rect, shadow.blur_radius) - alpha_scale) < 0.000001 and x % Tile.width != 0) : (x += 1) {}
            try appendStrip(allocator, strips, start, y, x - start, color, shadow.blend_mode);
        }
    }
}

fn appendLinearGradientRectStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillLinearGradientRect,
    target_width: u32,
    target_height: u32,
) !void {
    const inverse = fill.area.inverse() orelse return;
    var bounds = fill.area.bounds(target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;
    const axis = fill.gradient.end.sub(fill.gradient.start);
    const axis_len_sq = axis.x * axis.x + axis.y * axis.y;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = localSamplePoint(inverse, x, y);
            if (!pointInRect(sample, fill.area.rect)) continue;
            const t = if (axis_len_sq <= 0.000001) 0.0 else sample.sub(fill.gradient.start).dot(axis) / axis_len_sq;
            try appendStrip(
                allocator,
                strips,
                x,
                y,
                1,
                applyOpacity(applyGradientDither(sampleLinearGradient(fill.gradient, t), fill.gradient.dither, x, y), fill.opacity),
                fill.blend_mode,
            );
        }
    }
}

fn appendRadialGradientRectStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillRadialGradientRect,
    target_width: u32,
    target_height: u32,
) !void {
    if (fill.gradient.radius <= 0.000001) return;
    const inverse = fill.area.inverse() orelse return;
    var bounds = fill.area.bounds(target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = localSamplePoint(inverse, x, y);
            if (!pointInRect(sample, fill.area.rect)) continue;
            const t = radialGradientT(fill.gradient, sample) orelse continue;
            try appendStrip(
                allocator,
                strips,
                x,
                y,
                1,
                applyOpacity(applyGradientDither(sampleRadialGradient(fill.gradient, t), fill.gradient.dither, x, y), fill.opacity),
                fill.blend_mode,
            );
        }
    }
}

fn sampleLinearGradient(gradient: LinearGradient, t: f32) Color {
    return sampleGradientStops(gradient.stops, gradient.stop_count, gradient.start_color, gradient.end_color, applyGradientSpread(t, gradient.spread), gradient.interpolation);
}

fn sampleRadialGradient(gradient: RadialGradient, t: f32) Color {
    return sampleGradientStops(gradient.stops, gradient.stop_count, gradient.inner_color, gradient.outer_color, applyGradientSpread(t, gradient.spread), gradient.interpolation);
}

fn radialGradientT(gradient: RadialGradient, sample: math.Vec2) ?f32 {
    const c0 = gradient.inner_center orelse gradient.center;
    const c1 = gradient.center;
    const r0 = @max(0.0, gradient.inner_radius);
    const r1 = gradient.radius;
    if (r1 <= 0.000001 and r0 <= 0.000001) return null;

    const cd = c1.sub(c0);
    const pd = sample.sub(c0);
    const dr = r1 - r0;
    const a = cd.dot(cd) - dr * dr;
    const b = pd.dot(cd) + r0 * dr;
    const c = pd.dot(pd) - r0 * r0;
    const min_dr = -r0;

    if (@abs(a) <= 0.000001) {
        if (@abs(b) <= 0.000001) return null;
        const t = 0.5 * c / b;
        if (t * dr >= min_dr) return @min(1.0, @max(0.0, t));
        return null;
    }

    const discr = b * b - a * c;
    if (discr < 0.0) return null;
    const sqrt_discr = @sqrt(discr);
    const t0 = (b + sqrt_discr) / a;
    const t1 = (b - sqrt_discr) / a;
    if (t0 * dr >= min_dr) return @min(1.0, @max(0.0, t0));
    if (t1 * dr >= min_dr) return @min(1.0, @max(0.0, t1));
    return null;
}

fn sampleSweepGradient(gradient: SweepGradient, t: f32) Color {
    return sampleGradientStops(gradient.stops, gradient.stop_count, gradient.start_color, gradient.end_color, applyGradientSpread(t, gradient.spread), gradient.interpolation);
}

fn applyGradientSpread(t: f32, spread: GradientSpread) f32 {
    return switch (spread) {
        .pad => t,
        .repeat => t - @floor(t),
        .reflect => blk: {
            const period = t - @floor(t / 2.0) * 2.0;
            break :blk if (period <= 1.0) period else 2.0 - period;
        },
    };
}

fn sampleGradientStops(stops: [max_gradient_stops]GradientStop, stop_count: u8, fallback_start: Color, fallback_end: Color, t: f32, interpolation: GradientInterpolation) Color {
    const count: usize = @intCast(stop_count);
    if (count < 2) return lerpGradientColor(fallback_start, fallback_end, t, interpolation);
    const clamped = @min(1.0, @max(0.0, t));
    if (clamped <= stops[0].offset) return stops[0].color;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const prev = stops[i - 1];
        const next = stops[i];
        if (clamped <= next.offset) {
            const span = next.offset - prev.offset;
            const local_t = if (span <= 0.000001) 0.0 else (clamped - prev.offset) / span;
            return lerpGradientColor(prev.color, next.color, local_t, interpolation);
        }
    }
    return stops[count - 1].color;
}

fn addGradientStop(stops: *[max_gradient_stops]GradientStop, stop_count: *u8, offset: f32, color: Color) !void {
    if (stop_count.* >= max_gradient_stops) return error.GradientStopCapacityExceeded;
    addGradientStopAssumeCapacity(stops, stop_count, offset, color);
}

fn addGradientStopAssumeCapacity(stops: *[max_gradient_stops]GradientStop, stop_count: *u8, offset: f32, color: Color) void {
    const clamped = @min(1.0, @max(0.0, offset));
    var idx: usize = @intCast(stop_count.*);
    while (idx > 0 and stops[idx - 1].offset > clamped) : (idx -= 1) {
        stops[idx] = stops[idx - 1];
    }
    stops[idx] = .{ .offset = clamped, .color = color };
    stop_count.* += 1;
}

fn lerpGradientColor(a: Color, b: Color, t: f32, interpolation: GradientInterpolation) Color {
    return switch (interpolation) {
        .srgb => Color.lerp(a, b, t),
        .linear_rgb => Color.lerpLinearRgb(a, b, t),
    };
}

fn applyGradientDither(c: Color, mode: DitherMode, x: u32, y: u32) Color {
    return switch (mode) {
        .none => c,
        .bayer => blk: {
            const m = bayer8x8(@intCast(x), @intCast(y)) / 255.0;
            break :blk .{
                .r = ditherChannel(c.r, m),
                .g = ditherChannel(c.g, m),
                .b = ditherChannel(c.b, m),
                .a = c.a,
            };
        },
        .blue_noise => blk: {
            const m = blueNoise64x64(@intCast(x), @intCast(y)) / 255.0;
            break :blk .{
                .r = ditherChannel(c.r, m),
                .g = ditherChannel(c.g, m),
                .b = ditherChannel(c.b, m),
                .a = c.a,
            };
        },
    };
}

fn ditherChannel(channel: u8, offset: f32) u8 {
    const value = @as(f32, @floatFromInt(channel)) + offset;
    return @intFromFloat(@floor(@min(255.0, @max(0.0, value))));
}

fn bayer8x8(x: i32, y: i32) f32 {
    const _y = y ^ x;
    const m: u32 = @intCast((_y & 1) << 5 | (x & 1) << 4 |
        (_y & 2) << 2 | (x & 2) << 1 |
        (_y & 4) >> 1 | (x & 4) >> 2);
    return @as(f32, @floatFromInt(m)) * (2.0 / 128.0) - (63.0 / 128.0);
}

fn blueNoise64x64(x: i32, y: i32) f32 {
    var n: u32 = @as(u32, @intCast(@mod(x, 64))) *% 0x9E37_79B9;
    n ^= @as(u32, @intCast(@mod(y, 64))) *% 0x85EB_CA6B;
    n ^= n >> 16;
    n *%= 0x7FEB_352D;
    n ^= n >> 15;
    n *%= 0x846C_A68B;
    n ^= n >> 16;
    return (@as(f32, @floatFromInt(n & 0xfff)) * (2.0 / 8192.0)) - (4095.0 / 8192.0);
}

fn appendSweepGradientRectStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillSweepGradientRect,
    target_width: u32,
    target_height: u32,
) !void {
    const inverse = fill.area.inverse() orelse return;
    var bounds = fill.area.bounds(target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = localSamplePoint(inverse, x, y);
            if (!pointInRect(sample, fill.area.rect)) continue;
            const t = sweepGradientT(sample, fill.gradient.center, fill.gradient.start_angle);
            try appendStrip(
                allocator,
                strips,
                x,
                y,
                1,
                applyOpacity(applyGradientDither(sampleSweepGradient(fill.gradient, t), fill.gradient.dither, x, y), fill.opacity),
                fill.blend_mode,
            );
        }
    }
}

fn appendImageRectStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillImageRect,
    image: *const ImageSource,
    target_width: u32,
    target_height: u32,
) !void {
    if (image.width == 0 or image.height == 0 or fill.area.rect.w <= 0 or fill.area.rect.h <= 0) return;
    const source = fill.source_rect orelse math.Rect{
        .x = 0,
        .y = 0,
        .w = @as(f32, @floatFromInt(image.width)),
        .h = @as(f32, @floatFromInt(image.height)),
    };
    if (source.w <= 0 or source.h <= 0) return;
    const inverse = fill.area.inverse() orelse return;
    var bounds = fill.area.bounds(target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = localSamplePoint(inverse, x, y);
            if (!pointInRect(sample, fill.area.rect)) continue;
            const u = (sample.x - fill.area.rect.x) / fill.area.rect.w;
            const v = (sample.y - fill.area.rect.y) / fill.area.rect.h;
            const sx = sampleImageSourceCoord(source.x + @min(0.999999, @max(0.0, u)) * source.w, image.width);
            const sy = sampleImageSourceCoord(source.y + @min(0.999999, @max(0.0, v)) * source.h, image.height);
            try appendStrip(
                allocator,
                strips,
                x,
                y,
                1,
                applyOpacity(image.pixels[sy * image.width + sx], fill.opacity),
                fill.blend_mode,
            );
        }
    }
}

fn appendMaskedRectStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: MaskedRect,
    mask: *const ImageSource,
    target_width: u32,
    target_height: u32,
) !void {
    if (mask.width == 0 or mask.height == 0 or fill.area.rect.w <= 0 or fill.area.rect.h <= 0) return;
    const inverse = fill.area.inverse() orelse return;
    var bounds = fill.area.bounds(target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var span_start: ?u32 = null;
        var span_color: Color = fill.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = localSamplePoint(inverse, x, y);
            if (!pointInRect(sample, fill.area.rect)) continue;
            const u = (sample.x - fill.area.rect.x) / fill.area.rect.w;
            const v = (sample.y - fill.area.rect.y) / fill.area.rect.h;
            const sx = sampleCoord(u, mask.width);
            const sy = sampleCoord(v, mask.height);
            const mask_alpha = @as(f32, @floatFromInt(mask.pixels[sy * mask.width + sx].a)) / 255.0;
            const covered_color = fill.color.withAlphaScale(fill.opacity * mask_alpha);
            if (covered_color.a > 0) {
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, fill.blend_mode);
        }
    }
}

fn appendTextStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillText,
    font: *const cangjie.Font,
    target_width: u32,
    target_height: u32,
) anyerror!void {
    if (fill.text.len == 0 or fill.size <= 0.000001) return;

    // Pure uniform scale can be folded into the font size before rasterization.
    // That keeps text sampling in mask space crisp and avoids resampling an
    // already-rasterized glyph mask.
    if (try appendAxisScaledTextStrips(allocator, strips, fill, font, target_width, target_height)) return;

    var layout_buffer = cangjie.LayoutBuffer.init(allocator);
    defer layout_buffer.deinit();
    const run = try cangjie.TextShaper.shapeUtf8(font, &layout_buffer, fill.text, fill.size);
    if (run.glyphs.len == 0) return;

    const text_width = @max(1.0, @ceil(run.width()) + 2.0);
    const scale = fill.size / @as(f32, @floatFromInt(font.units_per_em));
    const ascent = @max(0.0, @as(f32, @floatFromInt(font.ascender)) * scale);
    const descent = @max(0.0, @as(f32, @floatFromInt(-font.descender)) * scale);
    const text_height = @max(1.0, @ceil(ascent + descent) + 2.0);
    const mask_width: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(std.math.maxInt(u32))), text_width));
    const mask_height: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(std.math.maxInt(u32))), text_height));
    if (mask_width == 0 or mask_height == 0) return;

    var target = try cangjie.RenderTarget.init(allocator, mask_width, mask_height);
    defer target.deinit();
    var rasterizer = cangjie.Rasterizer.init(allocator);
    rasterizer.samples_per_axis = @max(1, fill.raster_samples_per_axis);
    try rasterizer.renderRun(&target, run, 1.0, 1.0 + ascent);

    // Render glyphs into a temporary grayscale mask first, then convert coverage
    // runs into strips. This keeps the Scene2D backend boundary independent from
    // cangjie internals while preserving subpixel coverage.
    const dst_x = fill.origin.x - 1.0;
    const dst_y = fill.origin.y - ascent - 1.0;
    if (try appendAxisAlignedTextMaskStrips(allocator, strips, fill, &target, dst_x, dst_y, target_width, target_height)) return;
    const text_rect: math.Rect = .{
        .x = dst_x,
        .y = dst_y,
        .w = @floatFromInt(mask_width),
        .h = @floatFromInt(mask_height),
    };
    const text_area = TransformedRect{ .rect = text_rect, .transform = fill.transform };
    const inverse = text_area.inverse() orelse return;
    var bounds = text_area.bounds(target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var span_start: ?u32 = null;
        var span_color: Color = fill.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = localSamplePoint(inverse, x, y);
            const mx_f = sample.x - dst_x;
            const my_f = sample.y - dst_y;
            if (mx_f < 0.0 or my_f < 0.0) continue;
            const mx: u32 = @intFromFloat(@floor(mx_f));
            const my: u32 = @intFromFloat(@floor(my_f));
            if (mx >= mask_width or my >= mask_height) continue;
            const raw_coverage = @as(f32, @floatFromInt(target.at(mx, my))) / 255.0;
            const coverage = applyAntiAliasCoverage(textCoverageContrast(raw_coverage), fill.anti_alias);
            if (coverage > 0.0) {
                const covered_color = fill.color.withAlphaScale(coverage * fill.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, fill.blend_mode);
        }
    }
}

fn appendAxisAlignedTextMaskStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillText,
    target: *const cangjie.RenderTarget,
    dst_x: f32,
    dst_y: f32,
    target_width: u32,
    target_height: u32,
) !bool {
    const transform = fill.transform;
    if (transform.by != 0 or transform.cx != 0) return false;
    if (@abs(transform.ax - 1.0) > 0.0001 or @abs(transform.dy - 1.0) > 0.0001) return false;

    const text_rect: math.Rect = .{
        .x = dst_x + transform.tx,
        .y = dst_y + transform.ty,
        .w = @floatFromInt(target.width),
        .h = @floatFromInt(target.height),
    };
    var bounds = rectBounds(text_rect, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return true;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        const mask_y_f = @as(f32, @floatFromInt(y)) + 0.5 - text_rect.y;
        if (mask_y_f < 0.0) continue;
        const mask_y: u32 = @intFromFloat(@floor(mask_y_f));
        if (mask_y >= target.height) continue;
        const row_start = @as(usize, mask_y) * target.width;
        var span_start: ?u32 = null;
        var span_color: Color = fill.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const mask_x_f = @as(f32, @floatFromInt(x)) + 0.5 - text_rect.x;
            if (mask_x_f < 0.0) {
                if (span_start) |start| {
                    try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    span_start = null;
                }
                continue;
            }
            const mask_x: u32 = @intFromFloat(@floor(mask_x_f));
            if (mask_x >= target.width) {
                if (span_start) |start| {
                    try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    span_start = null;
                }
                continue;
            }
            const raw_coverage = @as(f32, @floatFromInt(target.pixels[row_start + mask_x])) / 255.0;
            const coverage = applyAntiAliasCoverage(textCoverageContrast(raw_coverage), fill.anti_alias);
            if (coverage > 0.0) {
                const covered_color = fill.color.withAlphaScale(coverage * fill.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, fill.blend_mode);
        }
    }
    return true;
}

fn appendAxisScaledTextStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    fill: FillText,
    font: *const cangjie.Font,
    target_width: u32,
    target_height: u32,
) anyerror!bool {
    const transform = fill.transform;
    if (transform.by != 0 or transform.cx != 0) return false;
    const sx = transform.ax;
    const sy = transform.dy;
    if (sx <= 0 or sy <= 0) return false;
    if (@abs(sx - sy) > 0.0001) return false;
    if (@abs(sx - 1.0) < 0.0001 and @abs(sy - 1.0) < 0.0001 and @abs(transform.tx) < 0.0001 and @abs(transform.ty) < 0.0001) return false;
    const scaled_fill = FillText{
        .font_index = fill.font_index,
        .text = fill.text,
        .origin = transform.transformPoint(fill.origin),
        .size = fill.size * @max(sx, sy),
        .transform = .identity,
        .color = fill.color,
        .clip = fill.clip,
        .blend_mode = fill.blend_mode,
        .opacity = fill.opacity,
        .anti_alias = fill.anti_alias,
        .raster_samples_per_axis = fill.raster_samples_per_axis,
    };
    try appendTextStrips(allocator, strips, scaled_fill, font, target_width, target_height);
    return true;
}

fn textCoverageContrast(coverage: f32) f32 {
    const c = @min(1.0, @max(0.0, coverage));
    if (c >= 0.82) return 1.0;
    if (c <= 0.08) return 0.0;
    const t = (c - 0.08) / 0.74;
    return t * t * (3.0 - 2.0 * t);
}

fn appendLineStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    line: Line,
    target_width: u32,
    target_height: u32,
) !void {
    const radius = @max(line.width * 0.5, 0.5);
    const aa_radius = radius + 0.5;
    const min_x = @min(line.a.x, line.b.x) - aa_radius;
    const min_y = @min(line.a.y, line.b.y) - aa_radius;
    const max_x = @max(line.a.x, line.b.x) + aa_radius;
    const max_y = @max(line.a.y, line.b.y) + aa_radius;
    var bounds = BoundsU32{
        .x0 = clampFloor(min_x, 0, target_width),
        .y0 = clampFloor(min_y, 0, target_height),
        .x1 = clampCeil(max_x, 0, target_width),
        .y1 = clampCeil(max_y, 0, target_height),
    };
    bounds = intersectBounds(bounds, clipBounds(line.clip, target_width, target_height)) orelse return;
    const ab = line.b.sub(line.a);
    const len_sq = ab.x * ab.x + ab.y * ab.y;
    const len = @sqrt(len_sq);

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var span_start: ?u32 = null;
        var span_color: Color = line.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
            const dash_distance = lineDashDistance(sample, line, ab, len_sq);
            const distance = @max(lineDistance(sample, line, ab, len_sq, len), dash_distance);
            const coverage = applyAntiAliasCoverage(@min(1.0, @max(0.0, aa_radius - distance)), line.anti_alias);
            if (coverage > 0.0) {
                const covered_color = line.color.withAlphaScale(coverage * line.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, line.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, line.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, line.blend_mode);
        }
    }
}

fn appendEllipseStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    ellipse: Ellipse,
    target_width: u32,
    target_height: u32,
) !void {
    if (ellipse.radius.x <= 0.000001 or ellipse.radius.y <= 0.000001) return;
    if ((ellipse.mode == .stroke or ellipse.mode == .arc) and ellipse.stroke_width <= 0.000001) return;
    const inflate = if (ellipse.mode == .stroke or ellipse.mode == .arc) ellipse.stroke_width * 0.5 + 1.0 else 1.0;
    var bounds = BoundsU32{
        .x0 = clampFloor(ellipse.center.x - ellipse.radius.x - inflate, 0, target_width),
        .y0 = clampFloor(ellipse.center.y - ellipse.radius.y - inflate, 0, target_height),
        .x1 = clampCeil(ellipse.center.x + ellipse.radius.x + inflate, 0, target_width),
        .y1 = clampCeil(ellipse.center.y + ellipse.radius.y + inflate, 0, target_height),
    };
    bounds = intersectBounds(bounds, clipBounds(ellipse.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var span_start: ?u32 = null;
        var span_color: Color = ellipse.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(switch (ellipse.mode) {
                .fill => ellipsePixelCoverage(ellipse.center, ellipse.radius, x, y),
                .stroke => strokedEllipsePixelCoverage(ellipse.center, ellipse.radius, ellipse.stroke_width, x, y),
                .sector => arcSectorPixelCoverage(ellipse.center, ellipse.radius, ellipse.start_angle, ellipse.end_angle, x, y),
                .arc => strokedArcPixelCoverage(ellipse.center, ellipse.radius, ellipse.stroke_width, ellipse.start_angle, ellipse.end_angle, x, y),
            }, ellipse.anti_alias);
            if (coverage > 0.0) {
                const covered_color = ellipse.color.withAlphaScale(coverage * ellipse.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, ellipse.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, ellipse.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, ellipse.blend_mode);
        }
    }
}

fn appendTriangleStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    tri: Triangle2D,
    target_width: u32,
    target_height: u32,
) !void {
    var bounds = triangleBounds(tri.positions, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(tri.clip, target_width, target_height)) orelse return;
    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var span_start: ?u32 = null;
        var span_color: Color = tri.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(trianglePixelCoverage(tri.positions, x, y), tri.anti_alias);
            if (coverage > 0.0) {
                const covered_color = tri.color.withAlphaScale(coverage * tri.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, tri.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, tri.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, tri.blend_mode);
        }
    }
}

fn appendPathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    fill: FillPath,
    target_width: u32,
    target_height: u32,
) !void {
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPathForFill(allocator, path, &edges);
    if (edges.items.len == 0) return;

    // For filled paths, cache sorted scanline intersections for each sub-sample
    // row. Pixels on the same output row then reuse the edge walk and only test
    // their x-position against the cached winding/crossing list.
    var coverage_rows: PathCoverageRows = @splat(.empty);
    defer deinitPathCoverageRows(allocator, &coverage_rows);

    var bounds = edgeBounds(edges.items, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;
    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectPathCoverageRows(allocator, &coverage_rows, edges.items, y);
        var span_start: ?u32 = null;
        var span_color: Color = fill.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(pathPixelCoverageFromRows(&coverage_rows, x, fill.fill_rule), fill.anti_alias);
            if (coverage > 0.0) {
                const covered_color = fill.color.withAlphaScale(coverage * fill.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, fill.blend_mode);
        }
    }
}

fn appendLinearGradientPathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    fill: FillLinearGradientPath,
    target_width: u32,
    target_height: u32,
) !void {
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPathForFill(allocator, path, &edges);
    if (edges.items.len == 0) return;

    var coverage_rows: PathCoverageRows = @splat(.empty);
    defer deinitPathCoverageRows(allocator, &coverage_rows);

    var bounds = edgeBounds(edges.items, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;
    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectPathCoverageRows(allocator, &coverage_rows, edges.items, y);
        var span_start: ?u32 = null;
        var span_color: Color = .transparent;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(pathPixelCoverageFromRows(&coverage_rows, x, fill.fill_rule), fill.anti_alias);
            if (coverage > 0.0) {
                const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
                const color = applyGradientDither(fill.gradient.sampleAt(sample), fill.gradient.dither, x, y).withAlphaScale(coverage * fill.opacity);
                if (span_start == null or color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    }
                    span_start = x;
                    span_color = color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, fill.blend_mode);
        }
    }
}

fn appendRadialGradientPathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    fill: FillRadialGradientPath,
    target_width: u32,
    target_height: u32,
) !void {
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPathForFill(allocator, path, &edges);
    if (edges.items.len == 0) return;

    var coverage_rows: PathCoverageRows = @splat(.empty);
    defer deinitPathCoverageRows(allocator, &coverage_rows);
    var bounds = edgeBounds(edges.items, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectPathCoverageRows(allocator, &coverage_rows, edges.items, y);
        var span_start: ?u32 = null;
        var span_color: Color = .transparent;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(pathPixelCoverageFromRows(&coverage_rows, x, fill.fill_rule), fill.anti_alias);
            if (coverage > 0.0) {
                const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
                const color = applyGradientDither(fill.gradient.sampleAt(sample), fill.gradient.dither, x, y).withAlphaScale(coverage * fill.opacity);
                if (span_start == null or color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    span_start = x;
                    span_color = color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, fill.blend_mode);
    }
}

fn appendSweepGradientPathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    fill: FillSweepGradientPath,
    target_width: u32,
    target_height: u32,
) !void {
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPathForFill(allocator, path, &edges);
    if (edges.items.len == 0) return;

    var coverage_rows: PathCoverageRows = @splat(.empty);
    defer deinitPathCoverageRows(allocator, &coverage_rows);
    var bounds = edgeBounds(edges.items, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(fill.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectPathCoverageRows(allocator, &coverage_rows, edges.items, y);
        var span_start: ?u32 = null;
        var span_color: Color = .transparent;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(pathPixelCoverageFromRows(&coverage_rows, x, fill.fill_rule), fill.anti_alias);
            if (coverage > 0.0) {
                const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
                const color = applyGradientDither(fill.gradient.sampleAt(sample), fill.gradient.dither, x, y).withAlphaScale(coverage * fill.opacity);
                if (span_start == null or color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                    span_start = x;
                    span_color = color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, fill.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, fill.blend_mode);
    }
}

fn appendStrokePathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    stroke: StrokePath,
    target_width: u32,
    target_height: u32,
) !void {
    if (stroke.width <= 0.000001) return;
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPath(allocator, path, &edges);
    if (edges.items.len == 0) {
        if (stroke.cap == .round) {
            if (path.currentPoint()) |point| {
                try appendRoundCapPointStrips(allocator, strips, point, stroke, target_width, target_height);
            }
        }
        return;
    }

    const aa_radius = stroke.width * 0.5 + 1.0;
    var bounds = strokePathBounds(edges.items, stroke, aa_radius, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(stroke.clip, target_width, target_height)) orelse return;

    // Strokes can have many segments, so build per-edge bounds and per-row
    // candidate lists. Coverage then checks only nearby edges and joins instead
    // of scanning the entire path for every pixel.
    var edge_infos = try buildStrokeEdgeInfos(allocator, edges.items, stroke);
    defer edge_infos.deinit(allocator);
    var edge_candidate_buffer: [64]usize = undefined;
    var join_candidate_buffer: [64]usize = undefined;
    const use_stack_candidates = edge_infos.items.len <= edge_candidate_buffer.len;
    var edge_candidates: std.ArrayList(usize) = if (use_stack_candidates) std.ArrayList(usize).initBuffer(&edge_candidate_buffer) else .empty;
    defer if (!use_stack_candidates) edge_candidates.deinit(allocator);
    var join_candidates: std.ArrayList(usize) = if (use_stack_candidates) std.ArrayList(usize).initBuffer(&join_candidate_buffer) else .empty;
    defer if (!use_stack_candidates) join_candidates.deinit(allocator);

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectStrokeCandidatesForRow(allocator, &edge_candidates, &join_candidates, edge_infos.items, stroke, y);
        var span_start: ?u32 = null;
        var span_color: Color = stroke.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(strokePathPixelCoverageCached(edge_infos.items, edge_candidates.items, join_candidates.items, stroke, x, y), stroke.anti_alias);
            if (coverage > 0.0) {
                const covered_color = stroke.color.withAlphaScale(coverage * stroke.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| {
                        try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                    }
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| {
            try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, stroke.blend_mode);
        }
    }
}

fn appendLinearGradientStrokePathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    stroke: StrokeLinearGradientPath,
    target_width: u32,
    target_height: u32,
) !void {
    if (stroke.width <= 0.000001) return;
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPath(allocator, path, &edges);
    if (edges.items.len == 0) return;

    const proxy = StrokePath{
        .path_index = stroke.path_index,
        .width = stroke.width,
        .cap = stroke.cap,
        .join = stroke.join,
        .miter_limit = stroke.miter_limit,
        .dash_pattern = stroke.dash_pattern,
        .clip = stroke.clip,
        .blend_mode = stroke.blend_mode,
        .opacity = stroke.opacity,
        .anti_alias = stroke.anti_alias,
        .color = .white,
    };
    const aa_radius = proxy.width * 0.5 + 1.0;
    var bounds = strokePathBounds(edges.items, proxy, aa_radius, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(stroke.clip, target_width, target_height)) orelse return;

    var edge_infos = try buildStrokeEdgeInfos(allocator, edges.items, proxy);
    defer edge_infos.deinit(allocator);
    var edge_candidates: std.ArrayList(usize) = .empty;
    defer edge_candidates.deinit(allocator);
    var join_candidates: std.ArrayList(usize) = .empty;
    defer join_candidates.deinit(allocator);

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectStrokeCandidatesForRow(allocator, &edge_candidates, &join_candidates, edge_infos.items, proxy, y);
        var span_start: ?u32 = null;
        var span_color: Color = .transparent;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(strokePathPixelCoverageCached(edge_infos.items, edge_candidates.items, join_candidates.items, proxy, x, y), stroke.anti_alias);
            if (coverage > 0.0) {
                const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
                const color = applyGradientDither(stroke.gradient.sampleAt(sample), stroke.gradient.dither, x, y).withAlphaScale(coverage * stroke.opacity);
                if (span_start == null or color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                    span_start = x;
                    span_color = color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, stroke.blend_mode);
    }
}

fn appendRadialGradientStrokePathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    stroke: StrokeRadialGradientPath,
    target_width: u32,
    target_height: u32,
) !void {
    if (stroke.width <= 0.000001) return;
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPath(allocator, path, &edges);
    if (edges.items.len == 0) return;

    const proxy = StrokePath{ .path_index = stroke.path_index, .width = stroke.width, .cap = stroke.cap, .join = stroke.join, .miter_limit = stroke.miter_limit, .dash_pattern = stroke.dash_pattern, .clip = stroke.clip, .blend_mode = stroke.blend_mode, .opacity = stroke.opacity, .anti_alias = stroke.anti_alias, .color = .white };
    const aa_radius = proxy.width * 0.5 + 1.0;
    var bounds = strokePathBounds(edges.items, proxy, aa_radius, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(stroke.clip, target_width, target_height)) orelse return;

    var edge_infos = try buildStrokeEdgeInfos(allocator, edges.items, proxy);
    defer edge_infos.deinit(allocator);
    var edge_candidates: std.ArrayList(usize) = .empty;
    defer edge_candidates.deinit(allocator);
    var join_candidates: std.ArrayList(usize) = .empty;
    defer join_candidates.deinit(allocator);

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectStrokeCandidatesForRow(allocator, &edge_candidates, &join_candidates, edge_infos.items, proxy, y);
        var span_start: ?u32 = null;
        var span_color: Color = .transparent;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(strokePathPixelCoverageCached(edge_infos.items, edge_candidates.items, join_candidates.items, proxy, x, y), stroke.anti_alias);
            if (coverage > 0.0) {
                const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
                const color = applyGradientDither(stroke.gradient.sampleAt(sample), stroke.gradient.dither, x, y).withAlphaScale(coverage * stroke.opacity);
                if (span_start == null or color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                    span_start = x;
                    span_color = color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, stroke.blend_mode);
    }
}

fn appendSweepGradientStrokePathStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    path: *const Path,
    stroke: StrokeSweepGradientPath,
    target_width: u32,
    target_height: u32,
) !void {
    if (stroke.width <= 0.000001) return;
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPath(allocator, path, &edges);
    if (edges.items.len == 0) return;

    const proxy = StrokePath{ .path_index = stroke.path_index, .width = stroke.width, .cap = stroke.cap, .join = stroke.join, .miter_limit = stroke.miter_limit, .dash_pattern = stroke.dash_pattern, .clip = stroke.clip, .blend_mode = stroke.blend_mode, .opacity = stroke.opacity, .anti_alias = stroke.anti_alias, .color = .white };
    const aa_radius = proxy.width * 0.5 + 1.0;
    var bounds = strokePathBounds(edges.items, proxy, aa_radius, target_width, target_height);
    bounds = intersectBounds(bounds, clipBounds(stroke.clip, target_width, target_height)) orelse return;

    var edge_infos = try buildStrokeEdgeInfos(allocator, edges.items, proxy);
    defer edge_infos.deinit(allocator);
    var edge_candidates: std.ArrayList(usize) = .empty;
    defer edge_candidates.deinit(allocator);
    var join_candidates: std.ArrayList(usize) = .empty;
    defer join_candidates.deinit(allocator);

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        try collectStrokeCandidatesForRow(allocator, &edge_candidates, &join_candidates, edge_infos.items, proxy, y);
        var span_start: ?u32 = null;
        var span_color: Color = .transparent;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const coverage = applyAntiAliasCoverage(strokePathPixelCoverageCached(edge_infos.items, edge_candidates.items, join_candidates.items, proxy, x, y), stroke.anti_alias);
            if (coverage > 0.0) {
                const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
                const color = applyGradientDither(stroke.gradient.sampleAt(sample), stroke.gradient.dither, x, y).withAlphaScale(coverage * stroke.opacity);
                if (span_start == null or color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                    span_start = x;
                    span_color = color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, stroke.blend_mode);
    }
}

fn appendPixelSpan(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    y: u32,
    x0: u32,
    x1: u32,
    color: Color,
    blend_mode: BlendMode,
) !void {
    var x = x0;
    while (x < x1) {
        const tile_end = @min(x1, alignForward(x + 1, Tile.width));
        try appendStrip(allocator, strips, x, y, tile_end - x, color, blend_mode);
        x = tile_end;
    }
}

fn appendRoundCapPointStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    point: math.Vec2,
    stroke: StrokePath,
    target_width: u32,
    target_height: u32,
) !void {
    const radius = @max(stroke.width * 0.5, 0.5);
    const aa_radius = radius + 1.0;
    var bounds = BoundsU32{
        .x0 = clampFloor(point.x - aa_radius, 0, target_width),
        .y0 = clampFloor(point.y - aa_radius, 0, target_height),
        .x1 = clampCeil(point.x + aa_radius, 0, target_width),
        .y1 = clampCeil(point.y + aa_radius, 0, target_height),
    };
    bounds = intersectBounds(bounds, clipBounds(stroke.clip, target_width, target_height)) orelse return;

    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var span_start: ?u32 = null;
        var span_color = stroke.color;
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
            const dx = sample.x - point.x;
            const dy = sample.y - point.y;
            const coverage = applyAntiAliasCoverage(@min(1.0, @max(0.0, aa_radius - @sqrt(dx * dx + dy * dy))), stroke.anti_alias);
            if (coverage > 0.0) {
                const covered_color = stroke.color.withAlphaScale(coverage * stroke.opacity);
                if (span_start == null or covered_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                    span_start = x;
                    span_color = covered_color;
                }
            } else if (span_start) |start| {
                try appendPixelSpan(allocator, strips, y, start, x, span_color, stroke.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |start| try appendPixelSpan(allocator, strips, y, start, bounds.x1, span_color, stroke.blend_mode);
    }
}

fn scaleDashPattern(pattern: DashPattern, scale: f32) DashPattern {
    var out = pattern;
    out.offset *= scale;
    for (out.segments[0..out.count]) |*segment| {
        segment.* *= scale;
    }
    return out;
}

fn applyClipPathsToNewStrips(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    start: usize,
    clip_paths: []const ClipPath,
    paths: []const Path,
) !void {
    if (start >= strips.items.len) return;
    var filtered: std.ArrayList(Strip) = .empty;
    defer filtered.deinit(allocator);
    try filtered.ensureUnusedCapacity(allocator, strips.items.len - start);

    // Clip paths may cut a strip into smaller alpha-scaled spans. Rebuilding only
    // the strips emitted by the current primitive keeps earlier work untouched and
    // preserves primitive ordering.
    for (strips.items[start..]) |strip| {
        const x0: u32 = strip.x;
        const x1: u32 = strip.x + strip.width;
        var span_start: ?u32 = null;
        var span_color: Color = strip.color;
        var x = x0;
        while (x < x1) : (x += 1) {
            const coverage = try clipPathPixelCoverage(allocator, x, strip.y, clip_paths, paths);
            if (coverage > 0.0) {
                const clipped_color = strip.color.withAlphaScale(coverage);
                if (span_start == null or clipped_color.toRgba32() != span_color.toRgba32()) {
                    if (span_start) |s| {
                        try appendStrip(allocator, &filtered, s, strip.y, x - s, span_color, strip.blend_mode);
                    }
                    span_start = x;
                    span_color = clipped_color;
                }
            } else if (span_start) |s| {
                try appendStrip(allocator, &filtered, s, strip.y, x - s, span_color, strip.blend_mode);
                span_start = null;
            }
        }
        if (span_start) |s| {
            try appendStrip(allocator, &filtered, s, strip.y, x1 - s, span_color, strip.blend_mode);
        }
    }

    strips.shrinkRetainingCapacity(start);
    try strips.appendSlice(allocator, filtered.items);
}

fn clipPathPixelCoverage(
    allocator: std.mem.Allocator,
    x: u32,
    y: u32,
    clip_paths: []const ClipPath,
    paths: []const Path,
) !f32 {
    const sample_axis = path_coverage_sample_axis;
    var covered: u32 = 0;
    var sy: u32 = 0;
    while (sy < sample_axis) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < sample_axis) : (sx += 1) {
            const sample = math.Vec2{
                .x = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / sample_axis,
                .y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / sample_axis,
            };
            if (try pointInsideAllClipPaths(allocator, sample, clip_paths, paths)) covered += 1;
        }
    }
    return @as(f32, @floatFromInt(covered)) / @as(f32, @floatFromInt(sample_axis * sample_axis));
}

const path_coverage_sample_axis = 8;

fn pointInsideAllClipPaths(
    allocator: std.mem.Allocator,
    sample: math.Vec2,
    clip_paths: []const ClipPath,
    paths: []const Path,
) !bool {
    for (clip_paths) |clip| {
        if (clip.path_index >= paths.len) return false;
        if (!try pointInsidePath(allocator, &paths[clip.path_index], sample, clip.fill_rule)) return false;
    }
    return true;
}

fn pointInsidePath(allocator: std.mem.Allocator, path: *const Path, sample: math.Vec2, fill_rule: FillRule) !bool {
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(allocator);
    try flattenPath(allocator, path, &edges);
    if (edges.items.len == 0) return false;

    var intersections: std.ArrayList(PathIntersection) = .empty;
    defer intersections.deinit(allocator);
    try collectIntersections(allocator, &intersections, edges.items, sample.y);
    if (intersections.items.len == 0) return false;
    std.sort.heap(PathIntersection, intersections.items, {}, pathIntersectionLessThan);
    return pathContainsSortedIntersections(intersections.items, sample.x, fill_rule);
}

fn appendStrip(
    allocator: std.mem.Allocator,
    strips: *std.ArrayList(Strip),
    x: u32,
    y: u32,
    width: u32,
    color: Color,
    blend_mode: BlendMode,
) !void {
    if (width == 0) return;
    try strips.append(allocator, .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(width),
        .color = color,
        .blend_mode = blend_mode,
    });
}

const PathEdge = struct {
    a: math.Vec2,
    b: math.Vec2,
};

const StrokeEdgeInfo = struct {
    edge: PathEdge,
    ab: math.Vec2,
    len_sq: f32,
    len: f32,
    distance_start: f32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

const PathIntersection = struct {
    x: f32,
    winding: i32,
};

const PathCoverageRows = [path_coverage_sample_axis]std.ArrayList(PathIntersection);

const BoundsU32 = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
};

fn flattenPath(allocator: std.mem.Allocator, path: *const Path, edges: *std.ArrayList(PathEdge)) !void {
    try flattenPathImpl(allocator, path, edges, false);
}

fn flattenPathForFill(allocator: std.mem.Allocator, path: *const Path, edges: *std.ArrayList(PathEdge)) !void {
    try flattenPathImpl(allocator, path, edges, true);
}

fn flattenPathImpl(allocator: std.mem.Allocator, path: *const Path, edges: *std.ArrayList(PathEdge), close_open_subpaths: bool) !void {
    var current: math.Vec2 = .{};
    var start: math.Vec2 = .{};
    var has_current = false;
    var subpath_closed = true;

    for (path.commands.items) |cmd| {
        switch (cmd) {
            .move_to => |p| {
                if (close_open_subpaths and has_current and !subpath_closed) try appendEdge(allocator, edges, current, start);
                current = p;
                start = p;
                has_current = true;
                subpath_closed = false;
            },
            .line_to => |p| {
                if (!has_current) {
                    current = p;
                    start = p;
                    has_current = true;
                    subpath_closed = false;
                    continue;
                }
                try appendEdge(allocator, edges, current, p);
                current = p;
                subpath_closed = false;
            },
            .quad_to => |q| {
                if (!has_current) continue;
                const from = current;
                var prev = from;
                const steps = path.curveSteps(from, q.end);
                var i: u32 = 1;
                while (i <= steps) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                    const p = evalQuad(from, q.control, q.end, t);
                    try appendEdge(allocator, edges, prev, p);
                    prev = p;
                }
                current = q.end;
                subpath_closed = false;
            },
            .cubic_to => |c| {
                if (!has_current) continue;
                const from = current;
                var prev = from;
                const steps = path.curveSteps(from, c.end);
                var i: u32 = 1;
                while (i <= steps) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                    const p = evalCubic(from, c.c0, c.c1, c.end, t);
                    try appendEdge(allocator, edges, prev, p);
                    prev = p;
                }
                current = c.end;
                subpath_closed = false;
            },
            .close => {
                if (has_current) {
                    try appendEdge(allocator, edges, current, start);
                    current = start;
                    subpath_closed = true;
                }
            },
        }
    }
    if (close_open_subpaths and has_current and !subpath_closed) try appendEdge(allocator, edges, current, start);
}

fn appendEdge(allocator: std.mem.Allocator, edges: *std.ArrayList(PathEdge), a: math.Vec2, b: math.Vec2) !void {
    if (@abs(a.x - b.x) < 0.000001 and @abs(a.y - b.y) < 0.000001) return;
    try edges.append(allocator, .{ .a = a, .b = b });
}

fn polygonSignedArea(points: []const math.Vec2) f32 {
    var sum: f32 = 0.0;
    for (points, 0..) |point, i| {
        const next = points[(i + 1) % points.len];
        sum += point.x * next.y - next.x * point.y;
    }
    return sum * 0.5;
}

fn simplifyBowTie(path: *const Path, allocator: std.mem.Allocator) !?Path {
    var points: [4]math.Vec2 = undefined;
    var count: usize = 0;
    var closed = false;
    for (path.commands.items) |command| {
        switch (command) {
            .move_to, .line_to => |p| {
                if (count >= points.len) return null;
                points[count] = p;
                count += 1;
            },
            .close => closed = true,
            else => return null,
        }
    }
    if (!closed or count != 4) return null;
    const intersection = segmentIntersection(points[0], points[1], points[2], points[3]) orelse
        segmentIntersection(points[1], points[2], points[3], points[0]) orelse
        return null;

    var out = Path.init(allocator);
    errdefer out.deinit();
    try out.moveTo(points[0]);
    try out.lineTo(points[1]);
    try out.lineTo(intersection);
    try out.close();
    try out.moveTo(points[2]);
    try out.lineTo(points[3]);
    try out.lineTo(intersection);
    try out.close();
    return out;
}

fn simplifySelfIntersectingPolygonLoops(path: *const Path, allocator: std.mem.Allocator) !?Path {
    var points: std.ArrayList(math.Vec2) = .empty;
    defer points.deinit(allocator);
    var closed = false;
    for (path.commands.items) |command| {
        switch (command) {
            .move_to => |p| {
                if (points.items.len != 0) return null;
                try points.append(allocator, p);
            },
            .line_to => |p| try points.append(allocator, p),
            .close => closed = true,
            else => return null,
        }
    }
    if (!closed or points.items.len < 5) return null;

    const split = singlePolygonSelfIntersection(points.items) orelse return null;

    var out = Path.init(allocator);
    errdefer out.deinit();
    var loop_a: std.ArrayList(math.Vec2) = .empty;
    defer loop_a.deinit(allocator);
    var loop_b: std.ArrayList(math.Vec2) = .empty;
    defer loop_b.deinit(allocator);
    try loop_a.append(allocator, split.point);
    var i = split.edge_a + 1;
    while (i <= split.edge_b) : (i += 1) try loop_a.append(allocator, points.items[i % points.items.len]);
    try loop_a.append(allocator, split.point);

    try loop_b.append(allocator, split.point);
    i = split.edge_b + 1;
    while (i <= split.edge_a + points.items.len) : (i += 1) try loop_b.append(allocator, points.items[i % points.items.len]);
    try loop_b.append(allocator, split.point);

    var emitted: usize = 0;
    if (loop_a.items.len >= 4 and @abs(polygonSignedArea(loop_a.items[0 .. loop_a.items.len - 1])) > 0.000001) {
        try appendClosedPointLoop(&out, loop_a.items[0 .. loop_a.items.len - 1]);
        emitted += 1;
    }
    if (loop_b.items.len >= 4 and @abs(polygonSignedArea(loop_b.items[0 .. loop_b.items.len - 1])) > 0.000001) {
        try appendClosedPointLoop(&out, loop_b.items[0 .. loop_b.items.len - 1]);
        emitted += 1;
    }

    if (emitted != 2) {
        out.deinit();
        return null;
    }
    return out;
}

const PolygonIntersection = struct {
    edge_a: usize,
    edge_b: usize,
    point: math.Vec2,
};

fn singlePolygonSelfIntersection(points: []const math.Vec2) ?PolygonIntersection {
    var found: ?PolygonIntersection = null;
    for (points, 0..) |a0, i| {
        const a1 = points[(i + 1) % points.len];
        for (points, 0..) |b0, j| {
            if (j <= i) continue;
            if ((i + 1) % points.len == j or (j + 1) % points.len == i) continue;
            const b1 = points[(j + 1) % points.len];
            if (segmentIntersectionWithT(a0, a1, b0, b1)) |hit| {
                if (found != null) return null;
                found = .{ .edge_a = i, .edge_b = j, .point = hit.point };
            }
        }
    }
    return found;
}

fn appendClosedPointLoop(out: *Path, points: []const math.Vec2) !void {
    var wrote = false;
    for (points) |point| {
        if (!wrote) {
            try out.moveTo(point);
            wrote = true;
        } else if (!pointsNear(out.currentPoint().?, point)) {
            try out.lineTo(point);
        }
    }
    if (wrote) try out.close();
}

fn simplifySelfIntersectingPolygonHull(path: *const Path, allocator: std.mem.Allocator) !?Path {
    var points: std.ArrayList(math.Vec2) = .empty;
    defer points.deinit(allocator);
    var closed = false;
    for (path.commands.items) |command| {
        switch (command) {
            .move_to => |p| {
                if (points.items.len != 0) return null;
                try points.append(allocator, p);
            },
            .line_to => |p| try points.append(allocator, p),
            .close => closed = true,
            else => return null,
        }
    }
    if (!closed or points.items.len < 4 or !polygonSelfIntersects(points.items)) return null;

    var hull_points = try convexHull(allocator, points.items);
    defer hull_points.deinit(allocator);
    if (hull_points.items.len < 3) return null;

    var out = Path.init(allocator);
    errdefer out.deinit();
    for (hull_points.items, 0..) |point, i| {
        if (i == 0) try out.moveTo(point) else try out.lineTo(point);
    }
    try out.close();
    return out;
}

fn polygonSelfIntersects(points: []const math.Vec2) bool {
    for (points, 0..) |a0, i| {
        const a1 = points[(i + 1) % points.len];
        for (points, 0..) |b0, j| {
            if (j <= i) continue;
            if ((i + 1) % points.len == j or (j + 1) % points.len == i) continue;
            const b1 = points[(j + 1) % points.len];
            if (segmentIntersection(a0, a1, b0, b1) != null) return true;
        }
    }
    return false;
}

fn convexHull(allocator: std.mem.Allocator, points: []const math.Vec2) !std.ArrayList(math.Vec2) {
    var sorted = try std.ArrayList(math.Vec2).initCapacity(allocator, points.len);
    errdefer sorted.deinit(allocator);
    sorted.appendSliceAssumeCapacity(points);
    std.sort.heap(math.Vec2, sorted.items, {}, pointLessThan);

    var hull = std.ArrayList(math.Vec2).empty;
    errdefer hull.deinit(allocator);
    for (sorted.items) |point| {
        while (hull.items.len >= 2 and cross2(hull.items[hull.items.len - 2], hull.items[hull.items.len - 1], point) <= 0.0) {
            _ = hull.pop();
        }
        try hull.append(allocator, point);
    }
    const lower_len = hull.items.len;
    var i = sorted.items.len;
    while (i > 0) {
        i -= 1;
        const point = sorted.items[i];
        while (hull.items.len > lower_len and cross2(hull.items[hull.items.len - 2], hull.items[hull.items.len - 1], point) <= 0.0) {
            _ = hull.pop();
        }
        try hull.append(allocator, point);
    }
    if (hull.items.len > 0) _ = hull.pop();
    sorted.deinit(allocator);
    return hull;
}

fn pointLessThan(_: void, a: math.Vec2, b: math.Vec2) bool {
    return a.x < b.x or (a.x == b.x and a.y < b.y);
}

fn cross2(a: math.Vec2, b: math.Vec2, c: math.Vec2) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

fn segmentIntersection(a0: math.Vec2, a1: math.Vec2, b0: math.Vec2, b1: math.Vec2) ?math.Vec2 {
    return if (segmentIntersectionWithT(a0, a1, b0, b1)) |hit| hit.point else null;
}

const EdgeIntersectionPoint = struct {
    t: f32,
    point: math.Vec2,
};

fn segmentIntersectionWithT(a0: math.Vec2, a1: math.Vec2, b0: math.Vec2, b1: math.Vec2) ?EdgeIntersectionPoint {
    const r = a1.sub(a0);
    const s = b1.sub(b0);
    const denom = r.x * s.y - r.y * s.x;
    if (@abs(denom) <= 0.000001) return null;
    const qp = b0.sub(a0);
    const t = (qp.x * s.y - qp.y * s.x) / denom;
    const u = (qp.x * r.y - qp.y * r.x) / denom;
    if (t <= 0.000001 or t >= 0.999999 or u <= 0.000001 or u >= 0.999999) return null;
    return .{ .t = t, .point = a0.add(r.scale(t)) };
}

fn edgeIntersectionPointLessThan(_: void, lhs: EdgeIntersectionPoint, rhs: EdgeIntersectionPoint) bool {
    return lhs.t < rhs.t;
}

fn appendOffsetContour(allocator: std.mem.Allocator, out: *Path, points: []const math.Vec2, closed: bool, amount: f32) !void {
    if (!closed) {
        var offset = try offsetOpenPolyline(allocator, points, amount);
        defer offset.deinit();
        try out.commands.appendSlice(allocator, offset.commands.items);
        return;
    }
    if (points.len < 3) return error.UnsupportedPathOffset;
    const area = polygonSignedArea(points);
    if (@abs(area) <= 0.000001) return error.UnsupportedPathOffset;
    const clockwise = area > 0.0;
    const effective_offset = if (clockwise) -amount else amount;

    for (points, 0..) |point, i| {
        const prev = points[if (i == 0) points.len - 1 else i - 1];
        const next = points[(i + 1) % points.len];
        const in_vec = point.sub(prev);
        const out_vec = next.sub(point);
        const in_len = @sqrt(in_vec.dot(in_vec));
        const out_len = @sqrt(out_vec.dot(out_vec));
        if (in_len <= 0.000001 or out_len <= 0.000001) return error.UnsupportedPathOffset;
        const in_unit = in_vec.scale(1.0 / in_len);
        const out_unit = out_vec.scale(1.0 / out_len);
        const in_normal = math.Vec2{ .x = -in_unit.y * effective_offset, .y = in_unit.x * effective_offset };
        const out_normal = math.Vec2{ .x = -out_unit.y * effective_offset, .y = out_unit.x * effective_offset };
        const offset_point = lineIntersection(prev.add(in_normal), in_unit, point.add(out_normal), out_unit) orelse point.add(in_normal);
        if (i == 0) {
            try out.moveTo(offset_point);
        } else {
            try out.lineTo(offset_point);
        }
    }
    try out.close();
}

fn commandPoint(command: PathCommand) ?math.Vec2 {
    return switch (command) {
        .move_to => |p| p,
        .line_to => |p| p,
        else => null,
    };
}

fn pointsNear(a: math.Vec2, b: math.Vec2) bool {
    return @abs(a.x - b.x) <= 0.000001 and @abs(a.y - b.y) <= 0.000001;
}

fn pointsCollinear(a: math.Vec2, b: math.Vec2, c: math.Vec2) bool {
    const ab = b.sub(a);
    const ac = c.sub(a);
    return @abs(ab.x * ac.y - ab.y * ac.x) <= 0.000001;
}

fn offsetOpenPolyline(allocator: std.mem.Allocator, points: []const math.Vec2, amount: f32) !Path {
    if (points.len < 2) return error.UnsupportedPathOffset;

    var path = Path.init(allocator);
    errdefer path.deinit();
    var first_unit: math.Vec2 = .{};
    for (points[1..]) |point| {
        const segment = point.sub(points[0]);
        const len = @sqrt(segment.dot(segment));
        if (len > 0.000001) {
            first_unit = segment.scale(1.0 / len);
            break;
        }
    }
    if (first_unit.dot(first_unit) <= 0.000001) return error.UnsupportedPathOffset;

    for (points, 0..) |point, i| {
        const offset_point = if (i == 0) blk: {
            const normal = leftNormal(first_unit).scale(amount);
            break :blk point.add(normal);
        } else if (i == points.len - 1) blk: {
            const segment = point.sub(points[i - 1]);
            const len = @sqrt(segment.dot(segment));
            if (len <= 0.000001) return error.UnsupportedPathOffset;
            const normal = leftNormal(segment.scale(1.0 / len)).scale(amount);
            break :blk point.add(normal);
        } else blk: {
            const in_vec = point.sub(points[i - 1]);
            const out_vec = points[i + 1].sub(point);
            const in_len = @sqrt(in_vec.dot(in_vec));
            const out_len = @sqrt(out_vec.dot(out_vec));
            if (in_len <= 0.000001 or out_len <= 0.000001) return error.UnsupportedPathOffset;
            const in_unit = in_vec.scale(1.0 / in_len);
            const out_unit = out_vec.scale(1.0 / out_len);
            const in_normal = leftNormal(in_unit).scale(amount);
            const out_normal = leftNormal(out_unit).scale(amount);
            break :blk lineIntersection(points[i - 1].add(in_normal), in_unit, point.add(out_normal), out_unit) orelse point.add(in_normal);
        };

        if (i == 0) {
            try path.moveTo(offset_point);
        } else {
            try path.lineTo(offset_point);
        }
    }

    return path;
}

fn leftNormal(v: math.Vec2) math.Vec2 {
    return .{ .x = -v.y, .y = v.x };
}

fn evalQuad(a: math.Vec2, c: math.Vec2, b: math.Vec2, t: f32) math.Vec2 {
    const mt = 1.0 - t;
    return .{
        .x = mt * mt * a.x + 2.0 * mt * t * c.x + t * t * b.x,
        .y = mt * mt * a.y + 2.0 * mt * t * c.y + t * t * b.y,
    };
}

fn evalCubic(a: math.Vec2, c0: math.Vec2, c1: math.Vec2, b: math.Vec2, t: f32) math.Vec2 {
    const mt = 1.0 - t;
    return .{
        .x = mt * mt * mt * a.x + 3.0 * mt * mt * t * c0.x + 3.0 * mt * t * t * c1.x + t * t * t * b.x,
        .y = mt * mt * mt * a.y + 3.0 * mt * mt * t * c0.y + 3.0 * mt * t * t * c1.y + t * t * t * b.y,
    };
}

fn rectPath(path: *Path, rect: math.Rect) !void {
    const p0 = math.Vec2{ .x = rect.x, .y = rect.y };
    const p1 = math.Vec2{ .x = rect.right(), .y = rect.y };
    const p2 = math.Vec2{ .x = rect.right(), .y = rect.bottom() };
    const p3 = math.Vec2{ .x = rect.x, .y = rect.bottom() };
    try path.moveTo(p0);
    try path.lineTo(p1);
    try path.lineTo(p2);
    try path.lineTo(p3);
    try path.close();
}

fn roundedRectPath(path: *Path, rect: math.Rect, radius: f32) !void {
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.right();
    const y1 = rect.bottom();
    const r = @min(@max(0.0, radius), @min(rect.w, rect.h) * 0.5);
    const k = r * 0.5522847498;

    try path.moveTo(.{ .x = x0 + r, .y = y0 });
    try path.lineTo(.{ .x = x1 - r, .y = y0 });
    try path.cubicTo(
        .{ .x = x1 - r + k, .y = y0 },
        .{ .x = x1, .y = y0 + r - k },
        .{ .x = x1, .y = y0 + r },
    );
    try path.lineTo(.{ .x = x1, .y = y1 - r });
    try path.cubicTo(
        .{ .x = x1, .y = y1 - r + k },
        .{ .x = x1 - r + k, .y = y1 },
        .{ .x = x1 - r, .y = y1 },
    );
    try path.lineTo(.{ .x = x0 + r, .y = y1 });
    try path.cubicTo(
        .{ .x = x0 + r - k, .y = y1 },
        .{ .x = x0, .y = y1 - r + k },
        .{ .x = x0, .y = y1 - r },
    );
    try path.lineTo(.{ .x = x0, .y = y0 + r });
    try path.cubicTo(
        .{ .x = x0, .y = y0 + r - k },
        .{ .x = x0 + r - k, .y = y0 },
        .{ .x = x0 + r, .y = y0 },
    );
    try path.close();
}

fn ellipsePath(path: *Path, center: math.Vec2, radius: math.Vec2) !void {
    const rx = @max(0.0, radius.x);
    const ry = @max(0.0, radius.y);
    const k: f32 = 0.5522847498;
    try path.moveTo(.{ .x = center.x + rx, .y = center.y });
    try path.cubicTo(
        .{ .x = center.x + rx, .y = center.y + ry * k },
        .{ .x = center.x + rx * k, .y = center.y + ry },
        .{ .x = center.x, .y = center.y + ry },
    );
    try path.cubicTo(
        .{ .x = center.x - rx * k, .y = center.y + ry },
        .{ .x = center.x - rx, .y = center.y + ry * k },
        .{ .x = center.x - rx, .y = center.y },
    );
    try path.cubicTo(
        .{ .x = center.x - rx, .y = center.y - ry * k },
        .{ .x = center.x - rx * k, .y = center.y - ry },
        .{ .x = center.x, .y = center.y - ry },
    );
    try path.cubicTo(
        .{ .x = center.x + rx * k, .y = center.y - ry },
        .{ .x = center.x + rx, .y = center.y - ry * k },
        .{ .x = center.x + rx, .y = center.y },
    );
    try path.close();
}

fn arcPath(path: *Path, center: math.Vec2, radius: math.Vec2, start_angle: f32, end_angle: f32) !void {
    const rx = @max(0.0, radius.x);
    const ry = @max(0.0, radius.y);
    if (rx <= 0.000001 or ry <= 0.000001) return;
    const sweep = end_angle - start_angle;
    const steps: u32 = @max(2, @as(u32, @intFromFloat(@ceil(@abs(sweep) / (std.math.pi / 16.0)))));
    var i: u32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const angle = start_angle + sweep * t;
        const point = math.Vec2{
            .x = center.x + @cos(angle) * rx,
            .y = center.y + @sin(angle) * ry,
        };
        if (i == 0) {
            try path.moveTo(point);
        } else {
            try path.lineTo(point);
        }
    }
}

fn arcSectorPath(path: *Path, center: math.Vec2, radius: math.Vec2, start_angle: f32, end_angle: f32) !void {
    try path.moveTo(center);
    try arcPath(path, center, radius, start_angle, end_angle);
    try path.close();
}

fn collectIntersections(
    allocator: std.mem.Allocator,
    intersections: *std.ArrayList(PathIntersection),
    edges: []const PathEdge,
    y: f32,
) !void {
    for (edges) |e| {
        const y0 = e.a.y;
        const y1 = e.b.y;
        if ((y0 <= y and y1 > y) or (y1 <= y and y0 > y)) {
            const t = (y - y0) / (y1 - y0);
            try intersections.append(allocator, .{
                .x = e.a.x + t * (e.b.x - e.a.x),
                .winding = if (y1 > y0) 1 else -1,
            });
        }
    }
}

fn pathIntersectionLessThan(_: void, lhs: PathIntersection, rhs: PathIntersection) bool {
    return lhs.x < rhs.x;
}

fn deinitPathCoverageRows(allocator: std.mem.Allocator, rows: *PathCoverageRows) void {
    for (rows) |*row| row.deinit(allocator);
}

fn collectPathCoverageRows(
    allocator: std.mem.Allocator,
    rows: *PathCoverageRows,
    edges: []const PathEdge,
    y: u32,
) !void {
    for (rows, 0..) |*row, sy| {
        row.clearRetainingCapacity();
        const sample_y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / path_coverage_sample_axis;
        try collectIntersections(allocator, row, edges, sample_y);
        // Keep each row sorted so individual pixel samples can evaluate fill
        // rules with a linear scan over crossings to the right of the sample.
        if (row.items.len > 1) std.sort.heap(PathIntersection, row.items, {}, pathIntersectionLessThan);
    }
}

fn pathPixelCoverageFromRows(rows: *const PathCoverageRows, x: u32, fill_rule: FillRule) f32 {
    var covered: u32 = 0;
    for (rows) |row| {
        if (row.items.len == 0) continue;
        var sx: u32 = 0;
        while (sx < path_coverage_sample_axis) : (sx += 1) {
            const sample_x = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / path_coverage_sample_axis;
            if (pathContainsSortedIntersections(row.items, sample_x, fill_rule)) covered += 1;
        }
    }
    return @as(f32, @floatFromInt(covered)) / @as(f32, @floatFromInt(path_coverage_sample_axis * path_coverage_sample_axis));
}

fn pathContainsSortedIntersections(intersections: []const PathIntersection, sample_x: f32, fill_rule: FillRule) bool {
    switch (fill_rule) {
        .even_odd => {
            var crossings: u32 = 0;
            for (intersections) |intersection| {
                if (intersection.x > sample_x) crossings += 1;
            }
            return crossings % 2 == 1;
        },
        .non_zero => {
            var winding: i32 = 0;
            for (intersections) |intersection| {
                if (intersection.x > sample_x) winding += intersection.winding;
            }
            return winding != 0;
        },
    }
}

fn edgeBounds(edges: []const PathEdge, width: u32, height: u32) BoundsU32 {
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);

    for (edges) |e| {
        min_x = @min(min_x, @min(e.a.x, e.b.x));
        min_y = @min(min_y, @min(e.a.y, e.b.y));
        max_x = @max(max_x, @max(e.a.x, e.b.x));
        max_y = @max(max_y, @max(e.a.y, e.b.y));
    }

    return .{
        .x0 = clampFloor(min_x, 0, width),
        .y0 = clampFloor(min_y, 0, height),
        .x1 = clampCeil(max_x, 0, width),
        .y1 = clampCeil(max_y, 0, height),
    };
}

fn strokePathBounds(edges: []const PathEdge, stroke: StrokePath, radius: f32, width: u32, height: u32) BoundsU32 {
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);

    for (edges) |e| {
        min_x = @min(min_x, @min(e.a.x, e.b.x));
        min_y = @min(min_y, @min(e.a.y, e.b.y));
        max_x = @max(max_x, @max(e.a.x, e.b.x));
        max_y = @max(max_y, @max(e.a.y, e.b.y));
    }
    if (stroke.join == .miter) {
        const half_width = stroke.width * 0.5;
        for (edges[0 .. edges.len - 1], edges[1..]) |incoming, outgoing| {
            if (miterJoinTip(incoming, outgoing, half_width, stroke.miter_limit)) |tip| {
                min_x = @min(min_x, tip.x);
                min_y = @min(min_y, tip.y);
                max_x = @max(max_x, tip.x);
                max_y = @max(max_y, tip.y);
            }
        }
    }

    return .{
        .x0 = clampFloor(min_x - radius, 0, width),
        .y0 = clampFloor(min_y - radius, 0, height),
        .x1 = clampCeil(max_x + radius, 0, width),
        .y1 = clampCeil(max_y + radius, 0, height),
    };
}

fn triangleBounds(positions: [3]math.Vec2, width: u32, height: u32) BoundsU32 {
    const min_x = @min(@min(positions[0].x, positions[1].x), positions[2].x);
    const min_y = @min(@min(positions[0].y, positions[1].y), positions[2].y);
    const max_x = @max(@max(positions[0].x, positions[1].x), positions[2].x);
    const max_y = @max(@max(positions[0].y, positions[1].y), positions[2].y);
    return .{
        .x0 = clampFloor(min_x, 0, width),
        .y0 = clampFloor(min_y, 0, height),
        .x1 = clampCeil(max_x, 0, width),
        .y1 = clampCeil(max_y, 0, height),
    };
}

fn rectBounds(rect: math.Rect, width: u32, height: u32) BoundsU32 {
    return .{
        .x0 = clampFloor(rect.x, 0, width),
        .y0 = clampFloor(rect.y, 0, height),
        .x1 = clampCeil(rect.right(), 0, width),
        .y1 = clampCeil(rect.bottom(), 0, height),
    };
}

fn clipBounds(clip: ?math.Rect, width: u32, height: u32) BoundsU32 {
    return if (clip) |rect| rectBounds(rect, width, height) else .{
        .x0 = 0,
        .y0 = 0,
        .x1 = width,
        .y1 = height,
    };
}

fn sampleCoord(t: f32, extent: u32) u32 {
    const scaled = @floor(@min(0.999999, @max(0.0, t)) * @as(f32, @floatFromInt(extent)));
    return @intFromFloat(scaled);
}

fn sampleImageSourceCoord(coord: f32, extent: u32) u32 {
    if (extent == 0) return 0;
    const clamped = @min(@as(f32, @floatFromInt(extent)) - 0.000001, @max(0.0, coord));
    return @intFromFloat(@floor(clamped));
}

fn localSamplePoint(inverse: math.Affine2D, x: u32, y: u32) math.Vec2 {
    return inverse.transformPoint(.{
        .x = @as(f32, @floatFromInt(x)) + 0.5,
        .y = @as(f32, @floatFromInt(y)) + 0.5,
    });
}

fn pointInRect(point: math.Vec2, rect: math.Rect) bool {
    return point.x >= rect.x and point.x < rect.right() and point.y >= rect.y and point.y < rect.bottom();
}

fn sweepGradientT(sample: math.Vec2, center: math.Vec2, start_angle: f32) f32 {
    const tau = 2.0 * std.math.pi;
    const delta = sample.sub(center);
    var angle = std.math.atan2(delta.y, delta.x) - start_angle;
    while (angle < 0.0) angle += tau;
    while (angle >= tau) angle -= tau;
    return angle / tau;
}

fn shadowAlphaAtLocal(sample: math.Vec2, rect: math.Rect, blur_radius: f32) f32 {
    if (blur_radius <= 0.000001) return 1.0;

    const dx = @max(@max(rect.x - sample.x, 0.0), sample.x - rect.right());
    const dy = @max(@max(rect.y - sample.y, 0.0), sample.y - rect.bottom());
    const distance = @sqrt(dx * dx + dy * dy);
    return @max(0.0, 1.0 - distance / blur_radius);
}

fn applyOpacity(color: Color, opacity: f32) Color {
    return color.withAlphaScale(opacity);
}

fn axisAlignedTransform(transform: math.Affine2D) ?f32 {
    if (@abs(transform.by) > 0.0001 or @abs(transform.cx) > 0.0001) return null;
    if (transform.ax <= 0.0 or transform.dy <= 0.0) return null;
    if (@abs(transform.ax - transform.dy) > 0.0001) return null;
    return transform.ax;
}

fn transformAxisAlignedRect(transform: math.Affine2D, rect: math.Rect) math.Rect {
    const p0 = transform.transformPoint(.{ .x = rect.x, .y = rect.y });
    const p1 = transform.transformPoint(.{ .x = rect.right(), .y = rect.bottom() });
    const x0 = @min(p0.x, p1.x);
    const y0 = @min(p0.y, p1.y);
    const x1 = @max(p0.x, p1.x);
    const y1 = @max(p0.y, p1.y);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn applyAntiAliasCoverage(coverage: f32, mode: AntiAliasMode) f32 {
    return switch (mode) {
        .default => coverage,
        .none => if (coverage >= 0.5) 1.0 else 0.0,
    };
}

fn intersectBounds(a: BoundsU32, b: BoundsU32) ?BoundsU32 {
    const out = BoundsU32{
        .x0 = @max(a.x0, b.x0),
        .y0 = @max(a.y0, b.y0),
        .x1 = @min(a.x1, b.x1),
        .y1 = @min(a.y1, b.y1),
    };
    if (out.x0 >= out.x1 or out.y0 >= out.y1) return null;
    return out;
}

fn intersectRect(a: math.Rect, b: math.Rect) math.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.right(), b.right());
    const y1 = @min(a.bottom(), b.bottom());
    return .{
        .x = x0,
        .y = y0,
        .w = @max(0.0, x1 - x0),
        .h = @max(0.0, y1 - y0),
    };
}

fn transformRectBounds(rect: math.Rect, transform: math.Affine2D) math.Rect {
    return (TransformedRect{ .rect = rect, .transform = transform }).floatBounds();
}

fn edge(a: math.Vec2, b: math.Vec2, p: math.Vec2) f32 {
    return (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x);
}

fn insideTriangle(p: math.Vec2, tri: [3]math.Vec2) bool {
    const e0 = edge(tri[0], tri[1], p);
    const e1 = edge(tri[1], tri[2], p);
    const e2 = edge(tri[2], tri[0], p);
    return (e0 >= 0 and e1 >= 0 and e2 >= 0) or (e0 <= 0 and e1 <= 0 and e2 <= 0);
}

fn trianglePixelCoverage(tri: [3]math.Vec2, x: u32, y: u32) f32 {
    const offsets = [_]math.Vec2{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    var covered: u32 = 0;
    for (offsets) |offset| {
        const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + offset.x, .y = @as(f32, @floatFromInt(y)) + offset.y };
        if (insideTriangle(sample, tri)) covered += 1;
    }
    return @as(f32, @floatFromInt(covered)) / 4.0;
}

fn strokePathPixelCoverage(edges: []const PathEdge, stroke: StrokePath, x: u32, y: u32) f32 {
    const offsets = [_]math.Vec2{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    const radius = @max(stroke.width * 0.5, 0.5);
    const aa_radius = radius + 0.5;
    const sample_min_x = @as(f32, @floatFromInt(x)) - aa_radius;
    const sample_min_y = @as(f32, @floatFromInt(y)) - aa_radius;
    const sample_max_x = @as(f32, @floatFromInt(x + 1)) + aa_radius;
    const sample_max_y = @as(f32, @floatFromInt(y + 1)) + aa_radius;
    var coverage_sum: f32 = 0.0;
    for (offsets) |offset| {
        const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + offset.x, .y = @as(f32, @floatFromInt(y)) + offset.y };
        var min_distance_sq = std.math.inf(f32);
        if (stroke.join == .round) {
            for (edges[0 .. edges.len - 1]) |edge_value| {
                if (!strokePointMayAffectPixel(edge_value.b, radius, sample_min_x, sample_min_y, sample_max_x, sample_max_y)) continue;
                const dx = sample.x - edge_value.b.x;
                const dy = sample.y - edge_value.b.y;
                min_distance_sq = @min(min_distance_sq, dx * dx + dy * dy);
            }
        } else if (stroke.join == .miter) {
            const miter_pad = radius * @max(1.0, stroke.miter_limit);
            for (edges[0 .. edges.len - 1], edges[1..]) |incoming, outgoing| {
                if (!strokePointMayAffectPixel(incoming.b, miter_pad, sample_min_x, sample_min_y, sample_max_x, sample_max_y)) continue;
                if (sampleInsideMiterJoin(sample, incoming, outgoing, stroke.width * 0.5, stroke.miter_limit)) {
                    min_distance_sq = 0.0;
                    break;
                }
            }
        }
        var nearest_distance_along: f32 = 0.0;
        var path_distance: f32 = 0.0;
        for (edges, 0..) |edge_value, edge_index| {
            const ab = edge_value.b.sub(edge_value.a);
            const len_sq = ab.dot(ab);
            if (strokeEdgeMayAffectPixel(edge_value, stroke, edge_index, edges.len, sample_min_x, sample_min_y, sample_max_x, sample_max_y)) {
                const segment_distance_sq = strokePathSegmentDistanceSq(sample, edge_value, ab, len_sq, stroke, edge_index, edges.len);
                if (segment_distance_sq < min_distance_sq) {
                    min_distance_sq = segment_distance_sq;
                    nearest_distance_along = path_distance + distanceAlongSegment(sample, edge_value.a, ab, len_sq);
                }
            }
            path_distance += @sqrt(len_sq);
        }
        const dash_distance = pathDashDistance(nearest_distance_along, stroke);
        const distance = @max(@sqrt(min_distance_sq), dash_distance);
        coverage_sum += @min(1.0, @max(0.0, aa_radius - distance));
    }
    return coverage_sum / 4.0;
}

fn strokePathPixelCoverageCached(edge_infos: []const StrokeEdgeInfo, edge_candidates: []const usize, join_candidates: []const usize, stroke: StrokePath, x: u32, y: u32) f32 {
    const offsets = [_]math.Vec2{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    const radius = @max(stroke.width * 0.5, 0.5);
    const aa_radius = radius + 0.5;
    const sample_min_x = @as(f32, @floatFromInt(x)) - aa_radius;
    const sample_min_y = @as(f32, @floatFromInt(y)) - aa_radius;
    const sample_max_x = @as(f32, @floatFromInt(x + 1)) + aa_radius;
    const sample_max_y = @as(f32, @floatFromInt(y + 1)) + aa_radius;
    var coverage_sum: f32 = 0.0;
    for (offsets) |offset| {
        const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + offset.x, .y = @as(f32, @floatFromInt(y)) + offset.y };
        var min_distance_sq = std.math.inf(f32);
        if (stroke.join == .round) {
            for (join_candidates) |edge_index| {
                const point = edge_infos[edge_index].edge.b;
                if (!strokePointMayAffectPixel(point, radius, sample_min_x, sample_min_y, sample_max_x, sample_max_y)) continue;
                const dx = sample.x - point.x;
                const dy = sample.y - point.y;
                min_distance_sq = @min(min_distance_sq, dx * dx + dy * dy);
            }
        } else if (stroke.join == .miter) {
            for (join_candidates) |edge_index| {
                if (edge_index + 1 >= edge_infos.len) continue;
                const incoming = edge_infos[edge_index].edge;
                const outgoing = edge_infos[edge_index + 1].edge;
                if (sampleInsideMiterJoin(sample, incoming, outgoing, stroke.width * 0.5, stroke.miter_limit)) {
                    min_distance_sq = 0.0;
                    break;
                }
            }
        }
        var nearest_distance_along: f32 = 0.0;
        for (edge_candidates) |edge_index| {
            const info = edge_infos[edge_index];
            if (info.x1 < sample_min_x or info.x0 > sample_max_x or info.y1 < sample_min_y or info.y0 > sample_max_y) continue;
            const segment_distance_sq = strokePathSegmentDistanceSq(sample, info.edge, info.ab, info.len_sq, stroke, edge_index, edge_infos.len);
            if (segment_distance_sq < min_distance_sq) {
                min_distance_sq = segment_distance_sq;
                nearest_distance_along = info.distance_start + distanceAlongSegment(sample, info.edge.a, info.ab, info.len_sq);
            }
        }
        const dash_distance = pathDashDistance(nearest_distance_along, stroke);
        const distance = @max(@sqrt(min_distance_sq), dash_distance);
        coverage_sum += @min(1.0, @max(0.0, aa_radius - distance));
    }
    return coverage_sum / 4.0;
}

fn buildStrokeEdgeInfos(allocator: std.mem.Allocator, edges: []const PathEdge, stroke: StrokePath) !std.ArrayList(StrokeEdgeInfo) {
    var infos: std.ArrayList(StrokeEdgeInfo) = .empty;
    errdefer infos.deinit(allocator);
    try infos.ensureTotalCapacity(allocator, edges.len);
    var distance_start: f32 = 0.0;
    for (edges, 0..) |edge_value, edge_index| {
        const ab = edge_value.b.sub(edge_value.a);
        const len_sq = ab.dot(ab);
        const len = @sqrt(len_sq);
        var min_x = @min(edge_value.a.x, edge_value.b.x);
        var min_y = @min(edge_value.a.y, edge_value.b.y);
        var max_x = @max(edge_value.a.x, edge_value.b.x);
        var max_y = @max(edge_value.a.y, edge_value.b.y);
        const cap_pad: f32 = switch (stroke.cap) {
            .butt => 0.0,
            .round, .square => stroke.width * 0.5,
        };
        if (edge_index == 0 or edge_index + 1 == edges.len) {
            min_x -= cap_pad;
            min_y -= cap_pad;
            max_x += cap_pad;
            max_y += cap_pad;
        }
        infos.appendAssumeCapacity(.{
            .edge = edge_value,
            .ab = ab,
            .len_sq = len_sq,
            .len = len,
            .distance_start = distance_start,
            .x0 = min_x,
            .y0 = min_y,
            .x1 = max_x,
            .y1 = max_y,
        });
        distance_start += len;
    }
    return infos;
}

fn collectStrokeCandidatesForRow(allocator: std.mem.Allocator, edge_candidates: *std.ArrayList(usize), join_candidates: *std.ArrayList(usize), edge_infos: []const StrokeEdgeInfo, stroke: StrokePath, y: u32) !void {
    edge_candidates.clearRetainingCapacity();
    join_candidates.clearRetainingCapacity();
    const radius = @max(stroke.width * 0.5, 0.5);
    const aa_radius = radius + 0.5;
    const row_min_y = @as(f32, @floatFromInt(y)) - aa_radius;
    const row_max_y = @as(f32, @floatFromInt(y + 1)) + aa_radius;
    for (edge_infos, 0..) |info, edge_index| {
        if (info.y1 >= row_min_y and info.y0 <= row_max_y) try edge_candidates.append(allocator, edge_index);
    }
    switch (stroke.join) {
        .round => {
            for (edge_infos[0 .. edge_infos.len - 1], 0..) |info, edge_index| {
                if (info.edge.b.y + radius >= row_min_y and info.edge.b.y - radius <= row_max_y) try join_candidates.append(allocator, edge_index);
            }
        },
        .miter => {
            const miter_pad = radius * @max(1.0, stroke.miter_limit);
            for (edge_infos[0 .. edge_infos.len - 1], 0..) |info, edge_index| {
                if (info.edge.b.y + miter_pad >= row_min_y and info.edge.b.y - miter_pad <= row_max_y) try join_candidates.append(allocator, edge_index);
            }
        },
        .bevel => {},
    }
}

fn strokeEdgeMayAffectPixel(edge_value: PathEdge, stroke: StrokePath, edge_index: usize, edge_count: usize, sample_min_x: f32, sample_min_y: f32, sample_max_x: f32, sample_max_y: f32) bool {
    var min_x = @min(edge_value.a.x, edge_value.b.x);
    var min_y = @min(edge_value.a.y, edge_value.b.y);
    var max_x = @max(edge_value.a.x, edge_value.b.x);
    var max_y = @max(edge_value.a.y, edge_value.b.y);
    const cap_pad: f32 = switch (stroke.cap) {
        .butt => 0.0,
        .round, .square => stroke.width * 0.5,
    };
    if (edge_index == 0 or edge_index + 1 == edge_count) {
        min_x -= cap_pad;
        min_y -= cap_pad;
        max_x += cap_pad;
        max_y += cap_pad;
    }
    return max_x >= sample_min_x and min_x <= sample_max_x and max_y >= sample_min_y and min_y <= sample_max_y;
}

fn strokePointMayAffectPixel(point: math.Vec2, pad: f32, sample_min_x: f32, sample_min_y: f32, sample_max_x: f32, sample_max_y: f32) bool {
    return point.x + pad >= sample_min_x and point.x - pad <= sample_max_x and point.y + pad >= sample_min_y and point.y - pad <= sample_max_y;
}

fn sampleInsideMiterJoin(sample: math.Vec2, incoming: PathEdge, outgoing: PathEdge, radius: f32, miter_limit: f32) bool {
    if (radius <= 0.0) return false;
    const miter = miterJoinTip(incoming, outgoing, radius, miter_limit) orelse return false;
    const in_vec = incoming.b.sub(incoming.a);
    const out_vec = outgoing.b.sub(outgoing.a);
    const in_len = @sqrt(in_vec.dot(in_vec));
    const out_len = @sqrt(out_vec.dot(out_vec));
    const in_unit = in_vec.scale(1.0 / in_len);
    const out_unit = out_vec.scale(1.0 / out_len);
    const cross = in_unit.x * out_unit.y - in_unit.y * out_unit.x;
    const side: f32 = if (cross > 0.0) -1.0 else 1.0;
    const in_normal = math.Vec2{ .x = -in_unit.y * side, .y = in_unit.x * side };
    const out_normal = math.Vec2{ .x = -out_unit.y * side, .y = out_unit.x * side };
    const vertex = incoming.b;
    const p0 = vertex.add(in_normal.scale(radius));
    const p1 = vertex.add(out_normal.scale(radius));
    if (@abs(edge(p0, miter, p1)) <= 0.000001) return false;
    return insideTriangle(sample, .{ p0, miter, p1 });
}

fn miterJoinTip(incoming: PathEdge, outgoing: PathEdge, radius: f32, miter_limit: f32) ?math.Vec2 {
    if (radius <= 0.0) return null;
    const in_vec = incoming.b.sub(incoming.a);
    const out_vec = outgoing.b.sub(outgoing.a);
    const in_len = @sqrt(in_vec.dot(in_vec));
    const out_len = @sqrt(out_vec.dot(out_vec));
    if (in_len <= 0.000001 or out_len <= 0.000001) return null;

    const in_unit = in_vec.scale(1.0 / in_len);
    const out_unit = out_vec.scale(1.0 / out_len);
    const cross = in_unit.x * out_unit.y - in_unit.y * out_unit.x;
    if (@abs(cross) <= 0.000001) return null;

    const side: f32 = if (cross > 0.0) -1.0 else 1.0;
    const in_normal = math.Vec2{ .x = -in_unit.y * side, .y = in_unit.x * side };
    const out_normal = math.Vec2{ .x = -out_unit.y * side, .y = out_unit.x * side };
    const vertex = incoming.b;
    const p0 = vertex.add(in_normal.scale(radius));
    const p1 = vertex.add(out_normal.scale(radius));
    const miter = lineIntersection(p0, in_unit, p1, out_unit) orelse return null;
    const limit = @max(1.0, miter_limit);
    if (miter.sub(vertex).dot(miter.sub(vertex)) > radius * radius * limit * limit) return null;
    return miter;
}

fn lineIntersection(p: math.Vec2, r: math.Vec2, q: math.Vec2, s: math.Vec2) ?math.Vec2 {
    const denom = r.x * s.y - r.y * s.x;
    if (@abs(denom) <= 0.000001) return null;
    const qp = q.sub(p);
    const t = (qp.x * s.y - qp.y * s.x) / denom;
    return p.add(r.scale(t));
}

fn ellipsePixelCoverage(center: math.Vec2, radius: math.Vec2, x: u32, y: u32) f32 {
    const offsets = [_]math.Vec2{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    var covered: u32 = 0;
    for (offsets) |offset| {
        const sx = (@as(f32, @floatFromInt(x)) + offset.x - center.x) / radius.x;
        const sy = (@as(f32, @floatFromInt(y)) + offset.y - center.y) / radius.y;
        if (sx * sx + sy * sy <= 1.0) covered += 1;
    }
    return @as(f32, @floatFromInt(covered)) / 4.0;
}

fn strokedEllipsePixelCoverage(center: math.Vec2, radius: math.Vec2, stroke_width: f32, x: u32, y: u32) f32 {
    const offsets = [_]math.Vec2{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    const outer = math.Vec2{ .x = radius.x + stroke_width * 0.5, .y = radius.y + stroke_width * 0.5 };
    const inner = math.Vec2{ .x = @max(0.0, radius.x - stroke_width * 0.5), .y = @max(0.0, radius.y - stroke_width * 0.5) };
    var covered: u32 = 0;
    for (offsets) |offset| {
        const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + offset.x, .y = @as(f32, @floatFromInt(y)) + offset.y };
        if (pointInsideEllipse(sample, center, outer) and !pointInsideEllipse(sample, center, inner)) covered += 1;
    }
    return @as(f32, @floatFromInt(covered)) / 4.0;
}

fn arcSectorPixelCoverage(center: math.Vec2, radius: math.Vec2, start_angle: f32, end_angle: f32, x: u32, y: u32) f32 {
    const offsets = [_]math.Vec2{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    var covered: u32 = 0;
    for (offsets) |offset| {
        const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + offset.x, .y = @as(f32, @floatFromInt(y)) + offset.y };
        if (pointInsideEllipse(sample, center, radius) and angleInSweep(std.math.atan2(sample.y - center.y, sample.x - center.x), start_angle, end_angle)) covered += 1;
    }
    return @as(f32, @floatFromInt(covered)) / 4.0;
}

fn strokedArcPixelCoverage(center: math.Vec2, radius: math.Vec2, stroke_width: f32, start_angle: f32, end_angle: f32, x: u32, y: u32) f32 {
    const offsets = [_]math.Vec2{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    const outer = math.Vec2{ .x = radius.x + stroke_width * 0.5, .y = radius.y + stroke_width * 0.5 };
    const inner = math.Vec2{ .x = @max(0.0, radius.x - stroke_width * 0.5), .y = @max(0.0, radius.y - stroke_width * 0.5) };
    var covered: u32 = 0;
    for (offsets) |offset| {
        const sample = math.Vec2{ .x = @as(f32, @floatFromInt(x)) + offset.x, .y = @as(f32, @floatFromInt(y)) + offset.y };
        const angle = std.math.atan2(sample.y - center.y, sample.x - center.x);
        if (pointInsideEllipse(sample, center, outer) and !pointInsideEllipse(sample, center, inner) and angleInSweep(angle, start_angle, end_angle)) covered += 1;
    }
    return @as(f32, @floatFromInt(covered)) / 4.0;
}

fn pointInsideEllipse(sample: math.Vec2, center: math.Vec2, radius: math.Vec2) bool {
    if (radius.x <= 0.000001 or radius.y <= 0.000001) return false;
    const sx = (sample.x - center.x) / radius.x;
    const sy = (sample.y - center.y) / radius.y;
    return sx * sx + sy * sy <= 1.0;
}

fn angleInSweep(angle: f32, start_angle: f32, end_angle: f32) bool {
    const tau = 2.0 * std.math.pi;
    const raw_span = end_angle - start_angle;
    if (@abs(raw_span) >= tau) return true;
    const span = normalizePositiveAngle(raw_span);
    const rel = normalizePositiveAngle(angle - start_angle);
    return rel <= span;
}

fn normalizePositiveAngle(angle: f32) f32 {
    const tau = 2.0 * std.math.pi;
    var out = @mod(angle, tau);
    if (out < 0.0) out += tau;
    return out;
}

fn distanceToSegmentSq(p: math.Vec2, a: math.Vec2, b: math.Vec2, ab: math.Vec2, len_sq: f32) f32 {
    if (len_sq <= 0.000001) {
        const dx = p.x - a.x;
        const dy = p.y - a.y;
        return dx * dx + dy * dy;
    }
    const ap = p.sub(a);
    const t = @min(1.0, @max(0.0, (ap.x * ab.x + ap.y * ab.y) / len_sq));
    const nearest = math.Vec2{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    const dx = p.x - nearest.x;
    const dy = p.y - nearest.y;
    return dx * dx + dy * dy;
}

fn lineDistance(sample: math.Vec2, line: Line, ab: math.Vec2, len_sq: f32, len: f32) f32 {
    if (len_sq <= 0.000001) return switch (line.cap) {
        .round => @sqrt(distanceToSegmentSq(sample, line.a, line.b, ab, len_sq)),
        .butt, .square => std.math.inf(f32),
    };
    const unit = ab.scale(1.0 / len);
    const ap = sample.sub(line.a);
    const along = ap.dot(unit);
    if (line.cap == .butt and (along < 0.0 or along > len)) return std.math.inf(f32);
    const limit_min: f32 = switch (line.cap) {
        .butt, .round => 0.0,
        .square => -line.width * 0.5,
    };
    const limit_max: f32 = switch (line.cap) {
        .butt, .round => len,
        .square => len + line.width * 0.5,
    };
    if (line.cap == .round) {
        return @sqrt(distanceToSegmentSq(sample, line.a, line.b, ab, len_sq));
    }
    const clamped = @min(limit_max, @max(limit_min, along));
    const nearest = line.a.add(unit.scale(clamped));
    const dx = sample.x - nearest.x;
    const dy = sample.y - nearest.y;
    return @sqrt(dx * dx + dy * dy);
}

fn strokePathSegmentDistanceSq(sample: math.Vec2, edge_value: PathEdge, ab: math.Vec2, len_sq: f32, stroke: StrokePath, edge_index: usize, edge_count: usize) f32 {
    if (len_sq <= 0.000001) return if (stroke.cap == .round) distanceToSegmentSq(sample, edge_value.a, edge_value.b, ab, len_sq) else std.math.inf(f32);
    const len = @sqrt(len_sq);
    const unit = ab.scale(1.0 / len);
    const ap = sample.sub(edge_value.a);
    const along = ap.dot(unit);

    const starts_path = edge_index == 0;
    const ends_path = edge_index + 1 == edge_count;
    if (stroke.cap == .butt and ((starts_path and along < 0.0) or (ends_path and along > len))) return std.math.inf(f32);

    const limit_min: f32 = if (starts_path and stroke.cap == .square) -stroke.width * 0.5 else 0.0;
    const limit_max: f32 = if (ends_path and stroke.cap == .square) len + stroke.width * 0.5 else len;
    if ((starts_path or ends_path) and stroke.cap == .round) {
        return distanceToSegmentSq(sample, edge_value.a, edge_value.b, ab, len_sq);
    }
    const clamped = @min(limit_max, @max(limit_min, along));
    const nearest = edge_value.a.add(unit.scale(clamped));
    const dx = sample.x - nearest.x;
    const dy = sample.y - nearest.y;
    return dx * dx + dy * dy;
}

fn lineDashDistance(sample: math.Vec2, line: Line, ab: math.Vec2, len_sq: f32) f32 {
    if (len_sq <= 0.000001) return 0.0;
    if (line.dash_pattern.count > 0) {
        const ap = sample.sub(line.a);
        const t = @min(1.0, @max(0.0, ap.dot(ab) / len_sq));
        return dashPatternDistance(@sqrt(len_sq) * t, line.dash_pattern, line.cap, line.width);
    }
    if (line.dash_on <= 0.000001 or line.dash_off <= 0.000001) return 0.0;
    const ap = sample.sub(line.a);
    const t = @min(1.0, @max(0.0, ap.dot(ab) / len_sq));
    const distance_along = @sqrt(len_sq) * t + line.dash_offset;
    const period = line.dash_on + line.dash_off;
    const phase = @mod(distance_along, period);
    if (phase < line.dash_on) return 0.0;

    const cap_radius = switch (line.cap) {
        .butt => 0.0,
        .round, .square => line.width * 0.5,
    };
    const distance_to_dash = @min(phase - line.dash_on, period - phase);
    if (distance_to_dash <= cap_radius) return switch (line.cap) {
        .butt => std.math.inf(f32),
        .round, .square => 0.0,
    };
    return std.math.inf(f32);
}

fn pathDashDistance(distance_along: f32, stroke: StrokePath) f32 {
    if (stroke.dash_pattern.count > 0) return dashPatternDistance(distance_along, stroke.dash_pattern, stroke.cap, stroke.width);
    if (stroke.dash_on <= 0.000001 or stroke.dash_off <= 0.000001) return 0.0;
    const period = stroke.dash_on + stroke.dash_off;
    const phase = @mod(distance_along + stroke.dash_offset, period);
    if (phase < stroke.dash_on) return 0.0;

    const cap_radius = switch (stroke.cap) {
        .butt => 0.0,
        .round, .square => stroke.width * 0.5,
    };
    const distance_to_dash = @min(phase - stroke.dash_on, period - phase);
    if (distance_to_dash <= cap_radius) return switch (stroke.cap) {
        .butt => std.math.inf(f32),
        .round, .square => 0.0,
    };
    return std.math.inf(f32);
}

fn dashPatternDistance(distance_along: f32, pattern: DashPattern, cap: LineCap, width: f32) f32 {
    const total = pattern.totalLength();
    if (pattern.count == 0 or total <= 0.000001) return 0.0;
    var phase = @mod(distance_along + pattern.offset, total);
    var i: usize = 0;
    while (i < pattern.count) : (i += 1) {
        const segment = pattern.segments[i];
        if (phase <= segment) {
            if (i % 2 == 0) return 0.0;
            const cap_radius = switch (cap) {
                .butt => 0.0,
                .round, .square => width * 0.5,
            };
            const distance_to_dash = @min(phase, segment - phase);
            if (distance_to_dash <= cap_radius) return switch (cap) {
                .butt => std.math.inf(f32),
                .round, .square => 0.0,
            };
            return std.math.inf(f32);
        }
        phase -= segment;
    }
    return 0.0;
}

fn distanceAlongSegment(sample: math.Vec2, a: math.Vec2, ab: math.Vec2, len_sq: f32) f32 {
    if (len_sq <= 0.000001) return 0.0;
    const ap = sample.sub(a);
    const t = @min(1.0, @max(0.0, ap.dot(ab) / len_sq));
    return @sqrt(len_sq) * t;
}

fn alignForward(v: u32, alignment: u32) u32 {
    return ((v + alignment - 1) / alignment) * alignment;
}

fn clampFloor(v: f32, lo: u32, hi: u32) u32 {
    const floored: i32 = @intFromFloat(@floor(v));
    return @intCast(math.clampInt(floored, @intCast(lo), @intCast(hi)));
}

fn clampCeil(v: f32, lo: u32, hi: u32) u32 {
    const ceiled: i32 = @intFromFloat(@ceil(v));
    return @intCast(math.clampInt(ceiled, @intCast(lo), @intCast(hi)));
}

test "rectangles become tile bounded sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try scene.fillRect(.{ .x = 14, .y = 0, .w = 4, .h = 1 }, .red);
    var strips = try scene.buildSparseStrips(allocator, 32, 32);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), strips.items.len);
    try std.testing.expectEqual(@as(u16, 14), strips.items[0].x);
    try std.testing.expectEqual(@as(u16, 2), strips.items[0].width);
    try std.testing.expectEqual(@as(u16, 16), strips.items[1].x);
}

test "drop shadow rectangles become soft sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.dropShadowRect(.{ .x = 4, .y = 4, .w = 4, .h = 4 }, .{ .x = 2, .y = 1 }, 2, .black);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_full = false;
    var has_partial = false;
    for (strips.items) |strip| {
        if (strip.color.a == 255) has_full = true;
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
    }
    try std.testing.expect(has_full);
    try std.testing.expect(has_partial);
}

test "drop shadow rectangles apply scene transform scale and offset" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 2).scale(2, 2));
    try scene.dropShadowRect(.{ .x = 1, .y = 1, .w = 2, .h = 2 }, .{ .x = 1, .y = 0 }, 1, .black);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 16, 12);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    var min_x: u16 = std.math.maxInt(u16);
    var min_y: u16 = std.math.maxInt(u16);
    var max_x: u16 = 0;
    for (strips.items) |strip| {
        min_x = @min(min_x, strip.x);
        min_y = @min(min_y, strip.y);
        max_x = @max(max_x, strip.x + strip.width);
    }
    try std.testing.expect(min_x >= 6);
    try std.testing.expect(min_y >= 2);
    try std.testing.expect(max_x > 10);
}

test "scene clones filled paths" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 0 });
    try path.lineTo(.{ .x = 0, .y = 4 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .blue, .non_zero);

    try std.testing.expectEqual(@as(usize, 1), scene.paths.items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.primitives.items.len);
}

test "path initCapacity preallocates command storage" {
    const allocator = std.testing.allocator;
    var path = try Path.initCapacity(allocator, 4);
    defer path.deinit();

    try std.testing.expect(path.commands.capacity >= 4);
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 1, .y = 0 });
    try std.testing.expectEqual(@as(usize, 2), path.commands.items.len);
}

test "path initBuffer uses external command storage" {
    var buffer: [8]PathCommand = undefined;
    var path = Path.initBuffer(&buffer);
    defer path.deinit();

    path.moveToAssumeCapacity(.{ .x = 0, .y = 0 });
    path.lineToAssumeCapacity(.{ .x = 2, .y = 0 });
    try path.relLineToAssumeCapacity(.{ .x = 0, .y = 2 });
    path.closeAssumeCapacity();

    try std.testing.expectEqual(@as(usize, 4), path.commands.items.len);
    try std.testing.expectEqual(@as(usize, 8), path.commands.capacity);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 2, .y = 2 } }, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand.close, path.commands.items[3]);
}

test "path assume capacity curve commands match fallible commands" {
    var buffer: [6]PathCommand = undefined;
    var path = Path.initBuffer(&buffer);
    defer path.deinit();

    try std.testing.expectError(error.NoCurrentPoint, path.curveToAssumeCapacity(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 0 }));
    try std.testing.expectError(error.NoCurrentPoint, path.relCurveToAssumeCapacity(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }));
    try std.testing.expectError(error.NoCurrentPoint, path.quadToAssumeCapacity(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 0 }));

    path.moveToAssumeCapacity(.{ .x = 0, .y = 0 });
    try path.quadToAssumeCapacity(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 0 });
    try path.curveToAssumeCapacity(.{ .x = 3, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 5, .y = 0 });
    try path.relCurveToAssumeCapacity(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 });

    try std.testing.expectEqual(PathCommand{ .quad_to = .{ .control = .{ .x = 1, .y = 1 }, .end = .{ .x = 2, .y = 0 } } }, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .cubic_to = .{ .c0 = .{ .x = 3, .y = 1 }, .c1 = .{ .x = 4, .y = 1 }, .end = .{ .x = 5, .y = 0 } } }, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand{ .cubic_to = .{ .c0 = .{ .x = 6, .y = 0 }, .c1 = .{ .x = 7, .y = 0 }, .end = .{ .x = 8, .y = 0 } } }, path.commands.items[3]);
}

test "relative path commands use current point" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 1 });
    try path.relLineTo(.{ .x = 2, .y = 3 });
    try path.relQuadTo(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 2 });
    try path.relCubicTo(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 2 });
    try path.relMoveTo(.{ .x = -1, .y = -1 });

    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 3, .y = 4 } }, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .quad_to = .{ .control = .{ .x = 4, .y = 4 }, .end = .{ .x = 5, .y = 6 } } }, path.commands.items[2]);
    try std.testing.expectEqual(PathCommand{ .cubic_to = .{ .c0 = .{ .x = 6, .y = 6 }, .c1 = .{ .x = 7, .y = 7 }, .end = .{ .x = 8, .y = 8 } } }, path.commands.items[3]);
    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 7, .y = 7 } }, path.commands.items[4]);
    try std.testing.expectEqual(math.Vec2{ .x = 7, .y = 7 }, path.currentPoint().?);
}

test "relative path commands require current point" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try std.testing.expectError(error.NoCurrentPoint, path.relMoveTo(.{ .x = 1, .y = 1 }));
    try std.testing.expectError(error.NoCurrentPoint, path.relLineTo(.{ .x = 1, .y = 1 }));
    try std.testing.expectError(error.NoCurrentPoint, path.relQuadTo(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }));
    try std.testing.expectError(error.NoCurrentPoint, path.relCubicTo(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 3 }));
}

test "curve path commands require current point" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try std.testing.expectError(error.NoCurrentPoint, path.quadTo(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }));
    try std.testing.expectError(error.NoCurrentPoint, path.cubicTo(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 3 }));

    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.quadTo(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 });
    try path.cubicTo(.{ .x = 3, .y = 3 }, .{ .x = 4, .y = 4 }, .{ .x = 5, .y = 5 });
    try std.testing.expectEqual(@as(usize, 3), path.commands.items.len);
}

test "curveTo aliases cubic path commands" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try std.testing.expectError(error.NoCurrentPoint, path.curveTo(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 3 }));
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.curveTo(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 3 });
    try path.relCurveTo(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 });

    try std.testing.expectEqual(PathCommand{ .cubic_to = .{ .c0 = .{ .x = 1, .y = 1 }, .c1 = .{ .x = 2, .y = 2 }, .end = .{ .x = 3, .y = 3 } } }, path.commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .cubic_to = .{ .c0 = .{ .x = 4, .y = 3 }, .c1 = .{ .x = 5, .y = 3 }, .end = .{ .x = 6, .y = 3 } } }, path.commands.items[2]);
}

test "lineTo without current point acts as moveTo" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try path.lineTo(.{ .x = 3, .y = 4 });

    try std.testing.expectEqual(@as(usize, 1), path.commands.items.len);
    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 3, .y = 4 } }, path.commands.items[0]);
}

test "close without current point and double close are no-ops" {
    const allocator = std.testing.allocator;
    var empty = Path.init(allocator);
    defer empty.deinit();
    try empty.close();
    try std.testing.expectEqual(@as(usize, 0), empty.commands.items.len);

    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.close();
    try path.close();
    try std.testing.expectEqual(@as(usize, 3), path.commands.items.len);
}

test "path isClosed reports all subpaths closed" {
    const allocator = std.testing.allocator;
    var closed = Path.init(allocator);
    defer closed.deinit();
    try closed.moveTo(.{ .x = 0, .y = 0 });
    try closed.lineTo(.{ .x = 1, .y = 0 });
    try closed.close();
    try closed.moveTo(.{ .x = 2, .y = 0 });
    try closed.lineTo(.{ .x = 3, .y = 0 });
    try closed.close();
    try std.testing.expect(closed.isClosed());

    var open_tail = Path.init(allocator);
    defer open_tail.deinit();
    try open_tail.moveTo(.{ .x = 0, .y = 0 });
    try open_tail.lineTo(.{ .x = 1, .y = 0 });
    try open_tail.close();
    try open_tail.moveTo(.{ .x = 2, .y = 0 });
    try open_tail.lineTo(.{ .x = 3, .y = 0 });
    try std.testing.expect(!open_tail.isClosed());

    var empty = Path.init(allocator);
    defer empty.deinit();
    try std.testing.expect(!empty.isClosed());
}

test "path reset clears commands and current point" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.close();
    try std.testing.expect(path.isClosed());

    path.reset();

    try std.testing.expectEqual(@as(usize, 0), path.commands.items.len);
    try std.testing.expectEqual(@as(?math.Vec2, null), path.currentPoint());
    try std.testing.expect(!path.isClosed());
}

test "path arc starts a subpath when there is no current point" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try path.arc(.{ .x = 10, .y = 10 }, 4, 0, std.math.pi / 2.0);

    try std.testing.expect(path.commands.items.len > 2);
    const first = path.commands.items[0].move_to;
    const last = path.currentPoint().?;
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), first.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), first.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), last.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), last.y, 0.001);
}

test "path arc connects from current point" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.arc(.{ .x = 10, .y = 10 }, 4, 0, std.math.pi / 2.0);

    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 14, .y = 10 } }, path.commands.items[1]);
}

test "path arcNegative moves in decreasing angle direction" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();

    try path.arcNegative(.{ .x = 10, .y = 10 }, 4, 0, -std.math.pi / 2.0);

    const last = path.currentPoint().?;
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), last.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), last.y, 0.001);
}

test "path tolerance controls arc flattening" {
    const allocator = std.testing.allocator;
    var coarse = Path.init(allocator);
    defer coarse.deinit();
    coarse.setTolerance(1.0);
    try coarse.arc(.{ .x = 0, .y = 0 }, 10, 0, std.math.pi);

    var fine = Path.init(allocator);
    defer fine.deinit();
    fine.setTolerance(0.1);
    try fine.arc(.{ .x = 0, .y = 0 }, 10, 0, std.math.pi);

    try std.testing.expect(fine.commands.items.len > coarse.commands.items.len);
}

test "path tolerance controls curve offset flattening" {
    const allocator = std.testing.allocator;
    var coarse = Path.init(allocator);
    defer coarse.deinit();
    coarse.setTolerance(2.0);
    try coarse.moveTo(.{ .x = 0, .y = 0 });
    try coarse.quadTo(.{ .x = 8, .y = 0 }, .{ .x = 8, .y = 8 });
    var coarse_offset = try coarse.offset(allocator, 1);
    defer coarse_offset.deinit();

    var fine = Path.init(allocator);
    defer fine.deinit();
    fine.setTolerance(0.25);
    try fine.moveTo(.{ .x = 0, .y = 0 });
    try fine.quadTo(.{ .x = 8, .y = 0 }, .{ .x = 8, .y = 8 });
    var fine_offset = try fine.offset(allocator, 1);
    defer fine_offset.deinit();

    try std.testing.expect(fine_offset.commands.items.len > coarse_offset.commands.items.len);
}

test "filled paths become sparse strips" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 2 });
    try path.lineTo(.{ .x = 10, .y = 2 });
    try path.lineTo(.{ .x = 2, .y = 10 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .green, .non_zero);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    try std.testing.expectEqual(@as(u16, 2), strips.items[0].y);
}

test "linear gradients can fill arbitrary paths" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 0 });
    try path.lineTo(.{ .x = 0, .y = 4 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillLinearGradientPath(&path, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 4, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    }, .non_zero);

    var strips = try scene.buildSparseStrips(allocator, 4, 4);
    defer strips.deinit(allocator);

    var left_red = false;
    var right_blue = false;
    for (strips.items) |strip| {
        if (strip.y == 0 and strip.x == 0 and strip.color.r > strip.color.b) left_red = true;
        if (strip.y == 0 and strip.x >= 2 and strip.color.b > strip.color.r) right_blue = true;
    }
    try std.testing.expect(left_red);
    try std.testing.expect(right_blue);
}

test "radial and sweep gradients can fill arbitrary paths" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 0 });
    try path.lineTo(.{ .x = 0, .y = 4 });
    try path.close();

    var radial_scene = Scene2D.init(allocator);
    defer radial_scene.deinit();
    try radial_scene.fillRadialGradientPath(&path, .{
        .center = .{ .x = 0.5, .y = 0.5 },
        .radius = 4,
        .inner_color = .red,
        .outer_color = .blue,
    }, .non_zero);
    var radial = try radial_scene.buildSparseStrips(allocator, 4, 4);
    defer radial.deinit(allocator);
    try std.testing.expect(radial.items.len > 0);
    try std.testing.expect(radial.items[0].color.r > radial.items[radial.items.len - 1].color.r);

    var sweep_scene = Scene2D.init(allocator);
    defer sweep_scene.deinit();
    try sweep_scene.fillSweepGradientPath(&path, .{
        .center = .{ .x = 1.5, .y = 1.5 },
        .start_color = .red,
        .end_color = .blue,
    }, .non_zero);
    var sweep = try sweep_scene.buildSparseStrips(allocator, 4, 4);
    defer sweep.deinit(allocator);
    try std.testing.expect(sweep.items.len > 0);
    try std.testing.expect(sweep.items[0].color.toRgba32() != sweep.items[sweep.items.len - 1].color.toRgba32());
}

test "filled paths ignore degenerate closed line segments" {
    const allocator = std.testing.allocator;
    var degenerate = Path.init(allocator);
    defer degenerate.deinit();
    try degenerate.moveTo(.{ .x = 0, .y = 0 });
    try degenerate.lineTo(.{ .x = 4, .y = 4 });
    try degenerate.close();

    var empty_scene = Scene2D.init(allocator);
    defer empty_scene.deinit();
    try empty_scene.fillPath(&degenerate, .white, .non_zero);
    var empty = try empty_scene.buildSparseStrips(allocator, 8, 8);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);

    var square = Path.init(allocator);
    defer square.deinit();
    try rectPath(&square, .{ .x = 1, .y = 1, .w = 2, .h = 2 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&degenerate, .white, .non_zero);
    try scene.fillPath(&square, .white, .non_zero);

    var strips = try scene.buildSparseStrips(allocator, 8, 8);
    defer strips.deinit(allocator);

    var pixels: usize = 0;
    for (strips.items) |strip| pixels += strip.width;
    try std.testing.expectEqual(@as(usize, 4), pixels);
}

test "fully out-of-bounds fill and stroke paths are no-ops" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try rectPath(&path, .{ .x = -20, .y = -20, .w = 5, .h = 5 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .green, .non_zero);
    try scene.strokePath(&path, 4, .red);

    var strips = try scene.buildSparseStrips(allocator, 10, 10);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), strips.items.len);
}

test "partially out-of-bounds paths clip to target edges" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try rectPath(&path, .{ .x = -2, .y = 2, .w = 5, .h = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .green, .non_zero);
    try scene.strokePath(&path, 2, .red);

    var strips = try scene.buildSparseStrips(allocator, 8, 8);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    for (strips.items) |strip| {
        try std.testing.expect(strip.x < 8);
        try std.testing.expect(strip.y < 8);
        try std.testing.expect(strip.x + strip.width <= 8);
    }
}

test "path simplify removes duplicate and collinear line points" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 2, .y = 0 });
    try path.lineTo(.{ .x = 2, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 3 });
    try path.close();

    var simplified = try path.simplify(allocator);
    defer simplified.deinit();

    try std.testing.expectEqual(@as(usize, 4), simplified.commands.items.len);
    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 0, .y = 0 } }, simplified.commands.items[0]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 4, .y = 0 } }, simplified.commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 4, .y = 3 } }, simplified.commands.items[2]);
    try std.testing.expectEqual(PathCommand.close, simplified.commands.items[3]);
}

test "path simplify keeps curve commands" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.quadTo(.{ .x = 2, .y = 0 }, .{ .x = 4, .y = 4 });

    var simplified = try path.simplify(allocator);
    defer simplified.deinit();

    try std.testing.expectEqual(@as(usize, 2), simplified.commands.items.len);
    try std.testing.expectEqual(path.commands.items[1], simplified.commands.items[1]);
}

test "path simplify splits simple bow-tie self intersections" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 4 });
    try path.lineTo(.{ .x = 0, .y = 4 });
    try path.lineTo(.{ .x = 4, .y = 0 });
    try path.close();

    var simplified = try path.simplify(allocator);
    defer simplified.deinit();

    var moves: usize = 0;
    var closes: usize = 0;
    var has_intersection = false;
    for (simplified.commands.items) |command| {
        switch (command) {
            .move_to => moves += 1,
            .close => closes += 1,
            .line_to => |p| {
                if (pointsNear(p, .{ .x = 2, .y = 2 })) has_intersection = true;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), moves);
    try std.testing.expectEqual(@as(usize, 2), closes);
    try std.testing.expect(has_intersection);
}

test "path simplify splits repeated self-intersections into loops" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 4, .y = 4 });
    try path.lineTo(.{ .x = 0, .y = 4 });
    try path.lineTo(.{ .x = 4, .y = 0 });
    try path.lineTo(.{ .x = 6, .y = 0 });
    try path.close();

    var simplified = try path.simplify(allocator);
    defer simplified.deinit();

    var moves: usize = 0;
    var closes: usize = 0;
    var intersection_hits: usize = 0;
    for (simplified.commands.items) |command| {
        switch (command) {
            .move_to => |p| {
                moves += 1;
                if (pointsNear(p, .{ .x = 2, .y = 2 })) intersection_hits += 1;
            },
            .close => closes += 1,
            .line_to => |p| if (pointsNear(p, .{ .x = 2, .y = 2 })) {
                intersection_hits += 1;
            },
            else => {},
        }
    }
    try std.testing.expect(moves >= 2);
    try std.testing.expectEqual(moves, closes);
    try std.testing.expect(intersection_hits >= 1);
}

test "path simplify falls back to hull for complex self intersections" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 3 });
    try path.lineTo(.{ .x = 4, .y = 3 });
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.lineTo(.{ .x = 2, .y = 5 });
    try path.lineTo(.{ .x = 3, .y = 0 });
    try path.close();

    var simplified = try path.simplify(allocator);
    defer simplified.deinit();

    var moves: usize = 0;
    var closes: usize = 0;
    for (simplified.commands.items) |command| {
        switch (command) {
            .move_to => moves += 1,
            .close => closes += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), moves);
    try std.testing.expectEqual(@as(usize, 1), closes);
    try std.testing.expect(simplified.commands.items.len <= path.commands.items.len);
}

test "closed polygon paths can be offset outward" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try rectPath(&path, .{ .x = 2, .y = 2, .w = 4, .h = 4 });

    var offset = try path.offset(allocator, 1);
    defer offset.deinit();

    try std.testing.expectEqual(@as(usize, 5), offset.commands.items.len);
    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 1, .y = 1 } }, offset.commands.items[0]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 7, .y = 1 } }, offset.commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 7, .y = 7 } }, offset.commands.items[2]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 1, .y = 7 } }, offset.commands.items[3]);
}

test "closed polygon paths can be offset inward" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try rectPath(&path, .{ .x = 2, .y = 2, .w = 4, .h = 4 });

    var offset = try path.offset(allocator, -1);
    defer offset.deinit();

    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 3, .y = 3 } }, offset.commands.items[0]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 5, .y = 3 } }, offset.commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 5, .y = 5 } }, offset.commands.items[2]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 3, .y = 5 } }, offset.commands.items[3]);
}

test "path offset supports multiple subpaths" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try rectPath(&path, .{ .x = 2, .y = 2, .w = 4, .h = 4 });
    try rectPath(&path, .{ .x = 12, .y = 2, .w = 4, .h = 4 });

    var offset = try path.offset(allocator, 1);
    defer offset.deinit();

    var moves: usize = 0;
    var closes: usize = 0;
    for (offset.commands.items) |command| {
        switch (command) {
            .move_to => moves += 1,
            .close => closes += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), moves);
    try std.testing.expectEqual(@as(usize, 2), closes);
}

test "open line paths can be offset" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 2 });
    try path.lineTo(.{ .x = 6, .y = 2 });

    var offset = try path.offset(allocator, 1);
    defer offset.deinit();

    try std.testing.expectEqual(@as(usize, 2), offset.commands.items.len);
    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 2, .y = 3 } }, offset.commands.items[0]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 6, .y = 3 } }, offset.commands.items[1]);
}

test "open polyline paths offset joins by intersection" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 2 });
    try path.lineTo(.{ .x = 6, .y = 2 });
    try path.lineTo(.{ .x = 6, .y = 6 });

    var offset = try path.offset(allocator, 1);
    defer offset.deinit();

    try std.testing.expectEqual(PathCommand{ .move_to = .{ .x = 2, .y = 3 } }, offset.commands.items[0]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 5, .y = 3 } }, offset.commands.items[1]);
    try std.testing.expectEqual(PathCommand{ .line_to = .{ .x = 5, .y = 6 } }, offset.commands.items[2]);
}

test "curve paths can be flattened and offset" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.quadTo(.{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 });

    var offset = try path.offset(allocator, 1);
    defer offset.deinit();

    try std.testing.expect(offset.commands.items.len > 2);
    const first = offset.commands.items[0].move_to;
    try std.testing.expect(first.y > 0.0);
    try std.testing.expect(first.x < 0.0);
    try std.testing.expect((offset.commands.items[offset.commands.items.len - 1].line_to).x < 4.0);
}

test "self-intersecting paths can simplify before offset" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 6, .y = 6 });
    try path.lineTo(.{ .x = 0, .y = 6 });
    try path.lineTo(.{ .x = 6, .y = 0 });
    try path.lineTo(.{ .x = 8, .y = 0 });
    try path.close();

    var offset = try path.offset(allocator, 0.5);
    defer offset.deinit();

    var moves: usize = 0;
    var closes: usize = 0;
    for (offset.commands.items) |command| {
        switch (command) {
            .move_to => moves += 1,
            .close => closes += 1,
            else => {},
        }
    }
    try std.testing.expect(moves >= 2);
    try std.testing.expectEqual(moves, closes);
}

test "text fills rasterized glyph strips using cangjie fonts" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    const font_index = try scene.addTextFont(font_bytes);
    try scene.fillText(font_index, "A", .{ .x = 2, .y = 18 }, 16, .white);

    var strips = try scene.buildSparseStrips(allocator, 32, 24);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    var has_partial_alpha = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial_alpha = true;
    }
    try std.testing.expect(has_partial_alpha);
}

test "text fill preserves grayscale source color" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    const font_index = try scene.addTextFont(font_bytes);
    try scene.fillText(font_index, "A", .{ .x = 2, .y = 18 }, 16, Color.rgba(51, 51, 51, 255));

    var strips = try scene.buildSparseStrips(allocator, 32, 24);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    for (strips.items) |strip| {
        if (strip.color.a > 0) {
            try std.testing.expectEqual(@as(u8, 51), strip.color.r);
            try std.testing.expectEqual(@as(u8, 51), strip.color.g);
            try std.testing.expectEqual(@as(u8, 51), strip.color.b);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "text fill honors anti alias none" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    const font_index = try scene.addTextFont(font_bytes);
    try scene.pushAntiAlias(.none);
    try scene.fillText(font_index, "A", .{ .x = 2, .y = 18 }, 16, .white);
    scene.popAntiAlias();

    var strips = try scene.buildSparseStrips(allocator, 32, 24);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    for (strips.items) |strip| {
        try std.testing.expect(strip.color.a == 255);
    }
}

test "text coverage contrast keeps antialiased edges" {
    try std.testing.expectEqual(@as(f32, 0.0), textCoverageContrast(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), textCoverageContrast(1.0));
    try std.testing.expect(textCoverageContrast(0.25) < 0.25);
    try std.testing.expect(textCoverageContrast(0.75) > 0.75);
}

test "text metrics use cangjie layout advances" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    const font_index = try scene.addTextFont(font_bytes);
    const metrics = try scene.measureText(font_index, "A", 20);

    try std.testing.expectApproxEqAbs(@as(f32, 16.0), metrics.advance, 0.001);
    try std.testing.expect(metrics.ascent > 0.0);
    try std.testing.expect(metrics.height() >= metrics.ascent + metrics.descent);
}

test "text metrics reject invalid font handles" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try std.testing.expectError(error.InvalidTextFont, scene.measureText(0, "A", 20));
    try std.testing.expectError(error.InvalidTextFont, scene.showText("A", .{}, .white));
    try std.testing.expectError(error.InvalidTextFont, scene.measureTextCurrent("A"));
}

test "text state APIs show and measure current font" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    const font_index = try scene.addTextFont(font_bytes);
    try scene.setFont(font_index);
    scene.setFontSize(20);
    try std.testing.expectEqual(@as(f32, 20.0), scene.getFontSize());

    const metrics = try scene.measureTextCurrent("A");
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), metrics.advance, 0.001);
    try scene.showText("A", .{ .x = 2, .y = 20 }, .white);

    var strips = try scene.buildSparseStrips(allocator, 32, 24);
    defer strips.deinit(allocator);
    try std.testing.expect(strips.items.len > 0);
}

test "source color state drives current text drawing" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    _ = try scene.addTextFont(font_bytes);
    scene.setSourceColor(.green);
    try scene.showTextCurrent("A", .{ .x = 2, .y = 20 });

    var strips = try scene.buildSparseStrips(allocator, 32, 24);
    defer strips.deinit(allocator);
    try std.testing.expect(strips.items.len > 0);
    try std.testing.expectEqual(Color.green.r, strips.items[0].color.r);
    try std.testing.expectEqual(Color.green.g, strips.items[0].color.g);
}

test "scene transform applies to text origin" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    const font_index = try scene.addTextFont(font_bytes);
    try scene.pushTransform(math.Affine2D.identity.translate(10, 0));
    try scene.fillText(font_index, "A", .{ .x = 2, .y = 18 }, 16, .white);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 32, 24);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    var min_x: u16 = std.math.maxInt(u16);
    for (strips.items) |strip| min_x = @min(min_x, strip.x);
    try std.testing.expect(min_x >= 11);
}

test "scene scale transform applies to text size" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var base_scene = Scene2D.init(allocator);
    defer base_scene.deinit();
    const base_font = try base_scene.addTextFont(font_bytes);
    try base_scene.fillText(base_font, "A", .{ .x = 2, .y = 20 }, 12, .white);
    var base_strips = try base_scene.buildSparseStrips(allocator, 64, 48);
    defer base_strips.deinit(allocator);

    var scaled_scene = Scene2D.init(allocator);
    defer scaled_scene.deinit();
    const scaled_font = try scaled_scene.addTextFont(font_bytes);
    try scaled_scene.pushTransform(math.Affine2D.identity.scale(2, 2));
    try scaled_scene.fillText(scaled_font, "A", .{ .x = 2, .y = 20 }, 12, .white);
    scaled_scene.popTransform();
    var scaled_strips = try scaled_scene.buildSparseStrips(allocator, 64, 64);
    defer scaled_strips.deinit(allocator);

    const base_bounds = stripBounds(base_strips.items).?;
    const scaled_bounds = stripBounds(scaled_strips.items).?;
    try std.testing.expect((scaled_bounds.max_x - scaled_bounds.min_x) > (base_bounds.max_x - base_bounds.min_x));
    try std.testing.expect((scaled_bounds.max_y - scaled_bounds.min_y) > (base_bounds.max_y - base_bounds.min_y));
}

test "scene non-uniform transform applies to text width" {
    const allocator = std.testing.allocator;
    const test_font = cangjie.testing.test_font;
    const font_bytes = try test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var base_scene = Scene2D.init(allocator);
    defer base_scene.deinit();
    const base_font = try base_scene.addTextFont(font_bytes);
    try base_scene.fillText(base_font, "A", .{ .x = 2, .y = 20 }, 16, .white);
    var base_strips = try base_scene.buildSparseStrips(allocator, 64, 48);
    defer base_strips.deinit(allocator);

    var scaled_scene = Scene2D.init(allocator);
    defer scaled_scene.deinit();
    const scaled_font = try scaled_scene.addTextFont(font_bytes);
    try scaled_scene.pushTransform(math.Affine2D.identity.scale(2, 1));
    try scaled_scene.fillText(scaled_font, "A", .{ .x = 2, .y = 20 }, 16, .white);
    scaled_scene.popTransform();
    var scaled_strips = try scaled_scene.buildSparseStrips(allocator, 96, 48);
    defer scaled_strips.deinit(allocator);

    const base_bounds = stripBounds(base_strips.items).?;
    const scaled_bounds = stripBounds(scaled_strips.items).?;
    try std.testing.expect((scaled_bounds.max_x - scaled_bounds.min_x) > (base_bounds.max_x - base_bounds.min_x) + 4);
    try std.testing.expect((scaled_bounds.max_y - scaled_bounds.min_y) <= (base_bounds.max_y - base_bounds.min_y) + 2);
}

const StripTestBounds = struct {
    min_x: u16,
    max_x: u16,
    min_y: u16,
    max_y: u16,
};

fn stripBounds(strips: []const Strip) ?StripTestBounds {
    if (strips.len == 0) return null;
    var bounds = StripTestBounds{
        .min_x = std.math.maxInt(u16),
        .max_x = 0,
        .min_y = std.math.maxInt(u16),
        .max_y = 0,
    };
    for (strips) |strip| {
        bounds.min_x = @min(bounds.min_x, strip.x);
        bounds.max_x = @max(bounds.max_x, strip.x + strip.width);
        bounds.min_y = @min(bounds.min_y, strip.y);
        bounds.max_y = @max(bounds.max_y, strip.y);
    }
    return bounds;
}

test "scene transform applies to filled paths" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 2 });
    try path.lineTo(.{ .x = 6, .y = 2 });
    try path.lineTo(.{ .x = 2, .y = 6 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(6, 0));
    try scene.fillPath(&path, .green, .non_zero);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 16, 12);
    defer strips.deinit(allocator);

    for (strips.items) |strip| try std.testing.expect(strip.x >= 8);
}

test "scene transform applies to filled rectangles" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(6, 0));
    try scene.fillRect(.{ .x = 2, .y = 2, .w = 4, .h = 4 }, .red);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 16, 12);
    defer strips.deinit(allocator);

    var saw_translated = false;
    for (strips.items) |strip| {
        if (strip.x >= 8 and strip.x < 12 and strip.y >= 2 and strip.y < 6) saw_translated = true;
        try std.testing.expect(strip.x >= 8 or strip.color.a < 255);
    }
    try std.testing.expect(saw_translated);
}

test "scene transform state APIs affect subsequent drawing" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    scene.translate(4, 0);
    const saved = scene.getTransform();
    scene.scaleTransform(2, 2);
    try scene.fillRect(.{ .x = 1, .y = 1, .w = 2, .h = 2 }, .red);
    scene.setTransform(saved);
    try scene.fillRect(.{ .x = 0, .y = 5, .w = 1, .h = 1 }, .blue);
    scene.setIdentityTransform();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .green);

    var strips = try scene.buildSparseStrips(allocator, 12, 10);
    defer strips.deinit(allocator);

    var saw_scaled = false;
    var saw_saved = false;
    var saw_identity = false;
    for (strips.items) |strip| {
        if (strip.color.toRgba32() == Color.red.toRgba32() and strip.x >= 6 and strip.y >= 2) saw_scaled = true;
        if (strip.color.toRgba32() == Color.blue.toRgba32() and strip.x == 4 and strip.y == 5) saw_saved = true;
        if (strip.color.toRgba32() == Color.green.toRgba32() and strip.x == 0 and strip.y == 0) saw_identity = true;
    }
    try std.testing.expect(saw_scaled);
    try std.testing.expect(saw_saved);
    try std.testing.expect(saw_identity);
}

test "scene exposes z2d-style transformation helpers" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    scene.setTransformation(math.Affine2D.identity.translate(4, 2));
    try std.testing.expectEqual(scene.getTransform(), scene.getTransformation());
    try std.testing.expectEqual(math.Vec2{ .x = 5, .y = 3 }, scene.userToDevice(.{ .x = 1, .y = 1 }));
    try std.testing.expectEqual(math.Vec2{ .x = 1, .y = 1 }, scene.userToDeviceDistance(.{ .x = 1, .y = 1 }));
    try std.testing.expectEqual(math.Vec2{ .x = 1, .y = 1 }, scene.deviceToUser(.{ .x = 5, .y = 3 }).?);
    try std.testing.expectEqual(math.Vec2{ .x = 1, .y = 1 }, scene.deviceToUserDistance(.{ .x = 1, .y = 1 }).?);

    scene.mul(math.Affine2D.identity.scale(2, 3));
    try std.testing.expectEqual(math.Vec2{ .x = 6, .y = 5 }, scene.userToDevice(.{ .x = 1, .y = 1 }));

    scene.setIdentity();
    scene.translate(1, 2);
    scene.scale(3, 4);
    try std.testing.expectEqual(math.Vec2{ .x = 4, .y = 6 }, scene.userToDevice(.{ .x = 1, .y = 1 }));

    scene.setTransformation(.{ .ax = 0, .dy = 0 });
    try std.testing.expectEqual(@as(?math.Vec2, null), scene.deviceToUser(.{}));
    try std.testing.expectEqual(@as(?math.Vec2, null), scene.deviceToUserDistance(.{}));
}

test "scene current path fill and stroke mirror z2d context flow" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    scene.setSourceColor(.red);
    try scene.moveTo(.{ .x = 1, .y = 1 });
    try scene.lineTo(.{ .x = 4, .y = 1 });
    try scene.lineTo(.{ .x = 1, .y = 4 });
    try scene.closePath();
    try std.testing.expect(scene.isPathClosed());
    try scene.fill();

    scene.resetPath();
    scene.setSourceColor(.blue);
    scene.setLineWidth(2);
    try scene.moveTo(.{ .x = 5, .y = 2 });
    try scene.relLineTo(.{ .x = 4, .y = 0 });
    try scene.stroke();

    var strips = try scene.buildSparseStrips(allocator, 12, 8);
    defer strips.deinit(allocator);

    var red = false;
    var blue = false;
    for (strips.items) |strip| {
        if (strip.color.r > strip.color.b) red = true;
        if (strip.color.b > strip.color.r) blue = true;
    }
    try std.testing.expect(red);
    try std.testing.expect(blue);
}

test "scene current path records active transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    scene.translate(4, 0);
    try scene.moveTo(.{ .x = 0, .y = 0 });
    try scene.lineTo(.{ .x = 2, .y = 0 });
    try scene.lineTo(.{ .x = 0, .y = 2 });
    try scene.closePath();
    scene.setIdentity();
    scene.setSourceColor(.white);
    try scene.fill();

    var strips = try scene.buildSparseStrips(allocator, 8, 4);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    for (strips.items) |strip| try std.testing.expect(strip.x >= 4);
}

test "scene current path simplify and offset mutate path state" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try scene.moveTo(.{ .x = 2, .y = 2 });
    try scene.lineTo(.{ .x = 4, .y = 2 });
    try scene.lineTo(.{ .x = 4, .y = 2 });
    try scene.lineTo(.{ .x = 6, .y = 2 });
    try scene.lineTo(.{ .x = 6, .y = 6 });
    try scene.lineTo(.{ .x = 2, .y = 6 });
    try scene.closePath();

    try scene.simplifyPath();
    try scene.offsetPath(1);
    scene.setSourceColor(.white);
    try scene.fill();

    var strips = try scene.buildSparseStrips(allocator, 10, 10);
    defer strips.deinit(allocator);

    var has_outer = false;
    for (strips.items) |strip| {
        if (strip.y == 1 and strip.x <= 1 and strip.x + strip.width > 1) has_outer = true;
    }
    try std.testing.expect(has_outer);
}

test "filled paths emit anti-aliased edge alpha" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2.25, .y = 2.25 });
    try path.lineTo(.{ .x = 8.25, .y = 2.25 });
    try path.lineTo(.{ .x = 2.25, .y = 8.25 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .green, .non_zero);

    var strips = try scene.buildSparseStrips(allocator, 12, 12);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "filled paths implicitly close each open subpath" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 2 });
    try path.lineTo(.{ .x = 6, .y = 2 });
    try path.lineTo(.{ .x = 2, .y = 6 });
    try path.moveTo(.{ .x = 14, .y = 2 });
    try path.lineTo(.{ .x = 18, .y = 2 });
    try path.lineTo(.{ .x = 18, .y = 6 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .white, .non_zero);

    var strips = try scene.buildSparseStrips(allocator, 20, 8);
    defer strips.deinit(allocator);

    var has_left = false;
    var has_right = false;
    var has_bridge = false;
    for (strips.items) |strip| {
        if (strip.y == 3 and strip.x <= 3 and strip.x + strip.width > 3) has_left = true;
        if (strip.y == 3 and strip.x <= 17 and strip.x + strip.width > 17) has_right = true;
        if (strip.y == 3 and strip.x < 12 and strip.x + strip.width > 8) has_bridge = true;
    }
    try std.testing.expect(has_left);
    try std.testing.expect(has_right);
    try std.testing.expect(!has_bridge);
}

test "filled sliver paths preserve high precision partial coverage" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1.0, .y = 1.10 });
    try path.lineTo(.{ .x = 6.0, .y = 1.10 });
    try path.lineTo(.{ .x = 6.0, .y = 1.35 });
    try path.lineTo(.{ .x = 1.0, .y = 1.35 });
    try path.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillPath(&path, .white, .non_zero);

    var strips = try scene.buildSparseStrips(allocator, 8, 4);
    defer strips.deinit(allocator);

    var has_low_partial = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 128) has_low_partial = true;
    }
    try std.testing.expect(has_low_partial);
}

test "stroked paths become anti-aliased sparse strips" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 10 });
    try path.quadTo(.{ .x = 8, .y = 2 }, .{ .x = 14, .y = 10 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePath(&path, 2, .white);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "linear gradients can stroke arbitrary paths" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 9, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeLinearGradientPath(&path, .{
        .start = .{ .x = 1, .y = 0 },
        .end = .{ .x = 9, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    }, .{ .width = 2.0, .cap = .butt });

    var strips = try scene.buildSparseStrips(allocator, 12, 8);
    defer strips.deinit(allocator);

    var left_red = false;
    var right_blue = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.color.r > strip.color.b) left_red = true;
        if (strip.y == 4 and strip.x >= 7 and strip.color.b > strip.color.r) right_blue = true;
    }
    try std.testing.expect(left_red);
    try std.testing.expect(right_blue);
}

test "radial and sweep gradients can stroke arbitrary paths" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 9, .y = 4 });

    var radial_scene = Scene2D.init(allocator);
    defer radial_scene.deinit();
    try radial_scene.strokeRadialGradientPath(&path, .{
        .center = .{ .x = 1, .y = 4 },
        .radius = 8,
        .inner_color = .red,
        .outer_color = .blue,
    }, .{ .width = 2.0, .cap = .butt });
    var radial = try radial_scene.buildSparseStrips(allocator, 12, 8);
    defer radial.deinit(allocator);
    try std.testing.expect(radial.items.len > 0);
    try std.testing.expect(radial.items[0].color.r > radial.items[radial.items.len - 1].color.r);

    var sweep_scene = Scene2D.init(allocator);
    defer sweep_scene.deinit();
    try sweep_scene.strokeSweepGradientPath(&path, .{
        .center = .{ .x = 5, .y = 4 },
        .start_color = .red,
        .end_color = .blue,
    }, .{ .width = 2.0, .cap = .butt });
    var sweep = try sweep_scene.buildSparseStrips(allocator, 12, 8);
    defer sweep.deinit(allocator);
    try std.testing.expect(sweep.items.len > 0);
    try std.testing.expect(sweep.items[0].color.toRgba32() != sweep.items[sweep.items.len - 1].color.toRgba32());
}

test "stroked path paint extent is not clipped to path bounds" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 40, .y = 50 });
    try path.lineTo(.{ .x = 35, .y = 60 });
    try path.lineTo(.{ .x = 30, .y = 70 });
    try path.lineTo(.{ .x = 10, .y = 50 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePath(&path, 5, .white);

    var strips = try scene.buildSparseStrips(allocator, 50, 80);
    defer strips.deinit(allocator);

    var reaches_below_path = false;
    for (strips.items) |strip| {
        if (strip.y > 70) reaches_below_path = true;
    }
    try std.testing.expect(reaches_below_path);
}

test "strokePathCurrent uses stroke style state" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 17, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    scene.setLineWidth(2);
    scene.setLineCap(.butt);
    scene.setDashes(&.{ 2, 2, 4, 2 });
    try scene.strokePathCurrent(&path, .white);

    var strips = try scene.buildSparseStrips(allocator, 20, 8);
    defer strips.deinit(allocator);

    var first_gap = false;
    var long_dash = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) first_gap = true;
        if (strip.y == 4 and strip.x <= 7 and strip.x + strip.width > 7) long_dash = true;
    }
    try std.testing.expect(!first_gap);
    try std.testing.expect(long_dash);
}

test "hairline paths draw minimum-width strokes" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 7, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeHairlinePath(&path, .white);

    var strips = try scene.buildSparseStrips(allocator, 10, 8);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
}

test "zero-length stroked paths only draw round caps" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 4 });
    try path.lineTo(.{ .x = 4, .y = 4 });

    var round_scene = Scene2D.init(allocator);
    defer round_scene.deinit();
    try round_scene.strokePathCap(&path, 4, .round, .white);
    var round = try round_scene.buildSparseStrips(allocator, 10, 10);
    defer round.deinit(allocator);

    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokePathCap(&path, 4, .butt, .white);
    var butt = try butt_scene.buildSparseStrips(allocator, 10, 10);
    defer butt.deinit(allocator);

    try std.testing.expect(round.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), butt.items.len);
}

test "dashed stroked paths leave sparse strip gaps" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 13, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedPath(&path, 2, 3, 3, .white);

    var strips = try scene.buildSparseStrips(allocator, 16, 8);
    defer strips.deinit(allocator);

    var has_first_dash = false;
    var has_gap = false;
    var has_second_dash = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) has_first_dash = true;
        if (strip.y == 4 and strip.x <= 5 and strip.x + strip.width > 5) has_gap = true;
        if (strip.y == 4 and strip.x <= 8 and strip.x + strip.width > 8) has_second_dash = true;
    }
    try std.testing.expect(has_first_dash);
    try std.testing.expect(!has_gap);
    try std.testing.expect(has_second_dash);
}

test "dashed stroked paths apply dash offset" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 13, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedPathOffset(&path, 2, 3, 3, 3, .white);

    var strips = try scene.buildSparseStrips(allocator, 16, 8);
    defer strips.deinit(allocator);

    var start_gap = false;
    var shifted_dash = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) start_gap = true;
        if (strip.y == 4 and strip.x <= 5 and strip.x + strip.width > 5) shifted_dash = true;
    }
    try std.testing.expect(!start_gap);
    try std.testing.expect(shifted_dash);
}

test "stroked paths support multi-segment dash patterns" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 17, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePathPattern(&path, 2, DashPattern.fromSlice(&.{ 2, 2, 4, 2 }, 0), .butt, .white);

    var strips = try scene.buildSparseStrips(allocator, 20, 8);
    defer strips.deinit(allocator);

    var first_dash = false;
    var first_gap = false;
    var long_dash = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) first_dash = true;
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) first_gap = true;
        if (strip.y == 4 and strip.x <= 7 and strip.x + strip.width > 7) long_dash = true;
    }
    try std.testing.expect(first_dash);
    try std.testing.expect(!first_gap);
    try std.testing.expect(long_dash);
}

test "dashed stroked path cap modes extend dash endpoints" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 4 });
    try path.lineTo(.{ .x = 13, .y = 4 });

    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeDashedPathCap(&path, 2, 3, 3, .butt, .white);
    var butt = try butt_scene.buildSparseStrips(allocator, 16, 8);
    defer butt.deinit(allocator);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeDashedPathCap(&path, 2, 3, 3, .square, .white);
    var square = try square_scene.buildSparseStrips(allocator, 16, 8);
    defer square.deinit(allocator);

    var butt_gap_edge = false;
    for (butt.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) butt_gap_edge = true;
    }
    var square_gap_edge = false;
    for (square.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) square_gap_edge = true;
    }
    try std.testing.expect(!butt_gap_edge);
    try std.testing.expect(square_gap_edge);
}

test "stroked path cap modes change endpoint coverage" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 4 });
    try path.lineTo(.{ .x = 12, .y = 4 });

    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokePathCap(&path, 2, .butt, .white);
    var butt = try butt_scene.buildSparseStrips(allocator, 16, 8);
    defer butt.deinit(allocator);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokePathCap(&path, 2, .square, .white);
    var square = try square_scene.buildSparseStrips(allocator, 16, 8);
    defer square.deinit(allocator);

    var butt_before_start = false;
    for (butt.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) butt_before_start = true;
    }
    var square_before_start = false;
    for (square.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) square_before_start = true;
    }
    try std.testing.expect(!butt_before_start);
    try std.testing.expect(square_before_start);
}

test "very thin stroked paths still render minimum coverage" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 2 });
    try path.lineTo(.{ .x = 7, .y = 2 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePathCap(&path, 0.001, .butt, .white);

    var strips = try scene.buildSparseStrips(allocator, 10, 5);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    var has_partial = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
    }
    try std.testing.expect(has_partial);
}

test "stroked path applies scene transform" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 2, .y = 4 });
    try path.lineTo(.{ .x = 10, .y = 4 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(6, 2));
    try scene.strokePathCap(&path, 2, .butt, .white);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 20, 10);
    defer strips.deinit(allocator);

    var moved = false;
    var original = false;
    for (strips.items) |strip| {
        if (strip.y == 6 and strip.x <= 10 and strip.x + strip.width > 10) moved = true;
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) original = true;
    }
    try std.testing.expect(moved);
    try std.testing.expect(!original);
}

test "stroked path width applies scene scale" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 2 });
    try path.lineTo(.{ .x = 5, .y = 2 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.scale(2, 2));
    try scene.strokePath(&path, 2, .white);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 16, 12);
    defer strips.deinit(allocator);

    var vertical_span: usize = 0;
    for (strips.items) |strip| {
        if (strip.x <= 6 and strip.x + strip.width > 6) vertical_span += 1;
    }
    try std.testing.expect(vertical_span >= 4);
}

test "round path joins cover interior vertices" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 10 });
    try path.lineTo(.{ .x = 10, .y = 4 });
    try path.lineTo(.{ .x = 16, .y = 10 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePathCapJoin(&path, 4, .butt, .round, .white);
    var strips = try scene.buildSparseStrips(allocator, 20, 14);
    defer strips.deinit(allocator);

    var joined = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 10 and strip.x + strip.width > 10) joined = true;
    }
    try std.testing.expect(joined);
}

test "miter path joins extend sharp corners" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 20 });
    try path.lineTo(.{ .x = 14, .y = 6 });
    try path.lineTo(.{ .x = 24, .y = 20 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePathCapJoin(&path, 8, .butt, .miter, .white);
    var strips = try scene.buildSparseStrips(allocator, 28, 24);
    defer strips.deinit(allocator);

    var tip = false;
    for (strips.items) |strip| {
        if (strip.y == 0 and strip.x <= 14 and strip.x + strip.width > 14) tip = true;
    }
    try std.testing.expect(tip);
}

test "miter path joins honor low miter limit" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 20 });
    try path.lineTo(.{ .x = 14, .y = 6 });
    try path.lineTo(.{ .x = 24, .y = 20 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePathCapJoinMiterLimit(&path, 8, .butt, .miter, 1.0, .white);
    var strips = try scene.buildSparseStrips(allocator, 28, 24);
    defer strips.deinit(allocator);

    var tip = false;
    for (strips.items) |strip| {
        if (strip.y == 0 and strip.x <= 14 and strip.x + strip.width > 14) tip = true;
    }
    try std.testing.expect(!tip);
}

test "bevel path joins do not extend sharp corners" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 4, .y = 20 });
    try path.lineTo(.{ .x = 14, .y = 6 });
    try path.lineTo(.{ .x = 24, .y = 20 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokePathCapJoin(&path, 8, .butt, .bevel, .white);
    var strips = try scene.buildSparseStrips(allocator, 28, 24);
    defer strips.deinit(allocator);

    var tip = false;
    for (strips.items) |strip| {
        if (strip.y == 0 and strip.x <= 14 and strip.x + strip.width > 14) tip = true;
    }
    try std.testing.expect(!tip);
}

test "rounded rectangles become anti-aliased sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRoundedRect(.{ .x = 2, .y = 2, .w = 8, .h = 8 }, 3, .red);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    var center_pixels: usize = 0;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
        if (strip.y == 5 and strip.x <= 5 and strip.x + strip.width > 5) center_pixels += 1;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
    try std.testing.expect(center_pixels > 0);
}

test "stroked rounded rectangles become anti-aliased sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeRoundedRect(.{ .x = 2, .y = 2, .w = 10, .h = 10 }, 3, 2, .blue);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    var center_empty = true;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
        if (strip.y == 7 and strip.x <= 7 and strip.x + strip.width > 7) center_empty = false;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
    try std.testing.expect(center_empty);
}

test "gradient rounded rectangles clip to rounded corners" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillLinearGradientRoundedRect(.{ .x = 2, .y = 2, .w = 10, .h = 10 }, 4, .{
        .start = .{ .x = 2, .y = 2 },
        .end = .{ .x = 12, .y = 2 },
        .start_color = .red,
        .end_color = .blue,
    });

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_redish = false;
    var has_blueish = false;
    var corner_empty = true;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.r > strip.color.b) has_redish = true;
        if (strip.color.b > strip.color.r) has_blueish = true;
        if (strip.y == 2 and strip.x <= 2 and strip.x + strip.width > 2) corner_empty = false;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_redish);
    try std.testing.expect(has_blueish);
    try std.testing.expect(corner_empty);
}

test "filled triangles become sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillTriangle(.{
        .{ .x = 2, .y = 2 },
        .{ .x = 10, .y = 2 },
        .{ .x = 2, .y = 10 },
    }, .blue);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    try std.testing.expectEqual(@as(u16, 2), strips.items[0].y);
}

test "filled triangles apply scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 3));
    try scene.fillTriangle(.{
        .{ .x = 2, .y = 2 },
        .{ .x = 10, .y = 2 },
        .{ .x = 2, .y = 10 },
    }, .blue);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 20, 20);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    var moved = false;
    var original = false;
    for (strips.items) |strip| {
        if (strip.y == 5 and strip.x <= 6 and strip.x + strip.width > 6) moved = true;
        if (strip.y == 2 and strip.x <= 2 and strip.x + strip.width > 2) original = true;
    }
    try std.testing.expect(moved);
    try std.testing.expect(!original);
}

test "filled ellipses become anti-aliased sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, .blue);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    var center_hit = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
        if (strip.y == 8 and strip.x <= 8 and strip.x + strip.width > 8) center_hit = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
    try std.testing.expect(center_hit);
}

test "filled ellipses apply scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 3));
    try scene.fillEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, .blue);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 20, 18);
    defer strips.deinit(allocator);

    var moved = false;
    var min_x: u16 = std.math.maxInt(u16);
    var min_y: u16 = std.math.maxInt(u16);
    for (strips.items) |strip| {
        if (strip.y == 11 and strip.x <= 12 and strip.x + strip.width > 12) moved = true;
        min_x = @min(min_x, strip.x);
        min_y = @min(min_y, strip.y);
    }
    try std.testing.expect(moved);
    try std.testing.expect(min_x >= 7);
    try std.testing.expect(min_y >= 7);
}

test "stroked ellipses become anti-aliased sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, 2, .blue);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    var center_hit = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
        if (strip.y == 8 and strip.x <= 8 and strip.x + strip.width > 8) center_hit = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
    try std.testing.expect(!center_hit);
}

test "zero-width stroked ellipses and arcs are no-ops" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, 0, .white);
    try scene.strokeArc(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, 0, 0, std.math.pi, .white);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), strips.items.len);
}

test "stroked ellipses apply scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 3));
    try scene.strokeEllipse(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 3 }, 2, .blue);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 20, 18);
    defer strips.deinit(allocator);

    var moved = false;
    var original = false;
    for (strips.items) |strip| {
        if (strip.y == 8 and strip.x <= 12 and strip.x + strip.width > 12) moved = true;
        if (strip.y == 5 and strip.x <= 8 and strip.x + strip.width > 8) original = true;
    }
    try std.testing.expect(moved);
    try std.testing.expect(!original);
}

test "arc sectors become anti-aliased sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillArcSector(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, -std.math.pi / 2.0, std.math.pi / 2.0, .green);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_right = false;
    var has_left = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.y == 8 and strip.x <= 11 and strip.x + strip.width > 11) has_right = true;
        if (strip.y == 8 and strip.x <= 4 and strip.x + strip.width > 4) has_left = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_right);
    try std.testing.expect(!has_left);
}

test "arc sectors apply scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 3));
    try scene.fillArcSector(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, -std.math.pi / 2.0, std.math.pi / 2.0, .green);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 20, 20);
    defer strips.deinit(allocator);

    var moved = false;
    var original = false;
    for (strips.items) |strip| {
        if (strip.y == 11 and strip.x <= 15 and strip.x + strip.width > 15) moved = true;
        if (strip.y == 8 and strip.x <= 11 and strip.x + strip.width > 11) original = true;
    }
    try std.testing.expect(moved);
    try std.testing.expect(!original);
}

test "stroked arcs become anti-aliased sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeArc(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, 2, -std.math.pi / 2.0, std.math.pi / 2.0, .green);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_right = false;
    var has_left = false;
    var center_hit = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.y == 8 and strip.x <= 12 and strip.x + strip.width > 12) has_right = true;
        if (strip.y == 8 and strip.x <= 4 and strip.x + strip.width > 4) has_left = true;
        if (strip.y == 8 and strip.x <= 8 and strip.x + strip.width > 8) center_hit = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_right);
    try std.testing.expect(!has_left);
    try std.testing.expect(!center_hit);
}

test "stroked arcs apply scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 3));
    try scene.strokeArc(.{ .x = 8, .y = 8 }, .{ .x = 5, .y = 5 }, 2, -std.math.pi / 2.0, std.math.pi / 2.0, .green);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 20, 20);
    defer strips.deinit(allocator);

    var moved = false;
    var min_x: u16 = std.math.maxInt(u16);
    var min_y: u16 = std.math.maxInt(u16);
    for (strips.items) |strip| {
        if (strip.y == 11 and strip.x <= 17 and strip.x + strip.width > 17) moved = true;
        min_x = @min(min_x, strip.x);
        min_y = @min(min_y, strip.y);
    }
    try std.testing.expect(moved);
    try std.testing.expect(min_x >= 10);
    try std.testing.expect(min_y >= 4);
}

test "filled triangles emit anti-aliased edge alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillTriangle(.{
        .{ .x = 2.25, .y = 2.25 },
        .{ .x = 8.25, .y = 2.25 },
        .{ .x = 2.25, .y = 8.25 },
    }, .blue);

    var strips = try scene.buildSparseStrips(allocator, 12, 12);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "stroked lines become sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeLine(.{ .x = 1, .y = 1 }, .{ .x = 8, .y = 1 }, 2, .white);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len > 0);
    try std.testing.expectEqual(@as(u16, 0), strips.items[0].y);
}

test "strokeLineCurrent uses stroke style state and stack" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    scene.setLineWidth(2);
    scene.setLineCap(.square);
    try scene.pushStrokeStyle(.{ .width = 4, .cap = .butt });
    try scene.strokeLineCurrent(.{ .x = 1, .y = 4 }, .{ .x = 7, .y = 4 }, .white);
    scene.popStrokeStyle();
    try scene.strokeLineCurrent(.{ .x = 1, .y = 1 }, .{ .x = 7, .y = 1 }, .white);

    try std.testing.expectEqual(@as(f32, 4.0), scene.primitives.items[0].line.width);
    try std.testing.expectEqual(LineCap.butt, scene.primitives.items[0].line.cap);
    try std.testing.expectEqual(@as(f32, 2.0), scene.primitives.items[1].line.width);
    try std.testing.expectEqual(LineCap.square, scene.primitives.items[1].line.cap);
}

test "source color state drives current stroke drawing" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    scene.setSourceColor(.blue);
    try scene.strokeLineSource(.{ .x = 1, .y = 4 }, .{ .x = 7, .y = 4 });

    try std.testing.expectEqual(Color.blue, scene.primitives.items[0].line.color);
    try std.testing.expectEqual(Color.blue, scene.getSourceColor());
}

test "scene state getters report current drawing state" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try std.testing.expectEqual(BlendMode.source_over, scene.getBlendMode());
    try std.testing.expectEqual(FillRule.non_zero, scene.getFillRule());
    try std.testing.expectEqual(AntiAliasMode.default, scene.getAntiAlias());
    try std.testing.expectEqual(@as(f32, 2.0), scene.getLineWidth());
    try std.testing.expectEqual(LineCap.butt, scene.getLineCap());
    try std.testing.expectEqual(LineJoin.miter, scene.getLineJoin());
    try std.testing.expectEqual(@as(f32, 4.0), scene.getMiterLimit());
    try std.testing.expectEqual(@as(usize, 0), scene.getDashes().len);
    try std.testing.expect(!scene.getHairline());

    try scene.pushBlendMode(.multiply);
    try scene.pushFillRule(.even_odd);
    try scene.pushAntiAlias(.none);
    scene.setLineWidth(5);
    scene.setLineCap(.round);
    scene.setLineJoin(.bevel);
    scene.setMiterLimit(2);
    scene.setDashes(&.{ 3, 1, 2 });
    scene.setDashOffset(4);
    scene.setHairline(true);

    try std.testing.expectEqual(BlendMode.multiply, scene.getBlendMode());
    try std.testing.expectEqual(FillRule.even_odd, scene.getFillRule());
    try std.testing.expectEqual(AntiAliasMode.none, scene.getAntiAlias());
    try std.testing.expectEqual(@as(f32, 5.0), scene.getLineWidth());
    try std.testing.expectEqual(LineCap.round, scene.getLineCap());
    try std.testing.expectEqual(LineJoin.bevel, scene.getLineJoin());
    try std.testing.expectEqual(@as(f32, 2.0), scene.getMiterLimit());
    try std.testing.expectEqual(@as(usize, 3), scene.getDashes().len);
    try std.testing.expectEqual(@as(f32, 4.0), scene.getDashOffset());
    try std.testing.expect(scene.getHairline());

    scene.popBlendMode();
    scene.popFillRule();
    scene.popAntiAlias();
    try std.testing.expectEqual(BlendMode.source_over, scene.getBlendMode());
    try std.testing.expectEqual(FillRule.non_zero, scene.getFillRule());
    try std.testing.expectEqual(AntiAliasMode.default, scene.getAntiAlias());
}

test "strokeLineCurrent honors hairline state" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    scene.setLineWidth(8);
    scene.setHairline(true);
    try scene.strokeLineCurrent(.{ .x = 1, .y = 4 }, .{ .x = 7, .y = 4 }, .white);

    try std.testing.expectEqual(@as(f32, 1.0), scene.primitives.items[0].line.width);
    try std.testing.expectEqual(LineCap.butt, scene.primitives.items[0].line.cap);
}

test "hairline lines draw with butt caps" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeHairline(.{ .x = 2, .y = 4 }, .{ .x = 7, .y = 4 }, .white);

    var strips = try scene.buildSparseStrips(allocator, 10, 8);
    defer strips.deinit(allocator);

    var has_line = false;
    var extends_before = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) has_line = true;
        if (strip.y == 4 and strip.x <= 1 and strip.x + strip.width > 1) extends_before = true;
    }
    try std.testing.expect(has_line);
    try std.testing.expect(!extends_before);
}

test "zero-length lines only draw round caps" {
    const allocator = std.testing.allocator;
    var round_scene = Scene2D.init(allocator);
    defer round_scene.deinit();
    try round_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 4, .y = 4 }, 4, .round, .white);
    var round = try round_scene.buildSparseStrips(allocator, 10, 10);
    defer round.deinit(allocator);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 4, .y = 4 }, 4, .square, .white);
    var square = try square_scene.buildSparseStrips(allocator, 10, 10);
    defer square.deinit(allocator);

    try std.testing.expect(round.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), square.items.len);
}

test "stroked lines emit anti-aliased edge alpha" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeLine(.{ .x = 1, .y = 2 }, .{ .x = 7, .y = 2 }, 2, .white);

    var strips = try scene.buildSparseStrips(allocator, 10, 6);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_full = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.color.a == 255) has_full = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_full);
}

test "anti alias none quantizes line coverage" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushAntiAlias(.none);
    try scene.strokeLine(.{ .x = 1, .y = 2 }, .{ .x = 7, .y = 2 }, 2, .white);
    scene.popAntiAlias();

    var strips = try scene.buildSparseStrips(allocator, 10, 6);
    defer strips.deinit(allocator);

    for (strips.items) |strip| {
        try std.testing.expect(strip.color.a == 255);
    }
}

test "stroked lines apply scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 3));
    try scene.strokeLine(.{ .x = 1, .y = 2 }, .{ .x = 7, .y = 2 }, 2, .white);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 16, 10);
    defer strips.deinit(allocator);

    var moved = false;
    var original = false;
    for (strips.items) |strip| {
        if (strip.y == 5 and strip.x <= 6 and strip.x + strip.width > 6) moved = true;
        if (strip.y == 2 and strip.x <= 3 and strip.x + strip.width > 3) original = true;
    }
    try std.testing.expect(moved);
    try std.testing.expect(!original);
}

test "stroked line width and dash apply scene scale" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.scale(2, 2));
    try scene.strokeDashedLine(.{ .x = 1, .y = 4 }, .{ .x = 9, .y = 4 }, 2, 2, 2, .white);
    scene.popTransform();

    try std.testing.expectEqual(@as(f32, 4.0), scene.primitives.items[0].line.width);
    try std.testing.expectEqual(@as(f32, 4.0), scene.primitives.items[0].line.dash_on);
    try std.testing.expectEqual(@as(f32, 4.0), scene.primitives.items[0].line.dash_off);

    var strips = try scene.buildSparseStrips(allocator, 24, 16);
    defer strips.deinit(allocator);

    var vertical_span: usize = 0;
    for (strips.items) |strip| {
        if (strip.x <= 4 and strip.x + strip.width > 4) vertical_span += 1;
    }
    try std.testing.expect(vertical_span >= 4);
}

test "dashed lines leave sparse strip gaps" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedLine(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .white);

    var strips = try scene.buildSparseStrips(allocator, 16, 8);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_first_dash = false;
    var has_gap = false;
    var has_second_dash = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) has_first_dash = true;
        if (strip.y == 4 and strip.x <= 5 and strip.x + strip.width > 5) has_gap = true;
        if (strip.y == 4 and strip.x <= 8 and strip.x + strip.width > 8) has_second_dash = true;
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(has_first_dash);
    try std.testing.expect(!has_gap);
    try std.testing.expect(has_second_dash);
}

test "dashed lines apply dash offset" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeDashedLineOffset(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, 3, .white);

    var strips = try scene.buildSparseStrips(allocator, 16, 8);
    defer strips.deinit(allocator);

    var start_gap = false;
    var shifted_dash = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) start_gap = true;
        if (strip.y == 4 and strip.x <= 5 and strip.x + strip.width > 5) shifted_dash = true;
    }
    try std.testing.expect(!start_gap);
    try std.testing.expect(shifted_dash);
}

test "dashed lines support multi-segment dash patterns" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.strokeLinePattern(.{ .x = 1, .y = 4 }, .{ .x = 17, .y = 4 }, 2, DashPattern.fromSlice(&.{ 2, 2, 4, 2 }, 0), .butt, .white);

    var strips = try scene.buildSparseStrips(allocator, 20, 8);
    defer strips.deinit(allocator);

    var first_dash = false;
    var first_gap = false;
    var long_dash = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) first_dash = true;
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) first_gap = true;
        if (strip.y == 4 and strip.x <= 7 and strip.x + strip.width > 7) long_dash = true;
    }
    try std.testing.expect(first_dash);
    try std.testing.expect(!first_gap);
    try std.testing.expect(long_dash);
}

test "dashed line cap modes extend dash endpoints" {
    const allocator = std.testing.allocator;
    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeDashedLineCap(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .butt, .white);
    var butt = try butt_scene.buildSparseStrips(allocator, 16, 8);
    defer butt.deinit(allocator);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeDashedLineCap(.{ .x = 1, .y = 4 }, .{ .x = 13, .y = 4 }, 2, 3, 3, .square, .white);
    var square = try square_scene.buildSparseStrips(allocator, 16, 8);
    defer square.deinit(allocator);

    var butt_gap_edge = false;
    for (butt.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) butt_gap_edge = true;
    }
    var square_gap_edge = false;
    for (square.items) |strip| {
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) square_gap_edge = true;
    }
    try std.testing.expect(!butt_gap_edge);
    try std.testing.expect(square_gap_edge);
}

test "line cap modes change endpoint coverage" {
    const allocator = std.testing.allocator;
    var butt_scene = Scene2D.init(allocator);
    defer butt_scene.deinit();
    try butt_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 12, .y = 4 }, 2, .butt, .white);
    var butt = try butt_scene.buildSparseStrips(allocator, 16, 8);
    defer butt.deinit(allocator);

    var square_scene = Scene2D.init(allocator);
    defer square_scene.deinit();
    try square_scene.strokeLineCap(.{ .x = 4, .y = 4 }, .{ .x = 12, .y = 4 }, 2, .square, .white);
    var square = try square_scene.buildSparseStrips(allocator, 16, 8);
    defer square.deinit(allocator);

    var butt_before_start = false;
    for (butt.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) butt_before_start = true;
    }
    var square_before_start = false;
    for (square.items) |strip| {
        if (strip.y == 4 and strip.x <= 3 and strip.x + strip.width > 3) square_before_start = true;
    }
    try std.testing.expect(!butt_before_start);
    try std.testing.expect(square_before_start);
}

test "clip rect constrains subsequent sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try scene.pushClipRect(.{ .x = 2, .y = 2, .w = 3, .h = 2 });
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .red);
    scene.popClip();
    try scene.fillRect(.{ .x = 8, .y = 8, .w = 1, .h = 1 }, .blue);

    var strips = try scene.buildSparseStrips(allocator, 16, 16);
    defer strips.deinit(allocator);

    var red_pixels: usize = 0;
    var blue_pixels: usize = 0;
    for (strips.items) |strip| {
        if (strip.color.toRgba32() == Color.red.toRgba32()) {
            red_pixels += strip.width;
            try std.testing.expect(strip.x >= 2 and strip.x + strip.width <= 5);
            try std.testing.expect(strip.y >= 2 and strip.y < 4);
        }
        if (strip.color.toRgba32() == Color.blue.toRgba32()) {
            blue_pixels += strip.width;
        }
    }

    try std.testing.expectEqual(@as(usize, 6), red_pixels);
    try std.testing.expectEqual(@as(usize, 1), blue_pixels);
}

test "clip rect applies scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try scene.pushTransform(math.Affine2D.identity.translate(4, 0));
    try scene.pushClipRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 });
    scene.popTransform();
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 8, .h = 1 }, .red);
    scene.popClip();

    var strips = try scene.buildSparseStrips(allocator, 8, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), strips.items.len);
    try std.testing.expectEqual(@as(u16, 4), strips.items[0].x);
    try std.testing.expectEqual(@as(u16, 2), strips.items[0].width);
}

test "clip paths constrain subsequent sparse strips" {
    const allocator = std.testing.allocator;
    var clip = Path.init(allocator);
    defer clip.deinit();
    try clip.moveTo(.{ .x = 0, .y = 0 });
    try clip.lineTo(.{ .x = 4, .y = 0 });
    try clip.lineTo(.{ .x = 0, .y = 4 });
    try clip.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushClipPath(&clip, .non_zero);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .red);
    try scene.popClipPath();
    try scene.fillRect(.{ .x = 3, .y = 3, .w = 1, .h = 1 }, .blue);

    var strips = try scene.buildSparseStrips(allocator, 4, 4);
    defer strips.deinit(allocator);

    var red_pixels: usize = 0;
    var blue_pixels: usize = 0;
    var red_outside = false;
    for (strips.items) |strip| {
        if (strip.color.toRgba32() == Color.red.toRgba32()) {
            red_pixels += strip.width;
            if (strip.y == 3 and strip.x <= 3 and strip.x + strip.width > 3) red_outside = true;
        } else if (strip.color.toRgba32() == Color.blue.toRgba32()) {
            blue_pixels += strip.width;
        }
    }
    try std.testing.expect(red_pixels > 0);
    try std.testing.expect(!red_outside);
    try std.testing.expectEqual(@as(usize, 1), blue_pixels);
}

test "clip paths apply partial edge alpha" {
    const allocator = std.testing.allocator;
    var clip = Path.init(allocator);
    defer clip.deinit();
    try clip.moveTo(.{ .x = 0, .y = 0 });
    try clip.lineTo(.{ .x = 4, .y = 0 });
    try clip.lineTo(.{ .x = 0, .y = 4 });
    try clip.close();

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushClipPath(&clip, .non_zero);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .white);
    try scene.popClipPath();

    var strips = try scene.buildSparseStrips(allocator, 4, 4);
    defer strips.deinit(allocator);

    var has_partial = false;
    var partial_alpha: u8 = 0;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) {
            has_partial = true;
            partial_alpha = strip.color.a;
        }
    }
    try std.testing.expect(has_partial);
    try std.testing.expect(partial_alpha % 4 == 0);
}

test "nested clip paths intersect coverage" {
    const allocator = std.testing.allocator;
    var left = Path.init(allocator);
    defer left.deinit();
    try rectPath(&left, .{ .x = 0, .y = 0, .w = 3, .h = 4 });

    var right = Path.init(allocator);
    defer right.deinit();
    try rectPath(&right, .{ .x = 1, .y = 1, .w = 3, .h = 2 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushClipPathCurrent(&left);
    try scene.pushClipPathCurrent(&right);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .white);
    try scene.popClipPath();
    try scene.popClipPath();

    var strips = try scene.buildSparseStrips(allocator, 4, 4);
    defer strips.deinit(allocator);

    var pixels: usize = 0;
    var outside_intersection = false;
    for (strips.items) |strip| {
        pixels += strip.width;
        if (strip.y == 0 or strip.y == 3 or strip.x < 1 or strip.x + strip.width > 3) outside_intersection = true;
    }
    try std.testing.expect(pixels > 0);
    try std.testing.expect(!outside_intersection);
}

test "nested clip paths combine curved and even-odd coverage" {
    const allocator = std.testing.allocator;
    var circle = Path.init(allocator);
    defer circle.deinit();
    try ellipsePath(&circle, .{ .x = 4, .y = 4 }, .{ .x = 3, .y = 3 });

    var ring = Path.init(allocator);
    defer ring.deinit();
    try rectPath(&ring, .{ .x = 1, .y = 1, .w = 6, .h = 6 });
    try rectPath(&ring, .{ .x = 3, .y = 3, .w = 2, .h = 2 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushClipPath(&circle, .non_zero);
    try scene.pushClipPath(&ring, .even_odd);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, .white);
    try scene.popClipPath();
    try scene.popClipPath();

    var strips = try scene.buildSparseStrips(allocator, 8, 8);
    defer strips.deinit(allocator);

    var has_partial = false;
    var has_center = false;
    var has_outer_corner = false;
    for (strips.items) |strip| {
        if (strip.color.a > 0 and strip.color.a < 255) has_partial = true;
        if (strip.y == 4 and strip.x <= 4 and strip.x + strip.width > 4) has_center = true;
        if (strip.y == 0 and strip.x <= 0 and strip.x + strip.width > 0) has_outer_corner = true;
    }
    try std.testing.expect(strips.items.len > 0);
    try std.testing.expect(has_partial);
    try std.testing.expect(!has_center);
    try std.testing.expect(!has_outer_corner);
}

test "opacity state scales subsequent sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try scene.pushOpacity(0.5);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);
    scene.popOpacity();
    try scene.fillRect(.{ .x = 1, .y = 0, .w = 1, .h = 1 }, .white);

    var strips = try scene.buildSparseStrips(allocator, 2, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), strips.items.len);
    try std.testing.expectEqual(@as(u8, 128), strips.items[0].color.a);
    try std.testing.expectEqual(@as(u8, 255), strips.items[1].color.a);
}

test "fill rule state controls fillPathCurrent" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try rectPath(&path, .{ .x = 0, .y = 0, .w = 4, .h = 4 });
    try rectPath(&path, .{ .x = 1, .y = 1, .w = 2, .h = 2 });

    var even_odd_scene = Scene2D.init(allocator);
    defer even_odd_scene.deinit();
    try even_odd_scene.pushFillRule(.even_odd);
    try even_odd_scene.fillPathCurrent(&path, .white);
    even_odd_scene.popFillRule();
    var even_odd = try even_odd_scene.buildSparseStrips(allocator, 4, 4);
    defer even_odd.deinit(allocator);

    var non_zero_scene = Scene2D.init(allocator);
    defer non_zero_scene.deinit();
    try non_zero_scene.fillPathCurrent(&path, .white);
    var non_zero = try non_zero_scene.buildSparseStrips(allocator, 4, 4);
    defer non_zero.deinit(allocator);

    var even_odd_pixels: usize = 0;
    var non_zero_pixels: usize = 0;
    for (even_odd.items) |strip| even_odd_pixels += strip.width;
    for (non_zero.items) |strip| non_zero_pixels += strip.width;
    try std.testing.expect(even_odd_pixels < non_zero_pixels);
    try std.testing.expectEqual(FillRule.non_zero, even_odd_scene.current_fill_rule);
}

test "source color state drives current fill drawing" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try rectPath(&path, .{ .x = 0, .y = 0, .w = 2, .h = 2 });

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    scene.setSourceColor(.red);
    try scene.fillRectCurrent(.{ .x = 3, .y = 0, .w = 1, .h = 1 });
    try scene.fillPathSource(&path);

    var strips = try scene.buildSparseStrips(allocator, 4, 2);
    defer strips.deinit(allocator);

    var red_pixels: usize = 0;
    for (strips.items) |strip| {
        if (strip.color.toRgba32() == Color.red.toRgba32()) red_pixels += strip.width;
    }
    try std.testing.expectEqual(@as(usize, 5), red_pixels);
}

test "nested opacity state multiplies" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();

    try scene.pushOpacity(0.5);
    try scene.pushOpacity(0.5);
    try scene.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .white);

    var strips = try scene.buildSparseStrips(allocator, 1, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 64), strips.items[0].color.a);
}

test "linear gradient rectangles become per-pixel sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 3, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    });

    var strips = try scene.buildSparseStrips(allocator, 4, 2);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), strips.items.len);
    try std.testing.expect(strips.items[0].color.r > strips.items[2].color.r);
    try std.testing.expect(strips.items[0].color.b < strips.items[2].color.b);
}

test "multi-stop linear gradients sample interior stops" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    var stops = [_]GradientStop{.{}} ** max_gradient_stops;
    stops[0] = .{ .offset = 0.0, .color = .red };
    stops[1] = .{ .offset = 0.5, .color = .green };
    stops[2] = .{ .offset = 1.0, .color = .blue };
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 5, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 5, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
        .stops = stops,
        .stop_count = 3,
    });

    var strips = try scene.buildSparseStrips(allocator, 5, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), strips.items.len);
    try std.testing.expect(strips.items[0].color.r > strips.items[0].color.g);
    try std.testing.expect(strips.items[2].color.g > strips.items[2].color.r and strips.items[2].color.g > strips.items[2].color.b);
    try std.testing.expect(strips.items[4].color.b > strips.items[4].color.g);
}

test "gradient addStop keeps stops sorted and bounded" {
    var linear = LinearGradient{
        .start = .{},
        .end = .{ .x = 1 },
        .start_color = .black,
        .end_color = .white,
    };
    try linear.addStop(1.0, .blue);
    try linear.addStop(0.0, .red);
    linear.addStopAssumeCapacity(0.5, .green);
    try std.testing.expectEqual(@as(u8, 3), linear.stop_count);
    try std.testing.expectEqual(@as(f32, 0.0), linear.stops[0].offset);
    try std.testing.expectEqual(@as(f32, 0.5), linear.stops[1].offset);
    try std.testing.expectEqual(@as(f32, 1.0), linear.stops[2].offset);

    var radial = RadialGradient{ .center = .{}, .radius = 1, .inner_color = .black, .outer_color = .white };
    try radial.addStop(0.25, .red);
    try std.testing.expectEqual(@as(u8, 1), radial.stop_count);

    var sweep = SweepGradient{ .center = .{}, .start_color = .black, .end_color = .white };
    try sweep.addStop(0.25, .red);
    try std.testing.expectEqual(@as(u8, 1), sweep.stop_count);

    var full = LinearGradient{ .start = .{}, .end = .{ .x = 1 }, .start_color = .black, .end_color = .white };
    for (0..max_gradient_stops) |i| {
        try full.addStop(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(max_gradient_stops - 1)), .white);
    }
    try std.testing.expectError(error.GradientStopCapacityExceeded, full.addStop(0.5, .black));
}

test "linear gradients support repeat and reflect spread" {
    const allocator = std.testing.allocator;
    var repeat_scene = Scene2D.init(allocator);
    defer repeat_scene.deinit();
    try repeat_scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 2, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
        .spread = .repeat,
    });
    var repeat_strips = try repeat_scene.buildSparseStrips(allocator, 4, 1);
    defer repeat_strips.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), repeat_strips.items.len);
    try std.testing.expect(repeat_strips.items[0].color.r > repeat_strips.items[0].color.b);
    try std.testing.expect(repeat_strips.items[2].color.r > repeat_strips.items[2].color.b);

    var reflect_scene = Scene2D.init(allocator);
    defer reflect_scene.deinit();
    try reflect_scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 2, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
        .spread = .reflect,
    });
    var reflect_strips = try reflect_scene.buildSparseStrips(allocator, 4, 1);
    defer reflect_strips.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), reflect_strips.items.len);
    try std.testing.expect(reflect_strips.items[0].color.r > reflect_strips.items[0].color.b);
    try std.testing.expect(reflect_strips.items[2].color.b > reflect_strips.items[2].color.r);
}

test "linear gradients can interpolate in linear rgb" {
    const allocator = std.testing.allocator;
    var srgb_scene = Scene2D.init(allocator);
    defer srgb_scene.deinit();
    try srgb_scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 3, .y = 0 },
        .start_color = .black,
        .end_color = .white,
    });
    var srgb = try srgb_scene.buildSparseStrips(allocator, 3, 1);
    defer srgb.deinit(allocator);

    var linear_scene = Scene2D.init(allocator);
    defer linear_scene.deinit();
    try linear_scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 3, .y = 0 },
        .start_color = .black,
        .end_color = .white,
        .interpolation = .linear_rgb,
    });
    var linear = try linear_scene.buildSparseStrips(allocator, 3, 1);
    defer linear.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), srgb.items.len);
    try std.testing.expectEqual(@as(usize, 3), linear.items.len);
    try std.testing.expect(linear.items[1].color.r > srgb.items[1].color.r);
    try std.testing.expectEqual(linear.items[1].color.r, linear.items[1].color.g);
    try std.testing.expectEqual(linear.items[1].color.g, linear.items[1].color.b);
}

test "gradients can be sampled directly at points" {
    var stops = [_]GradientStop{.{}} ** max_gradient_stops;
    stops[0] = .{ .offset = 0.0, .color = .red };
    stops[1] = .{ .offset = 1.0, .color = .blue };

    const linear = LinearGradient{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 10, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    };
    try std.testing.expect(linear.sampleAt(.{ .x = 2, .y = 0 }).r > linear.sampleAt(.{ .x = 8, .y = 0 }).r);

    const radial = RadialGradient{
        .center = .{ .x = 5, .y = 0 },
        .radius = 5,
        .inner_color = .red,
        .outer_color = .blue,
    };
    try std.testing.expect(radial.sampleAt(.{ .x = 5, .y = 0 }).r > radial.sampleAt(.{ .x = 10, .y = 0 }).r);

    const sweep = SweepGradient{
        .center = .{},
        .start_color = .red,
        .end_color = .blue,
        .stops = stops,
        .stop_count = 2,
    };
    try std.testing.expect(sweep.sampleAt(.{ .x = 1, .y = 0 }).r > sweep.sampleAt(.{ .x = -1, .y = 0 }).r);
}

test "gradients expose z2d-like offsets at points" {
    const linear = LinearGradient{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 10, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    };
    try std.testing.expectEqual(@as(f32, 0.5), linear.offsetAt(.{ .x = 5, .y = 5 }));
    try std.testing.expectEqual(@as(f32, 0.0), linear.offsetAt(.{ .x = -10, .y = 0 }));
    try std.testing.expectEqual(@as(f32, -1.0), (LinearGradient{
        .start = .{},
        .end = .{},
        .start_color = .red,
        .end_color = .blue,
    }).offsetAt(.{}));

    const radial = RadialGradient{
        .center = .{ .x = 5, .y = 0 },
        .radius = 5,
        .inner_color = .red,
        .outer_color = .blue,
    };
    try std.testing.expectEqual(@as(f32, 0.0), radial.offsetAt(.{ .x = 5, .y = 0 }));
    try std.testing.expectEqual(@as(f32, 1.0), radial.offsetAt(.{ .x = 10, .y = 0 }));
    try std.testing.expectEqual(@as(f32, -1.0), (RadialGradient{
        .center = .{},
        .radius = 0,
        .inner_color = .red,
        .outer_color = .blue,
    }).offsetAt(.{}));

    const sweep = SweepGradient{
        .center = .{},
        .start_color = .red,
        .end_color = .blue,
    };
    try std.testing.expectEqual(@as(f32, 0.0), sweep.offsetAt(.{ .x = 1, .y = 0 }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sweep.offsetAt(.{ .x = 0, .y = 1 }), 0.000001);
}

test "linear gradients support bayer dither" {
    const allocator = std.testing.allocator;
    var plain_scene = Scene2D.init(allocator);
    defer plain_scene.deinit();
    try plain_scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 1, .y = 0 },
        .start_color = Color.rgba(128, 128, 128, 255),
        .end_color = Color.rgba(128, 128, 128, 255),
    });
    var plain = try plain_scene.buildSparseStrips(allocator, 2, 1);
    defer plain.deinit(allocator);

    var dither_scene = Scene2D.init(allocator);
    defer dither_scene.deinit();
    try dither_scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 1, .y = 0 },
        .start_color = Color.rgba(128, 128, 128, 255),
        .end_color = Color.rgba(128, 128, 128, 255),
        .dither = .bayer,
    });
    var dithered = try dither_scene.buildSparseStrips(allocator, 2, 1);
    defer dithered.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 128), plain.items[0].color.r);
    try std.testing.expectEqual(@as(u8, 128), plain.items[1].color.r);
    try std.testing.expect(dithered.items[0].color.r != dithered.items[1].color.r);
}

test "linear gradients support blue-noise dither" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 1, .y = 0 },
        .start_color = Color.rgba(128, 128, 128, 255),
        .end_color = Color.rgba(128, 128, 128, 255),
        .dither = .blue_noise,
    });
    var strips = try scene.buildSparseStrips(allocator, 4, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), strips.items.len);
    var different = false;
    for (strips.items[1..]) |strip| {
        if (strip.color.r != strips.items[0].color.r) different = true;
    }
    try std.testing.expect(different);
}

test "linear gradients inherit scene dither state" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    scene.setDither(.bayer);
    try std.testing.expectEqual(DitherMode.bayer, scene.getDither());
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 1, .y = 0 },
        .start_color = Color.rgba(128, 128, 128, 255),
        .end_color = Color.rgba(128, 128, 128, 255),
    });
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 1, .w = 2, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 1, .y = 0 },
        .start_color = Color.rgba(128, 128, 128, 255),
        .end_color = Color.rgba(128, 128, 128, 255),
        .dither = .blue_noise,
    });

    try std.testing.expectEqual(DitherMode.bayer, scene.primitives.items[0].fill_linear_gradient_rect.gradient.dither);
    try std.testing.expectEqual(DitherMode.blue_noise, scene.primitives.items[1].fill_linear_gradient_rect.gradient.dither);
}

test "linear gradient rectangles apply scene transform" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 0));
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 3, .y = 0 },
        .start_color = .red,
        .end_color = .blue,
    });
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 8, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), strips.items.len);
    try std.testing.expectEqual(@as(u16, 4), strips.items[0].x);
    try std.testing.expect(strips.items[0].color.r > strips.items[2].color.r);
}

test "radial gradient rectangles become per-pixel sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRadialGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .center = .{ .x = 0.5, .y = 0.5 },
        .radius = 3,
        .inner_color = .red,
        .outer_color = .blue,
    });

    var strips = try scene.buildSparseStrips(allocator, 4, 2);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), strips.items.len);
    try std.testing.expect(strips.items[0].color.r > strips.items[2].color.r);
    try std.testing.expect(strips.items[0].color.b < strips.items[2].color.b);
}

test "radial gradients support distinct inner circle" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillRadialGradientRect(.{ .x = 0, .y = 0, .w = 5, .h = 1 }, .{
        .center = .{ .x = 4.5, .y = 0.5 },
        .radius = 4,
        .inner_center = .{ .x = 0.5, .y = 0.5 },
        .inner_radius = 0,
        .inner_color = .red,
        .outer_color = .blue,
    });

    var strips = try scene.buildSparseStrips(allocator, 5, 1);
    defer strips.deinit(allocator);

    try std.testing.expect(strips.items.len >= 4);
    try std.testing.expect(strips.items[0].color.r > strips.items[strips.items.len - 1].color.r);
    try std.testing.expect(strips.items[strips.items.len - 1].color.b > strips.items[0].color.b);
}

test "sweep gradient rectangles become per-pixel sparse strips" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillSweepGradientRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, .{
        .center = .{ .x = 1.5, .y = 1.5 },
        .start_color = .red,
        .end_color = .blue,
    });

    var strips = try scene.buildSparseStrips(allocator, 4, 4);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), strips.items.len);
    try std.testing.expect(strips.items[0].color.r > strips.items[1].color.r);
    try std.testing.expect(strips.items[1].color.r > strips.items[2].color.r);
    try std.testing.expect(strips.items[0].color.b < strips.items[1].color.b);
}

test "sweep gradients sample interior stops" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    var stops = [_]GradientStop{.{}} ** max_gradient_stops;
    stops[0] = .{ .offset = 0.0, .color = .red };
    stops[1] = .{ .offset = 0.25, .color = .green };
    stops[2] = .{ .offset = 0.5, .color = .blue };
    stops[3] = .{ .offset = 1.0, .color = .white };
    try scene.fillSweepGradientRect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, .{
        .center = .{ .x = 2.5, .y = 2.5 },
        .start_color = .red,
        .end_color = .white,
        .stops = stops,
        .stop_count = 4,
    });

    var strips = try scene.buildSparseStrips(allocator, 5, 5);
    defer strips.deinit(allocator);

    var bottom_green = false;
    var left_blue = false;
    for (strips.items) |strip| {
        if (strip.y == 4 and strip.x <= 2 and strip.x + strip.width > 2) {
            bottom_green = strip.color.g > strip.color.r and strip.color.g > strip.color.b;
        }
        if (strip.y == 2 and strip.x == 0) {
            left_blue = strip.color.b > strip.color.r and strip.color.b > strip.color.g;
        }
    }
    try std.testing.expect(bottom_green);
    try std.testing.expect(left_blue);
}

test "sweep gradients support repeat spread" {
    const allocator = std.testing.allocator;
    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillSweepGradientRect(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{
        .center = .{ .x = 0.0, .y = 0.5 },
        .start_angle = std.math.pi * 0.25,
        .start_color = .red,
        .end_color = .blue,
        .spread = .repeat,
    });

    var strips = try scene.buildSparseStrips(allocator, 4, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), strips.items.len);
    try std.testing.expect(strips.items[0].color.b > strips.items[0].color.r);
    try std.testing.expect(strips.items[3].color.b > strips.items[3].color.r);
}

test "image rectangles copy and sample source pixels" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 2, 1, .transparent);
    defer image.deinit();
    image.writePixel(0, 0, .red);
    image.writePixel(1, 0, .blue);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillImageRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &image);
    image.writePixel(0, 0, .green);

    var strips = try scene.buildSparseStrips(allocator, 2, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), strips.items.len);
    try std.testing.expectEqual(Color.red, strips.items[0].color);
    try std.testing.expectEqual(Color.blue, strips.items[1].color);
}

test "image rectangles apply scene transform" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 2, 1, .transparent);
    defer image.deinit();
    image.writePixel(0, 0, .red);
    image.writePixel(1, 0, .blue);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 0));
    try scene.fillImageRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &image);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 8, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), strips.items.len);
    try std.testing.expectEqual(@as(u16, 4), strips.items[0].x);
    try std.testing.expectEqual(Color.red, strips.items[0].color);
    try std.testing.expectEqual(Color.blue, strips.items[1].color);
}

test "image sub-rectangles sample atlas regions" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 4, 1, .transparent);
    defer image.deinit();
    image.writePixel(0, 0, .red);
    image.writePixel(1, 0, .green);
    image.writePixel(2, 0, .blue);
    image.writePixel(3, 0, .white);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillImageSubRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &image, .{ .x = 1, .y = 0, .w = 2, .h = 1 });

    var strips = try scene.buildSparseStrips(allocator, 2, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), strips.items.len);
    try std.testing.expectEqual(Color.green, strips.items[0].color);
    try std.testing.expectEqual(Color.blue, strips.items[1].color);
}

test "masked rectangles scale alpha from mask image" {
    const allocator = std.testing.allocator;
    var mask = try Image.init(allocator, 2, 1, .transparent);
    defer mask.deinit();
    mask.writePixel(0, 0, Color.rgba(0, 0, 0, 128));
    mask.writePixel(1, 0, .transparent);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillMaskedRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .white, &mask);

    var strips = try scene.buildSparseStrips(allocator, 2, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), strips.items.len);
    try std.testing.expectEqual(@as(u8, 128), strips.items[0].color.a);
    try std.testing.expectEqual(@as(u16, 0), strips.items[0].x);
}

test "masked rectangles apply scene transform" {
    const allocator = std.testing.allocator;
    var mask = try Image.init(allocator, 2, 1, .transparent);
    defer mask.deinit();
    mask.writePixel(0, 0, Color.rgba(0, 0, 0, 128));
    mask.writePixel(1, 0, .white);

    var scene = Scene2D.init(allocator);
    defer scene.deinit();
    try scene.pushTransform(math.Affine2D.identity.translate(4, 0));
    try scene.fillMaskedRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .white, &mask);
    scene.popTransform();

    var strips = try scene.buildSparseStrips(allocator, 8, 1);
    defer strips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), strips.items.len);
    try std.testing.expectEqual(@as(u16, 4), strips.items[0].x);
    try std.testing.expectEqual(@as(u8, 128), strips.items[0].color.a);
    try std.testing.expectEqual(@as(u8, 255), strips.items[1].color.a);
}
