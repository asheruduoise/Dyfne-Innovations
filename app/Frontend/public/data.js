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

async function getJson(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(url + " returned " + response.status);
    return response.json();
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

let inventoryRows = [];

async function loadLiveData() {
    try {
        const [stats, rows] = await Promise.all([
            getJson("/api/dashboard"),
            getJson("/api/inventory")
        ]);
        inventoryRows = rows;
        renderStats(stats);
        renderInventory(rows);
        renderDashboardTable(rows);
        fillSetpointItems(rows);
    } catch (err) {
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
   SETPOINT CHANGES (Inventory page)
================================= */

const setpointForm = document.getElementById("setpoint-form");
const setpointVariant = document.getElementById("setpoint-variant");
const setpointValue = document.getElementById("setpoint-value");
const setpointFeedback = document.getElementById("setpoint-feedback");

function fillSetpointItems(rows) {
    GCR.fillSelect(setpointVariant, rows, r => String(r.VariantID), r =>
        `${r.VariantLabel === "Standard" ? r.ItemName : r.ItemName + " (" + r.VariantLabel + ")"} - setpoint ${r.Setpoint}, suggested ${r.SuggestedSetpoint ?? "n/a"}`);
}

setpointVariant.addEventListener("change", () => {
    const row = inventoryRows.find(r => String(r.VariantID) === setpointVariant.value);
    setpointValue.value = row ? row.Setpoint : "";
    setpointFeedback.textContent = "";
});

async function saveSetpoint(reset) {
    setpointFeedback.textContent = "";
    const userId = GCR.requireStaff(setpointFeedback);
    if (!userId) return;
    if (!setpointVariant.value) {
        setpointFeedback.textContent = "Choose an item first.";
        return;
    }
    const body = reset ? { userId, reset: true } : { userId, setpoint: Number(setpointValue.value) };
    try {
        await GCR.api("POST", `/api/inventory/${setpointVariant.value}/setpoint`, body);
        const label = setpointVariant.selectedOptions[0].textContent.split(" - setpoint")[0];
        setpointFeedback.textContent = reset ? `${label} reset to its suggested setpoint.` : `${label} setpoint saved.`;
        GCR.inventoryChanged();
    } catch (err) {
        setpointFeedback.textContent = err.message;
    }
}

setpointForm.addEventListener("submit", event => {
    event.preventDefault();
    saveSetpoint(false);
});
document.getElementById("setpoint-reset").addEventListener("click", () => saveSetpoint(true));
document.addEventListener("gcr:inventory-changed", loadLiveData);

loadLiveData();
