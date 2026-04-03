'use strict';

const express = require('express');
const { v4: uuidv4 } = require('uuid');

const app = express();
app.use(express.json());

const PORT           = parseInt(process.env.PORT          || '8000', 10);
const SERVICE        = 'payment-service';
const FAILURE_RATE   = parseFloat(process.env.FAILURE_RATE  || '0.3');   // 30 % failure probability
const MAX_LATENCY_MS = parseInt(process.env.MAX_LATENCY_MS  || '800', 10);

// ---------------------------------------------------------------------------
// Structured JSON logger – stdout only
// ---------------------------------------------------------------------------
const log = (level, message, extra = {}) => {
  process.stdout.write(
    JSON.stringify({ timestamp: new Date().toISOString(), level, service: SERVICE, message, ...extra }) + '\n'
  );
};

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// Middleware: request-correlation-id
// ---------------------------------------------------------------------------
app.use((req, res, next) => {
  req.requestId = req.headers['x-request-id'] || uuidv4();
  res.setHeader('x-request-id', req.requestId);
  next();
});

// ---------------------------------------------------------------------------
// Middleware: structured access log
// ---------------------------------------------------------------------------
app.use((req, res, next) => {
  const startedAt = Date.now();

  log('info', 'request_received', {
    requestId: req.requestId,
    method:    req.method,
    path:      req.path,
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
const payments = [
  { id: 'pay-0001', userId: 1, amount: 99.99,  currency: 'USD', status: 'completed', createdAt: '2024-01-10T08:00:00Z' },
  { id: 'pay-0002', userId: 2, amount: 49.50,  currency: 'EUR', status: 'completed', createdAt: '2024-01-11T10:30:00Z' },
  { id: 'pay-0003', userId: 3, amount: 150.00, currency: 'GBP', status: 'pending',   createdAt: '2024-01-12T14:15:00Z' },
];

const ERROR_CODES = [
  'PAYMENT_GATEWAY_TIMEOUT',
  'INSUFFICIENT_FUNDS',
  'CARD_DECLINED',
  'FRAUD_DETECTED',
];

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
app.get('/health', (_req, res) =>
  res.json({
    status:  'healthy',
    service: SERVICE,
    timestamp: new Date().toISOString(),
    config: { failureRate: FAILURE_RATE, maxLatencyMs: MAX_LATENCY_MS },
  })
);

app.get('/payments', async (req, res) => {
  // Simulate light read latency (up to half the max)
  const latencyMs = Math.floor(Math.random() * (MAX_LATENCY_MS / 2));
  await sleep(latencyMs);

  log('info', 'listing_payments', { requestId: req.requestId, count: payments.length, latencyMs });
  res.json({ payments, total: payments.length, requestId: req.requestId });
});

app.get('/payments/:id', (req, res) => {
  const payment = payments.find(p => p.id === req.params.id);

  if (!payment) {
    log('warn', 'payment_not_found', { requestId: req.requestId, paymentId: req.params.id });
    return res.status(404).json({
      error: 'Payment not found', paymentId: req.params.id, requestId: req.requestId,
    });
  }

  log('info', 'payment_found', { requestId: req.requestId, paymentId: payment.id, status: payment.status });
  res.json({ payment, requestId: req.requestId });
});

app.post('/payments', async (req, res) => {
  const requestId                     = req.requestId;
  const { userId, amount = 0, currency = 'USD' } = req.body || {};

  // Simulate payment-processor latency
  const latencyMs = Math.floor(Math.random() * MAX_LATENCY_MS);
  await sleep(latencyMs);

  // Randomly simulate payment failures (FAILURE_RATE probability)
  if (Math.random() < FAILURE_RATE) {
    const errorCode = ERROR_CODES[Math.floor(Math.random() * ERROR_CODES.length)];
    log('error', 'payment_processing_failed', {
      requestId, errorCode, userId, amount, currency, latencyMs,
    });
    return res.status(422).json({ error: 'Payment processing failed', errorCode, requestId });
  }

  const payment = {
    id:        `pay-${uuidv4().slice(0, 8)}`,
    userId:    userId || 1,
    amount,
    currency,
    status:    'completed',
    createdAt: new Date().toISOString(),
  };
  payments.push(payment);

  log('info', 'payment_processed', {
    requestId,
    paymentId: payment.id,
    userId:    payment.userId,
    amount:    payment.amount,
    currency:  payment.currency,
    latencyMs,
  });

  res.status(201).json({ payment, requestId });
});

// Intentional 500 endpoint for dashboard / alert testing
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
  log('info', 'service_started', { port: PORT, failureRate: FAILURE_RATE, maxLatencyMs: MAX_LATENCY_MS })
);

process.on('SIGTERM', () => {
  log('info', 'service_shutting_down', { signal: 'SIGTERM' });
  process.exit(0);
});
