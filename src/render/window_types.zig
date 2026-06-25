pub const Backend = enum {
    gpu,
    cpu,
};

pub const Vertex = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

pub const TextVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

pub const LineVertex = extern struct {
    pos: [2]f32,
    color: [4]f32,
    seg_a: [2]f32,
    seg_b: [2]f32,
    thickness: f32,
    side: f32,
};

pub const PaintQuadVertex = extern struct {
    pos: [2]f32,
    rect_origin: [2]f32,
    rect_size: [2]f32,
    radius: f32,
    background: [4]f32,
    border_color: [4]f32,
    border_width: f32,
};

pub const NodeId = u32;
pub const TextFontId = u32;
pub const ImageId = u32;

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Size = struct {
    w: f32,
    h: f32,
};

pub const PathCommand = union(enum) {
    move_to: [2]f32,
    line_to: [2]f32,
    quad_to: struct { control: [2]f32, end: [2]f32 },
    cubic_to: struct { c0: [2]f32, c1: [2]f32, end: [2]f32 },
    arc: struct { center: [2]f32, radius: f32, start_angle: f32, end_angle: f32 },
    arc_negative: struct { center: [2]f32, radius: f32, start_angle: f32, end_angle: f32 },
    close,
};

pub const Path2D = struct {
    commands: []const PathCommand,
};

pub const StrokeCap = enum {
    butt,
    square,
    round,
};

pub const StrokeJoin = enum {
    miter,
    round,
    bevel,
};

pub const StrokeQuality = enum {
    /// Let the renderer pick the best default for the primitive.
    auto,
    /// Fast segment shader path. Best for very dynamic, isolated single segments.
    fast,
    /// Continuous feathered geometry inspired by egui/epaint. Best for UI and plots.
    feathered,
    /// Vector-style continuous path mesh with explicit joins/caps.
    vector,
};

pub const max_dash_segments = 8;

pub const DashPattern = struct {
    segments: [max_dash_segments]f32 = [_]f32{0.0} ** max_dash_segments,
    count: u8 = 0,
    offset: f32 = 0.0,

    pub fn fromSlice(segments: []const f32, offset: f32) DashPattern {
        var pattern = DashPattern{ .offset = offset };
        const limit = @min(segments.len, max_dash_segments);
        for (segments[0..limit]) |segment| {
            if (segment < 0.0) return .{};
            pattern.segments[pattern.count] = segment;
            pattern.count += 1;
        }
        return if (pattern.totalLength() > 0.000001) pattern else .{};
    }

    pub fn fromPair(on: f32, off: f32, offset: f32) DashPattern {
        return DashPattern.fromSlice(&.{ on, off }, offset);
    }

    pub fn totalLength(self: DashPattern) f32 {
        var total: f32 = 0.0;
        for (self.segments[0..self.count]) |segment| total += segment;
        return total;
    }
};

pub const StrokeStyle = struct {
    width: f32 = 2.0,
    cap: StrokeCap = .butt,
    join: StrokeJoin = .miter,
    miter_limit: f32 = 4.0,
    dash: DashPattern = .{},
    quality: StrokeQuality = .auto,
};

pub const FillPath = struct {
    path: Path2D,
    color: [4]f32,
    layer: i32,
};

pub const StrokePath = struct {
    path: Path2D,
    style: StrokeStyle,
    color: [4]f32,
    layer: i32,
};

pub const StyledLine = struct {
    a: [2]f32,
    b: [2]f32,
    style: StrokeStyle,
    color: [4]f32,
    layer: i32,
};

pub const StyledPolyline = struct {
    points: []const [2]f32,
    style: StrokeStyle,
    color: [4]f32,
    layer: i32,
};

pub const Ellipse = struct {
    center: [2]f32,
    radius: [2]f32,
    color: [4]f32,
    layer: i32,
};

pub const StrokeEllipse = struct {
    center: [2]f32,
    radius: [2]f32,
    thickness: f32,
    color: [4]f32,
    layer: i32,
};

pub const RoundedRect = struct {
    rect: Rect,
    radius: f32,
    color: [4]f32,
    layer: i32,
};

pub const StrokeRoundedRect = struct {
    rect: Rect,
    radius: f32,
    thickness: f32,
    color: [4]f32,
    layer: i32,
};

pub const PaintQuad = struct {
    rect: Rect,
    radius: f32,
    background: [4]f32,
    border_width: f32 = 0.0,
    border_color: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    layer: i32,
};

pub const Triangle = struct {
    points: [3][2]f32,
    color: [4]f32,
    layer: i32,
};

pub const LinearGradientRect = struct {
    rect: Rect,
    radius: f32 = 0.0,
    start: [2]f32,
    end: [2]f32,
    start_color: [4]f32,
    end_color: [4]f32,
    layer: i32,
};

pub const RadialGradientRect = struct {
    rect: Rect,
    radius_px: f32 = 0.0,
    center: [2]f32,
    radius: f32,
    inner_color: [4]f32,
    outer_color: [4]f32,
    layer: i32,
};

pub const SweepGradientRect = struct {
    rect: Rect,
    radius: f32 = 0.0,
    center: [2]f32,
    start_angle: f32 = 0.0,
    start_color: [4]f32,
    end_color: [4]f32,
    layer: i32,
};

pub const DrawCmd = union(enum) {
    rect: struct { rect: Rect, color: [4]f32, layer: i32 },
    fill_path: FillPath,
    stroke_path: StrokePath,
    rounded_rect: RoundedRect,
    stroke_rounded_rect: StrokeRoundedRect,
    paint_quad: PaintQuad,
    triangle: Triangle,
    linear_gradient_rect: LinearGradientRect,
    radial_gradient_rect: RadialGradientRect,
    sweep_gradient_rect: SweepGradientRect,
    ellipse: Ellipse,
    stroke_ellipse: StrokeEllipse,
    line: struct { a: [2]f32, b: [2]f32, thickness: f32, color: [4]f32, layer: i32 },
    styled_line: StyledLine,
    point: struct { pos: [2]f32, size: f32, color: [4]f32, layer: i32 },
    polyline: struct { points: []const [2]f32, thickness: f32, color: [4]f32, layer: i32 },
    styled_polyline: StyledPolyline,
    bars: struct { values: []const f32, base: f32, bar_width: f32, origin: [2]f32, color: [4]f32, layer: i32 },
    scatter: struct { points: []const [2]f32, size: f32, color: [4]f32, layer: i32 },
    image: struct { image_id: ImageId, rect: Rect, tint: [4]f32, layer: i32 },
    text: struct { pos: [2]f32, size: f32, color: [4]f32, text: []const u8, font_id: ?TextFontId, rotation: f32 = 0.0, layer: i32 },
    clip_begin: Rect,
    clip_end: void,
};
