#!/usr/bin/env bun

/**
 * Pre-compile all markdown files to HTML at build time.
 * This eliminates the need for markdown-wasm, prismjs, asciimath2ml, and mermaid in the runtime bundle.
 */

import { readdir, readFile, writeFile, mkdir } from 'fs/promises';
import { join, relative, basename } from 'path';
import { existsSync } from 'fs';
import { marked } from 'marked';
import Prism from 'prismjs';
import loadLanguages from 'prismjs/components/index.js';
import { asciiToMathML } from 'asciimath2ml';
import { Window } from 'happy-dom';
import { slugifyDoc, generateAnchorId } from '../sdk/src/common/format.js';
import { chromium, type Browser } from 'playwright';

// Load Prism languages
loadLanguages(['javascript', 'typescript', 'jsx', 'tsx', 'json', 'bash', 'sql', 'markdown', 'solidity']);

interface CompiledDoc {
  slug: string;
  title: string;
  html: string;
  category: string | null;
}

// Mermaid theme configuration matching our app theme
const MERMAID_THEMES = {
  dark: {
    theme: 'dark',
    themeVariables: {
      // Primary colors
      primaryColor: '#1f1f1f',       // bg-1 (dark)
      primaryTextColor: '#fafafa',   // fg-0 (white)
      primaryBorderColor: '#3d3d3d', // bg-4 (dark)

      // Secondary colors
      secondaryColor: '#2a2a2a',     // bg-2 (dark)
      secondaryTextColor: '#cbcac3', // fg-1 (80% white)
      secondaryBorderColor: '#333333', // bg-3 (dark)

      // Tertiary colors
      tertiaryColor: '#242424',      // bg-1.5 (dark)
      tertiaryTextColor: '#7f7f7c',  // fg-2 (50% white)
      tertiaryBorderColor: '#2e2e2e', // bg-3 (dark)

      // Node colors
      nodeBorder: '#f68f11',         // primary (orange)
      nodeTextColor: '#fafafa',      // fg-0 (white)

      // Edge/arrow colors
      lineColor: '#7f7f7c',          // fg-2 (muted)
      arrowheadColor: '#f68f11',     // primary (orange)

      // Background
      background: '#1B1B1B',         // bg-0 (black)
      mainBkg: '#1f1f1f',            // bg-1 (dark)

      // Sentiment colors
      errorBkgColor: '#DB4E5C',      // error (red)
      errorTextColor: '#fafafa',
      warningBkgColor: '#ffd61e',    // warning (yellow)
      warningTextColor: '#1B1B1B',
      successBkgColor: '#10B981',    // success (green)
      successTextColor: '#fafafa',
      infoBkgColor: '#2ee7e7',       // info (cyan)
      infoTextColor: '#1B1B1B',

      // Additional semantic colors
      activationBkgColor: '#f68f11', // primary (orange)
      activationBorderColor: '#c47310',

      // Class diagram colors
      classText: '#fafafa',

      // State diagram colors
      labelColor: '#fafafa',

      // Sequence diagram colors
      actorBkg: '#2a2a2a',
      actorBorder: '#f68f11',
      actorTextColor: '#fafafa',
      actorLineColor: '#7f7f7c',
      signalColor: '#cbcac3',
      signalTextColor: '#fafafa',

      // Git diagram colors
      git0: '#3d7eff',               // blue
      git1: '#10B981',               // green
      git2: '#f68f11',               // orange
      git3: '#DB4E5C',               // red
      git4: '#ffd61e',               // yellow
      git5: '#2ee7e7',               // cyan
      git6: '#e94cef',               // pink
      git7: '#a273f5',               // violet

      // Gantt chart colors
      gridColor: '#3d3d3d',
      todayLineColor: '#f68f11',

      // Pie chart colors
      pie1: '#3d7eff',               // blue
      pie2: '#10B981',               // green
      pie3: '#f68f11',               // orange
      pie4: '#DB4E5C',               // red
      pie5: '#ffd61e',               // yellow
      pie6: '#2ee7e7',               // cyan
      pie7: '#e94cef',               // pink
      pie8: '#a273f5',               // violet
      pie9: '#6C6C6C',               // grey
      pie10: '#ffffff',
      pie11: '#1B1B1B',
      pie12: '#c47310',

      // Font
      fontFamily: 'Inter, sans-serif',
      fontSize: '14px',
    },
  },
  light: {
    theme: 'default',
    themeVariables: {
      // Primary colors
      primaryColor: '#e8e7e3',       // bg-1 (light)
      primaryTextColor: '#1B1B1B',   // fg-0 (black)
      primaryBorderColor: '#bfbfbf', // bg-4 (light)

      // Secondary colors
      secondaryColor: '#d9d8d4',     // bg-2 (light)
      secondaryTextColor: '#363636', // fg-1 (80% black)
      secondaryBorderColor: '#cccccc', // bg-3 (light)

      // Tertiary colors
      tertiaryColor: '#e0dfdb',      // bg-1.5 (light)
      tertiaryTextColor: '#7f7f7f',  // fg-2 (50% black)
      tertiaryBorderColor: '#d3d3d3', // bg-3 (light)

      // Node colors
      nodeBorder: '#f68f11',         // primary (orange)
      nodeTextColor: '#1B1B1B',      // fg-0 (black)

      // Edge/arrow colors
      lineColor: '#7f7f7f',          // fg-2 (muted)
      arrowheadColor: '#f68f11',     // primary (orange)

      // Background
      background: '#f2f2f2',         // bg-0 (light)
      mainBkg: '#e8e7e3',            // bg-1 (light)

      // Sentiment colors
      errorBkgColor: '#DB4E5C',      // error (red)
      errorTextColor: '#fafafa',
      warningBkgColor: '#ffd61e',    // warning (yellow)
      warningTextColor: '#1B1B1B',
      successBkgColor: '#10B981',    // success (green)
      successTextColor: '#fafafa',
      infoBkgColor: '#2ee7e7',       // info (cyan)
      infoTextColor: '#1B1B1B',

      // Additional semantic colors
      activationBkgColor: '#f68f11', // primary (orange)
      activationBorderColor: '#c47310',

      // Class diagram colors
      classText: '#1B1B1B',

      // State diagram colors
      labelColor: '#1B1B1B',

      // Sequence diagram colors
      actorBkg: '#d9d8d4',
      actorBorder: '#f68f11',
      actorTextColor: '#1B1B1B',
      actorLineColor: '#7f7f7f',
      signalColor: '#363636',
      signalTextColor: '#1B1B1B',

      // Git diagram colors
      git0: '#3d7eff',               // blue
      git1: '#10B981',               // green
      git2: '#f68f11',               // orange
      git3: '#DB4E5C',               // red
      git4: '#ffd61e',               // yellow
      git5: '#2ee7e7',               // cyan
      git6: '#e94cef',               // pink
      git7: '#a273f5',               // violet

      // Gantt chart colors
      gridColor: '#bfbfbf',
      todayLineColor: '#f68f11',

      // Pie chart colors
      pie1: '#3d7eff',               // blue
      pie2: '#10B981',               // green
      pie3: '#f68f11',               // orange
      pie4: '#DB4E5C',               // red
      pie5: '#ffd61e',               // yellow
      pie6: '#2ee7e7',               // cyan
      pie7: '#e94cef',               // pink
      pie8: '#a273f5',               // violet
      pie9: '#6C6C6C',               // grey
      pie10: '#1B1B1B',
      pie11: '#fafafa',
      pie12: '#c47310',

      // Font
      fontFamily: 'Inter, sans-serif',
      fontSize: '14px',
    },
  },
};

