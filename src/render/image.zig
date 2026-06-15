const std = @import("std");
const color = @import("color.zig");
const Color = color.Color;
const BlendMode = color.BlendMode;
const crc32 = std.hash.Crc32;

pub const Image = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []Color,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, clear_color: Color) !Image {
        const len = try pixelCount(width, height);
        const pixels = try allocator.alloc(Color, len);
        @memset(pixels, clear_color);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn initFromPixels(allocator: std.mem.Allocator, width: u32, height: u32, source: []const Color) !Image {
        const len = try pixelCount(width, height);
        if (source.len < len) return error.ImageSourceTooSmall;
        const pixels = try allocator.dupe(Color, source[0..len]);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn initFromRgba32(allocator: std.mem.Allocator, width: u32, height: u32, source: []const u32) !Image {
        const len = try pixelCount(width, height);
        if (source.len < len) return error.ImageSourceTooSmall;
        const pixels = try allocator.alloc(Color, len);
        errdefer allocator.free(pixels);
        for (pixels, source[0..len]) |*dst_pixel, value| {
            dst_pixel.* = Color.fromRgba32(value);
        }
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn clear(self: *Image, value: Color) void {
        @memset(self.pixels, value);
    }

    pub fn pixel(self: *const Image, x: u32, y: u32) ?Color {
        if (x >= self.width or y >= self.height) return null;
        return self.pixels[y * self.width + x];
    }

    pub fn writePixel(self: *Image, x: u32, y: u32, value: Color) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.width + x] = value;
    }

    pub fn paintSpan(self: *Image, x: i32, y: i32, len: usize, value: Color) void {
        if (x < 0 or y < 0 or y >= @as(i32, @intCast(self.height))) return;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const px = x + @as(i32, @intCast(i));
            if (px < 0 or px >= @as(i32, @intCast(self.width))) continue;
            self.writePixel(@intCast(px), @intCast(y), value);
        }
    }

    pub fn clearSpan(self: *Image, x: i32, y: i32, len: usize) void {
        self.paintSpan(x, y, len, .transparent);
    }

    pub fn span(self: *Image, x: i32, y: i32, len: usize) []Color {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return self.pixels[0..0];
        const start = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        const available = @as(usize, @intCast(self.width - @as(u32, @intCast(x))));
        return self.pixels[start .. start + @min(len, available)];
    }

    pub fn constSpan(self: *const Image, x: i32, y: i32, len: usize) []const Color {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return self.pixels[0..0];
        const start = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        const available = @as(usize, @intCast(self.width - @as(u32, @intCast(x))));
        return self.pixels[start .. start + @min(len, available)];
    }

    pub fn blendPixel(self: *Image, x: u32, y: u32, value: Color) void {
        self.blendPixelMode(x, y, value, .source_over);
    }

    pub fn blendPixelMode(self: *Image, x: u32, y: u32, value: Color, mode: BlendMode) void {
        if (x >= self.width or y >= self.height) return;
        const idx = y * self.width + x;
        self.pixels[idx] = color.blend(value, self.pixels[idx], mode);
    }

    pub fn compositeSpan(self: *Image, x: i32, y: i32, len: usize, value: Color, mode: BlendMode, opacity: f32) void {
        if (x < 0 or y < 0 or y >= @as(i32, @intCast(self.height))) return;
        const src = value.withAlphaScale(opacity);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const px = x + @as(i32, @intCast(i));
            if (px < 0 or px >= @as(i32, @intCast(self.width))) continue;
            self.blendPixelMode(@intCast(px), @intCast(y), src, mode);
        }
    }

    pub fn applyAlphaMask(self: *Image, mask: *const Image, dst_x: i32, dst_y: i32) void {
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const mask_x = @as(i32, @intCast(x)) - dst_x;
                const mask_y = @as(i32, @intCast(y)) - dst_y;
                if (mask_x < 0 or mask_y < 0 or mask_x >= @as(i32, @intCast(mask.width)) or mask_y >= @as(i32, @intCast(mask.height))) {
                    self.writePixel(x, y, .transparent);
                    continue;
                }
                const mask_pixel = mask.pixel(@intCast(mask_x), @intCast(mask_y)) orelse Color.transparent;
                if (mask_pixel.a == 0) {
                    self.writePixel(x, y, .transparent);
                    continue;
                }
                self.blendPixelMode(x, y, Color.rgba(0, 0, 0, mask_pixel.a), .destination_in);
            }
        }
    }

    pub fn compositeImage(self: *Image, source: *const Image, dst_x: i32, dst_y: i32, mode: BlendMode) void {
        var src_y: u32 = 0;
        while (src_y < source.height) : (src_y += 1) {
            const y = @as(i32, @intCast(src_y)) + dst_y;
            if (y < 0 or y >= @as(i32, @intCast(self.height))) continue;
            var src_x: u32 = 0;
            while (src_x < source.width) : (src_x += 1) {
                const x = @as(i32, @intCast(src_x)) + dst_x;
                if (x < 0 or x >= @as(i32, @intCast(self.width))) continue;
                const src_pixel = source.pixel(src_x, src_y) orelse Color.transparent;
                self.blendPixelMode(@intCast(x), @intCast(y), src_pixel, mode);
            }
        }
    }

    pub fn downsample2x(self: *const Image, allocator: std.mem.Allocator) !Image {
        const out_width = self.width / 2;
        const out_height = self.height / 2;
        var out = try Image.init(allocator, out_width, out_height, .transparent);
        errdefer out.deinit();
        var y: u32 = 0;
        while (y < out_height) : (y += 1) {
            var x: u32 = 0;
            while (x < out_width) : (x += 1) {
                out.writePixel(x, y, average4(
                    self.pixel(x * 2, y * 2).?,
                    self.pixel(x * 2 + 1, y * 2).?,
                    self.pixel(x * 2, y * 2 + 1).?,
                    self.pixel(x * 2 + 1, y * 2 + 1).?,
                ));
            }
        }
        return out;
    }

    pub fn countNonTransparentPixels(self: *const Image) usize {
        var count: usize = 0;
        for (self.pixels) |px| {
            if (px.a != 0) count += 1;
        }
        return count;
    }

    fn pixelCount(width: u32, height: u32) !usize {
        const len = std.math.mul(u32, width, height) catch return error.ImageTooLarge;
        return len;
    }

    pub fn compare(a: *const Image, b: *const Image, tolerance: u8) !ImageComparison {
        if (a.width != b.width or a.height != b.height) return error.ImageSizeMismatch;
        var stats = ImageComparison{ .width = a.width, .height = a.height };
        var total_error: u64 = 0;
        for (a.pixels, b.pixels) |pa, pb| {
            const dr = channelDiff(pa.r, pb.r);
            const dg = channelDiff(pa.g, pb.g);
            const db = channelDiff(pa.b, pb.b);
            const da = channelDiff(pa.a, pb.a);
            const pixel_max = @max(@max(dr, dg), @max(db, da));
            stats.max_channel_error = @max(stats.max_channel_error, pixel_max);
            total_error += @as(u64, dr) + dg + db + da;
            if (pixel_max > tolerance) stats.mismatched_pixels += 1;
        }
        const channel_count = @as(f64, @floatFromInt(a.pixels.len * 4));
        stats.mean_absolute_error = if (channel_count == 0.0) 0.0 else @as(f64, @floatFromInt(total_error)) / channel_count;
        return stats;
    }

    pub fn writePngFile(self: *const Image, io: std.Io, path: []const u8) !void {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        try self.writePng(&writer.interface);
        try writer.interface.flush();
    }

    pub fn writePng(self: *const Image, writer: *std.Io.Writer) !void {
        try writer.writeAll("\x89PNG\x0D\x0A\x1A\x0A");
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], self.width, .big);
        std.mem.writeInt(u32, ihdr[4..8], self.height, .big);
        ihdr[8] = 8;
        ihdr[9] = 6;
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;
        try writePngChunk(writer, "IHDR".*, &ihdr);
        try self.writePngIdat(writer);
        try writePngChunk(writer, "IEND".*, "");
    }

    fn writePngIdat(self: *const Image, writer: *std.Io.Writer) !void {
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(self.allocator);
        try stream.append(self.allocator, 0x78);
        try stream.append(self.allocator, 0x01);

        var adler_a: u32 = 1;
        var adler_b: u32 = 0;
        const row_len = try std.math.add(usize, 1, try std.math.mul(usize, @intCast(self.width), 4));
        const data_len = try std.math.mul(usize, row_len, @intCast(self.height));
        var remaining = data_len;
        var row_offset: usize = 0;
        while (remaining > 0) {
            const block_len: u16 = @intCast(@min(remaining, 65535));
            const final = remaining == block_len;
            try stream.append(self.allocator, if (final) 1 else 0);
            try appendLe16(&stream, self.allocator, block_len);
            try appendLe16(&stream, self.allocator, ~block_len);
            var written: usize = 0;
            while (written < block_len) {
                const row_pos = row_offset % row_len;
                const byte = if (row_pos == 0) blk: {
                    break :blk @as(u8, 0);
                } else blk: {
                    const pixel_index = row_offset / row_len * @as(usize, @intCast(self.width)) + (row_pos - 1) / 4;
                    const channel = (row_pos - 1) % 4;
                    const px = self.pixels[pixel_index];
                    break :blk switch (channel) {
                        0 => px.r,
                        1 => px.g,
                        2 => px.b,
                        else => px.a,
                    };
                };
                try stream.append(self.allocator, byte);
                adler_a = (adler_a + byte) % 65521;
                adler_b = (adler_b + adler_a) % 65521;
                row_offset += 1;
                written += 1;
            }
            remaining -= block_len;
        }
        var adler: [4]u8 = undefined;
        std.mem.writeInt(u32, &adler, (adler_b << 16) | adler_a, .big);
        try stream.appendSlice(self.allocator, &adler);
        try writePngChunk(writer, "IDAT".*, stream.items);
    }
};

