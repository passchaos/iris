const std = @import("std");
const iris = @import("iris");
const cangjie = @import("cangjie");

const iterations = 256;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const font_bytes = try cangjie.testing.test_font.buildMinimalTtf(allocator);
    defer allocator.free(font_bytes);

    var scene = iris.Scene2D.init(allocator);
    defer scene.deinit();
    const font = try scene.addTextFont(font_bytes);

    var radical = iris.scene2d.Path.init(allocator);
    defer radical.deinit();
    try radical.moveTo(.{ .x = 24, .y = 32 });
    try radical.lineTo(.{ .x = 32, .y = 46 });
    try radical.lineTo(.{ .x = 44, .y = 14 });
    try radical.lineTo(.{ .x = 90, .y = 14 });

    const glyphs = [_]iris.FormulaGlyph{
        .{ .font_index = font, .text = "x", .origin = .{ .x = 48, .y = 44 }, .size = 22, .color = .white },
        .{ .font_index = font, .text = "2", .origin = .{ .x = 64, .y = 26 }, .size = 12, .color = .white },
    };
    const rules = [_]iris.FormulaRule{
        .{ .rect = .{ .x = 100, .y = 34, .w = 36, .h = 2 }, .color = .white },
    };
    const paths = [_]iris.FormulaPathRequest{
        .{ .path = &radical, .stroke = .white, .stroke_width = 2.0 },
    };
    const draw_list = iris.FormulaDrawList{
        .glyphs = &glyphs,
        .path_requests = &paths,
        .rules = &rules,
        .debug_overlay = .{ .origin = .{ .x = 20 }, .width = 128, .baseline_y = 44, .math_axis_y = 34 },
    };

    const start = std.Io.Clock.awake.now(init.io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        for (scene.paths.items) |*stored_path| {
            stored_path.deinit();
        }
        scene.primitives.clearRetainingCapacity();
        scene.paths.clearRetainingCapacity();
        try iris.appendFormulaDrawList(&scene, draw_list);
    }
    const elapsed_ns = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
    const dump = iris.debugScene2DVisualizationBatch(&scene);
    const formula_dump = iris.debugFormulaDrawList(draw_list);

    var stdout_buffer: [512]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print(
        "iris formula bench: {d} iterations, {d} primitives, {d} formula-estimated primitives, {d} ns\n",
        .{
            iterations,
            dump.primitives,
            formula_dump.estimated_primitives,
            elapsed_ns,
        },
    );
    try stdout.flush();
}
