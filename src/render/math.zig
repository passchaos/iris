const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
};

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(v.dot(v));
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len <= 0.000001) return .{};
        return .{ .x = v.x / len, .y = v.y / len, .z = v.z / len };
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }
};

pub const Affine2D = struct {
    ax: f32 = 1,
    by: f32 = 0,
    cx: f32 = 0,
    dy: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub const identity: Affine2D = .{};

    pub fn mul(a: Affine2D, b: Affine2D) Affine2D {
        return .{
            .ax = a.ax * b.ax + a.by * b.cx,
            .by = a.ax * b.by + a.by * b.dy,
            .cx = a.cx * b.ax + a.dy * b.cx,
            .dy = a.cx * b.by + a.dy * b.dy,
            .tx = a.ax * b.tx + a.by * b.ty + a.tx,
            .ty = a.cx * b.tx + a.dy * b.ty + a.ty,
        };
    }

    pub fn translate(a: Affine2D, tx: f32, ty: f32) Affine2D {
        return a.mul(.{ .tx = tx, .ty = ty });
    }

    pub fn translate64(a: Affine2D, tx: f64, ty: f64) Affine2D {
        return a.translate(@floatCast(tx), @floatCast(ty));
    }

    pub fn scale(a: Affine2D, sx: f32, sy: f32) Affine2D {
        return a.mul(.{ .ax = sx, .dy = sy });
    }

    pub fn scale64(a: Affine2D, sx: f64, sy: f64) Affine2D {
        return a.scale(@floatCast(sx), @floatCast(sy));
    }

    pub fn rotate(a: Affine2D, radians: f32) Affine2D {
        const c = @cos(radians);
        const s = @sin(radians);
        return a.mul(.{ .ax = c, .by = -s, .cx = s, .dy = c });
    }

    pub fn rotate64(a: Affine2D, radians: f64) Affine2D {
        return a.rotate(@floatCast(radians));
    }

    pub fn determinant(self: Affine2D) f32 {
        return self.ax * self.dy - self.by * self.cx;
    }

    pub fn scaleMagnitude(self: Affine2D) Vec2 {
        return .{
            .x = @sqrt(self.ax * self.ax + self.cx * self.cx),
            .y = @sqrt(self.by * self.by + self.dy * self.dy),
        };
    }

    pub fn inverse(self: Affine2D) ?Affine2D {
        const det = self.determinant();
        if (@abs(det) <= 0.000001) return null;
        const inv_det = 1.0 / det;
        return .{
            .ax = self.dy * inv_det,
            .by = -self.by * inv_det,
            .cx = -self.cx * inv_det,
            .dy = self.ax * inv_det,
            .tx = (self.by * self.ty - self.dy * self.tx) * inv_det,
            .ty = (self.cx * self.tx - self.ax * self.ty) * inv_det,
        };
    }

    pub fn transformPoint(self: Affine2D, p: Vec2) Vec2 {
        return .{
            .x = self.ax * p.x + self.by * p.y + self.tx,
            .y = self.cx * p.x + self.dy * p.y + self.ty,
        };
    }

    pub fn transformVector(self: Affine2D, v: Vec2) Vec2 {
        return .{
            .x = self.ax * v.x + self.by * v.y,
            .y = self.cx * v.x + self.dy * v.y,
        };
    }

    pub fn isIdentity(self: Affine2D) bool {
        return self.ax == 1 and self.by == 0 and self.cx == 0 and self.dy == 1 and self.tx == 0 and self.ty == 0;
    }
};

