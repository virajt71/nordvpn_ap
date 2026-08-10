// App state
let stacks = [];
let interfaces = [];
let locations = [];
let activeLogStackId = null;
let logsInterval = null;
let activeLogTab = 'gluetun';
let lastAutoProfileId = '';
let lastAutoSsid = '';

// DOM Elements
const views = {
    dashboard: document.getElementById('view-dashboard'),
    credentials: document.getElementById('view-credentials'),
    interfaces: document.getElementById('view-interfaces')
};

const navItems = {
    dashboard: document.getElementById('btn-nav-dashboard'),
    credentials: document.getElementById('btn-nav-credentials'),
    interfaces: document.getElementById('btn-nav-interfaces')
};

// Notifications State
let notifications = [];

function showToast(message, type = 'info') {
    const notification = {
        id: Date.now(),
        message,
        type,
        time: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }),
        unread: true
    };
    notifications.unshift(notification);
    renderNotifications();
}

function renderNotifications() {
    const badge = document.getElementById('notification-badge');
    const list = document.getElementById('notification-list');

    // Count unread
    const unreadCount = notifications.filter(n => n.unread).length;
    if (unreadCount > 0) {
        badge.textContent = unreadCount;
        badge.style.display = 'block';
    } else {
        badge.style.display = 'none';
    }

    if (notifications.length === 0) {
        list.innerHTML = '<div class="notification-empty">No new activity</div>';
        return;
    }

    list.innerHTML = notifications.map(n => {
        let iconClass = 'fa-circle-info';
        if (n.type === 'success') iconClass = 'fa-circle-check';
        if (n.type === 'error') iconClass = 'fa-triangle-exclamation';

        return `
            <div class="notification-item ${n.type} ${n.unread ? 'unread' : ''}" data-id="${n.id}">
                <i class="fa-solid ${iconClass}"></i>
                <div class="notification-item-text">
                    ${n.message}
                    <span class="notification-item-time">${n.time}</span>
                </div>
            </div>
        `;
    }).join('');

    // Attach click listener to mark single notification as read on click
    list.querySelectorAll('.notification-item').forEach(item => {
        item.addEventListener('click', (e) => {
            const id = parseInt(item.getAttribute('data-id'));
            const notif = notifications.find(n => n.id === id);
            if (notif) {
                notif.unread = false;
                renderNotifications();
            }
        });
    });
}

// RF-Kill Modal Alert Handlers
function showRfKillModal(detailsText) {
    const modal = document.getElementById('modal-rfkill');
    if (!modal) return;
    const detailsElem = document.getElementById('rfkill-error-details');
    if (detailsElem && detailsText) {
        detailsElem.textContent = detailsText;
    }
    modal.classList.add('open');
    showToast('RF-kill wireless block detected on WiFi interface!', 'error');
}

function checkRfKillError(text) {
    if (typeof text === 'string' && (text.includes('RF-kill') || text.includes('rfkill') || text.includes('RF-Kill'))) {
        showRfKillModal(text);
        return true;
    }
    return false;
}

// Fetch wrapper with authentication
async function apiRequest(endpoint, options = {}) {
    const { silentError, ...fetchOptions } = options;
    const headers = {
        'Content-Type': 'application/json',
        ...fetchOptions.headers
    };

    const config = {
        ...fetchOptions,
        headers
    };

    try {
        const response = await fetch(endpoint, config);

        if (!response.ok) {
            const errData = await response.json().catch(() => ({}));
            const errMsg = errData.error || `HTTP error! Status: ${response.status}`;
            checkRfKillError(errMsg);
            throw new Error(errMsg);
        }

        return await response.json();
    } catch (error) {
        checkRfKillError(error.message);
        // ponytail: Suppress toast error notifications on silentError (background polling / health checks)
        if (!silentError) {
            showToast(error.message, 'error');
        }
        console.error('API Request Error:', error);
        throw error;
    }
}

// View switcher
function switchView(viewName) {
    Object.keys(views).forEach(key => {
        if (key === viewName) {
            views[key].classList.add('active');
            navItems[key].classList.add('active');
        } else {
            views[key].classList.remove('active');
            navItems[key].classList.remove('active');
        }
    });

    // Handle title mapping
    const titles = {
        dashboard: { title: 'Access Point Dashboard', subtitle: 'Monitor and control your VPN network gateways' },
        credentials: { title: 'Credentials Configuration', subtitle: 'Manage VPN usernames, keys, and API tokens' },
        interfaces: { title: 'System WiFi Hardware', subtitle: 'Inspect wireless controllers and connection parameters' }
    };

    document.getElementById('page-title').innerText = titles[viewName].title;
    document.getElementById('page-subtitle').innerText = titles[viewName].subtitle;

    // Load data based on view
    if (viewName === 'dashboard') {
        loadDashboard();
    } else if (viewName === 'credentials') {
        loadCredentialsForm();
    } else if (viewName === 'interfaces') {
        loadInterfacesTable();
    }
}

