// Database connection pool. Connects ONLY as the least-privilege app account
// (svc_gcr_inventory): it can read views and run stored procedures, nothing else.
require('dotenv').config({ quiet: true });
const mysql = require('mysql2/promise');

const required = ['DB_USER', 'DB_PASSWORD', 'DB_NAME'];
for (const name of required) {
  if (!process.env[name]) {
    console.error(`Missing ${name}. Copy .env.example to .env and fill it in.`);
    process.exit(1);
  }
}

module.exports = mysql.createPool({
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  connectionLimit: 5,
  decimalNumbers: true,
  dateStrings: true
});
