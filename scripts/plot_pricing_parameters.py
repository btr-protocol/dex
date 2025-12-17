#!/usr/bin/env python3
"""
Plot all AIMM pricing parameter curves with correct math and visualization.
"""

import sys
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
import numpy as np

from plot_theme import setup_dark_theme, get_line_colors, COLORS

setup_dark_theme()

WAD = 1e18
OUTPUT_DIR = '/Users/derpa/Work/btr/dex/contracts/test/unit/plots'


def style_3d_axes(ax):
    """Apply consistent dark theme to 3D axes."""
    ax.set_facecolor(COLORS['background'])
    for pane in [ax.xaxis.pane, ax.yaxis.pane, ax.zaxis.pane]:
        pane.fill = False
        pane.set_edgecolor(COLORS['grid'])
    for axis in [ax.xaxis, ax.yaxis, ax.zaxis]:
        axis.label.set_color(COLORS['text'])
    ax.tick_params(axis='x', colors=COLORS['text_secondary'])
    ax.tick_params(axis='y', colors=COLORS['text_secondary'])
    ax.tick_params(axis='z', colors=COLORS['text_secondary'])


# ═══════════════════════════════════════════════════════════════════════════════
# 1. WITHDRAWAL HAIRCUT
# ═══════════════════════════════════════════════════════════════════════════════

def haircut_curve(coverage, suppression):
    """h(c) = (1 - c)^p where p = 1 + suppression/10000"""
    coverage = max(0.0, min(1.0, coverage))
    p = 1.0 + (suppression / 10000.0)
    return min((1.0 - coverage) ** p, 1.0)


def plot_withdrawal_haircut():
    fig, ax = plt.subplots(figsize=(10, 7))

    suppressions = [0, 10000, 30000, 60000]
    colors = get_line_colors(4)
    coverage_vals = np.linspace(0, 1, 500)

    for suppression, color in zip(suppressions, colors):
        p = 1 + suppression / 10000
        haircuts = [haircut_curve(c, suppression) * 100 for c in coverage_vals]
        ax.plot([c * 100 for c in coverage_vals], haircuts,
                color=color, linewidth=2.5, label=f'p={p:.1f}')

    ax.set_xlabel('Coverage Ratio (%)', fontsize=11)
    ax.set_ylabel('Withdrawal Haircut (%)', fontsize=11)
    ax.set_title('Withdrawal Haircut: h(c) = (1 - c)^p', fontsize=13, fontweight='bold')
    ax.grid(True, alpha=0.2)
    ax.legend(loc='upper right', fontsize=10)
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 100)

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/haircut_suppressor.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/haircut_suppressor.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 2. DEPTH AMPLIFIER (Monotonic convergence at critical floor)
# ═══════════════════════════════════════════════════════════════════════════════

def depth_curve(coverage, liabilities, k, critical_floor=0.5):
    """
    Depth amplifier with concave monotonic interpolation.

    - At critical floor: D = R (all curves converge)
    - At 100%: D approaches L (all curves converge)
    - Between: D increases monotonically with concave shape

    Formula: D = R + k × (L-R) × progress^(1/k) for k>0
    This creates strongly concave curves where high k = more virtual depth early.

    k controls how quickly depth reaches its maximum.
    Higher k = faster rise (more concave).
    """
    reserves = coverage * liabilities

    # Above 100%: depth = reserves
    if coverage >= 1.0:
        return reserves

    # At or below critical floor: depth = reserves
    if coverage <= critical_floor:
        return reserves

    # Progress from critical to target (0 at critical, 1 at 100%)
    progress = (coverage - critical_floor) / (1.0 - critical_floor)

    # Concave interpolation using power function
    # progress^(1/(1+k)) creates concavity: higher k = more concave
    # At k=0: linear (exponent=1)
    # At k=1: sqrt-like (exponent=0.5)
    deficit = liabilities - reserves

    if k <= 0:
        virtual_depth = 0
    else:
        # Concave power: progress^(1/(1+2*k))
        # k=0.33 → exp≈0.6, k=0.67 → exp≈0.43, k=1.0 → exp=0.33
        exponent = 1.0 / (1.0 + 2.0 * k)
        concave_progress = progress ** exponent
        virtual_depth = k * deficit * concave_progress

    depth = reserves + virtual_depth
    return min(depth, liabilities)


