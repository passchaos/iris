const std = @import("std");
const iris = @import("iris");
const cangjie = @import("cangjie");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var image = try iris.Image.init(allocator, 420, 180, iris.Color.rgba(16, 18, 24, 255));
    defer image.deinit();

    var scene = iris.Scene2D.init(allocator);
    defer scene.deinit();
    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 420, .h = 180 }, .{
        .start = .{},
        .end = .{ .x = 420, .y = 180 },
        .start_color = iris.Color.rgba(18, 26, 42, 255),
        .end_color = iris.Color.rgba(42, 24, 52, 255),
    });

    const font_bytes = try cangjie.testing.test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);
    const font = try scene.addTextFont(font_bytes);

    var radical = iris.scene2d.Path.init(allocator);
    defer radical.deinit();
    try radical.moveTo(.{ .x = 232, .y = 94 });
    try radical.lineTo(.{ .x = 242, .y = 116 });
    try radical.lineTo(.{ .x = 258, .y = 62 });
    try radical.lineTo(.{ .x = 330, .y = 62 });

    const glyphs = [_]iris.FormulaGlyph{
        .{ .font_index = font, .text = "E", .origin = .{ .x = 42, .y = 82 }, .size = 28, .color = iris.Color.rgba(245, 248, 255, 255) },
        .{ .font_index = font, .text = "m", .origin = .{ .x = 88, .y = 82 }, .size = 24, .color = iris.Color.rgba(245, 248, 255, 255) },
        .{ .font_index = font, .text = "c", .origin = .{ .x = 126, .y = 82 }, .size = 24, .color = iris.Color.rgba(245, 248, 255, 255) },
        .{ .font_index = font, .text = "2", .origin = .{ .x = 145, .y = 58 }, .size = 14, .color = iris.Color.rgba(255, 222, 112, 255) },
        .{ .font_index = font, .text = "x", .origin = .{ .x = 274, .y = 104 }, .size = 24, .color = iris.Color.rgba(245, 248, 255, 255) },
        .{ .font_index = font, .text = "1", .origin = .{ .x = 294, .y = 104 }, .size = 18, .color = iris.Color.rgba(245, 248, 255, 255) },
    };
    const rules = [_]iris.FormulaRule{
        .{ .rect = .{ .x = 82, .y = 72, .w = 10, .h = 2 }, .color = iris.Color.rgba(245, 248, 255, 255) },
        .{ .rect = .{ .x = 190, .y = 84, .w = 34, .h = 2 }, .color = iris.Color.rgba(255, 222, 112, 255) },
    };
    const paths = [_]iris.FormulaPathRequest{
        .{ .path = &radical, .stroke = iris.Color.rgba(122, 214, 255, 255), .stroke_width = 3.0 },
    };
    const delimiter_parts = [_]iris.FormulaGlyph{
        .{ .font_index = font, .text = "(", .origin = .{ .x = 174, .y = 68 }, .size = 18, .color = iris.Color.rgba(180, 220, 255, 255) },
        .{ .font_index = font, .text = "|", .origin = .{ .x = 174, .y = 88 }, .size = 18, .color = iris.Color.rgba(180, 220, 255, 255) },
        .{ .font_index = font, .text = ")", .origin = .{ .x = 216, .y = 88 }, .size = 18, .color = iris.Color.rgba(180, 220, 255, 255) },
    };
    try iris.appendFormulaDrawList(&scene, .{
        .glyphs = &glyphs,
        .glyph_assemblies = &.{.{ .parts = &delimiter_parts }},
        .path_requests = &paths,
        .rules = &rules,
        .debug_overlay = .{
            .origin = .{ .x = 36, .y = 0 },
            .width = 320,
            .baseline_y = 84,
            .math_axis_y = 70,
        },
    });

    var renderer = iris.CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &image);

    std.Io.Dir.cwd().createDir(init.io, "zig-out", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writePpm(init.io, "zig-out/showcase_formula.ppm", &image);
    try printDone(init.io, "zig-out/showcase_formula.ppm", image.countNonTransparentPixels());
}

fn writePpm(io: std.Io, path: []const u8, image: *const iris.Image) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.print("P6\n{d} {d}\n255\n", .{ image.width, image.height });
    for (image.pixels) |pixel| {
        try writer.interface.writeAll(&.{ pixel.r, pixel.g, pixel.b });
    }
    try writer.interface.flush();
}

fn printDone(io: std.Io, path: []const u8, pixels: usize) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print("wrote {s} ({d} non-transparent pixels)\n", .{ path, pixels });
    try out.interface.flush();
}
