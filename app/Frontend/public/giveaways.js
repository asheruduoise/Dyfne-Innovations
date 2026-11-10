/* ==============================
   GIVEAWAY COMBINATIONS PAGE
================================= */

(() => {
    const cards = document.getElementById("combination-cards");
    const customCard = cards.querySelector(".bundle-card");
    const openButton = document.getElementById("open-custom-giveaway");
    const panel = document.getElementById("custom-giveaway-panel");
    const form = document.getElementById("custom-giveaway-form");
    const items = document.getElementById("giveaway-items");
    const feedback = document.getElementById("giveaway-feedback");
    const comboIdField = document.getElementById("giveaway-combination-id");
    const title = document.getElementById("giveaway-panel-title");
    const intro = document.getElementById("giveaway-panel-intro");
    let combos = [];

    function openPanel(combo) {
        resetForm();
        if (combo) {
            title.textContent = combo.name;
            intro.textContent = "Starting from this combination. Add, remove or change items before submitting.";
            comboIdField.value = combo.combinationId;
            combo.lines.forEach((line, i) => {
                const row = i === 0 ? items.firstElementChild : addItemRow(items, "giveaway-item-row", "giveaway", "1");
                row.querySelector("select").value = String(line.variantId);
                row.querySelector("input").value = line.quantity;
            });
            if (combo.defaultDistributionCategoryId) {
                document.getElementById("giveaway-category").value = String(combo.defaultDistributionCategoryId);
            }
        }
        panel.hidden = false;
        openButton.setAttribute("aria-expanded", "true");
        panel.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    function resetForm() {
        form.reset();
        resetItemRows(items, "giveaway-item-row", "1");
        comboIdField.value = "";
        title.textContent = "Create Custom Giveaway";
        intro.textContent = "Select items and quantities, then submit to record the giveaway as one Stock Out.";
        feedback.textContent = "";
    }

    function closePanel() {
        resetForm();
        panel.hidden = true;
        openButton.setAttribute("aria-expanded", "false");
    }

    function renderCombos() {
        cards.querySelectorAll(".combo-card").forEach(c => c.remove());
        combos.forEach(combo => {
            const card = document.createElement("div");
            card.className = "bundle-card combo-card";
            const h3 = document.createElement("h3");
            h3.textContent = combo.name;
            const desc = document.createElement("p");
            desc.className = "bundle-description";
            desc.textContent = combo.description || "Saved combination. Items and quantities can be customized.";
            const h4 = document.createElement("h4");
            h4.textContent = "Suggested Items";
            const ul = document.createElement("ul");
            ul.className = "bundle-items";
            combo.lines.forEach(line => {
                const li = document.createElement("li");
                const name = document.createElement("span");
                name.textContent = `${line.label} (${line.available} on hand)`;
                const qty = document.createElement("strong");
                qty.textContent = line.quantity;
                li.append(name, qty);
                ul.appendChild(li);
            });
            const footer = document.createElement("div");
            footer.className = "bundle-footer";
            const f1 = document.createElement("span");
            f1.textContent = "Default category";
            const f2 = document.createElement("strong");
            f2.textContent = combo.defaultDistributionCategory || "None";
            footer.append(f1, f2);
            const use = document.createElement("button");
            use.type = "button";
            use.className = "btn-primary";
            use.textContent = "Use Combination";
            use.addEventListener("click", () => openPanel(combo));
            card.append(h3, desc, h4, ul, footer, use);
            cards.insertBefore(card, customCard);
        });
    }

    async function loadCombos() {
        try {
            combos = await GCR.api("GET", "/api/combinations");
            renderCombos();
        } catch { /* custom giveaway still works */ }
    }

    openButton.addEventListener("click", () => openPanel(null));
    document.getElementById("cancel-custom-giveaway").addEventListener("click", closePanel);
    document.getElementById("add-giveaway-item").addEventListener("click", () => {
        addItemRow(items, "giveaway-item-row", "giveaway", "1").querySelector("select").focus();
    });
    items.addEventListener("click", event => {
        if (!event.target.classList.contains("remove-giveaway-item")) return;
        if (items.children.length > 1) event.target.closest(".giveaway-item-row").remove();
        updateRemoveButtons(items, "giveaway-item-row");
    });
    form.addEventListener("input", () => { feedback.textContent = ""; });

    form.addEventListener("submit", async event => {
        event.preventDefault();
        const userId = GCR.requireStaff(feedback);
        if (!userId) return;
        const lines = collectItemRows(items, feedback);
        if (!lines) return;
        const value = id => document.getElementById(id).value || null;
        const submit = form.querySelector("button[type=submit]");
        submit.disabled = true;
        feedback.textContent = "Saving…";
        try {
            const result = await GCR.api("POST", "/api/transactions", {
                userId,
                type: "OUT",
                lines,
                distributionCategoryId: value("giveaway-category"),
                recipientContextId: value("giveaway-recipient"),
                eventPurposeId: value("giveaway-event-purpose"),
                eventDetails: value("giveaway-purpose"),
                recipientName: value("giveaway-recipient-name"),
                combinationId: value("giveaway-combination-id"),
                notes: value("giveaway-notes")
            });
            const units = lines.reduce((sum, l) => sum + l.quantity, 0);
            resetForm();
            feedback.textContent = `Giveaway saved as transaction #${result.transactionId} (${units} units).`;
            GCR.inventoryChanged();
            loadCombos();
        } catch (err) {
            feedback.textContent = err.message;
        } finally {
            submit.disabled = false;
        }
    });

    document.getElementById("save-combination").addEventListener("click", async () => {
        const userId = GCR.requireStaff(feedback);
        if (!userId) return;
        const lines = collectItemRows(items, feedback);
        if (!lines) return;
        if (lines.some(l => !l.variantId || !(l.quantity > 0))) {
            feedback.textContent = "Choose an item and a quantity on every row before saving the combination.";
            return;
        }
        const current = combos.find(c => String(c.combinationId) === comboIdField.value);
        const name = window.prompt("Name for this combination (an existing name will be updated):", current ? current.name : "");
        if (name === null) return;
        if (!name.trim()) {
            feedback.textContent = "Enter a name for the combination.";
            return;
        }
        try {
            const result = await GCR.api("POST", "/api/combinations", {
                name, userId, lines,
                description: current && current.name === name.trim() ? current.description : null,
                defaultDistributionCategoryId: document.getElementById("giveaway-category").value || null
            });
            comboIdField.value = result.combinationId;
            title.textContent = name.trim();
            feedback.textContent = `Combination "${name.trim()}" saved.`;
            loadCombos();
        } catch (err) {
            feedback.textContent = err.message;
        }
    });

    document.addEventListener("gcr:inventory-changed", loadCombos);
    loadCombos();
})();
