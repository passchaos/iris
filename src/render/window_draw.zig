const std = @import("std");
const scene2d = @import("scene2d.zig");
const window = @import("window_types.zig");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const Rect = @import("math.zig").Rect;
const Vec2 = @import("math.zig").Vec2;

pub const TextAtlasGlyph = struct {
    uv0: [2]f32,
    uv1: [2]f32,
    size: [2]f32,
    bearing: [2]f32,
    advance: f32,
};

pub const TextAtlasFont = struct {
    size_px: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    atlas_w: u32,
    atlas_h: u32,
    atlas_pixels: []const u8,
};

pub const ResolvedGlyph = struct {
    font_index: usize,
    glyph: TextAtlasGlyph,
};

pub const ResolveGlyphFn = *const fn (context: *anyopaque, base_font_index: usize, codepoint: u21) ?ResolvedGlyph;
pub const TextAtlasProvider = struct {
    context: *anyopaque,
    defaultFontIndexFn: *const fn (context: *anyopaque) ?usize,
    fontCountFn: *const fn (context: *anyopaque) usize,
    fontFn: *const fn (context: *anyopaque, index: usize) ?TextAtlasFont,
    resolveGlyphFn: ResolveGlyphFn,
};

pub fn appendDrawListToScene(draw_list: []const window.DrawCmd, dst: *scene2d.Scene2D) !void {
    for (draw_list) |cmd| {
        switch (cmd) {
            .rect => |r| try dst.fillRect(toRect(r.rect), toColor(r.color)),
            .fill_path => |p| {
                var path = try toPath(dst.allocator, p.path.commands);
                defer path.deinit();
                try dst.fillPath(&path, toColor(p.color), .non_zero);
            },
            .stroke_path => |p| {
                var path = try toPath(dst.allocator, p.path.commands);
                defer path.deinit();
                try strokePath(dst, &path, p.style, toColor(p.color));
            },
            .rounded_rect => |r| try dst.fillRoundedRect(toRect(r.rect), r.radius, toColor(r.color)),
            .stroke_rounded_rect => |r| try dst.strokeRoundedRect(toRect(r.rect), r.radius, r.thickness, toColor(r.color)),
            .paint_quad => |q| {
                try dst.fillRoundedRect(toRect(q.rect), q.radius, toColor(q.background));
                if (q.border_width > 0.0 and q.border_color[3] > 0.0) {
                    try dst.strokeRoundedRect(toRect(q.rect), q.radius, q.border_width, toColor(q.border_color));
                }
            },
            .triangle => |t| {
                var path = scene2d.Path.init(dst.allocator);
                defer path.deinit();
                try path.moveTo(toVec2(t.points[0]));
                try path.lineTo(toVec2(t.points[1]));
                try path.lineTo(toVec2(t.points[2]));
                try path.close();
                try dst.fillPath(&path, toColor(t.color), .non_zero);
            },
            .linear_gradient_rect => |g| {
                const gradient = scene2d.LinearGradient{
                    .start = toVec2(g.start),
                    .end = toVec2(g.end),
                    .start_color = toColor(g.start_color),
                    .end_color = toColor(g.end_color),
                };
                if (g.radius > 0.0) {
                    try dst.fillLinearGradientRoundedRect(toRect(g.rect), g.radius, gradient);
                } else {
                    try dst.fillLinearGradientRect(toRect(g.rect), gradient);
                }
            },
            .radial_gradient_rect => |g| {
                const gradient = scene2d.RadialGradient{
                    .center = toVec2(g.center),
                    .radius = g.radius,
                    .inner_color = toColor(g.inner_color),
                    .outer_color = toColor(g.outer_color),
                };
                if (g.radius_px > 0.0) {
                    try dst.fillRadialGradientRoundedRect(toRect(g.rect), g.radius_px, gradient);
                } else {
                    try dst.fillRadialGradientRect(toRect(g.rect), gradient);
                }
            },
            .sweep_gradient_rect => |g| {
                const gradient = scene2d.SweepGradient{
                    .center = toVec2(g.center),
                    .start_angle = g.start_angle,
                    .start_color = toColor(g.start_color),
                    .end_color = toColor(g.end_color),
                };
                if (g.radius > 0.0) {
                    try dst.fillSweepGradientRoundedRect(toRect(g.rect), g.radius, gradient);
                } else {
                    try dst.fillSweepGradientRect(toRect(g.rect), gradient);
                }
            },
            .ellipse => |e| try dst.fillEllipse(toVec2(e.center), toVec2(e.radius), toColor(e.color)),
            .stroke_ellipse => |e| try dst.strokeEllipse(toVec2(e.center), toVec2(e.radius), e.thickness, toColor(e.color)),
            .line => |l| try dst.strokeLine(toVec2(l.a), toVec2(l.b), l.thickness, toColor(l.color)),
            .styled_line => |l| try strokeLine(dst, l.a, l.b, l.style, toColor(l.color)),
            .point => |p| {
                const half = p.size * 0.5;
                try dst.fillRect(.{
                    .x = p.pos[0] - half,
                    .y = p.pos[1] - half,
                    .w = p.size,
                    .h = p.size,
                }, toColor(p.color));
            },
            .polyline => |pl| {
                var path = try polylinePath(dst.allocator, pl.points);
                defer path.deinit();
                try dst.strokePathCapJoinMiterLimit(&path, pl.thickness, .butt, .round, 4.0, toColor(pl.color));
            },
            .styled_polyline => |pl| {
                var path = try polylinePath(dst.allocator, pl.points);
                defer path.deinit();
                try strokePath(dst, &path, pl.style, toColor(pl.color));
            },
            .bars => |b| {
                for (b.values, 0..) |value, i| {
                    const x = b.origin[0] + @as(f32, @floatFromInt(i)) * b.bar_width;
                    try dst.fillRect(.{
                        .x = x,
                        .y = b.origin[1] + b.base,
                        .w = b.bar_width,
                        .h = value,
                    }, toColor(b.color));
                }
            },
            .scatter => |s| {
                for (s.points) |point| {
                    try dst.fillEllipse(toVec2(point), .{ .x = s.size * 0.5, .y = s.size * 0.5 }, toColor(s.color));
                }
            },
            .clip_begin => |clip| try dst.pushClipRect(toRect(clip)),
            .clip_end => dst.popClip(),
            .image, .text => {},
        }
    }
}