fn appendLe16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try out.append(allocator, @intCast(value & 0xff));
    try out.append(allocator, @intCast(value >> 8));
}

fn writePngChunk(writer: *std.Io.Writer, chunk_type: [4]u8, data: []const u8) !void {
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(&chunk_type);
    try writer.writeAll(data);
    var hasher = crc32.init();
    hasher.update(&chunk_type);
    hasher.update(data);
    try writer.writeInt(u32, hasher.final(), .big);
}

pub const ImageComparison = struct {
    width: u32,
    height: u32,
    mismatched_pixels: usize = 0,
    max_channel_error: u8 = 0,
    mean_absolute_error: f64 = 0.0,

    pub fn within(self: ImageComparison, max_mismatched_pixels: usize, max_channel_error: u8, max_mean_absolute_error: f64) bool {
        return self.mismatched_pixels <= max_mismatched_pixels and
            self.max_channel_error <= max_channel_error and
            self.mean_absolute_error <= max_mean_absolute_error;
    }
};

fn channelDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

fn average4(a: Color, b: Color, c: Color, d: Color) Color {
    return .{
        .r = avgChannel4(a.r, b.r, c.r, d.r),
        .g = avgChannel4(a.g, b.g, c.g, d.g),
        .b = avgChannel4(a.b, b.b, c.b, d.b),
        .a = avgChannel4(a.a, b.a, c.a, d.a),
    };
}

