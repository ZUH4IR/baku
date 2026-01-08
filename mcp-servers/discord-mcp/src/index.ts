import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { Client, GatewayIntentBits, ChannelType } from "discord.js";
import * as keytar from "keytar";

const SERVICE_NAME = "baku-discord";

let discordClient: Client | null = null;

const server = new Server(
  { name: "discord-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

const tools = [
  {
    name: "discord_list_dms",
    description: "List recent DM conversations",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Max DMs (default: 20)" },
      },
    },
  },
  {
    name: "discord_get_messages",
    description: "Get messages from a DM or channel",
    inputSchema: {
      type: "object" as const,
      properties: {
        channelId: { type: "string", description: "Channel/DM ID" },
        limit: { type: "number", description: "Max messages (default: 20)" },
      },
      required: ["channelId"],
    },
  },
  {
    name: "discord_send",
    description: "Send a message to a channel or DM",
    inputSchema: {
      type: "object" as const,
      properties: {
        channelId: { type: "string", description: "Channel/DM ID" },
        content: { type: "string", description: "Message content" },
      },
      required: ["channelId", "content"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "discord_list_dms":
      return await listDMs(args as { limit?: number });
    case "discord_get_messages":
      return await getMessages(args as { channelId: string; limit?: number });
    case "discord_send":
      return await sendMessage(args as { channelId: string; content: string });
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function getClient(): Promise<Client> {
  if (!discordClient) {
    const token = await keytar.getPassword(SERVICE_NAME, "token");
    if (!token) throw new Error("Not authenticated. Add Discord bot token.");

    discordClient = new Client({
      intents: [
        GatewayIntentBits.DirectMessages,
        GatewayIntentBits.DirectMessageTyping,
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
      ],
    });

    await discordClient.login(token);
  }
  return discordClient;
}

async function listDMs(args: { limit?: number }) {
  const client = await getClient();

  // Get DM channels from cache
  const dmChannels = client.channels.cache
    .filter((ch) => ch.type === ChannelType.DM)
    .map((ch) => {
      const dm = ch as any;
      return {
        id: ch.id,
        recipient: dm.recipient?.username || "Unknown",
        recipientId: dm.recipient?.id,
      };
    })
    .slice(0, args.limit || 20);

  return { content: [{ type: "text", text: JSON.stringify(dmChannels, null, 2) }] };
}

async function getMessages(args: { channelId: string; limit?: number }) {
  const client = await getClient();
  const channel = await client.channels.fetch(args.channelId);

  if (!channel || !("messages" in channel)) {
    throw new Error("Invalid channel or no message access");
  }

  const messages = await (channel as any).messages.fetch({ limit: args.limit || 20 });

  const formatted = messages.map((msg: any) => ({
    id: msg.id,
    author: msg.author.username,
    content: msg.content,
    timestamp: msg.createdAt.toISOString(),
    attachments: msg.attachments.size,
  }));

  return { content: [{ type: "text", text: JSON.stringify(formatted, null, 2) }] };
}

async function sendMessage(args: { channelId: string; content: string }) {
  const client = await getClient();
  const channel = await client.channels.fetch(args.channelId);

  if (!channel || !("send" in channel)) {
    throw new Error("Invalid channel or cannot send messages");
  }

  const msg = await (channel as any).send(args.content);

  return {
    content: [{
      type: "text",
      text: JSON.stringify({ id: msg.id, sent: true }, null, 2),
    }],
  };
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Discord MCP server running");
}

main().catch(console.error);