def plot_depth_amplifier():
    fig, ax = plt.subplots(figsize=(10, 7))

    ks = [0.0, 0.33, 0.67, 1.0]  # k values
    colors = get_line_colors(4)
    coverage_vals = np.linspace(0.50, 1.10, 300)
    L = 1.0
    critical = 0.5

    for k, color in zip(ks, colors):
        depths = [depth_curve(c, L, k, critical) for c in coverage_vals]
        label = f'k={k:.0%}' if k > 0 else 'k=0 (D=R)'
        ax.plot([c * 100 for c in coverage_vals], depths,
                color=color, linewidth=2.5, label=label)

    ax.set_xlabel('Coverage Ratio (%)', fontsize=11)
    ax.set_ylabel('Effective Depth (D)', fontsize=11)
    ax.set_title('Depth Amplifier: D = R + k×(L-R)×progress^(1/(1+2k))\nConcave: high k = faster virtual depth', fontsize=12, fontweight='bold')
    ax.grid(True, alpha=0.2)
    ax.legend(loc='upper left', fontsize=10)
    ax.set_xlim(50, 110)
    ax.set_ylim(0.45, 1.05)

    ax.axvline(x=100, color=COLORS['border'], linestyle='--', alpha=0.5)
    ax.axvline(x=50, color=COLORS['line_4'], linestyle='--', alpha=0.5)
    ax.axhline(y=1.0, color=COLORS['text_secondary'], linestyle=':', alpha=0.5, linewidth=1)
    ax.text(51, 0.47, 'Critical\n(50%)', fontsize=9, color=COLORS['line_4'])
    ax.text(101, 0.47, 'Target\n(100%)', fontsize=9, color=COLORS['text_secondary'])

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/depth_amplifier.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/depth_amplifier.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 3. GAMMA (Inventory Skew - Exponential function with gamma as exponent)
# ═══════════════════════════════════════════════════════════════════════════════

def inventory_skew(coverage, gamma, critical_min=0.5, critical_max=2.0, target=1.0):
    """
    Odd-like inventory skew with gamma as exponent (skew amplifier).

    - At critical_min: skew → +100 (max premium)
    - At target: skew = 0 (equilibrium)
    - At critical_max: skew → -100 (max discount)

    Formula: skew = sign × 100 × progress^(gamma/10000)
    - progress = normalized distance from target (0 at target, 1 at critical)
    - gamma controls curve shape: low gamma = flat, high gamma = steep

    Key: gamma is the EXPONENT, not a linear multiplier.
    """
    # At critical bounds: max skew
    if coverage <= critical_min:
        return 100
    if coverage >= critical_max:
        return -100

    # At target: zero skew
    if coverage == target:
        return 0

    # gamma as exponent (10000 = 1.0x exponent)
    exp = gamma / 10000.0

    if coverage < target:
        # Under target: positive skew (premium)
        # progress = 0 at target, 1 at critical_min
        progress = (target - coverage) / (target - critical_min)
        skew = 100 * (progress ** exp)
        return min(skew, 100)
    else:
        # Over target: negative skew (discount)
        # progress = 0 at target, 1 at critical_max
        progress = (coverage - target) / (critical_max - target)
        skew = -100 * (progress ** exp)
        return max(skew, -100)


