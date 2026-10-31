
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
   STOCK TRANSACTION FORM
================================= */

const transactionTypeSelect = document.getElementById("transaction-type");
const transactionForm = document.getElementById("withdrawal-form");
const transactionItems = document.getElementById("transaction-items");
const transactionFeedback = document.getElementById("transaction-feedback");
const distributionHeading = Array.from(transactionForm.querySelectorAll("h3"))
    .find(heading => heading.textContent.trim() === "Distribution Information");
let nextTransactionItemId = 2;

function clearTransactionFeedback() {
    transactionFeedback.textContent = "";
    transactionItems.querySelectorAll("select").forEach(field => field.setCustomValidity(""));
}

function updateTransactionForm() {
    const isStockOut = transactionTypeSelect.value === "out";
    const isStockIn = transactionTypeSelect.value === "in";
    const reason = document.getElementById("stock-in-reason");
    document.getElementById("stock-in-reason-group").hidden = !isStockIn;
    reason.disabled = !isStockIn;
    reason.required = isStockIn;
    for (const id of ["distribution-category", "recipient-context", "transaction-purpose"]) {
        const field = document.getElementById(id);
        field.closest(".form-group").hidden = !isStockOut;
        field.disabled = !isStockOut;
        field.required = isStockOut && id !== "transaction-purpose";
    }
    distributionHeading.hidden = !isStockOut;
    distributionHeading.nextElementSibling.hidden = !isStockOut;
    clearTransactionFeedback();
}

function updateTransactionRemoveButtons() {
    const rows = transactionItems.querySelectorAll(".transaction-item-row");
    rows.forEach(row => {
        row.querySelector(".remove-transaction-item").disabled = rows.length === 1;
    });
}

document.getElementById("add-transaction-item").addEventListener("click", () => {
    const row = transactionItems.firstElementChild.cloneNode(true);
    const item = row.querySelector("select");
    const quantity = row.querySelector("input");
    item.id = "transaction-item-" + nextTransactionItemId;
    quantity.id = "transaction-quantity-" + nextTransactionItemId++;
    row.querySelectorAll("label")[0].htmlFor = item.id;
    row.querySelectorAll("label")[1].htmlFor = quantity.id;
    item.value = "";
    quantity.value = "";
    item.setCustomValidity("");
    transactionItems.appendChild(row);
    updateTransactionRemoveButtons();
    clearTransactionFeedback();
    item.focus();
});

transactionItems.addEventListener("click", event => {
    const button = event.target.closest(".remove-transaction-item");
    if (button && transactionItems.children.length > 1) {
        button.closest(".transaction-item-row").remove();
        updateTransactionRemoveButtons();
        clearTransactionFeedback();
    }
});
transactionTypeSelect.addEventListener("change", updateTransactionForm);
transactionForm.addEventListener("input", clearTransactionFeedback);
transactionForm.addEventListener("change", clearTransactionFeedback);
transactionForm.addEventListener("submit", event => {
    event.preventDefault();
    const seen = new Set();
    let duplicate = null;
    transactionItems.querySelectorAll("select").forEach(field => {
        field.setCustomValidity("");
        if (seen.has(field.value)) {
            field.setCustomValidity("Select each variant once; combine its quantities in one row.");
            duplicate = field;
        }
        seen.add(field.value);
    });
    if (duplicate) {
        transactionFeedback.textContent = "Repeated item: combine its quantities in one row.";
        duplicate.reportValidity();
        return;
    }
    transactionFeedback.textContent = "Demo form checked. Nothing was saved. The backend will verify available stock and save the transaction.";
});
updateTransactionForm();

/* ==============================
   CUSTOM GIVEAWAY FUNCTIONALITY
================================= */

const openGiveawayBtn = document.getElementById("open-custom-giveaway");
const giveawayPanel = document.getElementById("custom-giveaway-panel");
const cancelGiveawayBtn = document.getElementById("cancel-custom-giveaway");
const addGiveawayItemBtn = document.getElementById("add-giveaway-item");
const giveawayItems = document.getElementById("giveaway-items");
const customGiveawayForm = document.getElementById("custom-giveaway-form");

// Make sure all required HTML elements exist
if (
    openGiveawayBtn &&
    giveawayPanel &&
    cancelGiveawayBtn &&
    addGiveawayItemBtn &&
    giveawayItems &&
    customGiveawayForm
) {
    let nextGiveawayItemId = 2;

    // Open the Custom Giveaway form
    openGiveawayBtn.addEventListener("click", function () {
        giveawayPanel.hidden = false;
        openGiveawayBtn.setAttribute("aria-expanded", "true");

        giveawayPanel.scrollIntoView({
            behavior: "smooth",
            block: "start"
        });
    });

    // Update the Remove buttons
    function updateRemoveButtons() {
        const rows = giveawayItems.querySelectorAll(".giveaway-item-row");

        rows.forEach((row) => {
            const button = row.querySelector(".remove-giveaway-item");
            button.disabled = rows.length === 1;
        });
    }

    // Add another merchandise item
    addGiveawayItemBtn.addEventListener("click", function () {
        const firstRow = giveawayItems.querySelector(".giveaway-item-row");
        const newRow = firstRow.cloneNode(true);

        const itemSelect = newRow.querySelector('select[name="item[]"]');
        const quantityInput = newRow.querySelector('input[name="quantity[]"]');
        const labels = newRow.querySelectorAll("label");

        // Assign unique IDs
        itemSelect.id = "giveaway-item-" + nextGiveawayItemId;
        quantityInput.id = "giveaway-quantity-" + nextGiveawayItemId;

        labels[0].htmlFor = itemSelect.id;
        labels[1].htmlFor = quantityInput.id;

        nextGiveawayItemId++;

        // Reset the new item fields
        itemSelect.value = "";
        quantityInput.value = "1";

        // Add the new row
        giveawayItems.appendChild(newRow);

        updateRemoveButtons();
    });

    // Remove a merchandise item
    giveawayItems.addEventListener("click", function (event) {
        if (!event.target.classList.contains("remove-giveaway-item")) {
            return;
        }

        const row = event.target.closest(".giveaway-item-row");

        if (giveawayItems.children.length > 1) {
            row.remove();
        }

        updateRemoveButtons();
    });

    // Cancel and reset the Custom Giveaway form
    cancelGiveawayBtn.addEventListener("click", function () {
        giveawayPanel.hidden = true;
        openGiveawayBtn.setAttribute("aria-expanded", "false");

        // Reset form fields
        customGiveawayForm.reset();

        // Remove additional merchandise rows
        const rows = giveawayItems.querySelectorAll(".giveaway-item-row");

        rows.forEach((row, index) => {
            if (index > 0) {
                row.remove();
            }
        });

        updateRemoveButtons();
    });

    // Prevent form submission during the demonstration
    customGiveawayForm.addEventListener("submit", function (event) {
        event.preventDefault();
    });
}
