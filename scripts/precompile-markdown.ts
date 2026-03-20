#!/usr/bin/env bun

/**
 * Pre-compile all markdown files to HTML at build time.
 * This eliminates the need for markdown-wasm, prismjs, asciimath2ml, and mermaid in the runtime bundle.
 */

import { readdir, readFile, writeFile, mkdir } from 'fs/promises';
import { join, relative, basename } from 'path';
import { existsSync } from 'fs';
import Prism from 'prismjs';
import loadLanguages from 'prismjs/components/index.js';
import { asciiToMathML } from 'asciimath2ml';
import { slugifyDoc, generateAnchorId } from '../sdk/src/utils/format.js';
import { chromium, type Browser } from 'playwright';
import { logger } from '../sdk/src/utils/logger.js';

const log = logger.withContext('precompile-markdown');

// Load Prism languages
loadLanguages(['javascript', 'typescript', 'jsx', 'tsx', 'json', 'bash', 'sql', 'markdown', 'solidity']);

interface CompiledDoc {
  slug: string;
  title: string;
  html: string;
  category: string | null;
  prev?: { path: string; label: string } | null;
  next?: { path: string; label: string } | null;
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
      nodeBorder: '#E99339',         // primary (orange)
      nodeTextColor: '#fafafa',      // fg-0 (white)

      // Edge/arrow colors
      lineColor: '#7f7f7c',          // fg-2 (muted)
      arrowheadColor: '#E99339',     // primary (orange)

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
      activationBkgColor: '#E99339', // primary (orange)
      activationBorderColor: '#c47310',

      // Class diagram colors
      classText: '#fafafa',

      // State diagram colors
      labelColor: '#fafafa',

      // Sequence diagram colors
      actorBkg: '#2a2a2a',
      actorBorder: '#E99339',
      actorTextColor: '#fafafa',
      actorLineColor: '#7f7f7c',
      signalColor: '#cbcac3',
      signalTextColor: '#fafafa',

      // Git diagram colors
      git0: '#3d7eff',               // blue
      git1: '#10B981',               // green
      git2: '#E99339',               // orange
      git3: '#DB4E5C',               // red
      git4: '#ffd61e',               // yellow
      git5: '#2ee7e7',               // cyan
      git6: '#e94cef',               // pink
      git7: '#a273f5',               // violet

      // Gantt chart colors
      gridColor: '#3d3d3d',
      todayLineColor: '#E99339',

      // Pie chart colors
      pie1: '#3d7eff',               // blue
      pie2: '#10B981',               // green
      pie3: '#E99339',               // orange
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
      nodeBorder: '#E99339',         // primary (orange)
      nodeTextColor: '#1B1B1B',      // fg-0 (black)

      // Edge/arrow colors
      lineColor: '#7f7f7f',          // fg-2 (muted)
      arrowheadColor: '#E99339',     // primary (orange)

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
      activationBkgColor: '#E99339', // primary (orange)
      activationBorderColor: '#c47310',

      // Class diagram colors
      classText: '#1B1B1B',

      // State diagram colors
      labelColor: '#1B1B1B',

      // Sequence diagram colors
      actorBkg: '#d9d8d4',
      actorBorder: '#E99339',
      actorTextColor: '#1B1B1B',
      actorLineColor: '#7f7f7f',
      signalColor: '#363636',
      signalTextColor: '#1B1B1B',

      // Git diagram colors
      git0: '#3d7eff',               // blue
      git1: '#10B981',               // green
      git2: '#E99339',               // orange
      git3: '#DB4E5C',               // red
      git4: '#ffd61e',               // yellow
      git5: '#2ee7e7',               // cyan
      git6: '#e94cef',               // pink
      git7: '#a273f5',               // violet

      // Gantt chart colors
      gridColor: '#bfbfbf',
      todayLineColor: '#E99339',

      // Pie chart colors
      pie1: '#3d7eff',               // blue
      pie2: '#10B981',               // green
      pie3: '#E99339',               // orange
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

async function getAllMarkdownFiles(dir: string, baseDir: string = dir): Promise<string[]> {
  const files: string[] = [];

  // Verify the path exists and is a directory before calling readdir
  try {
    const stat = await Bun.file(dir).stat();
    if (!stat.isDirectory) {
      return files;
    }
  } catch {
    return files;
  }

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

// Removed: escapeHtml function was unnecessary and caused double-encoding issues
// Prism.highlight() returns safe HTML that can be inserted directly into the DOM

/**
 * Normalize math expression for AsciiMath parsing.
 *
 * NOTE: All LaTeX-to-AsciiMath conversions have been removed as obsolete.
 * The documentation now uses proper AsciiMath syntax throughout.
 * This function is kept for backward compatibility in case future normalization is needed.
 */
function normalizeMathExpr(expr: string): string {
  // Documentation uses proper AsciiMath syntax - no normalization needed
  return expr;
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
  }).join('');

