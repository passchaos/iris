const std = @import("std");
const cpu = @import("cpu.zig");
const cangjie = @import("cangjie");
const scene2d = @import("scene2d.zig");
const window = @import("window_types.zig");
const window_lower = @import("window_lower.zig");
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

pub const TextColorGlyph = struct {
    glyph: TextAtlasGlyph,
    width: u32,
    height: u32,
    rgba_pixels: []const u8,
};

pub const ShapedTextGlyph = struct {
    font_index: usize,
    glyph_id: cangjie.GlyphId,
    x_offset: f32,
    y_offset: f32,
    x_advance: f32,
};

pub const ResolveGlyphFn = *const fn (context: *anyopaque, base_font_index: usize, codepoint: u21) ?ResolvedGlyph;
pub const ResolveGlyphIdFn = *const fn (context: *anyopaque, font_index: usize, glyph_id: cangjie.GlyphId) ?ResolvedGlyph;
pub const ResolveColorGlyphFn = *const fn (context: *anyopaque, base_font_index: usize, codepoint: u21) ?TextColorGlyph;
pub const ResolveColorGlyphIdFn = *const fn (context: *anyopaque, font_index: usize, glyph_id: cangjie.GlyphId) ?TextColorGlyph;
pub const ShapeTextFn = *const fn (context: *anyopaque, allocator: std.mem.Allocator, base_font_index: usize, text: []const u8, size: f32) ?[]ShapedTextGlyph;
pub const TextAtlasProvider = struct {
    context: *anyopaque,
    defaultFontIndexFn: *const fn (context: *anyopaque) ?usize,
    fontCountFn: *const fn (context: *anyopaque) usize,
    fontFn: *const fn (context: *anyopaque, index: usize) ?TextAtlasFont,
    resolveGlyphFn: ResolveGlyphFn,
    resolveGlyphIdFn: ResolveGlyphIdFn = missingResolveGlyphId,
    resolveColorGlyphFn: ?ResolveColorGlyphFn = null,
    resolveColorGlyphIdFn: ?ResolveColorGlyphIdFn = null,
    shapeTextFn: ShapeTextFn = missingShapeText,
};

pub const ImageProvider = struct {
    context: *anyopaque,
    imageFn: *const fn (context: *anyopaque, image_id: window.ImageId) ?Image,
};

pub const ShapedTextLine = struct {
    glyphs: []ShapedTextGlyph,
};

fn missingResolveGlyphId(_: *anyopaque, _: usize, _: cangjie.GlyphId) ?ResolvedGlyph {
    return null;
}

fn missingShapeText(_: *anyopaque, _: std.mem.Allocator, _: usize, _: []const u8, _: f32) ?[]ShapedTextGlyph {
    return null;
}

pub fn shapeTextLines(
    allocator: std.mem.Allocator,
    provider: anytype,
    base_font_index: anytype,
    text: []const u8,
    size: f32,
) ![]ShapedTextLine {
    var lines = try std.ArrayList(ShapedTextLine).initCapacity(allocator, 0);
    errdefer {
        for (lines.items) |line| allocator.free(line.glyphs);
        lines.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        const glyphs = if (line.len == 0)
            try allocator.alloc(ShapedTextGlyph, 0)
        else
            provider.shapeTextFn(provider.context, allocator, base_font_index, line, size) orelse return error.TextShapingUnavailable;
        lines.append(allocator, .{ .glyphs = glyphs }) catch |err| {
            allocator.free(glyphs);
            return err;
        };
    }
    return try lines.toOwnedSlice(allocator);
}

pub fn freeShapedTextLines(allocator: std.mem.Allocator, lines: []ShapedTextLine) void {
    for (lines) |line| allocator.free(line.glyphs);
    allocator.free(lines);
}

pub fn appendDrawListToScene(draw_list: []const window.DrawCmd, dst: *scene2d.Scene2D) !void {
    try appendDrawListToSceneWithImages(draw_list, dst, null);
}

pub fn appendDrawListToSceneWithImages(draw_list: []const window.DrawCmd, dst: *scene2d.Scene2D, image_provider: ?ImageProvider) !void {
    var sink = SceneSink{ .scene = dst, .image_provider = image_provider };
    try window_lower.lowerDrawList(SceneSink, &sink, dst.allocator, draw_list);
}

fn tintImage(allocator: std.mem.Allocator, image: *const Image, tint: [4]f32) !Image {
    if (isWhiteTint(tint)) return try Image.initFromPixels(allocator, image.width, image.height, image.pixels);
    var out = try Image.init(allocator, image.width, image.height, .transparent);
    errdefer out.deinit();
    for (out.pixels, image.pixels) |*dst, src| {
        dst.* = Color.rgba(
            tintChannel(src.r, tint[0]),
            tintChannel(src.g, tint[1]),
            tintChannel(src.b, tint[2]),
            tintChannel(src.a, tint[3]),
        );
    }
    return out;
}

fn isWhiteTint(tint: [4]f32) bool {
    return @abs(tint[0] - 1.0) < 0.0001 and
        @abs(tint[1] - 1.0) < 0.0001 and
        @abs(tint[2] - 1.0) < 0.0001 and
        @abs(tint[3] - 1.0) < 0.0001;
}

fn tintChannel(value: u8, factor: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt(value)) * std.math.clamp(factor, 0.0, 1.0), 0.0, 255.0)));
}