// Setup navigation listeners
navItems.dashboard.addEventListener('click', () => switchView('dashboard'));
navItems.credentials.addEventListener('click', () => switchView('credentials'));
navItems.interfaces.addEventListener('click', () => switchView('interfaces'));

// ─── Health Checks ───────────────────────────────────────────────────────────
async function checkSystemHealth() {
    try {
        const res = await apiRequest('/api/health', { silentError: true });
        if (res && res.status === 'healthy') {
            const apiDot = document.getElementById('api-status-dot');
            apiDot.className = 'pulse-dot green';
            document.getElementById('api-status-text').innerText = 'Online';

            // Toggle path configuration warning banner
            const warningBanner = document.getElementById('env-warning-banner');
            if (warningBanner) {
                if (res.host_project_dir_defaulted) {
                    warningBanner.style.display = 'flex';
                } else {
                    warningBanner.style.display = 'none';
                }
            }

            if (typeof res.total_stacks === 'number') {
                const statActive = document.getElementById('stat-active-stacks');
                if (statActive) {
                    statActive.innerText = `${res.active_stacks} / ${res.total_stacks}`;
                }
            }
        }
    } catch {
        const apiDot = document.getElementById('api-status-dot');
        apiDot.className = 'pulse-dot red';
        document.getElementById('api-status-text').innerText = 'Offline';
    }
}

function updateTelemetryStats() {
    const total = stacks.length;
    const active = stacks.filter(s => s.status === 'running').length;
    const vpnConnected = stacks.filter(s => s.vpn_ip).length;

    const statActive = document.getElementById('stat-active-stacks');
    if (statActive) statActive.innerText = `${active} / ${total}`;

    const statVpn = document.getElementById('stat-vpn-tunnels');
    if (statVpn) statVpn.innerText = total > 0 ? `${vpnConnected} Connected` : '0 Connected';

    const statHw = document.getElementById('stat-hw-ifaces');
    if (statHw) {
        statHw.innerText = interfaces.length > 0 ? `${interfaces.length} Discovered` : 'Scanning...';
    }
}

// ─── Live stack status over WebSocket ───────────────────────────────────────
let stackSocket = null;
let stackSocketRetry = null;

function connectStackSocket() {
    if (stackSocketRetry) clearTimeout(stackSocketRetry);
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${proto}//${location.host}/ws/stacks`);
    stackSocket = ws;

    ws.onmessage = (ev) => {
        try {
            const data = JSON.parse(ev.data);
            if (!Array.isArray(data)) return;
            stacks = data;
            updateTelemetryStats();
            // Repaint only when dashboard is active to avoid clobbering other views.
            if (document.getElementById('view-dashboard').classList.contains('active')) {
                renderStacks();
            }
        } catch { }
    };
    ws.onclose = () => {
        stackSocketRetry = setTimeout(connectStackSocket, 3000); // ponytail: fixed 3s backoff, exponential if flapping later
    };
    ws.onerror = () => ws.close();
}

// ─── Loaders ─────────────────────────────────────────────────────────────────

async function loadDashboard() {
    const container = document.getElementById('stacks-container');
    container.innerHTML = `
        <div class="loading-state">
            <i class="fa-solid fa-spinner fa-spin loading-spinner"></i>
            <p>Fetching active profiles...</p>
        </div>
    `;

    try {
        if (interfaces.length === 0) {
            interfaces = await apiRequest('/api/wifi/interfaces', { silentError: true }).catch(() => []);
        }
        stacks = await apiRequest('/api/stacks', { silentError: true }) || [];
        updateTelemetryStats();
        renderStacks();
        connectStackSocket();
    } catch {
        container.innerHTML = `
            <div class="loading-state">
                <i class="fa-solid fa-triangle-exclamation" style="font-size: 32px; color: var(--color-danger);"></i>
                <p>Failed to load stacks. Check orchestrator logs.</p>
            </div>
        `;
    }
}

