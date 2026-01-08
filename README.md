# Baku - Morning Productivity Agent

A lightweight SwiftUI notch app that lives in your Mac's notch area, fetches messages from Discord, Slack, Gmail, and Twitter, and uses Claude to pre-generate response drafts.

## Features

- **Notch Integration** - Lives in your Mac's notch area, expands on hover
- **Multi-Platform Inbox** - Gmail, Slack, Discord, Twitter in one place
- **AI Drafts** - Claude generates response drafts for you
- **Morning Automation** - Fetches messages automatically each morning
- **Beautiful UI** - Dark mode, native Mac feel, smooth animations

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Baku (SwiftUI App)                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ NotchWindow │  │  InboxView  │  │    DraftEditor      │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│         │                │                    │             │
│  ┌──────┴────────────────┴────────────────────┴──────────┐ │
│  │              InboxManager / ClaudeManager              │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────────────┬──────────────────────────────┘
                               │ MCP Protocol (stdio)
     ┌─────────────────────────┼─────────────────────┐
     │           │             │           │         │
┌────┴────┐ ┌────┴────┐ ┌──────┴───┐ ┌─────┴───┐ ┌───┴────┐
│ Gmail   │ │ Slack   │ │ Discord  │ │ Twitter │ │ Claude │
│  MCP    │ │  MCP    │ │   MCP    │ │   MCP   │ │  API   │
└─────────┘ └─────────┘ └──────────┘ └─────────┘ └────────┘
```

## Requirements

- macOS 14 Sonoma or later
- Mac with notch (MacBook Pro 2021+)
- Xcode 15+ (for building)
- Node.js 18+ (for MCP servers)
- Claude API key (for AI drafts)

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/ZUH4IR/baku.git
cd baku

# 2. Run setup script
./setup.sh

# 3. Open in Xcode and run (⌘R)
open Baku
```

---

## Detailed Installation

### Step 1: Prerequisites

**Xcode** (required for SwiftUI):
```bash
# Check if Xcode is installed
xcode-select -p

# If not installed, get it from:
# https://apps.apple.com/app/xcode/id497799835

# After installing, set the path:
sudo xcode-select -s /Applications/Xcode.app
```

**Node.js** (required for MCP servers):
```bash
# Using Homebrew
brew install node

# Or download from https://nodejs.org
```

### Step 2: Install MCP Server Dependencies

```bash
cd mcp-servers

# Install all MCP servers
for server in gmail-mcp slack-mcp discord-mcp twitter-mcp; do
  cd $server && npm install && cd ..
done
```

### Step 3: Build the Swift App

**Option A: Command Line**
```bash
cd Baku
swift build -c release
.build/release/Baku
```

**Option B: Xcode (Recommended)**
1. Open `Baku/` folder in Xcode
2. Select your Mac as the run destination
3. Press `⌘R` to build and run

### Step 4: Install to Applications (Optional)

```bash
# Build release version in Xcode (Product → Archive)
# Or copy the built app:
cp -r Baku/.build/release/Baku.app /Applications/
```

---

## Platform Configuration

Each platform requires API credentials. Baku stores tokens securely in macOS Keychain via `keytar`.

### Gmail Setup