def plot_gamma_inventory_skew():
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))

    gammas = [5000, 10000, 15000, 20000]
    colors = get_line_colors(4)

    critical_min = 0.5
    critical_max = 2.0
    target = 1.0

    # Left plot - full curve
    ax1 = axes[0]
    coverage_vals = np.linspace(0.5, 2.0, 500)

    for gamma, color in zip(gammas, colors):
        skews = [inventory_skew(c, gamma, critical_min, critical_max, target)
                 for c in coverage_vals]
        ax1.plot([c * 100 for c in coverage_vals], skews,
                 color=color, linewidth=2.5, label=f'γ={gamma/10000:.1f}x')

    ax1.set_xlabel('Coverage Ratio (%)', fontsize=11)
    ax1.set_ylabel('Inventory Skew', fontsize=11)
    ax1.set_title('Gamma: Exponential Skew (γ = exponent)\nBounded by critical min/max', fontsize=12, fontweight='bold')
    ax1.grid(True, alpha=0.2)
    ax1.legend(loc='upper right', fontsize=10)
    ax1.set_xlim(50, 200)
    ax1.set_ylim(-105, 105)

    ax1.axhline(y=0, color=COLORS['border'], linestyle='-', alpha=0.3)
    ax1.axvline(x=target * 100, color=COLORS['border'], linestyle='--', alpha=0.5)
    ax1.axvline(x=critical_min * 100, color=COLORS['line_4'], linestyle=':', alpha=0.5)
    ax1.axvline(x=critical_max * 100, color=COLORS['line_4'], linestyle=':', alpha=0.5)
    ax1.text(target * 100 + 2, -95, 'Target\n(100%)', fontsize=8, color=COLORS['text_secondary'])
    ax1.text(critical_min * 100 + 2, 90, 'Crit\nMin', fontsize=8, color=COLORS['line_4'])
    ax1.text(critical_max * 100 - 8, -90, 'Crit\nMax', fontsize=8, color=COLORS['line_4'])

    # Right plot - distribution shift (non-linear)
    ax2 = axes[1]
    x = np.linspace(0, 10000, 500)
    y = 400 * np.exp(-0.5 * ((x - 5000) / 2000) ** 2)

    ax2.fill_between(x, y, alpha=0.2, color=COLORS['text_secondary'])
    ax2.plot(x, y, color=COLORS['text_secondary'], linewidth=2, linestyle='--')

    # Show at multiple coverage points
    cov_example = 0.75
    for gamma, color in zip(gammas, colors):
        sk = inventory_skew(cov_example, gamma, critical_min, critical_max, target)
        # Non-linear position mapping (quadratic)
        pos = 5000 + sk * 50
        ax2.axvline(x=pos, color=color, linewidth=2, label=f'γ={gamma/10000:.1f}x → {sk:.1f}')

    ax2.set_xlabel('Depth (5000=TWAP)', fontsize=11)
    ax2.set_ylabel('Liquidity', fontsize=11)
    ax2.set_title(f'Mid-Price Shift at {cov_example*100:.0f}% Coverage', fontsize=12, fontweight='bold')
    ax2.grid(True, alpha=0.2)
    ax2.legend(loc='upper right', fontsize=9)
    ax2.set_xlim(0, 10000)
    ax2.axvline(x=5000, color=COLORS['border'], linestyle='--', alpha=0.5)

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/gamma_inventory_skew.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/gamma_inventory_skew.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 4. VEGA (Dispersion & Density - Inverse Relationship)
# ═══════════════════════════════════════════════════════════════════════════════

def dispersion_for_plot(vol_pct, vega):
    """
    For visualization: dispersion = base × (1 + vol% × vega / 10)

    At 5% vol, vega=1x: disp = 1000 × (1 + 0.5) = 1500
    At 5% vol, vega=5x: disp = 1000 × (1 + 2.5) = 3500
    """
    base = 1000
    return base * (1 + vol_pct * vega / 10)