function renderStacks() {
    updateTelemetryStats();
    const container = document.getElementById('stacks-container');
    if (stacks.length === 0) {
        container.innerHTML = `
            <div class="loading-state">
                <i class="fa-solid fa-wifi-slash" style="font-size: 32px;"></i>
                <p>No WiFi Access Points configured yet. Click "Create Access Point" to get started.</p>
            </div>
        `;
        return;
    }

    container.innerHTML = stacks.map(s => {
        const badgeClass = s.status === 'running' ? 'running' : s.status === 'starting' ? 'starting' : 'stopped';
        const vpnIpSection = s.vpn_ip
            ? `<div class="vpn-box">
                <span class="vpn-box-label"><i class="fa-solid fa-circle-check"></i> VPN Tunneled</span>
                <span class="vpn-box-ip">${s.vpn_ip}</span>
               </div>`
            : `<div class="vpn-box" style="background: rgba(255,23,68,0.05);">
                <span class="vpn-box-label" style="color: var(--color-danger);"><i class="fa-solid fa-circle-xmark"></i> VPN Disconnected</span>
                <span class="vpn-box-ip" style="color: var(--color-danger);">--</span>
               </div>`;

        const auto12hBadge = s.auto_reconnect_12h
            ? `<div class="card-12h-badge"><i class="fa-solid fa-clock-rotate-left"></i> 12h Auto-Reconnect Enabled</div>`
            : '';

        return `
            <div class="glass-panel stack-card ${badgeClass}">
                <div class="stack-header">
                    <div class="stack-info-title">
                        <h3>${s.ssid}</h3>
                        <span class="stack-id-tag">id: ${s.id}</span>
                    </div>
                    <span class="badge ${badgeClass}">${s.status.toUpperCase()}</span>
                </div>
                <div class="stack-details">
                    <div class="detail-item">
                        <span class="label">WiFi Interface</span>
                        <span class="value">${s.ap_iface}</span>
                    </div>
                    <div class="detail-item">
                        <span class="label">Subnet</span>
                        <span class="value">${s.subnet}</span>
                    </div>
                    <div class="detail-item">
                        <span class="label">Routing Table</span>
                        <span class="value">Table ${s.routing_table}</span>
                    </div>
                    <div class="detail-item">
                        <span class="label">VPN Server</span>
                        <span class="value">${s.vpn_city ? `${s.vpn_city}, ` : ''}${s.vpn_country || s.id} (${s.vpn_type})</span>
                    </div>
                    ${vpnIpSection}
                    ${auto12hBadge}
                </div>
                <div class="stack-actions">
                    <button class="action-btn play" onclick="startStack('${s.id}')" title="Start AP Stack">
                        <i class="fa-solid fa-play"></i>
                    </button>
                    <button class="action-btn stop" onclick="stopStack('${s.id}')" title="Stop AP Stack">
                        <i class="fa-solid fa-stop"></i>
                    </button>
                    <button class="action-btn sync" onclick="restartStack('${s.id}')" title="Restart AP Stack">
                        <i class="fa-solid fa-rotate"></i>
                    </button>
                    <button class="action-btn edit" onclick="openEditStackModal('${s.id}')" title="Edit AP Stack">
                        <i class="fa-solid fa-pen-to-square"></i>
                    </button>
                    <button class="action-btn terminal" onclick="openLogsModal('${s.id}')" title="View Logs">
                        <i class="fa-solid fa-terminal"></i>
                    </button>
                    <button class="action-btn trash" onclick="deleteStack('${s.id}')" title="Delete AP Stack">
                        <i class="fa-solid fa-trash-can"></i>
                    </button>
                </div>
            </div>
        `;
    }).join('');
}

// ─── Stack Actions ───────────────────────────────────────────────────────────

async function startStack(id) {
    showToast(`Starting AP stack '${id}'...`);
    try {
        await apiRequest(`/api/stacks/${id}/start`, { method: 'POST' });
        showToast(`AP stack '${id}' started successfully.`, 'success');
        loadDashboard();
    } catch (err) {
        checkRfKillError(err?.message);
    }
}

async function stopStack(id) {
    showToast(`Stopping AP stack '${id}'...`);
    try {
        await apiRequest(`/api/stacks/${id}/stop`, { method: 'POST' });
        showToast(`AP stack '${id}' stopped.`, 'success');
        loadDashboard();
    } catch (err) {
        checkRfKillError(err?.message);
    }
}

async function restartStack(id) {
    showToast(`Restarting AP stack '${id}'...`);
    try {
        await apiRequest(`/api/stacks/${id}/restart`, { method: 'POST' });
        showToast(`AP stack '${id}' restarted.`, 'success');
        loadDashboard();
    } catch (err) {
        checkRfKillError(err?.message);
    }
}

async function deleteStack(id) {
    if (!confirm(`Are you sure you want to completely delete stack '${id}'? This will teardown its containers and delete all configuration.`)) {
        return;
    }
    showToast(`Deleting AP stack '${id}'...`);
    try {
        await apiRequest(`/api/stacks/${id}`, { method: 'DELETE' });
        showToast(`AP stack '${id}' deleted successfully.`, 'success');
        loadDashboard();
    } catch { }
}

