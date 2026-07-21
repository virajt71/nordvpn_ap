// Global API Token State
let API_TOKEN = localStorage.getItem('api_token') || 'default-token';

// App state
let stacks = [];
let interfaces = [];
let locations = [];
let activeLogStackId = null;
let logsInterval = null;
let activeLogTab = 'gluetun';

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

// Notification helper
function showToast(message, type = 'info') {
    const container = document.getElementById('notification-container');
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    
    let iconClass = 'fa-circle-info';
    if (type === 'success') iconClass = 'fa-circle-check';
    if (type === 'error') iconClass = 'fa-triangle-exclamation';
    
    toast.innerHTML = `
        <i class="fa-solid ${iconClass}"></i>
        <span>${message}</span>
    `;
    
    container.appendChild(toast);
    
    // Auto remove
    setTimeout(() => {
        toast.style.animation = 'slideIn 0.3s cubic-bezier(0.25, 0.8, 0.25, 1) reverse';
        setTimeout(() => toast.remove(), 300);
    }, 4000);
}

// Fetch wrapper with authentication
async function apiRequest(endpoint, options = {}) {
    const headers = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${API_TOKEN}`,
        ...options.headers
    };

    const config = {
        ...options,
        headers
    };

    try {
        const response = await fetch(endpoint, config);
        
        if (response.status === 401) {
            showAuthOverlay();
            return null;
        }

        if (!response.ok) {
            const errData = await response.json().catch(() => ({}));
            throw new Error(errData.error || `HTTP error! Status: ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        showToast(error.message, 'error');
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
        const res = await apiRequest('/api/health');
        if (res && res.status === 'healthy') {
            const apiDot = document.getElementById('api-status-dot');
            apiDot.className = 'pulse-dot green';
            document.getElementById('api-status-text').innerText = 'Orchestrator Online';
        }
    } catch {
        const apiDot = document.getElementById('api-status-dot');
        apiDot.className = 'pulse-dot red';
        document.getElementById('api-status-text').innerText = 'Offline / Error';
    }
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
        stacks = await apiRequest('/api/stacks') || [];
        renderStacks();
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

        return `
            <div class="glass-panel stack-card ${badgeClass}">
                <div class="stack-header">
                    <div class="stack-info-title">
                        <h3>${s.ssid}</h3>
                        <span class="stack-id-tag">id: ${s.id}</span>
                    </div>
                    <span class="badge ${badgeClass}">${s.status}</span>
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
                        <span class="value">${s.vpn_city} (${s.vpn_type})</span>
                    </div>
                    ${vpnIpSection}
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
    } catch {}
}

async function stopStack(id) {
    showToast(`Stopping AP stack '${id}'...`);
    try {
        await apiRequest(`/api/stacks/${id}/stop`, { method: 'POST' });
        showToast(`AP stack '${id}' stopped.`, 'success');
        loadDashboard();
    } catch {}
}

async function restartStack(id) {
    showToast(`Restarting AP stack '${id}'...`);
    try {
        await apiRequest(`/api/stacks/${id}/restart`, { method: 'POST' });
        showToast(`AP stack '${id}' restarted.`, 'success');
        loadDashboard();
    } catch {}
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
    } catch {}
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
        const res = await apiRequest(`/api/stacks/${activeLogStackId}/logs?tail=150`);
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
    tbody.innerHTML = `<tr><td colspan="6" class="text-center"><i class="fa-solid fa-spinner fa-spin"></i> Auditing WiFi hardware...</td></tr>`;

    try {
        interfaces = await apiRequest('/api/wifi/interfaces') || [];
        if (interfaces.length === 0) {
            tbody.innerHTML = `<tr><td colspan="6" class="text-center" style="color: var(--color-danger);">No wireless interfaces found. Ensure physical WiFi card is connected.</td></tr>`;
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
                    <td>Ch ${i.default_channel} (${i.default_hw_mode.toUpperCase()} / ${i.default_width}MHz)</td>
                </tr>
            `;
        }).join('');
    } catch {
        tbody.innerHTML = `<tr><td colspan="6" class="text-center" style="color: var(--color-danger);">Failed to query interfaces.</td></tr>`;
    }
}

// ─── Credentials Config Loaders ──────────────────────────────────────────────