def plot_vega_volatility():
    """
    Show inverse relationship: dispersion ↑ → density ↓
    More dispersion = wider spread = lower peak density
    *bps = 0.0001% basis
    """
    from plot_theme import AREA_ALPHA

    fig, axes = plt.subplots(1, 2, figsize=(14, 6))

    # Parameters - wider range for clear differentiation
    base_disp = 1000
    vol_pct = 5.0  # 5% volatility
    vegas = [0.5, 1.5, 5.0, 20.0]  # Very different values for visibility
    colors = get_line_colors(4)

    # Left plot: Distributions showing inverse relationship
    ax1 = axes[0]
    x = np.linspace(0, 10000, 500)

    for vega, color in zip(vegas, colors):
        disp = dispersion_for_plot(vol_pct, vega)
        # Scale = dispersion ratio
        scale = disp / base_disp
        # Gaussian: wider dispersion = lower peak (area preserved)
        sigma = 1000 * scale
        peak = 400 / scale  # Inverse relationship
        y = peak * np.exp(-0.5 * ((x - 5000) / sigma) ** 2)

        ax1.fill_between(x, y, alpha=AREA_ALPHA, color=color)
        ax1.plot(x, y, color=color, linewidth=2.5,
                 label=f'vega={vega:.1f}x → σ={disp:.0f}')

    ax1.set_xlabel('Price Offset (5000=TWAP)', fontsize=11)
    ax1.set_ylabel('Density (ρ)', fontsize=11)
    ax1.set_title(f'Vega Amplifies Volatility (σ={vol_pct}%)\n*bps = 0.0001%', fontsize=11, fontweight='bold')
    ax1.grid(True, alpha=0.2)
    ax1.legend(loc='upper right', fontsize=9)
    ax1.set_xlim(0, 10000)
    ax1.set_ylim(bottom=0)
    ax1.axvline(x=5000, color=COLORS['border'], linestyle='--', alpha=0.5)

    # Right plot: dispersion vs density curve
    ax2 = axes[1]
    disp_vals = np.linspace(800, 12000, 100)
    density_vals = base_disp * 400 / disp_vals  # ρ = k / dispersion

    ax2.plot(disp_vals, density_vals, color=COLORS['line_1'], linewidth=3)
    ax2.fill_between(disp_vals, density_vals, alpha=AREA_ALPHA, color=COLORS['line_1'])

    # Mark points for each vega
    for vega, color in zip(vegas, colors):
        disp = dispersion_for_plot(vol_pct, vega)
        dens = base_disp * 400 / disp
        ax2.scatter([disp], [dens], color=color, s=120, zorder=5, edgecolor='white', linewidth=1.5)
        ax2.annotate(f'{vega:.1f}x', (disp, dens),
                     textcoords="offset points", xytext=(8, -15), fontsize=9, color=color)

    ax2.set_xlabel('Dispersion (σ)', fontsize=11)
    ax2.set_ylabel('Peak Density (ρ)', fontsize=11)
    ax2.set_title('ρ = k / σ  (Inverse)', fontsize=12, fontweight='bold')
    ax2.grid(True, alpha=0.2)
    ax2.set_xlim(800, 12000)
    ax2.set_ylim(bottom=0)

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/vega_dispersion_density.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/vega_dispersion_density.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 5. LAMBDA (Deviation Sensitivity - Asymmetric Spread)
# ═══════════════════════════════════════════════════════════════════════════════

def plot_lambda_deviation():
    """
    Asymmetric spread chart: shows how lambda affects toxic flow surcharge.
    Base spread S_vol = max(σ×vega, minFeeBps)
    Toxic surcharge U = λ × Δ on worsening trades only.
    """
    fig, ax = plt.subplots(figsize=(10, 7))

    s_vol = 100  # base spread in bps* (*bps = 0.0001%)
    delta_bps = 200  # 0.02% deviation
    lambdas = [5000, 10000, 15000, 20000]
    colors = get_line_colors(4)

    # Direction scale: -25 to +25 (normalized trade impact)
    x = np.linspace(-25, 25, 200)

    for lam, color in zip(lambdas, colors):
        spreads = []
        for xi in x:
            if xi <= 0:
                # Arb path (improves coverage): just base spread
                spreads.append(s_vol)
            else:
                # Toxic path (worsens coverage): base + surcharge
                # U = delta × lambda × position / 10000
                u = (delta_bps * lam * (xi / 25)) / 10000
                spreads.append(s_vol + u)
        ax.plot(x, spreads, color=color, linewidth=2.5, label=f'λ={lam/10000:.1f}x')

    ax.axhline(y=s_vol, color=COLORS['text_secondary'], linestyle='--', alpha=0.5)
    ax.axvline(x=0, color=COLORS['border'], linestyle='--', alpha=0.5)
    ax.fill_between(x, s_vol - 10, s_vol, where=(x <= 0), alpha=0.1, color=COLORS['line_1'], label='Arb (improves)')
    ax.fill_between(x, s_vol, 200, where=(x > 0), alpha=0.1, color=COLORS['line_4'], label='Toxic (worsens)')

    ax.set_xlabel('Trade Direction Impact', fontsize=11)
    ax.set_ylabel('Spread (bps*)', fontsize=11)
    ax.set_title(f'Asymmetric Spread: S_vol = max(σ×vega, minFee)\nToxic surcharge U = λ×Δ  |  *bps = 0.0001%', fontsize=11, fontweight='bold')
    ax.grid(True, alpha=0.2)
    ax.legend(loc='upper left', fontsize=9)
    ax.set_xlim(-25, 25)
    ax.set_ylim(80, 200)

    ax.text(-20, 85, '← Improves coverage', fontsize=9, color=COLORS['line_1'])
    ax.text(5, 85, 'Worsens coverage →', fontsize=9, color=COLORS['line_4'])

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/lambda_deviation.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/lambda_deviation.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 6. COVERAGE FLOOR (Critical Min Parameter)
# ═══════════════════════════════════════════════════════════════════════════════