pub fn drawTextCommands(
    draw_list: []const window.DrawCmd,
    target: *Image,
    fonts: []const TextAtlasFont,
    default_font_index: ?usize,
    context: *anyopaque,
    resolve_glyph: ResolveGlyphFn,
) void {
    for (draw_list) |cmd| {
        switch (cmd) {
            .text => |text| drawTextCommand(text, target, fonts, default_font_index, context, resolve_glyph),
            else => {},
        }
    }
}

pub fn drawTextCommandsWithProvider(
    draw_list: []const window.DrawCmd,
    target: *Image,
    provider: TextAtlasProvider,
) void {
    for (draw_list) |cmd| {
        switch (cmd) {
            .text => |text| drawTextCommandWithProvider(text, target, provider),
            else => {},
        }
    }
}

fn drawTextCommand(
    cmd: anytype,
    target: *Image,
    fonts: []const TextAtlasFont,
    default_font_index: ?usize,
    context: *anyopaque,
    resolve_glyph: ResolveGlyphFn,
) void {
    const base_font_index = if (cmd.font_id) |font_id| @as(usize, @intCast(font_id)) else default_font_index orelse return;
    if (base_font_index >= fonts.len) return;
    const base_font = fonts[base_font_index];
    const base_scale = cmd.size / base_font.size_px;
    const line_height = (base_font.ascent - base_font.descent + base_font.line_gap) * base_scale;
    var pen_x = cmd.pos[0];
    var pen_y = cmd.pos[1];
    const line_start_x = pen_x;
    const view = std.unicode.Utf8View.initUnchecked(cmd.text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n') {
            pen_x = line_start_x;
            pen_y += line_height;
            continue;
        }
        const resolved = resolve_glyph(context, base_font_index, cp) orelse continue;
        if (resolved.font_index >= fonts.len) continue;
        const font = fonts[resolved.font_index];
        const scale = cmd.size / font.size_px;
        const gx = pen_x + resolved.glyph.bearing[0] * scale;
        const gy = pen_y + resolved.glyph.bearing[1] * scale;
        blitGlyph(target, font, resolved.glyph, gx, gy, scale, cmd.color);
        pen_x += resolved.glyph.advance * scale;
    }
}

