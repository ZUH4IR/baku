import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { WebClient } from "@slack/web-api";
import * as keytar from "keytar";

const SERVICE_NAME = "baku-slack";

let slackClient: WebClient | null = null;

const server = new Server(
  { name: "slack-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

const tools = [
  {
    name: "slack_list_dms",
    description: "List recent direct message conversations",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Max conversations (default: 20)" },
      },
    },
  },
  {
    name: "slack_get_messages",
    description: "Get messages from a channel or DM",
    inputSchema: {
      type: "object" as const,
      properties: {
        channel: { type: "string", description: "Channel ID" },
        limit: { type: "number", description: "Max messages (default: 20)" },
      },
      required: ["channel"],
    },
  },
  {
    name: "slack_get_mentions",
    description: "Get messages where you were mentioned",
    inputSchema: {
      type: "object" as const,
      properties: {
        limit: { type: "number", description: "Max mentions (default: 20)" },
      },
    },
  },
  {
    name: "slack_post",
    description: "Post a message to a channel",
    inputSchema: {
      type: "object" as const,
      properties: {
        channel: { type: "string", description: "Channel ID" },
        text: { type: "string", description: "Message text" },
        thread_ts: { type: "string", description: "Thread timestamp (optional)" },
      },
      required: ["channel", "text"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "slack_list_dms":
      return await listDMs(args as { limit?: number });
    case "slack_get_messages":
      return await getMessages(args as { channel: string; limit?: number });
    case "slack_get_mentions":
      return await getMentions(args as { limit?: number });
    case "slack_post":
      return await postMessage(args as { channel: string; text: string; thread_ts?: string });
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function getClient(): Promise<WebClient> {
  if (!slackClient) {
    const token = await keytar.getPassword(SERVICE_NAME, "token");
    if (!token) throw new Error("Not authenticated. Run OAuth flow first.");
    slackClient = new WebClient(token);
  }
  return slackClient;
}

async function listDMs(args: { limit?: number }) {
  const client = await getClient();
  const result = await client.conversations.list({
    types: "im,mpim",
    limit: args.limit || 20,
  });

  const conversations = await Promise.all(
    (result.channels || []).map(async (ch) => {
      const info = ch.is_im && ch.user
        ? await client.users.info({ user: ch.user })
        : null;
      return {
        id: ch.id,
        type: ch.is_im ? "dm" : "group_dm",
        user: info?.user?.real_name || ch.user,
        username: info?.user?.name,
      };
    })
  );

  return { content: [{ type: "text", text: JSON.stringify(conversations, null, 2) }] };
}

async function getMessages(args: { channel: string; limit?: number }) {
  const client = await getClient();
  const result = await client.conversations.history({
    channel: args.channel,
    limit: args.limit || 20,
  });

  const messages = await Promise.all(
    (result.messages || []).map(async (msg) => {
      const userInfo = msg.user ? await client.users.info({ user: msg.user }).catch(() => null) : null;
      return {
        ts: msg.ts,
        user: userInfo?.user?.real_name || msg.user,
        text: msg.text,
        thread_ts: msg.thread_ts,
        reply_count: msg.reply_count,
      };
    })
  );

  return { content: [{ type: "text", text: JSON.stringify(messages, null, 2) }] };
}

async function getMentions(args: { limit?: number }) {
  const client = await getClient();
  const auth = await client.auth.test();
  const userId = auth.user_id;

  const result = await client.search.messages({
    query: `<@${userId}>`,
    count: args.limit || 20,
    sort: "timestamp",
  });

  const mentions = (result.messages?.matches || []).map((match) => ({
    channel: match.channel?.name,
    user: match.username,
    text: match.text,
    ts: match.ts,
    permalink: match.permalink,
  }));

  return { content: [{ type: "text", text: JSON.stringify(mentions, null, 2) }] };
}

async function postMessage(args: { channel: string; text: string; thread_ts?: string }) {
  const client = await getClient();
  const result = await client.chat.postMessage({
    channel: args.channel,
    text: args.text,
    thread_ts: args.thread_ts,
  });

  return {
    content: [{
      type: "text",
      text: JSON.stringify({ ok: result.ok, ts: result.ts }, null, 2),
    }],
  };
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Slack MCP server running");
}

main().catch(console.error);