const SceneSink = struct {
    scene: *scene2d.Scene2D,
    image_provider: ?ImageProvider,

    pub fn rect(self: *SceneSink, r: anytype, _: ?window.Rect) !void {
        try self.scene.fillRect(toRect(r.rect), toColor(r.color));
    }

    pub fn fillPath(self: *SceneSink, p: window.FillPath, _: ?window.Rect) !void {
        var path = try toPath(self.scene.allocator, p.path.commands);
        defer path.deinit();
        try self.scene.fillPath(&path, toColor(p.color), .non_zero);
    }

    pub fn strokePath(self: *SceneSink, p: window.StrokePath, _: ?window.Rect) !void {
        var path = try toPath(self.scene.allocator, p.path.commands);
        defer path.deinit();
        try strokeScenePath(self.scene, &path, p.style, toColor(p.color));
    }

    pub fn roundedRect(self: *SceneSink, r: window.RoundedRect, _: ?window.Rect) !void {
        try self.scene.fillRoundedRect(toRect(r.rect), r.radius, toColor(r.color));
    }

    pub fn strokeRoundedRect(self: *SceneSink, r: window.StrokeRoundedRect, _: ?window.Rect) !void {
        try self.scene.strokeRoundedRect(toRect(r.rect), r.radius, r.thickness, toColor(r.color));
    }

    pub fn paintQuad(self: *SceneSink, q: window.PaintQuad, _: ?window.Rect) !void {
        try self.scene.fillRoundedRect(toRect(q.rect), q.radius, toColor(q.background));
        if (q.border_width > 0.0 and q.border_color[3] > 0.0) {
            try self.scene.strokeRoundedRect(toRect(q.rect), q.radius, q.border_width, toColor(q.border_color));
        }
    }

    pub fn triangle(self: *SceneSink, t: window.Triangle, _: ?window.Rect) !void {
        var path = scene2d.Path.init(self.scene.allocator);
        defer path.deinit();
        try path.moveTo(toVec2(t.points[0]));
        try path.lineTo(toVec2(t.points[1]));
        try path.lineTo(toVec2(t.points[2]));
        try path.close();
        try self.scene.fillPath(&path, toColor(t.color), .non_zero);
    }

    pub fn linearGradientRect(self: *SceneSink, g: window.LinearGradientRect, _: ?window.Rect) !void {
        const gradient = scene2d.LinearGradient{
            .start = toVec2(g.start),
            .end = toVec2(g.end),
            .start_color = toColor(g.start_color),
            .end_color = toColor(g.end_color),
        };
        if (g.radius > 0.0) {
            try self.scene.fillLinearGradientRoundedRect(toRect(g.rect), g.radius, gradient);
        } else {
            try self.scene.fillLinearGradientRect(toRect(g.rect), gradient);
        }
    }

    pub fn radialGradientRect(self: *SceneSink, g: window.RadialGradientRect, _: ?window.Rect) !void {
        const gradient = scene2d.RadialGradient{
            .center = toVec2(g.center),
            .radius = g.radius,
            .inner_color = toColor(g.inner_color),
            .outer_color = toColor(g.outer_color),
        };
        if (g.radius_px > 0.0) {
            try self.scene.fillRadialGradientRoundedRect(toRect(g.rect), g.radius_px, gradient);
        } else {
            try self.scene.fillRadialGradientRect(toRect(g.rect), gradient);
        }
    }

    pub fn sweepGradientRect(self: *SceneSink, g: window.SweepGradientRect, _: ?window.Rect) !void {
        const gradient = scene2d.SweepGradient{
            .center = toVec2(g.center),
            .start_angle = g.start_angle,
            .start_color = toColor(g.start_color),
            .end_color = toColor(g.end_color),
        };
        if (g.radius > 0.0) {
            try self.scene.fillSweepGradientRoundedRect(toRect(g.rect), g.radius, gradient);
        } else {
            try self.scene.fillSweepGradientRect(toRect(g.rect), gradient);
        }
    }

    pub fn ellipse(self: *SceneSink, e: window.Ellipse, _: ?window.Rect) !void {
        try self.scene.fillEllipse(toVec2(e.center), toVec2(e.radius), toColor(e.color));
    }

    pub fn strokeEllipse(self: *SceneSink, e: window.StrokeEllipse, _: ?window.Rect) !void {
        try self.scene.strokeEllipse(toVec2(e.center), toVec2(e.radius), e.thickness, toColor(e.color));
    }

    pub fn line(self: *SceneSink, l: anytype, _: ?window.Rect) !void {
        try self.scene.strokeLine(toVec2(l.a), toVec2(l.b), l.thickness, toColor(l.color));
    }

    pub fn styledLine(self: *SceneSink, l: window.StyledLine, _: ?window.Rect) !void {
        try strokeLine(self.scene, l.a, l.b, l.style, toColor(l.color));
    }

    pub fn point(self: *SceneSink, p: anytype, _: ?window.Rect) !void {
        const half = p.size * 0.5;
        try self.scene.fillRect(.{
            .x = p.pos[0] - half,
            .y = p.pos[1] - half,
            .w = p.size,
            .h = p.size,
        }, toColor(p.color));
    }

    pub fn polyline(self: *SceneSink, p: anytype, _: ?window.Rect) !void {
        var path = try polylinePath(self.scene.allocator, p.points);
        defer path.deinit();
        try self.scene.strokePathCapJoinMiterLimit(&path, p.thickness, .butt, .round, 4.0, toColor(p.color));
    }

    pub fn styledPolyline(self: *SceneSink, p: window.StyledPolyline, _: ?window.Rect) !void {
        var path = try polylinePath(self.scene.allocator, p.points);
        defer path.deinit();
        try strokeScenePath(self.scene, &path, p.style, toColor(p.color));
    }

    pub fn bars(self: *SceneSink, b: anytype, _: ?window.Rect) !void {
        for (b.values, 0..) |value, i| {
            const x = b.origin[0] + @as(f32, @floatFromInt(i)) * b.bar_width;
            try self.scene.fillRect(.{
                .x = x,
                .y = b.origin[1] + b.base,
                .w = b.bar_width,
                .h = value,
            }, toColor(b.color));
        }
    }

    pub fn scatter(self: *SceneSink, s: anytype, _: ?window.Rect) !void {
        for (s.points) |scatter_point| {
            try self.scene.fillEllipse(toVec2(scatter_point), .{ .x = s.size * 0.5, .y = s.size * 0.5 }, toColor(s.color));
        }
    }

    pub fn image(self: *SceneSink, image_cmd: anytype, _: ?window.Rect) !void {
        if (self.image_provider) |provider| {
            if (provider.imageFn(provider.context, image_cmd.image_id)) |image_value| {
                var tinted = try tintImage(self.scene.allocator, &image_value, image_cmd.tint);
                defer tinted.deinit();
                try self.scene.fillImageRect(toRect(image_cmd.rect), &tinted);
            }
        }
    }

    pub fn text(_: *SceneSink, _: anytype, _: ?window.Rect) !void {}
};