// Mermaid rendering function - generates both light and dark SVGs
let browser: Browser | null = null;

async function renderMermaidToSVG(mermaidCode: string): Promise<{ light: string; dark: string }> {
  // Launch browser if not already running
  if (!browser) {
    browser = await chromium.launch({
      headless: true,
    });
  }

  const page = await browser.newPage();

  try {
    // Render both light and dark themes
    const svgs: { light: string; dark: string } = { light: '', dark: '' };

    for (const theme of ['light', 'dark'] as const) {
      const themeConfig = MERMAID_THEMES[theme];

      await page.setContent(`
        <!DOCTYPE html>
        <html>
          <head>
            <script type="module">
              import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
              mermaid.initialize(${JSON.stringify(themeConfig)});

              window.renderMermaid = async (code) => {
                const { svg } = await mermaid.render('mermaid-diagram', code);
                return svg;
              };
            </script>
          </head>
          <body></body>
        </html>
      `);

      const svg = await page.evaluate(async (code) => {
        return await (window as any).renderMermaid(code);
      }, mermaidCode);

      svgs[theme] = svg;
    }

    await page.close();
    return svgs;
  } catch (err) {
    await page.close();
    throw err;
  }
}

// Close browser when done
async function closeBrowser() {
  if (browser) {
    await browser.close();
    browser = null;
  }
}

// Configure marked
marked.setOptions({
  gfm: true,
  breaks: false,
  pedantic: false,
});

async function getAllMarkdownFiles(dir: string, baseDir: string = dir): Promise<string[]> {
  const files: string[] = [];
  const items = await readdir(dir, { withFileTypes: true });

  for (const item of items) {
    const fullPath = join(dir, item.name);
    if (item.isDirectory()) {
      files.push(...await getAllMarkdownFiles(fullPath, baseDir));
    } else if (item.name.endsWith('.md')) {
      files.push(fullPath);
    }
  }

  return files;
}

