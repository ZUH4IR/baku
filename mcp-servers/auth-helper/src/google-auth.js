#!/usr/bin/env node
/**
 * Google OAuth helper - browser-based authentication
 *
 * Opens the system browser for the user to log in, captures the OAuth callback
 * via a local server, and returns access/refresh tokens.
 *
 * Usage: node google-auth.js --client-id ID --client-secret SECRET
 *
 * Output: JSON with access_token, refresh_token, expires_in
 */

import http from 'http';
import { URL } from 'url';
import { exec } from 'child_process';

// Gmail scopes we need
const SCOPES = [
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/gmail.send',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile'
].join(' ');

async function getAuthTokens(clientId, clientSecret) {
    // Use a fixed port so it can be pre-registered in Google Cloud Console
    const port = 8085;
    const redirectUri = `http://localhost:${port}/callback`;

    // Build OAuth URL
    const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth');
    authUrl.searchParams.set('client_id', clientId);
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('scope', SCOPES);
    authUrl.searchParams.set('access_type', 'offline');
    authUrl.searchParams.set('prompt', 'consent');

    // Promise that resolves when we get the auth code
    let resolveAuth, rejectAuth;
    const authPromise = new Promise((resolve, reject) => {
        resolveAuth = resolve;
        rejectAuth = reject;
    });

    // Start local server to capture callback
    const server = http.createServer((req, res) => {
        const url = new URL(req.url, `http://localhost:${port}`);

        if (url.pathname === '/callback') {
            const code = url.searchParams.get('code');
            const error = url.searchParams.get('error');

            if (error) {
                res.writeHead(200, { 'Content-Type': 'text/html' });
                res.end(`
                    <html><body style="font-family: -apple-system, system-ui, sans-serif; text-align: center; padding: 50px; background: #1a1a1a; color: white;">
                        <h1 style="color: #ff6b6b;">Authentication Failed</h1>
                        <p>Error: ${error}</p>
                        <p style="color: #888;">You can close this window.</p>
                    </body></html>
                `);
                rejectAuth(new Error(error));
            } else if (code) {
                res.writeHead(200, { 'Content-Type': 'text/html' });
                res.end(`
                    <html><body style="font-family: -apple-system, system-ui, sans-serif; text-align: center; padding: 50px; background: #1a1a1a; color: white;">
                        <h1 style="color: #4ade80;">Success!</h1>
                        <p>You're signed in to Baku.</p>
                        <p style="color: #888;">You can close this window.</p>
                        <script>setTimeout(() => window.close(), 2000);</script>
                    </body></html>
                `);
                resolveAuth(code);
            }
        } else {
            res.writeHead(404);
            res.end('Not found');
        }
    });

    await new Promise((resolve) => server.listen(port, resolve));
    console.error(`OAuth callback server listening on port ${port}`);

    // Open system browser
    const openCommand = process.platform === 'darwin' ? 'open' : 'xdg-open';
    exec(`${openCommand} "${authUrl.toString()}"`);
    console.error('Opened browser for Google sign-in...');

    // Set timeout
    const timeout = setTimeout(() => {
        server.close();
        rejectAuth(new Error('Authentication timed out after 5 minutes'));
    }, 5 * 60 * 1000);

    // Wait for auth code
    let authCode;
    try {
        authCode = await authPromise;
    } finally {
        clearTimeout(timeout);
        server.close();
    }

    console.error('Got auth code, exchanging for tokens...');

    // Exchange auth code for tokens
    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            code: authCode,
            client_id: clientId,
            client_secret: clientSecret,
            redirect_uri: redirectUri,
            grant_type: 'authorization_code'
        })
    });

    if (!tokenResponse.ok) {
        const error = await tokenResponse.text();
        throw new Error(`Token exchange failed: ${error}`);
    }

    const tokens = await tokenResponse.json();
    console.error('Successfully obtained tokens');

    return tokens;
}

async function findAvailablePort() {
    return new Promise((resolve, reject) => {
        const server = http.createServer();
        server.listen(0, () => {
            const port = server.address().port;
            server.close(() => resolve(port));
        });
        server.on('error', reject);
    });
}

// Parse command line args
const args = process.argv.slice(2);
let clientId = process.env.GOOGLE_CLIENT_ID || '';
let clientSecret = process.env.GOOGLE_CLIENT_SECRET || '';

for (let i = 0; i < args.length; i++) {
    if (args[i] === '--client-id' && args[i + 1]) {
        clientId = args[++i];
    } else if (args[i] === '--client-secret' && args[i + 1]) {
        clientSecret = args[++i];
    }
}

if (!clientId || !clientSecret) {
    console.log(JSON.stringify({
        error: 'missing_credentials',
        message: 'Please provide Google OAuth credentials via --client-id and --client-secret'
    }));
    process.exit(1);
}

// Run auth flow
try {
    const tokens = await getAuthTokens(clientId, clientSecret);
    // Output tokens as JSON to stdout (stderr was used for progress messages)
    console.log(JSON.stringify(tokens));
} catch (error) {
    console.log(JSON.stringify({
        error: 'auth_failed',
        message: error.message
    }));
    process.exit(1);
}
