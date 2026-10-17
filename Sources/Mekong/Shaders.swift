/// The whole visual is one fullscreen fragment shader, compiled from source at
/// launch (a Swift Package can't build .metal files without full Xcode).
///
/// The monochrome scenes return a single 0…1 value per pixel — pure
/// luminance, crisp edges, hashed data — tinted by the palette afterwards.
/// The colour scenes (Scratch, Ribbons) return RGB and are softer. The audio
/// only drives density, timing, colour and change. Sizes scale with
/// `height / 1080`, so the small preview and a 1080p projector look the same.
///
/// Over everything sits the CRT presence: in silence the picture collapses to
/// a horizontal line, then a dot, then black, and opens the same way back.
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
        float presence, pad1, pad2, pad3;
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

    inline float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        return mix(mix(h21(i), h21(i + float2(1, 0)), w.x),
                   mix(h21(i + float2(0, 1)), h21(i + float2(1, 1)), w.x), w.y);
    }

    // Painted grounds and scratch inks for Scratch: muted film-dye colours.
    constant float3 lyeGround[6] = {
        float3(0.78, 0.55, 0.20), float3(0.70, 0.30, 0.22), float3(0.15, 0.45, 0.48),
        float3(0.18, 0.20, 0.45), float3(0.45, 0.50, 0.22), float3(0.45, 0.20, 0.38)
    };
    constant float3 lyeInk[6] = {
        float3(0.96, 0.92, 0.80), float3(0.92, 0.30, 0.18), float3(0.98, 0.85, 0.30),
        float3(0.40, 0.80, 0.85), float3(0.95, 0.55, 0.65), float3(0.05, 0.05, 0.06)
    };

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

    // 4 — Scratch: after Len Lye's direct-on-film work. Boiling painted
    // ground, hand-scratched lines that tremble frame to frame, zigzags that
    // dance with the mids, rings thrown out by attacks, grain and dust. The
    // whole thing steps at 12 fps with gate weave, like projected film.
    float3 scratch(float2 px, constant U& u, constant float* b) {
        float k = u.height / 1080.0;
        float2 res = float2(u.width, u.height);
        float frame = floor(u.time * 12.0);
        float2 weave = (float2(h11(frame * 1.3), h11(frame * 2.7)) - 0.5) * float2(3.0, 5.0) * k;
        float2 q = px + weave;
        float2 uv = q / res;
        float era = u.seed;

        int ia = int(h11(era * 0.37 + 0.1) * 6.0) % 6;
        int ib = (ia + 1 + int(h11(era * 0.91 + 0.3) * 5.0)) % 6;
        float paint = smoothstep(0.25, 0.75, vnoise(uv * float2(3.0, 2.0) + float2(0.0, frame * 0.37)));
        float3 col = mix(lyeGround[ia], lyeGround[ib], paint) * (0.25 + 0.6 * u.level);

        // Scratched verticals.
        for (int i = 0; i < 8; i++) {
            float fi = float(i);
            if (fi >= 2.0 + u.level * 6.0) break;
            float bv = band(b, fi * 4.0 + 2.0);
            float base = 0.06 + 0.88 * h11(fi * 7.1 + floor(era / 2.0) * 0.3);
            float wob = sin(uv.y * (6.0 + fi * 2.0) * 3.14159 + frame * 1.7 + fi) * (0.004 + 0.03 * bv)
                      + (vnoise(float2(uv.y * 20.0, frame + fi * 10.0)) - 0.5) * 0.012;
            float d = abs(uv.x - (base + wob)) * u.width;
            float halfw = (1.0 + 3.5 * bv) * k;
            float line = 1.0 - smoothstep(halfw, halfw + 1.5 * k, d);
            line *= step(0.18, vnoise(float2(fi * 3.0, uv.y * 8.0 + frame * 0.5)));
            float3 ink = lyeInk[int(h11(fi * 5.3 + era) * 6.0) % 6];
            col = mix(col, ink, line * (0.6 + 0.4 * bv));
        }

        // Zigzags, Lambeth Walk style.
        for (int j = 0; j < 2; j++) {
            float fj = float(j);
            float tri = abs(fract(uv.x * (5.0 + fj * 3.0) + u.scroll * (2.0 - fj * 3.0)) - 0.5) * 2.0;
            float y = 0.32 + 0.36 * fj + (tri - 0.5) * (0.02 + 0.12 * u.mid);
            float d = abs(uv.y - y) * u.height;
            float l = 1.0 - smoothstep(2.0 * k, 3.5 * k, d);
            col = mix(col, lyeInk[(2 + j * 2) % 6], l * smoothstep(0.15, 0.45, u.level));
        }

        // A ring thrown out by each attack.
        float2 rc = (float2(h11(era * 1.7), h11(era * 2.9)) * 0.8 + 0.1) * res;
        float rr = (1.0 - u.onset) * 0.35 * u.height + 20.0 * k;
        float rd = abs(length(q - rc) - rr);
        float ring = (1.0 - smoothstep(3.0 * k, 5.5 * k, rd)) * u.onset;
        col = mix(col, lyeInk[int(h11(era * 4.1) * 5.0) % 6], ring);

        // Grain, dust, a soft projector falloff.
        col += (h21(floor(q / (2.0 * k)) + frame * 13.0) - 0.5) * 0.06;
        col = mix(col, float3(0.95, 0.92, 0.85), step(0.9993, h21(floor(q / (3.0 * k)) + frame * 7.0)));
        float2 vc = uv - 0.5;
        col *= 1.0 - dot(vc, vc) * 0.7;
        return clamp(col, 0.0, 1.0);
    }

    // 5 — Ribbons: vertical streaks of coloured light flying outward from
    // the centre in perspective, brightened by their band, surging on attacks.
    float3 ribbons(float2 px, constant U& u, constant float* b) {
        float k = u.height / 1080.0;
        float cx = u.width * 0.5;
        float3 col = float3(0.0);
        for (int i = 0; i < 52; i++) {
            float fi = float(i);
            float z = fract(h11(fi * 3.7 + 1.3) + u.scroll * 0.6);
            float side = h11(fi * 9.1) > 0.5 ? 1.0 : -1.0;
            float persp = z * z * z;
            float x = cx + side * (0.01 + persp) * u.width * 0.6 * (0.4 + 0.6 * h11(fi * 5.5));
            float w = (0.6 + 22.0 * persp) * k * (0.5 + h11(fi * 2.2));
            float d = (px.x - x) / w;
            float d2 = d * d;
            if (d2 > 30.0) continue;
            float bv = band(b, fi);
            float fade = smoothstep(0.0, 0.15, z) * (1.0 - smoothstep(0.85, 1.0, z));
            float surge = u.onset * step(0.55, h11(fi + u.seed));
            float amp = fade * (0.3 + 1.3 * bv + 0.9 * surge);
            float hcol = h11(fi * 1.9 + 0.4);
            float3 hue = 0.5 + 0.5 * cos(6.28318 * (hcol * 0.75 + float3(0.0, 0.33, 0.67) + 0.85));
            col += hue * exp(-d2) * amp * 0.55 + exp(-d2 * 10.0) * amp * 0.2;
        }
        col *= 0.85 + 0.15 * sin(px.y / u.height * 3.14159);
        return 1.0 - exp(-col * 1.4);
    }

    float3 shade(int s, float2 px, constant U& u, constant float* b) {
        if (s == 4) return scratch(px, u, b) * u.intensity;
        if (s == 5) return ribbons(px, u, b) * u.intensity;
        float v;
        switch (s) {
            case 0: v = barcode(px, u, b); break;
            case 1: v = grid(px, u, b); break;
            case 2: v = horizon(px, u, b); break;
            default: v = interference(px, u, b); break;
        }
        v = clamp(v * u.intensity, 0.0, 1.0);
        if (u.palette > 1.5) return float3(1.0 - v);
        if (u.palette > 0.5) return v * float3(0.55, 0.86, 0.96);
        return float3(v);
    }

    fragment float4 fmain(VOut in [[stage_in]],
                          constant U& u [[buffer(0)]],
                          constant float* b [[buffer(1)]]) {
        float2 res = float2(u.width, u.height);
        float2 px = floor(in.pos.xy);
        float k = u.height / 1080.0;
        float p = u.presence;
        if (p <= 0.0005) return float4(0.0, 0.0, 0.0, 1.0);

        // CRT presence: a dot grows into a line (first 40 %), the line opens
        // into the picture (the rest). Collapse runs the same path backwards.
        float2 c = floor(res * 0.5);
        float2 d = px - c;
        float sx = smoothstep(0.0, 0.4, p);
        float sy = smoothstep(0.4, 1.0, p);
        float halfW = max(sx * res.x * 0.5, 1.5 * k);
        float halfH = max(sy * res.y * 0.5, 1.5 * k);

        float3 col = float3(0.0);
        if (abs(d.x) <= halfW && abs(d.y) <= halfH) {
            float2 spx = p >= 1.0 ? px
                       : clamp(floor(c + d / float2(max(sx, 0.001), max(sy, 0.001))), float2(0.0), res - 1.0);
            col = shade(int(u.sceneA), spx, u, b);
            if (u.mixAB > 0.0) col = mix(col, shade(int(u.sceneB), spx, u, b), u.mixAB);
            col = mix(col, float3(1.0), (1.0 - sy) * 0.85);   // the collapsed beam burns white
        }
        if (p < 1.0) {
            float fadeIn = smoothstep(0.0, 0.12, p);
            float lineGlow = exp(-abs(d.y) / (5.0 * k)) * step(abs(d.x), halfW) * (1.0 - sy);
            float dotGlow = exp(-length(d) / (9.0 * k)) * (1.0 - sx);
            col += (lineGlow * 0.35 + dotGlow * 0.7) * fadeIn;
        }

        col = mix(col, 1.0 - col, u.flash);
        return float4(clamp(col, 0.0, 1.0) * u.master, 1.0);
    }
    """
}
