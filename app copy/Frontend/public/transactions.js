/* ==============================
   STOCK TRANSACTIONS PAGE
================================= */

(() => {
    const form = document.getElementById("withdrawal-form");
    const typeSelect = document.getElementById("transaction-type");
    const items = document.getElementById("transaction-items");
    const feedback = document.getElementById("transaction-feedback");
    const recordedBy = document.getElementById("transaction-user");
    const recentBody = document.getElementById("recent-transactions-body");
    const recentFeedback = document.getElementById("recent-transactions-feedback");
    const distributionHeading = Array.from(form.querySelectorAll("h3"))
        .find(h => h.textContent.trim() === "Distribution Information");
    const outOnly = ["distribution-category", "recipient-context", "transaction-event-purpose",
        "transaction-purpose", "transaction-recipient-name"];

    function updateForm() {
        const isOut = typeSelect.value === "out";
        const isIn = typeSelect.value === "in";
        const reason = document.getElementById("stock-in-reason");
        document.getElementById("stock-in-reason-group").hidden = !isIn;
        reason.disabled = !isIn;
        reason.required = isIn;
        for (const id of outOnly) {
            const field = document.getElementById(id);
            field.closest(".form-group").hidden = !isOut;
            field.disabled = !isOut;
            field.required = isOut && (id === "distribution-category" || id === "recipient-context");
        }
        distributionHeading.hidden = !isOut;
        distributionHeading.nextElementSibling.hidden = !isOut;
        feedback.textContent = "";
    }

    function showRecordedBy(staff) {
        recordedBy.value = staff ? staff.FullName : "Select your name at the top of the page";
    }

    document.getElementById("add-transaction-item").addEventListener("click", () => {
        addItemRow(items, "transaction-item-row", "transaction", "").querySelector("select").focus();
        feedback.textContent = "";
    });

    items.addEventListener("click", event => {
        const button = event.target.closest(".remove-transaction-item");
        if (button && items.children.length > 1) {
            button.closest(".transaction-item-row").remove();
            updateRemoveButtons(items, "transaction-item-row");
            feedback.textContent = "";
        }
    });

    typeSelect.addEventListener("change", updateForm);
    form.addEventListener("input", () => { feedback.textContent = ""; });

    form.addEventListener("submit", async event => {
        event.preventDefault();
        const userId = GCR.requireStaff(feedback);
        if (!userId) return;
        const lines = collectItemRows(items, feedback);
        if (!lines) return;
        const isOut = typeSelect.value === "out";
        const value = id => document.getElementById(id).value || null;
        const body = {
            userId,
            type: isOut ? "OUT" : "IN",
            lines,
            stockInReason: isOut ? null : value("stock-in-reason"),
            distributionCategoryId: isOut ? value("distribution-category") : null,
            recipientContextId: isOut ? value("recipient-context") : null,
            eventPurposeId: isOut ? value("transaction-event-purpose") : null,
            eventDetails: isOut ? value("transaction-purpose") : null,
            recipientName: isOut ? value("transaction-recipient-name") : null,
            notes: value("transaction-notes")
        };
        const submit = form.querySelector("button[type=submit]");
        submit.disabled = true;
        feedback.textContent = "Saving…";
        try {
            const result = await GCR.api("POST", "/api/transactions", body);
            const low = result.lines.filter(l => l.StockStatus !== "OK").map(l => l.ItemName);
            const message = `Saved transaction #${result.transactionId} (${result.lines.length} item${result.lines.length === 1 ? "" : "s"}).` +
                (low.length ? ` Now at or below setpoint: ${[...new Set(low)].join(", ")}.` : "");
            form.reset();
            resetItemRows(items, "transaction-item-row", "");
            updateForm();
            feedback.textContent = message;
            showRecordedBy(GCR.currentStaff());
            GCR.inventoryChanged();
            loadRecent();
        } catch (err) {
            feedback.textContent = err.message;
        } finally {
            submit.disabled = false;
        }
    });

    // ---------- recent transactions ----------
    function cell(text) {
        const td = document.createElement("td");
        td.textContent = text === null || text === undefined || text === "" ? "—" : String(text);
        return td;
    }

    function details(t) {
        if (t.TransactionTypeLabel === "Stock In") return t.StockInReason || "";
        return [t.DistributionCategory, t.RecipientContext, t.EventDetails, t.TemplateUsed && `Template: ${t.TemplateUsed}`]
            .filter(Boolean).join(" · ");
    }

    async function loadRecent() {
        try {
            const rows = await GCR.api("GET", "/api/transactions?limit=10");
            recentBody.replaceChildren();
            if (!rows.length) {
                recentBody.innerHTML = '<tr><td colspan="7">No transactions yet.</td></tr>';
                return;
            }
            rows.forEach(t => {
                const tr = document.createElement("tr");
                if (t.IsDeleted) tr.classList.add("deleted-row");
                const type = t.IsDeleted ? `${t.TransactionTypeLabel} (deleted)` : t.TransactionTypeLabel;
                tr.append(cell(t.TransactionID), cell(GCR.formatDate(t.TransactionDate)), cell(type),
                    cell(t.Items), cell(t.IsDeleted ? `Deleted by ${t.DeletedBy}: ${t.DeleteReason}` : details(t)),
                    cell(t.SubmittedBy));
                const actions = document.createElement("td");
                if (!t.IsDeleted) {
                    const del = document.createElement("button");
                    del.type = "button";
                    del.className = "btn-secondary btn-small";
                    del.textContent = "Delete";
                    del.setAttribute("aria-label", `Delete transaction ${t.TransactionID}`);
                    del.addEventListener("click", () => deleteTransaction(t));
                    actions.appendChild(del);
                }
                tr.appendChild(actions);
                recentBody.appendChild(tr);
            });
        } catch (err) {
            recentBody.innerHTML = '<tr><td colspan="7">Could not load transactions.</td></tr>';
        }
    }

    async function deleteTransaction(t) {
        recentFeedback.textContent = "";
        const userId = GCR.requireStaff(recentFeedback);
        if (!userId) return;
        const reason = window.prompt(`Delete transaction #${t.TransactionID} (${t.Items})?\nIts inventory will be put back. Enter the reason:`);
        if (reason === null) return;
        if (!reason.trim()) {
            recentFeedback.textContent = "A reason is required to delete a transaction.";
            return;
        }
        try {
            await GCR.api("POST", `/api/transactions/${t.TransactionID}/delete`, { userId, reason });
            recentFeedback.textContent = `Transaction #${t.TransactionID} deleted and its inventory reversed.`;
            GCR.inventoryChanged();
            loadRecent();
        } catch (err) {
            recentFeedback.textContent = err.message;
        }
    }

    document.addEventListener("gcr:staff-changed", e => showRecordedBy(e.detail));
    document.addEventListener("gcr:inventory-changed", loadRecent);
    updateForm();
    loadRecent();
})();