// ─── Logs Modal ──────────────────────────────────────────────────────────────

async function openLogsModal(id) {
    activeLogStackId = id;
    document.getElementById('log-stack-id').innerText = id;
    document.getElementById('modal-logs').classList.add('open');
    document.getElementById('logs-output').innerText = 'Loading logs...';

    fetchLogs();

    // Set refresh interval (every 5 seconds)
    if (logsInterval) clearInterval(logsInterval);
    logsInterval = setInterval(fetchLogs, 5000);
}

async function fetchLogs() {
    if (!activeLogStackId) return;
    try {
        const res = await apiRequest(`/api/stacks/${activeLogStackId}/logs?tail=150`, { silentError: true });
        if (!res) return;

        let content = '';
        if (activeLogTab === 'gluetun') {
            content = res.gluetun || 'No Gluetun logs available.';
        } else if (activeLogTab === 'wifiap') {
            content = res.wifi_ap || 'No WiFi Access Point logs available.';
        } else if (activeLogTab === 'adguard') {
            content = res.adguard || 'No AdGuard Home logs available.';
        }

        const outputElem = document.getElementById('logs-output');
        outputElem.innerText = content;

        if (content.includes('RF-kill') || content.includes('rfkill') || content.includes('RF-Kill')) {
            checkRfKillError(content);
        }

        // Scroll terminal to bottom
        const terminalBody = document.getElementById('terminal-content');
        terminalBody.scrollTop = terminalBody.scrollHeight;
    } catch (e) {
        document.getElementById('logs-output').innerText = `Error loading logs: ${e.message}`;
    }
}

// Logs tab event handlers
document.querySelectorAll('.logs-tab').forEach(tab => {
    tab.addEventListener('click', (e) => {
        document.querySelectorAll('.logs-tab').forEach(t => t.classList.remove('active'));
        e.target.classList.add('active');
        activeLogTab = e.target.getAttribute('data-tab');
        fetchLogs();
    });
});

document.getElementById('btn-close-logs-modal').addEventListener('click', () => {
    document.getElementById('modal-logs').classList.remove('open');
    if (logsInterval) {
        clearInterval(logsInterval);
        logsInterval = null;
    }
    activeLogStackId = null;
});

document.getElementById('btn-refresh-logs').addEventListener('click', fetchLogs);

// ─── Interfaces Loaders ──────────────────────────────────────────────────────

async function loadInterfacesTable() {
    const tbody = document.getElementById('interfaces-table-body');
    tbody.innerHTML = `<tr><td colspan="7" class="text-center"><i class="fa-solid fa-spinner fa-spin"></i> Auditing WiFi hardware...</td></tr>`;

    try {
        interfaces = await apiRequest('/api/wifi/interfaces', { silentError: true }) || [];
        if (interfaces.length === 0) {
            tbody.innerHTML = `<tr><td colspan="7" class="text-center" style="color: var(--color-danger);">No wireless interfaces found. Ensure physical WiFi card is connected.</td></tr>`;
            return;
        }

        tbody.innerHTML = interfaces.map(i => {
            const bands = [];
            if (i.supports_2_4ghz) bands.push('2.4GHz');
            if (i.supports_5ghz) bands.push('5GHz');

            const stds = ['g'];
            if (i.supports_n) stds.push('n');
            if (i.supports_ac) stds.push('ac');
            if (i.supports_ax) stds.push('ax');

            const security = ['WPA', 'WPA2'];
            if (i.supports_wpa3) security.push('WPA3');

            return `
                <tr>
                    <td><strong>${i.name}</strong></td>
                    <td>${i.vendor_model}</td>
                    <td>
                        <span class="badge ${i.supports_ap ? 'running' : 'stopped'}">
                            ${i.supports_ap ? 'Supported' : 'No AP Mode'}
                        </span>
                    </td>
                    <td>${bands.join(' / ')}</td>
                    <td>802.11${stds.join('/')}</td>
                    <td>${security.join(' / ')}</td>
                    <td>Ch ${i.default_channel} (${i.default_hw_mode.toUpperCase()} / ${i.default_width}MHz)</td>
                </tr>
            `;
        }).join('');
    } catch {
        tbody.innerHTML = `<tr><td colspan="7" class="text-center" style="color: var(--color-danger);">Failed to query interfaces.</td></tr>`;
    }
}

// ─── Credentials Config Loaders ──────────────────────────────────────────────

let savedCredentials = {};

