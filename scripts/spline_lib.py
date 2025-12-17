"""
Unified LibSpline test data generation and visualization.

Provides distribution generators, spline interpolation, and test data export
for both Python visualization and Solidity unit tests.
"""

import math

WAD = 10**18
BPS_RANGE = 10000  # x-axis range [0, 10000]


# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

def to_wad(x):
    """Convert float to WAD-scaled integer."""
    return int(x * WAD)


def normal_pdf(x, mu, sigma):
    """Standard normal probability density function."""
    return (1 / (sigma * math.sqrt(2 * math.pi))) * math.exp(-0.5 * ((x - mu) / sigma) ** 2)


# ═══════════════════════════════════════════════════════════════════════════════
# CATMULL-ROM SPLINE UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

def compute_tangent(pts, i):
    """Compute Catmull-Rom tangent at control point i."""
    n = len(pts)
    if n < 2:
        return 0

    # First point: forward difference
    if i == 0:
        return (pts[1][1] - pts[0][1]) / (pts[1][0] - pts[0][0]) if pts[1][0] != pts[0][0] else 0

    # Last point: backward difference
    if i == n - 1:
        return (pts[n-1][1] - pts[n-2][1]) / (pts[n-1][0] - pts[n-2][0]) if pts[n-1][0] != pts[n-2][0] else 0

    # Interior points: average of adjacent secants
    s1 = (pts[i][1] - pts[i-1][1]) / (pts[i][0] - pts[i-1][0]) if pts[i][0] != pts[i-1][0] else 0
    s2 = (pts[i+1][1] - pts[i][1]) / (pts[i+1][0] - pts[i][0]) if pts[i+1][0] != pts[i][0] else 0
    return (s1 + s2) / 2


def integrate_hermite_segment(x0, y0, x1, y1, m0, m1):
    """
    Analytically integrate cubic Hermite segment.

    The cubic Hermite basis functions integrate to known values:
    - ∫h00 = 1/2
    - ∫h10 = 1/12
    - ∫h01 = 1/2
    - ∫h11 = -1/12

    Area = dx * (y0/2 + y1/2 + (m0 - m1)/12)
    """
    dx = x1 - x0
    # m0, m1 are already scaled by dx in caller
    area = dx * ((y0 + y1) / 2) + (m0 - m1) / 12
    return area


def compute_spline_area(pts, x_start=0, x_end=BPS_RANGE):
    """Compute area under cubic Hermite spline from x_start to x_end."""
    if len(pts) < 2:
        return pts[0][1] * (x_end - x_start) if len(pts) == 1 else 0

    tangents = [compute_tangent(pts, i) for i in range(len(pts))]
    total_area = 0

    for i in range(len(pts) - 1):
        x0, y0 = pts[i]
        x1, y1 = pts[i + 1]

        # Clip to integration range
        if x1 <= x_start or x0 >= x_end:
            continue

        seg_start = max(x0, x_start)
        seg_end = min(x1, x_end)

        if seg_start >= seg_end:
            continue

        # Scale tangents by segment width
        m0 = tangents[i] * (x1 - x0)
        m1 = tangents[i + 1] * (x1 - x0)

        # For partial segments, use linear approximation
        if seg_start > x0 or seg_end < x1:
            t_start = (seg_start - x0) / (x1 - x0)
            t_end = (seg_end - x0) / (x1 - x0)
            y_start = y0 + t_start * (y1 - y0)
            y_end = y0 + t_end * (y1 - y0)
            area = (y_start + y_end) / 2 * (seg_end - seg_start)
        else:
            area = integrate_hermite_segment(x0, y0, x1, y1, m0, m1)

        total_area += area

    return total_area


# ═══════════════════════════════════════════════════════════════════════════════
# DISTRIBUTION GENERATORS
# ═══════════════════════════════════════════════════════════════════════════════

def generate_normal():
    """Normal (Gaussian) distribution - bell curve."""
    x_vals = [0, 2000, 3500, 4500, 5000, 5500, 6500, 8000, 10000]
    mu, sigma = 5000, 1500
    peak_scale = 500 * sigma * math.sqrt(2 * math.pi)
    pts = [(x, normal_pdf(x, mu, sigma) * peak_scale) for x in x_vals]
    return pts, "Normal Distribution (Bell Curve)", "μ=5000, σ=1500, peak≈500bps"


