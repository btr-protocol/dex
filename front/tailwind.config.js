/** @type {import('tailwindcss').Config} */
const config = {
  darkMode: "class",
  content: [
    "./src/**/*.{ts,tsx}",
    "./index.html",
  ],
  theme: {
    container: {
      center: true,
      padding: "2rem",
      screens: {
        "2xl": "1400px",
      },
    },
    extend: {
      colors: {
        border: "#14b8a640",
        input: "#14b8a640",
        ring: "#14b8a6",
        background: "#0a201d",
        foreground: "#ffffff",
        primary: {
          DEFAULT: "#14b8a6",
          foreground: "#0a0a0a",
        },
        secondary: {
          DEFAULT: "#f59e0b",
          foreground: "#0a0a0a",
        },
        destructive: {
          DEFAULT: "#ef4444",
          foreground: "#ffffff",
        },
        muted: {
          DEFAULT: "#0b322d",
          foreground: "#9ca3af",
        },
        accent: {
          DEFAULT: "rgba(255, 255, 255, 0.1)",
          foreground: "#ffffff",
        },
        popover: {
          DEFAULT: "#0b322d",
          foreground: "#ffffff",
        },
        card: {
          DEFAULT: "#0b322d",
          foreground: "#ffffff",
        },
        success: {
          DEFAULT: "#10b981",
          foreground: "#ffffff",
        },
        warning: {
          DEFAULT: "#f59e0b",
          foreground: "#ffffff",
        },
      },
      borderRadius: {
        lg: "0.5rem",
        md: "calc(0.5rem - 2px)",
        sm: "calc(0.5rem - 4px)",
      },
      keyframes: {
        "accordion-down": {
          from: { height: "0" },
          to: { height: "var(--radix-accordion-content-height)" },
        },
        "accordion-up": {
          from: { height: "var(--radix-accordion-content-height)" },
          to: { height: "0" },
        },
      },
      animation: {
        "accordion-down": "accordion-down 0.2s ease-out",
        "accordion-up": "accordion-up 0.2s ease-out",
      },
    },
  },
  plugins: [
    require("tailwindcss-animate"),
    require("@tailwindcss/typography"),
  ],
};

module.exports = config;
