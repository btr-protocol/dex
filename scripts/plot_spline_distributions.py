#!/usr/bin/env python3
"""
Plot all LibSpline test distributions for visualization.

This script generates plots for all distribution shapes tested in LibSpline.t.sol
to help visualize the liquidity profiles used in AIMM pricing.

Uses unified spline_lib for consistent data generation across all tools.
"""

import sys
from pathlib import Path

try:
    import matplotlib
    matplotlib.use('Agg')  # Non-interactive backend
    import matplotlib.pyplot as plt
except ImportError:
    print("Please install matplotlib: pip3 install matplotlib")
    exit(1)

# Import unified spline library and theme
from spline_lib import get_all_distributions, interpolate_spline
from plot_theme import setup_dark_theme, get_line_colors, COLORS

setup_dark_theme()


def plot_all_distributions():
    """Create a figure with all distribution shapes."""
    distributions_gens = get_all_distributions()
    distributions = [gen() for gen in distributions_gens]

    # Create figure with subplots
    fig, axes = plt.subplots(2, 3, figsize=(15, 10))
    fig.suptitle('LibSpline Test Distributions\nLiquidity Profile Shapes for AIMM Pricing',
                 fontsize=14, fontweight='bold')

    colors = get_line_colors(6)

    for idx, (pts, title, params) in enumerate(distributions):
        ax = axes[idx // 3, idx % 3]

        # Get control points
        x_pts = [p[0] for p in pts]
        y_pts = [p[1] for p in pts]

        # Interpolate smooth curve
        x_smooth, y_smooth = interpolate_spline(pts)

        # Plot smooth curve (no fill for better visibility)
        ax.plot(x_smooth, y_smooth, color=colors[idx], linewidth=2.5, label='Spline')

        # Plot control points (small, subtle)
        ax.scatter(x_pts, y_pts, color=colors[idx], s=30, zorder=5,
                   edgecolors=colors[idx], linewidths=0.5, alpha=0.7)

        # Styling
        ax.set_title(f'{title}\n{params}', fontsize=11)
        ax.set_xlabel('Depth Position (0-10000)', fontsize=9)
        ax.set_ylabel('Price Offset (bps)', fontsize=9)
        ax.set_xlim(-200, 10200)
        ax.set_ylim(bottom=-20)
        ax.grid(True, alpha=0.2)
        ax.axhline(y=0, color=COLORS['border'], linestyle='--', alpha=0.5)
        ax.axvline(x=5000, color=COLORS['border'], linestyle=':', alpha=0.5, label='Center')

        # Calculate and display area
        area = sum((y_smooth[i] + y_smooth[i+1]) / 2 * (x_smooth[i+1] - x_smooth[i])
                   for i in range(len(x_smooth)-1))
        ax.text(0.98, 0.98, f'Area ≈ {area:,.0f}',
                transform=ax.transAxes, ha='right', va='top',
                fontsize=9, color=COLORS['text'],
                bbox=dict(boxstyle='round', facecolor=COLORS['background'], edgecolor=COLORS['border'], alpha=0.9))

    plt.tight_layout()
    plt.subplots_adjust(top=0.90)

    # Save to file
    output_path = '/Users/derpa/Work/btr/dex/contracts/test/unit/plots/spline_distributions.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f"Saved plot to: {output_path}")
    plt.close()


def plot_comparison():
    """Create a single plot comparing all distributions."""
    distributions_gens = get_all_distributions()
    distributions = [
        (gen(), label)
        for gen, label in zip(distributions_gens,
                             ['Normal', 'Double Peak', 'V-Shape', 'Skewed', 'Semicircle', 'Flat'])
    ]

    colors = get_line_colors(6)
    fig, ax = plt.subplots(figsize=(14, 8))

    for idx, ((pts, title, params), label) in enumerate(distributions):
        color = colors[idx]
        x_smooth, y_smooth = interpolate_spline(pts)
        ax.plot(x_smooth, y_smooth, color=color, linewidth=2.5, label=label, alpha=0.8)

    ax.set_title('LibSpline Distribution Comparison\nAll Liquidity Profile Shapes',
                 fontsize=14, fontweight='bold')
    ax.set_xlabel('Depth Position (0 = oversupplied, 10000 = undersupplied)', fontsize=11)
    ax.set_ylabel('Price Offset (basis points)', fontsize=11)
    ax.set_xlim(-200, 10200)
    ax.grid(True, alpha=0.2)
    ax.axhline(y=0, color=COLORS['border'], linestyle='--', alpha=0.5)
    ax.axvline(x=5000, color=COLORS['border'], linestyle=':', alpha=0.5)
    ax.legend(loc='upper right', fontsize=10)

    # Add annotations
    ax.annotate('Balanced\n(50% depth)', xy=(5000, 0), xytext=(5000, -50),
                ha='center', fontsize=9, color=COLORS['text_secondary'])
    ax.annotate('Oversupplied', xy=(500, 50), fontsize=9, color=COLORS['text_secondary'])
    ax.annotate('Undersupplied', xy=(9000, 50), fontsize=9, color=COLORS['text_secondary'])

    plt.tight_layout()

    output_path = '/Users/derpa/Work/btr/dex/contracts/test/unit/plots/spline_comparison.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f"Saved comparison plot to: {output_path}")
    plt.close()


if __name__ == "__main__":
    print("Generating LibSpline distribution plots...")
    print()

    plot_all_distributions()
    print()
    plot_comparison()

    print()
    print("Done! Check the generated PNG files.")