fn drawTextCommandWithProvider(cmd: anytype, target: *Image, provider: TextAtlasProvider) void {
    const base_font_index = if (cmd.font_id) |font_id| @as(usize, @intCast(font_id)) else provider.defaultFontIndexFn(provider.context) orelse return;
    if (base_font_index >= provider.fontCountFn(provider.context)) return;
    const base_font = provider.fontFn(provider.context, base_font_index) orelse return;
    const base_scale = cmd.size / base_font.size_px;
    const line_height = (base_font.ascent - base_font.descent + base_font.line_gap) * base_scale;
    var pen_x = cmd.pos[0];
    var pen_y = cmd.pos[1];
    const line_start_x = pen_x;
    const view = std.unicode.Utf8View.initUnchecked(cmd.text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n') {
            pen_x = line_start_x;
            pen_y += line_height;
            continue;
        }
        const resolved = provider.resolveGlyphFn(provider.context, base_font_index, cp) orelse continue;
        if (resolved.font_index >= provider.fontCountFn(provider.context)) continue;
        const font = provider.fontFn(provider.context, resolved.font_index) orelse continue;
        const scale = cmd.size / font.size_px;
        const gx = pen_x + resolved.glyph.bearing[0] * scale;
        const gy = pen_y + resolved.glyph.bearing[1] * scale;
        blitGlyph(target, font, resolved.glyph, gx, gy, scale, cmd.color);
        pen_x += resolved.glyph.advance * scale;
    }
}

fn blitGlyph(target: *Image, font: TextAtlasFont, glyph: TextAtlasGlyph, x: f32, y: f32, scale: f32, color: [4]f32) void {
    if (glyph.size[0] <= 0.0 or glyph.size[1] <= 0.0) return;
    const src_x0: u32 = @intFromFloat(@floor(glyph.uv0[0] * @as(f32, @floatFromInt(font.atlas_w))));
    const src_y0: u32 = @intFromFloat(@floor(glyph.uv0[1] * @as(f32, @floatFromInt(font.atlas_h))));
    const src_x1: u32 = @intFromFloat(@ceil(glyph.uv1[0] * @as(f32, @floatFromInt(font.atlas_w))));
    const src_y1: u32 = @intFromFloat(@ceil(glyph.uv1[1] * @as(f32, @floatFromInt(font.atlas_h))));
    const dst_w: i32 = @intFromFloat(@ceil(glyph.size[0] * scale));
    const dst_h: i32 = @intFromFloat(@ceil(glyph.size[1] * scale));
    if (dst_w <= 0 or dst_h <= 0 or src_x1 <= src_x0 or src_y1 <= src_y0) return;
    const red = toByte(color[0]);
    const green = toByte(color[1]);
    const blue = toByte(color[2]);
    const color_alpha = toByte(color[3]);
    var dy: i32 = 0;
    while (dy < dst_h) : (dy += 1) {
        const py = @as(i32, @intFromFloat(@floor(y))) + dy;
        if (py < 0 or py >= @as(i32, @intCast(target.height))) continue;
        const sy = src_y0 + @as(u32, @intCast(@divTrunc(dy * @as(i32, @intCast(src_y1 - src_y0)), dst_h)));
        var dx: i32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const px = @as(i32, @intFromFloat(@floor(x))) + dx;
            if (px < 0 or px >= @as(i32, @intCast(target.width))) continue;
            const sx = src_x0 + @as(u32, @intCast(@divTrunc(dx * @as(i32, @intCast(src_x1 - src_x0)), dst_w)));
            const glyph_alpha = font.atlas_pixels[@as(usize, sy) * font.atlas_w + sx];
            if (glyph_alpha == 0) continue;
            const alpha: u8 = @intCast((@as(u16, glyph_alpha) * @as(u16, color_alpha)) / 255);
            target.blendPixel(@intCast(px), @intCast(py), Color.rgba(red, green, blue, alpha));
        }
    }
}