async function loadCredentialsForm() {
    try {
        const res = await apiRequest('/api/credentials', { silentError: true });
        if (!res) return;

        savedCredentials = {
            'cred-wg-key': res.wireguard_private_key || '',
            'cred-ovpn-pass': res.openvpn_password || '',
            'cred-ovpn-user': res.openvpn_user || '',
        };

        // Populate OpenVPN Username if available and not already edited
        if (res.openvpn_user && !document.getElementById('cred-ovpn-user').value) {
            document.getElementById('cred-ovpn-user').value = res.openvpn_user;
        }

        // Display has credential labels
        document.getElementById('cred-wg-key').placeholder = res.has_wireguard_private_key ? '•••••••••••••••• (WireGuard key is configured)' : 'Enter WireGuard Private Key';
        document.getElementById('cred-ovpn-user').placeholder = res.has_openvpn_user ? '•••••••• (Username is configured)' : 'Enter Username';
        document.getElementById('cred-ovpn-pass').placeholder = res.has_openvpn_password ? '•••••••• (Password is configured)' : 'Enter Password';
    } catch { }
}

document.getElementById('form-credentials').addEventListener('submit', async (e) => {
    e.preventDefault();

    const wg_key = document.getElementById('cred-wg-key').value.trim();
    const ovpn_user = document.getElementById('cred-ovpn-user').value.trim();
    const ovpn_pass = document.getElementById('cred-ovpn-pass').value.trim();

    const payload = {};
    if (wg_key) payload.wireguard_private_key = wg_key;
    if (ovpn_user) payload.openvpn_user = ovpn_user;
    if (ovpn_pass) payload.openvpn_password = ovpn_pass;

    showToast('Saving credentials...');
    try {
        await apiRequest('/api/credentials', {
            method: 'PATCH',
            body: JSON.stringify(payload)
        });

        showToast('Credentials updated successfully.', 'success');
        loadCredentialsForm();
        switchView('dashboard');
    } catch { }
});

// Fetch WireGuard Key via NordVPN Access Token
document.getElementById('btn-fetch-wg-key').addEventListener('click', async () => {
    const token = document.getElementById('cred-nordvpn-token').value.trim();
    if (!token) {
        showToast('Please enter a NordVPN Access Token first.', 'error');
        return;
    }

    showToast('Exchanging Access Token for WireGuard Private Key...');
    try {
        const res = await apiRequest('/api/credentials', {
            method: 'PATCH',
            body: JSON.stringify({ nordvpn_token: token })
        });

        if (res && res.success) {
            showToast('WireGuard Private Key successfully fetched and saved!', 'success');
            document.getElementById('cred-nordvpn-token').value = '';

            if (res.wireguard_private_key) {
                document.getElementById('cred-wg-key').value = res.wireguard_private_key;
                savedCredentials['cred-wg-key'] = res.wireguard_private_key;
            }

            loadCredentialsForm();
        } else {
            showToast(res.error || 'Failed to exchange token.', 'error');
        }
    } catch (err) {
        showToast(err.message || 'Error occurred during token exchange.', 'error');
    }
});

// ponytail: Event delegation handler for password visibility toggling with saved credentials support
document.querySelectorAll('.btn-toggle-show').forEach(btn => {
    btn.addEventListener('click', () => {
        const targetId = btn.getAttribute('data-target');
        const input = document.getElementById(targetId);
        if (!input) return;

        // If input field is empty and we have a saved credential for it, populate saved credential
        if (!input.value && savedCredentials[targetId]) {
            input.value = savedCredentials[targetId];
        }

        const isPassword = input.type === 'password';
        input.type = isPassword ? 'text' : 'password';
        btn.innerHTML = isPassword
            ? '<i class="fa-solid fa-eye-slash"></i> Hide'
            : '<i class="fa-solid fa-eye"></i> Show';
    });
});

// ─── Create & Edit AP Modal Handlers ─────────────────────────────────────────

document.getElementById('btn-create-ap').addEventListener('click', async () => {
    // Reset form and set create mode
    document.getElementById('form-stack').reset();
    document.getElementById('stack-edit-mode').value = 'false';
    document.getElementById('modal-title').innerText = 'Create Access Point';
    document.getElementById('btn-save-stack').innerText = 'Create Stack';

    // Enable VPN location & Profile ID fields
    document.getElementById('stack-vpn-city').disabled = false;
    document.getElementById('stack-id').disabled = false;

    lastAutoProfileId = '';
    lastAutoSsid = '';
    handleSecurityChange();

    // Populate form drop downs
    const ifaceSelect = document.getElementById('stack-iface');
    ifaceSelect.innerHTML = `<option>Auditing interfaces...</option>`;

    const citySelect = document.getElementById('stack-vpn-city');
    citySelect.innerHTML = `<option>Loading locations...</option>`;

    document.getElementById('modal-stack').classList.add('open');

    try {
        // Fetch interfaces
        interfaces = await apiRequest('/api/wifi/interfaces') || [];
        ifaceSelect.innerHTML = interfaces.map(i => {
            const disabled = !i.supports_ap ? 'disabled' : '';
            const suffix = !i.supports_ap ? ' (No AP support)' : '';
            return `<option value="${i.name}" ${disabled}>${i.name} - ${i.vendor_model}${suffix}</option>`;
        }).join('');

        // Fetch locations
        locations = await apiRequest('/api/vpn/locations') || [];
        citySelect.innerHTML = locations.map(l => {
            return `<option value="${l.name}">${l.name}</option>`;
        }).join('');

        // Auto populate fields for first location
        updateDefaultStackFields();

        // Sync security + hw-mode options with default selected interface
        updateSecurityOptionsForSelectedInterface();
        updateHwModeOptions();
    } catch { }
});

