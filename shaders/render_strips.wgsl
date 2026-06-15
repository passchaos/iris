struct Strip {
    xy_width_pad: vec4<u32>,
    rgba: u32,
};

@group(0) @binding(0) var<storage, read> strips: array<Strip>;
@group(0) @binding(1) var target: texture_storage_2d<rgba8unorm, write>;

fn unpack_color(rgba: u32) -> vec4<f32> {
    let r = f32(rgba & 0xffu) / 255.0;
    let g = f32((rgba >> 8u) & 0xffu) / 255.0;
    let b = f32((rgba >> 16u) & 0xffu) / 255.0;
    let a = f32((rgba >> 24u) & 0xffu) / 255.0;
    return vec4<f32>(r, g, b, a);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let strip_ix = gid.x;
    if (strip_ix >= arrayLength(&strips)) {
        return;
    }

    let strip = strips[strip_ix];
    let x0 = strip.xy_width_pad.x;
    let y = strip.xy_width_pad.y;
    let width = strip.xy_width_pad.z;
    // 0 source-over, 1 copy, 2 add, 3 multiply. Real backend integration
    // will map this to render pipeline blending or a read/modify/write pass.
    let blend_mode = strip.xy_width_pad.w;
    let color = unpack_color(strip.rgba);
    _ = blend_mode;

    var x = 0u;
    loop {
        if (x >= width) {
            break;
        }
        textureStore(target, vec2<i32>(i32(x0 + x), i32(y)), color);
        x = x + 1u;
    }
}