fn avgChannel4(a: u8, b: u8, c: u8, d: u8) u8 {
    return @intCast((@as(u16, a) + b + c + d + 2) / 4);
}

test "image writes and blends pixels" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 2, 2, .transparent);
    defer img.deinit();

    img.writePixel(1, 1, .red);
    img.blendPixel(1, 1, Color.rgba(0, 0, 255, 128));

    try std.testing.expectEqual(@as(usize, 1), img.countNonTransparentPixels());
    try std.testing.expect((img.pixel(1, 1) orelse Color.transparent).b > 120);
}

test "image initializes by copying external pixel buffers" {
    const allocator = std.testing.allocator;
    var pixels = [_]Color{ .red, .green, .blue, .white };

    var img = try Image.initFromPixels(allocator, 2, 2, &pixels);
    defer img.deinit();
    pixels[0] = .black;

    try std.testing.expectEqual(Color.red, img.pixel(0, 0).?);
    try std.testing.expectEqual(Color.white, img.pixel(1, 1).?);
    try std.testing.expectError(error.ImageSourceTooSmall, Image.initFromPixels(allocator, 3, 2, &pixels));
}

test "image initializes from rgba32 buffers" {
    const allocator = std.testing.allocator;
    const pixels = [_]u32{
        Color.red.toRgba32(),
        Color.rgba(1, 2, 3, 4).toRgba32(),
    };

    var img = try Image.initFromRgba32(allocator, 2, 1, &pixels);
    defer img.deinit();

    try std.testing.expectEqual(Color.red, img.pixel(0, 0).?);
    try std.testing.expectEqual(Color.rgba(1, 2, 3, 4), img.pixel(1, 0).?);
    try std.testing.expectError(error.ImageSourceTooSmall, Image.initFromRgba32(allocator, 3, 1, &pixels));
}