  return `<math display="${display}"><mstyle displaystyle="true">${lhsMathML}<mo>=</mo><mrow><mo stretchy="true" fence="true">{</mo><mtable columnspacing="1em" rowspacing="0.5em">${rows}</mtable></mrow></mstyle></math>`;
}

export interface RenderMarkdownOptions {
  includeMermaid?: boolean;
  includeCopyButton?: boolean;
}

/**
 * Unified markdown renderer - handles both docs compilation and agent responses.
 *
 * Supports:
 * - Markdown (GFM) with marked.js
 * - AsciiMath: $$...$$ (display), $...$ (inline), ```math blocks
 * - Syntax highlighting with Prism.js
 * - Mermaid diagrams (optional)
 * - Charts (Chartist.js) with ```chart blocks
 * - Tables with sortable headers
 *
 * @param content - Raw markdown content
 * @param options - Rendering options
 * @returns Compiled HTML
 */
export async function renderMarkdown(content: string, options: RenderMarkdownOptions = {}): Promise<string> {
  const { includeMermaid = true, includeCopyButton = true } = options;

  // Track math, mermaid, and chart placeholders
  const mathBlocks: { placeholder: string; html: string }[] = [];
  const chartBlocks: { placeholder: string; config: string }[] = [];
  let mathCounter = 0;
  let chartCounter = 0;
  
  let processedContent = content;
  
  // Handle ```chart blocks (Chartist.js charts)
  const chartMatches = [...content.matchAll(/```chart\n([\s\S]+?)\n```/g)];
  for (const match of chartMatches) {
    const chartConfig = match[1].trim();
    try {
      // Validate JSON config
      JSON.parse(chartConfig);

      // Create placeholder with embedded config
      const placeholder = `<!--CHART${chartCounter}-->`;
      chartBlocks.push({ placeholder, config: chartConfig });
      processedContent = processedContent.replace(match[0], placeholder);
      chartCounter++;
    } catch (err) {
      // Silent failure - leave as code block if JSON is invalid
      log.warn('Invalid chart config JSON:', err);
    }
  }

  // Handle ```mermaid blocks (optional)
  if (includeMermaid) {
    const mermaidMatches = [...content.matchAll(/```mermaid\s*([\s\S]+?)\s*```/g)];
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
        processedContent = processedContent.replace(match[0], placeholder);
        mathCounter++;

        // Silent success
      } catch (err) {
        // Silent failure - leave code block as-is if rendering fails
      }
    }
  }

  // Merge consecutive $$...$$ blocks into single multi-line math block
  // Pattern: $$expr1$$\n\n$$expr2$$\n\n$$expr3$$ -> separate lines with spacing
  processedContent = processedContent.replace(
    /(\$\$[^$]+?\$\$(?:\s*\n\s*\n?\s*\$\$[^$]+?\$\$)+)/g,
    (multiBlock) => {
      // Extract all expressions from consecutive blocks
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
        const html = `<div class="math-block math-multiline">${mathMLParts.join('')}</div>`;
        mathBlocks.push({ placeholder, html });
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
        mathBlocks.push({ placeholder, html: `<div class="math-block">${piecewise}</div>` });
        mathCounter++;
        return placeholder;
      }

      const normalized = normalizeMathExpr(trimmed);
      const mathML = asciiToMathML(normalized, false);
      const placeholder = `<!--MATHBLOCK${mathCounter}-->`;
      const html = `<div class="math-block">${mathML}</div>`;
      mathBlocks.push({ placeholder, html });
      mathCounter++;
      return placeholder;
    } catch (err) {
      // Silent failure - keep original
      return match;
    }
  });

  // Replace inline math $...$ with placeholders
  // Only match if contains math operators/symbols: ^, _, *, /, =, ', greek letters, or parentheses
  processedContent = processedContent.replace(/\$([^$\n]+?)\$/g, (match, math) => {
    const trimmed = math.trim();
    // Check if it looks like actual math:
    // - Single letters/variables (e.g., $k$, $R$, $c$)
    // - Contains operators, subscripts, or special symbols (including prime ')
    // - Greek letters or math functions
    const isMath = /^[a-zA-Z]$/.test(trimmed) ||
      /[=^_*/'()<>\\]|alpha|beta|gamma|delta|sigma|lambda|phi|pi|theta|omega|rho|eta|psi|nu|mu|tau|epsilon|kappa|chi|zeta|xi|iota|upsilon|sqrt|sum|int|frac|cdot|times|div|bar|max|min|abs/i.test(trimmed);

    if (!isMath) {
      // Not math, just a dollar amount - leave it as is
      return match;
    }

    try {
      // Try piecewise for inline
      const piecewise = renderPiecewise(trimmed, false);
      if (piecewise) {
        const placeholder = `<!--MATHINLINE${mathCounter}-->`;
        mathBlocks.push({ placeholder, html: `<span class="math-inline">${piecewise}</span>` });
        mathCounter++;
        return placeholder;
      }

      const normalized = normalizeMathExpr(trimmed);
      let mathML = asciiToMathML(normalized, true);
      // Fix displaystyle for inline math - should be false for compact rendering
      mathML = mathML.replace(/displaystyle="true"/g, 'displaystyle="false"');
      const placeholder = `<!--MATHINLINE${mathCounter}-->`;
      const html = `<span class="math-inline">${mathML}</span>`;
      mathBlocks.push({ placeholder, html });
      mathCounter++;
      return placeholder;
    } catch (err) {
      // Silent failure - keep original
      return match;
    }
  });

  // Parse markdown with Bun.markdown
  let html = Bun.markdown.html(processedContent, {
    gfm: true,
    latexMath: true,
  });

  // Apply syntax highlighting with Prism
  const codeBlockRegex = /<pre><code class="language-([^"]*)">([\s\S]*?)<\/code><\/pre>/g;
  html = html.replace(codeBlockRegex, (match, lang, code) => {
    // Decode HTML entities to get raw code (marked may encode some characters)
    const rawCode = code
      .replace(/<[^>]+>/g, '')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#039;/g, "'");

    // Highlight with Prism if language is supported
    let highlighted = rawCode;
    if (lang && Prism.languages[lang]) {
      try {
        highlighted = Prism.highlight(rawCode, Prism.languages[lang], lang);
      } catch {
        // If Prism fails, use raw code (already decoded)
        highlighted = rawCode;
      }
    }

    // Wrap each line in .line element
    const lines = highlighted.split('\n').filter((l: string) => l.trim());
    const wrappedLines = lines.map((line: string) => `<span class="line">${line || ' '}</span>`).join('\n');

    // Add copy button only if requested (false for agent responses, handled in frontend)
    let copyButton = '';
    if (includeCopyButton) {
      const lineCount = rawCode.split('\n').filter(l => l.trim()).length;
      const shortAttr = lineCount <= 3 ? ' data-short="true"' : '';

      // Escape rawCode for HTML attribute (but NOT for the code content)
      const codeForAttr = rawCode
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');

      copyButton = `<button class="copy-button" data-code="${codeForAttr}" aria-label="Copy code"${shortAttr}><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" /></svg></button>`;
    }

    return `<pre data-language="${lang}"><code class="language-${lang}">${highlighted}</code>${copyButton}</pre>`;
  });

  // Add IDs to headings
  const headingRegex = /<(h[1-6])([^>]*)>([\s\S]*?)<\/\1>/g;
  html = html.replace(headingRegex, (match, tag, attrs, content) => {
    const text = content.replace(/<[^>]+>/g, '').trim();
    const id = generateAnchorId(text);
    return `<${tag}${attrs} id="${id}" class="scroll-mt-24">${content}</${tag}>`;
  });

  // Make table headers sortable
  html = html.replace(/<th([^>]*)>/g, '<th$1 class="sortable">');
  
  let fixedHtml = html;
  
  // Restore math blocks - handle both escaped and unescaped comment forms
  mathBlocks.forEach(({ placeholder, html: mathHtml }) => {
    // Match placeholder in various escaped forms
    const escaped = placeholder.replace('<!--', '&lt;!--').replace('-->', '--&gt;');
    fixedHtml = fixedHtml.replace(placeholder, mathHtml);
    fixedHtml = fixedHtml.replace(escaped, mathHtml);
    // Also handle when wrapped in <p> tags
    fixedHtml = fixedHtml.replace(`<p>${placeholder}</p>`, mathHtml);
    fixedHtml = fixedHtml.replace(`<p>${escaped}</p>`, mathHtml);
  });

  // Restore chart blocks - convert placeholders to data attributes for frontend rendering
  chartBlocks.forEach(({ placeholder, config }) => {
    const encodedConfig = encodeURIComponent(config);
    const escaped = placeholder.replace('<!--', '&lt;!--').replace('-->', '--&gt;');

    // Create chart container with data attribute
    const html = `<div class="chart-container" data-chart-config="${encodedConfig}"></div>`;

    fixedHtml = fixedHtml.replace(placeholder, html);
    fixedHtml = fixedHtml.replace(escaped, html);
    // Also handle when wrapped in <p> tags
    fixedHtml = fixedHtml.replace(`<p>${placeholder}</p>`, html);
    fixedHtml = fixedHtml.replace(`<p>${escaped}</p>`, html);
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
      log.error(`Failed to compile ${slug}:`, err);
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
    log.error('Docs directory not found:', docsDir);
    process.exit(1);
  }

  // Ensure output directory exists
  await mkdir(outputDir, { recursive: true });

  // Get all markdown files
  const docsFiles = await getAllMarkdownFiles(docsDir);
  const legalFiles = existsSync(legalDir) ? await getAllMarkdownFiles(legalDir) : [];
  const allFiles = [...docsFiles, ...legalFiles];

  log.info(`Found ${allFiles.length} markdown files`);

  // Split files into chunks for parallel processing
  const numWorkers = Math.min(8, Math.max(2, Math.floor(allFiles.length / 4)));
  const chunkSize = Math.ceil(allFiles.length / numWorkers);
  const chunks: string[][] = [];

  for (let i = 0; i < allFiles.length; i += chunkSize) {
    chunks.push(allFiles.slice(i, i + chunkSize));
  }

  log.info(`Spawning ${chunks.length} workers (${chunkSize} files each)...`);

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

  log.info(`✓ Compiled ${Object.keys(compiledDocs).length} documents`);

  // Add prev/next navigation to each doc
  const sortKey = (slug: string) => {
    // Special ordering for top-level docs
    const order: Record<string, number> = {
      'overview': 0,
      'manifesto': 1,
      'foundations': 2,
      'glossary': 999,
    };

    if (order[slug] !== undefined) {
      return `0-${order[slug].toString().padStart(3, '0')}`;
    }

    // Extract numeric prefix for sorting (e.g., "1.1.6" from "1.1.6-toxic-flow-mitigation")
    const match = slug.match(/^([\d.]+)/);
    if (match) {
      const parts = match[1].split('.').map(n => n.padStart(3, '0'));
      return `1-${parts.join('.')}`;
    }

    return `2-${slug}`;
  };

  const orderedSlugs = Object.keys(compiledDocs).sort((a, b) => sortKey(a).localeCompare(sortKey(b)));

  // Add prev/next to each doc
  for (let i = 0; i < orderedSlugs.length; i++) {
    const slug = orderedSlugs[i];
    const doc = compiledDocs[slug];

    doc.prev = i > 0 ? {
      path: `/docs/${orderedSlugs[i - 1]}`,
      label: compiledDocs[orderedSlugs[i - 1]].title
    } : null;

    doc.next = i < orderedSlugs.length - 1 ? {
      path: `/docs/${orderedSlugs[i + 1]}`,
      label: compiledDocs[orderedSlugs[i + 1]].title
    } : null;
  }

  // Write compiled docs as a single JSON file
  const outputPath = join(outputDir, 'docs.json');
  await writeFile(outputPath, JSON.stringify(compiledDocs, null, 2));

  // Also create a gzipped version for production
  const gzippedContent = await Bun.gzipSync(new TextEncoder().encode(JSON.stringify(compiledDocs)));
  await writeFile(join(outputDir, 'docs.json.gz'), gzippedContent);

  const originalSize = JSON.stringify(compiledDocs).length;
  const gzippedSize = gzippedContent.length;
  log.info(`Original: ${(originalSize / 1024).toFixed(2)} KB`);
  log.info(`Gzipped: ${(gzippedSize / 1024).toFixed(2)} KB (${((gzippedSize / originalSize) * 100).toFixed(1)}% compression)`);
}

main().catch((err) => {
  log.error('Fatal error:', err);
  process.exit(1);
});