async function openEditStackModal(id) {
    const stack = stacks.find(s => s.id === id);
    if (!stack) return;

    document.getElementById('stack-edit-mode').value = 'true';
    document.getElementById('modal-title').innerText = `Edit Access Point (${id})`;
    document.getElementById('btn-save-stack').innerText = 'Save Changes';

    const ifaceSelect = document.getElementById('stack-iface');
    const citySelect = document.getElementById('stack-vpn-city');

    try {
        if (interfaces.length === 0) {
            interfaces = await apiRequest('/api/wifi/interfaces') || [];
        }
        if (locations.length === 0) {
            locations = await apiRequest('/api/vpn/locations') || [];
        }

        ifaceSelect.innerHTML = interfaces.map(i => {
            const disabled = !i.supports_ap ? 'disabled' : '';
            const suffix = !i.supports_ap ? ' (No AP support)' : '';
            const sel = i.name === stack.ap_iface ? 'selected' : '';
            return `<option value="${i.name}" ${disabled} ${sel}>${i.name} - ${i.vendor_model}${suffix}</option>`;
        }).join('');

        citySelect.innerHTML = locations.map(l => {
            const sel = (l.name === stack.vpn_city || l.name === stack.vpn_country) ? 'selected' : '';
            return `<option value="${l.name}" ${sel}>${l.name}</option>`;
        }).join('');
    } catch { }

    // Disable VPN City & Profile ID (per requirement: edit everything except VPN location)
    citySelect.disabled = true;
    document.getElementById('stack-id').disabled = true;

    // Prefill fields
    document.getElementById('stack-id').value = stack.id;
    document.getElementById('stack-ssid').value = stack.ssid;
    document.getElementById('stack-pass').value = stack.password;
    document.getElementById('stack-security').value = stack.ap_security;
    document.getElementById('stack-vpn-type').value = stack.vpn_type;
    document.getElementById('stack-subnet').value = stack.subnet;
    document.getElementById('stack-routing-table').value = stack.routing_table;
    document.getElementById('stack-channel').value = stack.ap_channel;
    document.getElementById('stack-hw-mode').value = stack.ap_hw_mode;
    document.getElementById('stack-auto-reconnect-12h').checked = !!stack.auto_reconnect_12h;

    handleSecurityChange();
    updateSecurityOptionsForSelectedInterface();
    updateHwModeOptions();

    document.getElementById('modal-stack').classList.add('open');
}

// Normalize a location label into a clean identifier token.
function slugifyLocation(name, lowercase = true) {
    const s = lowercase ? name.toLowerCase() : name;
    return s.replace(/[^a-z0-9]+/gi, '_').replace(/^_+|_+$/g, '');
}

function updateDefaultStackFields() {
    // Only update defaults if creating a new stack
    if (document.getElementById('stack-edit-mode').value === 'true') return;

    const citySelect = document.getElementById('stack-vpn-city');
    const locationVal = citySelect.value;
    if (locationVal && locationVal !== 'Loading locations...') {
        const newSlug = slugifyLocation(locationVal);
        const newSsid = 'AP_' + slugifyLocation(locationVal, false);

        const idInput = document.getElementById('stack-id');
        const ssidInput = document.getElementById('stack-ssid');

        // Only overwrite if input is empty or matches last auto-generated value
        if (idInput.value === '' || idInput.value === lastAutoProfileId) {
            idInput.value = newSlug;
            lastAutoProfileId = newSlug;
        }

        if (ssidInput.value === '' || ssidInput.value === lastAutoSsid) {
            ssidInput.value = newSsid;
            lastAutoSsid = newSsid;
        }
    }
}

document.getElementById('stack-vpn-city').addEventListener('change', updateDefaultStackFields);