def plot_coverage_floor():
    """Show effect of different critical_min values on inventory skew."""
    fig, ax = plt.subplots(figsize=(12, 7))

    critical_mins = [0.3, 0.5, 0.7, 0.9]
    colors = get_line_colors(4)
    coverage_vals = np.linspace(0.25, 2.0, 500)

    for crit_min, color in zip(critical_mins, colors):
        skews = [inventory_skew(c, gamma=10000, critical_min=crit_min, critical_max=2.0, target=1.0)
                 for c in coverage_vals]
        ax.plot([c * 100 for c in coverage_vals], skews,
                color=color, linewidth=2.5, label=f'crit_min={crit_min*100:.0f}%')

    ax.set_xlabel('Coverage Ratio (%)', fontsize=11)
    ax.set_ylabel('Inventory Skew', fontsize=11)
    ax.set_title('Critical Min Floor Effect (γ=1.0x, target=100%, crit_max=200%)', fontsize=12, fontweight='bold')
    ax.grid(True, alpha=0.2)
    ax.legend(loc='upper right', fontsize=10)
    ax.set_xlim(25, 200)
    ax.set_ylim(-105, 105)
    ax.axhline(y=0, color=COLORS['border'], linestyle='-', alpha=0.3)
    ax.axvline(x=100, color=COLORS['border'], linestyle='--', alpha=0.5)
    ax.axvline(x=200, color=COLORS['line_4'], linestyle=':', alpha=0.5)

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/coverage_floor.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/coverage_floor.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 7. LIABILITY DECAY 2D
# ═══════════════════════════════════════════════════════════════════════════════

def calc_decay(liab, res, threshold, slope_annual, dt_days):
    """Calculate decay amount."""
    if liab == 0 or slope_annual == 0:
        return 0
    cov = res / liab
    if cov >= threshold:
        return 0
    slope_per_day = slope_annual / 365
    raw_decay = liab * slope_per_day * dt_days
    max_decay = max(0, liab - res)
    return min(raw_decay, max_decay)


def plot_liability_decay_2d():
    """
    3-year horizon decay simulation.
    Shows step-like behavior as coverage threshold determines when decay kicks in.
    """
    fig, ax = plt.subplots(figsize=(12, 7))

    L = 1000
    cov0 = 0.70  # Starting at 70% coverage
    res = cov0 * L  # Reserves = 700
    slopes = [(0.05, '5%/yr'), (0.10, '10%/yr'), (0.20, '20%/yr'), (0.50, '50%/yr')]
    colors = get_line_colors(4)

    # 3-year horizon (1095 days)
    days = list(range(0, 1096, 7))  # Weekly steps

    for (slope_annual, label), color in zip(slopes, colors):
        remaining = []
        curr_L = L
        curr_R = res
        for d in days:
            if d > 0:
                # Weekly decay
                decay = calc_decay(curr_L, curr_R, 0.98, slope_annual, 7)
                curr_L = max(curr_R, curr_L - decay)
            remaining.append(curr_L)
        ax.plot(days, remaining, color=color, linewidth=2.5, label=label)

    ax.axhline(y=res, color=COLORS['border'], linestyle='--', alpha=0.5)
    ax.text(50, res - 20, f'R={res:.0f} (reserves)', fontsize=9, color=COLORS['text_secondary'])

    # Mark year boundaries
    for year in [365, 730]:
        ax.axvline(x=year, color=COLORS['grid'], linestyle=':', alpha=0.5)

    ax.set_xlabel('Days', fontsize=11)
    ax.set_ylabel('Liabilities', fontsize=11)
    ax.set_title('Liability Decay Over 3 Years\n(70% starting coverage, 98% threshold)', fontsize=12, fontweight='bold')
    ax.grid(True, alpha=0.2)
    ax.legend(loc='upper right', fontsize=10)
    ax.set_xlim(0, 1095)
    ax.set_ylim(650, L * 1.02)

    ax.text(180, L * 1.01, 'Year 1', fontsize=9, color=COLORS['text_secondary'])
    ax.text(545, L * 1.01, 'Year 2', fontsize=9, color=COLORS['text_secondary'])
    ax.text(910, L * 1.01, 'Year 3', fontsize=9, color=COLORS['text_secondary'])

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/liability_decay.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/liability_decay.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 8. LIABILITY DECAY 3D
# ═══════════════════════════════════════════════════════════════════════════════