test "image paints and composites spans" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 5, 2, .transparent);
    defer img.deinit();

    img.paintSpan(1, 0, 3, .red);
    try std.testing.expectEqual(Color.transparent, img.pixel(0, 0).?);
    try std.testing.expectEqual(Color.red, img.pixel(1, 0).?);
    try std.testing.expectEqual(Color.red, img.pixel(3, 0).?);
    try std.testing.expectEqual(Color.transparent, img.pixel(4, 0).?);

    img.compositeSpan(2, 0, 2, .blue, .add, 0.5);
    try std.testing.expectEqual(Color.rgba(255, 0, 128, 255), img.pixel(2, 0).?);
    try std.testing.expectEqual(Color.rgba(255, 0, 128, 255), img.pixel(3, 0).?);

    img.clearSpan(2, 0, 1);
    try std.testing.expectEqual(Color.transparent, img.pixel(2, 0).?);

    const mutable_span = img.span(1, 0, 4);
    try std.testing.expectEqual(@as(usize, 4), mutable_span.len);
    mutable_span[0] = .green;
    try std.testing.expectEqual(Color.green, img.pixel(1, 0).?);
    try std.testing.expectEqual(@as(usize, 0), img.span(-1, 0, 2).len);

    const readonly_span = img.constSpan(1, 0, 4);
    try std.testing.expectEqual(@as(usize, 4), readonly_span.len);
    try std.testing.expectEqual(Color.green, readonly_span[0]);
}

test "image span operations clip out-of-range coordinates" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 3, 1, .transparent);
    defer img.deinit();

    img.paintSpan(-1, 0, 3, .green);
    img.compositeSpan(2, 0, 3, .blue, .source, 1.0);
    img.paintSpan(0, -1, 3, .red);

    try std.testing.expectEqual(Color.transparent, img.pixel(0, 0).?);
    try std.testing.expectEqual(Color.transparent, img.pixel(1, 0).?);
    try std.testing.expectEqual(Color.blue, img.pixel(2, 0).?);
}

test "image alpha mask keeps covered destination pixels" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 3, 1, .red);
    defer img.deinit();

    var mask = try Image.init(allocator, 3, 1, .transparent);
    defer mask.deinit();
    mask.writePixel(0, 0, Color.rgba(0, 0, 0, 255));
    mask.writePixel(1, 0, Color.rgba(0, 0, 0, 128));
    mask.writePixel(2, 0, Color.rgba(0, 0, 0, 0));

    img.applyAlphaMask(&mask, 0, 0);

    try std.testing.expectEqual(@as(u8, 255), img.pixel(0, 0).?.a);
    try std.testing.expectEqual(@as(u8, 128), img.pixel(1, 0).?.a);
    try std.testing.expectEqual(Color.transparent, img.pixel(2, 0).?);
}

test "image alpha mask supports destination offsets" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 4, 1, .blue);
    defer img.deinit();

    var mask = try Image.init(allocator, 2, 1, .transparent);
    defer mask.deinit();
    mask.writePixel(0, 0, Color.rgba(0, 0, 0, 255));
    mask.writePixel(1, 0, Color.rgba(0, 0, 0, 128));

    img.applyAlphaMask(&mask, 1, 0);

    try std.testing.expectEqual(Color.transparent, img.pixel(0, 0).?);
    try std.testing.expectEqual(@as(u8, 255), img.pixel(1, 0).?.a);
    try std.testing.expectEqual(@as(u8, 128), img.pixel(2, 0).?.a);
    try std.testing.expectEqual(Color.transparent, img.pixel(3, 0).?);
}

