#include <metal_stdlib>
using namespace metal;

// Horizon frame throughout: x = north, y = west, z = zenith (SkyCore's HOR).
// Must match `Uniforms` in Renderer.swift field for field.
struct Uniforms {
    float4x4 viewProj;      // horizon direction (w = 1) → clip
    float4x4 invViewProj;   // clip → horizon ray
    float3x3 eqjToHor;      // J2000 catalog → horizon
    float3 beta;            // Earth velocity / c, J2000 (annual aberration)
    float3 sunDir;          // horizon frame
    float2 viewport;        // drawable pixels
    float pxPerDeg;         // drawable pixels per degree at the centre of view
    float limitMag;         // faintest star drawn
    float darkness;         // 0 = daylight … 1 = astronomical night
    float scale;            // drawable pixels per point
};

struct StarGPU {
    packed_float3 dir;
    float mag;
    float bv;
};

struct GlowGPU {            // bodies and satellites, in the horizon frame; 48 bytes
    packed_float3 dir;
    float radiusPx;
    packed_float4 color;
    packed_float4 phase;    // Moon only: screen direction to the Sun (x, y), cos(phase angle), 1 = apply
};

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float sharpness;
    float4 phase;
};

// --- shared helpers ---------------------------------------------------------

static float radians(float d) { return d * (M_PI_F / 180.0); }
static float degrees(float r) { return r * (180.0 / M_PI_F); }

// Bennett's refraction, as the eye sees it: lifts objects near the horizon.
static float3 refractHorizon(float3 v) {
    float alt = degrees(asin(clamp(v.z, -1.0, 1.0)));
    if (alt < -1.5 || alt > 85.0) return v;
    float r = 1.0 / tan(radians(alt + 7.31 / (alt + 4.4))) / 60.0;
    float na = radians(alt + r);
    float2 h = normalize(v.xy);
    return float3(h * cos(na), sin(na));
}

static float4 offscreen() { return float4(0, 0, 2, 1); }

static float2 corner(uint vid) {
    return float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
}

// B−V colour index → a gentle, eye-like tint (blue-white … orange), not a
// physical blackbody: saturated star colours read as cartoonish.
static float3 starTint(float bv) {
    float t = clamp((bv + 0.3) / 2.0, 0.0, 1.0);
    float3 blue = float3(0.72, 0.82, 1.0);
    float3 white = float3(1.0, 0.98, 0.94);
    float3 orange = float3(1.0, 0.78, 0.55);
    return t < 0.3 ? mix(blue, white, t / 0.3) : mix(white, orange, (t - 0.3) / 0.7);
}

// Height of the land in degrees along an azimuth (radians): low rolling hills
// with a ragged treeline, so the horizon reads as ground, not a cut.
// Low, like Star Walk's distant ridgeline. Mirrored in SkyView.swift.
static float terrainHeight(float az) {
    float h = 0.75;
    h += 0.45 * sin(az * 2.0 + 0.7) + 0.3 * sin(az * 5.0 + 2.1) + 0.2 * sin(az * 11.0 + 0.4);
    h += 0.12 * sin(az * 37.0 + 1.3) + 0.08 * sin(az * 71.0 + 4.0) + 0.05 * sin(az * 143.0);
    return max(h, 0.25);
}

// J2000 equatorial → galactic (IAU), as columns.
constant float3x3 eqjToGal = float3x3(
    float3(-0.0548755604, 0.4941094279, -0.8676661490),
    float3(-0.8734370902, -0.4448296300, -0.1980763734),
    float3(-0.4838350155, 0.7469822445, 0.4559837762));

static float3 rayAt(float2 ndc, constant Uniforms &u) {
    float4 p = u.invViewProj * float4(ndc, 1.0, 1.0);
    return normalize(p.xyz / p.w);
}

// --- full-screen sky and ground --------------------------------------------

struct ScreenOut {
    float4 position [[position]];
    float2 ndc;
};

vertex ScreenOut screenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;   // one oversized triangle
    ScreenOut o;
    o.position = float4(p, 0, 1);
    o.ndc = p;
    return o;
}

