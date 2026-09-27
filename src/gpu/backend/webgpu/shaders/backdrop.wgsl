// Appended to ui_primitives.wgsl: shares its bindings, sdRoundedBox and clipAlpha.
// Group 1 (`atlas_texture`, `atlas_sampler`) is the backdrop source being read.

struct BlurOutput {
    @builtin(position) clip_pos: vec4f,
    @location(0) uv: vec2f,
    @location(1) half_pixel: vec2f,
    @location(2) bounds: vec4f,
}

// One triangle covering the viewport, which is the destination level's region.
// In source UV: `source` is the region's origin and extent, `bounds` clamps taps
// inside it, and `tap` is the tap distance.
@vertex
fn vs_blur(
    @builtin(vertex_index) vid: u32,
    @location(0) source: vec4f,
    @location(1) bounds: vec4f,
    @location(2) tap: vec2f,
) -> BlurOutput {
    let uv = vec2f(f32((vid << 1u) & 2u), f32(vid & 2u));
    var out: BlurOutput;
    out.clip_pos = vec4f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.uv = source.xy + uv * source.zw;
    out.half_pixel = tap;
    out.bounds = bounds;
    return out;
}

fn tap(uv: vec2f, lo: vec2f, hi: vec2f) -> vec4f {
    return textureSampleLevel(atlas_texture, atlas_sampler, clamp(uv, lo, hi), 0.0);
}

// Dual Kawase (Bjørge, SIGGRAPH 2015) downsample.
@fragment
fn fs_blur_down(in: BlurOutput) -> @location(0) vec4f {
    let h = in.half_pixel;
    let lo = in.bounds.xy;
    let hi = in.bounds.zw;
    var sum = tap(in.uv, lo, hi) * 4.0;
    sum += tap(in.uv - h, lo, hi);
    sum += tap(in.uv + h, lo, hi);
    sum += tap(in.uv + vec2f(h.x, -h.y), lo, hi);
    sum += tap(in.uv - vec2f(h.x, -h.y), lo, hi);
    return sum / 8.0;
}

// Dual Kawase upsample.
@fragment
fn fs_blur_up(in: BlurOutput) -> @location(0) vec4f {
    let h = in.half_pixel;
    let lo = in.bounds.xy;
    let hi = in.bounds.zw;
    var sum = tap(in.uv + vec2f(-h.x * 2.0, 0.0), lo, hi);
    sum += tap(in.uv + vec2f(-h.x, h.y), lo, hi) * 2.0;
    sum += tap(in.uv + vec2f(0.0, h.y * 2.0), lo, hi);
    sum += tap(in.uv + vec2f(h.x, h.y), lo, hi) * 2.0;
    sum += tap(in.uv + vec2f(h.x * 2.0, 0.0), lo, hi);
    sum += tap(in.uv + vec2f(h.x, -h.y), lo, hi) * 2.0;
    sum += tap(in.uv + vec2f(0.0, -h.y * 2.0), lo, hi);
    sum += tap(in.uv + vec2f(-h.x, -h.y), lo, hi) * 2.0;
    return sum / 12.0;
}

struct GlassInput {
    @location(0) rect: vec4f,
    @location(1) corner_radius: vec4f,
    // xy = logical origin of the filtered region, zw = its UV per logical pixel.
    @location(2) sample_map: vec4f,
    // x = saturation, y = clip node.
    @location(3) params: vec4f,
    // x = refraction, y = bezel, z = dispersion, w = specular.
    @location(4) optics: vec4f,
}

struct GlassOutput {
    @builtin(position) clip_pos: vec4f,
    @location(0) local: vec2f,
    @location(1) half_size: vec2f,
    @location(2) corner_radius: vec4f,
    @location(3) sample_uv: vec2f,
    @location(4) world_pos: vec2f,
    @location(5) params: vec4f,
    @location(6) uv_per_logical: vec2f,
    @location(7) optics: vec4f,
}

