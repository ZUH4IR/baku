import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import * as keytar from "keytar";

const SERVICE_NAME = "baku-grok";
const XAI_API_URL = "https://api.x.ai/v1/chat/completions";

const server = new Server(
  { name: "grok-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

const tools = [
  {
    name: "grok_tech_pulse",
    description: "Get a pulse on what's happening in tech Twitter right now - trending topics, discussions, and insights",
    inputSchema: {
      type: "object" as const,
      properties: {
        focus: {
          type: "string",
          description: "Optional focus area (e.g., 'AI', 'startups', 'crypto', 'frontend')",
        },
      },
    },
  },
  {
    name: "grok_analyze_topic",
    description: "Deep dive into a specific tech topic - what people are saying, sentiment, key voices",
    inputSchema: {
      type: "object" as const,
      properties: {
        topic: { type: "string", description: "Topic to analyze" },
      },
      required: ["topic"],
    },
  },
  {
    name: "grok_auth_status",
    description: "Check Grok API connection status",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "grok_tech_pulse":
      return await getTechPulse(args as { focus?: string });
    case "grok_analyze_topic":
      return await analyzeTopic(args as { topic: string });
    case "grok_auth_status":
      return await checkAuthStatus();
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function getApiKey(): Promise<string> {
  // Try keychain first
  const keychainKey = await keytar.getPassword(SERVICE_NAME, "api_key");
  if (keychainKey) return keychainKey;

  // Fall back to environment variable
  const envKey = process.env.GROK_API_KEY;
  if (envKey) return envKey;

  throw new Error("Grok API key not configured. Set GROK_API_KEY or add via settings.");
}

async function callGrok(prompt: string): Promise<string> {
  const apiKey = await getApiKey();

  const response = await fetch(XAI_API_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: "grok-3-latest",
      messages: [
        {
          role: "system",
          content: "You are Grok, an AI with real-time access to X/Twitter. Provide concise, insightful summaries of what's happening on tech Twitter. Be direct and informative. Use bullet points for clarity.",
        },
        {
          role: "user",
          content: prompt,
        },
      ],
      temperature: 0.7,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Grok API error: ${response.status} - ${error}`);
  }

  const data = await response.json() as {
    choices: Array<{ message: { content: string } }>;
  };

  return data.choices[0]?.message?.content || "No response from Grok";
}

async function getTechPulse(args: { focus?: string }) {
  const focusArea = args.focus ? ` focusing on ${args.focus}` : "";

  const prompt = `What's happening on tech Twitter right now${focusArea}? Give me the pulse:

1. Top 3-5 trending discussions or topics
2. Any breaking news or announcements
3. Notable takes or debates
4. Interesting threads worth reading

Keep it concise and actionable. Format as a morning briefing.`;

  try {
    const response = await callGrok(prompt);

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          type: "tech_pulse",
          focus: args.focus || "general",
          timestamp: new Date().toISOString(),
          pulse: response,
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          error: error.message,
          type: "tech_pulse",
        }, null, 2),
      }],
    };
  }
}

async function analyzeTopic(args: { topic: string }) {
  const prompt = `Analyze what tech Twitter is saying about "${args.topic}":

1. Overall sentiment (bullish/bearish/mixed)
2. Key points being discussed
3. Notable voices weighing in
4. Any contrarian takes
5. What you should know

Be specific and cite real discussions if possible.`;

  try {
    const response = await callGrok(prompt);

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          type: "topic_analysis",
          topic: args.topic,
          timestamp: new Date().toISOString(),
          analysis: response,
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          error: error.message,
          type: "topic_analysis",
        }, null, 2),
      }],
    };
  }
}

async function checkAuthStatus() {
  try {
    const apiKey = await getApiKey();
    const masked = apiKey.slice(0, 8) + "..." + apiKey.slice(-4);

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          connected: true,
          apiKeyMasked: masked,
        }, null, 2),
      }],
    };
  } catch (error: any) {
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          connected: false,
          error: error.message,
        }, null, 2),
      }],
    };
  }
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Grok MCP server running");
}

main().catch(console.error);
