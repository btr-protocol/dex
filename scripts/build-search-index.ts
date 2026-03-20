#!/usr/bin/env bun

import fs from "fs";
import path from "path";
import { gzipSync } from "zlib";
import MiniSearch from "minisearch";
import { slugifyDoc, generateAnchorId } from "../sdk/src/utils/format.js";
import { logger } from "../sdk/src/utils/logger.js";

const log = logger.withContext('build-search-index');

interface SearchDocument {
  id: string;
  title: string;
  content: string;
  url: string;
  category?: string;
  headings: Array<{
    level: number;
    text: string;
    anchor: string;
  }>;
  excerpt?: string;
}

interface DocStructure {
  name: string;
  path: string;
  type: "file" | "directory";
  children?: DocStructure[];
}

const docsDirectory = path.join(__dirname, "../docs");
const compiledDocsDir = path.join(__dirname, "../front/public/compiled-docs");
const outputPath = path.join(compiledDocsDir, "search-index.json");
const outputPathGz = path.join(compiledDocsDir, "search-index.json.gz");
const docsStructureOutputPath = path.join(compiledDocsDir, "docs-structure.json");
const docsStructureOutputPathGz = path.join(compiledDocsDir, "docs-structure.json.gz");

// Extract frontmatter from markdown (simple parser, no gray-matter bloat)
function parseFrontmatter(content: string): { data: Record<string, any>; content: string } {
  const frontmatterRegex = /^---\s*\n([\s\S]*?)\n---\s*\n([\s\S]*)$/;
  const match = content.match(frontmatterRegex);

  if (!match) {
    return { data: {}, content };
  }

  const [, frontmatterText, markdownContent] = match;
  const data: Record<string, any> = {};

  // Parse simple YAML-like frontmatter
  frontmatterText.split('\n').forEach(line => {
    const colonIndex = line.indexOf(':');
    if (colonIndex > 0) {
      const key = line.substring(0, colonIndex).trim();
      const value = line.substring(colonIndex + 1).trim().replace(/^["']|["']$/g, '');
      data[key] = value;
    }
  });

  return { data, content: markdownContent };
}

// NB: generateAnchorId is now imported from SDK (../sdk/src/utils/format.js)

// Strip markdown formatting (simple, no need for full parser)
function stripMarkdown(markdown: string): string {
  return markdown
    // Remove code blocks
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`[^`]+`/g, ' ')
    // Remove links but keep text
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    // Remove images
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '')
    // Remove headings markers
    .replace(/^#{1,6}\s+/gm, '')
    // Remove bold/italic
    .replace(/[*_]{1,2}([^*_]+)[*_]{1,2}/g, '$1')
    // Remove horizontal rules
    .replace(/^[-*_]{3,}\s*$/gm, '')
    // Remove blockquotes
    .replace(/^>\s+/gm, '')
    // Remove HTML tags
    .replace(/<[^>]*>/g, ' ')
    // Normalize whitespace
    .replace(/\s+/g, ' ')
    .trim();
}

// Extract headings from markdown content
function extractHeadings(
  content: string,
): Array<{ level: number; text: string; anchor: string }> {
  const headings: Array<{ level: number; text: string; anchor: string }> = [];
  const headingRegex = /^(#{1,6})\s+(.+)$/gm;
  let match;

  while ((match = headingRegex.exec(content)) !== null) {
    const level = match[1].length;
    const text = match[2].trim();
    const anchor = generateAnchorId(text);
    headings.push({ level, text, anchor });
  }

  return headings;
}

// Recursively get all markdown files
function getAllMarkdownFiles(dirPath: string, relativePath = ""): string[] {
  const files: string[] = [];

  if (!fs.existsSync(dirPath)) {
    log.warn(`Directory does not exist: ${dirPath}`);
    return files;
  }

  const items = fs.readdirSync(dirPath);

  items.forEach((item) => {
    if (item.startsWith(".")) return; // Skip hidden files

    const fullPath = path.join(dirPath, item);
    const itemPath = relativePath ? path.join(relativePath, item) : item;

    if (fs.statSync(fullPath).isDirectory()) {
      files.push(...getAllMarkdownFiles(fullPath, itemPath));
    } else if (item.endsWith(".md") || item.endsWith(".mdx")) {
      files.push(itemPath);
    }
  });

  return files;
}

// Generate docs structure recursively
function generateDocsStructure(dirPath: string, relativePath = ""): DocStructure[] {
  const structure: DocStructure[] = [];

  if (!fs.existsSync(dirPath)) {
    log.warn(`Directory does not exist: ${dirPath}`);
    return structure;
  }

  const items = fs.readdirSync(dirPath);

  items.forEach((item) => {
    if (item.startsWith(".")) return; // Skip hidden files

    const fullPath = path.join(dirPath, item);
    const itemPath = relativePath ? path.join(relativePath, item) : item;
    const normalizedPath = itemPath.replace(/\\/g, "/");

    if (fs.statSync(fullPath).isDirectory()) {
      const children = generateDocsStructure(fullPath, itemPath);
      if (children.length > 0) {
        // Use directory name as-is for display
        const displayName = item;
        structure.push({
          name: displayName,
          path: normalizedPath,
          type: "directory",
          children: children
        });
      }
    } else if (item.endsWith(".md") || item.endsWith(".mdx")) {
      const fileName = path.basename(item, path.extname(item));
      structure.push({
        name: fileName,
        path: slugifyDoc(fileName, relativePath),
        type: "file"
      });
    }
  });

  // Sort: Overview first, then numbered sections, then Foundations/Manifesto/Glossary
  const sortItems = (items: DocStructure[]) => {
    items.sort((a, b) => {
      // Overview always first
      if (a.name === "Overview") return -1;
      if (b.name === "Overview") return 1;

      // Extract full numeric prefix (e.g., "1.1.2" from "1.1.2. Title")
      const aNumMatch = a.name.match(/^([\d.]+)\.\s/);
      const bNumMatch = b.name.match(/^([\d.]+)\.\s/);

      if (aNumMatch && bNumMatch) {
        // Split into parts and compare numerically
        const aParts = aNumMatch[1].split('.').map(n => parseInt(n, 10));
        const bParts = bNumMatch[1].split('.').map(n => parseInt(n, 10));

        // Compare each part numerically
        const maxLen = Math.max(aParts.length, bParts.length);
        for (let i = 0; i < maxLen; i++) {
          const aVal = aParts[i] || 0;
          const bVal = bParts[i] || 0;
          if (aVal !== bVal) return aVal - bVal;
        }
        return 0; // Equal
      }

      // Numbered items come before non-numbered
      if (aNumMatch) return -1;
      if (bNumMatch) return 1;

      // Foundations before Manifesto/Glossary
      if (a.name === "Foundations") return -1;
      if (b.name === "Foundations") return 1;

      // Default: alphabetical
      return a.name.localeCompare(b.name);
    });

    // Sort children recursively
    items.forEach(item => {
      if (item.children) sortItems(item.children);
    });
  };

  sortItems(structure);

  return structure;
}

// Generate the docs structure JSON files
function generateDocsStructureFiles(docsStructure: DocStructure[]) {
  // Create output directory if it doesn't exist
  const outputDir = path.dirname(docsStructureOutputPath);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  // Write uncompressed and gzipped versions
  const jsonContent = JSON.stringify(docsStructure, null, 2);
  fs.writeFileSync(docsStructureOutputPath, jsonContent);

  const compressedContent = gzipSync(Buffer.from(jsonContent));
  fs.writeFileSync(docsStructureOutputPathGz, compressedContent);
}

// Generate search index
async function generateSearchIndex() {
  log.info("Building search index...");

  const markdownFiles = getAllMarkdownFiles(docsDirectory);
  const documents: SearchDocument[] = [];
  const seenIds = new Set<string>();

  for (const filePath of markdownFiles) {
    try {
      const fullPath = path.join(docsDirectory, filePath);
      const fileContents = fs.readFileSync(fullPath, "utf8");
      const { data, content } = parseFrontmatter(fileContents);

      // Generate slug from filename, store original path for reference
      const fileName = path.basename(filePath, path.extname(filePath));
      const pathParts = filePath.split('/');
      const category = pathParts.length > 1 ? pathParts[0] : undefined;
      const slug = slugifyDoc(fileName, category);

      // Use filename as title if not provided in frontmatter
      const title =
        data.title || path.basename(filePath, path.extname(filePath));

      // Extract headings from content
      const headings = extractHeadings(content);

      // Strip markdown to get plain text
      const plainTextContent = stripMarkdown(content);

      // Create excerpt (first 200 characters)
      const excerpt =
        plainTextContent.length > 200
          ? plainTextContent.substring(0, 200) + "..."
          : plainTextContent;

      // Create search document
      const document: SearchDocument = {
        id: slug,
        title,
        content: plainTextContent,
        url: `/docs/${slug}`,
        category,
        headings,
        excerpt,
      };

      if (!seenIds.has(document.id)) {
        documents.push(document);
        seenIds.add(document.id);
      }

      // Also create entries for each heading (for more granular search)
      headings.forEach((heading, idx) => {
        if (heading.level <= 3) {
          // Only include h1, h2, h3 as separate entries
          // Make ID unique by appending index if duplicate
          let headingId = `${slug}#${heading.anchor}`;
          if (seenIds.has(headingId)) {
            headingId = `${slug}#${heading.anchor}-${idx}`;
          }

          if (!seenIds.has(headingId)) {
            documents.push({
              id: headingId,
              title: `${title} - ${heading.text}`,
              content: heading.text,
              url: `/docs/${slug}#${heading.anchor}`,
              category,
              headings: [],
              excerpt: `${heading.text} (from ${title})`,
            });
            seenIds.add(headingId);
          }
        }
      });
    } catch (error) {
      log.error(`Error processing file ${filePath}:`, error);
    }
  }

  // Create output directory if it doesn't exist
  const outputDir = path.dirname(outputPath);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  // Create MiniSearch index
  const miniSearch = new MiniSearch({
    fields: ['title', 'content', 'category'],
    storeFields: ['title', 'url', 'excerpt', 'category'],
    searchOptions: {
      boost: { title: 2 },
      fuzzy: 0.2,
      prefix: true,
    }
  });

  miniSearch.addAll(documents);

  // Export index for client-side use
  const indexData = {
    index: miniSearch.toJSON(),
    documents: documents.map(doc => ({
      id: doc.id,
      title: doc.title,
      url: doc.url,
      content: doc.content, // Full content for searching
      excerpt: doc.excerpt, // Short excerpt for display
      category: doc.category,
    }))
  };

  // Write uncompressed and gzipped versions
  const jsonContent = JSON.stringify(indexData);
  fs.writeFileSync(outputPath, jsonContent);

  const compressedContent = gzipSync(Buffer.from(jsonContent));
  fs.writeFileSync(outputPathGz, compressedContent);

  const originalSize = jsonContent.length;
  const compressedSize = compressedContent.length;
  const compressionRatio = ((originalSize - compressedSize) / originalSize * 100).toFixed(1);

  // Generate docs structure
  const docsStructure = generateDocsStructure(docsDirectory);
  generateDocsStructureFiles(docsStructure);

  const docsStructureOriginalSize = fs.statSync(docsStructureOutputPath).size;
  const docsStructureCompressedSize = fs.statSync(docsStructureOutputPathGz).size;
  const docsStructureCompressionRatio = ((docsStructureOriginalSize - docsStructureCompressedSize) / docsStructureOriginalSize * 100).toFixed(1);

  log.info(`Done: ${markdownFiles.length} files, ${documents.length} entries`);
  log.info(`  index: ${(originalSize / 1024).toFixed(0)}KB -> ${(compressedSize / 1024).toFixed(0)}KB (${compressionRatio}%)`);
  log.info(`  structure: ${(docsStructureOriginalSize / 1024).toFixed(1)}KB -> ${(docsStructureCompressedSize / 1024).toFixed(1)}KB (${docsStructureCompressionRatio}%)`);
}

// Run the script
if (import.meta.main) {
  generateSearchIndex().catch((err) => {
    log.error('Fatal error:', err);
    process.exit(1);
  });
}

export { generateSearchIndex };
