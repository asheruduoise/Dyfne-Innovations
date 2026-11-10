/* ==============================
   LIVE DATA FROM THE DATABASE
   Fills the Dashboard and Inventory pages from /api/dashboard and /api/inventory.
================================= */

const DASH = "\u2014"; // em dash for empty values

function cell(text) {
    const td = document.createElement("td");
    td.textContent = text === null || text === undefined || text === "" ? DASH : String(text);
    return td;
}

function statusCell(stockStatus) {
    const td = document.createElement("td");
    const span = document.createElement("span");
    span.className = "status";
    if (stockStatus === "OK") {
        span.classList.add("in-stock");
        span.textContent = "In Stock";
    } else if (stockStatus === "Low Stock" || stockStatus === "Out of Stock") {
        span.classList.add("low-stock");
        span.textContent = stockStatus;
    } else {
        span.classList.add("pending");
        span.textContent = "Not Verified";
    }
    td.appendChild(span);
    return td;
}

function showMessage(tbody, columns, message) {
    tbody.replaceChildren();
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = columns;
    td.textContent = message;
    tr.appendChild(td);
    tbody.appendChild(tr);
}

function money(value) {
    return "$" + Number(value).toLocaleString("en-US", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
    });
}

// Thrown when the session is missing or expired; the sign-in screen is shown instead.
class SignedOutError extends Error {}

// All API calls go through here. JSON in and out; the session cookie is sent automatically.
async function apiFetch(url, options = {}) {
    const init = { method: options.method || "GET", headers: {} };
    if (options.body !== undefined) {
        init.headers["Content-Type"] = "application/json";
        init.body = JSON.stringify(options.body);
    }
    const response = await fetch(url, init);
    let data = null;
    try { data = await response.json(); } catch { data = null; }
    if (response.status === 401 && !options.allowSignedOut) {
        showSignIn(data && data.error);
        throw new SignedOutError(data && data.error);
    }
    if (response.status === 403 && data && data.mustChangePassword) {
        showChangePassword();
        throw new SignedOutError(data.error);
    }
    if (!response.ok) {
        const err = new Error((data && data.error) || url + " returned " + response.status);
        err.status = response.status;
        err.userMessage = data && data.error;
        throw err;
    }
    return data;
}

async function getJson(url) {
    return apiFetch(url);
}

// Inventory page: full table
function renderInventory(rows) {
    const tbody = document.getElementById("inventory-table-body");
    if (!tbody) return;
    if (rows.length === 0) {
        showMessage(tbody, 8, "No inventory items found.");
        return;
    }
    tbody.replaceChildren();
    rows.forEach((r) => {
        const tr = document.createElement("tr");
        tr.append(
            cell(r.CategoryName),
            cell(r.ItemName),
            cell(r.Gender),
            cell(r.SizeCode),
            cell(r.BaselineQuantity),
            cell(r.CurrentQuantity),
            cell(r.Setpoint),
            cell(r.UnitValue === null ? null : money(r.UnitValue))
        );
        tbody.appendChild(tr);
    });
}

// Dashboard: items needing attention first, then the rest (top 5)
function renderDashboardTable(rows) {
    const tbody = document.getElementById("dashboard-table-body");
    if (!tbody) return;
    const rank = { "Out of Stock": 0, "Low Stock": 1, "Not Yet Counted": 2, "OK": 3 };
    const top = [...rows]
        .sort((a, b) => (rank[a.StockStatus] ?? 4) - (rank[b.StockStatus] ?? 4))
        .slice(0, 5);
    if (top.length === 0) {
        showMessage(tbody, 4, "No inventory items found.");
        return;
    }
    tbody.replaceChildren();
    top.forEach((r) => {
        const tr = document.createElement("tr");
        const name = r.VariantLabel === "Standard" ? r.ItemName : r.ItemName + " (" + r.VariantLabel + ")";
        tr.append(cell(name), cell(r.CategoryName), cell(r.CurrentQuantity), statusCell(r.StockStatus));
        tbody.appendChild(tr);
    });
}

function renderStats(s) {
    document.getElementById("stat-catalog").textContent = s.catalogEntries;
    document.getElementById("stat-low").textContent = s.lowStockCount;
    document.getElementById("stat-low-detail").textContent =
        s.lowStockCount === 0 ? "No items at or below setpoint" : "At or below their setpoints";
    if (s.valuedItemCount > 0) {
        document.getElementById("stat-value").textContent = money(s.totalValue);
        document.getElementById("stat-value-detail").textContent =
            "Across " + s.valuedItemCount + " items with values";
    } else {
        document.getElementById("stat-value").textContent = "Unknown";
        document.getElementById("stat-value-detail").textContent = "Values not yet provided";
    }
}

