// Set or reset an app user's password from the command line (run on the GCR PC).
//
//   npm run set-password -- gcr.admin
//       Sets gcr.admin's own password. Use this once for the first admin.
//   npm run set-password -- gcr.staff1 --by gcr.admin
//       gcr.admin sets a temporary password for gcr.staff1, who must choose
//       a new one the first time they sign in.
//
// The password is typed (not shown), hashed with bcrypt here, and only the
// hash is sent to the database. It is never stored in a file or shell history.
const readline = require('readline');
const pool = require('./db');
const auth = require('./auth');

// Reads lines without echoing what is typed. One reader for all questions,
// so nothing typed ahead gets lost between prompts.
function hiddenPrompter() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  let prompt = '';
  rl._writeToOutput = (s) => {
    if (s.includes(prompt) && prompt) rl.output.write(prompt);
    else if (s.includes('\n') || s.includes('\r')) rl.output.write('\n');
  };
  const queue = [];
  const waiting = [];
  rl.on('line', (line) => {
    if (waiting.length) waiting.shift()(line);
    else queue.push(line);
  });
  return {
    ask(question) {
      prompt = question;
      rl.output.write(question);
      if (queue.length) return Promise.resolve(queue.shift());
      return new Promise((resolve) => waiting.push(resolve));
    },
    close() {
      rl.close();
    }
  };
}

async function findUser(username) {
  const cred = await auth.getCredentials(pool, username);
  if (!cred) throw new Error(`No user named "${username}".`);
  if (!cred.IsActive) throw new Error(`"${username}" is deactivated.`);
  return cred;
}

async function main() {
  const args = process.argv.slice(2);
  const target = args[0];
  const byIndex = args.indexOf('--by');
  const actorName = byIndex > -1 ? args[byIndex + 1] : target;
  if (!target || target.startsWith('--') || !actorName) {
    console.log('Usage: npm run set-password -- <username> [--by <admin username>]');
    process.exitCode = 1;
    return;
  }

  const targetUser = await findUser(target);
  const actorUser = await findUser(actorName);

  const prompter = hiddenPrompter();
  let password;
  let again;
  try {
    password = await prompter.ask(`New password for ${target}: `);
    again = await prompter.ask('Type it again: ');
  } finally {
    prompter.close();
  }
  const problem = auth.checkNewPassword(password);
  if (problem) throw new Error(problem);
  if (again !== password) throw new Error('The two passwords did not match.');

  const hash = await auth.hashPassword(password);
  await pool.query('CALL usp_User_SetPassword(?, ?, ?)', [actorUser.UserID, targetUser.UserID, hash]);

  if (actorUser.UserID === targetUser.UserID) {
    console.log(`Password set for ${target}. They can sign in now.`);
  } else {
    console.log(`Temporary password set for ${target} by ${actorName}.`);
    console.log('They must choose a new password the first time they sign in.');
  }
}

main()
  .catch((err) => {
    console.error('Error:', err.sqlMessage || err.message);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
