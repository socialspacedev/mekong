/// The whole visual is one fullscreen fragment shader, compiled from source at
/// launch (a Swift Package can't build .metal files without full Xcode).
///
/// Every scene returns a single 0…1 value per pixel — pure luminance, crisp
/// edges, hashed data — and the audio only drives density, timing and
/// re-scrambling. Sizes scale with `height / 1080`, so the small preview and
/// a 1080p projector look the same.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct U {
        float time, width, height, level;
        float onset, centroid, low, mid;
        float high, seed, flash, density;
        float intensity, master, sceneA, sceneB;
        float mixAB, palette, tick, scroll;
    };

    struct VOut { float4 pos [[position]]; };

    vertex VOut vmain(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    inline float h11(float p) {
        p = fract(p * 0.1031);
        p *= p + 33.33;
        p *= p + p;
        return fract(p);
    }

    inline float h21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    inline float band(constant float* b, float i) {
        return b[int(fmod(fmod(i, 32.0) + 32.0, 32.0))];
    }

    // 0 — Barcode: horizontal strata of hashed vertical lines.
    float barcode(float2 px, constant U& u, constant float* b) {
        float2 res = float2(u.width, u.height);
        float2 uv = px / res;
        float era = floor(u.seed / 3.0);
        float rows = 1.0 + floor(h11(era * 7.13 + 0.5) * 3.0);
        float r = floor(uv.y * rows);
        float rs = r * 17.0 + era * 3.0;
        float n = floor(mix(48.0, 480.0, u.density) * (0.5 + h11(rs + 1.0)));
        float x = uv.x + (h11(u.seed + r) - 0.5) * 0.08 * u.onset;
        float st = floor(u.tick + h11(rs) * 10.0);
        float bv = band(b, r * 7.0 + 3.0);
        float thr = 0.03 + 0.27 * clamp(u.level * 0.4 + bv * 0.6, 0.0, 1.0);
        float fine = step(h21(float2(floor(x * n), st + rs)), thr);
        float wide = step(h21(float2(floor(x * n * 0.13), st * 1.7 + rs + 5.0)), thr * 0.25) * 0.8;
        float v = max(fine, wide);
        float gapPx = fract(uv.y * rows) * res.y / rows;
        return v * step(3.0 * res.y / 1080.0, gapPx);
    }

    // 1 — Grid: rows of cells scrolling like a data feed.
    float grid(float2 px, constant U& u, constant float* b) {
        float k = u.height / 1080.0;
        float cell = max(3.0, floor(mix(30.0, 7.0, u.density) * k));
        float2 g = floor(px / cell);
        float2 f = fract(px / cell);
        float era = floor(u.seed / 4.0);
        float rowSeed = g.y * 3.1 + era * 11.0;
        float dir = h11(rowSeed) > 0.5 ? 1.0 : -1.0;
        float rr = h11(rowSeed + 1.0);
        float x = floor(px.x / cell + u.scroll * dir * (0.2 + 2.5 * rr * rr) * 30.0);
        float bv = band(b, g.y);
        float lit = step(h21(float2(x, g.y + era * 3.0)), 0.06 + 0.75 * bv);
        float dim = 0.4 + 0.6 * step(0.6, h21(float2(x + 0.5, g.y * 1.3)));
        float sq = step(0.14, f.x) * step(f.x, 0.86) * step(0.14, f.y) * step(f.y, 0.86);
        float hlRow = floor(h11(u.seed * 1.37 + 0.2) * floor(u.height / cell));
        float hl = abs(g.y - hlRow) < 0.5 ? u.onset : 0.0;
        return max(lit * dim, hl) * sq;
    }

    // 2 — Horizon: a held centre line that splits into many with level.
    float horizon(float2 px, constant U& u, constant float* b) {
        float k = u.height / 1080.0;
        float cy = u.height * 0.5;
        float v = step(abs(px.y - cy), (0.6 + 2.0 * u.low) * k) * (0.5 + 0.5 * u.level);
        float count = floor(mix(12.0, 40.0, u.density));
        float spread = 0.03 + 0.42 * pow(u.level, 0.8);
        float era = floor(u.seed / 2.0);
        float xu = px.x / u.width;
        for (int i = 0; i < 40; i++) {
            float fi = float(i);
            if (fi >= count) break;
            if (fi / count > u.level * 1.4 + 0.05) break;
            float bv = band(b, fi);
            float ly = cy + (h11(fi * 13.7 + era * 0.91) - 0.5) * 2.0 * spread * u.height;
            float th = (0.5 + 2.5 * bv) * k;
            if (abs(px.y - ly) > th) continue;
            float x0 = h11(fi * 3.1 + era) * 0.6;
            float x1 = x0 + 0.2 + h11(fi * 5.7 + era) * 0.8;
            float seg = step(x0, xu) * step(xu, x1);
            v = max(v, seg * (0.25 + 0.75 * bv));
        }
        return v;
    }

    // 3 — Interference: blocks of stripes, broken into static by attacks.
    float interference(float2 px, constant U& u, constant float* b) {
        float k = u.height / 1080.0;
        float era = floor(u.seed / 2.0);
        float blocks = 3.0 + floor(h11(era * 2.3 + 0.7) * 9.0);
        float bi = floor(px.x / u.width * blocks);
        float bv = band(b, bi * 3.0 + 2.0);
        float period = max(2.0, floor(mix(48.0, 3.0, bv) * k));
        float drift = (h11(bi + era) - 0.5) * 2.0;
        float y = px.y + u.scroll * drift * 400.0 * k;
        float stripe = step(0.5, fract(y / period));
        float nz = step(0.5, h21(floor(px / max(2.0, 2.0 * k)) + floor(u.time * 24.0) * 7.0));
        float noisy = step(h11(bi * 1.7 + u.seed), u.onset * 0.9);
        float v = mix(stripe, nz, noisy);
        float show = step(h11(bi * 7.0 + floor(u.tick * 0.5)), 0.25 + 0.9 * u.level);
        return v * show * (0.55 + 0.45 * bv);
    }

    float scene(int s, float2 px, constant U& u, constant float* b) {
        switch (s) {
            case 0: return barcode(px, u, b);
            case 1: return grid(px, u, b);
            case 2: return horizon(px, u, b);
            default: return interference(px, u, b);
        }
    }

    fragment float4 fmain(VOut in [[stage_in]],
                          constant U& u [[buffer(0)]],
                          constant float* b [[buffer(1)]]) {
        float2 px = floor(in.pos.xy);
        float v = scene(int(u.sceneA), px, u, b);
        if (u.mixAB > 0.0) v = mix(v, scene(int(u.sceneB), px, u, b), u.mixAB);
        v = clamp(v * u.intensity, 0.0, 1.0);
        v = mix(v, 1.0 - v, u.flash);
        float3 c = float3(v);
        if (u.palette > 1.5) c = float3(1.0 - v);
        else if (u.palette > 0.5) c = v * float3(0.55, 0.86, 0.96);
        return float4(c * u.master, 1.0);
    }
    """
}
