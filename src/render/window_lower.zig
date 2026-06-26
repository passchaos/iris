const std = @import("std");
const window = @import("window_types.zig");

pub fn lowerDrawList(
    comptime Sink: type,
    sink: *Sink,
    allocator: std.mem.Allocator,
    cmds: []const window.DrawCmd,
) !void {
    var clip_stack = try std.ArrayList(window.Rect).initCapacity(allocator, 8);
    defer clip_stack.deinit(allocator);

    for (cmds) |cmd| {
        const clip = currentClip(clip_stack.items);
        switch (cmd) {
            .clip_begin => |rect| try clip_stack.append(allocator, effectiveClip(clip, rect)),
            .clip_end => {
                if (clip_stack.items.len > 0) _ = clip_stack.pop();
            },
            else => try lowerCommand(Sink, sink, cmd, clip),
        }
    }
}

fn lowerCommand(comptime Sink: type, sink: *Sink, cmd: window.DrawCmd, clip: ?window.Rect) !void {
    switch (cmd) {
        .rect => |c| try sink.rect(c, clip),
        .fill_path => |c| try sink.fillPath(c, clip),
        .stroke_path => |c| try sink.strokePath(c, clip),
        .rounded_rect => |c| try sink.roundedRect(c, clip),
        .stroke_rounded_rect => |c| try sink.strokeRoundedRect(c, clip),
        .paint_quad => |c| try sink.paintQuad(c, clip),
        .triangle => |c| try sink.triangle(c, clip),
        .linear_gradient_rect => |c| try sink.linearGradientRect(c, clip),
        .radial_gradient_rect => |c| try sink.radialGradientRect(c, clip),
        .sweep_gradient_rect => |c| try sink.sweepGradientRect(c, clip),
        .ellipse => |c| try sink.ellipse(c, clip),
        .stroke_ellipse => |c| try sink.strokeEllipse(c, clip),
        .line => |c| try sink.line(c, clip),
        .styled_line => |c| try sink.styledLine(c, clip),
        .point => |c| try sink.point(c, clip),
        .polyline => |c| try sink.polyline(c, clip),
        .styled_polyline => |c| try sink.styledPolyline(c, clip),
        .bars => |c| try sink.bars(c, clip),
        .scatter => |c| try sink.scatter(c, clip),
        .image => |c| try sink.image(c, clip),
        .text => |c| try sink.text(c, clip),
        .clip_begin, .clip_end => unreachable,
    }
}

pub fn currentClip(stack: []const window.Rect) ?window.Rect {
    if (stack.len == 0) return null;
    return stack[stack.len - 1];
}

pub fn effectiveClip(current: ?window.Rect, next: window.Rect) window.Rect {
    if (current) |clip| {
        const x0 = @max(clip.x, next.x);
        const y0 = @max(clip.y, next.y);
        const x1 = @min(clip.x + clip.w, next.x + next.w);
        const y1 = @min(clip.y + clip.h, next.y + next.h);
        return .{ .x = x0, .y = y0, .w = @max(0.0, x1 - x0), .h = @max(0.0, y1 - y0) };
    }
    return next;
}

test "window lower maintains nested effective clip stack" {
    const Sink = struct {
        clips: std.ArrayList(window.Rect),

        pub fn rect(self: *@This(), _: anytype, clip: ?window.Rect) !void {
            try self.clips.append(std.testing.allocator, clip.?);
        }
        pub fn fillPath(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn strokePath(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn roundedRect(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn strokeRoundedRect(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn paintQuad(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn triangle(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn linearGradientRect(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn radialGradientRect(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn sweepGradientRect(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn ellipse(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn strokeEllipse(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn line(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn styledLine(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn point(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn polyline(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn styledPolyline(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn bars(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn scatter(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn image(_: *@This(), _: anytype, _: ?window.Rect) !void {}
        pub fn text(_: *@This(), _: anytype, _: ?window.Rect) !void {}
    };

    var sink = Sink{ .clips = try std.ArrayList(window.Rect).initCapacity(std.testing.allocator, 0) };
    defer sink.clips.deinit(std.testing.allocator);
    try lowerDrawList(Sink, &sink, std.testing.allocator, &.{
        .{ .clip_begin = .{ .x = 0, .y = 0, .w = 10, .h = 10 } },
        .{ .clip_begin = .{ .x = 4, .y = 2, .w = 8, .h = 5 } },
        .{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 12, .h = 12 }, .color = .{ 1, 0, 0, 1 }, .layer = 0 } },
        .{ .clip_end = {} },
        .{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 12, .h = 12 }, .color = .{ 0, 1, 0, 1 }, .layer = 0 } },
        .{ .clip_end = {} },
    });

    try std.testing.expectEqual(@as(usize, 2), sink.clips.items.len);
    try std.testing.expectEqual(window.Rect{ .x = 4, .y = 2, .w = 6, .h = 5 }, sink.clips.items[0]);
    try std.testing.expectEqual(window.Rect{ .x = 0, .y = 0, .w = 10, .h = 10 }, sink.clips.items[1]);
}
