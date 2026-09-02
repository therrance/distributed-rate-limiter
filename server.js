require('dotenv').config();
const express = require('express');
const redis = require('redis');
const fs = require('fs');
const path = require('path');

const app = express();
const client = redis.createClient({
  socket: {
    host: process.env.REDIS_HOST || '127.0.0.1',
    port: parseInt(process.env.REDIS_PORT, 10) || 6379
  }
});
client.on('error', (err) => console.error('Redis client error:', err));

const rateLimitScript = fs.readFileSync(path.join(__dirname, 'rate_limiter.lua'), 'utf-8');

const RATE_LIMIT = parseInt(process.env.RATE_LIMIT);
const TIME_WINDOW = parseInt(process.env.TIME_WINDOW);

const USER_RATE_LIMIT = parseInt(process.env.USER_RATE_LIMIT) || RATE_LIMIT;
const USER_TIME_WINDOW = parseInt(process.env.USER_TIME_WINDOW) || TIME_WINDOW;

const USER_ID_HEADER = 'X-User-Id';

// Middleware for rate limiting.
// Limits requests by IP by default, but requests carrying an X-User-Id header are limited per user.
async function rateLimiter(req, res, next) {
  const userId = req.header(USER_ID_HEADER);
  const scope = userId ? 'user' : 'ip';
  const identifier = userId || req.ip;
  const limit = scope === 'user' ? USER_RATE_LIMIT : RATE_LIMIT;
  const windowSeconds = scope === 'user' ? USER_TIME_WINDOW : TIME_WINDOW;
  const key = `rate:limit:${scope}:${identifier}`;
  try {
    const allowed = await client.eval(rateLimitScript, {
      keys: [key],
      arguments: [String(limit), String(windowSeconds)]
    });
    if (allowed === 1) {
      console.log(`Request allowed for ${scope} ${identifier}`);
      next();
    } else {
      console.log(`Request denied for ${scope} ${identifier}`);
      res.status(429).json({ message: 'Too many requests. Please try again later' });
    }
  } catch (err) {
    console.error('Error in rate limiter:', err);
    res.status(500).json({ message: 'Internal server error' });
  }
}

app.use(rateLimiter);

app.get('/', (req, res) => {
  res.send('Welcome to the Rate Limiter API!');
});

const PORT = process.env.PORT;

if (require.main === module) {
  client.connect().then(() => {
    app.listen(PORT, () => {
      console.log(`Server runnig on port ${PORT}`);
    });
  });
}

module.exports = { app, client, rateLimiter, USER_ID_HEADER };
