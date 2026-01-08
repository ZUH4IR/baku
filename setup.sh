#!/bin/bash
set -e

echo "🌙 Setting up Baku - Morning Productivity Agent"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check for Xcode
if ! xcode-select -p | grep -q "Xcode.app"; then
    echo -e "${YELLOW}⚠️  Xcode.app not found. You need full Xcode (not just Command Line Tools) for SwiftUI.${NC}"
    echo ""
    echo "Options:"
    echo "  1. Install Xcode from App Store: https://apps.apple.com/app/xcode/id497799835"
    echo "  2. After install, run: sudo xcode-select -s /Applications/Xcode.app"
    echo ""
fi

# Navigate to project
cd "$(dirname "$0")"
PROJECT_DIR=$(pwd)

echo -e "${GREEN}📦 Installing MCP server dependencies...${NC}"

# Install MCP servers (grok uses Claude CLI, not MCP)
for server in gmail-mcp slack-mcp discord-mcp twitter-mcp markets-mcp news-mcp predictions-mcp; do
    if [ -d "mcp-servers/$server" ]; then
        echo "  → Installing $server..."
        cd "mcp-servers/$server"
        npm install --silent 2>/dev/null || echo "    (npm install skipped - run manually if needed)"
        cd "$PROJECT_DIR"
    fi
done

echo ""
echo -e "${GREEN}🔨 Building Swift app...${NC}"

cd Baku
if swift build 2>/dev/null; then
    echo -e "${GREEN}✅ Build successful!${NC}"
    echo ""
    echo "To run Baku:"
    echo "  .build/debug/Baku"
else
    echo -e "${YELLOW}⚠️  Swift build failed. Open in Xcode instead:${NC}"
    echo ""
    echo "  1. Open Xcode"
    echo "  2. File → Open → Select: $PROJECT_DIR/Baku"
    echo "  3. Click Run (⌘R)"
fi

cd "$PROJECT_DIR"

echo ""
echo -e "${GREEN}🎉 Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Open Baku in Xcode: open Baku (then select 'Open as Project')"
echo "  2. Press ⌘R to run"
echo "  3. Look for the Baku icon in your menubar/notch area"
echo ""
echo "To connect platforms, you'll need API credentials:"
echo "  - Gmail: Create OAuth app at https://console.cloud.google.com"
echo "  - Slack: Create app at https://api.slack.com/apps"
echo "  - Discord: Use your account token (get from browser DevTools)"
echo "  - Twitter: Apply at https://developer.twitter.com"
echo ""
echo "No credentials needed for (uses Claude Code or free APIs):"
echo "  - Tech Pulse (uses Claude CLI)"
echo "  - Markets (Yahoo Finance + CoinGecko)"
echo "  - News (RSS feeds)"
echo "  - Predictions (Polymarket)"
