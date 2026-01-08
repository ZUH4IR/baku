import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "predictions-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

const POLYMARKET_API = "https://gamma-api.polymarket.com";

const tools = [
  {
    name: "predictions_pulse",
    description: "Get trending prediction markets from Polymarket - see what people are betting on",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Number of markets (default: 15)" },
      },
    },
  },
  {
    name: "predictions_search",
    description: "Search prediction markets by keyword",
    inputSchema: {
      type: "object" as const,
      properties: {
        query: { type: "string", description: "Search term (e.g., 'Trump', 'AI', 'Bitcoin')" },
      },
      required: ["query"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "predictions_pulse":
      return await getPredictionsPulse(args as { limit?: number });
    case "predictions_search":
      return await searchPredictions(args as { query: string });
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

interface PolymarketEvent {
  id: string;
  title: string;
  slug: string;
  volume: number;
  liquidity: number;
  markets: PolymarketMarket[];
}

interface PolymarketMarket {
  id: string;
  question: string;
  outcomePrices: string; // JSON string like "[0.65, 0.35]"
  outcomes: string; // JSON string like "[\"Yes\", \"No\"]"
  volume: number;
}

async function fetchPolymarketEvents(limit: number = 15): Promise<PolymarketEvent[]> {
  try {
    const url = `${POLYMARKET_API}/events?closed=false&order=volume&ascending=false&limit=${limit}`;

    const response = await fetch(url, {
      headers: {
        "User-Agent": "Baku/1.0",
        "Accept": "application/json",
      },
    });

    if (!response.ok) {
      throw new Error(`Polymarket API error: ${response.status}`);
    }

    return (await response.json()) as PolymarketEvent[];
  } catch (error: any) {
    console.error("Polymarket fetch error:", error.message);
    return [];
  }
}

async function searchPolymarketEvents(query: string): Promise<PolymarketEvent[]> {
  try {
    const url = `${POLYMARKET_API}/events?closed=false&title_contains=${encodeURIComponent(query)}&limit=10`;

    const response = await fetch(url, {
      headers: {
        "User-Agent": "Baku/1.0",
        "Accept": "application/json",
      },
    });

    if (!response.ok) {
      throw new Error(`Polymarket API error: ${response.status}`);
    }

    return (await response.json()) as PolymarketEvent[];
  } catch (error: any) {
    console.error("Polymarket search error:", error.message);
    return [];
  }
}

function formatVolume(volume: number): string {
  if (volume >= 1000000) {
    return `$${(volume / 1000000).toFixed(1)}M`;
  } else if (volume >= 1000) {
    return `$${(volume / 1000).toFixed(0)}K`;
  }
  return `$${volume.toFixed(0)}`;
}

function parseMarketOdds(market: PolymarketMarket): { outcome: string; probability: number }[] {
  try {
    const prices = JSON.parse(market.outcomePrices) as number[];
    const outcomes = JSON.parse(market.outcomes) as string[];

    return outcomes.map((outcome, i) => ({
      outcome,
      probability: Math.round(prices[i] * 100),
    }));
  } catch {
    return [];
  }
}

async function getPredictionsPulse(args: { limit?: number }) {
  const limit = args.limit || 15;

  try {
    const events = await fetchPolymarketEvents(limit);

    const formatted = events.map((event) => {
      const primaryMarket = event.markets?.[0];
      const odds = primaryMarket ? parseMarketOdds(primaryMarket) : [];

      return {
        title: event.title,
        volume: formatVolume(event.volume),
        volumeRaw: event.volume,
        url: `https://polymarket.com/event/${event.slug}`,
        odds: odds.length > 0 ? odds : undefined,
        topOutcome: odds.length > 0
          ? `${odds[0].outcome}: ${odds[0].probability}%`
          : undefined,
      };
    });

    // Generate summary of what's hot
    const topByVolume = formatted.slice(0, 5);
    const summary = topByVolume
      .map((m) => `${m.title} (${m.topOutcome || "N/A"})`)
      .join(" | ");

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          type: "predictions_pulse",
          timestamp: new Date().toISOString(),
          markets: formatted,
          summary: `Top bets: ${summary}`,
          totalVolume: formatVolume(events.reduce((sum, e) => sum + e.volume, 0)),
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ error: error.message, type: "predictions_pulse" }, null, 2),
      }],
    };
  }
}

async function searchPredictions(args: { query: string }) {
  try {
    const events = await searchPolymarketEvents(args.query);

    const formatted = events.map((event) => {
      const primaryMarket = event.markets?.[0];
      const odds = primaryMarket ? parseMarketOdds(primaryMarket) : [];

      return {
        title: event.title,
        volume: formatVolume(event.volume),
        url: `https://polymarket.com/event/${event.slug}`,
        odds,
      };
    });

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          type: "predictions_search",
          query: args.query,
          timestamp: new Date().toISOString(),
          results: formatted,
          count: formatted.length,
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ error: error.message, type: "predictions_search" }, null, 2),
      }],
    };
  }
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Predictions MCP server running");
}

main().catch(console.error);
