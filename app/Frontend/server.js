// GCR Inventory web app: serves the pages and exposes the stored procedures as a JSON API.
// No sign-in by design: staff pick their name from the staff list, and every change records it.
// The server listens on 0.0.0.0 by default so staff on the UH campus network can reach it. 
require('dotenv').config({ quiet: true });
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const pool = require('./db');
const mailer = require('./mailer');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '50kb' }));

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

app.use(express.static(path.join(__dirname, 'public')));

// ---------- helpers ----------

// Business-rule error from a procedure (SIGNAL SQLSTATE '45000'): safe to show the user.
class UserError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; }
}

// Runs a CALL on one connection and reads any OUT variables afterwards.
async function callProc(name, args, outVars = []) {
  const conn = await pool.getConnection();
  try {
    if (outVars.length) await conn.query(`SET ${outVars.map(v => `@${v} = NULL`).join(', ')}`);
    const placeholders = args.map(() => '?').concat(outVars.map(v => `@${v}`)).join(', ');
    const [results] = await conn.query(`CALL ${name}(${placeholders})`, args);
    const sets = Array.isArray(results) ? results.filter(Array.isArray) : [];
    let out = {};
    if (outVars.length) {
      const [[row]] = await conn.query(`SELECT ${outVars.map(v => `@${v} AS ${v}`).join(', ')}`);
      out = row;
    }
    return { sets, out };
  } finally {
    conn.release();
  }
}

const wrap = fn => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function id(value, label, { optional = false } = {}) {
  if (optional && (value === undefined || value === null || value === '')) return null;
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) throw new UserError(`${label} is missing or invalid.`);
  return n;
}

function text(value, max) {
  if (value === undefined || value === null) return null;
  const s = String(value).trim();
  return s === '' ? null : s.slice(0, max);
}

function date(value) {
  if (!value) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new UserError('Dates must be YYYY-MM-DD.');
  return value;
}

// ---------- status ----------

app.get('/api/health', wrap(async (req, res) => {
  await pool.query('SELECT 1');
  res.json({ ok: true, email: mailer.status() });
}));

app.get('/api/setup', wrap(async (req, res) => {
  const [[row]] = await pool.query('SELECT * FROM vw_SetupStatus');
  res.json(row);
}));

// ---------- inventory ----------

app.get('/api/inventory', wrap(async (req, res) => {
  const [rows] = await pool.query(
    `SELECT VariantID, CategoryName, ItemName, Gender, SizeCode, VariantLabel,
            BaselineQuantity, CurrentQuantity, SuggestedSetpoint, Setpoint, UnitValue, StockStatus
       FROM vw_CurrentInventory
      WHERE ItemIsActive AND VariantIsActive
      ORDER BY CategoryName, ItemName, Gender, SizeSortOrder`
  );
  res.json(rows);
}));

app.get('/api/dashboard', wrap(async (req, res) => {
  const [[catalog]] = await pool.query(
    'SELECT COUNT(*) AS n FROM vw_CurrentInventory WHERE ItemIsActive AND VariantIsActive'
  );
  const [[low]] = await pool.query('SELECT COUNT(*) AS n FROM vw_LowInventory');
  const [[value]] = await pool.query(
    'SELECT COUNT(*) AS valued, COALESCE(SUM(TotalValue), 0) AS total FROM vw_InventoryValue'
  );
  res.json({
    catalogEntries: catalog.n,
    lowStockCount: low.n,
    valuedItemCount: value.valued,
    totalValue: value.total
  });
}));

app.post('/api/inventory/:variantId/setpoint', wrap(async (req, res) => {
  const variantId = id(req.params.variantId, 'Item');
  const userId = id(req.body.userId, 'Staff member');
  const reset = req.body.reset === true;
  if (reset) {
    await callProc('usp_ApplySuggestedSetpoints', [userId, variantId]);
  } else {
    const setpoint = Number(req.body.setpoint);
    if (!Number.isInteger(setpoint) || setpoint < 0) throw new UserError('Setpoint must be a whole number of 0 or more.');
    await callProc('usp_UpdateSetpoint', [variantId, setpoint, userId]);
  }
  res.json({ ok: true });
}));

// ---------- drop-down values ----------

app.get('/api/lookups', wrap(async (req, res) => {
  const { sets } = await callProc('usp_GetLookups', []);
  const [distributionCategories, recipientContexts, eventPurposes, categories, sizes] = sets;
  res.json({ distributionCategories, recipientContexts, eventPurposes, categories, sizes });
}));

app.get('/api/variants', wrap(async (req, res) => {
  const { sets } = await callProc('usp_GetSelectableVariants', [null]);
  res.json(sets[0] || []);
}));

// ---------- transactions ----------