test "image composites source at destination offset" {
    const allocator = std.testing.allocator;
    var dst = try Image.init(allocator, 4, 2, .transparent);
    defer dst.deinit();

    var src = try Image.init(allocator, 2, 1, .transparent);
    defer src.deinit();
    src.writePixel(0, 0, .red);
    src.writePixel(1, 0, Color.rgba(0, 0, 255, 128));

    dst.compositeImage(&src, 1, 1, .source_over);

    try std.testing.expectEqual(Color.transparent, dst.pixel(0, 1).?);
    try std.testing.expectEqual(Color.red, dst.pixel(1, 1).?);
    try std.testing.expectEqual(Color.rgba(0, 0, 255, 128), dst.pixel(2, 1).?);
    try std.testing.expectEqual(Color.transparent, dst.pixel(3, 1).?);
}

test "image composite clips negative source offsets" {
    const allocator = std.testing.allocator;
    var dst = try Image.init(allocator, 2, 1, .transparent);
    defer dst.deinit();

    var src = try Image.init(allocator, 3, 1, .transparent);
    defer src.deinit();
    src.writePixel(0, 0, .red);
    src.writePixel(1, 0, .green);
    src.writePixel(2, 0, .blue);

    dst.compositeImage(&src, -1, 0, .source);

    try std.testing.expectEqual(Color.green, dst.pixel(0, 0).?);
    try std.testing.expectEqual(Color.blue, dst.pixel(1, 0).?);
}

test "image composite supports blend modes" {
    const allocator = std.testing.allocator;
    var dst = try Image.init(allocator, 1, 1, .red);
    defer dst.deinit();

    var src = try Image.init(allocator, 1, 1, .blue);
    defer src.deinit();

    dst.compositeImage(&src, 0, 0, .add);

    try std.testing.expectEqual(Color.rgba(255, 0, 255, 255), dst.pixel(0, 0).?);
}

test "image downsamples 2x by averaging pixels" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 3, 3, .transparent);
    defer img.deinit();
    img.writePixel(0, 0, Color.rgba(0, 0, 0, 0));
    img.writePixel(1, 0, Color.rgba(100, 0, 0, 0));
    img.writePixel(0, 1, Color.rgba(0, 100, 0, 0));
    img.writePixel(1, 1, Color.rgba(0, 0, 100, 200));
    img.writePixel(2, 2, .white);

    var down = try img.downsample2x(allocator);
    defer down.deinit();

    try std.testing.expectEqual(@as(u32, 1), down.width);
    try std.testing.expectEqual(@as(u32, 1), down.height);
    try std.testing.expectEqual(Color.rgba(25, 25, 25, 50), down.pixel(0, 0).?);
}

test "image comparison reports per-channel error statistics" {
    const allocator = std.testing.allocator;
    var a = try Image.init(allocator, 2, 1, .black);
    defer a.deinit();
    var b = try Image.init(allocator, 2, 1, .black);
    defer b.deinit();

    b.writePixel(0, 0, Color.rgba(3, 2, 1, 255));
    b.writePixel(1, 0, Color.rgba(0, 0, 8, 255));

    const stats = try a.compare(&b, 2);
    try std.testing.expectEqual(@as(u32, 2), stats.width);
    try std.testing.expectEqual(@as(u32, 1), stats.height);
    try std.testing.expectEqual(@as(usize, 2), stats.mismatched_pixels);
    try std.testing.expectEqual(@as(u8, 8), stats.max_channel_error);
    try std.testing.expect(stats.mean_absolute_error > 1.0);
    try std.testing.expect(!stats.within(0, 2, 1.0));
    try std.testing.expect(stats.within(2, 8, 2.0));
}

test "image comparison rejects size mismatches" {
    const allocator = std.testing.allocator;
    var a = try Image.init(allocator, 1, 1, .black);
    defer a.deinit();
    var b = try Image.init(allocator, 2, 1, .black);
    defer b.deinit();

    try std.testing.expectError(error.ImageSizeMismatch, a.compare(&b, 0));
}

test "image writes PNG structure" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 2, 1, .transparent);
    defer img.deinit();
    img.writePixel(0, 0, .red);
    img.writePixel(1, 0, Color.rgba(0, 0, 255, 128));

    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try img.writePng(&writer);
    const out = writer.buffered();

    try std.testing.expect(std.mem.startsWith(u8, out, "\x89PNG\x0D\x0A\x1A\x0A"));
    try std.testing.expect(std.mem.indexOf(u8, out, "IHDR") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "IDAT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "IEND") != null);
}