pub fn renderDrawListCpu(
    draw_list: []const window.DrawCmd,
    dst: *scene2d.Scene2D,
    renderer: *cpu.CpuRenderer,
    target: *Image,
    text_provider: ?TextAtlasProvider,
    image_provider: ?ImageProvider,
    scale_factor: f32,
) !void {
    const scale = @max(0.25, scale_factor);
    var clip_stack = try std.ArrayList(window.Rect).initCapacity(dst.allocator, 8);
    defer clip_stack.deinit(dst.allocator);
    var scene_dirty = false;

    dst.clear();
    dst.scale(scale, scale);

    for (draw_list) |cmd| {
        switch (cmd) {
            .paint_quad => |quad| {
                try flushScene(dst, renderer, target, &clip_stack, scale, &scene_dirty);
                drawPaintQuad(target, quad, scale, currentClip(clip_stack.items));
            },
            .text => |text| {
                try flushScene(dst, renderer, target, &clip_stack, scale, &scene_dirty);
                if (text_provider) |provider| {
                    drawTextCommandWithProviderScaled(text, target, provider, scale, currentClip(clip_stack.items));
                }
            },
            .clip_begin => |clip| {
                try appendOneDrawCommandToScene(cmd, dst, image_provider);
                try clip_stack.append(dst.allocator, effectiveClip(currentClip(clip_stack.items), clip));
                scene_dirty = true;
            },
            .clip_end => {
                try appendOneDrawCommandToScene(cmd, dst, image_provider);
                _ = clip_stack.pop();
                scene_dirty = true;
            },
            else => {
                try appendOneDrawCommandToScene(cmd, dst, image_provider);
                scene_dirty = true;
            },
        }
    }
    try flushScene(dst, renderer, target, &clip_stack, scale, &scene_dirty);
}

fn appendOneDrawCommandToScene(cmd: window.DrawCmd, dst: *scene2d.Scene2D, image_provider: ?ImageProvider) !void {
    const one = [_]window.DrawCmd{cmd};
    try appendDrawListToSceneWithImages(&one, dst, image_provider);
}

fn flushScene(
    dst: *scene2d.Scene2D,
    renderer: *cpu.CpuRenderer,
    target: *Image,
    clip_stack: *const std.ArrayList(window.Rect),
    scale: f32,
    scene_dirty: *bool,
) !void {
    if (!scene_dirty.*) return;
    try renderer.render2D(dst, target);
    dst.clear();
    dst.scale(scale, scale);
    for (clip_stack.items) |clip| try dst.pushClipRect(toRect(clip));
    scene_dirty.* = false;
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
    drawTextCommandsWithProviderScaled(draw_list, target, provider, 1.0);
}

pub fn drawTextCommandsWithProviderScaled(
    draw_list: []const window.DrawCmd,
    target: *Image,
    provider: TextAtlasProvider,
    scale_factor: f32,
) void {
    const scale = @max(0.25, scale_factor);
    var clip_buf: [16]window.Rect = undefined;
    var clip_len: usize = 0;
    for (draw_list) |cmd| {
        switch (cmd) {
            .clip_begin => |rect| {
                const current = if (clip_len == 0) null else clip_buf[clip_len - 1];
                const next = effectiveClip(current, rect);
                if (clip_len < clip_buf.len) {
                    clip_buf[clip_len] = next;
                    clip_len += 1;
                }
            },
            .clip_end => {
                if (clip_len > 0) clip_len -= 1;
            },
            .text => |text| drawTextCommandWithProviderScaled(text, target, provider, scale, if (clip_len == 0) null else clip_buf[clip_len - 1]),
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
    var pen_y = textTopLeftY(cmd);
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
        blitGlyphRotated(target, font, resolved.glyph, gx, gy, scale, cmd.color, cmd.pos, cmd.rotation, null);
        pen_x += resolved.glyph.advance * scale;
    }
}

fn drawTextCommandWithProvider(cmd: anytype, target: *Image, provider: TextAtlasProvider) void {
    drawTextCommandWithProviderScaled(cmd, target, provider, 1.0, null);
}

fn drawTextCommandWithProviderScaled(cmd: anytype, target: *Image, provider: TextAtlasProvider, scale_factor: f32, clip: ?window.Rect) void {
    const base_font_index = if (cmd.font_id) |font_id| @as(usize, @intCast(font_id)) else provider.defaultFontIndexFn(provider.context) orelse return;
    if (base_font_index >= provider.fontCountFn(provider.context)) return;
    const base_font = provider.fontFn(provider.context, base_font_index) orelse return;
    const size = cmd.size * scale_factor;
    const base_scale = size / base_font.size_px;
    const line_height = (base_font.ascent - base_font.descent + base_font.line_gap) * base_scale;
    var pen_x = cmd.pos[0] * scale_factor;
    var pen_y = textTopLeftY(cmd) * scale_factor;
    const line_start_x = pen_x;
    const shaped_lines = shapeTextLines(target.allocator, provider, base_font_index, cmd.text, size) catch null;
    if (shaped_lines) |lines| {
        defer freeShapedTextLines(target.allocator, lines);
        for (lines) |line| {
            for (line.glyphs) |position| {
                if (provider.resolveColorGlyphIdFn) |resolve_color_glyph| {
                    if (resolve_color_glyph(provider.context, position.font_index, position.glyph_id)) |color_glyph| {
                        const gx = pen_x + position.x_offset + color_glyph.glyph.bearing[0] * scale_factor;
                        const gy = pen_y + position.y_offset + color_glyph.glyph.bearing[1] * scale_factor;
                        blitColorGlyph(target, color_glyph, gx, gy, cmd.color);
                        continue;
                    }
                }
                const resolved = provider.resolveGlyphIdFn(provider.context, position.font_index, position.glyph_id) orelse continue;
                const font = provider.fontFn(provider.context, resolved.font_index) orelse continue;
                const scale = size / font.size_px;
                const gx = pen_x + position.x_offset + resolved.glyph.bearing[0] * scale;
                const gy = pen_y + position.y_offset + resolved.glyph.bearing[1] * scale;
                blitGlyph(target, font, resolved.glyph, gx, gy, scale, cmd.color);
            }
            pen_x = line_start_x;
            pen_y += line_height;
        }
        return;
    }

    pen_x = line_start_x;
    pen_y = textTopLeftY(cmd) * scale_factor;
    const view = std.unicode.Utf8View.initUnchecked(cmd.text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n') {
            pen_x = line_start_x;
            pen_y += line_height;
            continue;
        }
        if (provider.resolveColorGlyphFn) |resolve_color_glyph| {
            if (resolve_color_glyph(provider.context, base_font_index, cp)) |color_glyph| {
                const gx = pen_x + color_glyph.glyph.bearing[0];
                const gy = pen_y + color_glyph.glyph.bearing[1];
                blitColorGlyph(target, color_glyph, gx, gy, cmd.color);
                pen_x += color_glyph.glyph.advance;
                continue;
            }
        }
        const resolved = provider.resolveGlyphFn(provider.context, base_font_index, cp) orelse continue;
        if (resolved.font_index >= provider.fontCountFn(provider.context)) continue;
        const font = provider.fontFn(provider.context, resolved.font_index) orelse continue;
        const scale = size / font.size_px;
        const gx = pen_x + resolved.glyph.bearing[0] * scale;
        const gy = pen_y + resolved.glyph.bearing[1] * scale;
        blitGlyphRotated(target, font, resolved.glyph, gx, gy, scale, cmd.color, .{ cmd.pos[0] * scale_factor, cmd.pos[1] * scale_factor }, cmd.rotation, scaledClipRect(clip, scale_factor));
        pen_x += resolved.glyph.advance * scale;
    }
}