async function loadCredentialsForm() {
    try {
        const res = await apiRequest('/api/credentials');
        if (!res) return;

        // Display has credential labels
        document.getElementById('cred-wg-key').placeholder = res.has_wireguard_private_key ? '•••••••••••••••• (WireGuard key is configured)' : 'Enter WireGuard Private Key';
        document.getElementById('cred-ovpn-user').placeholder = res.has_openvpn_user ? '•••••••• (Username is configured)' : 'Enter Username';
        document.getElementById('cred-ovpn-pass').placeholder = res.has_openvpn_password ? '•••••••• (Password is configured)' : 'Enter Password';
        document.getElementById('cred-api-token').value = res.api_token || API_TOKEN;
        
        // Show token preview
        document.getElementById('bearer-token-preview').innerText = res.api_token || '••••••••';
    } catch {}
}

document.getElementById('form-credentials').addEventListener('submit', async (e) => {
    e.preventDefault();
    
    const wg_key = document.getElementById('cred-wg-key').value.trim();
    const ovpn_user = document.getElementById('cred-ovpn-user').value.trim();
    const ovpn_pass = document.getElementById('cred-ovpn-pass').value.trim();
    const api_token = document.getElementById('cred-api-token').value.trim();

    const payload = {};
    if (wg_key) payload.wireguard_private_key = wg_key;
    if (ovpn_user) payload.openvpn_user = ovpn_user;
    if (ovpn_pass) payload.openvpn_password = ovpn_pass;
    if (api_token) payload.api_token = api_token;

    showToast('Saving credentials...');
    try {
        await apiRequest('/api/credentials', {
            method: 'PATCH',
            body: JSON.stringify(payload)
        });
        
        if (api_token) {
            API_TOKEN = api_token;
            localStorage.setItem('api_token', api_token);
        }

        showToast('Credentials updated successfully.', 'success');
        loadCredentialsForm();
    } catch {}
});

document.getElementById('btn-copy-token').addEventListener('click', () => {
    navigator.clipboard.writeText(API_TOKEN).then(() => {
        showToast('Bearer token copied to clipboard!', 'success');
    }).catch(() => {
        showToast('Failed to copy token. Copy manually.', 'error');
    });
});

// ─── Create AP Modal Handlers ────────────────────────────────────────────────

document.getElementById('btn-create-ap').addEventListener('click', async () => {
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
    } catch {}
});

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

    const id = document.getElementById('stack-id').value.trim();
    const ap_iface = document.getElementById('stack-iface').value;
    const ssid = document.getElementById('stack-ssid').value.trim();
    const password = document.getElementById('stack-pass').value.trim();
    const vpn_type = document.getElementById('stack-vpn-type').value;
    const vpn_city = document.getElementById('stack-vpn-city').value;
    
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
        vpn_city
    };

    if (subnet_val) payload.subnet = subnet_val;
    if (rt_val) payload.routing_table = parseInt(rt_val);
    if (chan_val) payload.ap_channel = parseInt(chan_val);
    if (hw_val) payload.ap_hw_mode = hw_val;

    showToast(`Creating AP configuration '${id}'...`);
    try {
        await apiRequest('/api/stacks', {
            method: 'POST',
            body: JSON.stringify(payload)
        });
        showToast(`Stack '${id}' created successfully. Start it from dashboard.`, 'success');
        document.getElementById('modal-stack').classList.remove('open');
        document.getElementById('form-stack').reset();
        switchView('dashboard');
    } catch {}
});

// Initialize dashboard health checks & timers
let healthInterval = null;
let isAuthOverlayOpen = false;

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

function showAuthOverlay() {
    if (isAuthOverlayOpen) return;
    isAuthOverlayOpen = true;
    
    stopHealthCheck();
    if (logsInterval) {
        clearInterval(logsInterval);
        logsInterval = null;
    }
    
    const authModal = document.getElementById('modal-auth');
    if (authModal) {
        authModal.style.display = 'flex';
        authModal.classList.add('open');
    }
}

document.getElementById('btn-submit-auth').addEventListener('click', () => {
    const tokenInput = document.getElementById('auth-token-input').value.trim();
    if (!tokenInput) {
        showToast('Please enter a valid token.', 'error');
        return;
    }
    API_TOKEN = tokenInput;
    localStorage.setItem('api_token', tokenInput);
    
    const authModal = document.getElementById('modal-auth');
    if (authModal) {
        authModal.style.display = 'none';
        authModal.classList.remove('open');
    }
    isAuthOverlayOpen = false;
    
    startHealthCheck();
    switchView('dashboard');
});

// Start application
startHealthCheck();
switchView('dashboard');
