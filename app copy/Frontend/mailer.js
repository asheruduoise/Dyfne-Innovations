// Low-stock email job. Reads vw_PendingAlertEmails, sends one email per triggering
// transaction, then records each attempt with usp_MarkAlertSent. After 5 failed
// attempts an alert moves to vw_FailedAlertEmails. Disabled until SMTP_HOST is set.
const nodemailer = require('nodemailer');

const INTERVAL_MS = Number(process.env.ALERT_POLL_SECONDS || 60) * 1000;
let transport = null;
let pool = null;
let timer = null;
let running = false;
let lastError = null;

function configured() {
  return Boolean(process.env.SMTP_HOST && process.env.ALERT_FROM);
}

function status() {
  if (!configured()) return 'not configured';
  return lastError ? `error: ${lastError}` : 'on';
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function compose(alerts) {
  const label = a => (a.VariantLabel === 'Standard' ? a.ItemName : `${a.ItemName} (${a.VariantLabel})`);
  const subject = alerts.length === 1
    ? `UH Inventory - Low stock: ${label(alerts[0])}`
    : `UH Inventory - Low stock: ${alerts.length} items`;
  const lines = alerts.map(a => `${label(a)}: ${a.CurrentQuantity} left (restock threshold ${a.Setpoint})`);
  const text = [
    'The following merchandise has reached its restock threshold:',
    '',
    ...lines.map(l => `- ${l}`),
    '',
    'Please review these items in the GCR inventory system.',
    'Automated notification from the UH GCR Inventory Management System.'
  ].join('\n');
  const rows = alerts.map(a => `<tr><td style="padding:6px 12px">${escapeHtml(label(a))}</td>` +
    `<td style="padding:6px 12px;text-align:right">${a.CurrentQuantity}</td>` +
    `<td style="padding:6px 12px;text-align:right">${a.Setpoint}</td></tr>`).join('');
  const html = `<div style="font-family:Arial,sans-serif;color:#222">
    <h2 style="color:#c8102e;margin:0 0 12px">Time to review your stock</h2>
    <p>The following merchandise has reached its restock threshold:</p>
    <table style="border-collapse:collapse;background:#f6f1ea">
      <tr><th style="padding:6px 12px;text-align:left">Item</th><th style="padding:6px 12px">Current quantity</th>
          <th style="padding:6px 12px">Restock threshold</th></tr>${rows}</table>
    <p>Please review these items in the GCR inventory system.</p>
    <p style="font-size:11px;color:#777">Automated notification from the UH GCR Inventory Management System.</p></div>`;
  return { subject, text, html };
}

async function markSent(alertId, recipients, error) {
  await pool.query('CALL usp_MarkAlertSent(?, ?, ?)', [alertId, recipients, error ? String(error).slice(0, 1000) : null]);
}

async function runOnce() {
  if (!transport || running) return;
  running = true;
  try {
    const [rows] = await pool.query('SELECT * FROM vw_PendingAlertEmails ORDER BY AlertGeneratedAt, AlertID');
    const groups = new Map();
    for (const r of rows) {
      const key = r.TriggeringTransactionID === null ? `alert-${r.AlertID}` : `txn-${r.TriggeringTransactionID}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(r);
    }
    for (const alerts of groups.values()) {
      const to = alerts[0].Recipients;
      const recipients = to.split(';').map(s => s.trim()).filter(Boolean);
      try {
        await transport.sendMail({ from: process.env.ALERT_FROM, to: recipients, ...compose(alerts) });
        for (const a of alerts) await markSent(a.AlertID, to, null);
        lastError = null;
      } catch (err) {
        lastError = err.message;
        console.error('Alert email failed:', err.message);
        for (const a of alerts) await markSent(a.AlertID, to, err.message);
      }
    }
  } catch (err) {
    console.error('Alert job error:', err.message);
  } finally {
    running = false;
  }
}

function start(dbPool) {
  pool = dbPool;
  if (!configured()) {
    console.log('Alert emails: not configured (set SMTP_HOST and ALERT_FROM in .env). Alerts stay queued.');
    return;
  }
  transport = nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT || 587),
    secure: process.env.SMTP_SECURE === 'true',
    auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASSWORD } : undefined
  });
  console.log(`Alert emails: on (checking every ${INTERVAL_MS / 1000}s via ${process.env.SMTP_HOST}).`);
  timer = setInterval(runOnce, INTERVAL_MS);
  timer.unref();
  runOnce();
}

// Check right away after a transaction instead of waiting for the next poll
function kick() {
  if (transport) setTimeout(runOnce, 500);
}

module.exports = { start, kick, status, runOnce };
