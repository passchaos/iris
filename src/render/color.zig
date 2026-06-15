const std = @import("std");

pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const blue: Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn over(src: Color, dst: Color) Color {
        if (src.a == 255) return src;
        if (src.a == 0) return dst;

        const sa: u32 = src.a;
        const inv_sa: u32 = 255 - sa;
        const out_a: u32 = sa + (@as(u32, dst.a) * inv_sa + 127) / 255;
        if (out_a == 0) return .transparent;

        const src_a: u32 = src.a;
        const dst_a: u32 = dst.a;
        const dst_factor = (dst_a * inv_sa + 127) / 255;
        return .{
            .r = unpremultiply((@as(u32, src.r) * src_a + 127) / 255 + (@as(u32, dst.r) * dst_factor + 127) / 255, out_a),
            .g = unpremultiply((@as(u32, src.g) * src_a + 127) / 255 + (@as(u32, dst.g) * dst_factor + 127) / 255, out_a),
            .b = unpremultiply((@as(u32, src.b) * src_a + 127) / 255 + (@as(u32, dst.b) * dst_factor + 127) / 255, out_a),
            .a = @intCast(out_a),
        };
    }

    pub fn toRgba32(self: Color) u32 {
        return @as(u32, self.r) |
            (@as(u32, self.g) << 8) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.a) << 24);
    }

    pub fn fromRgba32(value: u32) Color {
        return .{
            .r = @intCast(value & 0xff),
            .g = @intCast((value >> 8) & 0xff),
            .b = @intCast((value >> 16) & 0xff),
            .a = @intCast((value >> 24) & 0xff),
        };
    }

    pub fn lerp(a: Color, b: Color, t: f32) Color {
        const clamped = @min(1.0, @max(0.0, t));
        return .{
            .r = lerpChannel(a.r, b.r, clamped),
            .g = lerpChannel(a.g, b.g, clamped),
            .b = lerpChannel(a.b, b.b, clamped),
            .a = lerpChannel(a.a, b.a, clamped),
        };
    }

    pub fn lerpLinearRgb(a: Color, b: Color, t: f32) Color {
        const clamped = @min(1.0, @max(0.0, t));
        return .{
            .r = linearToSrgbChannel(lerpFloat(srgbToLinear(a.r), srgbToLinear(b.r), clamped)),
            .g = linearToSrgbChannel(lerpFloat(srgbToLinear(a.g), srgbToLinear(b.g), clamped)),
            .b = linearToSrgbChannel(lerpFloat(srgbToLinear(a.b), srgbToLinear(b.b), clamped)),
            .a = lerpChannel(a.a, b.a, clamped),
        };
    }

    pub fn withAlphaScale(self: Color, coverage: f32) Color {
        const clamped = @min(1.0, @max(0.0, coverage));
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = @intFromFloat(@round(@as(f32, @floatFromInt(self.a)) * clamped)),
        };
    }
};

