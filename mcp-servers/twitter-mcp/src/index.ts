import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { TwitterApi } from "twitter-api-v2";
import * as keytar from "keytar";

const SERVICE_NAME = "baku-twitter";

let twitterClient: TwitterApi | null = null;

const server = new Server(
  { name: "twitter-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

const tools = [
  {
    name: "twitter_get_dms",
    description: "Get recent DM conversations",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Max conversations (default: 20)" },
      },
    },
  },
  {
    name: "twitter_get_mentions",
    description: "Get tweets mentioning you",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Max mentions (default: 20)" },
      },
    },
  },
  {
    name: "twitter_send_dm",
    description: "Send a DM to a user",
    inputSchema: {
      type: "object" as const,
      properties: {
        userId: { type: "string", description: "Recipient user ID" },
        text: { type: "string", description: "Message text" },
      },
      required: ["userId", "text"],
    },
  },
  {
    name: "twitter_reply",
    description: "Reply to a tweet",
    inputSchema: {
      type: "object" as const,
      properties: {
        tweetId: { type: "string", description: "Tweet ID to reply to" },
        text: { type: "string", description: "Reply text" },
      },
      required: ["tweetId", "text"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "twitter_get_dms":
      return await getDMs(args as { limit?: number });
    case "twitter_get_mentions":
      return await getMentions(args as { limit?: number });
    case "twitter_send_dm":
      return await sendDM(args as { userId: string; text: string });
    case "twitter_reply":
      return await replyToTweet(args as { tweetId: string; text: string });
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function getClient(): Promise<TwitterApi> {
  if (!twitterClient) {
    const accessToken = await keytar.getPassword(SERVICE_NAME, "access_token");
    const accessSecret = await keytar.getPassword(SERVICE_NAME, "access_secret");

    if (!accessToken || !accessSecret) {
      throw new Error("Not authenticated. Run OAuth flow first.");
    }

    const appKey = process.env.TWITTER_API_KEY;
    const appSecret = process.env.TWITTER_API_SECRET;

    if (!appKey || !appSecret) {
      throw new Error("Missing TWITTER_API_KEY or TWITTER_API_SECRET");
    }

    twitterClient = new TwitterApi({
      appKey,
      appSecret,
      accessToken,
      accessSecret,
    });
  }
  return twitterClient;
}

async function getDMs(args: { limit?: number }) {
  const client = await getClient();

  try {
    const dmEvents = await client.v2.listDmEvents({
      max_results: Math.min(args.limit || 20, 100),
      "dm_event.fields": ["created_at", "sender_id", "text"],
    });

    const dms = dmEvents.data?.map((event) => ({
      id: event.id,
      senderId: event.sender_id,
      text: event.text,
      createdAt: event.created_at,
    })) || [];

    return { content: [{ type: "text", text: JSON.stringify(dms, null, 2) }] };
  } catch (error: any) {
    // DM API is restricted, return helpful error
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          error: "DM access requires elevated API access",
          message: error.message,
        }, null, 2),
      }],
    };
  }
}

async function getMentions(args: { limit?: number }) {
  const client = await getClient();

  const me = await client.v2.me();
  const mentions = await client.v2.userMentionTimeline(me.data.id, {
    max_results: Math.min(args.limit || 20, 100),
    "tweet.fields": ["created_at", "author_id", "text"],
  });

  const formatted = mentions.data?.data?.map((tweet) => ({
    id: tweet.id,
    authorId: tweet.author_id,
    text: tweet.text,
    createdAt: tweet.created_at,
  })) || [];

  return { content: [{ type: "text", text: JSON.stringify(formatted, null, 2) }] };
}

async function sendDM(args: { userId: string; text: string }) {
  const client = await getClient();

  try {
    const result = await client.v2.sendDmToParticipant(args.userId, {
      text: args.text,
    });

    return {
      content: [{
        type: "text",
        text: JSON.stringify({ sent: true, eventId: result.data.dm_event_id }, null, 2),
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

async function replyToTweet(args: { tweetId: string; text: string }) {
  const client = await getClient();

  const result = await client.v2.reply(args.text, args.tweetId);

  return {
    content: [{
      type: "text",
      text: JSON.stringify({ tweetId: result.data.id, sent: true }, null, 2),
    }],
  };
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Twitter MCP server running");
}

main().catch(console.error);
