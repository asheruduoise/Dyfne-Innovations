
/* ==============================
   SIDEBAR NAVIGATION
================================= */

const navLinks = document.querySelectorAll(".nav-link");
const pages = document.querySelectorAll(".page");

// Display the selected page
function showPage() {
    const pageId = window.location.hash.substring(1) || "dashboard";
    const targetPage = document.getElementById(pageId);

    // Default to Dashboard if the page doesn't exist
    const activePageId = targetPage?.classList.contains("page")
        ? pageId
        : "dashboard";

    // Show the selected page and hide the others
    pages.forEach((page) => {
        page.classList.toggle("active", page.id === activePageId);
    });

    // Highlight the selected navigation link
    navLinks.forEach((link) => {
        const isActive = link.getAttribute("href") === "#" + activePageId;

        link.classList.toggle("active", isActive);

        if (isActive) {
            link.setAttribute("aria-current", "page");
        } else {
            link.removeAttribute("aria-current");
        }
    });
}

// Update navigation when the URL changes
window.addEventListener("hashchange", showPage);

// Display the correct page when the website loads
showPage();


/* ==============================
   ITEM ROWS (shared by the transaction and giveaway forms)
================================= */

// Adds a row by copying the first one; returns the new row
function addItemRow(container, rowClass, idPrefix, defaultQuantity) {
    const row = container.querySelector("." + rowClass).cloneNode(true);
    const item = row.querySelector("select");
    const quantity = row.querySelector("input");
    const n = container.dataset.nextId ? Number(container.dataset.nextId) : container.children.length + 1;
    container.dataset.nextId = String(n + 1);
    item.id = idPrefix + "-item-" + n;
    quantity.id = idPrefix + "-quantity-" + n;
    const labels = row.querySelectorAll("label");
    labels[0].htmlFor = item.id;
    labels[1].htmlFor = quantity.id;
    item.value = "";
    quantity.value = defaultQuantity;
    item.setCustomValidity("");
    container.appendChild(row);
    updateRemoveButtons(container, rowClass);
    return row;
}

function updateRemoveButtons(container, rowClass) {
    const rows = container.querySelectorAll("." + rowClass);
    rows.forEach(row => { row.querySelector("button").disabled = rows.length === 1; });
}

// Keep only the first row and clear it
function resetItemRows(container, rowClass, defaultQuantity) {
    container.querySelectorAll("." + rowClass).forEach((row, i) => { if (i > 0) row.remove(); });
    const first = container.querySelector("." + rowClass);
    first.querySelector("select").value = "";
    first.querySelector("input").value = defaultQuantity;
    updateRemoveButtons(container, rowClass);
}

// Collects [{variantId, quantity}] and flags repeated items; returns null if invalid
function collectItemRows(container, feedback) {
    const seen = new Set();
    const lines = [];
    for (const row of container.children) {
        const select = row.querySelector("select");
        const quantity = row.querySelector("input");
        select.setCustomValidity("");
        if (select.value && seen.has(select.value)) {
            select.setCustomValidity("Select each item once; combine its quantities in one row.");
            feedback.textContent = "Repeated item: combine its quantities in one row.";
            select.reportValidity();
            return null;
        }
        seen.add(select.value);
        lines.push({ variantId: Number(select.value), quantity: Number(quantity.value) });
    }
    return lines;
}
