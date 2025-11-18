#!/usr/bin/env bun

import fs from "fs";
import path from "path";
import { gzipSync } from "zlib";
import matter from "gray-matter";
import { marked } from "marked";

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

const docsDirectory = path.join(__dirname, "../specs");
const frontPublicDir = path.join(__dirname, "../front/public");
const outputPath = path.join(frontPublicDir, "search-index.json");
const compressedOutputPath = path.join(frontPublicDir, "search-index.json.gz");
const docsStructureOutputPath = path.join(frontPublicDir, "docs-structure.json");
const docsStructureCompressedPath = path.join(frontPublicDir, "docs-structure.json.gz");

// Strip HTML tags and decode entities
function stripHtml(html: string): string {
  return html
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
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
    const anchor = text
      .toLowerCase()
      .replace(/[^a-z0-9\s-]/g, "")
      .replace(/\s+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "");

    headings.push({ level, text, anchor });
  }

  return headings;
}

// Recursively get all markdown files
function getAllMarkdownFiles(dirPath: string, relativePath = ""): string[] {
  const files: string[] = [];

  if (!fs.existsSync(dirPath)) {
    console.warn(`Directory does not exist: ${dirPath}`);
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
    console.warn(`Directory does not exist: ${dirPath}`);
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
        // Remove number prefix and underscore, convert to proper display name
        const displayName = item.replace(/^\d+_/, '').replace(/-/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
        structure.push({
          name: displayName,
          path: normalizedPath,
          type: "directory",
          children: children
        });
      }
    } else if (item.endsWith(".md") || item.endsWith(".mdx")) {
      // Convert file name to proper display name
      const fileName = path.basename(item, path.extname(item));
      const displayName = fileName.replace(/-/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
      const filePath = normalizedPath.replace(/\.mdx?$/, "");

      structure.push({
        name: displayName,
        path: filePath,
        type: "file"
      });
    }
  });

  // Sort structure: directories first, then files, alphabetically
  structure.sort((a, b) => {
    if (a.type !== b.type) {
      return a.type === "directory" ? -1 : 1;
    }
    return a.name.localeCompare(b.name);
  });

  return structure;
}

// Generate the docs structure JSON files
function generateDocsStructureFiles(docsStructure: DocStructure[]) {
  // Write JSON file
  const jsonContent = JSON.stringify(docsStructure, null, 2);
  fs.writeFileSync(docsStructureOutputPath, jsonContent);

  // Create compressed version
  const compressedContent = gzipSync(Buffer.from(jsonContent));
  fs.writeFileSync(docsStructureCompressedPath, compressedContent);
}

// Generate search index
async function generateSearchIndex() {
  console.log("🔍 Building search index and docs structure...");

  const markdownFiles = getAllMarkdownFiles(docsDirectory);
  const documents: SearchDocument[] = [];

  for (const filePath of markdownFiles) {
    try {
      const fullPath = path.join(docsDirectory, filePath);
      const fileContents = fs.readFileSync(fullPath, "utf8");
      const { data, content } = matter(fileContents);

      // Generate slug from file path
      const slug = filePath.replace(/\.mdx?$/, "").replace(/\\/g, "/");

      // Extract category from path
      const pathParts = slug.split("/");
      const category = pathParts.length > 1 ? pathParts[0] : undefined;

      // Use filename as title if not provided in frontmatter
      const title =
        data.title || path.basename(filePath, path.extname(filePath));

      // Extract headings from content
      const headings = extractHeadings(content);

      // Convert markdown to HTML then strip to get plain text
      const htmlContent = marked(content) as string;
      const plainTextContent = stripHtml(htmlContent);

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

      documents.push(document);

      // Also create entries for each heading (for more granular search)
      headings.forEach((heading) => {
        if (heading.level <= 3) {
          // Only include h1, h2, h3 as separate entries
          documents.push({
            id: `${slug}#${heading.anchor}`,
            title: `${title} - ${heading.text}`,
            content: heading.text,
            url: `/docs/${slug}#${heading.anchor}`,
            category,
            headings: [],
            excerpt: `${heading.text} (from ${title})`,
          });
        }
      });
    } catch (error) {
      console.error(`Error processing file ${filePath}:`, error);
    }
  }

  // Create output directory if it doesn't exist
  const outputDir = path.dirname(outputPath);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  // Write search index to JSON file
  const jsonContent = JSON.stringify(documents);
  fs.writeFileSync(outputPath, jsonContent);

  // Create compressed version
  const compressedContent = gzipSync(Buffer.from(jsonContent));
  fs.writeFileSync(compressedOutputPath, compressedContent);

  const originalSize = fs.statSync(outputPath).size;
  const compressedSize = fs.statSync(compressedOutputPath).size;
  const compressionRatio = ((originalSize - compressedSize) / originalSize * 100).toFixed(1);

  // Generate docs structure
  console.log("📁 Generating docs structure...");
  const docsStructure = generateDocsStructure(docsDirectory);

  generateDocsStructureFiles(docsStructure);

  const docsStructureOriginalSize = fs.statSync(docsStructureOutputPath).size;
  const docsStructureCompressedSize = fs.statSync(docsStructureCompressedPath).size;
  const docsStructureCompressionRatio = ((docsStructureOriginalSize - docsStructureCompressedSize) / docsStructureOriginalSize * 100).toFixed(1);

  console.log(`✅ Search index and docs structure built successfully!`);
  console.log(`   📄 Processed ${markdownFiles.length} files`);
  console.log(`   🔍 Generated ${documents.length} search entries`);
  console.log(`   💾 Search index: ${outputPath} (${(originalSize / 1024).toFixed(1)}KB)`);
  console.log(`   🗜️  Search compressed: ${compressedOutputPath} (${(compressedSize / 1024).toFixed(1)}KB, ${compressionRatio}% smaller)`);
  console.log(`   📁 Docs structure: ${docsStructureOutputPath} (${(docsStructureOriginalSize / 1024).toFixed(1)}KB)`);
  console.log(`   🗜️  Docs compressed: ${docsStructureCompressedPath} (${(docsStructureCompressedSize / 1024).toFixed(1)}KB, ${docsStructureCompressionRatio}% smaller)`);
}

// Run the script
if (import.meta.main) {
  generateSearchIndex().catch(console.error);
}

export { generateSearchIndex };