fragment float4 skyFragment(ScreenOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                            texture2d<float> milkyWay [[texture(0)]]) {
    float3 d = rayAt(in.ndc, u);
    float alt = asin(clamp(d.z, -1.0, 1.0));
    float up = clamp(alt / 1.2, 0.0, 1.0);

    // night: Star Walk's flat deep blue (0,0,55), a touch violet toward the zenith
    float3 night = mix(float3(0.0, 0.0, 0.216), float3(0.022, 0.006, 0.275), pow(clamp(alt / 1.57, 0.0, 1.0), 1.5));

    // Milky Way: ESO's panorama with the stars removed, in galactic coordinates,
    // tinted Star Walk lavender. The catalog frame barely moves, so the inverse
    // of eqjToHor (a rotation) is its transpose.
    float3 g = eqjToGal * (transpose(u.eqjToHor) * d);
    float2 uv = float2(0.5 - atan2(g.y, g.x) / (2.0 * M_PI_F), 0.5 - asin(clamp(g.z, -1.0, 1.0)) / M_PI_F);
    constexpr sampler mwSampler(filter::linear, address::repeat);
    float mw = milkyWay.sample(mwSampler, uv, level(0)).r;
    night += float3(0.30, 0.27, 0.46) * mw * 0.5;

    // day and twilight
    float3 dayZenith = float3(0.16, 0.38, 0.78);
    float3 dayHorizon = float3(0.55, 0.72, 0.92);
    float3 day = mix(dayHorizon, dayZenith, pow(up, 0.5));
    float sunAlt = asin(clamp(u.sunDir.z, -1.0, 1.0));
    float towardSun = max(dot(normalize(d.xy + 1e-6), normalize(u.sunDir.xy + 1e-6)), 0.0);
    float twilight = smoothstep(radians(-14.0), radians(-2.0), sunAlt) * (1.0 - smoothstep(radians(4.0), radians(12.0), sunAlt));
    float3 glow = float3(0.95, 0.52, 0.28) * pow(towardSun, 3.0) * exp(-max(alt, 0.0) * 5.0) * twilight;

    float3 c = mix(day, night, u.darkness) + glow * 0.8;
    // sun disc + aureole in daylight
    float sd = dot(d, u.sunDir);
    c += float3(1.0, 0.95, 0.85) * (smoothstep(0.99996, 0.99999, sd) + 0.25 * pow(max(sd, 0.0), 400.0)) * (1.0 - u.darkness);
    return float4(c, 1);
}

fragment float4 groundFragment(ScreenOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                               constant float &fade [[buffer(1)]]) {
    float3 d = rayAt(in.ndc, u);
    float alt = degrees(asin(clamp(d.z, -1.0, 1.0)));
    float az = atan2(-d.y, d.x);
    float edge = terrainHeight(az);
    float aa = 1.5 / u.pxPerDeg;                         // ~1.5 px of antialiasing
    float cover = 1.0 - smoothstep(edge - aa, edge + aa, alt);
    if (cover <= 0.0) discard_fragment();
    // the ridge is solid; below the true horizon is Star Walk's dark lake,
    // translucent so whatever has set still shows through, dimmed
    float lake = smoothstep(-aa, aa, -alt);
    float3 ridge = mix(float3(0.20, 0.27, 0.18), float3(0.031, 0.043, 0.125), u.darkness);
    float3 water = mix(float3(0.10, 0.16, 0.22), float3(0.012, 0.03, 0.19), u.darkness);
    float3 c = mix(ridge, water, lake);
    float a = mix(1.0, 0.55, lake);
    // a faint lit rim along the top of the ridge
    c += float3(0.05, 0.06, 0.12) * (1.0 - smoothstep(0.0, 4.0 * aa, edge - alt)) * (1.0 - lake);
    return float4(c, cover * a * fade);      // fade < 1 while looking through the Earth at a target
}

// --- stars ------------------------------------------------------------------

vertex SpriteOut starVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device StarGPU *stars [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    StarGPU s = stars[iid];
    SpriteOut o;
    float rel = u.limitMag - s.mag;                      // > 0: brighter than the limit
    float3 e = float3(s.dir);
    e = normalize(e + u.beta - dot(e, u.beta) * e);
    float4 clip = u.viewProj * float4(refractHorizon(u.eqjToHor * e), 1);
    if (rel <= 0 || clip.w <= 0) { o.position = offscreen(); return o; }

    // size and brightness both grow with how far above the limit a star is;
    // the brightest few get a wide halo that's what makes them read as glowing
    float radius = clamp(1.3 + 0.75 * rel + 0.13 * rel * rel, 1.3, 22.0);
    radius = (radius + smoothstep(3.0, 6.0, rel) * radius * 0.8) * u.scale;   // room for the sparkle
    float alpha = clamp(0.2 + rel / 2.5, 0.2, 1.0) * u.darkness;
    float2 c = corner(vid);
    clip.xy += c * radius * 2.0 / u.viewport * clip.w;
    o.position = clip;
    o.uv = c;
    o.color = float4(starTint(s.bv) * alpha, alpha);
    o.sharpness = clamp(rel / 6.0, 0.0, 1.0);
    return o;
}

