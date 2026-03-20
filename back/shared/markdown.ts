/**
 * Minimal markdown renderer for agent responses
 * Subset of scripts/precompile-markdown.ts for runtime use
 * Now using Bun's native markdown parser
 */
import Prism from 'prismjs';
import loadLanguages from 'prismjs/components/index.js';

// Load common languages
loadLanguages(['javascript', 'typescript', 'json', 'bash', 'sql', 'solidity']);

export interface RenderMarkdownOptions {
  includeMermaid?: boolean;
  includeCopyButton?: boolean;
}

/**
 * Render markdown to HTML for agent responses
 * Simplified version without mermaid/math/chart support
 */
export async function renderMarkdown(
  content: string,
  options: RenderMarkdownOptions = {}
): Promise<string> {
  const { includeCopyButton = false } = options;

  // Parse markdown with Bun.markdown
  // @ts-expect-error - Bun.markdown types may not be updated yet
  let html = Bun.markdown.html(content, {
    gfm: true,
    latexMath: true,
  });

  // Apply syntax highlighting with Prism
  const codeBlockRegex = /<pre><code class="language-([^"]*)">([\s\S]*?)<\/code><\/pre>/g;
  html = html.replace(codeBlockRegex, (match: string, lang: string, code: string) => {
    // Decode HTML entities
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
        highlighted = rawCode;
      }
    }

    // Wrap each line
    const lines = highlighted.split('\n').filter((l: string) => l.trim());
    const wrappedLines = lines.map((line: string) => `<span class="line">${line || ' '}</span>`).join('\n');

    // Optional copy button
    let copyButton = '';
    if (includeCopyButton) {
      const codeForAttr = rawCode
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
      copyButton = `<button class="copy-button" data-code="${codeForAttr}" aria-label="Copy code"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" /></svg></button>`;
    }

    return `<pre data-language="${lang}"><code class="language-${lang}">${highlighted}</code>${copyButton}</pre>`;
  });

  return html;
}
