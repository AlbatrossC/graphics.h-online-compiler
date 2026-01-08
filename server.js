const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const bodyParser = require('body-parser');
const { spawn, exec } = require('child_process');
const fs = require('fs-extra');
const path = require('path');
const { v4: uuidv4 } = require('uuid');

const app = express();
const PORT = process.env.PORT || 3000;

// Configuration
const BASE_DISPLAY = 100;
const BASE_XPRA_PORT = 10000;
const MAX_SESSIONS = 5;
const SESSION_TIMEOUT = 10 * 60 * 1000; // 10 minutes

// Global State
const sessions = new Map();

// Middleware
app.use(bodyParser.json());
app.use(express.static('public'));
app.use('/xpra-client', express.static('/usr/share/xpra/www'));

// Root route - redirect to compiler
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'win-compiler.html'));
});

// ============================================
// LOGGING UTILITIES
// ============================================

const colors = {
    reset: '\x1b[0m',
    bright: '\x1b[1m',
    dim: '\x1b[2m',
    
    // Foreground colors
    black: '\x1b[30m',
    red: '\x1b[31m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    blue: '\x1b[34m',
    magenta: '\x1b[35m',
    cyan: '\x1b[36m',
    white: '\x1b[37m',
    gray: '\x1b[90m',
    
    // Background colors
    bgRed: '\x1b[41m',
    bgGreen: '\x1b[42m',
    bgYellow: '\x1b[43m',
    bgBlue: '\x1b[44m',
    bgMagenta: '\x1b[45m',
    bgCyan: '\x1b[46m'
};

// Session nickname colors (cycling through distinct colors)
const nicknameColors = [
    colors.cyan,
    colors.green,
    colors.yellow,
    colors.magenta,
    colors.blue
];

let colorIndex = 0;

function generateNickname() {
    const adjectives = [
        'Swift', 'Bright', 'Bold', 'Quick', 'Sharp', 'Clever', 'Wise', 'Brave',
        'Cool', 'Prime', 'Super', 'Mega', 'Ultra', 'Hyper', 'Turbo', 'Rapid'
    ];
    const nouns = [
        'Coder', 'Hacker', 'Dev', 'Builder', 'Maker', 'Creator', 'Wizard', 'Guru',
        'Ninja', 'Master', 'Expert', 'Pro', 'Artist', 'Genius', 'Champion', 'Hero'
    ];
    
    const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
    const noun = nouns[Math.floor(Math.random() * nouns.length)];
    const num = Math.floor(Math.random() * 100);
    
    return `${adj}${noun}${num}`;
}

function getTimestamp() {
    const now = new Date();
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const seconds = String(now.getSeconds()).padStart(2, '0');
    return `${colors.gray}[${hours}:${minutes}:${seconds}]${colors.reset}`;
}

function log(level, nickname, nicknameColor, message, details = '') {
    const timestamp = getTimestamp();
    const levelColors = {
        'INFO': colors.blue,
        'SUCCESS': colors.green,
        'WARN': colors.yellow,
        'ERROR': colors.red,
        'DEBUG': colors.gray
    };
    
    const levelColor = levelColors[level] || colors.white;
    const levelTag = `${levelColor}${level.padEnd(7)}${colors.reset}`;
    const nicknameTag = `${nicknameColor}[${nickname}]${colors.reset}`;
    const detailsStr = details ? ` ${colors.dim}${details}${colors.reset}` : '';
    
    console.log(`${timestamp} ${levelTag} ${nicknameTag} ${message}${detailsStr}`);
}

function logServer(level, message, details = '') {
    const timestamp = getTimestamp();
    const levelColors = {
        'INFO': colors.blue,
        'SUCCESS': colors.green,
        'WARN': colors.yellow,
        'ERROR': colors.red
    };
    
    const levelColor = levelColors[level] || colors.white;
    const levelTag = `${levelColor}${level.padEnd(7)}${colors.reset}`;
    const serverTag = `${colors.bright}${colors.white}[SERVER]${colors.reset}`;
    const detailsStr = details ? ` ${colors.dim}${details}${colors.reset}` : '';
    
    console.log(`${timestamp} ${levelTag} ${serverTag} ${message}${detailsStr}`);
}

// ============================================
// SESSION MANAGER
// ============================================

class Session {
    constructor(id) {
        this.id = id;
        this.nickname = generateNickname();
        this.nicknameColor = nicknameColors[colorIndex % nicknameColors.length];
        colorIndex++;
        
        this.displayNum = null;
        this.port = null;
        this.xpraProcess = null;
        this.wineProcess = null;
        this.lastActivity = Date.now();
        this.workspace = path.join(process.cwd(), 'temp', this.id);
        this.streamReady = false;
        
        fs.ensureDirSync(this.workspace);
        
        this.log('INFO', 'Session created', `ID: ${this.id.substring(0, 8)}`);
    }

    log(level, message, details = '') {
        log(level, this.nickname, this.nicknameColor, message, details);
    }

    async start() {
        const allocated = this.allocateResources();
        if (!allocated) {
            this.log('ERROR', 'Resource allocation failed', 'Server at capacity');
            throw new Error('Server at maximum capacity. Try again later.');
        }

        this.log('INFO', 'Starting Xpra server', `Display :${this.displayNum}, Port ${this.port}`);
        await this.startXpra();
        
        return {
            id: this.id,
            nickname: this.nickname,
            display: this.displayNum,
            streamReady: this.streamReady
        };
    }

    allocateResources() {
        let offset = 0;
        while (offset < MAX_SESSIONS) {
            const proposedDisplay = BASE_DISPLAY + offset;
            const isUsed = Array.from(sessions.values()).some(s => s.displayNum === proposedDisplay);
            
            if (!isUsed) {
                this.displayNum = proposedDisplay;
                this.port = BASE_XPRA_PORT + offset;
                this.log('SUCCESS', 'Resources allocated', `Display :${this.displayNum}, Port ${this.port}`);
                return true;
            }
            offset++;
        }
        return false;
    }

    startXpra() {
        return new Promise((resolve, reject) => {
            const display = `:${this.displayNum}`;

            // Clean up any stale locks
            exec(`rm -f /tmp/.X${this.displayNum}-lock /tmp/.X11-unix/X${this.displayNum}`, (err) => {
                if (err) {
                    this.log('WARN', 'Lock cleanup warning', err.message);
                }
                
                const xpraCmd = `xpra start ${display} \
                    --bind-tcp=127.0.0.1:${this.port} \
                    --daemon=no \
                    --dpi=96 \
                    --sharing=yes \
                    --html=on \
                    --headerbar=no \
                    --notifications=no \
                    --pulseaudio=no \
                    --webcam=no`;

                this.xpraProcess = spawn('bash', ['-c', xpraCmd], {
                    stdio: ['ignore', 'pipe', 'pipe']
                });

                let resolved = false;
                let outputBuffer = '';

                const onReady = (data) => {
                    const output = data.toString();
                    outputBuffer += output;
                    
                    // Log first 100 chars of output
                    if (output.length > 0) {
                        const preview = output.substring(0, 100).replace(/\n/g, ' ');
                        this.log('DEBUG', 'Xpra output', preview);
                    }
                    
                    if (!resolved && output.includes('xpra is ready')) {
                        resolved = true;
                        this.streamReady = true;
                        this.log('SUCCESS', 'Xpra server ready', `WebSocket available on port ${this.port}`);
                        resolve();
                    }
                };

                this.xpraProcess.stdout.on('data', onReady);
                this.xpraProcess.stderr.on('data', onReady);

                this.xpraProcess.on('exit', (code) => {
                    if (code !== 0 && code !== null) {
                        this.log('ERROR', `Xpra exited with code ${code}`);
                    }
                    if (!resolved) {
                        this.log('ERROR', 'Xpra crashed during startup');
                        reject(new Error('Xpra crashed during startup'));
                    }
                    this.cleanup();
                });

                // Timeout safety
                setTimeout(() => {
                    if (!resolved) {
                        this.log('ERROR', 'Xpra startup timeout', 'No ready signal after 15s');
                        reject(new Error('Xpra startup timeout after 15s'));
                    }
                }, 15000);
            });
        });
    }

    async runCode(code) {
        this.updateActivity();
        
        const fileName = path.join(this.workspace, 'source.cpp');
        const exeName = path.join(this.workspace, 'program.exe');

        this.log('INFO', 'Compilation started', `Source: ${code.length} chars`);

        // Kill previous Wine process
        if (this.wineProcess) {
            try { 
                process.kill(this.wineProcess.pid, 'SIGKILL');
                this.log('INFO', 'Killed previous Wine process');
            } catch(e) {
                this.log('DEBUG', 'Previous Wine process already terminated');
            }
            exec(`DISPLAY=:${this.displayNum} wineserver -k`);
            this.wineProcess = null;
        }

        try {
            await fs.writeFile(fileName, code);
            
            // Compile
            const compileCmd = `cd "${this.workspace}" && graphics.h source.cpp program`;
            
            const compileOutput = await new Promise((resolve, reject) => {
                exec(compileCmd, (err, stdout, stderr) => {
                    if (err) {
                        const errorMsg = stderr || stdout || 'Compilation failed';
                        this.log('ERROR', 'Compilation failed', errorMsg.substring(0, 100));
                        return reject(errorMsg);
                    }
                    this.log('SUCCESS', 'Compilation successful', `Output: program.exe`);
                    resolve(stdout);
                });
            });

            // Prepare Wine environment
            const winePrefix = path.join(this.workspace, 'wineprefix');
            
            // Copy template Wine prefix if exists
            const templatePrefix = '/opt/wine-template';
            if (fs.existsSync(templatePrefix) && !fs.existsSync(winePrefix)) {
                this.log('INFO', 'Copying Wine template', 'First run optimization');
                await fs.copy(templatePrefix, winePrefix);
            } else {
                fs.ensureDirSync(winePrefix);
            }

            const env = {
                ...process.env,
                DISPLAY: `:${this.displayNum}`,
                WINEPREFIX: winePrefix,
                WINEDEBUG: '-all'
            };

            this.log('INFO', 'Launching program', `Display :${this.displayNum}`);
            
            this.wineProcess = spawn('wine', [exeName], {
                env: env,
                cwd: this.workspace,
                stdio: ['ignore', 'pipe', 'pipe']
            });

            const pid = this.wineProcess.pid;
            this.log('SUCCESS', 'Program started', `PID: ${pid}`);

            this.wineProcess.stdout.on('data', (data) => {
                const output = data.toString().substring(0, 100);
                this.log('DEBUG', 'Wine output', output);
            });

            this.wineProcess.stderr.on('data', (data) => {
                const output = data.toString().substring(0, 100);
                this.log('DEBUG', 'Wine stderr', output);
            });

            this.wineProcess.on('error', (err) => {
                this.log('ERROR', 'Wine process error', err.message);
            });

            this.wineProcess.on('exit', (code) => {
                if (code !== 0 && code !== null) {
                    this.log('WARN', `Program exited with code ${code}`);
                } else {
                    this.log('INFO', 'Program terminated normally');
                }
            });

            return { success: true, pid: pid };

        } catch (err) {
            this.log('ERROR', 'Execution failed', err.toString().substring(0, 200));
            return { success: false, output: err.toString() };
        }
    }

    updateActivity() {
        this.lastActivity = Date.now();
    }

    cleanup() {
        this.log('INFO', 'Cleanup initiated');
        
        if (this.xpraProcess && !this.xpraProcess.killed) {
            this.xpraProcess.kill('SIGTERM');
            setTimeout(() => {
                if (!this.xpraProcess.killed) {
                    this.xpraProcess.kill('SIGKILL');
                }
            }, 2000);
        }
        
        exec(`xpra stop :${this.displayNum} 2>/dev/null`, (err) => {
            if (err) this.log('DEBUG', 'Xpra stop command failed', err.message);
        });
        
        if (this.wineProcess) {
            try { 
                process.kill(this.wineProcess.pid, 'SIGKILL');
                this.log('INFO', 'Wine process terminated');
            } catch(e) {
                this.log('DEBUG', 'Wine process already terminated');
            }
        }

        exec(`DISPLAY=:${this.displayNum} wineserver -k 2>/dev/null`);

        // Async cleanup of workspace
        setTimeout(() => {
            fs.remove(this.workspace, (err) => {
                if (err) {
                    this.log('WARN', 'Workspace cleanup error', err.message);
                } else {
                    this.log('INFO', 'Workspace cleaned');
                }
            });
        }, 1000);
        
        sessions.delete(this.id);
        this.log('INFO', 'Session cleaned up');
    }
}

// ============================================
// ROUTES
// ============================================

app.post('/api/init', async (req, res) => {
    try {
        const id = uuidv4();
        const session = new Session(id);
        sessions.set(id, session);
        
        const info = await session.start();
        
        res.json({ 
            success: true, 
            sessionId: info.id,
            nickname: info.nickname,
            display: info.display,
            streamReady: info.streamReady
        });
    } catch (err) {
        logServer('ERROR', 'Session initialization failed', err.message);
        res.status(503).json({ success: false, error: err.message });
    }
});

app.post('/api/run', async (req, res) => {
    const { sessionId, code } = req.body;
    const session = sessions.get(sessionId);
    
    if (!session) {
        logServer('WARN', 'Run request for expired session', sessionId.substring(0, 8));
        return res.status(404).json({ 
            success: false, 
            output: "Session expired.",
            expired: true 
        });
    }

    const result = await session.runCode(code);
    res.json(result);
});

app.post('/api/heartbeat', (req, res) => {
    const { sessionId } = req.body;
    const session = sessions.get(sessionId);
    
    if (session) {
        session.updateActivity();
        res.json({ alive: true });
    } else {
        res.json({ alive: false, expired: true });
    }
});

// ============================================
// DYNAMIC PROXY
// ============================================

const sessionProxy = createProxyMiddleware({
    target: 'http://localhost',
    ws: true,
    router: (req) => {
        const match = req.url.match(/^\/session\/([a-zA-Z0-9-]+)\/stream\//);
        if (match && match[1]) {
            const session = sessions.get(match[1]);
            if (session && session.streamReady) {
                return `http://127.0.0.1:${session.port}`;
            }
        }
        return null;
    },
    pathRewrite: (path) => {
        return path.replace(/^\/session\/[a-zA-Z0-9-]+\/stream/, '');
    },
    onError: (err, req, res) => {
        logServer('ERROR', 'Proxy error', err.message);
        if (!res.headersSent) {
            res.status(502).json({ error: 'Stream not ready' });
        }
    },
    onProxyReqWs: (proxyReq, req, socket) => {
        socket.on('error', (err) => {
            logServer('WARN', 'WebSocket error', err.message);
        });
    }
});

app.use('/session/:id/stream', sessionProxy);

// ============================================
// CLEANUP & MONITORING
// ============================================

setInterval(() => {
    const now = Date.now();
    for (const [id, session] of sessions) {
        if (now - session.lastActivity > SESSION_TIMEOUT) {
            session.log('WARN', 'Session expired due to inactivity', `Idle for ${Math.floor((now - session.lastActivity) / 1000)}s`);
            session.cleanup();
        }
    }
}, 60000);

// Graceful Shutdown
process.on('SIGTERM', () => {
    logServer('WARN', 'SIGTERM received, cleaning up all sessions');
    for (const session of sessions.values()) {
        session.cleanup();
    }
    process.exit(0);
});

process.on('SIGINT', () => {
    logServer('WARN', 'SIGINT received, cleaning up all sessions');
    for (const session of sessions.values()) {
        session.cleanup();
    }
    process.exit(0);
});

// ============================================
// START SERVER
// ============================================

app.listen(PORT, () => {
    console.log('\n' + '='.repeat(60));
    logServer('SUCCESS', `Server started on port ${PORT}`);
    logServer('INFO', `Maximum concurrent sessions: ${MAX_SESSIONS}`);
    logServer('INFO', `Session timeout: ${SESSION_TIMEOUT / 1000 / 60} minutes`);
    console.log('='.repeat(60) + '\n');
    
    fs.ensureDirSync(path.join(process.cwd(), 'temp'));
});