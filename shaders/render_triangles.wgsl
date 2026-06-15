struct Vertex3D {
    x: f32,
    y: f32,
    z: f32,
    world_x: f32,
    world_y: f32,
    world_z: f32,
    u: f32,
    v: f32,
    nx: f32,
    ny: f32,
    nz: f32,
    base_rgba: u32,
    rgba: u32,
};

struct Triangle {
    a: Vertex3D,
    b: Vertex3D,
    c: Vertex3D,
    texture_index: u32,
    normal_texture_index: u32,
    material_ambient: f32,
    material_diffuse: f32,
    material_roughness: f32,
    material_metallic: f32,
    material_emissive: u32,
    material_emissive_strength: f32,
};

struct TextureInfo {
    width: u32,
    height: u32,
    pixel_start: u32,
    pixel_count: u32,
};

struct Light {
    kind: u32,
    direction_x: f32,
    direction_y: f32,
    direction_z: f32,
    position_x: f32,
    position_y: f32,
    position_z: f32,
    ambient: f32,
    diffuse: f32,
    range: f32,
    attenuation: f32,
    inner_angle: f32,
    outer_angle: f32,
};

@group(0) @binding(0) var<storage, read> triangles: array<Triangle>;
@group(0) @binding(1) var<storage, read> textures: array<TextureInfo>;
@group(0) @binding(2) var<storage, read> texture_pixels: array<u32>;
@group(0) @binding(3) var<storage, read> lights: array<Light>;
@group(0) @binding(4) var<uniform> lighting_enabled: u32;

const INVALID_TEXTURE_INDEX: u32 = 0xffffffffu;

fn unpack_color(rgba: u32) -> vec4<f32> {
    let r = f32(rgba & 0xffu) / 255.0;
    let g = f32((rgba >> 8u) & 0xffu) / 255.0;
    let b = f32((rgba >> 16u) & 0xffu) / 255.0;
    let a = f32((rgba >> 24u) & 0xffu) / 255.0;
    return vec4<f32>(r, g, b, a);
}

fn sample_texture(texture_index: u32, uv: vec2<f32>) -> vec4<f32> {
    if (texture_index == INVALID_TEXTURE_INDEX || texture_index >= arrayLength(&textures)) {
        return vec4<f32>(1.0);
    }
    let texture = textures[texture_index];
    if (texture.width == 0u || texture.height == 0u || texture.pixel_count == 0u) {
        return vec4<f32>(1.0);
    }
    let x = u32(floor(clamp(uv.x, 0.0, 0.999999) * f32(texture.width)));
    let y = u32(floor(clamp(uv.y, 0.0, 0.999999) * f32(texture.height)));
    let local_index = min(texture.pixel_count - 1u, y * texture.width + x);
    let pixel_index = texture.pixel_start + local_index;
    if (pixel_index >= arrayLength(&texture_pixels)) {
        return vec4<f32>(1.0);
    }
    return unpack_color(texture_pixels[pixel_index]);
}

fn sample_normal(normal_texture_index: u32, uv: vec2<f32>, fallback: vec3<f32>) -> vec3<f32> {
    if (normal_texture_index == INVALID_TEXTURE_INDEX) {
        return normalize(fallback);
    }
    let encoded = sample_texture(normal_texture_index, uv);
    return normalize(encoded.xyz * 2.0 - vec3<f32>(1.0));
}

