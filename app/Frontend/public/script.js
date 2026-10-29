
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

// Fields displayed only for Stock Out
const stockOutFieldIds = [
    "transaction-item-2",
    "transaction-quantity-2",
    "distribution-category",
    "recipient-context",
    "transaction-purpose"
];

// Find the Distribution Information heading and description
const distributionHeading = Array.from(
    document.querySelectorAll("#withdrawal-form h3")
).find((heading) =>
    heading.textContent.trim() === "Distribution Information"
);

const distributionDescription = distributionHeading?.nextElementSibling;

// Show or hide fields depending on transaction type
function updateTransactionForm() {
    if (!transactionTypeSelect) return;

    const isStockOut = transactionTypeSelect.value === "out";

    // Toggle Stock Out fields
    stockOutFieldIds.forEach((id) => {
        const field = document.getElementById(id);
        const group = field?.closest(".form-group");

        if (group) {
            group.style.display = isStockOut ? "" : "none";
        }
    });

    // Toggle Distribution Information heading
    if (distributionHeading) {
        distributionHeading.style.display = isStockOut ? "" : "none";
    }

    // Toggle Distribution Information description
    if (distributionDescription) {
        distributionDescription.style.display = isStockOut ? "" : "none";
    }
}

// Update the form when the transaction type changes
if (transactionTypeSelect) {
    transactionTypeSelect.addEventListener("change", updateTransactionForm);

    // Set initial form visibility
    updateTransactionForm();
}


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