fragment float4 starFragment(SpriteOut in [[stage_in]]) {
    float r2 = dot(in.uv, in.uv);
    if (r2 > 1.0) discard_fragment();
    // faint stars fill their little quad; bright ones are a hot core in a wide
    // halo with Star Walk's four-point sparkle
    float core = exp(-r2 * mix(2.5, 40.0, in.sharpness));
    float halo = exp(-r2 * 5.0) * 0.3 * in.sharpness;
    float2 a = abs(in.uv);
    float spikes = (exp(-a.y * 60.0) * (1.0 - a.x) + exp(-a.x * 60.0) * (1.0 - a.y));
    spikes *= smoothstep(0.45, 0.9, in.sharpness) * 0.8;
    return in.color * (core * 1.4 + halo + spikes);
}

// --- glows: Milky Way blobs and solar-system bodies --------------------------

vertex SpriteOut glowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device GlowGPU *glows [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]],
                            constant uint &catalogFrame [[buffer(2)]]) {
    GlowGPU g = glows[iid];
    SpriteOut o;
    float3 h = catalogFrame ? u.eqjToHor * float3(g.dir) : float3(g.dir);
    float4 clip = u.viewProj * float4(refractHorizon(h), 1);
    if (clip.w <= 0) { o.position = offscreen(); return o; }
    // radius is in degrees for catalog glows (they scale with zoom), pixels for bodies
    float radius = catalogFrame ? g.radiusPx * u.pxPerDeg : g.radiusPx * u.scale;
    float2 c = corner(vid);
    clip.xy += c * radius * 2.0 / u.viewport * clip.w;
    o.position = clip;
    o.uv = c;
    o.color = float4(g.color) * (catalogFrame ? u.darkness : 1.0);
    o.sharpness = catalogFrame ? 0.0 : 1.0;
    o.phase = float4(g.phase);
    return o;
}

fragment float4 glowFragment(SpriteOut in [[stage_in]]) {
    float r2 = dot(in.uv, in.uv);
    if (r2 > 1.0) discard_fragment();
    // bodies: a crisp disc with a soft rim; Milky Way: a broad gaussian
    float disc = in.sharpness > 0.5 ? (1.0 - smoothstep(0.30, 0.42, r2)) + 0.35 * exp(-r2 * 3.0) : exp(-r2 * 3.0);
    if (in.phase.w > 0.5) {
        // the Moon: lit where x (toward the Sun) clears the terminator ellipse,
        // x > −cos(i)·√(1−y²); a faint earthshine on the rest, mild limb darkening
        float2 p = in.uv / 0.6;
        float rr = dot(p, p);
        float2 sunward = normalize(in.phase.xy + 1e-5);
        float x = dot(p, sunward), y = dot(p, float2(-sunward.y, sunward.x));
        float edge = -in.phase.z * sqrt(max(0.0, 1.0 - y * y));
        float lit = smoothstep(edge - 0.04, edge + 0.04, x);
        float body = (1.0 - smoothstep(0.92, 1.05, rr)) * (0.78 + 0.22 * sqrt(max(0.0, 1.0 - rr)));
        float glow = 0.25 * exp(-r2 * 3.0) * (1.0 + in.phase.z) / 2.0;   // halo ∝ lit fraction
        return in.color * (body * mix(0.07, 1.0, lit) + glow);
    }
    return in.color * disc;
}

// --- constellation figures ---------------------------------------------------

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut lineVertex(uint vid [[vertex_id]],
                          const device packed_float3 *dirs [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]],
                          constant float &brightness [[buffer(2)]]) {
    LineOut o;
    // left unclipped on purpose: the near plane trims segments that run behind the camera
    o.position = u.viewProj * float4(refractHorizon(u.eqjToHor * float3(dirs[vid])), 1);
    o.color = float4(0.55, 0.62, 0.85, 1.0) * brightness;
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) { return in.color; }

// --- night mode ---------------------------------------------------------------

// Last pass: everything drawn so far, read back from the tile (Apple GPUs'
// framebuffer fetch) and redrawn as red at its own brightness, so the screen
// doesn't spoil eyes adapted to the dark.
fragment float4 nightFragment(ScreenOut in [[stage_in]], float4 dst [[color(0)]]) {
    // steeper than linear: the sky's glow sinks toward black, stars and the Moon stay
    float l = 0.9 * pow(dot(dst.rgb, float3(0.30, 0.59, 0.11)), 1.4);
    return float4(l, l * 0.05, 0, 1);
}