pub const Mat4 = struct {
    m: [16]f32,

    pub const identity: Mat4 = .{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    pub fn translation(v: Vec3) Mat4 {
        return .{ .m = .{
            1,   0,   0,   0,
            0,   1,   0,   0,
            0,   0,   1,   0,
            v.x, v.y, v.z, 1,
        } };
    }

    pub fn scale(v: Vec3) Mat4 {
        return .{ .m = .{
            v.x, 0,   0,   0,
            0,   v.y, 0,   0,
            0,   0,   v.z, 0,
            0,   0,   0,   1,
        } };
    }

    pub fn rotationX(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            1, 0,  0, 0,
            0, c,  s, 0,
            0, -s, c, 0,
            0, 0,  0, 1,
        } };
    }

    pub fn rotationY(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            c, 0, -s, 0,
            0, 1, 0,  0,
            s, 0, c,  0,
            0, 0, 0,  1,
        } };
    }

    pub fn rotationZ(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            c,  s, 0, 0,
            -s, c, 0, 0,
            0,  0, 1, 0,
            0,  0, 0, 1,
        } };
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: [16]f32 = undefined;
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                out[col * 4 + row] =
                    a.m[0 * 4 + row] * b.m[col * 4 + 0] +
                    a.m[1 * 4 + row] * b.m[col * 4 + 1] +
                    a.m[2 * 4 + row] * b.m[col * 4 + 2] +
                    a.m[3 * 4 + row] * b.m[col * 4 + 3];
            }
        }
        return .{ .m = out };
    }

    pub fn orthographic(width: f32, height: f32) Mat4 {
        return .{ .m = .{
            2.0 / width, 0,             0, 0,
            0,           -2.0 / height, 0, 0,
            0,           0,             1, 0,
            -1,          1,             0, 1,
        } };
    }

    pub fn orthographicCentered(width: f32, height: f32, near: f32, far: f32) Mat4 {
        return .{ .m = .{
            2.0 / width, 0,            0,                   0,
            0,           2.0 / height, 0,                   0,
            0,           0,            1.0 / (near - far),  0,
            0,           0,            near / (near - far), 1,
        } };
    }

    pub fn perspective(fovy_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy_radians * 0.5);
        return .{ .m = .{
            f / aspect, 0, 0,                                 0,
            0,          f, 0,                                 0,
            0,          0, (far + near) / (near - far),       -1,
            0,          0, (2.0 * far * near) / (near - far), 0,
        } };
    }

    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up.normalize()).normalize();
        const u = s.cross(f);
        return .{ .m = .{
            s.x,         u.x,         -f.x,       0,
            s.y,         u.y,         -f.y,       0,
            s.z,         u.z,         -f.z,       0,
            -s.dot(eye), -u.dot(eye), f.dot(eye), 1,
        } };
    }

    pub fn transformPoint(self: Mat4, v: Vec3) Vec3 {
        const x = v.x * self.m[0] + v.y * self.m[4] + v.z * self.m[8] + self.m[12];
        const y = v.x * self.m[1] + v.y * self.m[5] + v.z * self.m[9] + self.m[13];
        const z = v.x * self.m[2] + v.y * self.m[6] + v.z * self.m[10] + self.m[14];
        const w = v.x * self.m[3] + v.y * self.m[7] + v.z * self.m[11] + self.m[15];
        if (w == 0 or w == 1) return .{ .x = x, .y = y, .z = z };
        return .{ .x = x / w, .y = y / w, .z = z / w };
    }

    pub fn transformVector(self: Mat4, v: Vec3) Vec3 {
        return .{
            .x = v.x * self.m[0] + v.y * self.m[4] + v.z * self.m[8],
            .y = v.x * self.m[1] + v.y * self.m[5] + v.z * self.m[9],
            .z = v.x * self.m[2] + v.y * self.m[6] + v.z * self.m[10],
        };
    }

    pub fn transformNormal(self: Mat4, normal: Vec3) Vec3 {
        const a00 = self.m[0];
        const a01 = self.m[4];
        const a02 = self.m[8];
        const a10 = self.m[1];
        const a11 = self.m[5];
        const a12 = self.m[9];
        const a20 = self.m[2];
        const a21 = self.m[6];
        const a22 = self.m[10];

        const c00 = a11 * a22 - a12 * a21;
        const c01 = -(a10 * a22 - a12 * a20);
        const c02 = a10 * a21 - a11 * a20;
        const det = a00 * c00 + a01 * c01 + a02 * c02;
        if (@abs(det) <= 0.000001) return self.transformVector(normal).normalize();

        const inv_det = 1.0 / det;
        return (Vec3{
            .x = (c00 * normal.x + c01 * normal.y + c02 * normal.z) * inv_det,
            .y = (-(a01 * a22 - a02 * a21) * normal.x + (a00 * a22 - a02 * a20) * normal.y - (a00 * a21 - a01 * a20) * normal.z) * inv_det,
            .z = ((a01 * a12 - a02 * a11) * normal.x - (a00 * a12 - a02 * a10) * normal.y + (a00 * a11 - a01 * a10) * normal.z) * inv_det,
        }).normalize();
    }

    pub fn inverse(self: Mat4) ?Mat4 {
        const m = self.m;
        var inv: [16]f32 = undefined;

        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

        const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
        if (@abs(det) <= 0.000001) return null;
        const inv_det = 1.0 / det;
        for (&inv) |*value| {
            value.* *= inv_det;
        }
        return .{ .m = inv };
    }
};

pub fn clampInt(v: i32, lo: i32, hi: i32) i32 {
    return @min(@max(v, lo), hi);
}

test "cross product follows right handed coordinates" {
    const out = Vec3.cross(.{ .x = 1 }, .{ .y = 1 });
    try std.testing.expectEqual(@as(f32, 1), out.z);
}

