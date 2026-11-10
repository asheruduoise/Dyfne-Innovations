/* ==============================
   STAFF PAGE
================================= */

(() => {
    const form = document.getElementById("staff-form");
    const idField = document.getElementById("staff-id");
    const first = document.getElementById("staff-first");
    const last = document.getElementById("staff-last");
    const email = document.getElementById("staff-email");
    const type = document.getElementById("staff-type");
    const submit = document.getElementById("staff-submit");
    const cancel = document.getElementById("staff-cancel");
    const formTitle = document.getElementById("staff-form-title");
    const feedback = document.getElementById("staff-feedback");
    const body = document.getElementById("staff-table-body");

    function resetForm() {
        form.reset();
        idField.value = "";
        formTitle.textContent = "Add a staff member";
        submit.textContent = "Add staff member";
        cancel.hidden = true;
    }

    function edit(s) {
        idField.value = s.UserID;
        first.value = s.FirstName;
        last.value = s.LastName;
        email.value = s.Email;
        type.value = s.UserType;
        formTitle.textContent = `Edit ${s.FullName}`;
        submit.textContent = "Save changes";
        cancel.hidden = false;
        feedback.textContent = "";
        first.focus();
    }

    function button(label, onClick, aria) {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "btn-secondary btn-small";
        b.textContent = label;
        b.setAttribute("aria-label", aria);
        b.addEventListener("click", onClick);
        return b;
    }

    function render(staff) {
        body.replaceChildren();
        if (!staff.length) {
            body.innerHTML = '<tr><td colspan="5">No staff yet. Add the first person above.</td></tr>';
            return;
        }
        staff.forEach(s => {
            const tr = document.createElement("tr");
            if (!s.IsActive) tr.classList.add("deleted-row");
            const cells = [s.FullName, s.Email, s.UserType];
            cells.forEach(text => {
                const td = document.createElement("td");
                td.textContent = text;
                tr.appendChild(td);
            });
            const status = document.createElement("td");
            const span = document.createElement("span");
            span.className = "status " + (s.IsActive ? "in-stock" : "pending");
            span.textContent = s.IsActive ? "Active" : "Inactive";
            status.appendChild(span);
            tr.appendChild(status);
            const actions = document.createElement("td");
            const group = document.createElement("div");
            group.className = "row-actions";
            group.appendChild(button("Edit", () => edit(s), `Edit ${s.FullName}`));
            group.appendChild(button(s.IsActive ? "Deactivate" : "Reactivate",
                () => setActive(s, !s.IsActive), `${s.IsActive ? "Deactivate" : "Reactivate"} ${s.FullName}`));
            actions.appendChild(group);
            tr.appendChild(actions);
            body.appendChild(tr);
        });
    }

    async function setActive(s, active) {
        feedback.textContent = "";
        if (!active && !window.confirm(`Deactivate ${s.FullName}? They will no longer appear in "Working as". Their past transactions keep their name.`)) return;
        try {
            await GCR.api("POST", `/api/staff/${s.UserID}/active`, { active, actingUserId: GCR.currentStaffId() });
            feedback.textContent = `${s.FullName} ${active ? "reactivated" : "deactivated"}.`;
            await GCR.loadStaff();
            GCR.refreshSetup();
        } catch (err) {
            feedback.textContent = err.message;
        }
    }

    form.addEventListener("submit", async event => {
        event.preventDefault();
        feedback.textContent = "";
        const payload = {
            firstName: first.value, lastName: last.value, email: email.value, userType: type.value,
            actingUserId: GCR.currentStaffId()
        };
        const editing = idField.value;
        submit.disabled = true;
        try {
            if (editing) {
                await GCR.api("PUT", `/api/staff/${editing}`, payload);
                feedback.textContent = `${first.value} ${last.value} updated.`;
            } else {
                await GCR.api("POST", "/api/staff", payload);
                feedback.textContent = `${first.value} ${last.value} added. They can now choose their name in "Working as".`;
            }
            resetForm();
            await GCR.loadStaff();
            GCR.refreshSetup();
        } catch (err) {
            feedback.textContent = err.message;
        } finally {
            submit.disabled = false;
        }
    });

    cancel.addEventListener("click", () => { resetForm(); feedback.textContent = ""; });
    document.addEventListener("gcr:staff-loaded", e => render(e.detail));
})();