function generateSlugFromPath(filePath: string, docsDir: string): string {
  const relativePath = relative(docsDir, filePath).replace(/\\/g, '/');
  const pathParts = relativePath.split('/');
  const filename = basename(filePath, '.md');
  const category = pathParts.length > 1 ? pathParts[0] : undefined;
  return slugifyDoc(filename, category);
}

function extractTitleFromSlug(slug: string): string {
  const pathParts = slug.split('/');
  const lastPart = pathParts[pathParts.length - 1];

  // If already contains spaces, use as-is, otherwise convert dashes to spaces
  return lastPart.includes(' ')
    ? lastPart
    : lastPart
        .split('-')
        .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
        .join(' ');
}

function escapeHtml(text: string): string {
  const div = new Window().document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

/**
 * Normalize math expression for AsciiMath parsing.
 * - Converts LaTeX symbols (\pi, \gamma, etc.) to AsciiMath equivalents
 * - Converts |expr| absolute value bars to abs(expr)
 * - Adds quad spacing around "with" and "where" keywords
 * - Quotes text phrases in piecewise functions
 */
function normalizeMathExpr(expr: string): string {
  let result = expr
    // LaTeX symbols to AsciiMath
    .replace(/\\pi/g, 'pi')
    .replace(/\\gamma/g, 'gamma')
    .replace(/\\eta/g, 'eta')
    .replace(/\\rho/g, 'rho')
    .replace(/\\Delta/g, 'Delta')
    .replace(/\\Sigma/g, 'Sigma')
    .replace(/\\sigma/g, 'sigma')
    .replace(/\\alpha/g, 'alpha')
    .replace(/\\beta/g, 'beta')
    .replace(/\\theta/g, 'theta')
    .replace(/\\lambda/g, 'lambda')
    .replace(/\\omega/g, 'omega')
    .replace(/\\phi/g, 'phi')
    .replace(/\\psi/g, 'psi')
    .replace(/\\epsilon/g, 'epsilon')
    .replace(/\\mu/g, 'mu')
    .replace(/\\nu/g, 'nu')
    .replace(/\\tau/g, 'tau')
    .replace(/\\chi/g, 'chi')
    .replace(/\\kappa/g, 'kappa')
    .replace(/\\zeta/g, 'zeta')
    // Convert |expr| to abs(expr) to avoid parser confusion
    .replace(/\|([^|]+)\|/g, 'abs($1)');

  // Add quad spacing around "with" and "where" keywords (but not if already processed)
  // Pattern: " with " -> quad "with" quad
  result = result.replace(/\s+with\s+(?!quad)/gi, ' quad "with" quad ');
  result = result.replace(/\s+where\s+(?!quad)/gi, ' quad "where" quad ');

  // Quote text phrases in piecewise functions (if X, otherwise, etc.)
  // Match "if <text>" patterns and quote them
  result = result.replace(/,\s*if\s+([^,)]+)/g, (_, text) => {
    const trimmed = text.trim();
    // If it's already quoted or is a simple variable, leave it
    if (trimmed.startsWith('"') || /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(trimmed)) {
      return `, "if" ${trimmed}`;
    }
    return `, "if ${trimmed}"`;
  });
  result = result.replace(/,\s*otherwise\s*\)/g, ', "otherwise")');

  return result;
}

/**
 * Render piecewise/cases function to proper MathML.
 * Pattern: S = { (expr1, cond1), (expr2, cond2) :}
 * Returns null if not a piecewise pattern, MathML string if it is.
 */
