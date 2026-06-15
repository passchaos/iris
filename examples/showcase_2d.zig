const std = @import("std");
const iris = @import("iris");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var image = try iris.Image.init(allocator, 512, 320, iris.Color.rgba(12, 14, 18, 255));
    defer image.deinit();

    var scene = iris.Scene2D.init(allocator);
    defer scene.deinit();

    try scene.fillLinearGradientRect(.{ .x = 0, .y = 0, .w = 512, .h = 320 }, .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 512, .y = 320 },
        .start_color = iris.Color.rgba(16, 30, 54, 255),
        .end_color = iris.Color.rgba(45, 16, 64, 255),
    });
    try scene.dropShadowRect(.{ .x = 54, .y = 50, .w = 180, .h = 90 }, .{ .x = 14, .y = 16 }, 18, iris.Color.rgba(0, 0, 0, 160));
    try scene.fillRoundedRect(.{ .x = 54, .y = 50, .w = 180, .h = 90 }, 18, iris.Color.rgba(240, 245, 255, 230));
    try scene.strokeEllipse(.{ .x = 145, .y = 95 }, .{ .x = 66, .y = 28 }, 4, iris.Color.rgba(50, 110, 220, 255));
    try scene.fillEllipse(.{ .x = 145, .y = 95 }, .{ .x = 42, .y = 18 }, iris.Color.rgba(80, 180, 255, 210));

    try scene.fillSweepGradientRect(.{ .x = 280, .y = 42, .w = 160, .h = 160 }, .{
        .center = .{ .x = 360, .y = 122 },
        .start_color = iris.Color.rgba(255, 130, 60, 255),
        .end_color = iris.Color.rgba(60, 190, 255, 255),
    });
    try scene.fillArcSector(.{ .x = 360, .y = 122 }, .{ .x = 76, .y = 76 }, -std.math.pi / 4.0, std.math.pi * 1.15, iris.Color.rgba(255, 255, 255, 95));
    try scene.strokeArc(.{ .x = 360, .y = 122 }, .{ .x = 82, .y = 82 }, 5, std.math.pi * 0.15, std.math.pi * 1.72, iris.Color.rgba(20, 35, 56, 240));

    var heatmap = try makeHeatmap(allocator);
    defer heatmap.deinit();
    try scene.dropShadowRect(.{ .x = 292, .y = 214, .w = 104, .h = 74 }, .{ .x = 8, .y = 10 }, 12, iris.Color.rgba(0, 0, 0, 145));
    try scene.fillImageRect(.{ .x = 296, .y = 218, .w = 96, .h = 66 }, &heatmap);

    var volume_slice = try makeVolumeSlice(allocator);
    defer volume_slice.deinit();
    try scene.dropShadowRect(.{ .x = 398, .y = 40, .w = 80, .h = 58 }, .{ .x = 7, .y = 9 }, 10, iris.Color.rgba(0, 0, 0, 135));
    try scene.fillImageRect(.{ .x = 402, .y = 44, .w = 72, .h = 50 }, &volume_slice);

    var volume_atlas = try makeVolumeAtlas(allocator);
    defer volume_atlas.deinit();
    try scene.dropShadowRect(.{ .x = 398, .y = 112, .w = 80, .h = 58 }, .{ .x = 7, .y = 9 }, 10, iris.Color.rgba(0, 0, 0, 130));
    try scene.fillImageRect(.{ .x = 402, .y = 116, .w = 72, .h = 50 }, &volume_atlas);

    try addPolylinePlot(&scene);
    try addTimeline(&scene);
    try addNodeGraph(&scene);

    var path = iris.scene2d.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 64, .y = 250 });
    try path.cubicTo(.{ .x = 120, .y = 180 }, .{ .x = 210, .y = 305 }, .{ .x = 276, .y = 230 });
    try path.quadTo(.{ .x = 335, .y = 165 }, .{ .x = 438, .y = 250 });
    try scene.strokeDashedPathCap(&path, 6, 18, 10, .round, iris.Color.rgba(255, 230, 120, 235));

    var mask = try iris.Image.init(allocator, 80, 80, .transparent);
    defer mask.deinit();
    var y: u32 = 0;
    while (y < mask.height) : (y += 1) {
        var x: u32 = 0;
        while (x < mask.width) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) - 40.0;
            const dy = @as(f32, @floatFromInt(y)) - 40.0;
            const d = @sqrt(dx * dx + dy * dy);
            const a: u8 = @intFromFloat(@max(0.0, 255.0 - d * 5.5));
            mask.writePixel(x, y, iris.Color.rgba(255, 255, 255, a));
        }
    }
    try scene.fillMaskedRect(.{ .x = 420, .y = 214, .w = 80, .h = 80 }, iris.Color.rgba(80, 255, 180, 255), &mask);

    var renderer = iris.CpuRenderer.init(allocator);
    defer renderer.deinit();
    try renderer.render2D(&scene, &image);

    std.Io.Dir.cwd().createDir(init.io, "zig-out", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writePpm(init.io, "zig-out/showcase_2d.ppm", &image);
    try printDone(init.io, "zig-out/showcase_2d.ppm", image.countNonTransparentPixels());
}

fn makeHeatmap(allocator: std.mem.Allocator) !iris.Image {
    const width: u32 = 24;
    const height: u32 = 16;
    var values = try allocator.alloc(f32, width * height);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1));
            const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height - 1));
            values[y * width + x] = 0.5 + 0.35 * @sin(u * std.math.tau * 1.4) + 0.15 * @cos(v * std.math.tau * 2.0);
        }
    }
    return try iris.heatmapImage(allocator, values, .{
        .width = width,
        .height = height,
        .min_value = 0.0,
        .max_value = 1.0,
        .palette = .viridis,
    });
}

