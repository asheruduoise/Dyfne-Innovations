// GCR Inventory web app.
// Step 1: serve the pages and read inventory from MySQL.
// Step 2: sign-in, and Stock In / Stock Out through the stored procedures.
// Every transaction is recorded under the signed-in user; the browser never
// chooses the user ID. The server still listens on 127.0.0.1 by default.
require('dotenv').config({ quiet: true });
const path = require('path');
const express = require('express');
const pool = require('./db');
const auth = require('./auth');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '20kb' }));

// Writes must be JSON. Together with the SameSite=Strict cookie, this stops
// other websites from submitting forms to the app.
app.use('/api', (req, res, next) => {
  if (req.method === 'POST' && !req.is('application/json')) {
    return res.status(415).json({ error: 'Requests must be JSON.' });
  }
  next();
});

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

// --- Sign-in (open) ---
app.post('/api/login', auth.login);
app.post('/api/logout', auth.logout);

// --- Everything below needs a valid session ---
app.use('/api', auth.requireSession);

app.get('/api/me', (req, res) => {
  res.json({
    displayName: req.user.displayName,
    username: req.user.username,
    mustChangePassword: req.user.mustChangePassword
  });
});
app.post('/api/change-password', auth.changePassword);

// --- Everything below also needs the password change done (if one was required) ---
app.use('/api', auth.blockUntilPasswordChanged);

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

// Everything the Stock Transactions form needs for its drop-downs.
app.get('/api/form-options', async (req, res, next) => {
  try {
    const [variantSets] = await pool.query('CALL usp_GetSelectableVariants(NULL)');
    const [categories] = await pool.query(
      `SELECT DistributionCategoryID, CategoryName, Description
         FROM vw_App_DistributionCategories ORDER BY DistributionCategoryID`
    );
    const [contexts] = await pool.query(
      `SELECT RecipientContextID, ContextName, Description
         FROM vw_App_RecipientContexts ORDER BY RecipientContextID`
    );
    res.json({ variants: variantSets[0], categories, contexts });
  } catch (err) {
    next(err);
  }
});

// Latest transactions (one row per item line) for the Stock Transactions page.
app.get('/api/transactions/recent', async (req, res, next) => {
  try {
    const [rows] = await pool.query(
      `SELECT TransactionID, TransactionDate, TransactionTypeLabel, StockInReason,
              SubmittedBy, ItemName, VariantLabel, Quantity, DistributionCategory,
              RecipientContext, EventDetails
         FROM vw_TransactionHistory
        WHERE TransactionID IN (SELECT TransactionID FROM (
                SELECT DISTINCT TransactionID FROM vw_TransactionHistory
                 ORDER BY TransactionID DESC LIMIT 10) AS latest)
        ORDER BY TransactionID DESC, ItemName`
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

// --- input checks (the database re-checks everything; these give clear messages early) ---
const STOCK_IN_REASONS = ['Received', 'Returned', 'Adjustment'];
const isId = (v) => Number.isInteger(v) && v > 0;
const optionalText = (v, max) =>
  v === undefined || v === null || (typeof v === 'string' && v.length <= max);
const cleanText = (v) => (typeof v === 'string' && v.trim() !== '' ? v.trim() : null);

function checkTransaction(body) {
  const b = body || {};
  if (b.type !== 'IN' && b.type !== 'OUT') return 'Choose Stock In or Stock Out.';
  if (!Array.isArray(b.lines) || b.lines.length === 0) return 'Add at least one item.';
  if (b.lines.length > 50) return 'Too many items in one transaction.';
  for (const line of b.lines) {
    if (!line || !isId(line.variantId)) return 'Choose an item on every row.';
    if (!Number.isInteger(line.quantity) || line.quantity < 1 || line.quantity > 100000) {
      return 'Quantities must be whole numbers greater than zero.';
    }
  }
  if (new Set(b.lines.map((l) => l.variantId)).size !== b.lines.length) {
    return 'An item appears on more than one row; combine its quantities in one row.';
  }
  if (b.type === 'IN' && !STOCK_IN_REASONS.includes(b.stockInReason)) {
    return 'Choose a Stock In reason.';
  }
  if (b.type === 'OUT' && (!isId(b.distributionCategoryId) || !isId(b.recipientContextId))) {
    return 'Choose a distribution category and recipient context for Stock Out.';
  }
  if (!optionalText(b.eventDetails, 255) || !optionalText(b.notes, 1000)) {
    return 'Event/purpose must be 255 characters or fewer, and notes 1000 or fewer.';
  }
  return null;
}

// Record a Stock In or Stock Out (one or more items, all-or-nothing),
// always under the signed-in user.
app.post('/api/transactions', async (req, res, next) => {
  const problem = checkTransaction(req.body);
  if (problem) return res.status(400).json({ error: problem });

  const b = req.body;
  const isOut = b.type === 'OUT';
  const lines = JSON.stringify(
    b.lines.map((l) => ({ VariantID: l.variantId, Quantity: l.quantity }))
  );

  let conn;
  try {
    // Same connection for the CALL and the OUT parameter read.
    conn = await pool.getConnection();
    await conn.query(
      'CALL usp_RecordTransaction(?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, ?, @newTransactionId)',
      [
        req.user.id,
        b.type,
        lines,
        isOut ? null : b.stockInReason,
        isOut ? b.distributionCategoryId : null,
        isOut ? b.recipientContextId : null,
        isOut ? cleanText(b.eventDetails) : null,
        cleanText(b.notes)
      ]
    );
    const [[out]] = await conn.query('SELECT @newTransactionId AS transactionId');
    res.status(201).json({ transactionId: out.transactionId });
  } catch (err) {
    // Business-rule rejections from the procedures (e.g. not enough stock)
    // are written for staff to read, so pass those through.
    if (err.sqlState === '45000') {
      return res.status(400).json({ error: err.sqlMessage });
    }
    next(err);
  } finally {
    if (conn) conn.release();
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