@vertex
fn vs_glass(@builtin(vertex_index) vid: u32, in: GlassInput) -> GlassOutput {
    var corners = array<vec2f, 4>(
        vec2f(0.0, 0.0),
        vec2f(1.0, 0.0),
        vec2f(1.0, 1.0),
        vec2f(0.0, 1.0),
    );
    let corner = corners[vid];
    let world = in.rect.xy + in.rect.zw * corner;
    let ndc = (world / viewport.size) * 2.0 - 1.0;

    var out: GlassOutput;
    out.clip_pos = vec4f(ndc.x, -ndc.y, 0.0, 1.0);
    out.half_size = in.rect.zw * 0.5;
    out.local = world - in.rect.xy - out.half_size;
    out.corner_radius = in.corner_radius;
    out.sample_uv = (world - in.sample_map.xy) * in.sample_map.zw;
    out.world_pos = world;
    out.params = in.params;
    out.uv_per_logical = in.sample_map.zw;
    out.optics = in.optics;
    return out;
}

const GLASS_IOR: f32 = 1.5;

// Lateral shift of a vertical ray refracted by the rim, normalized to 1 at the
// outer edge. `x` runs 0 at the edge to 1 where the bezel meets the flat top;
// the surface there is Apple's convex squircle, h(x) = (1 - (1 - x)^4)^(1/4).
fn refractionProfile(x: f32) -> f32 {
    let u = 1.0 - clamp(x, 0.0, 1.0);
    let run = u * u * u;
    let rise = pow(max(1.0 - u * u * u * u, 1e-6), 0.75);
    let inv = inverseSqrt(run * run + rise * rise);
    let sin_in = run * inv;
    let cos_in = rise * inv;
    let sin_out = sin_in / GLASS_IOR;
    let cos_out = sqrt(1.0 - sin_out * sin_out);
    let shift = (sin_in * cos_out - cos_in * sin_out) / max(cos_in * cos_out + sin_in * sin_out, 1e-4);
    return shift / sqrt(GLASS_IOR * GLASS_IOR - 1.0);
}

fn glassTap(uv: vec2f) -> vec3f {
    return textureSampleLevel(atlas_texture, atlas_sampler, uv, 0.0).rgb;
}

// Pass-through: the source holds the scene's stored encoding, so no conversion.
@fragment
fn fs_glass(in: GlassOutput) -> @location(0) vec4f {
    let d = sdRoundedBox(in.local, in.half_size, in.corner_radius);
    let coverage = 1.0 - smoothstep(-0.5, 0.5, d);

    // Outward edge normal from the distance field's gradient.
    let e = vec2f(0.5, 0.0);
    let gradient = vec2f(
        sdRoundedBox(in.local + e.xy, in.half_size, in.corner_radius) - sdRoundedBox(in.local - e.xy, in.half_size, in.corner_radius),
        sdRoundedBox(in.local + e.yx, in.half_size, in.corner_radius) - sdRoundedBox(in.local - e.yx, in.half_size, in.corner_radius),
    );
    let normal = gradient / max(length(gradient), 1e-5);

    let bezel = in.optics.y;
    let x = select(1.0, -d / max(bezel, 1e-5), bezel > 0.0);
    // Sample inward so content under the rim is magnified outward.
    let shift = normal * (in.optics.x * refractionProfile(x)) * in.uv_per_logical;
    let spread = in.optics.z;
    var color = vec3f(
        glassTap(in.sample_uv - shift * (1.0 + spread)).r,
        glassTap(in.sample_uv - shift).g,
        glassTap(in.sample_uv - shift * (1.0 - spread)).b,
    );

    let luma = dot(color, vec3f(0.2126, 0.7152, 0.0722));
    color = mix(vec3f(luma), color, in.params.x);

    // Rim highlight, strongest on edges facing the top-left light.
    let rim = 1.0 - clamp(x, 0.0, 1.0);
    let facing = abs(dot(normal, vec2f(-0.70710678, -0.70710678)));
    let highlight = clamp(in.optics.w * rim * rim * rim * (0.3 + 0.7 * facing), 0.0, 1.0);
    color = color + (vec3f(1.0) - color) * highlight;

    return vec4f(color, coverage * clipAlpha(in.world_pos, in.params.y));
}
