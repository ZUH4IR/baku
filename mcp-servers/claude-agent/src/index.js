#!/usr/bin/env node
/**
 * Baku Claude Agent Service
 *
 * Provides self-healing capabilities by running Claude Agent SDK
 * to diagnose and fix Swift build errors autonomously.
 *
 * Communication: WebSocket server on configurable port
 * Protocol: JSON messages for requests/responses/streaming
 */

import { spawn } from 'child_process';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import fs from 'fs/promises';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.BAKU_AGENT_PORT || 9847;

// Track active repair sessions
const sessions = new Map();

/**
 * Run Claude Code CLI with specific prompt and tools
 */
async function runClaudeAgent(sessionId, { error, projectPath, context }, ws) {
  const prompt = `You are debugging a Swift/SwiftUI macOS app called Baku.

BUILD ERROR:
${error}

PROJECT PATH: ${projectPath}

${context ? `ADDITIONAL CONTEXT:\n${context}` : ''}

INSTRUCTIONS:
1. Read the relevant Swift files to understand the error
2. Identify the root cause
3. Fix the error by editing the file(s)
4. Verify your fix makes sense
5. Report what you changed

Be precise and minimal - only change what's necessary to fix the error.`;

  // Use claude CLI in non-interactive mode
  const claudePath = process.env.CLAUDE_PATH || 'claude';

  const args = [
    '--print',
    '--dangerously-skip-permissions',
    '--allowedTools', 'Read,Edit,Glob,Grep,Bash',
    '--max-turns', '10',
    prompt
  ];

  sendMessage(ws, sessionId, 'status', { state: 'starting', message: 'Starting Claude agent...' });

  return new Promise((resolve, reject) => {
    const proc = spawn(claudePath, args, {
      cwd: projectPath,
      env: { ...process.env, FORCE_COLOR: '0' },
      stdio: ['pipe', 'pipe', 'pipe']
    });

    sessions.set(sessionId, { proc, startTime: Date.now() });

    let output = '';
    let errorOutput = '';

    proc.stdout.on('data', (data) => {
      const chunk = data.toString();
      output += chunk;
      sendMessage(ws, sessionId, 'output', { chunk });
    });

    proc.stderr.on('data', (data) => {
      const chunk = data.toString();
      errorOutput += chunk;
      // Don't send stderr as it's often just progress info
    });

    proc.on('close', (code) => {
      sessions.delete(sessionId);

      if (code === 0) {
        sendMessage(ws, sessionId, 'complete', {
          success: true,
          output,
          duration: Date.now() - sessions.get(sessionId)?.startTime || 0
        });
        resolve({ success: true, output });
      } else {
        sendMessage(ws, sessionId, 'complete', {
          success: false,
          error: errorOutput || `Process exited with code ${code}`,
          output
        });
        resolve({ success: false, error: errorOutput, output });
      }
    });

    proc.on('error', (err) => {
      sessions.delete(sessionId);
      sendMessage(ws, sessionId, 'error', { message: err.message });
      reject(err);
    });
  });
}

/**
 * Send structured message to WebSocket client
 */
function sendMessage(ws, sessionId, type, payload) {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify({ sessionId, type, payload, timestamp: Date.now() }));
  }
}

/**
 * Handle incoming WebSocket messages
 */
async function handleMessage(ws, message) {
  let data;
  try {
    data = JSON.parse(message);
  } catch (e) {
    sendMessage(ws, null, 'error', { message: 'Invalid JSON' });
    return;
  }

  const { action, sessionId, ...params } = data;

  switch (action) {
    case 'ping':
      sendMessage(ws, sessionId, 'pong', { time: Date.now() });
      break;

    case 'repair':
      if (!params.error || !params.projectPath) {
        sendMessage(ws, sessionId, 'error', { message: 'Missing error or projectPath' });
        return;
      }
      try {
        await runClaudeAgent(sessionId || crypto.randomUUID(), params, ws);
      } catch (err) {
        sendMessage(ws, sessionId, 'error', { message: err.message });
      }
      break;

    case 'cancel':
      const session = sessions.get(sessionId);
      if (session?.proc) {
        session.proc.kill('SIGTERM');
        sessions.delete(sessionId);
        sendMessage(ws, sessionId, 'cancelled', {});
      }
      break;

    case 'status':
      sendMessage(ws, sessionId, 'status', {
        activeSessions: sessions.size,
        sessions: Array.from(sessions.keys())
      });
      break;

    default:
      sendMessage(ws, sessionId, 'error', { message: `Unknown action: ${action}` });
  }
}

// Create HTTP server for health checks
const server = createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', activeSessions: sessions.size }));
  } else {
    res.writeHead(404);
    res.end();
  }
});

// Create WebSocket server
const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
  console.log('Client connected');
  sendMessage(ws, null, 'connected', { version: '1.0.0' });

  ws.on('message', (message) => handleMessage(ws, message.toString()));
  ws.on('close', () => console.log('Client disconnected'));
  ws.on('error', (err) => console.error('WebSocket error:', err));
});

// Start server
server.listen(PORT, () => {
  console.log(`Baku Claude Agent service running on port ${PORT}`);
  console.log(`WebSocket: ws://localhost:${PORT}`);
  console.log(`Health: http://localhost:${PORT}/health`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Shutting down...');
  sessions.forEach((session) => session.proc?.kill('SIGTERM'));
  wss.close();
  server.close();
  process.exit(0);
});