fn blitColorGlyph(target: *Image, color_glyph: TextColorGlyph, x: f32, y: f32, tint: [4]f32) void {
    if (color_glyph.width == 0 or color_glyph.height == 0) return;
    if (color_glyph.rgba_pixels.len < @as(usize, color_glyph.width) * @as(usize, color_glyph.height) * 4) return;
    const dst_w: i32 = @intFromFloat(@ceil(color_glyph.glyph.size[0]));
    const dst_h: i32 = @intFromFloat(@ceil(color_glyph.glyph.size[1]));
    if (dst_w <= 0 or dst_h <= 0) return;
    const tint_alpha = std.math.clamp(tint[3], 0.0, 1.0);
    var dy: i32 = 0;
    while (dy < dst_h) : (dy += 1) {
        const py = @as(i32, @intFromFloat(@floor(y))) + dy;
        if (py < 0 or py >= @as(i32, @intCast(target.height))) continue;
        const sy: u32 = @intCast(@divTrunc(dy * @as(i32, @intCast(color_glyph.height)), dst_h));
        var dx: i32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const px = @as(i32, @intFromFloat(@floor(x))) + dx;
            if (px < 0 or px >= @as(i32, @intCast(target.width))) continue;
            const sx: u32 = @intCast(@divTrunc(dx * @as(i32, @intCast(color_glyph.width)), dst_w));
            const src = (@as(usize, sy) * color_glyph.width + sx) * 4;
            const alpha: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(color_glyph.rgba_pixels[src + 3])) * tint_alpha));
            if (alpha == 0) continue;
            target.blendPixel(
                @intCast(px),
                @intCast(py),
                Color.rgba(color_glyph.rgba_pixels[src + 0], color_glyph.rgba_pixels[src + 1], color_glyph.rgba_pixels[src + 2], alpha),
            );
        }
    }
}

fn textTopLeftY(cmd: anytype) f32 {
    if (!@hasField(@TypeOf(cmd), "origin")) return cmd.pos[1];
    return switch (cmd.origin) {
        .top_left => cmd.pos[1],
        .baseline => cmd.pos[1] - cmd.baseline,
    };
}

fn blitGlyph(target: *Image, font: TextAtlasFont, glyph: TextAtlasGlyph, x: f32, y: f32, scale: f32, color: [4]f32) void {
    blitGlyphClipped(target, font, glyph, x, y, scale, color, null);
}

fn blitGlyphRotated(target: *Image, font: TextAtlasFont, glyph: TextAtlasGlyph, x: f32, y: f32, scale: f32, color: [4]f32, origin: [2]f32, rotation: f32, clip: ?PixelClip) void {
    if (@abs(rotation) <= 0.0001) {
        blitGlyphClipped(target, font, glyph, x, y, scale, color, clip);
        return;
    }
    const cos_r = @cos(rotation);
    const sin_r = @sin(rotation);
    const p0 = rotatePoint(.{ x, y }, origin, cos_r, sin_r);
    const p1 = rotatePoint(.{ x + glyph.size[0] * scale, y }, origin, cos_r, sin_r);
    const p2 = rotatePoint(.{ x + glyph.size[0] * scale, y + glyph.size[1] * scale }, origin, cos_r, sin_r);
    const p3 = rotatePoint(.{ x, y + glyph.size[1] * scale }, origin, cos_r, sin_r);
    blitGlyphQuad(target, font, glyph, .{ p0, p1, p2, p3 }, color, clip);
}

fn rotatePoint(point: [2]f32, origin: [2]f32, cos_r: f32, sin_r: f32) [2]f32 {
    const dx = point[0] - origin[0];
    const dy = point[1] - origin[1];
    return .{
        origin[0] + dx * cos_r - dy * sin_r,
        origin[1] + dx * sin_r + dy * cos_r,
    };
}