function updateSecurityOptionsForSelectedInterface() {
    const ifaceSelect = document.getElementById('stack-iface');
    const ifaceName = ifaceSelect.value;
    const ifaceObj = interfaces.find(i => i.name === ifaceName);
    const securitySelect = document.getElementById('stack-security');
    if (!securitySelect) return;

    const wpa3Opt = securitySelect.querySelector('option[value="wpa3"]');
    const mixedOpt = securitySelect.querySelector('option[value="mixed"]');
    const setOpt = (opt, supported) => {
        if (!opt) return;
        opt.disabled = !supported;
        opt.text = supported ? opt.dataset.label : opt.dataset.label + " - Unsupported by adapter";
    };
    const supported = !(ifaceObj && !ifaceObj.supports_wpa3);
    setOpt(wpa3Opt, supported);
    setOpt(mixedOpt, supported);

    if (!supported && (securitySelect.value === 'wpa3' || securitySelect.value === 'mixed')) {
        securitySelect.value = 'wpa2';
        handleSecurityChange();
    }
}

// Show only 802.11 modes the selected adapter actually supports.
function updateHwModeOptions() {
    const ifaceName = document.getElementById('stack-iface').value;
    const ifaceObj = interfaces.find(i => i.name === ifaceName);
    const hwSelect = document.getElementById('stack-hw-mode');
    if (!hwSelect || !ifaceObj) return;

    let best = null;
    for (const [mode, req] of [['ax', 'supports_ax'], ['ac', 'supports_ac'], ['n', 'supports_n'], ['a', 'supports_5ghz'], ['g', 'supports_2_4ghz']]) {
        const opt = hwSelect.querySelector(`option[value="${mode}"]`);
        if (!opt) continue;
        const ok = ifaceObj[req];
        opt.disabled = !ok;
        if (ok && best === null) best = mode; // first (highest) match wins
    }
    if (best === null) best = 'g';
    if (hwSelect.querySelector(`option[value="${hwSelect.value}"]`).disabled) {
        hwSelect.value = best;
    }
}

function handleSecurityChange() {
    const securitySelect = document.getElementById('stack-security');
    if (!securitySelect) return;
    const security = securitySelect.value;

    const passwordRow = document.getElementById('password-form-row');
    const passwordInput = document.getElementById('stack-pass');
    const passwordHelp = document.getElementById('password-help');

    if (!passwordRow || !passwordInput) return;

    if (security === 'none') {
        passwordRow.style.display = 'none';
        passwordInput.required = false;
        passwordInput.removeAttribute('minlength');
        passwordInput.value = '';
    } else {
        passwordRow.style.display = 'flex';
        passwordInput.required = true;
        passwordInput.minlength = 8;

        if (passwordHelp) {
            const label = { wpa3: 'WPA3 SAE', wpa2: 'WPA2 CCMP', wpa: 'WPA Legacy (WPA-PSK)', mixed: 'Mixed WPA2/WPA3' };
            passwordHelp.innerText = `${label[security] || label.mixed} requires 8-63 characters. Special characters are fully supported.`;
        }
    }
}

document.getElementById('stack-iface').addEventListener('change', () => {
    updateSecurityOptionsForSelectedInterface();
    updateHwModeOptions();
});
document.getElementById('stack-security').addEventListener('change', handleSecurityChange);

document.getElementById('btn-close-stack-modal').addEventListener('click', () => {
    document.getElementById('modal-stack').classList.remove('open');
});

// Toggle Advanced settings inside create AP form
document.getElementById('adv-settings-toggle').addEventListener('click', () => {
    const advContent = document.getElementById('adv-settings-content');
    advContent.classList.toggle('open');

    const toggleIcon = document.querySelector('#adv-settings-toggle i');
    toggleIcon.classList.toggle('fa-chevron-down');
    toggleIcon.classList.toggle('fa-chevron-up');
});

