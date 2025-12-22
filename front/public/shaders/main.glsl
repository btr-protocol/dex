precision mediump float;

uniform vec2  iResolution;
uniform float iTime;
uniform float uRingCount;
uniform float uVelocityFactor;
uniform float uEyeSize;
uniform float uIsDark;

// Compile-time constants
const int   MAX_RINGS    = 32;
const float DEF_RINGS    = 12.0;
const float DEF_VEL      = 20.0;
const float DEF_EYE      = 0.15;
const float TAU          = 6.2831853;
const float MARGIN       = 0.1;
const float SCALE        = 1.0 / (1.0 - MARGIN);
const float STROKE_WIDTH = 0.0;

// Theme colors
const lowp vec3 DARK_BASE    = vec3(0.16);
const lowp vec3 LIGHT_BASE   = vec3(0.90);
const lowp vec3 DARK_CENTER  = vec3(0.08);
const lowp vec3 LIGHT_CENTER = vec3(0.75);
const lowp vec3 DARK_BORDER  = vec3(0.16);
const lowp vec3 LIGHT_BORDER = vec3(0.87);

// Sin-free hash (fract/mul chain)
float fast_hash(float n) {
    n = fract(n * 0.1031);
    n *= n + 33.33;
    n *= n + n;
    return fract(n);
}

void main() {
    // Aspect-correct UV so circles stay circles, sized by MAX(res.x, res.y)
    vec2  res    = iResolution.xy;
    float maxRes = max(res.x, res.y);
    // Center at (0,0), normalized by max dimension -> circle of radius 1
    // fully swallows the viewport.
    vec2 uv = (gl_FragCoord.xy - 0.5 * res) / maxRes * 2.0;
    // Apply uniform zoom (no aspect distortion)
    uv *= SCALE;

    // Config with clamping
    float ringCount = clamp(uRingCount, DEF_RINGS, float(MAX_RINGS));
    // Allow slowing below default: if <= 0, fall back to DEF_VEL
    float velFactor = ((uVelocityFactor > 0.0) ? uVelocityFactor : DEF_VEL) / 20.0;
    float eyeSize   = uEyeSize > 0.0 ? uEyeSize : DEF_EYE;

    // Theme precompute
    lowp float isDark      = step(0.5, uIsDark);
    lowp vec3  baseColor   = mix(LIGHT_BASE,   DARK_BASE,   isDark);
    lowp vec3  centerColor = mix(LIGHT_CENTER, DARK_CENTER, isDark);
    lowp vec3  borderBase  = mix(LIGHT_BORDER, DARK_BORDER, isDark);

    // Early cull for pixels outside ring area
    float uvLen = length(uv);
    if (uvLen > 1.0 + STROKE_WIDTH * 2.0) {
        gl_FragColor = vec4(baseColor, 1.0);
        return;
    }

    lowp vec3 col = baseColor;
    vec2  center  = vec2(0.0);
    float prevRadius   = 1.0;
    int   intRingCount = int(ringCount);
    float oneOverCount = 1.0 / max(ringCount - 0.5, 1.0);
    float timeScaled   = iTime * 60.0;

    for (int i = 0; i < MAX_RINGS; ++i) {
        if (i >= intRingCount) break;

        float fi = float(i);
        float t  = fi * oneOverCount;

        // Nonlinear spacing: outer rings farther apart, inner rings closer
        // to create a depth impression.
        float s      = 1.0 - t;          // 1 at outer, 0 at inner
        float s2     = s * s;            // bias spacing toward outer
        float radius = eyeSize + (1.0 - eyeSize) * s2;

        if (i > 0) {
            float seed    = fi * 12.9898;
            float randArc = fast_hash(seed) * TAU;
            float randVel = (fast_hash(seed + 2.0) - 0.5) * 0.04602 * velFactor; // 0.000767 * 60.0
            float arc     = randArc + timeScaled * randVel;

            float r_diff = prevRadius - radius;
            center += vec2(cos(arc), sin(arc)) * r_diff;
        }
        prevRadius = radius;

        float dist      = length(uv - center);
        lowp float depth = t;

        lowp vec3 fillColor   = mix(baseColor,  centerColor, depth);
        lowp vec3 strokeColor = mix(borderBase, centerColor, depth * 0.7);

        // Hard fill + independent stroke (original visual behavior)
        col = mix(col, fillColor, step(dist, radius));
        col = mix(col, strokeColor,
                  clamp(1.0 - abs(dist - radius) / STROKE_WIDTH, 0.0, 1.0));
    }

    gl_FragColor = vec4(col, 1.0);
}