const PixelClip = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

fn blitGlyphClipped(target: *Image, font: TextAtlasFont, glyph: TextAtlasGlyph, x: f32, y: f32, scale: f32, color: [4]f32, clip: ?PixelClip) void {
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
        if (clip) |clip_rect| {
            if (py < clip_rect.y0 or py >= clip_rect.y1) continue;
        }
        const sample_y = @as(f32, @floatFromInt(src_y0)) + (@as(f32, @floatFromInt(dy)) + 0.5) * @as(f32, @floatFromInt(src_y1 - src_y0)) / @as(f32, @floatFromInt(dst_h)) - 0.5;
        var dx: i32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const px = @as(i32, @intFromFloat(@floor(x))) + dx;
            if (px < 0 or px >= @as(i32, @intCast(target.width))) continue;
            if (clip) |clip_rect| {
                if (px < clip_rect.x0 or px >= clip_rect.x1) continue;
            }
            const sample_x = @as(f32, @floatFromInt(src_x0)) + (@as(f32, @floatFromInt(dx)) + 0.5) * @as(f32, @floatFromInt(src_x1 - src_x0)) / @as(f32, @floatFromInt(dst_w)) - 0.5;
            const glyph_alpha = sampleAtlasBilinear(font, sample_x, sample_y);
            if (glyph_alpha == 0) continue;
            const alpha: u8 = @intCast((@as(u16, glyph_alpha) * @as(u16, color_alpha)) / 255);
            target.blendPixel(@intCast(px), @intCast(py), Color.rgba(red, green, blue, alpha));
        }
    }
}

fn blitGlyphQuad(target: *Image, font: TextAtlasFont, glyph: TextAtlasGlyph, quad: [4][2]f32, color: [4]f32, clip: ?PixelClip) void {
    if (glyph.size[0] <= 0.0 or glyph.size[1] <= 0.0) return;
    const src_x0: u32 = @intFromFloat(@floor(glyph.uv0[0] * @as(f32, @floatFromInt(font.atlas_w))));
    const src_y0: u32 = @intFromFloat(@floor(glyph.uv0[1] * @as(f32, @floatFromInt(font.atlas_h))));
    const src_x1: u32 = @intFromFloat(@ceil(glyph.uv1[0] * @as(f32, @floatFromInt(font.atlas_w))));
    const src_y1: u32 = @intFromFloat(@ceil(glyph.uv1[1] * @as(f32, @floatFromInt(font.atlas_h))));
    if (src_x1 <= src_x0 or src_y1 <= src_y0) return;
    const red = toByte(color[0]);
    const green = toByte(color[1]);
    const blue = toByte(color[2]);
    const color_alpha = toByte(color[3]);
    const min_x = @min(@min(quad[0][0], quad[1][0]), @min(quad[2][0], quad[3][0]));
    const min_y = @min(@min(quad[0][1], quad[1][1]), @min(quad[2][1], quad[3][1]));
    const max_x = @max(@max(quad[0][0], quad[1][0]), @max(quad[2][0], quad[3][0]));
    const max_y = @max(@max(quad[0][1], quad[1][1]), @max(quad[2][1], quad[3][1]));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    var x0: i32 = @intFromFloat(@floor(min_x));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    if (clip) |clip_rect| {
        x0 = @max(x0, clip_rect.x0);
        y0 = @max(y0, clip_rect.y0);
        x1 = @min(x1, clip_rect.x1);
        y1 = @min(y1, clip_rect.y1);
    }
    x0 = @max(x0, 0);
    y0 = @max(y0, 0);
    x1 = @min(x1, @as(i32, @intCast(target.width)));
    y1 = @min(y1, @as(i32, @intCast(target.height)));
    if (x1 <= x0 or y1 <= y0) return;

    const edge_x = .{ quad[1][0] - quad[0][0], quad[1][1] - quad[0][1] };
    const edge_y = .{ quad[3][0] - quad[0][0], quad[3][1] - quad[0][1] };
    const det = edge_x[0] * edge_y[1] - edge_x[1] * edge_y[0];
    if (@abs(det) <= 0.000001) return;
    const inv_det = 1.0 / det;

    var py = y0;
    while (py < y1) : (py += 1) {
        var px = x0;
        while (px < x1) : (px += 1) {
            const rel_x = @as(f32, @floatFromInt(px)) + 0.5 - quad[0][0];
            const rel_y = @as(f32, @floatFromInt(py)) + 0.5 - quad[0][1];
            const u = (rel_x * edge_y[1] - rel_y * edge_y[0]) * inv_det;
            const v = (edge_x[0] * rel_y - edge_x[1] * rel_x) * inv_det;
            if (u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0) continue;
            const sample_x = @as(f32, @floatFromInt(src_x0)) + u * @as(f32, @floatFromInt(src_x1 - src_x0)) - 0.5;
            const sample_y = @as(f32, @floatFromInt(src_y0)) + v * @as(f32, @floatFromInt(src_y1 - src_y0)) - 0.5;
            const glyph_alpha = sampleAtlasBilinear(font, sample_x, sample_y);
            if (glyph_alpha == 0) continue;
            const alpha: u8 = @intCast((@as(u16, glyph_alpha) * @as(u16, color_alpha)) / 255);
            target.blendPixel(@intCast(px), @intCast(py), Color.rgba(red, green, blue, alpha));
        }
    }
}

