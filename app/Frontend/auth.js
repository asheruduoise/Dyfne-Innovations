// Sign-in, sessions and passwords, following the contract in the main README (section 4).
// The database does the real work (lockout, 15-minute idle timeout, audit log);
// this file only checks passwords with bcrypt and carries the session token in a cookie.
const bcrypt = require('bcryptjs');
const pool = require('./db');

const COOKIE = 'gcr_session';
const BCRYPT_COST = 12;
const MIN_PASSWORD_LENGTH = 12;
// Compared against when the username doesn't exist, so a wrong username takes
// as long as a wrong password and the two can't be told apart.
const DUMMY_HASH = bcrypt.hashSync('not-a-real-password-just-for-timing', BCRYPT_COST);

function readSessionCookie(req) {
  const header = req.headers.cookie || '';
  for (const part of header.split(';')) {
    const [name, ...rest] = part.trim().split('=');
    if (name === COOKIE) {
      const value = rest.join('=');
      return /^[0-9a-f]{64}$/i.test(value) ? value : null;
    }
  }
  return null;
}

function setSessionCookie(res, token) {
  // HttpOnly: page scripts can't read it. SameSite=Strict: other sites can't send it.
  // No Max-Age: it disappears when the browser closes; the database ends idle sessions after 15 min.
  res.setHeader('Set-Cookie', `${COOKIE}=${token}; HttpOnly; SameSite=Strict; Path=/`);
}

function clearSessionCookie(res) {
  res.setHeader('Set-Cookie', `${COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`);
}

function clientInfo(req) {
  return `${req.ip} ${req.headers['user-agent'] || ''}`.slice(0, 255);
}

async function getCredentials(conn, username) {
  const [sets] = await conn.query('CALL usp_Auth_GetCredentials(?)', [username]);
  return sets[0][0] || null;
}

async function getUserById(conn, userId) {
  const [rows] = await conn.query(
    'SELECT UserID, Username, DisplayName FROM vw_App_ActiveUsers WHERE UserID = ?',
    [userId]
  );
  return rows[0] || null;
}

// Every API request (except sign-in and health) goes through here.
// Sets req.user = { id, username, displayName, mustChangePassword }.
async function requireSession(req, res, next) {
  const token = readSessionCookie(req);
  if (!token) return res.status(401).json({ error: 'Please sign in.' });
  let conn;
  try {
    conn = await pool.getConnection();
    await conn.query('CALL usp_Auth_ValidateSession(?, @sessUser, @sessStatus)', [token]);
    const [[s]] = await conn.query('SELECT @sessUser AS userId, @sessStatus AS status');
    if (s.status !== 'OK') {
      clearSessionCookie(res);
      const msg = s.status === 'Expired'
        ? 'You were signed out after 15 minutes of inactivity. Please sign in again.'
        : 'Please sign in.';
      return res.status(401).json({ error: msg });
    }
    const user = await getUserById(conn, s.userId);
    if (!user) {
      clearSessionCookie(res);
      return res.status(401).json({ error: 'Please sign in.' });
    }
    const cred = await getCredentials(conn, user.Username);
    req.user = {
      id: user.UserID,
      username: user.Username,
      displayName: user.DisplayName,
      mustChangePassword: Boolean(cred && cred.MustChangePassword)
    };
    req.sessionToken = token;
    next();
  } catch (err) {
    next(err);
  } finally {
    if (conn) conn.release();
  }
}

// After a password reset by someone else, the user must pick a new password
// before doing anything else.
function blockUntilPasswordChanged(req, res, next) {
  if (req.user.mustChangePassword) {
    return res.status(403).json({ error: 'Please choose a new password first.', mustChangePassword: true });
  }
  next();
}

async function login(req, res, next) {
  const username = typeof req.body?.username === 'string' ? req.body.username.trim() : '';
  const password = typeof req.body?.password === 'string' ? req.body.password : '';
  if (!username || !password || username.length > 50 || password.length > 200) {
    return res.status(400).json({ error: 'Enter your username and password.' });
  }
  let conn;
  try {
    conn = await pool.getConnection();
    const cred = await getCredentials(conn, username);
    // Always run bcrypt, even with no account or no password set (same timing).
    const hash = cred && cred.PasswordHash ? cred.PasswordHash : DUMMY_HASH;
    const passwordOk = (await bcrypt.compare(password, hash)) && Boolean(cred && cred.PasswordHash);

    await conn.query(
      'CALL usp_Auth_RecordLoginAttempt(?, ?, ?, @loginOutcome, @loginUser, @loginToken)',
      [username, passwordOk, clientInfo(req)]
    );
    const [[r]] = await conn.query(
      'SELECT @loginOutcome AS outcome, @loginUser AS userId, @loginToken AS token'
    );

    if (r.outcome === 'Locked') {
      return res.status(423).json({ error: 'Too many attempts. Try again in 15 minutes.' });
    }
    if (r.outcome !== 'OK') {
      return res.status(401).json({ error: 'Username or password is incorrect.' });
    }
    setSessionCookie(res, r.token);
    const user = await getUserById(conn, r.userId);
    res.json({
      displayName: user ? user.DisplayName : username,
      mustChangePassword: Boolean(cred.MustChangePassword)
    });
  } catch (err) {
    next(err);
  } finally {
    if (conn) conn.release();
  }
}

async function logout(req, res, next) {
  const token = readSessionCookie(req);
  clearSessionCookie(res);
  if (!token) return res.json({ ok: true });
  try {
    await pool.query('CALL usp_Auth_Logout(?)', [token]);
    res.json({ ok: true });
  } catch (err) {
    next(err);
  }
}

function checkNewPassword(password) {
  if (typeof password !== 'string' || password.length < MIN_PASSWORD_LENGTH) {
    return `New password must be at least ${MIN_PASSWORD_LENGTH} characters.`;
  }
  if (password.length > 72) {
    return 'New password must be 72 characters or fewer.';
  }
  return null;
}

async function hashPassword(password) {
  return bcrypt.hash(password, BCRYPT_COST);
}

// Signed-in user changes their own password (clears "must change").
async function changePassword(req, res, next) {
  const current = typeof req.body?.currentPassword === 'string' ? req.body.currentPassword : '';
  const next1 = req.body?.newPassword;
  const problem = checkNewPassword(next1);
  if (problem) return res.status(400).json({ error: problem });
  if (next1 === current) {
    return res.status(400).json({ error: 'Choose a password different from your current one.' });
  }
  let conn;
  try {
    conn = await pool.getConnection();
    const cred = await getCredentials(conn, req.user.username);
    const ok = cred && cred.PasswordHash && (await bcrypt.compare(current, cred.PasswordHash));
    if (!ok) return res.status(400).json({ error: 'Your current password is incorrect.' });
    const hash = await hashPassword(next1);
    await conn.query('CALL usp_User_SetPassword(?, ?, ?)', [req.user.id, req.user.id, hash]);
    res.json({ ok: true });
  } catch (err) {
    if (err.sqlState === '45000') return res.status(400).json({ error: err.sqlMessage });
    next(err);
  } finally {
    if (conn) conn.release();
  }
}

module.exports = {
  requireSession,
  blockUntilPasswordChanged,
  login,
  logout,
  changePassword,
  checkNewPassword,
  hashPassword,
  getCredentials
};