def calc_6mo_loss(thresh, slope_annual, weeks=26, drop_per_week=0.01):
    """Calculate LP loss over 6 months with weekly coverage drops."""
    L = 1000.0
    R = 1000.0
    total_decay = 0.0
    slope_per_week = slope_annual / 52.0

    for _ in range(weeks):
        R = max(0, R - drop_per_week * L)
        cov = R / L if L > 0 else 0
        if cov < thresh and L > R:
            decay = L * slope_per_week
            max_d = L - R
            decay = min(decay, max_d)
            L -= decay
            total_decay += decay

    return (total_decay / 1000.0) * 100


def plot_liability_decay_3d():
    fig = plt.figure(figsize=(12, 9))
    ax = fig.add_subplot(111, projection='3d')

    # Inverted: threshold 70-100 on Y, slope 0-200 on X
    thresholds = np.linspace(0.70, 1.0, 25)
    slopes = np.linspace(0.0, 2.0, 25)

    X, Y = np.meshgrid(thresholds, slopes)  # Swapped order
    Z = np.zeros_like(X)

    for i in range(X.shape[0]):
        for j in range(X.shape[1]):
            Z[i, j] = calc_6mo_loss(X[i, j], Y[i, j])

    surf = ax.plot_surface(X * 100, Y * 100, Z, cmap='viridis', alpha=0.8, edgecolor='none')

    ax.set_xlabel('Threshold (%)', fontsize=10)
    ax.set_ylabel('Slope (%/yr)', fontsize=10)
    ax.set_zlabel('LP Loss (%)', fontsize=10)
    ax.set_title('Liability Decay: 6-Month Loss\n(1% coverage drop/week)', fontsize=13, fontweight='bold')

    # View from front: threshold increasing left-to-right, slope front-to-back
    ax.view_init(elev=25, azim=225)
    fig.colorbar(surf, ax=ax, shrink=0.5, aspect=10, label='Loss %')
    style_3d_axes(ax)

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/liability_decay_3d.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/liability_decay_3d.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 9. PRICE IMPACT 3D
# ═══════════════════════════════════════════════════════════════════════════════

def price_impact(gamma, depth_k, trade_pct=20, cov=0.5):
    """
    Slippage from liquidity profile traversal.

    Key insight: both gamma and depth_k affect how fast we traverse the profile.
    - Lower depth = trade is larger fraction of depth = traverse more = more slippage
    - Higher gamma = steeper price curve = more slippage per unit traversed

    At 50% coverage with 20% trade:
    - k=0: depth=50, ratio=20/50=40% traversal
    - k=1: depth=100, ratio=20/100=20% traversal
    This 2x difference is very visible.

    Gamma amplifies the base impact multiplicatively.
    """
    L = 100.0
    R = cov * L
    deficit = L - R

    # Depth from reserves + k * deficit
    # At k=0: depth = R = 50 (half collateralized)
    # At k=1: depth = R + deficit = L = 100 (full virtual)
    depth = R + depth_k * deficit
    depth = max(depth, 1.0)

    trade = trade_pct * L / 100

    # Traversal ratio: how much of the profile we traverse
    ratio = trade / depth

    # Base slippage from ratio (linear in traversal)
    # k=0: ratio=0.4 → base=20%
    # k=1: ratio=0.2 → base=10%
    base_slip = ratio * 50

    # Gamma multiplier: higher gamma = more slippage
    # gamma=10000 → mult=1.0x
    # gamma=20000 → mult=2.0x
    # gamma=5000 → mult=0.5x
    gamma_mult = gamma / 10000.0

    slip = base_slip * gamma_mult

    return min(slip, 40)  # Cap at 40% for visualization