fn sampleAtlasBilinear(font: TextAtlasFont, x: f32, y: f32) u8 {
    const max_x = @as(f32, @floatFromInt(@max(font.atlas_w, 1) - 1));
    const max_y = @as(f32, @floatFromInt(@max(font.atlas_h, 1) - 1));
    const fx = std.math.clamp(x, 0.0, max_x);
    const fy = std.math.clamp(y, 0.0, max_y);
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, font.atlas_w - 1);
    const y1 = @min(y0 + 1, font.atlas_h - 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));
    const a00: f32 = @floatFromInt(font.atlas_pixels[@as(usize, y0) * font.atlas_w + x0]);
    const a10: f32 = @floatFromInt(font.atlas_pixels[@as(usize, y0) * font.atlas_w + x1]);
    const a01: f32 = @floatFromInt(font.atlas_pixels[@as(usize, y1) * font.atlas_w + x0]);
    const a11: f32 = @floatFromInt(font.atlas_pixels[@as(usize, y1) * font.atlas_w + x1]);
    const top = a00 + (a10 - a00) * tx;
    const bottom = a01 + (a11 - a01) * tx;
    return @intFromFloat(@round(std.math.clamp(top + (bottom - top) * ty, 0.0, 255.0)));
}

fn scaledClipRect(clip: ?window.Rect, scale: f32) ?PixelClip {
    const rect = clip orelse return null;
    const s = @max(0.25, scale);
    return .{
        .x0 = @intFromFloat(@floor(rect.x * s)),
        .y0 = @intFromFloat(@floor(rect.y * s)),
        .x1 = @intFromFloat(@ceil((rect.x + rect.w) * s)),
        .y1 = @intFromFloat(@ceil((rect.y + rect.h) * s)),
    };
}

fn drawPaintQuad(target: *Image, quad: window.PaintQuad, scale: f32, clip: ?window.Rect) void {
    if (quad.rect.w <= 0.0 or quad.rect.h <= 0.0) return;
    const s = @max(0.25, scale);
    const rect = window.Rect{
        .x = quad.rect.x * s,
        .y = quad.rect.y * s,
        .w = quad.rect.w * s,
        .h = quad.rect.h * s,
    };
    const radius = @min(@max(0.0, quad.radius * s), @min(rect.w, rect.h) * 0.5);
    const border_width = @max(0.0, quad.border_width * s);
    const clip_px = scaledClipRect(clip, s);
    const rect_x0: i32 = @intFromFloat(@floor(rect.x - 1.0));
    const rect_y0: i32 = @intFromFloat(@floor(rect.y - 1.0));
    const rect_x1: i32 = @intFromFloat(@ceil(rect.x + rect.w + 1.0));
    const rect_y1: i32 = @intFromFloat(@ceil(rect.y + rect.h + 1.0));
    const x0 = @max(0, if (clip_px) |c| @max(rect_x0, c.x0) else rect_x0);
    const y0 = @max(0, if (clip_px) |c| @max(rect_y0, c.y0) else rect_y0);
    const x1 = @min(@as(i32, @intCast(target.width)), if (clip_px) |c| @min(rect_x1, c.x1) else rect_x1);
    const y1 = @min(@as(i32, @intCast(target.height)), if (clip_px) |c| @min(rect_y1, c.y1) else rect_y1);
    if (x1 <= x0 or y1 <= y0) return;

    const background = toColor(quad.background);
    const border = toColor(quad.border_color);
    const aa: f32 = 0.75;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = roundedRectSdf(px, py, rect, radius);
            const outer_alpha = 1.0 - smoothstep(-aa, aa, d);
            if (outer_alpha <= 0.0) continue;

            var color = background;
            if (border_width > 0.0 and border.a > 0) {
                const inner_sdf = -(d + border_width);
                const border_sdf = @max(inner_sdf, d);
                if (border_sdf < aa) {
                    const blended = blendBorderOverBackground(border, background);
                    color = mixColor(background, blended, 1.0 - smoothstep(-aa, aa, inner_sdf));
                }
            }
            target.blendPixel(@intCast(x), @intCast(y), color.withAlphaScale(outer_alpha));
        }
    }
}

fn roundedRectSdf(px: f32, py: f32, rect: window.Rect, radius: f32) f32 {
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

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn blendBorderOverBackground(border: Color, background: Color) Color {
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

fn mixColor(a: Color, b: Color, t: f32) Color {
    return Color.rgba(
        mixByte(a.r, b.r, t),
        mixByte(a.g, b.g, t),
        mixByte(a.b, b.b, t),
        mixByte(a.a, b.a, t),
    );
}

fn mixByte(a: u8, b: u8, t: f32) u8 {
    const value = @as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * std.math.clamp(t, 0.0, 1.0);
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 255.0)));
}

