/*
 * The fragment shader below is ported from @craftedstudios/shaders 1.0.1
 * (https://shaders.craftedstudios.co, src/shader.js), the avatar half only,
 * by way of happy-ios's Metal port (AvatarShaderSource.swift).
 *
 * MIT License, Copyright (c) 2026 Crafted Studios. Its full text is
 * assets/avatar-placeholders/LICENSE-craftedstudios-shaders.txt.
 *
 * Changes from the original: GLSL ES to AGSL; only the five effects an
 * avatar's seed can pick (no metals) and no outlines; no goo, pointer
 * interaction, entrance or ring, so an avatar fills its square and its
 * clip shapes it; GLSL's smoothstep (which allows edges in either order)
 * written out; loops counted in ints, as AGSL wants; names AGSL reserves
 * (layout, line, blend, noise) renamed; a Black & White mode.
 */
package com.slopus.happy.ui.components.avatar

internal const val AVATAR_SHADER_AGSL = """
uniform float3 col1;
uniform float3 col2;
uniform float3 col3;
uniform float3 col4;
uniform float4 seedLayout; // per-seed pattern offset (xy), turn (z) and zoom (w)
uniform float2 turn;       // cos and sin of the turn, worked out exactly on the CPU
uniform float fx;          // which effect: 0 linear, 1 thermal, 2 topography, 3 plasma, 4 radial
uniform float t;           // seconds, phase included
uniform float angle;       // per-seed angle for effects that have a direction
uniform float warp;        // distortion: 1 is each effect's own amount
uniform float scale;       // pattern zoom
uniform float grain;
uniform float grainCell;
uniform float mono;        // 1 drains the colour
uniform float2 size;       // px

// GLSL's smoothstep, which runs either way between its edges.
float sstep(float e0, float e1, float x) {
  float k = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
  return k * k * (3.0 - 2.0 * k);
}

// sin of large arguments, worked out in plain float arithmetic: the hash
// below multiplies sin by 43758.5 and keeps the fraction, so a GPU's own
// approximate sin of an argument in the thousands would give other noise
// than the pictures were drawn with (happy-ios uses precise::sin for this).
// The argument is reduced by 2π split in two (Cody–Waite), folded into
// [-π/2, π/2], and a degree-11 Taylor series finishes it.
float psin(float x) {
  float k = floor(x * 0.15915494309189535 + 0.5);
  float r = x - k * 6.28125;
  r -= k * 0.0019353071795864769;
  if (r > 1.5707963267948966) r = 3.141592653589793 - r;
  if (r < -1.5707963267948966) r = -3.141592653589793 - r;
  float r2 = r * r;
  return r * (1.0 + r2 * (-1.0 / 6.0 + r2 * (1.0 / 120.0 + r2 * (-1.0 / 5040.0 + r2 * (1.0 / 362880.0 + r2 * (-1.0 / 39916800.0))))));
}

float hash21(float2 p) { return fract(psin(dot(p, float2(41.3, 289.1))) * 43758.5); }
float vnoise(float2 p) {
  float2 i = floor(p);
  float2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}

float rfHash12(float2 p) {
  float3 p3 = fract(p.xyx * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}
float rfFilmGrain(float2 px, float3 col) {
  float k = floor(fract(t * 0.731) * 240.0);
  float n = rfHash12(floor(px / grainCell) + float2(k * 17.0, k * 9.0));
  float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
  float resp = mix(0.35, 1.0, sstep(0.0, 0.22, luma)) * (1.0 - 0.8 * sstep(0.72, 1.0, luma));
  return (n - 0.5) * resp * 1.5;
}

float3 toLab(float3 c) {
  c = pow(max(c, 0.0), float3(2.2));
  float3 lms = pow(float3(
    0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b,
    0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b,
    0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b), float3(1.0 / 3.0));
  return float3(
    0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
    1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
    0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z);
}
float3 fromLab(float3 L) {
  float3 lms = float3(
    L.x + 0.3963377774 * L.y + 0.2158037573 * L.z,
    L.x - 0.1055613458 * L.y - 0.0638541728 * L.z,
    L.x - 0.0894841775 * L.y - 1.2914855480 * L.z);
  lms = lms * lms * lms;
  float3 c = float3(
    4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
    -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
    -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z);
  return pow(clamp(c, 0.0, 1.0), float3(1.0 / 2.2));
}

float3 labMix(float3 a, float3 b, float k) {
  return fromLab(mix(toLab(a), toLab(b), k));
}

float3 steps4(float g, float3 c1, float3 c2, float3 c3, float3 c4) {
  if (g < 0.34) return c1;
  if (g < 0.57) return labMix(c1, c2, sstep(0.34, 0.57, g));
  if (g < 0.59) return c2;
  if (g < 0.76) return labMix(c2, c3, sstep(0.59, 0.76, g));
  if (g < 0.78) return c3;
  if (g < 0.93) return labMix(c3, c4, sstep(0.78, 0.93, g));
  return c4;
}

float2 rot2(float2 v, float a) { float c = cos(a); float s = sin(a); return float2(v.x * c - v.y * s, v.x * s + v.y * c); }
// A turn by a known cosine and sine. What feeds the noise turns by exact
// values: a GPU's own cos and sin are close, but the noise magnifies any
// difference into other noise.
float2 rotCS(float2 v, float c, float s) { return float2(v.x * c - v.y * s, v.x * s + v.y * c); }

float3 fxPlasma(float2 uv, float tt, float3 c1, float3 c2, float3 c3, float3 c4) {
  tt *= 0.15;
  float2 p = uv * 1.8;
  for (int n = 1; n <= 3; n++) {
    float i = float(n);
    p.x += 0.16 * warp / i * sin(i * 1.7 * p.y + tt * 0.9 + i * 0.3);
    p.y += 0.16 * warp / i * cos(i * 2.1 * p.x + tt * 1.1 - i * 0.5);
  }
  float v = sin(p.x * 3.0 + tt) + sin(p.y * 2.7 - tt * 0.7) + sin((p.x + p.y) * 2.3 + tt * 0.5);
  float2 c = p - 0.9;
  v += sin(length(c) * 4.0 - tt * 1.3);
  v += 0.7 * sin(p.x * 1.8 - p.y * 2.5 + tt * 0.8) + 0.5 * sin(rot2(p, 0.7).x * 3.5 + tt * 0.4);
  v = v / 5.2 * 0.5 + 0.5;
  float g = fract(v * 1.5);
  if (g > 0.88) return labMix(c4, c1, sstep(0.88, 1.0, g));
  return steps4(g / 0.88, c1, c2, c3, c4);
}

float3 fxLinear(float2 uv, float tt, float3 c1, float3 c2, float3 c3, float3 c4) {
  tt *= 0.15;
  float2 p = uv;
  for (int n = 1; n <= 2; n++) {
    float i = float(n);
    p.x += 0.12 * warp / i * sin(i * 5.1 * p.y + tt * 0.9 + i * 0.3);
    p.y += 0.12 * warp / i * cos(i * 6.3 * p.x + tt * 1.1 - i * 0.5);
  }
  float g = clamp((p.x - 0.5) * cos(angle) + (p.y - 0.5) * sin(angle) + 0.5, 0.0, 1.0);
  return steps4(g, c1, c2, c3, c4);
}

float3 fxRadial(float2 uv, float tt, float3 c1, float3 c2, float3 c3, float3 c4) {
  tt *= 0.15;
  float g = clamp(length(uv - 0.5) * 2.0 / 1.2, 0.0, 1.0);
  float n = vnoise(uv * 3.0 + tt * 0.4) + vnoise(uv * 2.5 - tt * 0.3 + 50.0) - 1.0;
  return steps4(1.0 - clamp(g + n * 0.15 * warp * sstep(1.0, 0.6, g), 0.0, 1.0), c1, c2, c3, c4);
}

float3 fxThermal(float2 uv, float tt, float3 c1, float3 c2, float3 c3, float3 c4) {
  tt *= 0.15;
  float light = 0.0;
  for (int k = 0; k < 2; k++) {
    float fk = float(k);
    float x = uv.x * (1.0 + fk * 0.4) + fk * 5.3;
    float mid = mix(0.62, 0.34, fk)
      + (mix(0.12, 0.08, fk) * sin(x * 2.0 + tt * (0.8 + fk * 0.3) + fk * 2.0)
      + 0.04 * sin(x * 4.7 - tt * 1.2 + fk)
      + 0.07 * (vnoise(float2(x * 1.4, tt * 0.3 + fk * 4.0)) - 0.5)) * warp;
    float thick = mix(0.13, 0.09, fk) * (0.75 + 0.5 * vnoise(float2(x * 1.8 - tt * 0.3, fk * 5.0)));
    float d = mid - uv.y;
    float ray = 0.75 + 0.5 * vnoise(float2(x * 9.0 + tt * 0.5, fk * 9.0));
    float up = thick * 1.6 * ray;
    float down = thick * 0.7;
    float body = d > 0.0 ? exp(-pow(d / up, 1.6)) : exp(-pow(abs(d) / down, 2.0));
    float fold = 0.8 + 0.2 * vnoise(float2(x * 2.2 - tt * 0.4, fk * 6.0));
    light = 1.0 - (1.0 - light) * (1.0 - clamp(body * fold * mix(1.0, 0.6, fk), 0.0, 1.0));
  }
  return steps4(light, c1, c2, c3, c4);
}

float topoFbm(float2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 6; i++) { p = rotCS(p, 0.8253356149096783, 0.5646424733950354); v += a * vnoise(p); p *= 2.0; a *= 0.5; }
  return v;
}
float3 fxTopo(float2 uv, float tt, float3 lineC, float3 fillC, float3 ground) {
  tt *= 0.15;
  float2 p = uv * 1.6;
  p += float2(topoFbm(p + tt * 0.3), topoFbm(p + float2(5.2, 1.3) + tt * 0.2)) * 0.3 * warp;
  float e = topoFbm(p + tt * 0.1);
  float se = e * 6.0;
  float ld = min(fract(se), 1.0 - fract(se));
  float l = 1.0 - sstep(0.04, 0.14, ld);
  float3 fill = mix(ground, fillC, e * 0.6);
  return mix(fill, lineC, l);
}

float3 paint(float2 uv, float2 ua) {
  if (fx < 0.5) return fxLinear(uv, t, col1, col2, col3, col4);
  if (fx < 1.5) return fxThermal(ua, t, col1, col2, col3, col4);
  if (fx < 2.5) return fxTopo(uv, t, col1, col2, col3);
  if (fx < 3.5) return fxPlasma(uv, t, col1, col2, col3, col4);
  return fxRadial(uv, t, col1, col2, col3, col4);
}

half4 main(float2 px) {
  float r = size.x * 0.5;
  float2 uv = (px - r) / (r * 2.0 * scale) + 0.5;
  // Each seed sees its own part of the pattern. Thermal only slides
  // sideways and zooms, so it stays upright.
  float2 ua = (uv - 0.5) / seedLayout.w + 0.5 + float2(seedLayout.x, 0.0);
  uv = rotCS(uv - 0.5, turn.x, turn.y) / seedLayout.w + 0.5 + seedLayout.xy;
  float3 c = paint(uv, ua);
  c += rfFilmGrain(px, c) * grain;
  c = clamp(c, 0.0, 1.0);
  if (mono > 0.5) c = float3(dot(c, float3(0.299, 0.587, 0.114)));
  return half4(half3(c), 1.0);
}
"""
