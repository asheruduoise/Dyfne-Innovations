/* Shared recipient editor. GET/PUT routes are a contract for the backend team.
   No local storage, email transport, or successful-save simulation is used. */
(() => {
    const form = document.getElementById('alert-recipients-form');
    const rows = document.getElementById('alert-recipient-rows');
    const add = document.getElementById('add-alert-recipient');
    const save = document.getElementById('save-alert-recipients');
    const feedback = document.getElementById('alert-recipients-feedback');
    const connection = document.getElementById('alerts-connection');
    let nextId = 1;
    let revision = null;
    let connected = false;
    let busy = false;
    let editing = false;
    const endpoint = '/api/alert-recipients';

    function update() {
        const count = rows.children.length;
        document.getElementById('recipient-count').textContent = count + ' / 3';
        document.getElementById('recipients-empty').hidden = count > 0;
        add.disabled = busy || count >= 3;
        save.disabled = busy || !connected;
        const emails = [...rows.querySelectorAll('input[type=email]')].map(e => e.value.trim()).filter(Boolean);
        document.getElementById('alert-preview-to').textContent = emails.join('; ') || 'Your saved recipients';
    }

    function addRow(recipient = {}) {
        if (rows.children.length >= 3) return;
        const row = document.createElement('div');
        row.className = 'alert-recipient-row';
        const id = nextId++;
        for (const field of [{key: 'name', label: 'Name (optional)', type: 'text', max: 100}, {key: 'email', label: 'Email address', type: 'email', max: 254}]) {
            const group = document.createElement('div');
            group.className = 'form-group';
            const label = document.createElement('label');
            const input = document.createElement('input');
            input.id = 'alert-' + field.key + '-' + id;
            label.htmlFor = input.id;
            label.textContent = field.label;
            input.name = field.key;
            input.type = field.type;
            input.maxLength = field.max;
            input.required = field.key === 'email';
            input.autocomplete = field.key;
            input.placeholder = field.key === 'email' ? 'colleague@example.com' : 'Employee name';
            input.value = recipient[field.key] || '';
            group.append(label, input);
            row.append(group);
        }
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'btn-secondary';
        remove.textContent = 'Remove';
        remove.setAttribute('aria-label', 'Remove recipient ' + id);
        remove.addEventListener('click', () => {
            editing = true;
            row.remove();
            clearFeedback();
            update();
            add.focus();
        });
        row.append(remove);
        rows.append(row);
        update();
        return row;
    }

    function clearFeedback() {
        feedback.textContent = '';
        rows.querySelectorAll('input').forEach(input => input.setCustomValidity(''));
    }

    function validate() {
        clearFeedback();
        const recipients = [...rows.children].map(row => ({name: row.querySelector('[name=name]').value.trim(), email: row.querySelector('[name=email]').value.trim()}));
        // Match the current database: saving requires 1–3 recipients.
        if (!recipients.length) {
            feedback.textContent = 'Add at least one recipient. To replace the last employee, add the new recipient before removing the old one.';
            return null;
        }
        const seen = new Set();
        for (const row of rows.children) {
            const email = row.querySelector('[name=email]');
            email.value = email.value.trim();
            const key = email.value.toLowerCase();
            if (seen.has(key)) email.setCustomValidity('This email is already on the list. Enter each address only once.');
            seen.add(key);
        }
        if (!form.reportValidity()) return null;
        return recipients;
    }

    function validPayload(payload) {
        return payload && typeof payload.revision === 'string' && payload.revision.length > 0 &&
            Array.isArray(payload.recipients) && payload.recipients.length <= 3 &&
            payload.recipients.every(r => r && typeof r.email === 'string' && (!r.name || typeof r.name === 'string'));
    }

    function render(payload) {
        rows.replaceChildren();
        payload.recipients.forEach(addRow);
        revision = payload.revision;
        update();
    }

    add.addEventListener('click', () => {
        editing = true;
        clearFeedback();
        const row = addRow();
        row?.querySelector('[name=email]').focus();
    });
    form.addEventListener('input', () => { editing = true; clearFeedback(); update(); });
    document.getElementById('check-alert-recipients').addEventListener('click', () => {
        if (validate()) feedback.textContent = 'The list looks valid. This check did not save settings or send email.';
    });

    form.addEventListener('submit', async event => {
        event.preventDefault();
        const recipients = validate();
        if (!recipients) return;
        if (!connected) {
            feedback.textContent = 'Saving is unavailable until alert settings are connected to the backend. Nothing was saved.';
            return;
        }
        busy = true;
        form.querySelectorAll('input, button').forEach(e => e.disabled = true);
        try {
            const response = await fetch(endpoint, {
                method: 'PUT', credentials: 'same-origin', headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
                body: JSON.stringify({recipients, revision}), signal: AbortSignal.timeout(10000)
            });
            if (response.status === 409) throw new Error('Someone else updated the list. Reload the page and review their changes before saving again.');
            if (response.status === 401 || response.status === 403) throw new Error('Sign in with permission to manage alert recipients. Nothing was saved.');
            if (!response.ok) throw new Error('Could not save the list. Your draft is still here. Please try again.');
            const payload = await response.json();
            if (!validPayload(payload)) throw new Error('The server response could not be confirmed. Reload to check the saved list.');
            render(payload);
            feedback.textContent = 'Recipient list saved. Email delivery depends on the configured email service.';
        } catch (error) {
            feedback.textContent = error.name === 'TimeoutError' ? 'The request timed out. Reload to check whether the list was saved before retrying.' : error.message;
        } finally {
            busy = false;
            form.querySelectorAll('input, button').forEach(e => e.disabled = false);
            update();
        }
    });

    async function load() {
        try {
            const response = await fetch(endpoint, {credentials: 'same-origin', headers: {'Accept': 'application/json'}, signal: AbortSignal.timeout(8000)});
            if (!response.ok) throw new Error('Unavailable');
            const payload = await response.json();
            if (!validPayload(payload)) throw new Error('Invalid settings response');
            if (editing) {
                connection.textContent = 'Settings became available after you started editing. Reload to load the saved list before making changes.';
                return;
            }
            connected = true;
            render(payload);
            connection.textContent = 'Recipient settings connected. Changes take effect after you save.';
        } catch {
            connection.textContent = 'Preview mode: saved recipients could not be loaded. You can edit and check a draft, but saving and email delivery are not connected here.';
            if (!editing && !rows.children.length) addRow();
        }
        update();
    }
    load();
})();