fn toRect(rect: window.Rect) Rect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

fn toVec2(point: [2]f32) Vec2 {
    return .{ .x = point[0], .y = point[1] };
}

fn toPath(allocator: std.mem.Allocator, commands: []const window.PathCommand) !scene2d.Path {
    var path = scene2d.Path.init(allocator);
    errdefer path.deinit();
    for (commands) |command| {
        switch (command) {
            .move_to => |p| try path.moveTo(toVec2(p)),
            .line_to => |p| try path.lineTo(toVec2(p)),
            .quad_to => |q| try path.quadTo(toVec2(q.control), toVec2(q.end)),
            .cubic_to => |c| try path.cubicTo(toVec2(c.c0), toVec2(c.c1), toVec2(c.end)),
            .arc => |a| try path.arc(toVec2(a.center), a.radius, a.start_angle, a.end_angle),
            .arc_negative => |a| try path.arcNegative(toVec2(a.center), a.radius, a.start_angle, a.end_angle),
            .close => try path.close(),
        }
    }
    return path;
}

fn polylinePath(allocator: std.mem.Allocator, points: []const [2]f32) !scene2d.Path {
    var path = scene2d.Path.init(allocator);
    errdefer path.deinit();
    if (points.len == 0) return path;
    try path.moveTo(toVec2(points[0]));
    for (points[1..]) |point| {
        try path.lineTo(toVec2(point));
    }
    return path;
}

fn strokePath(dst: *scene2d.Scene2D, path: *const scene2d.Path, style: window.StrokeStyle, color: Color) !void {
    if (style.dash.count > 0) {
        try dst.strokePathPattern(path, style.width, toDashPattern(style.dash), toLineCap(style.cap), color);
    } else {
        try dst.strokePathCapJoinMiterLimit(path, style.width, toLineCap(style.cap), toLineJoin(style.join), style.miter_limit, color);
    }
}

fn strokeLine(dst: *scene2d.Scene2D, a: [2]f32, b: [2]f32, style: window.StrokeStyle, color: Color) !void {
    if (style.dash.count > 0) {
        try dst.strokeLinePattern(toVec2(a), toVec2(b), style.width, toDashPattern(style.dash), toLineCap(style.cap), color);
    } else {
        try dst.strokeLineCap(toVec2(a), toVec2(b), style.width, toLineCap(style.cap), color);
    }
}

fn toLineCap(cap: window.StrokeCap) scene2d.LineCap {
    return switch (cap) {
        .butt => .butt,
        .square => .square,
        .round => .round,
    };
}

fn toLineJoin(join: window.StrokeJoin) scene2d.LineJoin {
    return switch (join) {
        .miter => .miter,
        .round => .round,
        .bevel => .bevel,
    };
}

fn toDashPattern(pattern: window.DashPattern) scene2d.DashPattern {
    return .{ .segments = pattern.segments, .count = pattern.count, .offset = pattern.offset };
}

fn toColor(color: [4]f32) Color {
    return Color.rgba(toByte(color[0]), toByte(color[1]), toByte(color[2]), toByte(color[3]));
}

fn toByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}
