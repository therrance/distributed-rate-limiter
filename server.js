require('dotenv').config();
const express = require('express');

const app = express();

// Rate limiting is enforced at the OpenResty edge (see nginx/ and
// rate_limiter.lua), which is the only entry point to this service. This
// process is a plain backend and no longer talks to Redis.
app.get('/', (req, res) => {
  res.send('Welcome to the Rate Limiter API!');
});

// Unmetered liveness probe: used by the container healthcheck, never exposed
// through nginx's rate-limited location.
app.get('/healthz', (req, res) => {
  res.json({ status: 'ok' });
});

const PORT = process.env.PORT || 3000;

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`Server runnig on port ${PORT}`);
  });
}

module.exports = { app };
