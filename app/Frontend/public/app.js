/* ==============================
   SHARED: API calls, staff picker, drop-down data, setup banner
================================= */

const GCR = (() => {
    const STAFF_KEY = "gcr.staffId";
    const state = { staff: [], lookups: null, variants: [], staffId: null };

    async function api(method, url, body) {
        const options = { method, headers: { Accept: "application/json" } };
        if (body !== undefined) {
            options.headers["Content-Type"] = "application/json";
            options.body = JSON.stringify(body);
        }
        let response;
        try {
            response = await fetch(url, options);
        } catch {
            throw new Error("Could not reach the server. Make sure the app is running.");
        }
        const payload = await response.json().catch(() => null);
        if (!response.ok) {
            throw new Error((payload && payload.error) || "Something went wrong. Please try again.");
        }
        return payload;
    }

    function readSavedStaff() {
        try { return Number(localStorage.getItem(STAFF_KEY)) || null; } catch { return null; }
    }

    function saveStaff(id) {
        try {
            if (id) localStorage.setItem(STAFF_KEY, String(id));
            else localStorage.removeItem(STAFF_KEY);
        } catch { /* storage unavailable: selection lasts for this page only */ }
    }

    function emit(name, detail) {
        document.dispatchEvent(new CustomEvent(name, { detail }));
    }

    function option(value, label) {
        const o = document.createElement("option");
        o.value = value;
        o.textContent = label;
        return o;
    }

    // Replace a select's options, keeping its first placeholder option and current value
    function fillSelect(select, items, valueOf, labelOf) {
        const keep = select.value;
        const placeholder = select.options[0] && select.options[0].value === "" ? select.options[0] : null;
        select.replaceChildren();
        if (placeholder) select.appendChild(placeholder);
        items.forEach(item => select.appendChild(option(valueOf(item), labelOf(item))));
        if ([...select.options].some(o => o.value === keep)) select.value = keep;
    }

    function variantLabel(v) {
        const detail = [v.Gender, v.SizeCode].filter(Boolean).join(" / ");
        return detail ? `${v.ItemName} - ${detail}` : v.ItemName;
    }

    // ---------- staff picker ----------
    const picker = document.getElementById("current-staff");

    function currentStaff() {
        return state.staff.find(s => s.UserID === state.staffId && s.IsActive) || null;
    }

    function renderPicker() {
        const active = state.staff.filter(s => s.IsActive);
        picker.replaceChildren(option("", active.length ? "-- Select your name --" : "No staff yet - add on Staff page"));
        active.forEach(s => picker.appendChild(option(String(s.UserID), s.FullName)));
        if (!currentStaff()) state.staffId = null;
        picker.value = state.staffId ? String(state.staffId) : "";
        picker.classList.toggle("needs-choice", !state.staffId);
    }

    picker.addEventListener("change", () => {
        state.staffId = Number(picker.value) || null;
        saveStaff(state.staffId);
        picker.classList.toggle("needs-choice", !state.staffId);
        emit("gcr:staff-changed", currentStaff());
    });

    // Returns the selected staff ID, or shows a message and returns null
    function requireStaff(feedbackEl) {
        const s = currentStaff();
        if (s) return s.UserID;
        if (feedbackEl) feedbackEl.textContent = "Choose your name in \"Working as\" at the top of the page first.";
        picker.focus();
        return null;
    }

    async function loadStaff() {
        state.staff = await api("GET", "/api/staff");
        renderPicker();
        emit("gcr:staff-loaded", state.staff);
        emit("gcr:staff-changed", currentStaff());
    }

    // ---------- drop-down data ----------
    async function loadLookups() {
        state.lookups = await api("GET", "/api/lookups");
        document.querySelectorAll(".lookup-select").forEach(select => {
            const list = state.lookups[select.dataset.lookup] || [];
            fillSelect(select, list, x => String(x.id), x => x.name);
        });
    }

    async function loadVariants() {
        state.variants = await api("GET", "/api/variants");
        document.querySelectorAll(".variant-select").forEach(fillVariantSelect);
        emit("gcr:variants-loaded", state.variants);
    }

    function fillVariantSelect(select) {
        fillSelect(select, state.variants, v => String(v.VariantID),
            v => `${variantLabel(v)} (${v.CurrentQuantity} on hand)`);
    }

    // ---------- setup banner ----------
    const banner = document.getElementById("setup-banner");

    async function refreshSetup() {
        try {
            const s = await api("GET", "/api/setup");
            const steps = [];
            if (s.NeedsStaff) steps.push(["Add your staff list", "#staff"]);
            if (s.NeedsAlertRecipient) steps.push(["Add at least one low-stock alert email", "#alerts"]);
            if (s.NeedsOpeningCounts) steps.push(["Load the opening inventory counts", "#inventory"]);
            banner.replaceChildren();
            if (!steps.length) { banner.hidden = true; return; }
            const strong = document.createElement("strong");
            strong.textContent = "Finish setting up: ";
            banner.appendChild(strong);
            steps.forEach(([label, href], i) => {
                const a = document.createElement("a");
                a.href = href;
                a.textContent = label;
                banner.appendChild(a);
                if (i < steps.length - 1) banner.appendChild(document.createTextNode(" · "));
            });
            banner.hidden = false;
        } catch {
            banner.hidden = true;
        }
    }

    function formatDate(value) {
        if (!value) return "";
        const d = new Date(String(value).replace(" ", "T"));
        return isNaN(d) ? String(value) : d.toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" });
    }

    // Inventory changed: refresh everything that shows quantities
    function inventoryChanged() {
        emit("gcr:inventory-changed");
        loadVariants().catch(() => {});
        refreshSetup();
    }

    state.staffId = readSavedStaff();

    async function init() {
        await Promise.allSettled([loadStaff(), loadLookups(), loadVariants()]);
        refreshSetup();
    }

    return {
        api, fillSelect, fillVariantSelect, variantLabel, currentStaff, requireStaff, formatDate,
        loadStaff, loadVariants, refreshSetup, inventoryChanged, init,
        get variants() { return state.variants; },
        get lookups() { return state.lookups; },
        get staff() { return state.staff; },
        currentStaffId: () => (currentStaff() ? currentStaff().UserID : null)
    };
})();

document.addEventListener("DOMContentLoaded", () => GCR.init());
