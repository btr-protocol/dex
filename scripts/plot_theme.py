"""
Dark theme configuration for AIMM pricing parameter visualizations.
Shared across all plotting scripts for consistency.
"""

import matplotlib.pyplot as plt

# ═══════════════════════════════════════════════════════════════════════════════
# COLOR PALETTE (Dark theme, consistent with research/articles/assets/common.py)
# ═══════════════════════════════════════════════════════════════════════════════

COLORS = {
    'background': '#0d1117',
    'text': '#FFFFFF',
    'text_secondary': '#999999',
    'axes_label': '#999999',
    'grid': '#333333',
    'border': '#555555',

    # Line colors - vivid palette
    'line_1': '#00FF41',       # Vivid green
    'line_2': '#00D9FF',       # Vivid cyan
    'line_3': '#FFD700',       # Vivid gold
    'line_4': '#FF6B9D',       # Vivid pink
    'line_5': '#FF00FF',       # Vivid magenta
    'line_6': '#FF8C00',       # Vivid orange
}

# ═══════════════════════════════════════════════════════════════════════════════
# MATPLOTLIB SETUP
# ═══════════════════════════════════════════════════════════════════════════════

def setup_dark_theme():
    """
    Configure matplotlib with dark theme matching research/articles style.
    Call this at the start of any plotting script.
    """
    plt.style.use('dark_background')

    # Figure and axes background
    plt.rcParams['figure.facecolor'] = COLORS['background']
    plt.rcParams['axes.facecolor'] = COLORS['background']

    # Text colors
    plt.rcParams['text.color'] = COLORS['text']
    plt.rcParams['axes.labelcolor'] = COLORS['axes_label']
    plt.rcParams['xtick.color'] = COLORS['axes_label']
    plt.rcParams['ytick.color'] = COLORS['axes_label']

    # Grid styling
    plt.rcParams['grid.color'] = COLORS['grid']
    plt.rcParams['grid.alpha'] = 0.1
    plt.rcParams['grid.linestyle'] = '-'
    plt.rcParams['grid.linewidth'] = 0.5

    # Font
    plt.rcParams['font.family'] = 'monospace'
    plt.rcParams['font.size'] = 10

    # Legend
    plt.rcParams['legend.facecolor'] = COLORS['background']
    plt.rcParams['legend.edgecolor'] = COLORS['border']
    plt.rcParams['legend.framealpha'] = 0.9

    # Spine colors
    plt.rcParams['axes.edgecolor'] = COLORS['border']
    plt.rcParams['axes.spines.left'] = True
    plt.rcParams['axes.spines.bottom'] = True
    plt.rcParams['axes.spines.top'] = False
    plt.rcParams['axes.spines.right'] = False

def get_line_colors(n: int):
    """Get n distinct line colors from the palette."""
    palette = [
        COLORS['line_1'],  # Green
        COLORS['line_2'],  # Cyan
        COLORS['line_3'],  # Gold
        COLORS['line_4'],  # Pink
        COLORS['line_5'],  # Magenta
        COLORS['line_6'],  # Orange
    ]
    return [palette[i % len(palette)] for i in range(n)]


# ═══════════════════════════════════════════════════════════════════════════════
# GLOBAL CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

# Area chart opacity (reduced for better overlay visibility)
AREA_ALPHA = 0.08

# Line fill between alpha
FILL_ALPHA = 0.10

# BPS definition note for charts
BPS_NOTE = "BPS basis: 0.0001% (1 bps = 0.0001%)"