fn makeVolumeSlice(allocator: std.mem.Allocator) !iris.Image {
    const width: u32 = 12;
    const height: u32 = 10;
    const depth: u32 = 8;
    var values = try allocator.alloc(f32, width * height * depth);
    var z: u32 = 0;
    while (z < depth) : (z += 1) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1));
                const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height - 1));
                const w = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(depth - 1));
                values[z * width * height + y * width + x] = (u * 0.45 + v * 0.3 + w * 0.25);
            }
        }
    }
    return try iris.volumeSliceImage(allocator, values, .{
        .width = width,
        .height = height,
        .depth = depth,
        .axis = .z,
        .slice = 4,
        .min_value = 0.0,
        .max_value = 1.0,
        .palette = .magma,
    });
}

fn makeVolumeAtlas(allocator: std.mem.Allocator) !iris.Image {
    const width: u32 = 8;
    const height: u32 = 6;
    const depth: u32 = 6;
    var values = try allocator.alloc(f32, width * height * depth);
    var z: u32 = 0;
    while (z < depth) : (z += 1) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1));
                const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height - 1));
                const w = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(depth - 1));
                values[z * width * height + y * width + x] = @min(1.0, @max(0.0, 0.2 + u * 0.35 + v * 0.2 + w * 0.35));
            }
        }
    }
    return try iris.volumeSliceAtlasImage(allocator, values, .{
        .width = width,
        .height = height,
        .depth = depth,
        .axis = .z,
        .columns = 3,
        .min_value = 0.0,
        .max_value = 1.0,
        .palette = .viridis,
    });
}

fn addPolylinePlot(scene: *iris.Scene2D) !void {
    const plot_rect = iris.math.Rect{ .x = 304, .y = 230, .w = 76, .h = 44 };
    const points = [_]iris.math.Vec2{
        .{ .x = 0.0, .y = 0.18 },
        .{ .x = 0.12, .y = 0.28 },
        .{ .x = 0.24, .y = 0.2 },
        .{ .x = 0.38, .y = 0.58 },
        .{ .x = 0.52, .y = 0.44 },
        .{ .x = 0.66, .y = 0.78 },
        .{ .x = 0.82, .y = 0.62 },
        .{ .x = 1.0, .y = 0.9 },
    };
    try scene.fillRoundedRect(.{ .x = 286, .y = 220, .w = 116, .h = 72 }, 8, iris.Color.rgba(10, 14, 22, 125));
    try iris.appendPlotAxes(scene, .{
        .rect = plot_rect,
        .color = iris.Color.rgba(224, 232, 245, 210),
        .grid_color = iris.Color.rgba(120, 145, 175, 75),
        .x_ticks = 3,
        .y_ticks = 2,
    });
    try iris.appendPolylinePlot(scene, &points, .{
        .rect = plot_rect,
        .x_min = 0.0,
        .x_max = 1.0,
        .y_min = 0.0,
        .y_max = 1.0,
        .width = 2.5,
        .color = iris.Color.rgba(255, 238, 132, 245),
    });
    const legend = [_]iris.LegendItem{.{ .color = iris.Color.rgba(255, 238, 132, 245) }};
    try iris.appendLegend(scene, &legend, .{
        .rect = .{ .x = 362, .y = 224, .w = 28, .h = 12 },
        .swatch_size = 6,
        .gap = 3,
    });
}

fn addTimeline(scene: *iris.Scene2D) !void {
    const events = [_]iris.TimelineEvent{
        .{ .start = 0.0, .end = 1.4, .lane = 0, .color = iris.Color.rgba(96, 202, 255, 230) },
        .{ .start = 0.8, .end = 2.8, .lane = 1, .color = iris.Color.rgba(255, 170, 88, 230) },
        .{ .start = 2.2, .end = 4.0, .lane = 2, .color = iris.Color.rgba(120, 238, 148, 230) },
    };
    try iris.appendTimeline(scene, &events, .{
        .rect = .{ .x = 56, .y = 154, .w = 178, .h = 44 },
        .time_min = 0.0,
        .time_max = 4.0,
        .lanes = 3,
        .padding = 3.0,
    });
}

fn addNodeGraph(scene: *iris.Scene2D) !void {
    const node_a = iris.math.Rect{ .x = 58, .y = 206, .w = 30, .h = 20 };
    const node_b = iris.math.Rect{ .x = 138, .y = 188, .w = 34, .h = 22 };
    const node_c = iris.math.Rect{ .x = 208, .y = 218, .w = 36, .h = 22 };
    try scene.fillRoundedRect(node_a, 6, iris.Color.rgba(42, 84, 146, 230));
    try scene.fillRoundedRect(node_b, 6, iris.Color.rgba(68, 132, 98, 230));
    try scene.fillRoundedRect(node_c, 6, iris.Color.rgba(144, 96, 62, 230));
    const edges = [_]iris.NodeGraphEdge{
        .{
            .from = .{ .x = node_a.x + node_a.w, .y = node_a.y + node_a.h * 0.5 },
            .to = .{ .x = node_b.x, .y = node_b.y + node_b.h * 0.5 },
            .color = iris.Color.rgba(125, 210, 255, 235),
            .width = 2.0,
        },
        .{
            .from = .{ .x = node_b.x + node_b.w, .y = node_b.y + node_b.h * 0.5 },
            .to = .{ .x = node_c.x, .y = node_c.y + node_c.h * 0.5 },
            .color = iris.Color.rgba(255, 216, 126, 235),
            .width = 2.0,
        },
    };
    try iris.appendNodeGraphEdges(scene, &edges, .{ .curvature = 0.45, .arrow_size = 6.0 });
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
