export interface SearchDoc {
  id: string;
  title: string;
  content: string;
  url: string;
  category?: string;
  headings: { level: number; text: string; anchor: string }[];
  excerpt?: string;
}

export interface SearchRes {
  id: string;
  title: string;
  url: string;
  category?: string;
  excerpt?: string;
  matchedText?: string;
  score: number;
}

class SearchService {
  private idx: any;
  private docs = new Map<string, SearchDoc>();
  private init = false;
  private flexPromise: Promise<any> | null = null;

  private async getFlex() {
    return (this.flexPromise ||= import("flexsearch").then((m) => m.Index));
  }

  private async initIdx() {
    if (!this.idx) {
      const Idx = await this.getFlex();
      this.idx = new Idx({
        preset: "performance",
        tokenize: "forward",
        cache: 100,
        resolution: 9,
      });
    }
  }

  async initialize() {
    if (this.init) return;

    await this.initIdx();

    try {
      let docs: SearchDoc[];

      try {
        const res = await fetch("/search-index.json.gz");
        if (res.ok) {
          const buf = await res.arrayBuffer();
          const stream = new ReadableStream({
            start(c) {
              c.enqueue(new Uint8Array(buf));
              c.close();
            },
          });
          const reader = stream
            .pipeThrough(new DecompressionStream("gzip"))
            .getReader();
          const chunks: Uint8Array[] = [];
          let done = false;

          while (!done) {
            const { value, done: d } = await reader.read();
            done = d;
            if (value) chunks.push(value);
          }

          const total = chunks.reduce((s, c) => s + c.length, 0);
          const result = new Uint8Array(total);
          let offset = 0;
          for (const c of chunks) {
            result.set(c, offset);
            offset += c.length;
          }

          docs = JSON.parse(new TextDecoder().decode(result));
        } else {
          throw new Error("Compressed not available");
        }
      } catch {
        const res = await fetch("/search-index.json");
        if (!res.ok) throw new Error(`Failed to load: ${res.statusText}`);
        docs = await res.json();
      }

      this.docs.clear();

      docs.forEach((doc, i) => {
        this.docs.set(doc.id, doc);
        const content = [
          doc.title,
          doc.content,
          doc.category,
          doc.headings.map((h) => h.text).join(" "),
        ]
          .filter(Boolean)
          .join(" ");
        this.idx.add(i, content);
      });

      this.init = true;
      console.log(`Search initialized: ${docs.length} docs`);
    } catch (e) {
      console.error("Search init failed:", e);
    }
  }

  async search(q: string, limit = 10): Promise<SearchRes[]> {
    if (!this.init) await this.initialize();
    if (!q.trim() || q.length < 2) return [];

    try {
      const results = this.idx.search(q, { limit: limit * 2 });
      const docsArr = Array.from(this.docs.values());
      const qLower = q.toLowerCase();

      const searchRes: SearchRes[] = results
        .map((i: number) => {
          const doc = docsArr[i];
          if (!doc) return null;

          const titleMatch = doc.title.toLowerCase().includes(qLower);
          const contentMatch = doc.content.toLowerCase().includes(qLower);
          const score = (titleMatch ? 10 : 0) + (contentMatch ? 5 : 1);

          return {
            id: doc.id,
            title: doc.title,
            url: doc.url,
            category: doc.category,
            excerpt: doc.excerpt,
            matchedText: this.findMatch(doc, q),
            score,
          };
        })
        .filter(Boolean);

      const unique = new Map<string, SearchRes>();
      searchRes
        .sort((a, b) => b.score - a.score)
        .forEach((r) => {
          if (!unique.has(r.url)) unique.set(r.url, r);
        });

      return Array.from(unique.values()).slice(0, limit);
    } catch (e) {
      console.error("Search error:", e);
      return [];
    }
  }

  private findMatch(doc: SearchDoc, q: string): string {
    const qLower = q.toLowerCase();
    const content = doc.content.toLowerCase();
    const idx = content.indexOf(qLower);

    if (idx === -1) return doc.excerpt || `${doc.content.substring(0, 100)}...`;

    const start = Math.max(0, idx - 50);
    const end = Math.min(doc.content.length, idx + q.length + 50);
    const ctx = doc.content.substring(start, end);

    return (
      (start > 0 ? "..." : "") + ctx + (end < doc.content.length ? "..." : "")
    );
  }

  highlight(text: string, q: string): string {
    if (!q.trim()) return text;
    const regex = new RegExp(
      `(${q.replace(/[-\\^$*+?.()|[\]{}]/g, "\\$&")})`,
      "gi",
    );
    return text.replace(
      regex,
      '<mark class="bg-primary/20 text-primary! font-medium">$1</mark>',
    );
  }
}

export const searchService = new SearchService();
export const search = searchService; // Legacy alias
export type SearchResult = SearchRes;