test "vec3 normalize returns unit length" {
    const out = (Vec3{ .x = 3, .y = 4 }).normalize();
    try std.testing.expect(@abs(out.length() - 1.0) < 0.0001);
}

test "vec3 scales components" {
    const out = (Vec3{ .x = 1, .y = -2, .z = 3 }).scale(2.0);
    try std.testing.expectEqual(@as(f32, 2), out.x);
    try std.testing.expectEqual(@as(f32, -4), out.y);
    try std.testing.expectEqual(@as(f32, 6), out.z);
}

test "mat4 composes scale and translation" {
    const m = Mat4.translation(.{ .x = 2, .y = 3, .z = 4 }).mul(Mat4.scale(.{ .x = 2, .y = 2, .z = 2 }));
    const out = m.transformPoint(.{ .x = 1, .y = 1, .z = 1 });
    try std.testing.expectEqual(@as(f32, 4), out.x);
    try std.testing.expectEqual(@as(f32, 5), out.y);
    try std.testing.expectEqual(@as(f32, 6), out.z);
}

test "mat4 inverse recovers transformed points" {
    const m = Mat4.translation(.{ .x = 2, .y = 3, .z = 4 })
        .mul(Mat4.rotationY(std.math.pi / 4.0))
        .mul(Mat4.scale(.{ .x = 2, .y = 3, .z = 4 }));
    const inv = m.inverse().?;
    const point = Vec3{ .x = 0.25, .y = -0.5, .z = 1.5 };
    const recovered = inv.transformPoint(m.transformPoint(point));

    try std.testing.expect(@abs(recovered.x - point.x) < 0.0001);
    try std.testing.expect(@abs(recovered.y - point.y) < 0.0001);
    try std.testing.expect(@abs(recovered.z - point.z) < 0.0001);
    try std.testing.expect(Mat4.scale(.{ .x = 0, .y = 1, .z = 1 }).inverse() == null);
}

test "mat4 transforms vectors without translation" {
    const m = Mat4.translation(.{ .x = 2, .y = 3, .z = 4 }).mul(Mat4.rotationZ(std.math.pi / 2.0));
    const out = m.transformVector(.{ .x = 1 });
    try std.testing.expect(@abs(out.x) < 0.0001);
    try std.testing.expect(@abs(out.y - 1.0) < 0.0001);
    try std.testing.expect(@abs(out.z) < 0.0001);
}

test "mat4 rotates vectors around x and y axes" {
    const x_out = Mat4.rotationX(std.math.pi / 2.0).transformVector(.{ .y = 1 });
    try std.testing.expect(@abs(x_out.x) < 0.0001);
    try std.testing.expect(@abs(x_out.y) < 0.0001);
    try std.testing.expect(@abs(x_out.z - 1.0) < 0.0001);

    const y_out = Mat4.rotationY(std.math.pi / 2.0).transformVector(.{ .z = 1 });
    try std.testing.expect(@abs(y_out.x - 1.0) < 0.0001);
    try std.testing.expect(@abs(y_out.y) < 0.0001);
    try std.testing.expect(@abs(y_out.z) < 0.0001);
}

test "mat4 transforms normals with inverse transpose" {
    const m = Mat4.scale(.{ .x = 2, .y = 1, .z = 1 });
    const out = m.transformNormal(.{ .x = 1, .y = 1 });
    try std.testing.expect(@abs(out.length() - 1.0) < 0.0001);
    try std.testing.expect(@abs(out.x - 0.4472136) < 0.0001);
    try std.testing.expect(@abs(out.y - 0.8944272) < 0.0001);
}

test "centered orthographic maps camera-space depth into clip range" {
    const m = Mat4.orthographicCentered(4.0, 4.0, 0.1, 100.0);
    const center = m.transformPoint(.{ .z = -3.0 });
    const right = m.transformPoint(.{ .x = 2.0, .z = -3.0 });
    try std.testing.expect(@abs(center.x) < 0.0001);
    try std.testing.expect(center.z > 0.0 and center.z < 1.0);
    try std.testing.expect(@abs(right.x - 1.0) < 0.0001);
}

test "perspective look-at maps visible point to clip space" {
    const view = Mat4.lookAt(.{ .z = 3 }, .{}, .{ .y = 1 });
    const projection = Mat4.perspective(std.math.pi / 2.0, 1.0, 0.1, 100.0);
    const out = projection.mul(view).transformPoint(.{});
    try std.testing.expect(@abs(out.x) < 0.0001);
    try std.testing.expect(@abs(out.y) < 0.0001);
    try std.testing.expect(out.z > 0.0 and out.z < 1.0);
}
