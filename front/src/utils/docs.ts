// Dynamic docs utilities that load JSON data at runtime
export interface DocFile {
  slug: string;
  title: string;
  content: string;
  frontMatter: Record<string, any>;
  category?: string | null;
  prev?: { path: string; label: string } | null;
  next?: { path: string; label: string } | null;
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
    // Load from compiled docs.json
    const response = await fetch('/compiled-docs/docs.json');
    if (!response.ok) {
      console.error('Failed to load compiled docs');
      return null;
    }

    const allDocs = await response.json();
    const doc = allDocs[slug];

    if (!doc) {
      console.error(`Doc not found: ${slug}`);
      return null;
    }

    const docFile: DocFile = {
      slug: doc.slug,
      title: doc.title,
      content: doc.html, // Using HTML from compiled docs
      frontMatter: {},
      category: doc.category,
      prev: doc.prev || null,
      next: doc.next || null,
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
  try {
    const response = await fetch('/compiled-docs/docs.json');
    if (!response.ok) {
      return [];
    }

    const allDocs = await response.json();
    return Object.values(allDocs).map((doc: any) => ({
      slug: doc.slug,
      title: doc.title,
      content: doc.html,
      frontMatter: {},
      category: doc.category,
      prev: doc.prev || null,
      next: doc.next || null,
    }));
  } catch (error) {
    console.error("Error loading all docs:", error);
    return [];
  }
}
