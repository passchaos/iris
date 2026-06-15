const std = @import("std");
const iris = @import("iris");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var image = try iris.Image.init(allocator, 512, 512, .transparent);
    defer image.deinit();

    var scene = iris.Scene2D.init(allocator);
    defer scene.deinit();

    var i: u32 = 0;
    while (i < 128) : (i += 1) {
        const x = @as(f32, @floatFromInt((i * 17) % 480));
        const y = @as(f32, @floatFromInt((i * 29) % 480));
        try scene.fillRect(.{ .x = x, .y = y, .w = 28, .h = 19 }, iris.Color.rgba(255, @intCast((i * 3) % 255), 96, 180));

        var path = iris.scene2d.Path.init(allocator);
        defer path.deinit();
        try path.moveTo(.{ .x = x + 4, .y = y + 32 });
        try path.quadTo(.{ .x = x + 18, .y = y + 4 }, .{ .x = x + 36, .y = y + 32 });
        try path.lineTo(.{ .x = x + 4, .y = y + 32 });
        try path.close();
        try scene.fillPath(&path, iris.Color.rgba(64, 180, 255, 170), .non_zero);
    }

    var renderer = iris.CpuRenderer.init(allocator);
    defer renderer.deinit();

    const start = std.Io.Clock.awake.now(init.io);
    try renderer.render2D(&scene, &image);
    const elapsed_ns = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print(
        "iris bench: {d} primitives, {d} strips, {d} tiles, {d}x{d} tile-bounds, {d} pixels, {d} ns\n",
        .{
            scene.primitives.items.len,
            renderer.stats.strips_emitted,
            renderer.stats.tiles_touched,
            renderer.stats.tile_bounds_width,
            renderer.stats.tile_bounds_height,
            image.countNonTransparentPixels(),
            elapsed_ns,
        },
    );
    try stdout.flush();
}