function renderPiecewise(expr: string, isBlock: boolean): string | null {
  // Match: VAR = { (expr, cond), (expr, cond), ... :}
  const match = expr.match(/^(.+?)\s*=\s*\{\s*(.+?)\s*:\s*\}$/);
  if (!match) return null;

  const [, lhs, casesStr] = match;

  // Parse cases: (expr, cond), (expr, cond), ...
  const caseRegex = /\(\s*([^,]+?)\s*,\s*(.+?)\s*\)/g;
  const cases: { expr: string; cond: string }[] = [];

  let caseMatch;
  while ((caseMatch = caseRegex.exec(casesStr)) !== null) {
    cases.push({ expr: caseMatch[1].trim(), cond: caseMatch[2].trim() });
  }

  if (cases.length === 0) return null;

  // Generate proper MathML with mtable for cases
  const display = isBlock ? 'block' : 'inline';

  // Render LHS
  const lhsNorm = normalizeMathExpr(lhs);
  let lhsMathML: string;
  try {
    // Extract inner content from asciimath result
    const full = asciiToMathML(lhsNorm, true);
    const innerMatch = full.match(/<mstyle[^>]*>([\s\S]*)<\/mstyle>/);
    lhsMathML = innerMatch ? innerMatch[1] : lhsNorm;
  } catch {
    lhsMathML = `<mi>${lhs}</mi>`;
  }

  // Build rows
  const rows = cases.map(({ expr: caseExpr, cond }) => {
    let exprMathML: string;
    let condMathML: string;

    try {
      const exprFull = asciiToMathML(normalizeMathExpr(caseExpr), true);
      const exprInner = exprFull.match(/<mstyle[^>]*>([\s\S]*)<\/mstyle>/);
      exprMathML = exprInner ? exprInner[1] : `<mi>${caseExpr}</mi>`;
    } catch {
      exprMathML = `<mi>${caseExpr}</mi>`;
    }

    // Condition - wrap in mtext if it's quoted text
    const condClean = cond.replace(/^["']|["']$/g, '');
    condMathML = `<mtext>${condClean}</mtext>`;

    return `<mtr><mtd columnalign="left">${exprMathML}</mtd><mtd columnalign="left">${condMathML}</mtd></mtr>`;
  });

  return `<math display="${display}"><mstyle displaystyle="true">${lhsMathML}<mo>=</mo><mrow><mo stretchy="true" fence="true">{</mo><mtable columnspacing="1em" rowspacing="0.5em">${rows.join('')}</mtable></mrow></mstyle></math>`;
}

async function renderMarkdown(content: string): Promise<string> {
  // Track math and mermaid placeholders
  const mathBlocks: { placeholder: string; html: string }[] = [];
  let mathCounter = 0;

  // Handle ```mermaid blocks - compile to themed SVG
  const mermaidMatches = [...content.matchAll(/```mermaid\n([\s\S]+?)\n```/g)];
  for (const match of mermaidMatches) {
    const mermaidCode = match[1];
    try {
      const { light, dark } = await renderMermaidToSVG(mermaidCode);

      // Wrap SVGs in a container that switches based on theme
      const placeholder = `<!--MERMAID${mathCounter}-->`;
      const html = `
<div class="mermaid-diagram">
  <div class="mermaid-light" style="display: none;">${light}</div>
  <div class="mermaid-dark" style="display: none;">${dark}</div>
</div>`.trim();

      mathBlocks.push({ placeholder, html });
      content = content.replace(match[0], placeholder);
      mathCounter++;

      // Silent success
    } catch (err) {
      // Silent failure - leave the code block as-is if rendering fails
    }
  }

  // First, placeholder ALL labeled code blocks to avoid false matches
  const codeBlockPlaceholders: { placeholder: string; content: string }[] = [];
  let codeBlockCounter = 0;

  let processedContent = content.replace(/```([a-z]+)\n([\s\S]+?)\n```/g, (match, lang, code) => {
    const placeholder = `<!--CODEBLOCK${codeBlockCounter}-->`;
    codeBlockPlaceholders.push({ placeholder, content: match });
    codeBlockCounter++;
    return placeholder;
  });

  // Handle ```math blocks - convert to proper math notation
  processedContent = processedContent.replace(/```math\n([\s\S]+?)\n```/g, (match, blockContent) => {
    const lines = blockContent.split('\n');
    let result: string[] = [];
    let inWhere = false;

    for (const line of lines) {
      const trimmed = line.trim();

      if (!trimmed) {
        result.push(''); // preserve blank lines
      } else if (trimmed === 'where:' || trimmed === 'for each chain:') {
        result.push(`\n**${trimmed}**\n`); // Keep as markdown header
        inWhere = true;
      } else if (trimmed.match(/^[-•]\s/)) {
        // Already a list item - keep as is
        result.push(line);
      } else if (inWhere && line.match(/^  /)) {
        // Indented line in where/for clause - use list with inline math
        result.push(`- $${trimmed}$`);
      } else if (trimmed.match(/^[A-Z_][a-z_]*\s*[=<>∈]/)) {
        // Formula line starting with variable - use display math
        result.push(`$$${trimmed}$$\n`);
      } else {
        // Keep as regular text (like comments in brackets)
        result.push(line);
      }
    }

    return result.join('\n');
  });

  // Also handle unlabeled ``` blocks that contain math (backwards compatibility)
  // This now safely runs after labeled blocks are placeholdered
  processedContent = processedContent.replace(/```\n([\s\S]+?)\n```/g, (match, blockContent) => {
    // Check if this looks like math
    const hasMathSymbols = /[×Σλγσ]|V_[a-z]+\s*=|effectiveStake|skew\s*=|EMA_|haircut\s*=/.test(blockContent);

    if (hasMathSymbols) {
      // Treat as math block
      return `\`\`\`math\n${blockContent}\n\`\`\``;
    }
    return match;
  });

  // Restore labeled code blocks
  codeBlockPlaceholders.forEach(({ placeholder, content }) => {
    processedContent = processedContent.replace(placeholder, content);
  });

  // Convert backtick math to $ syntax for inline expressions
  // Only convert if it has clear AsciiMath operators: xx (with spaces), //, quoted strings
  processedContent = processedContent.replace(/`([^`\n]+)`/g, (match, code) => {
    const trimmed = code.trim();

    // Definite code patterns - exclude these first
    const isDefinitelyCode =
      /^[a-z][a-zA-Z0-9_]*$/.test(trimmed) || // simple identifier like `foo`
      /^[A-Z_][A-Z0-9_]*$/.test(trimmed) || // constant like `MAX_VALUE`
      /https?:|^\/|\.ts|\.js|\.sol|\.md|#\//.test(trimmed) || // URL, path, extension
      /^\d+$/.test(trimmed) || // plain number like `123`
      /^[a-zA-Z][a-zA-Z0-9_]*\(/.test(trimmed) || // function like `foo(` or `FooBar(`
      /^[a-zA-Z][a-zA-Z0-9_]*\[/.test(trimmed) || // array like `arr[`
      /^\.[a-z]/.test(trimmed) || // property like `.foo`
      /[,;{}]|uint\d+|address|bool|string/.test(trimmed); // code/Solidity syntax

    if (isDefinitelyCode) {
      return match;
    }

    // Definite math patterns - only these get converted
    const isDefinitelyMath =
      / xx /.test(trimmed) || // AsciiMath multiply: `a xx b`
      / \/\/ /.test(trimmed) || // AsciiMath divide: `a // b`
      /"[a-z_]+"/.test(trimmed); // AsciiMath quoted strings: `"progress"`

    if (isDefinitelyMath) {
      return `$${trimmed}$`;
    }

    // Default: keep as code
    return match;
  });

  // Handle WHERE blocks - convert to styled div with math rendering
  // Match code blocks that start with "WHERE" (no language specified)
  processedContent = processedContent.replace(/```\nWHERE\n([\s\S]+?)\n```/g, (match, whereContent) => {
    const lines = whereContent.trim().split('\n');
    const renderedLines: string[] = [];

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      // Split by comma to handle multiple definitions per line (e.g., "x = input, y = output")
      const parts = trimmed.split(/,\s*(?=[a-zA-Z$_\\])/);

      for (const part of parts) {
        const partTrimmed = part.trim();
        if (!partTrimmed) continue;

        // Try to extract math expression and description
        // Format: "$var$ = $expression$" or "$var$ = description text" or "var = description"

        // Check if line has $...$ segments
        const mathSegments = [...partTrimmed.matchAll(/\$([^$]+)\$/g)];

        if (mathSegments.length > 0) {
          // Find where the math ends and description begins
          const lastMathEnd = partTrimmed.lastIndexOf('$');
          const afterMath = partTrimmed.slice(lastMathEnd + 1).trim();

          // Check for parenthetical description at end of line
          let description = '';
          let mathPortion = partTrimmed;
          let wrapInParens = false;

          const commentMatch = afterMath.match(/^\s*\((.+)\)$/);
          if (commentMatch) {
            description = commentMatch[1];
            mathPortion = partTrimmed.slice(0, lastMathEnd + 1).trim();
            wrapInParens = true;
          } else if (afterMath && !afterMath.startsWith('$')) {
            description = afterMath.trim();
            mathPortion = partTrimmed.slice(0, lastMathEnd + 1).trim();
          }

          // Merge all $...$ segments into one math expression
          let fullMathExpr = mathPortion.replace(/\$/g, '').trim();
          fullMathExpr = normalizeMathExpr(fullMathExpr);

          // Render the math expression
          let mathHtml = '';
          try {
            const mathML = asciiToMathML(fullMathExpr, true);
            mathHtml = `<span class="math-inline">${mathML}</span>`;
          } catch {
            mathHtml = `<code class="where-expr">${escapeHtml(fullMathExpr)}</code>`;
          }

          if (description) {
            // Render description as plain HTML text (not math - preserves spaces and proper formatting)
            const descText = wrapInParens ? `(${description})` : description;
            renderedLines.push(`<div class="where-line">${mathHtml}<span class="where-desc">${escapeHtml(descText)}</span></div>`);
          } else {
            renderedLines.push(`<div class="where-line">${mathHtml}</div>`);
          }
        } else {
          // No math segments - check for simple "var = desc" pattern
          const eqMatch = partTrimmed.match(/^([^=]+?)\s*=\s*(.+)$/);
          if (eqMatch) {
            const [, varPart, descPart] = eqMatch;
            try {
              const normalized = normalizeMathExpr(varPart.trim());
              const mathML = asciiToMathML(normalized, true);
              // Render description as plain HTML text
              renderedLines.push(`<div class="where-line"><span class="math-inline">${mathML}</span><span class="where-eq">=</span><span class="where-desc">${escapeHtml(descPart.trim())}</span></div>`);
            } catch {
              renderedLines.push(`<div class="where-line"><span class="where-var">${escapeHtml(varPart.trim())}</span><span class="where-eq">=</span><span class="where-desc">${escapeHtml(descPart.trim())}</span></div>`);
            }
          } else {
            // No equals sign - just render as plain text
            renderedLines.push(`<div class="where-line"><span class="where-desc">${escapeHtml(partTrimmed)}</span></div>`);
          }
        }
      }
    }

    const placeholder = `<!--WHEREBLOCK${mathCounter}-->`;
    mathBlocks.push({
      placeholder,
      html: `<div class="where-block"><div class="where-header">WHERE</div>${renderedLines.join('\n')}</div>`,
    });
    mathCounter++;
    return placeholder;
  });

  // Merge consecutive $$...$$ blocks into single multi-line math blocks
  // Pattern: $$expr1$$\n\n$$expr2$$\n\n$$expr3$$ -> one block with all expressions
  processedContent = processedContent.replace(
    /(\$\$[^$]+?\$\$(?:\s*\n\s*\n?\s*\$\$[^$]+?\$\$)+)/g,
    (multiBlock) => {
      // Extract all expressions from the consecutive blocks
      const expressions = [...multiBlock.matchAll(/\$\$([^$]+?)\$\$/g)].map(m => m[1].trim());

      try {
        // Render each expression - check for piecewise first
        const mathMLParts = expressions.map(expr => {
          // Try piecewise rendering first
          const piecewise = renderPiecewise(expr, true);
          if (piecewise) return piecewise;

          const normalized = normalizeMathExpr(expr);
          return asciiToMathML(normalized, false);
        });

        const placeholder = `<!--MATHBLOCK${mathCounter}-->`;
        mathBlocks.push({
          placeholder,
          html: `<div class="math-block math-multiline">${mathMLParts.join('<br/>')}</div>`,
        });
        mathCounter++;
        return placeholder;
      } catch (err) {
        // Silent failure - keep original
        return multiBlock;
      }
    }
  );

  // Replace remaining single block math $$...$$ with placeholders
  // Use HTML comment placeholders to avoid markdown parsing
  processedContent = processedContent.replace(/\$\$([^$]+?)\$\$/g, (match, math) => {
    try {
      const trimmed = math.trim();

      // Try piecewise rendering first
      const piecewise = renderPiecewise(trimmed, true);
      if (piecewise) {
        const placeholder = `<!--MATHBLOCK${mathCounter}-->`;
        mathBlocks.push({
          placeholder,
          html: `<div class="math-block">${piecewise}</div>`,
        });
        mathCounter++;
        return placeholder;
      }

      const normalized = normalizeMathExpr(trimmed);
      const mathML = asciiToMathML(normalized, false);
      const placeholder = `<!--MATHBLOCK${mathCounter}-->`;
      mathBlocks.push({
        placeholder,
        html: `<div class="math-block">${mathML}</div>`,
      });
      mathCounter++;
      return placeholder;
    } catch (err) {
      // Silent failure - keep original
      return match;
    }
  });

  // Replace inline math $...$ with placeholders
  // Only match if contains math operators/symbols: ^, _, *, /, =, greek letters, or parentheses
  processedContent = processedContent.replace(/\$([^$\n]+?)\$/g, (match, math) => {
    const trimmed = math.trim();
    // Check if it looks like actual math:
    // - Single letters/variables (e.g., $k$, $R$, $c$)
    // - Contains operators, subscripts, or special symbols
    // - Greek letters or math functions
    const isMath = /^[a-zA-Z]$/.test(trimmed) || /[=^_*/()<>\\]|alpha|beta|gamma|delta|sigma|lambda|phi|pi|theta|omega|rho|eta|psi|sqrt|sum|int|frac|cdot|times|div/i.test(trimmed);

    if (!isMath) {
      // Not math, just a dollar amount - leave it as is
      return match;
    }

    try {
      const normalized = normalizeMathExpr(trimmed);
      const mathML = asciiToMathML(normalized, true);
      const placeholder = `<!--MATHINLINE${mathCounter}-->`;
      mathBlocks.push({
        placeholder,
        html: `<span class="math-inline">${mathML}</span>`,
      });
      mathCounter++;
      return placeholder;
    } catch (err) {
      // Silent failure - keep original
      return match;
    }
  });

  // Parse markdown with marked
  let html = marked.parse(processedContent) as string;

  // Post-process: Apply syntax highlighting with Prism
  const window = new Window();
  const doc = window.document;
  doc.body.innerHTML = html;
  const codeBlocks = doc.querySelectorAll('pre code');

  codeBlocks.forEach((block) => {
    const classList = Array.from(block.classList);
    const langClass = classList.find((cls: string) => cls.startsWith('language-'));
    const pre = block.parentElement;

    if (!pre) return;

    // Get raw code for copy button
    const rawCode = block.textContent || '';

    if (langClass) {
      const lang = langClass.replace('language-', '');

      // Add data-language attribute to <pre> for CSS language label
      pre.setAttribute('data-language', lang);

      if (Prism.languages[lang]) {
        try {
          const highlighted = Prism.highlight(rawCode, Prism.languages[lang], lang);

          // Wrap each line in .line element for line numbers
          // Remove trailing empty lines
          let lines = highlighted.split('\n');
          while (lines.length > 0 && !lines[lines.length - 1].trim()) {
            lines.pop();
          }
          const wrappedLines = lines.map(line => `<span class="line">${line || ' '}</span>`).join('\n');
          block.innerHTML = wrappedLines;
        } catch (err) {
          // Fallback: still wrap lines even if highlighting fails
          let lines = rawCode.split('\n');
          while (lines.length > 0 && !lines[lines.length - 1].trim()) {
            lines.pop();
          }
          const wrappedLines = lines.map(line => `<span class="line">${escapeHtml(line) || ' '}</span>`).join('\n');
          block.innerHTML = wrappedLines;
        }
      } else {
        // No syntax highlighting available, but still wrap lines
        let lines = rawCode.split('\n');
        while (lines.length > 0 && !lines[lines.length - 1].trim()) {
          lines.pop();
        }
        const wrappedLines = lines.map(line => `<span class="line">${escapeHtml(line) || ' '}</span>`).join('\n');
        block.innerHTML = wrappedLines;
      }
    } else {
      // No language specified - treat as plain text (e.g., WHERE blocks)
      // Check if it's a WHERE block or similar
      const isWhereBlock = rawCode.trim().startsWith('WHERE');

      if (isWhereBlock) {
        pre.setAttribute('data-language', '');  // No language label for WHERE blocks
      }

      // Still wrap lines for line numbers
      // Remove trailing empty lines
      let lines = rawCode.split('\n');
      while (lines.length > 0 && !lines[lines.length - 1].trim()) {
        lines.pop();
      }
      const wrappedLines = lines.map(line => `<span class="line">${escapeHtml(line) || ' '}</span>`).join('\n');
      block.innerHTML = wrappedLines;
    }

    // Add copy button to all code blocks
    const copyButton = doc.createElement('button');
    copyButton.className = 'copy-button';
    copyButton.setAttribute('data-code', rawCode);
    copyButton.setAttribute('aria-label', 'Copy code');

    // Mark as short if 3 lines or fewer (hide until hover to avoid overlap with language label)
    const lineCount = rawCode.split('\n').filter(line => line.trim()).length;
    if (lineCount <= 3) {
      copyButton.setAttribute('data-short', 'true');
    }

    copyButton.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" /></svg>`;
    pre.appendChild(copyButton);
  });

  // Add IDs to headings for TOC navigation
  const headings = doc.querySelectorAll('h1, h2, h3, h4, h5, h6');
  headings.forEach((heading) => {
    const text = heading.textContent?.trim() || '';
    const id = generateAnchorId(text);
    heading.id = id;
    heading.classList.add('scroll-mt-24');
  });

  // Make tables sortable
  const tables = doc.querySelectorAll('table');
  tables.forEach((table) => {
    const headers = table.querySelectorAll('th');
    headers.forEach((th) => {
      th.classList.add('sortable');
    });
  });

  // Fix Unicode character encoding issues
  let fixedHtml = doc.body.innerHTML;
  fixedHtml = fixedHtml
    .replace(/�/g, '→')
    .replace(/◆/g, '→')
    .replace(/\u25C6/g, '→')
    .replace(/×/g, '×')
    .replace(/\s@\s/g, ' × ')
    .replace(/→\s+/g, '→ ')
    .replace(/<li>\s*\*\s*/g, '<li>');

  // Restore math blocks - handle both escaped and unescaped comment forms
  mathBlocks.forEach(({ placeholder, html: mathHtml }) => {
    // Match the placeholder in various escaped forms
    const escaped = placeholder.replace('<!--', '&lt;!--').replace('-->', '--&gt;');
    fixedHtml = fixedHtml.replace(placeholder, mathHtml);
    fixedHtml = fixedHtml.replace(escaped, mathHtml);
    // Also handle when wrapped in <p> tags
    fixedHtml = fixedHtml.replace(`<p>${placeholder}</p>`, mathHtml);
    fixedHtml = fixedHtml.replace(`<p>${escaped}</p>`, mathHtml);
  });

  return fixedHtml;
}

async function compileMarkdownFiles(files: string[], docsDir: string, legalDir: string): Promise<Record<string, CompiledDoc>> {
  const compiledDocs: Record<string, CompiledDoc> = {};

  for (const filePath of files) {
    const baseDir = filePath.includes('/legal/') ? legalDir : docsDir;
    const slug = generateSlugFromPath(filePath, baseDir);
    const relativePath = relative(baseDir, filePath).replace(/\\/g, '/');
    const pathParts = relativePath.split('/');
    const title = basename(filePath, '.md');
    const category = pathParts.length > 1 ? pathParts[0] : null;
    const content = await readFile(filePath, 'utf-8');

    try {
      const html = await renderMarkdown(content);
      compiledDocs[slug] = {
        slug,
        title,
        html,
        category,
      };
    } catch (err) {
      console.error(`Failed to compile ${slug}:`, err);
    }
  }

  // Close browser after all docs are compiled
  await closeBrowser();

  return compiledDocs;
}

async function main() {
  const docsDir = join(import.meta.dir, '../docs');
  const legalDir = join(import.meta.dir, '../front/public/legal');
  const outputDir = join(import.meta.dir, '../front/public/compiled-docs');

  // If files are provided as arguments, compile only those files
  const args = process.argv.slice(2);

  if (args.length > 0 && !args[0].startsWith('--output=')) {
    // Worker mode: compile specific files and write to temp file
    const outputFile = args[0];
    const files = args.slice(1).filter(f => existsSync(f));
    const compiled = await compileMarkdownFiles(files, docsDir, legalDir);
    await writeFile(outputFile, JSON.stringify(compiled));
    return;
  }

  // Main mode: collect all files and spawn workers
  if (!existsSync(docsDir)) {
    console.error('Docs directory not found:', docsDir);
    process.exit(1);
  }

  // Ensure output directory exists
  await mkdir(outputDir, { recursive: true });

  // Get all markdown files
  const docsFiles = await getAllMarkdownFiles(docsDir);
  const legalFiles = existsSync(legalDir) ? await getAllMarkdownFiles(legalDir) : [];
  const allFiles = [...docsFiles, ...legalFiles];

  console.log(`Found ${allFiles.length} markdown files`);

  // Split files into chunks for parallel processing
  const numWorkers = Math.min(8, Math.max(2, Math.floor(allFiles.length / 4)));
  const chunkSize = Math.ceil(allFiles.length / numWorkers);
  const chunks: string[][] = [];

  for (let i = 0; i < allFiles.length; i += chunkSize) {
    chunks.push(allFiles.slice(i, i + chunkSize));
  }

  console.log(`Spawning ${chunks.length} workers (${chunkSize} files each)...`);

  // Spawn worker processes
  const workers = chunks.map(async (chunk, idx) => {
    const tmpFile = join(outputDir, `worker-${idx}.json`);

    const proc = Bun.spawn({
      cmd: ['bun', import.meta.path, tmpFile, ...chunk],
      stderr: 'inherit',
    });

    await proc.exited;

    if (proc.exitCode !== 0) {
      throw new Error(`Worker ${idx} failed with exit code ${proc.exitCode}`);
    }

    const result = JSON.parse(await readFile(tmpFile, 'utf-8')) as Record<string, CompiledDoc>;

    // Clean up temp file
    try {
      await Bun.file(tmpFile).delete();
    } catch {}

    return result;
  });

  // Wait for all workers to complete
  const results = await Promise.all(workers);

  // Merge results
  const compiledDocs: Record<string, CompiledDoc> = {};
  for (const result of results) {
    Object.assign(compiledDocs, result);
  }

  console.log(`✓ Compiled ${Object.keys(compiledDocs).length} documents`);

  // Write compiled docs as a single JSON file
  const outputPath = join(outputDir, 'docs.json');
  await writeFile(outputPath, JSON.stringify(compiledDocs, null, 2));

  // Also create a gzipped version for production
  const gzippedContent = await Bun.gzipSync(new TextEncoder().encode(JSON.stringify(compiledDocs)));
  await writeFile(join(outputDir, 'docs.json.gz'), gzippedContent);

  const originalSize = JSON.stringify(compiledDocs).length;
  const gzippedSize = gzippedContent.length;
  console.log(`Original: ${(originalSize / 1024).toFixed(2)} KB`);
  console.log(`Gzipped: ${(gzippedSize / 1024).toFixed(2)} KB (${((gzippedSize / originalSize) * 100).toFixed(1)}% compression)`);
}

main().catch(console.error);