async function loadLiveData() {
    try {
        const [stats, rows] = await Promise.all([
            getJson("/api/dashboard"),
            getJson("/api/inventory")
        ]);
        renderStats(stats);
        renderInventory(rows);
        renderDashboardTable(rows);
    } catch (err) {
        if (err instanceof SignedOutError) return;
        console.error(err);
        for (const id of ["stat-catalog", "stat-low", "stat-value"]) {
            document.getElementById(id).textContent = "Unavailable";
        }
        document.getElementById("stat-low-detail").textContent = "Start the app server to load data";
        document.getElementById("stat-value-detail").textContent = "Database connection required";
        const message = "Could not load inventory from the database. Please try again.";
        const a = document.getElementById("inventory-table-body");
        const b = document.getElementById("dashboard-table-body");
        if (a) showMessage(a, 8, message);
        if (b) showMessage(b, 4, message);
    }
}


/* ==============================
   SIGN-IN
   The page stays hidden (body.signed-out) until /api/me confirms a session.
================================= */

let currentUser = null;

const authScreen = document.getElementById("auth-screen");
const loginForm = document.getElementById("login-form");
const loginMessage = document.getElementById("login-message");
const changeForm = document.getElementById("change-password-form");
const changeMessage = document.getElementById("change-password-message");

function showSignIn(message) {
    currentUser = null;
    document.body.classList.add("signed-out");
    authScreen.hidden = false;
    changeForm.hidden = true;
    loginForm.hidden = false;
    loginForm.reset();
    loginMessage.textContent = message && message !== "Please sign in." ? message : "";
    document.getElementById("login-username").focus();
}

function showChangePassword() {
    document.body.classList.add("signed-out");
    authScreen.hidden = false;
    loginForm.hidden = true;
    changeForm.hidden = false;
    changeForm.reset();
    changeMessage.textContent = "";
    document.getElementById("current-password").focus();
}

function enterApp(me) {
    currentUser = me;
    authScreen.hidden = true;
    document.body.classList.remove("signed-out");
    document.getElementById("current-user-name").textContent = me.displayName;
    document.getElementById("transaction-user").value = me.displayName;
    loadLiveData();
    loadFormOptions();
    loadRecentTransactions();
}

async function startApp() {
    try {
        const me = await apiFetch("/api/me");
        if (me.mustChangePassword) showChangePassword();
        else enterApp(me);
    } catch (err) {
        if (!(err instanceof SignedOutError)) {
            console.error(err);
            showSignIn("Could not reach the server. Make sure the app is running, then refresh.");
        }
    }
}

loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const username = document.getElementById("login-username").value.trim();
    const password = document.getElementById("login-password").value;
    if (!username || !password) {
        loginMessage.textContent = "Enter your username and password.";
        return;
    }
    const button = loginForm.querySelector("button[type=submit]");
    button.disabled = true;
    loginMessage.textContent = "";
    try {
        await apiFetch("/api/login", { method: "POST", body: { username, password }, allowSignedOut: true });
        await startApp();
    } catch (err) {
        loginMessage.textContent = err.userMessage || "Could not sign in. Please try again.";
        document.getElementById("login-password").value = "";
        document.getElementById("login-password").focus();
    } finally {
        button.disabled = false;
    }
});

changeForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const currentPassword = document.getElementById("current-password").value;
    const newPassword = document.getElementById("new-password").value;
    const confirm = document.getElementById("confirm-password").value;
    if (newPassword.length < 12) {
        changeMessage.textContent = "New password must be at least 12 characters.";
        return;
    }
    if (newPassword !== confirm) {
        changeMessage.textContent = "The new passwords don't match.";
        return;
    }
    const button = changeForm.querySelector("button[type=submit]");
    button.disabled = true;
    try {
        await apiFetch("/api/change-password", { method: "POST", body: { currentPassword, newPassword } });
        await startApp();
    } catch (err) {
        if (!(err instanceof SignedOutError)) {
            changeMessage.textContent = err.userMessage || "Could not save the password. Please try again.";
        }
    } finally {
        button.disabled = false;
    }
});

async function signOut() {
    try {
        await apiFetch("/api/logout", { method: "POST", body: {}, allowSignedOut: true });
    } catch (err) {
        console.error(err);
    }
    showSignIn("You have signed out.");
}

document.getElementById("logout-button").addEventListener("click", signOut);
document.getElementById("change-password-cancel").addEventListener("click", signOut);


