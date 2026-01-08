import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "markets-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

// Yahoo Finance symbols
const INDICES = ["^GSPC", "^DJI", "^IXIC", "^VIX"];
const TOP_STOCKS = ["AAPL", "MSFT", "NVDA", "GOOGL", "AMZN", "META", "TSLA"];
const CRYPTO_IDS = ["bitcoin", "ethereum", "solana"];

const tools = [
  {
    name: "markets_pulse",
    description: "Get morning markets snapshot - indices, top stocks, crypto",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "markets_stock",
    description: "Get quote for a specific stock symbol",
    inputSchema: {
      type: "object" as const,
      properties: {
        symbol: { type: "string", description: "Stock ticker symbol (e.g., AAPL)" },
      },
      required: ["symbol"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "markets_pulse":
      return await getMarketsPulse();
    case "markets_stock":
      return await getStockQuote(args as { symbol: string });
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

interface YahooQuote {
  symbol: string;
  regularMarketPrice: number;
  regularMarketChange: number;
  regularMarketChangePercent: number;
  shortName?: string;
}

interface CoinGeckoPrice {
  [id: string]: {
    usd: number;
    usd_24h_change: number;
  };
}

async function fetchYahooQuotes(symbols: string[]): Promise<YahooQuote[]> {
  const url = `https://query1.finance.yahoo.com/v7/finance/quote?symbols=${symbols.join(",")}`;

  try {
    const response = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0" },
    });

    if (!response.ok) throw new Error(`Yahoo API error: ${response.status}`);

    const data = await response.json() as { quoteResponse: { result: YahooQuote[] } };
    return data.quoteResponse.result || [];
  } catch (error: any) {
    console.error("Yahoo fetch error:", error.message);
    return [];
  }
}

async function fetchCryptoPrices(): Promise<CoinGeckoPrice> {
  const url = `https://api.coingecko.com/api/v3/simple/price?ids=${CRYPTO_IDS.join(",")}&vs_currencies=usd&include_24hr_change=true`;

  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`CoinGecko API error: ${response.status}`);
    return await response.json() as CoinGeckoPrice;
  } catch (error: any) {
    console.error("CoinGecko fetch error:", error.message);
    return {};
  }
}

function formatChange(change: number, percent: number): string {
  const sign = change >= 0 ? "+" : "";
  return `${sign}${change.toFixed(2)} (${sign}${percent.toFixed(2)}%)`;
}

async function getMarketsPulse() {
  try {
    // Fetch all data in parallel
    const [indices, stocks, crypto] = await Promise.all([
      fetchYahooQuotes(INDICES),
      fetchYahooQuotes(TOP_STOCKS),
      fetchCryptoPrices(),
    ]);

    // Format indices
    const indexNames: Record<string, string> = {
      "^GSPC": "S&P 500",
      "^DJI": "Dow Jones",
      "^IXIC": "NASDAQ",
      "^VIX": "VIX",
    };

    const indicesFormatted = indices.map((q) => ({
      name: indexNames[q.symbol] || q.symbol,
      price: q.regularMarketPrice.toFixed(2),
      change: formatChange(q.regularMarketChange, q.regularMarketChangePercent),
      direction: q.regularMarketChange >= 0 ? "up" : "down",
    }));

    // Format stocks
    const stocksFormatted = stocks.map((q) => ({
      symbol: q.symbol,
      price: q.regularMarketPrice.toFixed(2),
      change: formatChange(q.regularMarketChange, q.regularMarketChangePercent),
      direction: q.regularMarketChange >= 0 ? "up" : "down",
    }));

    // Format crypto
    const cryptoNames: Record<string, string> = {
      bitcoin: "BTC",
      ethereum: "ETH",
      solana: "SOL",
    };

    const cryptoFormatted = Object.entries(crypto).map(([id, data]) => ({
      symbol: cryptoNames[id] || id.toUpperCase(),
      price: data.usd.toLocaleString("en-US", { style: "currency", currency: "USD" }),
      change: `${data.usd_24h_change >= 0 ? "+" : ""}${data.usd_24h_change.toFixed(2)}%`,
      direction: data.usd_24h_change >= 0 ? "up" : "down",
    }));

    const pulse = {
      type: "markets_pulse",
      timestamp: new Date().toISOString(),
      indices: indicesFormatted,
      stocks: stocksFormatted,
      crypto: cryptoFormatted,
      summary: generateSummary(indicesFormatted, stocksFormatted, cryptoFormatted),
    };

    return {
      content: [{ type: "text", text: JSON.stringify(pulse, null, 2) }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ error: error.message, type: "markets_pulse" }, null, 2),
      }],
    };
  }
}

function generateSummary(
  indices: { name: string; change: string; direction: string }[],
  stocks: { symbol: string; change: string; direction: string }[],
  crypto: { symbol: string; change: string; direction: string }[]
): string {
  const sp500 = indices.find((i) => i.name === "S&P 500");
  const vix = indices.find((i) => i.name === "VIX");

  let summary = "";

  if (sp500) {
    summary += `Markets ${sp500.direction === "up" ? "up" : "down"} (S&P ${sp500.change}). `;
  }

  if (vix) {
    const vixLevel = parseFloat(vix.change);
    if (vixLevel > 20) summary += "Elevated volatility. ";
  }

  const bigMovers = stocks.filter((s) => {
    const pct = parseFloat(s.change.match(/\((.*?)%\)/)?.[1] || "0");
    return Math.abs(pct) > 2;
  });

  if (bigMovers.length > 0) {
    summary += `Notable: ${bigMovers.map((s) => `${s.symbol} ${s.change}`).join(", ")}. `;
  }

  const btc = crypto.find((c) => c.symbol === "BTC");
  if (btc) {
    summary += `BTC ${btc.change}.`;
  }

  return summary || "Markets relatively quiet.";
}

async function getStockQuote(args: { symbol: string }) {
  try {
    const quotes = await fetchYahooQuotes([args.symbol.toUpperCase()]);

    if (quotes.length === 0) {
      return {
        content: [{
          type: "text",
          text: JSON.stringify({ error: `No data for ${args.symbol}` }, null, 2),
        }],
      };
    }

    const q = quotes[0];
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          symbol: q.symbol,
          name: q.shortName,
          price: q.regularMarketPrice.toFixed(2),
          change: formatChange(q.regularMarketChange, q.regularMarketChangePercent),
          direction: q.regularMarketChange >= 0 ? "up" : "down",
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ error: error.message }, null, 2),
      }],
    };
  }
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Markets MCP server running");
}

main().catch(console.error);
