// GCR Inventory web app - Step 1: serve the pages and read inventory from MySQL.
// NOTE: there is no login yet (Step 2). Until then the server listens on
// 127.0.0.1 only, so it is reachable from this laptop and nowhere else.
require('dotenv').config({ quiet: true });
const path = require('path');
const express = require('express');
const pool = require('./db');

const app = express();
app.disable('x-powered-by');

// Basic security headers.
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader(
    'Content-Security-Policy',
    "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:"
  );
  next();
});

// Kiet's pages (index.html, style.css, script.js, data.js).
app.use(express.static(path.join(__dirname, 'public')));

// Health check: confirms the app can reach the database.
app.get('/api/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true });
  } catch (err) {
    console.error('Health check failed:', err.message);
    res.status(503).json({ ok: false });
  }
});

// Full inventory list (Inventory page and Dashboard overview).
app.get('/api/inventory', async (req, res, next) => {
  try {
    const [rows] = await pool.query(
      `SELECT VariantID, CategoryName, ItemName, Gender, SizeCode, VariantLabel,
              BaselineQuantity, CurrentQuantity, Setpoint, UnitValue, StockStatus
         FROM vw_CurrentInventory
        WHERE ItemIsActive AND VariantIsActive
        ORDER BY CategoryName, ItemName, SizeSortOrder, Gender`
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

// Dashboard summary cards.
app.get('/api/dashboard', async (req, res, next) => {
  try {
    const [[catalog]] = await pool.query(
      `SELECT COUNT(*) AS n FROM vw_CurrentInventory WHERE ItemIsActive AND VariantIsActive`
    );
    const [[low]] = await pool.query(`SELECT COUNT(*) AS n FROM vw_LowInventory`);
    const [[value]] = await pool.query(
      `SELECT COUNT(*) AS valued, COALESCE(SUM(TotalValue), 0) AS total FROM vw_InventoryValue`
    );
    res.json({
      catalogEntries: catalog.n,
      lowStockCount: low.n,
      valuedItemCount: value.valued,
      totalValue: value.total
    });
  } catch (err) {
    next(err);
  }
});

// Any error: log the details on the server, send a generic message to the browser.
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'Something went wrong. Please try again.' });
});

const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || '127.0.0.1';
app.listen(port, host, () => {
  console.log(`GCR Inventory app running at http://${host === '0.0.0.0' ? 'localhost' : host}:${port}`);
});