/* ==============================
   STOCK TRANSACTIONS
   Drop-downs come from /api/form-options; saving posts to /api/transactions.
================================= */

function fillSelect(select, placeholder, options) {
    const keep = select.value;
    select.replaceChildren(new Option(placeholder, ""));
    options.forEach(({ value, label }) => select.add(new Option(label, value)));
    if (options.some(o => String(o.value) === keep)) select.value = keep;
}

async function loadFormOptions() {
    try {
        const data = await apiFetch("/api/form-options");
        const items = data.variants.map(v => ({
            value: v.VariantID,
            label: v.DisplayName + " (on hand: " + v.CurrentQuantity + ")"
        }));
        document.querySelectorAll('#transaction-items select[name="variant[]"]').forEach(select =>
            fillSelect(select, "-- Select an Item --", items));
        fillSelect(document.getElementById("distribution-category"), "-- Select Category --",
            data.categories.map(c => ({ value: c.DistributionCategoryID, label: c.CategoryName })));
        fillSelect(document.getElementById("recipient-context"), "-- Select Recipient --",
            data.contexts.map(c => ({ value: c.RecipientContextID, label: c.ContextName })));
    } catch (err) {
        if (err instanceof SignedOutError) return;
        console.error(err);
        document.getElementById("transaction-feedback").textContent =
            "Could not load the item list. Refresh the page to try again.";
    }
}

function formatDate(value) {
    const d = new Date(String(value).replace(" ", "T"));
    return isNaN(d) ? value : d.toLocaleString("en-US", {
        month: "short", day: "numeric", hour: "numeric", minute: "2-digit"
    });
}

async function loadRecentTransactions() {
    const tbody = document.getElementById("recent-transactions-body");
    try {
        const rows = await apiFetch("/api/transactions/recent");
        if (rows.length === 0) {
            showMessage(tbody, 7, "No transactions yet.");
            return;
        }
        tbody.replaceChildren();
        rows.forEach(r => {
            const tr = document.createElement("tr");
            const item = r.VariantLabel && r.VariantLabel !== "Standard"
                ? r.ItemName + " (" + r.VariantLabel + ")" : r.ItemName;
            const details = r.TransactionTypeLabel === "Stock In"
                ? r.StockInReason
                : [r.DistributionCategory, r.RecipientContext, r.EventDetails].filter(Boolean).join(" · ");
            tr.append(
                cell(r.TransactionID),
                cell(formatDate(r.TransactionDate)),
                cell(r.TransactionTypeLabel),
                cell(item),
                cell(r.Quantity),
                cell(details),
                cell(r.SubmittedBy)
            );
            tbody.appendChild(tr);
        });
    } catch (err) {
        if (err instanceof SignedOutError) return;
        console.error(err);
        showMessage(tbody, 7, "Could not load recent transactions.");
    }
}

// Called by the form's submit handler in script.js after its own checks pass.
window.saveTransaction = async function (form, feedback, resetForm) {
    const type = document.getElementById("transaction-type").value === "out" ? "OUT" : "IN";
    const lines = Array.from(form.querySelectorAll(".transaction-item-row")).map(row => ({
        variantId: Number(row.querySelector("select").value),
        quantity: Number(row.querySelector("input").value)
    }));
    const body = {
        type,
        lines,
        notes: document.getElementById("transaction-notes").value
    };
    if (type === "IN") {
        body.stockInReason = document.getElementById("stock-in-reason").value;
    } else {
        body.distributionCategoryId = Number(document.getElementById("distribution-category").value);
        body.recipientContextId = Number(document.getElementById("recipient-context").value);
        body.eventDetails = document.getElementById("transaction-purpose").value;
    }

    const button = document.getElementById("transaction-submit");
    button.disabled = true;
    feedback.textContent = "Saving…";
    try {
        const result = await apiFetch("/api/transactions", { method: "POST", body });
        resetForm();
        document.getElementById("transaction-user").value = currentUser ? currentUser.displayName : "";
        feedback.textContent = "Saved. Transaction #" + result.transactionId + " recorded (" +
            (type === "IN" ? "Stock In" : "Stock Out") + ", " + lines.length +
            (lines.length === 1 ? " item" : " items") + ").";
        loadLiveData();
        loadFormOptions();
        loadRecentTransactions();
    } catch (err) {
        if (err instanceof SignedOutError) return;
        if (!err.userMessage) console.error(err);
        feedback.textContent = "Not saved. " + (err.userMessage || "Something went wrong. Please try again.");
    } finally {
        button.disabled = false;
    }
};

startApp();
