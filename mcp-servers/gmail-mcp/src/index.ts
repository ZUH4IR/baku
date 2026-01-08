import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { google } from "googleapis";
import * as keytar from "keytar";

// Constants
const SERVICE_NAME = "baku-gmail";
const SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"];

// OAuth client (will be configured with credentials)
let oauth2Client: any = null;

// Create MCP server
const server = new Server(
  {
    name: "gmail-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Tool definitions
const tools = [
  {
    name: "gmail_list_unread",
    description: "List unread emails from Gmail inbox",
    inputSchema: {
      type: "object" as const,
      properties: {
        maxResults: {
          type: "number",
          description: "Maximum number of emails to return (default: 20)",
        },
        query: {
          type: "string",
          description: "Optional Gmail search query",
        },
      },
    },
  },
  {
    name: "gmail_get_message",
    description: "Get full content of a specific email",
    inputSchema: {
      type: "object" as const,
      properties: {
        messageId: {
          type: "string",
          description: "The Gmail message ID",
        },
      },
      required: ["messageId"],
    },
  },
  {
    name: "gmail_get_thread",
    description: "Get all messages in an email thread",
    inputSchema: {
      type: "object" as const,
      properties: {
        threadId: {
          type: "string",
          description: "The Gmail thread ID",
        },
      },
      required: ["threadId"],
    },
  },
  {
    name: "gmail_auth_status",
    description: "Check Gmail authentication status",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
];

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "gmail_list_unread":
      return await listUnreadEmails(args as { maxResults?: number; query?: string });

    case "gmail_get_message":
      return await getMessage(args as { messageId: string });

    case "gmail_get_thread":
      return await getThread(args as { threadId: string });

    case "gmail_auth_status":
      return await checkAuthStatus();

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// Tool implementations

async function listUnreadEmails(args: { maxResults?: number; query?: string }) {
  const gmail = await getGmailClient();

  const query = args.query
    ? `is:unread ${args.query}`
    : "is:unread -category:promotions -category:social -category:updates";

  const response = await gmail.users.messages.list({
    userId: "me",
    q: query,
    maxResults: args.maxResults || 20,
  });

  const messages = response.data.messages || [];
  const results = [];

  for (const msg of messages.slice(0, 10)) {
    const full = await gmail.users.messages.get({
      userId: "me",
      id: msg.id!,
      format: "metadata",
      metadataHeaders: ["From", "Subject", "Date"],
    });

    const headers = full.data.payload?.headers || [];
    results.push({
      id: msg.id,
      threadId: msg.threadId,
      from: headers.find((h) => h.name === "From")?.value,
      subject: headers.find((h) => h.name === "Subject")?.value,
      date: headers.find((h) => h.name === "Date")?.value,
      snippet: full.data.snippet,
    });
  }

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(results, null, 2),
      },
    ],
  };
}

async function getMessage(args: { messageId: string }) {
  const gmail = await getGmailClient();

  const response = await gmail.users.messages.get({
    userId: "me",
    id: args.messageId,
    format: "full",
  });

  const headers = response.data.payload?.headers || [];
  const body = extractBody(response.data.payload);

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          {
            id: response.data.id,
            threadId: response.data.threadId,
            from: headers.find((h) => h.name === "From")?.value,
            to: headers.find((h) => h.name === "To")?.value,
            subject: headers.find((h) => h.name === "Subject")?.value,
            date: headers.find((h) => h.name === "Date")?.value,
            body: body,
          },
          null,
          2
        ),
      },
    ],
  };
}

async function getThread(args: { threadId: string }) {
  const gmail = await getGmailClient();

  const response = await gmail.users.threads.get({
    userId: "me",
    id: args.threadId,
    format: "metadata",
    metadataHeaders: ["From", "Subject", "Date"],
  });

  const messages = (response.data.messages || []).map((msg) => {
    const headers = msg.payload?.headers || [];
    return {
      id: msg.id,
      from: headers.find((h) => h.name === "From")?.value,
      subject: headers.find((h) => h.name === "Subject")?.value,
      date: headers.find((h) => h.name === "Date")?.value,
      snippet: msg.snippet,
    };
  });

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(messages, null, 2),
      },
    ],
  };
}

async function checkAuthStatus() {
  try {
    const token = await keytar.getPassword(SERVICE_NAME, "refresh_token");
    const isAuthenticated = !!token;

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            authenticated: isAuthenticated,
            message: isAuthenticated
              ? "Gmail is connected"
              : "Gmail is not connected. Please authenticate.",
          }),
        },
      ],
    };
  } catch {
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            authenticated: false,
            message: "Error checking auth status",
          }),
        },
      ],
    };
  }
}

// Helper functions

async function getGmailClient() {
  if (!oauth2Client) {
    // Get credentials from environment
    const clientId = process.env.GMAIL_CLIENT_ID;
    const clientSecret = process.env.GMAIL_CLIENT_SECRET;

    if (!clientId || !clientSecret) {
      throw new Error(
        "Missing GMAIL_CLIENT_ID or GMAIL_CLIENT_SECRET environment variables"
      );
    }

    oauth2Client = new google.auth.OAuth2(
      clientId,
      clientSecret,
      "http://localhost:3001/oauth/callback"
    );

    // Try to load saved tokens
    const refreshToken = await keytar.getPassword(SERVICE_NAME, "refresh_token");
    if (refreshToken) {
      oauth2Client.setCredentials({ refresh_token: refreshToken });
    } else {
      throw new Error("Not authenticated. Please run OAuth flow first.");
    }
  }

  return google.gmail({ version: "v1", auth: oauth2Client });
}

function extractBody(payload: any): string {
  if (!payload) return "";

  // Check for plain text body
  if (payload.mimeType === "text/plain" && payload.body?.data) {
    return Buffer.from(payload.body.data, "base64").toString("utf-8");
  }

  // Check for HTML body (fallback)
  if (payload.mimeType === "text/html" && payload.body?.data) {
    const html = Buffer.from(payload.body.data, "base64").toString("utf-8");
    // Simple HTML stripping
    return html.replace(/<[^>]*>/g, "").trim();
  }

  // Check parts
  if (payload.parts) {
    for (const part of payload.parts) {
      const body = extractBody(part);
      if (body) return body;
    }
  }

  return "";
}

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Gmail MCP server running on stdio");
}

main().catch(console.error);
