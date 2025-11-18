// Dynamic docs utilities that load JSON data at runtime
export interface DocFile {
  slug: string;
  title: string;
  content: string;
  frontMatter: Record<string, any>;
  category?: string | null;
}

export interface DocStructure {
  name: string;
  path: string;
  type: "file" | "directory";
  children?: DocStructure[];
}

// Simple in-memory cache for loaded docs
const docCache = new Map<string, DocFile>();
let docsStructureCache: DocStructure[] | null = null;

// Load docs structure from JSON
export async function getDocStructure(): Promise<DocStructure[]> {
  if (docsStructureCache) {
    return docsStructureCache;
  }

  try {
    const response = await fetch("/docs-structure.json");
    if (!response.ok) {
      throw new Error(`Failed to load docs structure: ${response.status}`);
    }

    docsStructureCache = await response.json();
    return docsStructureCache || [];
  } catch (error) {
    console.error("Error loading docs structure:", error);
    return [];
  }
}

export async function getDocBySlug(slug: string): Promise<DocFile | null> {
  // Check cache first
  if (docCache.has(slug)) {
    return docCache.get(slug)!;
  }

  try {
    // Attempt to load the document from the public docs folder
    const response = await fetch(`/docs/${slug}.md`);
    if (!response.ok) {
      return null;
    }

    const content = await response.text();

    // Extract category from slug
    const pathParts = slug.split("/");
    const category = pathParts.length > 1 ? pathParts[0] : null;

    // Generate title from slug (last part of path) - handle proper file names with spaces
    const lastPart = pathParts[pathParts.length - 1];

    // Decode URI components first to handle %20 and other encoded characters
    const decodedPart = decodeURIComponent(lastPart);

    const title = decodedPart.includes(" ")
      ? decodedPart // If already contains spaces, use as-is
      : decodedPart
          .split("-")
          .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
          .join(" ");

    const docFile: DocFile = {
      slug,
      title,
      content,
      frontMatter: {},
      category,
    };

    // Cache the result
    docCache.set(slug, docFile);

    return docFile;
  } catch (error) {
    console.error("Error loading doc:", error);
    return null;
  }
}

export async function getDocCategories(): Promise<string[]> {
  const structure = await getDocStructure();
  return structure.map((item) => item.name);
}

export async function getAllDocs(): Promise<DocFile[]> {
  const docs: DocFile[] = [];

  // This is a simplified version that would need to be expanded
  // For now, return empty array as this function isn't used by the current UI
  return docs;
}
