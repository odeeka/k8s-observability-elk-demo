'use strict';

const express = require('express');
const { v4: uuidv4 } = require('uuid');

const app = express();
app.use(express.json());

const PORT        = parseInt(process.env.PORT || '3000', 10);
const SERVICE     = 'user-service';

// ---------------------------------------------------------------------------
// Structured JSON logger – writes ONLY to stdout (12-factor / K8s friendly)
// Fields: timestamp, level, service, message, ...extra
// ---------------------------------------------------------------------------
const log = (level, message, extra = {}) => {
  process.stdout.write(
    JSON.stringify({ timestamp: new Date().toISOString(), level, service: SERVICE, message, ...extra }) + '\n'
  );
};

// ---------------------------------------------------------------------------
// Middleware: propagate / generate a request-correlation-id
// ---------------------------------------------------------------------------
app.use((req, res, next) => {
  req.requestId = req.headers['x-request-id'] || uuidv4();
  res.setHeader('x-request-id', req.requestId);
  next();
});

// ---------------------------------------------------------------------------
// Middleware: structured access log (request + response)
// ---------------------------------------------------------------------------
app.use((req, res, next) => {
  const startedAt = Date.now();

  log('info', 'request_received', {
    requestId: req.requestId,
    method:    req.method,
    path:      req.path,
    userAgent: req.get('user-agent'),
  });

  res.on('finish', () => {
    const durationMs = Date.now() - startedAt;
    const level = res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info';
    log(level, 'request_completed', {
      requestId:  req.requestId,
      method:     req.method,
      path:       req.path,
      statusCode: res.statusCode,
      durationMs,
    });
  });

  next();
});

// ---------------------------------------------------------------------------
// In-memory data
// ---------------------------------------------------------------------------
const USERS = [
  { id: 1, name: 'Alice Johnson',  email: 'alice@example.com',  role: 'admin' },
  { id: 2, name: 'Bob Smith',      email: 'bob@example.com',    role: 'user'  },
  { id: 3, name: 'Carol Williams', email: 'carol@example.com',  role: 'user'  },
  { id: 4, name: 'David Chen',     email: 'david@example.com',  role: 'user'  },
];

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
app.get('/health', (_req, res) =>
  res.json({ status: 'healthy', service: SERVICE, timestamp: new Date().toISOString() })
);

app.get('/users', (req, res) => {
  log('info', 'listing_users', { requestId: req.requestId, count: USERS.length });
  res.json({ users: USERS, total: USERS.length, requestId: req.requestId });
});

app.get('/users/:id', (req, res) => {
  const id   = parseInt(req.params.id, 10);
  const user = USERS.find(u => u.id === id);

  if (!user) {
    log('warn', 'user_not_found', { requestId: req.requestId, userId: id });
    return res.status(404).json({ error: 'User not found', userId: id, requestId: req.requestId });
  }

  log('info', 'user_found', { requestId: req.requestId, userId: user.id, role: user.role });
  res.json({ user, requestId: req.requestId });
});

// Triggers a deliberate 500 – useful for testing dashboards and alerts
app.get('/error', (req, res) => {
  log('error', 'intentional_error_triggered', {
    requestId: req.requestId,
    errorCode: 'SIMULATED_FAILURE',
    errorType: 'deliberately_triggered',
  });
  res.status(500).json({ error: 'Internal server error', errorCode: 'SIMULATED_FAILURE', requestId: req.requestId });
});

// ---------------------------------------------------------------------------
// Server lifecycle
// ---------------------------------------------------------------------------
app.listen(PORT, '0.0.0.0', () =>
  log('info', 'service_started', { port: PORT })
);

process.on('SIGTERM', () => {
  log('info', 'service_shutting_down', { signal: 'SIGTERM' });
  process.exit(0);
});
