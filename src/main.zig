const std = @import("std");
const iris = @import("iris");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    var image = try iris.Image.init(arena, 64, 64, .transparent);
    defer image.deinit();

    var scene = iris.Scene2D.init(arena);
    defer scene.deinit();
    try scene.fillRect(.{ .x = 8, .y = 8, .w = 24, .h = 16 }, .red);
    try scene.strokeLine(.{ .x = 0, .y = 63 }, .{ .x = 63, .y = 0 }, 2, .white);

    var renderer = iris.HybridRenderer.init(arena, .{ .prefer_gpu = false });
    defer renderer.deinit();
    try renderer.render2D(&scene, &image);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("iris rendered {d} non-transparent pixels using {d} CPU job(s)\n", .{
        image.countNonTransparentPixels(),
        renderer.stats.cpu_jobs,
    });
    try stdout_writer.flush();
}