fn lerpChannel(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

fn lerpFloat(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn srgbToLinear(channel: u8) f32 {
    const c = @as(f32, @floatFromInt(channel)) / 255.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn linearToSrgbChannel(value: f32) u8 {
    const c = @min(1.0, @max(0.0, value));
    const srgb = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(srgb * 255.0));
}

pub const BlendMode = enum(u8) {
    source_over = 0,
    copy = 1,
    add = 2,
    multiply = 3,
    clear = 4,
    source = 5,
    destination = 6,
    destination_over = 7,
    source_in = 8,
    destination_in = 9,
    source_out = 10,
    destination_out = 11,
    source_atop = 12,
    destination_atop = 13,
    xor = 14,
    screen = 15,
    overlay = 16,
    darken = 17,
    lighten = 18,
    hard_light = 19,
    difference = 20,
    exclusion = 21,
    color_dodge = 22,
    color_burn = 23,
    soft_light = 24,
    hue = 25,
    saturation = 26,
    color = 27,
    luminosity = 28,
};

pub fn blend(src: Color, dst: Color, mode: BlendMode) Color {
    return switch (mode) {
        .source_over => src.over(dst),
        .copy, .source => src,
        .add => blendPremultiplied(src, dst, plusChannel),
        .multiply => blendPremultiplied(src, dst, multiplyChannel),
        .clear => .transparent,
        .destination => dst,
        .destination_over => dst.over(src),
        .source_in => .{
            .r = src.r,
            .g = src.g,
            .b = src.b,
            .a = scaleChannel(src.a, dst.a),
        },
        .destination_in => .{
            .r = dst.r,
            .g = dst.g,
            .b = dst.b,
            .a = scaleChannel(dst.a, src.a),
        },
        .source_out => .{
            .r = src.r,
            .g = src.g,
            .b = src.b,
            .a = scaleChannel(src.a, 255 - dst.a),
        },
        .destination_out => .{
            .r = dst.r,
            .g = dst.g,
            .b = dst.b,
            .a = scaleChannel(dst.a, 255 - src.a),
        },
        .source_atop => blendPremultipliedPorterDuff(src, dst, .source_atop),
        .destination_atop => blendPremultipliedPorterDuff(src, dst, .destination_atop),
        .xor => blendPremultipliedPorterDuff(src, dst, .xor),
        .screen => blendPremultiplied(src, dst, screenChannel),
        .overlay => blendPremultiplied(src, dst, overlayChannel),
        .darken => blendPremultiplied(src, dst, darkenChannel),
        .lighten => blendPremultiplied(src, dst, lightenChannel),
        .hard_light => blendPremultiplied(src, dst, hardLightChannel),
        .difference => blendPremultiplied(src, dst, differenceChannel),
        .exclusion => blendPremultiplied(src, dst, exclusionChannel),
        .color_dodge => blendPremultiplied(src, dst, colorDodgeChannel),
        .color_burn => blendPremultiplied(src, dst, colorBurnChannel),
        .soft_light => blendPremultiplied(src, dst, softLightChannel),
        .hue => blendPremultipliedColor(src, dst, hueColor),
        .saturation => blendPremultipliedColor(src, dst, saturationColor),
        .color => blendPremultipliedColor(src, dst, colorBlendColor),
        .luminosity => blendPremultipliedColor(src, dst, luminosityColor),
    };
}

fn scaleChannel(value: u8, alpha: u8) u8 {
    return @intCast((@as(u16, value) * alpha + 127) / 255);
}

fn unpremultiply(channel: u32, alpha: u32) u8 {
    if (alpha == 0) return 0;
    return @intCast(@min(255, (channel * 255 + alpha / 2) / alpha));
}

fn premultiply(channel: u8, alpha: u8) u32 {
    return (@as(u32, channel) * alpha + 127) / 255;
}

fn blendPremultiplied(src: Color, dst: Color, comptime blendChannel: fn (u8, u8) u8) Color {
    const sa: u32 = src.a;
    const da: u32 = dst.a;
    const out_a = sa + da - (sa * da + 127) / 255;
    if (out_a == 0) return .transparent;

    const channels = [_]struct { src: u8, dst: u8 }{
        .{ .src = src.r, .dst = dst.r },
        .{ .src = src.g, .dst = dst.g },
        .{ .src = src.b, .dst = dst.b },
    };
    var out: [3]u8 = undefined;
    for (channels, 0..) |channel, i| {
        const sca = premultiply(channel.src, src.a);
        const dca = premultiply(channel.dst, dst.a);
        const blended = premultiply(blendChannel(channel.src, channel.dst), @intCast((sa * da + 127) / 255));
        const premul = blended +
            (sca * (255 - da) + 127) / 255 +
            (dca * (255 - sa) + 127) / 255;
        out[i] = unpremultiply(@min(255, premul), out_a);
    }

    return .{ .r = out[0], .g = out[1], .b = out[2], .a = @intCast(out_a) };
}

fn blendPremultipliedColor(src: Color, dst: Color, comptime blendColor: fn (Color, Color) Color) Color {
    const sa: u32 = src.a;
    const da: u32 = dst.a;
    const out_a = sa + da - (sa * da + 127) / 255;
    if (out_a == 0) return .transparent;

    const blended = blendColor(src, dst);
    const channels = [_]struct { src: u8, dst: u8, blend: u8 }{
        .{ .src = src.r, .dst = dst.r, .blend = blended.r },
        .{ .src = src.g, .dst = dst.g, .blend = blended.g },
        .{ .src = src.b, .dst = dst.b, .blend = blended.b },
    };
    var out: [3]u8 = undefined;
    for (channels, 0..) |channel, i| {
        const sca = premultiply(channel.src, src.a);
        const dca = premultiply(channel.dst, dst.a);
        const blended_premul = premultiply(channel.blend, @intCast((sa * da + 127) / 255));
        const premul = blended_premul +
            (sca * (255 - da) + 127) / 255 +
            (dca * (255 - sa) + 127) / 255;
        out[i] = unpremultiply(@min(255, premul), out_a);
    }

    return .{ .r = out[0], .g = out[1], .b = out[2], .a = @intCast(out_a) };
}

const PorterDuffMode = enum {
    source_atop,
    destination_atop,
    xor,
};

fn blendPremultipliedPorterDuff(src: Color, dst: Color, mode: PorterDuffMode) Color {
    const sa: u32 = src.a;
    const da: u32 = dst.a;
    const out_a = switch (mode) {
        .source_atop => da,
        .destination_atop => sa,
        .xor => ((sa * (255 - da) + 127) + (da * (255 - sa) + 127)) / 255,
    };
    if (out_a == 0) return .transparent;

    const channels = [_]struct { src: u8, dst: u8 }{
        .{ .src = src.r, .dst = dst.r },
        .{ .src = src.g, .dst = dst.g },
        .{ .src = src.b, .dst = dst.b },
    };
    var out: [3]u8 = undefined;
    for (channels, 0..) |channel, i| {
        const sca = premultiply(channel.src, src.a);
        const dca = premultiply(channel.dst, dst.a);
        const premul = switch (mode) {
            .source_atop => (sca * da + 127) / 255 + (dca * (255 - sa) + 127) / 255,
            .destination_atop => (dca * sa + 127) / 255 + (sca * (255 - da) + 127) / 255,
            .xor => (sca * (255 - da) + 127) / 255 + (dca * (255 - sa) + 127) / 255,
        };
        out[i] = unpremultiply(@min(255, premul), out_a);
    }
    return .{ .r = out[0], .g = out[1], .b = out[2], .a = @intCast(out_a) };
}

fn plusChannel(src: u8, dst: u8) u8 {
    return @intCast(@min(255, @as(u16, src) + dst));
}

fn multiplyChannel(src: u8, dst: u8) u8 {
    return @intCast((@as(u16, src) * dst + 127) / 255);
}

fn screenChannel(src: u8, dst: u8) u8 {
    return @intCast(255 - ((@as(u16, 255 - src) * (255 - dst) + 127) / 255));
}

fn overlayChannel(src: u8, dst: u8) u8 {
    return if (dst <= 127)
        @intCast((2 * @as(u16, src) * dst + 127) / 255)
    else
        @intCast(255 - (2 * @as(u16, 255 - src) * (255 - dst) + 127) / 255);
}

fn hardLightChannel(src: u8, dst: u8) u8 {
    return overlayChannel(dst, src);
}

fn darkenChannel(src: u8, dst: u8) u8 {
    return @min(src, dst);
}

fn lightenChannel(src: u8, dst: u8) u8 {
    return @max(src, dst);
}

fn differenceChannel(src: u8, dst: u8) u8 {
    return if (src > dst) src - dst else dst - src;
}

fn exclusionChannel(src: u8, dst: u8) u8 {
    return @intCast(@as(u16, src) + dst - (2 * @as(u16, src) * dst + 127) / 255);
}

fn colorDodgeChannel(src: u8, dst: u8) u8 {
    if (dst == 0) return 0;
    if (src == 255) return 255;
    return @intCast(@min(255, (@as(u16, dst) * 255 + @as(u16, 254 - src) / 2) / @as(u16, 255 - src)));
}

fn colorBurnChannel(src: u8, dst: u8) u8 {
    if (dst == 255) return 255;
    if (src == 0) return 0;
    const burned = @min(255, (@as(u16, 255 - dst) * 255 + @as(u16, src) / 2) / src);
    return @intCast(255 - burned);
}

fn softLightChannel(src: u8, dst: u8) u8 {
    const s = @as(f32, @floatFromInt(src)) / 255.0;
    const d = @as(f32, @floatFromInt(dst)) / 255.0;
    const out = if (s <= 0.5)
        d - (1.0 - 2.0 * s) * d * (1.0 - d)
    else blk: {
        const g = if (d <= 0.25)
            ((16.0 * d - 12.0) * d + 4.0) * d
        else
            @sqrt(d);
        break :blk d + (2.0 * s - 1.0) * (g - d);
    };
    return @intFromFloat(@round(@min(1.0, @max(0.0, out)) * 255.0));
}

const RgbF = struct {
    r: f32,
    g: f32,
    b: f32,
};

fn colorToRgbF(c: Color) RgbF {
    return .{
        .r = @as(f32, @floatFromInt(c.r)) / 255.0,
        .g = @as(f32, @floatFromInt(c.g)) / 255.0,
        .b = @as(f32, @floatFromInt(c.b)) / 255.0,
    };
}

fn rgbFToColor(c: RgbF) Color {
    return .{
        .r = @intFromFloat(@round(@min(1.0, @max(0.0, c.r)) * 255.0)),
        .g = @intFromFloat(@round(@min(1.0, @max(0.0, c.g)) * 255.0)),
        .b = @intFromFloat(@round(@min(1.0, @max(0.0, c.b)) * 255.0)),
        .a = 255,
    };
}

fn hueColor(src: Color, dst: Color) Color {
    return rgbFToColor(setLum(setSat(colorToRgbF(src), sat(colorToRgbF(dst))), lum(colorToRgbF(dst))));
}

fn saturationColor(src: Color, dst: Color) Color {
    return rgbFToColor(setLum(setSat(colorToRgbF(dst), sat(colorToRgbF(src))), lum(colorToRgbF(dst))));
}

fn colorBlendColor(src: Color, dst: Color) Color {
    return rgbFToColor(setLum(colorToRgbF(src), lum(colorToRgbF(dst))));
}

fn luminosityColor(src: Color, dst: Color) Color {
    return rgbFToColor(setLum(colorToRgbF(dst), lum(colorToRgbF(src))));
}

fn lum(c: RgbF) f32 {
    return c.r * 0.3 + c.g * 0.59 + c.b * 0.11;
}

fn sat(c: RgbF) f32 {
    return @max(c.r, @max(c.g, c.b)) - @min(c.r, @min(c.g, c.b));
}

fn clipColor(c: RgbF) RgbF {
    const l = lum(c);
    const n = @min(c.r, @min(c.g, c.b));
    const x = @max(c.r, @max(c.g, c.b));
    var out = c;
    if (n < 0.0) {
        const t = l - n;
        out = if (t == 0.0) RgbF{ .r = 0, .g = 0, .b = 0 } else .{
            .r = l + (out.r - l) * l / t,
            .g = l + (out.g - l) * l / t,
            .b = l + (out.b - l) * l / t,
        };
    }
    if (x > 1.0) {
        const t = x - l;
        out = if (t == 0.0) RgbF{ .r = 0, .g = 0, .b = 0 } else .{
            .r = l + (out.r - l) * (1.0 - l) / t,
            .g = l + (out.g - l) * (1.0 - l) / t,
            .b = l + (out.b - l) * (1.0 - l) / t,
        };
    }
    return out;
}

fn setLum(c: RgbF, l: f32) RgbF {
    const d = l - lum(c);
    return clipColor(.{ .r = c.r + d, .g = c.g + d, .b = c.b + d });
}

fn setSat(c: RgbF, s: f32) RgbF {
    const n = @min(c.r, @min(c.g, c.b));
    const x = @max(c.r, @max(c.g, c.b));
    const d = x - n;
    if (d == 0.0) return .{ .r = 0, .g = 0, .b = 0 };
    return .{
        .r = (c.r - n) * s / d,
        .g = (c.g - n) * s / d,
        .b = (c.b - n) * s / d,
    };
}

test "alpha over blends source onto destination" {
    const out = Color.rgba(255, 0, 0, 128).over(.blue);
    try std.testing.expect(out.r > 120);
    try std.testing.expect(out.b > 120);
    try std.testing.expectEqual(@as(u8, 255), out.a);
}

test "blend modes cover copy add and multiply" {
    try std.testing.expectEqual(Color.red, blend(.red, .blue, .copy));
    try std.testing.expectEqual(Color.rgba(255, 0, 255, 255), blend(.red, .blue, .add));
    try std.testing.expectEqual(Color.black, blend(.red, .blue, .multiply));
}

test "porter duff blend modes cover destination and masks" {
    const src = Color.rgba(200, 40, 20, 128);
    const dst = Color.rgba(20, 80, 220, 192);

    try std.testing.expectEqual(Color.transparent, blend(src, dst, .clear));
    try std.testing.expectEqual(src, blend(src, dst, .source));
    try std.testing.expectEqual(dst, blend(src, dst, .destination));
    try std.testing.expectEqual(@as(u8, 96), blend(src, dst, .source_in).a);
    try std.testing.expectEqual(@as(u8, 96), blend(src, dst, .destination_in).a);
    try std.testing.expectEqual(@as(u8, 32), blend(src, dst, .source_out).a);
    try std.testing.expectEqual(@as(u8, 96), blend(src, dst, .destination_out).a);
    try std.testing.expectEqual(dst.a, blend(src, dst, .source_atop).a);
    try std.testing.expectEqual(src.a, blend(src, dst, .destination_atop).a);
    try std.testing.expectEqual(@as(u8, 128), blend(src, dst, .xor).a);
}

test "artistic blend modes cover screen overlay darken and difference" {
    const src = Color.rgba(200, 40, 20, 255);
    const dst = Color.rgba(20, 80, 220, 255);

    const screened = blend(src, dst, .screen);
    try std.testing.expect(screened.r > src.r);
    try std.testing.expect(screened.b > dst.b);

    const overlaid = blend(src, dst, .overlay);
    try std.testing.expect(overlaid.g < dst.g);
    try std.testing.expect(overlaid.b > src.b);

    try std.testing.expectEqual(Color.rgba(20, 40, 20, 255), blend(src, dst, .darken));
    try std.testing.expectEqual(Color.rgba(200, 80, 220, 255), blend(src, dst, .lighten));
    try std.testing.expectEqual(Color.rgba(180, 40, 200, 255), blend(src, dst, .difference));
    try std.testing.expectEqual(Color.rgba(189, 95, 205, 255), blend(src, dst, .exclusion));
    try std.testing.expectEqual(blend(dst, src, .overlay), blend(src, dst, .hard_light));
}

test "advanced artistic blend modes cover dodge burn and soft light" {
    const src = Color.rgba(200, 40, 20, 255);
    const dst = Color.rgba(20, 80, 220, 255);

    const dodged = blend(src, dst, .color_dodge);
    try std.testing.expect(dodged.r > dst.r);
    try std.testing.expect(dodged.g > dst.g);
    try std.testing.expectEqual(@as(u8, 239), dodged.b);

    const burned = blend(src, dst, .color_burn);
    try std.testing.expectEqual(@as(u8, 0), burned.r);
    try std.testing.expect(burned.g < dst.g);
    try std.testing.expect(burned.b < dst.b);

    const soft = blend(src, dst, .soft_light);
    try std.testing.expect(soft.r > dst.r);
    try std.testing.expect(soft.g < dst.g);
    try std.testing.expect(soft.b < dst.b);
}

test "non-separable blend modes cover hue saturation color and luminosity" {
    const src = Color.rgba(143, 128, 227, 255);
    const dst = Color.rgba(176, 59, 54, 255);

    try std.testing.expectEqual(Color.rgba(93, 75, 197, 255), blend(src, dst, .hue));
    try std.testing.expectEqual(Color.rgba(160, 66, 61, 255), blend(src, dst, .saturation));
    try std.testing.expectEqual(Color.rgba(93, 78, 177, 255), blend(src, dst, .color));
    try std.testing.expectEqual(Color.rgba(226, 109, 104, 255), blend(src, dst, .luminosity));
}

test "color lerp interpolates channels" {
    try std.testing.expectEqual(Color.rgba(128, 0, 128, 255), Color.lerp(.red, .blue, 0.5));
}

test "color linear rgb lerp is brighter than srgb midpoint" {
    const srgb = Color.lerp(.black, .white, 0.5);
    const linear = Color.lerpLinearRgb(.black, .white, 0.5);
    try std.testing.expect(linear.r > srgb.r);
    try std.testing.expectEqual(linear.r, linear.g);
    try std.testing.expectEqual(linear.g, linear.b);
}

test "rgba32 round trip preserves channels" {
    const value = Color.rgba(1, 2, 3, 4);
    try std.testing.expectEqual(value, Color.fromRgba32(value.toRgba32()));
}

test "alpha scale adjusts only alpha" {
    try std.testing.expectEqual(Color.rgba(10, 20, 30, 128), Color.rgba(10, 20, 30, 255).withAlphaScale(0.5));
}