1. **Create Google Cloud Project**
   - Go to [Google Cloud Console](https://console.cloud.google.com)
   - Create a new project
   - Enable the Gmail API

2. **Create OAuth Credentials**
   - Go to APIs & Services → Credentials
   - Create OAuth 2.0 Client ID (Desktop app)
   - Download the credentials JSON

3. **Set Environment Variables**
   ```bash
   export GMAIL_CLIENT_ID="your-client-id.apps.googleusercontent.com"
   export GMAIL_CLIENT_SECRET="your-client-secret"
   ```

4. **Authenticate**
   - Open Baku settings → Click "Connect" next to Gmail
   - Complete OAuth flow in browser

### Slack Setup

1. **Create Slack App**
   - Go to [Slack API](https://api.slack.com/apps)
   - Create New App → From scratch

2. **Configure OAuth Scopes**
   Add these Bot Token Scopes:
   - `channels:history`
   - `channels:read`
   - `chat:write`
   - `im:history`
   - `im:read`
   - `mpim:history`
   - `mpim:read`
   - `search:read`
   - `users:read`

3. **Install to Workspace**
   - OAuth & Permissions → Install to Workspace
   - Copy the Bot User OAuth Token

4. **Store Token**
   The token is stored in Keychain when you connect via Baku settings.

### Discord Setup

1. **Create Discord Application**
   - Go to [Discord Developer Portal](https://discord.com/developers/applications)
   - Create New Application

2. **Create Bot**
   - Go to Bot section → Add Bot
   - Enable these Privileged Intents:
     - Message Content Intent
     - Direct Messages Intent

3. **Get Bot Token**
   - Bot section → Reset Token → Copy token

4. **Invite Bot to Server**
   ```
   https://discord.com/api/oauth2/authorize?client_id=YOUR_CLIENT_ID&permissions=274877991936&scope=bot
   ```

5. **Store Token**
   Token is stored in Keychain when you connect via Baku settings.

### Twitter/X Setup

1. **Apply for Developer Access**
   - Go to [Twitter Developer Portal](https://developer.twitter.com)
   - Apply for access (may require approval)

2. **Create Project & App**
   - Create a new Project
   - Create an App within the project
   - Set up User Authentication Settings:
     - OAuth 1.0a
     - Read and write permissions

3. **Get API Keys**
   - Keys and Tokens section
   - Generate API Key and Secret
   - Generate Access Token and Secret

4. **Set Environment Variables**
   ```bash
   export TWITTER_API_KEY="your-api-key"
   export TWITTER_API_SECRET="your-api-secret"
   ```

5. **Authenticate**
   Access tokens are stored in Keychain when you connect via Baku settings.

---

## Environment Variables

Create a `.env` file or export these variables:

```bash
# Gmail (required for Gmail integration)
export GMAIL_CLIENT_ID="xxx.apps.googleusercontent.com"
export GMAIL_CLIENT_SECRET="xxx"

# Twitter (required for Twitter integration)
export TWITTER_API_KEY="xxx"
export TWITTER_API_SECRET="xxx"

# Claude API (required for AI drafts)
export ANTHROPIC_API_KEY="sk-ant-xxx"
```

**Tip**: Add these to your `~/.zshrc` or `~/.bashrc` for persistence.

---

## Morning Automation

Baku can automatically fetch messages every morning using macOS LaunchAgent.

### Install LaunchAgent

```bash
# Copy plist to LaunchAgents
cp LaunchAgent/com.baku.morning.plist ~/Library/LaunchAgents/

# Load the agent
launchctl load ~/Library/LaunchAgents/com.baku.morning.plist
```

### Configure Schedule

Edit `~/Library/LaunchAgents/com.baku.morning.plist`:

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>
    <integer>7</integer>  <!-- Change to your preferred hour -->
    <key>Minute</key>
    <integer>0</integer>
</dict>
```

Reload after changes:
```bash
launchctl unload ~/Library/LaunchAgents/com.baku.morning.plist
launchctl load ~/Library/LaunchAgents/com.baku.morning.plist
```

### View Logs

```bash
# Standard output
tail -f /tmp/baku.log

# Errors
tail -f /tmp/baku.error.log
```

### Uninstall LaunchAgent

```bash
launchctl unload ~/Library/LaunchAgents/com.baku.morning.plist
rm ~/Library/LaunchAgents/com.baku.morning.plist
```

---

## Using with Claude Code

The MCP servers can be used standalone with Claude Code or any MCP-compatible client.

### Add to Claude Code Settings

Add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "gmail": {
      "command": "node",
      "args": ["/path/to/baku/mcp-servers/gmail-mcp/dist/index.js"],
      "env": {
        "GMAIL_CLIENT_ID": "your-client-id",
        "GMAIL_CLIENT_SECRET": "your-client-secret"
      }
    },
    "slack": {
      "command": "node",
      "args": ["/path/to/baku/mcp-servers/slack-mcp/dist/index.js"]
    },
    "discord": {
      "command": "node",
      "args": ["/path/to/baku/mcp-servers/discord-mcp/dist/index.js"]
    },
    "twitter": {
      "command": "node",
      "args": ["/path/to/baku/mcp-servers/twitter-mcp/dist/index.js"],
      "env": {
        "TWITTER_API_KEY": "your-api-key",
        "TWITTER_API_SECRET": "your-api-secret"
      }
    }
  }
}
```

### Build MCP Servers for Claude Code

```bash
cd mcp-servers

for server in gmail-mcp slack-mcp discord-mcp twitter-mcp; do
  cd $server
  npm install
  npm run build  # Compiles TypeScript to dist/
  cd ..
done
```

---

## Project Structure

```
baku/
├── Baku/                       # SwiftUI macOS App
│   ├── Sources/Baku/
│   │   ├── BakuApp.swift       # App entry point
│   │   ├── ContentView.swift   # Main notch UI
│   │   ├── Components/         # UI components
│   │   │   ├── NotchWindow.swift
│   │   │   ├── InboxView.swift
│   │   │   └── SettingsView.swift
│   │   ├── Managers/           # Business logic
│   │   │   ├── ClaudeManager.swift   # Claude API integration
│   │   │   ├── InboxManager.swift    # MCP orchestration
│   │   │   ├── MCPClient.swift       # MCP protocol client
│   │   │   └── SettingsManager.swift # Credentials storage
│   │   └── Models/             # Data models
│   │       ├── Message.swift
│   │       ├── Draft.swift
│   │       └── Platform.swift
│   └── Package.swift
│
├── mcp-servers/                # MCP Servers (Node.js/TypeScript)
│   ├── gmail-mcp/              # Gmail integration
│   │   ├── src/index.ts
│   │   └── package.json
│   ├── slack-mcp/              # Slack integration
│   ├── discord-mcp/            # Discord integration
│   └── twitter-mcp/            # Twitter/X integration
│
├── LaunchAgent/                # macOS automation
│   └── com.baku.morning.plist  # Morning schedule config
│
└── setup.sh                    # Quick setup script
```

---

## MCP Tools Reference

### Gmail MCP

| Tool | Description |
|------|-------------|
| `gmail_list_unread` | List unread emails (filters promotions/social by default) |
| `gmail_get_message` | Get full content of a specific email |
| `gmail_get_thread` | Get all messages in an email thread |
| `gmail_auth_status` | Check authentication status |

### Slack MCP

| Tool | Description |
|------|-------------|
| `slack_list_dms` | List recent DM conversations |
| `slack_get_messages` | Get messages from a channel/DM |
| `slack_get_mentions` | Get messages where you were mentioned |
| `slack_post` | Send a message to a channel |

### Discord MCP

| Tool | Description |
|------|-------------|
| `discord_list_dms` | List recent DM conversations |
| `discord_get_messages` | Get messages from a channel/DM |
| `discord_send` | Send a message |

### Twitter MCP

| Tool | Description |
|------|-------------|
| `twitter_get_dms` | Get recent DM conversations |
| `twitter_get_mentions` | Get tweets mentioning you |
| `twitter_send_dm` | Send a DM to a user |
| `twitter_reply` | Reply to a tweet |

---

## Troubleshooting

### App won't build in Xcode
- Ensure you have full Xcode installed (not just Command Line Tools)
- Run `sudo xcode-select -s /Applications/Xcode.app`

### MCP server won't connect
- Check Node.js is installed: `node --version`
- Ensure dependencies are installed: `cd mcp-servers/xxx-mcp && npm install`
- Check environment variables are set

### OAuth errors
- Verify API credentials are correct
- Check redirect URIs match in your OAuth app settings
- For Gmail: ensure Gmail API is enabled in Google Cloud Console

### LaunchAgent not running
- Check logs: `tail -f /tmp/baku.error.log`
- Verify app path in plist matches your installation
- Ensure launchctl load was successful

### Tokens not saving
- Keychain access may be blocked - check System Preferences → Security
- Try manually adding via Keychain Access app

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Commit changes: `git commit -m 'Add amazing feature'`
4. Push to branch: `git push origin feature/amazing-feature`
5. Open a Pull Request

---

## License

MIT

---

## Acknowledgments

- Built with [Model Context Protocol (MCP)](https://modelcontextprotocol.io)
- AI powered by [Claude](https://anthropic.com) from Anthropic
- SwiftUI for native macOS experience