fn sampleGlyphAlpha(font: TextAtlasFont, src_x: u32, src_y: u32, src_w: u32, src_h: u32, dst_x: i32, dst_y: i32, dst_w: i32, dst_h: i32) u8 {
    if (src_w == 0 or src_h == 0 or dst_w <= 0 or dst_h <= 0) return 0;
    const src_w_f: f32 = @floatFromInt(src_w);
    const src_h_f: f32 = @floatFromInt(src_h);
    const dst_w_f: f32 = @floatFromInt(dst_w);
    const dst_h_f: f32 = @floatFromInt(dst_h);
    const x0 = @as(f32, @floatFromInt(dst_x)) * src_w_f / dst_w_f;
    const x1 = @as(f32, @floatFromInt(dst_x + 1)) * src_w_f / dst_w_f;
    const y0 = @as(f32, @floatFromInt(dst_y)) * src_h_f / dst_h_f;
    const y1 = @as(f32, @floatFromInt(dst_y + 1)) * src_h_f / dst_h_f;

    const ix0: i32 = @intFromFloat(@floor(x0));
    const ix1: i32 = @intFromFloat(@ceil(x1));
    const iy0: i32 = @intFromFloat(@floor(y0));
    const iy1: i32 = @intFromFloat(@ceil(y1));

    var weighted_sum: f32 = 0.0;
    var area_sum: f32 = 0.0;
    var sy = iy0;
    while (sy < iy1) : (sy += 1) {
        if (sy < 0 or sy >= @as(i32, @intCast(src_h))) continue;
        const py0 = @max(y0, @as(f32, @floatFromInt(sy)));
        const py1 = @min(y1, @as(f32, @floatFromInt(sy + 1)));
        const wy = py1 - py0;
        if (wy <= 0.0) continue;
        var sx = ix0;
        while (sx < ix1) : (sx += 1) {
            if (sx < 0 or sx >= @as(i32, @intCast(src_w))) continue;
            const px0 = @max(x0, @as(f32, @floatFromInt(sx)));
            const px1 = @min(x1, @as(f32, @floatFromInt(sx + 1)));
            const wx = px1 - px0;
            if (wx <= 0.0) continue;
            const area = wx * wy;
            const atlas_x: u32 = src_x + @as(u32, @intCast(sx));
            const atlas_y: u32 = src_y + @as(u32, @intCast(sy));
            const alpha = font.atlas_pixels[@as(usize, atlas_y) * font.atlas_w + atlas_x];
            weighted_sum += @as(f32, @floatFromInt(alpha)) * area;
            area_sum += area;
        }
    }
    if (area_sum <= 0.0) return 0;
    return @intFromFloat(@round(std.math.clamp(weighted_sum / area_sum, 0.0, 255.0)));
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

fn strokeScenePath(dst: *scene2d.Scene2D, path: *const scene2d.Path, style: window.StrokeStyle, color: Color) !void {
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

test "window text drawing respects clip rectangles" {
    var pixels = [_]u8{
        255, 255,
        255, 255,
    };
    const font = TextAtlasFont{
        .size_px = 1,
        .ascent = 1,
        .descent = 0,
        .line_gap = 0,
        .atlas_w = 2,
        .atlas_h = 2,
        .atlas_pixels = &pixels,
    };
    const glyph = TextAtlasGlyph{
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 1, 1 },
        .size = .{ 4, 4 },
        .bearing = .{ 0, 0 },
        .advance = 4,
    };
    const Provider = struct {
        fn defaultFontIndexFn(_: *anyopaque) ?usize {
            return 0;
        }
        fn fontCountFn(_: *anyopaque) usize {
            return 1;
        }
        fn fontFn(_: *anyopaque, index: usize) ?TextAtlasFont {
            return if (index == 0) font else null;
        }
        fn resolveGlyphFn(_: *anyopaque, _: usize, _: u21) ?ResolvedGlyph {
            return .{ .font_index = 0, .glyph = glyph };
        }
    };
    const provider = TextAtlasProvider{
        .context = undefined,
        .defaultFontIndexFn = Provider.defaultFontIndexFn,
        .fontCountFn = Provider.fontCountFn,
        .fontFn = Provider.fontFn,
        .resolveGlyphFn = Provider.resolveGlyphFn,
    };
    var image = try Image.init(std.testing.allocator, 6, 6, .transparent);
    defer image.deinit();

    const cmds = [_]window.DrawCmd{
        .{ .clip_begin = .{ .x = 0, .y = 0, .w = 2, .h = 2 } },
        .{ .text = .{ .pos = .{ 0, 0 }, .size = 4, .color = .{ 1, 1, 1, 1 }, .text = "A", .font_id = null, .layer = 0 } },
        .{ .clip_end = {} },
    };
    drawTextCommandsWithProviderScaled(&cmds, &image, provider, 1.0);

    try std.testing.expect(image.pixel(1, 1).?.a > 0);
    try std.testing.expectEqual(Color.transparent, image.pixel(3, 1).?);
    try std.testing.expectEqual(Color.transparent, image.pixel(1, 3).?);

    var nested = try Image.init(std.testing.allocator, 6, 6, .transparent);
    defer nested.deinit();
    const nested_cmds = [_]window.DrawCmd{
        .{ .clip_begin = .{ .x = 0, .y = 0, .w = 4, .h = 4 } },
        .{ .clip_begin = .{ .x = 1, .y = 1, .w = 2, .h = 2 } },
        .{ .text = .{ .pos = .{ 0, 0 }, .size = 4, .color = .{ 1, 1, 1, 1 }, .text = "A", .font_id = null, .layer = 0 } },
        .{ .clip_end = {} },
        .{ .text = .{ .pos = .{ 0, 0 }, .size = 4, .color = .{ 1, 1, 1, 1 }, .text = "A", .font_id = null, .layer = 0 } },
        .{ .clip_end = {} },
    };
    drawTextCommandsWithProviderScaled(&nested_cmds, &nested, provider, 1.0);
    try std.testing.expect(nested.pixel(1, 1).?.a > 0);
    try std.testing.expect(nested.pixel(3, 3).?.a > 0);
    try std.testing.expectEqual(Color.transparent, nested.pixel(5, 1).?);
}

test "window text drawing bilinear samples atlas coverage" {
    var pixels = [_]u8{
        0,   255,
        255, 255,
    };
    const font = TextAtlasFont{
        .size_px = 1,
        .ascent = 1,
        .descent = 0,
        .line_gap = 0,
        .atlas_w = 2,
        .atlas_h = 2,
        .atlas_pixels = &pixels,
    };
    const glyph = TextAtlasGlyph{
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 1, 1 },
        .size = .{ 1, 1 },
        .bearing = .{ 0, 0 },
        .advance = 1,
    };
    var image = try Image.init(std.testing.allocator, 1, 1, .transparent);
    defer image.deinit();

    blitGlyph(&image, font, glyph, 0, 0, 1.0, .{ 1, 1, 1, 1 });
    const alpha = image.pixel(0, 0).?.a;
    try std.testing.expect(alpha > 180 and alpha < 200);
}

