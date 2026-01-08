import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "news-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

// RSS feeds - tech and AI focused
const FEEDS = {
  hackernews: "https://hnrss.org/frontpage?count=10",
  verge: "https://www.theverge.com/rss/index.xml",
  arstechnica: "https://feeds.arstechnica.com/arstechnica/technology-lab",
  techcrunch: "https://techcrunch.com/feed/",
};

const AI_FEEDS = {
  openai: "https://openai.com/blog/rss.xml",
  anthropic: "https://www.anthropic.com/rss.xml",
};

const tools = [
  {
    name: "news_pulse",
    description: "Get tech news headlines from HN, Verge, Ars Technica, TechCrunch",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Max headlines per source (default: 5)" },
      },
    },
  },
  {
    name: "news_ai",
    description: "Get latest AI company blog posts (OpenAI, Anthropic)",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "news_hn_top",
    description: "Get top Hacker News stories with scores",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Number of stories (default: 10)" },
      },
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "news_pulse":
      return await getNewsPulse(args as { limit?: number });
    case "news_ai":
      return await getAINews();
    case "news_hn_top":
      return await getHNTop(args as { limit?: number });
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

interface FeedItem {
  title: string;
  link: string;
  pubDate?: string;
  description?: string;
}

async function fetchRSS(url: string): Promise<FeedItem[]> {
  try {
    const response = await fetch(url, {
      headers: { "User-Agent": "Baku/1.0" },
    });

    if (!response.ok) throw new Error(`RSS fetch error: ${response.status}`);

    const xml = await response.text();
    return parseRSS(xml);
  } catch (error: any) {
    console.error(`RSS fetch error for ${url}:`, error.message);
    return [];
  }
}

function parseRSS(xml: string): FeedItem[] {
  const items: FeedItem[] = [];

  // Simple regex-based RSS parsing (works for most feeds)
  const itemRegex = /<item>([\s\S]*?)<\/item>/gi;
  const titleRegex = /<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?<\/title>/i;
  const linkRegex = /<link>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?<\/link>/i;
  const pubDateRegex = /<pubDate>(.*?)<\/pubDate>/i;
  const descRegex = /<description>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/description>/i;

  let match;
  while ((match = itemRegex.exec(xml)) !== null) {
    const itemXml = match[1];

    const titleMatch = titleRegex.exec(itemXml);
    const linkMatch = linkRegex.exec(itemXml);
    const pubDateMatch = pubDateRegex.exec(itemXml);
    const descMatch = descRegex.exec(itemXml);

    if (titleMatch && linkMatch) {
      items.push({
        title: decodeHTMLEntities(titleMatch[1].trim()),
        link: linkMatch[1].trim(),
        pubDate: pubDateMatch?.[1],
        description: descMatch ? decodeHTMLEntities(descMatch[1].trim()).slice(0, 200) : undefined,
      });
    }
  }

  return items;
}

function decodeHTMLEntities(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/<[^>]*>/g, ""); // Strip HTML tags
}

function timeAgo(dateStr: string | undefined): string {
  if (!dateStr) return "";

  const date = new Date(dateStr);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffHrs = Math.floor(diffMs / (1000 * 60 * 60));

  if (diffHrs < 1) return "just now";
  if (diffHrs < 24) return `${diffHrs}h ago`;
  const diffDays = Math.floor(diffHrs / 24);
  return `${diffDays}d ago`;
}

async function getNewsPulse(args: { limit?: number }) {
  const limit = args.limit || 5;

  try {
    // Fetch all feeds in parallel
    const feedResults = await Promise.all(
      Object.entries(FEEDS).map(async ([source, url]) => {
        const items = await fetchRSS(url);
        return {
          source,
          items: items.slice(0, limit).map((item) => ({
            title: item.title,
            link: item.link,
            time: timeAgo(item.pubDate),
          })),
        };
      })
    );

    const pulse = {
      type: "news_pulse",
      timestamp: new Date().toISOString(),
      feeds: feedResults.filter((f) => f.items.length > 0),
      topHeadlines: feedResults
        .flatMap((f) => f.items.map((i) => ({ ...i, source: f.source })))
        .slice(0, 10),
    };

    return {
      content: [{ type: "text", text: JSON.stringify(pulse, null, 2) }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ error: error.message, type: "news_pulse" }, null, 2),
      }],
    };
  }
}

async function getAINews() {
  try {
    const feedResults = await Promise.all(
      Object.entries(AI_FEEDS).map(async ([source, url]) => {
        const items = await fetchRSS(url);
        return {
          source,
          items: items.slice(0, 5).map((item) => ({
            title: item.title,
            link: item.link,
            time: timeAgo(item.pubDate),
            description: item.description,
          })),
        };
      })
    );

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          type: "ai_news",
          timestamp: new Date().toISOString(),
          companies: feedResults,
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ error: error.message, type: "ai_news" }, null, 2),
      }],
    };
  }
}

interface HNStory {
  id: number;
  title: string;
  url?: string;
  score: number;
  by: string;
  descendants: number;
}

async function getHNTop(args: { limit?: number }) {
  const limit = args.limit || 10;

  try {
    // Fetch top story IDs
    const topRes = await fetch("https://hacker-news.firebaseio.com/v0/topstories.json");
    const topIds = (await topRes.json()) as number[];

    // Fetch story details (first N)
    const stories = await Promise.all(
      topIds.slice(0, limit).map(async (id) => {
        const res = await fetch(`https://hacker-news.firebaseio.com/v0/item/${id}.json`);
        return (await res.json()) as HNStory;
      })
    );

    const formatted = stories.map((s, i) => ({
      rank: i + 1,
      title: s.title,
      url: s.url || `https://news.ycombinator.com/item?id=${s.id}`,
      score: s.score,
      comments: s.descendants || 0,
      by: s.by,
      hnLink: `https://news.ycombinator.com/item?id=${s.id}`,
    }));

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          type: "hn_top",
          timestamp: new Date().toISOString(),
          stories: formatted,
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ error: error.message, type: "hn_top" }, null, 2),
      }],
    };
  }
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("News MCP server running");
}

main().catch(console.error);