document.getElementById('form-stack').addEventListener('submit', async (e) => {
    e.preventDefault();

    const isEditMode = document.getElementById('stack-edit-mode').value === 'true';
    const id = document.getElementById('stack-id').value.trim();
    const ap_iface = document.getElementById('stack-iface').value;
    const ssid = document.getElementById('stack-ssid').value.trim();
    const ap_security = document.getElementById('stack-security').value;
    const vpn_type = document.getElementById('stack-vpn-type').value;
    const vpn_location = document.getElementById('stack-vpn-city').value;
    const auto_reconnect_12h = document.getElementById('stack-auto-reconnect-12h').checked;

    let password = '';
    if (ap_security !== 'none') {
        password = document.getElementById('stack-pass').value;
        if (password.length < 8) {
            showToast('WiFi Password must be at least 8 characters.', 'error');
            return;
        }
        if (password.length > 63) {
            showToast('WiFi Password must be 63 characters or less.', 'error');
            return;
        }
        const asciiPrintableRegex = /^[\x20-\x7E]+$/;
        if (!asciiPrintableRegex.test(password)) {
            showToast('WiFi Password must only contain printable ASCII characters (alphanumerics, spaces, and punctuation).', 'error');
            return;
        }
    }

    // Optional settings
    const subnet_val = document.getElementById('stack-subnet').value.trim();
    const rt_val = document.getElementById('stack-routing-table').value.trim();
    const chan_val = document.getElementById('stack-channel').value.trim();
    const hw_val = document.getElementById('stack-hw-mode').value;

    const payload = {
        id,
        ssid,
        password,
        ap_iface,
        vpn_type,
        vpn_country: vpn_location,
        ap_security,
        auto_reconnect_12h
    };

    if (subnet_val) payload.subnet = subnet_val;
    if (rt_val) payload.routing_table = parseInt(rt_val);
    if (chan_val) payload.ap_channel = parseInt(chan_val);
    if (hw_val) payload.ap_hw_mode = hw_val;

    if (isEditMode) {
        showToast(`Updating AP configuration '${id}'...`);
        try {
            await apiRequest(`/api/stacks/${id}`, {
                method: 'PATCH',
                body: JSON.stringify(payload)
            });
            showToast(`Stack '${id}' updated successfully.`, 'success');
            document.getElementById('modal-stack').classList.remove('open');
            loadDashboard();
        } catch { }
    } else {
        showToast(`Creating AP configuration '${id}'...`);
        try {
            await apiRequest('/api/stacks', {
                method: 'POST',
                body: JSON.stringify(payload)
            });
            showToast(`Stack '${id}' created successfully. Start it from dashboard.`, 'success');
            document.getElementById('modal-stack').classList.remove('open');
            document.getElementById('form-stack').reset();
            loadDashboard();
        } catch { }
    }
});

// Initialize dashboard health checks & timers
let healthInterval = null;

function startHealthCheck() {
    checkSystemHealth();
    if (!healthInterval) {
        healthInterval = setInterval(checkSystemHealth, 10000);
    }
}

function stopHealthCheck() {
    if (healthInterval) {
        clearInterval(healthInterval);
        healthInterval = null;
    }
}

// Notification dropdown toggle
document.getElementById('btn-notification-bell').addEventListener('click', (e) => {
    e.stopPropagation();
    const dropdown = document.getElementById('notification-dropdown');
    const isVisible = dropdown.style.display === 'block';

    // Toggle
    dropdown.style.display = isVisible ? 'none' : 'block';

    // If opening, mark all notifications as read
    if (!isVisible) {
        notifications.forEach(n => n.unread = false);
        renderNotifications();
    }
});

// Clear all notifications
document.getElementById('btn-clear-notifications').addEventListener('click', (e) => {
    e.stopPropagation();
    notifications = [];
    renderNotifications();
});

// Close notification dropdown when clicking outside
document.addEventListener('click', (e) => {
    const container = document.querySelector('.notification-bell-container');
    if (container && !container.contains(e.target)) {
        document.getElementById('notification-dropdown').style.display = 'none';
    }
});

// RF-kill Modal Event Listeners
const closeRfkillBtn = document.getElementById('btn-close-rfkill-modal');
const dismissRfkillBtn = document.getElementById('btn-dismiss-rfkill');
const unblockRfkillBtn = document.getElementById('btn-unblock-rfkill');

if (closeRfkillBtn) {
    closeRfkillBtn.addEventListener('click', () => {
        document.getElementById('modal-rfkill').classList.remove('open');
    });
}
if (dismissRfkillBtn) {
    dismissRfkillBtn.addEventListener('click', () => {
        document.getElementById('modal-rfkill').classList.remove('open');
    });
}
if (unblockRfkillBtn) {
    unblockRfkillBtn.addEventListener('click', async () => {
        unblockRfkillBtn.disabled = true;
        unblockRfkillBtn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> Unblocking...';
        try {
            const res = await apiRequest('/api/rfkill/unblock', { method: 'POST' });
            showToast(res.message || 'RF-kill unblock command issued successfully.', 'success');
            document.getElementById('modal-rfkill').classList.remove('open');
            loadDashboard();
        } catch (e) {
            showToast(`Unblock failed: ${e.message}`, 'error');
        } finally {
            unblockRfkillBtn.disabled = false;
            unblockRfkillBtn.innerHTML = '<i class="fa-solid fa-bolt"></i> Attempt RF-Unblock Now';
        }
    });
}

// Start application
startHealthCheck();
connectStackSocket();
switchView('dashboard');