test "window text drawing applies rotation around command origin" {
    var pixels = [_]u8{
        255, 255,
        255, 255,
    };
    const font = TextAtlasFont{
        .size_px = 1,
        .ascent = 1,
        .descent = 0,
        .line_gap = 0,
        .atlas_w = 2,
        .atlas_h = 2,
        .atlas_pixels = &pixels,
    };
    const glyph = TextAtlasGlyph{
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 1, 1 },
        .size = .{ 4, 2 },
        .bearing = .{ 0, 0 },
        .advance = 4,
    };
    const Provider = struct {
        fn defaultFontIndexFn(_: *anyopaque) ?usize {
            return 0;
        }
        fn fontCountFn(_: *anyopaque) usize {
            return 1;
        }
        fn fontFn(_: *anyopaque, index: usize) ?TextAtlasFont {
            return if (index == 0) font else null;
        }
        fn resolveGlyphFn(_: *anyopaque, _: usize, _: u21) ?ResolvedGlyph {
            return .{ .font_index = 0, .glyph = glyph };
        }
    };
    const provider = TextAtlasProvider{
        .context = undefined,
        .defaultFontIndexFn = Provider.defaultFontIndexFn,
        .fontCountFn = Provider.fontCountFn,
        .fontFn = Provider.fontFn,
        .resolveGlyphFn = Provider.resolveGlyphFn,
    };
    var image = try Image.init(std.testing.allocator, 10, 10, .transparent);
    defer image.deinit();

    const cmds = [_]window.DrawCmd{.{ .text = .{
        .pos = .{ 6, 2 },
        .size = 4,
        .color = .{ 1, 1, 1, 1 },
        .text = "A",
        .font_id = null,
        .rotation = std.math.pi / 2.0,
        .layer = 0,
    } }};
    drawTextCommandsWithProviderScaled(&cmds, &image, provider, 1.0);

    try std.testing.expect(image.pixel(5, 4).?.a > 0);
    try std.testing.expectEqual(Color.transparent, image.pixel(8, 2).?);
}

test "window CPU paint quad uses anti-aliased rounded SDF" {
    var image = try Image.init(std.testing.allocator, 8, 8, .transparent);
    defer image.deinit();

    drawPaintQuad(&image, .{
        .rect = .{ .x = 1, .y = 1, .w = 6, .h = 6 },
        .radius = 2,
        .background = .{ 1, 0, 0, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .border_width = 0,
    }, 1.0, null);

    try std.testing.expect(image.pixel(4, 4).?.a == 255);
    const corner_alpha = image.pixel(1, 1).?.a;
    try std.testing.expect(corner_alpha > 0 and corner_alpha < 255);
    try std.testing.expectEqual(Color.transparent, image.pixel(0, 0).?);
}

test "window CPU paint quad clips to intersection with quad bounds" {
    var image = try Image.init(std.testing.allocator, 12, 12, .transparent);
    defer image.deinit();

    drawPaintQuad(&image, .{
        .rect = .{ .x = 2, .y = 2, .w = 4, .h = 4 },
        .radius = 0,
        .background = .{ 1, 0, 0, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .border_width = 0,
    }, 1.0, .{ .x = 4, .y = 4, .w = 6, .h = 6 });

    try std.testing.expectEqual(Color.transparent, image.pixel(3, 3).?);
    try std.testing.expect(image.pixel(4, 4).?.a > 0);
    try std.testing.expectEqual(Color.transparent, image.pixel(8, 8).?);
}

test "window draw image provider applies tint in CPU scene path" {
    var source = try Image.init(std.testing.allocator, 1, 1, .transparent);
    defer source.deinit();
    source.writePixel(0, 0, Color.rgba(200, 100, 50, 255));

    const Provider = struct {
        var image: *Image = undefined;
        fn imageFn(_: *anyopaque, image_id: window.ImageId) ?Image {
            return if (image_id == 7) image.* else null;
        }
    };
    Provider.image = &source;
    const provider = ImageProvider{ .context = undefined, .imageFn = Provider.imageFn };

    var scene = scene2d.Scene2D.init(std.testing.allocator);
    defer scene.deinit();
    const cmds = [_]window.DrawCmd{.{ .image = .{
        .image_id = 7,
        .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .tint = .{ 0.5, 0.25, 1.0, 0.5 },
        .layer = 0,
    } }};
    try appendDrawListToSceneWithImages(&cmds, &scene, provider);

    var out = try Image.init(std.testing.allocator, 1, 1, .transparent);
    defer out.deinit();
    var renderer = cpu.CpuRenderer.init(std.testing.allocator);
    try renderer.render2D(&scene, &out);

    const px = out.pixel(0, 0).?;
    try std.testing.expect(px.r >= 95 and px.r <= 105);
    try std.testing.expect(px.g >= 20 and px.g <= 30);
    try std.testing.expect(px.b >= 45 and px.b <= 55);
    try std.testing.expect(px.a >= 120 and px.a <= 130);
}

test "window_draw baseline origin shifts text blit to top-left" {
    var image = try Image.init(std.testing.allocator, 24, 24, .transparent);
    defer image.deinit();

    const atlas_pixels = [_]u8{255};
    const fonts = [_]TextAtlasFont{.{
        .size_px = 10,
        .ascent = 8,
        .descent = 2,
        .line_gap = 0,
        .atlas_w = 1,
        .atlas_h = 1,
        .atlas_pixels = &atlas_pixels,
    }};
    const draw_list = [_]window.DrawCmd{.{ .text = .{
        .pos = .{ 4, 14 },
        .size = 10,
        .color = .{ 1, 1, 1, 1 },
        .text = "A",
        .font_id = 0,
        .origin = .baseline,
        .baseline = 8,
        .layer = 0,
    } }};

    drawTextCommands(&draw_list, &image, &fonts, 0, undefined, resolveUnitGlyph);

    try std.testing.expectEqual(Color.rgba(255, 255, 255, 255), image.pixel(4, 6).?);
    try std.testing.expectEqual(Color.transparent, image.pixel(4, 14).?);
}

fn resolveUnitGlyph(_: *anyopaque, _: usize, _: u21) ?ResolvedGlyph {
    return .{
        .font_index = 0,
        .glyph = .{
            .uv0 = .{ 0, 0 },
            .uv1 = .{ 1, 1 },
            .size = .{ 1, 1 },
            .bearing = .{ 0, 0 },
            .advance = 1,
        },
    };
}