fn light_intensity(normal: vec3<f32>, position: vec3<f32>, in: VertexOut) -> f32 {
    var intensity = 0.0;
    for (var i = 0u; i < arrayLength(&lights); i = i + 1u) {
        let light = lights[i];
        var falloff = 1.0;
        let light_direction = vec3<f32>(light.direction_x, light.direction_y, light.direction_z);
        let light_position = vec3<f32>(light.position_x, light.position_y, light.position_z);
        var light_dir = normalize(light_direction);
        if (light.kind == 1u || light.kind == 2u) {
            let offset = light_position - position;
            let distance = length(offset);
            if (distance > light.range) {
                intensity = intensity + light.ambient * in.material_ambient;
                continue;
            }
            if (light.kind == 2u) {
                let from_light = normalize(position - light_position);
                let cone = dot(from_light, normalize(light_direction));
                let outer = cos(light.outer_angle);
                if (cone <= outer) {
                    intensity = intensity + light.ambient * in.material_ambient;
                    continue;
                }
                let inner = cos(light.inner_angle);
                if (cone < inner) {
                    let denom = inner - outer;
                    if (abs(denom) > 0.000001) {
                        falloff = falloff * ((cone - outer) / denom);
                    } else {
                        falloff = 0.0;
                    }
                }
            }
            if (light.attenuation > 0.0) {
                let t = select(1.0, min(1.0, distance / light.range), light.range > 0.000001);
                falloff = falloff * max(0.0, 1.0 - t * t) / (1.0 + light.attenuation * distance * distance);
            }
            light_dir = normalize(offset);
        }
        let ndotl = max(0.0, dot(normalize(normal), light_dir));
        let specular = in.material_metallic * (1.0 - in.material_roughness) * ndotl * ndotl;
        intensity = intensity + light.ambient * in.material_ambient + light.diffuse * (in.material_diffuse * ndotl + specular) * falloff;
    }
    return min(1.0, intensity);
}

fn apply_material_color(value: vec4<f32>, intensity: f32, in: VertexOut) -> vec4<f32> {
    let lit = vec4<f32>(value.rgb * clamp(intensity, 0.0, 1.0), value.a);
    return vec4<f32>(
        min(vec3<f32>(1.0), lit.rgb + in.material_emissive.rgb * max(0.0, in.material_emissive_strength)),
        lit.a,
    );
}

struct VertexOut {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) base_color: vec4<f32>,
    @location(2) world_position: vec3<f32>,
    @location(3) uv: vec2<f32>,
    @location(4) normal: vec3<f32>,
    @location(5) @interpolate(flat) texture_index: u32,
    @location(6) @interpolate(flat) normal_texture_index: u32,
    @location(7) @interpolate(flat) material_ambient: f32,
    @location(8) @interpolate(flat) material_diffuse: f32,
    @location(9) @interpolate(flat) material_roughness: f32,
    @location(10) @interpolate(flat) material_metallic: f32,
    @location(11) @interpolate(flat) material_emissive: vec4<f32>,
    @location(12) @interpolate(flat) material_emissive_strength: f32,
};

@vertex
fn vertex_main(@builtin(vertex_index) vertex_index: u32) -> VertexOut {
    let triangle = triangles[vertex_index / 3u];
    let local = vertex_index % 3u;
    var vertex = triangle.a;
    if (local == 1u) {
        vertex = triangle.b;
    }
    if (local == 2u) {
        vertex = triangle.c;
    }

    var out: VertexOut;
    out.clip_position = vec4<f32>(vertex.x, vertex.y, vertex.z, 1.0);
    out.color = unpack_color(vertex.rgba);
    out.base_color = unpack_color(vertex.base_rgba);
    out.world_position = vec3<f32>(vertex.world_x, vertex.world_y, vertex.world_z);
    out.uv = vec2<f32>(vertex.u, vertex.v);
    out.normal = vec3<f32>(vertex.nx, vertex.ny, vertex.nz);
    out.texture_index = triangle.texture_index;
    out.normal_texture_index = triangle.normal_texture_index;
    out.material_ambient = triangle.material_ambient;
    out.material_diffuse = triangle.material_diffuse;
    out.material_roughness = triangle.material_roughness;
    out.material_metallic = triangle.material_metallic;
    out.material_emissive = unpack_color(triangle.material_emissive);
    out.material_emissive_strength = triangle.material_emissive_strength;
    return out;
}

@fragment
fn fragment_main(in: VertexOut) -> @location(0) vec4<f32> {
    if (lighting_enabled == 0u) {
        return in.color * sample_texture(in.texture_index, in.uv);
    }
    let base = in.base_color * sample_texture(in.texture_index, in.uv);
    let normal = sample_normal(in.normal_texture_index, in.uv, in.normal);
    return apply_material_color(base, light_intensity(normal, in.world_position, in), in);
}