app.post('/api/transactions', wrap(async (req, res) => {
  const b = req.body;
  const type = b.type === 'IN' || b.type === 'OUT' ? b.type : null;
  if (!type) throw new UserError('Choose Stock In or Stock Out.');
  if (!Array.isArray(b.lines) || b.lines.length === 0 || b.lines.length > 50) {
    throw new UserError('Add at least one item.');
  }
  const lines = b.lines.map(l => {
    const quantity = Number(l.quantity);
    if (!Number.isInteger(quantity) || quantity <= 0) throw new UserError('Quantities must be whole numbers greater than zero.');
    return { VariantID: id(l.variantId, 'Item'), Quantity: quantity };
  });
  const { sets, out } = await callProc('usp_RecordTransaction', [
    id(b.userId, 'Staff member'),
    type,
    JSON.stringify(lines),
    type === 'IN' ? text(b.stockInReason, 20) : null,
    type === 'OUT' ? id(b.distributionCategoryId, 'Distribution category', { optional: true }) : null,
    type === 'OUT' ? id(b.recipientContextId, 'Recipient context', { optional: true }) : null,
    type === 'OUT' ? id(b.eventPurposeId, 'Event purpose', { optional: true }) : null,
    text(b.eventDetails, 255),
    text(b.recipientName, 150),
    id(b.combinationId, 'Combination', { optional: true }),
    text(b.notes, 1000)
  ], ['txn_id']);
  mailer.kick();
  res.status(201).json({ transactionId: out.txn_id, lines: sets[0] || [] });
}));

app.get('/api/transactions', wrap(async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 25, 200);
  const [rows] = await pool.query(
    `SELECT h.TransactionID, h.TransactionDate, h.TransactionTypeLabel, h.StockInReason, h.SubmittedBy,
            h.DistributionCategory, h.RecipientContext, h.EventDetails, h.TemplateUsed, h.Notes,
            h.IsDeleted, h.DeletedBy, h.DeleteReason,
            GROUP_CONCAT(CONCAT(h.Quantity, ' x ', h.ItemName,
                         IF(h.VariantLabel = 'Standard', '', CONCAT(' (', h.VariantLabel, ')')))
                         ORDER BY h.ItemName SEPARATOR '; ') AS Items,
            SUM(h.Quantity) AS TotalUnits
       FROM vw_TransactionHistory h
       JOIN (SELECT DISTINCT TransactionID FROM vw_TransactionHistory
              ORDER BY TransactionID DESC LIMIT ?) recent ON recent.TransactionID = h.TransactionID
      GROUP BY h.TransactionID, h.TransactionDate, h.TransactionTypeLabel, h.StockInReason, h.SubmittedBy,
               h.DistributionCategory, h.RecipientContext, h.EventDetails, h.TemplateUsed, h.Notes,
               h.IsDeleted, h.DeletedBy, h.DeleteReason
      ORDER BY h.TransactionID DESC`,
    [limit]
  );
  res.json(rows);
}));

app.post('/api/transactions/:id/delete', wrap(async (req, res) => {
  const reason = text(req.body.reason, 255);
  if (!reason) throw new UserError('Enter a reason for deleting this transaction.');
  await callProc('usp_DeleteTransaction', [id(req.params.id, 'Transaction'), id(req.body.userId, 'Staff member'), reason]);
  mailer.kick();
  res.json({ ok: true });
}));

// ---------- giveaway combinations ----------

app.get('/api/combinations', wrap(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT * FROM vw_GiveawayCombinations ORDER BY CombinationName, ItemName, VariantLabel'
  );
  const byId = new Map();
  for (const r of rows) {
    if (!byId.has(r.CombinationID)) {
      byId.set(r.CombinationID, {
        combinationId: r.CombinationID,
        name: r.CombinationName,
        description: r.Description,
        defaultDistributionCategoryId: r.DefaultDistributionCategoryID,
        defaultDistributionCategory: r.DefaultDistributionCategory,
        lines: []
      });
    }
    byId.get(r.CombinationID).lines.push({
      variantId: r.VariantID,
      label: r.VariantLabel === 'Standard' ? r.ItemName : `${r.ItemName} (${r.VariantLabel})`,
      quantity: r.SuggestedQuantity,
      available: r.CurrentQuantity,
      selectable: !!r.IsSelectable
    });
  }
  res.json([...byId.values()]);
}));

app.post('/api/combinations', wrap(async (req, res) => {
  const b = req.body;
  const name = text(b.name, 100);
  if (!name) throw new UserError('Enter a name for the combination.');
  if (!Array.isArray(b.lines) || b.lines.length === 0) throw new UserError('Add at least one item.');
  const lines = b.lines.map(l => ({ VariantID: id(l.variantId, 'Item'), Quantity: Number(l.quantity) }));
  const { out } = await callProc('usp_SaveGiveawayCombination', [
    name,
    id(b.userId, 'Staff member'),
    JSON.stringify(lines),
    text(b.description, 255),
    id(b.defaultDistributionCategoryId, 'Distribution category', { optional: true })
  ], ['combo_id']);
  res.status(201).json({ combinationId: out.combo_id });
}));

// ---------- staff ----------