def plot_price_impact_3d():
    fig = plt.figure(figsize=(12, 9))
    ax = fig.add_subplot(111, projection='3d')

    # Gamma inverted: high gamma on left (2.0x), low on right (0.5x)
    gammas = np.linspace(20000, 5000, 25)  # Inverted
    depth_ks = np.linspace(0, 1.0, 25)

    X, Y = np.meshgrid(depth_ks, gammas)  # Swapped: depth on X, gamma on Y
    Z = np.zeros_like(X)

    for i in range(X.shape[0]):
        for j in range(X.shape[1]):
            Z[i, j] = price_impact(Y[i, j], X[i, j])

    surf = ax.plot_surface(X * 100, Y / 10000, Z, cmap='viridis', alpha=0.8, edgecolor='none')

    ax.set_xlabel('Depth k (%)', fontsize=10)
    ax.set_ylabel('Gamma (×)', fontsize=10)
    ax.set_zlabel('Slippage (%)', fontsize=10)
    ax.set_title('Price Impact: k↓ & γ↑ → more slippage\n(20% trade, 50% coverage)', fontsize=11, fontweight='bold')

    # View to show depth impact clearly
    ax.view_init(elev=30, azim=135)
    fig.colorbar(surf, ax=ax, shrink=0.5, aspect=10, label='Slippage %')
    style_3d_axes(ax)

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/price_impact_3d.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/price_impact_3d.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# 10. SPREAD 3D (Volatility dominant, deviation visible on toxic)
# ═══════════════════════════════════════════════════════════════════════════════

def spread_3d(vega_sigma, lambda_delta, toxic=True):
    """
    S_vol = 100 + vega_sigma / 20 (volatility base)
    U = (lambda_delta / 50)^1.5 when toxic (visible deviation surcharge)
    Both overlap at lambda_delta=0
    """
    # Volatility component: base spread
    s_vol = 100 + vega_sigma / 20

    if not toxic or lambda_delta == 0:
        return s_vol

    # Deviation surcharge: now more visible
    u = (lambda_delta / 50) ** 1.5
    return s_vol + u


def plot_spread_3d():
    fig = plt.figure(figsize=(12, 9))
    ax = fig.add_subplot(111, projection='3d')

    # Balanced ranges for both axes
    vega_sigma = np.linspace(0, 3000, 30)   # 0-30% vol range
    lambda_delta = np.linspace(0, 1500, 30)  # 0-15% deviation

    X, Y = np.meshgrid(vega_sigma, lambda_delta)

    Z_rebal = np.zeros_like(X)
    Z_toxic = np.zeros_like(X)

    for i in range(X.shape[0]):
        for j in range(X.shape[1]):
            Z_rebal[i, j] = spread_3d(X[i, j], Y[i, j], toxic=False)
            Z_toxic[i, j] = spread_3d(X[i, j], Y[i, j], toxic=True)

    # Surfaces
    ax.plot_surface(X / 100, Y / 100, Z_rebal,
                    color=COLORS['line_1'], alpha=0.5, edgecolor='none')
    ax.plot_surface(X / 100, Y / 100, Z_toxic,
                    color=COLORS['line_4'], alpha=0.6, edgecolor='none')

    ax.set_xlabel('Vega×σ (%)', fontsize=10)
    ax.set_ylabel('λ×Δ (%)', fontsize=10)
    ax.set_zlabel('Spread (bps*)', fontsize=10)
    ax.set_title('Bid-Ask Spread: Rebal vs Toxic\n*bps = 0.0001%', fontsize=11, fontweight='bold')

    # View angle - inverted to see both surfaces clearly
    ax.view_init(elev=25, azim=225)

    from matplotlib.patches import Patch
    legend_elements = [
        Patch(facecolor=COLORS['line_1'], alpha=0.5, label='Rebalancing (S_vol)'),
        Patch(facecolor=COLORS['line_4'], alpha=0.6, label='Toxic (S_vol + U)')
    ]
    ax.legend(handles=legend_elements, loc='upper left')
    style_3d_axes(ax)

    plt.tight_layout()
    plt.savefig(f'{OUTPUT_DIR}/spread_vega_lambda_3d.png', dpi=150, bbox_inches='tight')
    print(f"Saved: {OUTPUT_DIR}/spread_vega_lambda_3d.png")
    plt.close()


# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)

    print("Generating AIMM pricing plots...")
    print()

    print("2D plots:")
    plot_withdrawal_haircut()
    plot_depth_amplifier()
    plot_gamma_inventory_skew()
    plot_vega_volatility()
    plot_lambda_deviation()
    plot_coverage_floor()
    plot_liability_decay_2d()

    print("\n3D plots:")
    plot_liability_decay_3d()
    plot_price_impact_3d()
    plot_spread_3d()

    print()
    print(f"Done! Files in: {OUTPUT_DIR}/")