def generate_double_peak():
    """Double-peak (M-shape / bimodal) distribution."""
    x_vals = [0, 1500, 3000, 4500, 5000, 5500, 7000, 8500, 10000]
    mu1, mu2 = 3000, 7000
    sigma = 1200
    peak_scale = 400 * sigma * math.sqrt(2 * math.pi)
    pts = []
    for x in x_vals:
        y1 = normal_pdf(x, mu1, sigma) * peak_scale
        y2 = normal_pdf(x, mu2, sigma) * peak_scale
        pts.append((x, y1 + y2))
    return pts, "Double Peak (M-Shape / Bimodal)", "Peaks at 3000 & 7000, σ=1200"


def generate_v_shape():
    """V-shape (inverted distribution) - minimum at center."""
    x_vals = [0, 3000, 5000, 7000, 10000]
    max_val, min_val = 600, 50
    pts = []
    for x in x_vals:
        dist = abs(x - 5000)
        y = min_val + (max_val - min_val) * (dist / 5000)
        pts.append((x, y))
    return pts, "V-Shape (Inverted)", "Min=50bps at center, max=600bps at edges"


def generate_skewed():
    """Skewed distribution - asymmetric with heavy right tail."""
    x_vals = [0, 1000, 2000, 3000, 4000, 6000, 8000, 10000]
    peak_x, left_sigma, right_sigma = 2500, 1000, 3000
    peak_val = 450
    pts = []
    for x in x_vals:
        if x <= peak_x:
            y = peak_val * math.exp(-0.5 * ((x - peak_x) / left_sigma) ** 2)
        else:
            y = peak_val * math.exp(-0.5 * ((x - peak_x) / right_sigma) ** 2)
        pts.append((x, y))
    return pts, "Skewed Distribution", "Peak at 2500, left_σ=1000, right_σ=3000"


def generate_semicircle():
    """Semicircle (round dome) shape - smooth wide-top dome."""
    x_vals = [0, 800, 1800, 3000, 4000, 5000, 6000, 7000, 8200, 9200, 10000]
    center, radius, max_height = 5000, 5000, 400
    pts = []
    for x in x_vals:
        dist = x - center
        if abs(dist) >= radius:
            y = 0
        else:
            y = math.sqrt(radius**2 - dist**2) / radius * max_height
        pts.append((x, y))
    return pts, "Semicircle (Round Dome)", "Center=5000, radius=5000, height=400bps"


def generate_flat():
    """Flat/constant distribution."""
    x_vals = [0, 10000]
    const_val = 300
    pts = [(x, const_val) for x in x_vals]
    return pts, "Flat (Constant)", "Constant 300bps"


# ═══════════════════════════════════════════════════════════════════════════════
# SOLIDITY TEST DATA EXPORT
# ═══════════════════════════════════════════════════════════════════════════════

def export_solidity_test_data(pts, name):
    """Generate Solidity test data array from control points."""
    print(f"\n// {name}")
    for i, (x, y) in enumerate(pts):
        print(f"pts[{i}] = S.Point({int(x)}, {to_wad(y)});")

    area = compute_spline_area(pts)
    print(f"// Expected area ≈ {to_wad(area)}")
    return area


# ═══════════════════════════════════════════════════════════════════════════════
# VISUALIZATION SUPPORT
# ═══════════════════════════════════════════════════════════════════════════════

def hermite_eval(t, y0, y1, m0, m1):
    """Evaluate cubic Hermite at parameter t in [0,1]."""
    t2, t3 = t*t, t*t*t
    h00 = 2*t3 - 3*t2 + 1
    h10 = t3 - 2*t2 + t
    h01 = -2*t3 + 3*t2
    h11 = t3 - t2
    return h00*y0 + h10*m0 + h01*y1 + h11*m1


def interpolate_spline(pts, num_points=500):
    """Interpolate spline with cubic Hermite for smooth plotting."""
    if len(pts) < 2:
        return [pts[0][0]], [pts[0][1]]

    tangents = [compute_tangent(pts, i) for i in range(len(pts))]

    x_interp, y_interp = [], []

    for i in range(len(pts) - 1):
        x0, y0 = pts[i]
        x1, y1 = pts[i + 1]
        dx = x1 - x0
        m0 = tangents[i] * dx
        m1 = tangents[i + 1] * dx

        # Number of points for this segment (proportional to width)
        seg_points = max(10, int(num_points * dx / BPS_RANGE))

        for j in range(seg_points):
            t = j / seg_points
            x = x0 + t * dx
            y = hermite_eval(t, y0, y1, m0, m1)
            x_interp.append(x)
            y_interp.append(y)

    # Add final point
    x_interp.append(pts[-1][0])
    y_interp.append(pts[-1][1])

    return x_interp, y_interp


def get_all_distributions():
    """Return list of all distribution generators."""
    return [
        generate_normal,
        generate_double_peak,
        generate_v_shape,
        generate_skewed,
        generate_semicircle,
        generate_flat,
    ]