app.get('/api/staff', wrap(async (req, res) => {
  const [rows] = await pool.query(
    `SELECT UserID, Username, FirstName, LastName, FullName, Email, UserType, IsActive, CreatedAt, AddedBy
       FROM vw_Users ORDER BY IsActive DESC, FirstName, LastName`
  );
  res.json(rows);
}));

app.post('/api/staff', wrap(async (req, res) => {
  const b = req.body;
  const { out } = await callProc('usp_CreateUser', [
    text(b.email, 254), text(b.firstName, 50), text(b.lastName, 50), text(b.userType, 30), null,
    id(b.actingUserId, 'Staff member', { optional: true })
  ], ['new_user']);
  res.status(201).json({ userId: out.new_user });
}));

app.put('/api/staff/:id', wrap(async (req, res) => {
  const b = req.body;
  await callProc('usp_UpdateUser', [
    id(req.params.id, 'Staff member'), text(b.email, 254), text(b.firstName, 50), text(b.lastName, 50),
    text(b.userType, 30), id(b.actingUserId, 'Staff member', { optional: true })
  ]);
  res.json({ ok: true });
}));

app.post('/api/staff/:id/active', wrap(async (req, res) => {
  await callProc('usp_SetUserActive', [
    id(req.params.id, 'Staff member'), req.body.active === true,
    id(req.body.actingUserId, 'Staff member', { optional: true })
  ]);
  res.json({ ok: true });
}));

// ---------- alert recipients (contract used by alerts.js) ----------

async function readRecipients() {
  const [rows] = await pool.query(
    'SELECT RecipientSlot, RecipientName, Email, ConfigUpdatedAt FROM vw_AlertRecipients ORDER BY RecipientSlot'
  );
  const recipients = rows.map(r => ({ name: r.RecipientName || '', email: r.Email }));
  const revision = crypto.createHash('sha256')
    .update(JSON.stringify([recipients, rows[0] ? rows[0].ConfigUpdatedAt : null]))
    .digest('hex').slice(0, 16);
  return { revision, recipients };
}

app.get('/api/alert-recipients', wrap(async (req, res) => {
  res.json(await readRecipients());
}));

app.put('/api/alert-recipients', wrap(async (req, res) => {
  const b = req.body;
  const current = await readRecipients();
  if (b.revision !== current.revision) {
    return res.status(409).json({ error: 'Someone else updated the list. Reload and try again.' });
  }
  if (!Array.isArray(b.recipients) || b.recipients.length < 1 || b.recipients.length > 3) {
    throw new UserError('Between one and three alert recipients are required.');
  }
  const list = b.recipients.map((r, i) => ({
    Slot: i + 1, Name: text(r.name, 100), Email: text(r.email, 254)
  }));
  await callProc('usp_SetAlertRecipients', [JSON.stringify(list), id(b.userId, 'Staff member', { optional: true })]);
  res.json(await readRecipients());
}));

// ---------- reports ----------

const reports = {
  'current-inventory': q => ['usp_rpt_CurrentInventory', [id(q.categoryId, 'Category', { optional: true }), false]],
  'low-inventory':     () => ['usp_rpt_LowInventory', []],
  'usage':             q => ['usp_rpt_InventoryUsage', [date(q.start), date(q.end), null, null]],
  'value':             () => ['usp_rpt_InventoryValue', [null]],
  'history':           q => ['usp_rpt_TransactionHistory', [date(q.start), date(q.end), null, null, null, q.includeDeleted === 'true']],
  'giveaway':          q => ['usp_rpt_Giveaway', [date(q.start), date(q.end), null, null, false, false]],
  'forecast':          () => ['usp_rpt_DemandForecast', [null, null, null]],
  'security-review':   () => ['usp_Security_WeeklyReview', [7]]
};

app.get('/api/reports/:key', wrap(async (req, res) => {
  const build = reports[req.params.key];
  if (!build) throw new UserError('Unknown report.', 404);
  const [proc, args] = build(req.query);
  const { sets } = await callProc(proc, args);
  res.json(sets);
}));

// ---------- errors ----------

app.use('/api', (req, res) => res.status(404).json({ error: 'Not found.' }));

app.use((err, req, res, next) => {
  if (err instanceof UserError) return res.status(err.status).json({ error: err.message });
  if (err.sqlState === '45000') return res.status(400).json({ error: err.sqlMessage });
  if (err.code === 'ER_CHECK_CONSTRAINT_VIOLATED' || err.code === 'ER_DUP_ENTRY') {
    return res.status(400).json({ error: 'That value is not allowed or already exists.' });
  }
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Invalid request.' });
  console.error(err);
  res.status(500).json({ error: 'Something went wrong. Please try again.' });
});

const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || '0.0.0.0';
app.listen(port, host, () => {
  console.log(`GCR Inventory app running at http://${host === '0.0.0.0' ? 'localhost' : host}:${port}`);
  mailer.start(pool);
});
