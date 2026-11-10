/* ==============================
   REPORTS PAGE
================================= */

(() => {
    const card = document.getElementById("report-output-card");
    const output = document.getElementById("report-output");
    const titleEl = document.getElementById("report-output-title");
    const meta = document.getElementById("report-output-meta");
    const start = document.getElementById("report-start");
    const end = document.getElementById("report-end");
    let lastSets = [];
    let lastName = "report";

    // Default range: last 30 days
    const today = new Date();
    const monthAgo = new Date(today.getTime() - 30 * 86400000);
    const iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    end.value = iso(today);
    start.value = iso(monthAgo);

    // Column names come from the procedures in PascalCase; make them readable
    function heading(key) {
        return key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2");
    }

    function format(key, value) {
        if (value === null || value === undefined || value === "") return "—";
        if (typeof value === "object") return JSON.stringify(value);
        if (/Value|Cost/.test(key) && typeof value === "number") {
            return "$" + value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        }
        if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(value)) return GCR.formatDate(value);
        return String(value);
    }

    function renderTable(rows) {
        const wrap = document.createElement("div");
        wrap.className = "report-table";
        if (!rows.length) {
            const p = document.createElement("p");
            p.className = "report-empty";
            p.textContent = "No rows for this report.";
            wrap.appendChild(p);
            return wrap;
        }
        const keys = Object.keys(rows[0]);
        const table = document.createElement("table");
        const thead = document.createElement("thead");
        const htr = document.createElement("tr");
        keys.forEach(k => {
            const th = document.createElement("th");
            th.scope = "col";
            th.textContent = heading(k);
            htr.appendChild(th);
        });
        thead.appendChild(htr);
        const tbody = document.createElement("tbody");
        rows.forEach(r => {
            const tr = document.createElement("tr");
            keys.forEach(k => {
                const td = document.createElement("td");
                td.textContent = format(k, r[k]);
                tr.appendChild(td);
            });
            tbody.appendChild(tr);
        });
        table.append(thead, tbody);
        wrap.appendChild(table);
        return wrap;
    }

    async function run(button) {
        const key = button.dataset.report;
        const name = button.closest(".report-card").querySelector("h3").textContent;
        const params = new URLSearchParams();
        if (button.dataset.dated) {
            if (start.value) params.set("start", start.value);
            if (end.value) params.set("end", end.value);
        }
        card.hidden = false;
        titleEl.textContent = name;
        meta.textContent = "Running…";
        output.replaceChildren();
        try {
            const sets = await GCR.api("GET", `/api/reports/${key}?${params}`);
            lastSets = sets;
            lastName = key;
            meta.textContent = (button.dataset.dated ? `${start.value || "start"} to ${end.value || "today"} · ` : "") +
                `Run ${new Date().toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" })}`;
            sets.forEach((rows, i) => {
                if (sets.length > 1) {
                    const h3 = document.createElement("h3");
                    h3.className = "report-section-title";
                    h3.textContent = `Part ${i + 1}`;
                    output.appendChild(h3);
                }
                output.appendChild(renderTable(rows));
            });
        } catch (err) {
            meta.textContent = err.message;
        }
        card.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    function csvValue(v) {
        if (v === null || v === undefined) return "";
        const s = typeof v === "object" ? JSON.stringify(v) : String(v);
        return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    }

    document.getElementById("report-export").addEventListener("click", () => {
        const parts = lastSets.filter(rows => rows.length).map(rows => {
            const keys = Object.keys(rows[0]);
            return [keys.join(","), ...rows.map(r => keys.map(k => csvValue(r[k])).join(","))].join("\n");
        });
        const blob = new Blob([parts.join("\n\n")], { type: "text/csv" });
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = `gcr-${lastName}-${iso(new Date())}.csv`;
        a.click();
        URL.revokeObjectURL(a.href);
    });

    document.querySelectorAll(".run-report").forEach(b => b.addEventListener("click", () => run(b)));
})();
