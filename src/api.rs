use crate::config::{ConfigManager, Stack};
use crate::docker::DockerManager;
use crate::wifi;
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, Request, State,
    },
    http::{header, StatusCode},
    middleware::{self, Next},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::process::Command;
use std::sync::Arc;
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct AppState {
    pub config_manager: Arc<ConfigManager>,
    pub docker_manager: Arc<DockerManager>,
    pub host_project_dir_defaulted: bool,
    pub stack_tx: StackSnapshotTx,
}

/// Channel carrying the latest full stack-status snapshot for all WS subscribers.
pub type StackSnapshotTx = broadcast::Sender<Vec<StackStatusDto>>;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ContainerStatusDto {
    pub name: String,
    pub status: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct StackStatusDto {
    #[serde(flatten)]
    pub stack: Stack,
    pub status: String, // "stopped", "starting", "running", "error"
    pub vpn_ip: Option<String>,
    pub containers: Vec<ContainerStatusDto>,
}

#[derive(Debug, Deserialize)]
pub struct CreateStackInput {
    pub id: String,
    pub ssid: String,
    pub password: String,
    pub ap_iface: String,
    pub vpn_type: String, // "wireguard" or "openvpn"
    pub vpn_country: Option<String>,
    pub vpn_city: Option<String>,
    pub subnet: Option<String>,
    pub routing_table: Option<u8>,
    pub ap_channel: Option<u8>,
    pub ap_hw_mode: Option<String>,
    pub ap_channel_width: Option<u8>,
    pub ap_security: Option<String>,
    pub auto_reconnect_12h: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateCredentialsInput {
    pub openvpn_user: Option<String>,
    pub openvpn_password: Option<String>,
    pub wireguard_private_key: Option<String>,
    pub nordvpn_token: Option<String>,
}

const CONTAINER_ROLES: &[&str] = &["gluetun", "adguard", "wifi-ap"];

// Inspect the three stack containers and derive the aggregate stack status.
fn aggregate_status(state: &AppState, id: &str) -> (Vec<ContainerStatusDto>, String) {
    let mut containers = Vec::new();
    let mut running = 0;
    let mut _present = 0;
    for role in CONTAINER_ROLES {
        if let Some(st) = state.docker_manager.inspect_container_status(&format!("{}-{}", role, id)) {
            _present += 1;
            if st == "running" { running += 1; }
            containers.push(ContainerStatusDto { name: role.to_string(), status: st });
        }
    }
    let status = if running == CONTAINER_ROLES.len() {
        "running"
    } else if running == 0 {
        "stopped"
    } else {
        "starting"
    };
    (containers, status.to_string())
}

// Build the full stack-status list for every configured stack.
fn build_snapshot(state: &AppState) -> Vec<StackStatusDto> {
    let Ok(stacks) = state.config_manager.load_stacks() else {
        return Vec::new();
    };
    stacks
        .into_iter()
        .map(|s| {
            let (containers, status) = aggregate_status(state, &s.id);
            let vpn_ip = if status == "running" {
                state.docker_manager.get_vpn_ip(&s.id)
            } else {
                None
            };
            StackStatusDto { stack: s, status, vpn_ip, containers }
        })
        .collect()
}

/// Recompute and broadcast the latest snapshot to all WS subscribers.
// ponytail: global broadcast, one snapshot for all clients; per-client filtering if needed later.
pub fn publish_stacks(state: &AppState) {
    let _ = state.stack_tx.send(build_snapshot(state));
}

// Returns the first collision error against an existing stack, if any.
fn collision_error(existing: &Stack, candidate: &Stack) -> Option<String> {
    if existing.ap_iface == candidate.ap_iface {
        Some(format!("WiFi Interface '{}' is already in use by stack '{}'", candidate.ap_iface, existing.id))
    } else if existing.subnet == candidate.subnet {
        Some(format!("Subnet '{}' is already allocated", candidate.subnet))
    } else if existing.routing_table == candidate.routing_table {
        Some(format!("Routing table '{}' is already allocated", candidate.routing_table))
    } else if existing.ssid == candidate.ssid {
        Some(format!("SSID '{}' is already in use", candidate.ssid))
    } else {
        None
    }
}

async fn add_security_headers(
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let mut response = next.run(req).await;
    let headers = response.headers_mut();
    headers.insert("X-Content-Type-Options", axum::http::HeaderValue::from_static("nosniff"));
    headers.insert("X-Frame-Options", axum::http::HeaderValue::from_static("DENY"));
    headers.insert("X-XSS-Protection", axum::http::HeaderValue::from_static("1; mode=block"));
    headers.insert("Content-Security-Policy", axum::http::HeaderValue::from_static("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:;"));
    headers.insert("Permissions-Policy", axum::http::HeaderValue::from_static("geolocation=(), microphone=(), camera=()"));
    headers.insert("Referrer-Policy", axum::http::HeaderValue::from_static("strict-origin-when-cross-origin"));
    response
}


// ponytail: bearer gate is opt-in via AP_API_TOKEN; when unset we pass through (dev) so the
// service isn't bricked. prod upgrade path: return 401 instead of `true` in the None branch.
async fn require_auth(
    State(token): State<Option<String>>,
    req: Request,
    next: Next,
) -> axum::response::Response {
    let authorized = match &token {
        Some(expected) => req
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .map(|v| v == format!("Bearer {}", expected))
            .unwrap_or(false),
        None => true,
    };
    if authorized {
        next.run(req).await
    } else {
        (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Bearer")],
            "missing or invalid bearer token",
        )
            .into_response()
    }
}

pub fn start_12h_reconnect_scheduler(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            let now = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
                Ok(d) => d.as_secs(),
                Err(_) => continue,
            };

            let mut stacks_to_restart = Vec::new();
            if let Ok(stacks) = state.config_manager.load_stacks() {
                for stack in stacks {
                    if stack.auto_reconnect_12h {
                        let (_, status) = aggregate_status(&state, &stack.id);
                        if status == "running" {
                            let elapsed = now.saturating_sub(stack.last_reconnect_at);
                            if elapsed >= 12 * 3600 {
                                stacks_to_restart.push(stack.id);
                            }
                        }
                    }
                }
            }

            for id in stacks_to_restart {
                tracing::info!("12-hour auto-reconnect triggering for stack: {}", id);
                let _ = state.docker_manager.restart_stack(&id);
                if let Ok(mut stacks) = state.config_manager.load_stacks() {
                    if let Some(s) = stacks.iter_mut().find(|x| x.id == id) {
                        s.last_reconnect_at = now;
                        let _ = state.config_manager.save_stacks(&stacks);
                    }
                }
                publish_stacks(&state);
            }
        }
    });
}

pub fn create_router(state: AppState, api_token: Option<String>) -> Router {
    start_12h_reconnect_scheduler(state.clone());

    let api_routes = Router::new()
        // Stack routes
        .route("/stacks", get(list_stacks).post(create_stack))
        .route("/stacks/:id", get(get_stack).patch(update_stack).delete(delete_stack))
        .route("/stacks/:id/start", post(start_stack))
        .route("/stacks/:id/stop", post(stop_stack))
        .route("/stacks/:id/restart", post(restart_stack))
        .route("/stacks/:id/logs", get(get_stack_logs))
        // Credentials routes
        .route("/credentials", get(get_credentials).patch(update_credentials))
        // Utils routes
        .route("/wifi/interfaces", get(list_wifi_interfaces))
        .route("/vpn/locations", get(list_vpn_locations))
        .route("/rfkill/unblock", post(unblock_rfkill))
        .route("/health", get(get_health));

    let api_routes = api_routes.layer(middleware::from_fn_with_state(api_token, require_auth));

    Router::new()
        .route("/ws/stacks", get(stream_stacks))
        .nest("/api", api_routes)
        .layer(middleware::from_fn(add_security_headers))
        .with_state(state)
}

async fn stream_stacks(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, state: AppState) {
    // Send current snapshot immediately on connect.
    let snap = build_snapshot(&state);
    if let Ok(msg) = serde_json::to_string(&snap) {
        let _ = socket.send(Message::Text(msg)).await;
    }

    let mut rx = state.stack_tx.subscribe();
    loop {
        match rx.recv().await {
            Ok(snap) => {
                let msg = match serde_json::to_string(&snap) {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                if socket.send(Message::Text(msg)).await.is_err() {
                    break; // client gone
                }
            }
            Err(broadcast::error::RecvError::Lagged(_)) => continue, // ponytail: drop stale, client resyncs on next
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

// ─── Stack Handlers ──────────────────────────────────────────────────────────

async fn list_stacks(State(state): State<AppState>) -> impl IntoResponse {
    // Touch the config so a bad path surfaces as 500 rather than an empty list.
    if let Err(e) = state.config_manager.load_stacks() {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response();
    }

    let dtos = build_snapshot(&state);
    Json(dtos).into_response()
}

async fn create_stack(
    State(state): State<AppState>,
    Json(input): Json<CreateStackInput>,
) -> impl IntoResponse {
    let mut stacks = match state.config_manager.load_stacks() {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    };

    // Check if ID already exists
    if stacks.iter().any(|s| s.id == input.id) {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("Stack ID '{}' already exists", input.id) }))).into_response();
    }

    // Allocate resource if missing
    let (subnet, routing_table) = match (input.subnet, input.routing_table) {
        (Some(sub), Some(rt)) => (sub, rt),
        _ => state.config_manager.allocate_resources(&stacks),
    };

    // Audit interface defaults if channel is missing
    let mut ap_channel = input.ap_channel.unwrap_or(0);
    let mut ap_hw_mode = input.ap_hw_mode.unwrap_or_else(|| "g".to_string());
    let mut ap_channel_width = input.ap_channel_width.unwrap_or(20);

    if ap_channel == 0 {
        // Query wifi auditor for recommendations
        let wifis = wifi::list_wifi_interfaces();
        if let Some(w) = wifis.iter().find(|w| w.name == input.ap_iface) {
            ap_channel = w.default_channel;
            ap_hw_mode = w.default_hw_mode.clone();
            ap_channel_width = w.default_width;
        } else {
            ap_channel = 6;
            ap_hw_mode = "g".to_string();
            ap_channel_width = 20;
        }
    }

    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);

    let vpn_country = input
        .vpn_country
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| {
            input.vpn_city.clone().unwrap_or_else(|| input.id.clone())
        });

    let vpn_city = input
        .vpn_city
        .filter(|c| !c.is_empty() && !c.eq_ignore_ascii_case(&vpn_country));

    let new_stack = Stack {
        id: input.id,
        ssid: input.ssid,
        password: input.password,
        ap_iface: input.ap_iface,
        vpn_type: input.vpn_type,
        vpn_country,
        vpn_city,
        subnet,
        routing_table,
        ap_channel,
        ap_hw_mode,
        ap_channel_width,
        ap_security: input.ap_security.unwrap_or_else(|| "wpa2".to_string()),
        auto_reconnect_12h: input.auto_reconnect_12h.unwrap_or(false),
        last_reconnect_at: now,
    };

    // Check collisions
    for s in &stacks {
        if let Some(err) = collision_error(s, &new_stack) {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": err }))).into_response();
        }
    }

    // Generate docker-compose config
    let creds = state.config_manager.load_credentials();
    if let Err(e) = state.docker_manager.generate_compose_file(&new_stack, &creds) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": format!("Compose generation failed: {}", e) }))).into_response();
    }

    stacks.push(new_stack.clone());
    if let Err(e) = state.config_manager.save_stacks(&stacks) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response();
    }

    publish_stacks(&state);
    (StatusCode::CREATED, Json(new_stack)).into_response()
}

async fn get_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    let stacks = match state.config_manager.load_stacks() {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    };

    let stack = match stacks.into_iter().find(|s| s.id == id) {
        Some(s) => s,
        None => return (StatusCode::NOT_FOUND, Json(json!({ "error": "Stack not found" }))).into_response(),
    };

    let (containers, status) = aggregate_status(&state, &id);
    let vpn_ip = if status == "running" {
        state.docker_manager.get_vpn_ip(&id)
    } else {
        None
    };

    Json(StackStatusDto {
        stack,
        status,
        vpn_ip,
        containers,
    }).into_response()
}

async fn update_stack(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<CreateStackInput>,
) -> impl IntoResponse {
    let mut stacks = match state.config_manager.load_stacks() {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    };

    let idx = match stacks.iter().position(|s| s.id == id) {
        Some(i) => i,
        None => return (StatusCode::NOT_FOUND, Json(json!({ "error": "Stack not found" }))).into_response(),
    };

    let mut updated = stacks[idx].clone();
    
    // Update config fields
    updated.ssid = input.ssid;
    updated.password = input.password;
    updated.ap_iface = input.ap_iface;
    updated.vpn_type = input.vpn_type;
    if let Some(country) = input.vpn_country { updated.vpn_country = country; }
    if input.vpn_city.is_some() {
        updated.vpn_city = input.vpn_city.filter(|c| !c.is_empty() && !c.eq_ignore_ascii_case(&updated.vpn_country));
    }
    if let Some(sub) = input.subnet { updated.subnet = sub; }
    if let Some(rt) = input.routing_table { updated.routing_table = rt; }
    if let Some(ch) = input.ap_channel { updated.ap_channel = ch; }
    if let Some(hw) = input.ap_hw_mode { updated.ap_hw_mode = hw; }
    if let Some(width) = input.ap_channel_width { updated.ap_channel_width = width; }
    if let Some(sec) = input.ap_security { updated.ap_security = sec; }
    if let Some(auto_rec) = input.auto_reconnect_12h { updated.auto_reconnect_12h = auto_rec; }

    // Re-verify collisions (excluding itself)
    for (i, s) in stacks.iter().enumerate() {
        if i == idx { continue; }
        if let Some(err) = collision_error(s, &updated) {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": err }))).into_response();
        }
    }

    // Regenerate compose config
    let creds = state.config_manager.load_credentials();
    if let Err(e) = state.docker_manager.generate_compose_file(&updated, &creds) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": format!("Compose generation failed: {}", e) }))).into_response();
    }

    stacks[idx] = updated.clone();
    if let Err(e) = state.config_manager.save_stacks(&stacks) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response();
    }

    // If stack was running, restart containers to apply new config
    let (_, status) = aggregate_status(&state, &id);
    if status == "running" {
        let _ = state.docker_manager.restart_stack(&id);
    }

    publish_stacks(&state);
    Json(updated).into_response()
}

async fn delete_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    let mut stacks = match state.config_manager.load_stacks() {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    };

    let idx = match stacks.iter().position(|s| s.id == id) {
        Some(i) => i,
        None => return (StatusCode::NOT_FOUND, Json(json!({ "error": "Stack not found" }))).into_response(),
    };

    // Down containers and clean files
    if let Err(e) = state.docker_manager.destroy_stack(&id) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response();
    }

    stacks.remove(idx);
    if let Err(e) = state.config_manager.save_stacks(&stacks) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response();
    }

    publish_stacks(&state);
    Json(json!({ "success": true })).into_response()
}

// ─── Stack Actions ───────────────────────────────────────────────────────────

async fn start_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);

    // Regenerate compose config on start to pick up template or credential updates & update timestamp
    if let Ok(mut stacks) = state.config_manager.load_stacks() {
        if let Some(s) = stacks.iter_mut().find(|x| x.id == id) {
            s.last_reconnect_at = now;
            let creds = state.config_manager.load_credentials();
            let _ = state.docker_manager.generate_compose_file(s, &creds);
            let _ = state.config_manager.save_stacks(&stacks);
        }
    }

    match state.docker_manager.start_stack(&id) {
        Ok(out) => {
            publish_stacks(&state);
            Json(json!({ "success": true, "output": out })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    }
}

async fn stop_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    match state.docker_manager.stop_stack(&id) {
        Ok(out) => {
            publish_stacks(&state);
            Json(json!({ "success": true, "output": out })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    }
}

async fn restart_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    if let Ok(mut stacks) = state.config_manager.load_stacks() {
        if let Some(s) = stacks.iter_mut().find(|x| x.id == id) {
            s.last_reconnect_at = now;
            let _ = state.config_manager.save_stacks(&stacks);
        }
    }

    match state.docker_manager.restart_stack(&id) {
        Ok(out) => {
            publish_stacks(&state);
            Json(json!({ "success": true, "output": out })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct LogsQuery {
    pub tail: Option<usize>,
}

async fn get_stack_logs(
    Path(id): Path<String>,
    Query(query): Query<LogsQuery>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let tail = query.tail.unwrap_or(100);

    let gluetun_logs = state.docker_manager.get_container_logs(&format!("gluetun-{}", id), tail).unwrap_or_default();
    let adguard_logs = state.docker_manager.get_container_logs(&format!("adguard-{}", id), tail).unwrap_or_default();
    let wifiap_logs = state.docker_manager.get_container_logs(&format!("wifi-ap-{}", id), tail).unwrap_or_default();

    Json(json!({
        "gluetun": gluetun_logs,
        "adguard": adguard_logs,
        "wifi_ap": wifiap_logs,
    })).into_response()
}

// ─── Credentials Handlers ───────────────────────────────────────────────────

async fn get_credentials(State(state): State<AppState>) -> impl IntoResponse {
    let creds = state.config_manager.load_credentials();
    // Return credential existence status and values if configured
    Json(json!({
        "has_openvpn_user": creds.openvpn_user.is_some() && !creds.openvpn_user.as_ref().unwrap().is_empty(),
        "has_openvpn_password": creds.openvpn_password.is_some() && !creds.openvpn_password.as_ref().unwrap().is_empty(),
        "has_wireguard_private_key": creds.wireguard_private_key.is_some() && !creds.wireguard_private_key.as_ref().unwrap().is_empty(),
    }))
}

async fn update_credentials(
    State(state): State<AppState>,
    Json(input): Json<UpdateCredentialsInput>,
) -> impl IntoResponse {
    let mut creds = state.config_manager.load_credentials();

    if let Some(user) = input.openvpn_user { creds.openvpn_user = Some(user); }
    if let Some(pass) = input.openvpn_password { creds.openvpn_password = Some(pass); }
    if let Some(key) = input.wireguard_private_key { creds.wireguard_private_key = Some(key); }

    // If an Access Token is provided, fetch the WireGuard private key via NordVPN API
    if let Some(token) = input.nordvpn_token {
        let token_str = token.trim();
        if !token_str.is_empty() {
            // Strip "token:" prefix if user pasted it directly
            let clean_token = token_str.strip_prefix("token:").unwrap_or(token_str);


            tracing::info!("Attempting to exchange NordVPN Access Token for WireGuard key...");
            let curl_res = Command::new("curl")
                .args([
                    "-s",
                    "-L",
                    "--max-time",
                    "10",
                    "-H",
                    "User-Agent: NordAP/1.0",
                    "-u",
                    &format!("token:{}", clean_token),
                    "https://api.nordvpn.com/v1/users/services/credentials"
                ])
                .output();
                
            match curl_res {
                Ok(out) => {
                    let body_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    if out.status.success() {
                        if let Ok(json_body) = serde_json::from_str::<serde_json::Value>(&body_str) {
                            if let Some(key) = json_body.get("nordlynx_private_key").and_then(|k| k.as_str()) {
                                tracing::info!("Successfully extracted WireGuard private key from token exchange.");
                                creds.wireguard_private_key = Some(key.to_string());
                            } else {
                                // Extract API error if present
                                let err_msg = json_body.get("errors")
                                    .and_then(|e| e.get("message"))
                                    .and_then(|m| m.as_str())
                                    .unwrap_or("Response did not contain 'nordlynx_private_key'");
                                tracing::error!("Token response did not contain private key. Response: {}", body_str);
                                return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("NordVPN API Error: {}", err_msg) }))).into_response();
                            }
                        } else {
                            tracing::error!("Failed to parse JSON response from NordVPN. Body: {}", body_str);
                            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("Invalid JSON response: {}", body_str) }))).into_response();
                        }
                    } else {
                        let err_msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
                        tracing::error!("Curl request failed. Stderr: {}", err_msg);
                        return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("NordVPN API request failed: {}", err_msg) }))).into_response();
                    }
                }
                Err(e) => {
                    tracing::error!("Failed to execute curl: {}", e);
                    return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": format!("Failed to run curl command: {}", e) }))).into_response();
                }
            }
        }
    }

    if let Err(e) = state.config_manager.save_credentials(&creds) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response();
    }

    Json(json!({ "success": true })).into_response()
}

// ─── Utils Handlers ──────────────────────────────────────────────────────────

async fn list_wifi_interfaces() -> impl IntoResponse {
    Json(wifi::list_wifi_interfaces())
}

async fn list_vpn_locations() -> impl IntoResponse {
    // Attempt to download countries from NordVPN API
    let output = Command::new("curl")
        .args(["-s", "--max-time", "5", "https://api.nordvpn.com/v1/servers/countries"])
        .output();

    if let Ok(out) = output {
        if out.status.success() {
            if let Ok(json_val) = serde_json::from_slice::<serde_json::Value>(&out.stdout) {
                return Json(json_val).into_response();
            }
        }
    }

    // Static fallback countries list if curl fails
    let fallback = json!([
        { "name": "United States", "code": "US" },
        { "name": "Germany", "code": "DE" },
        { "name": "United Kingdom", "code": "GB" },
        { "name": "Canada", "code": "CA" },
        { "name": "France", "code": "FR" },
        { "name": "Netherlands", "code": "NL" },
        { "name": "Switzerland", "code": "CH" },
        { "name": "Japan", "code": "JP" },
        { "name": "Australia", "code": "AU" }
    ]);
    Json(fallback).into_response()
}

async fn unblock_rfkill() -> impl IntoResponse {
    // wifi-ap runs `privileged: true` + `pid: host`, so rfkill here already reaches the host RF
    // subsystem. No nsenter into init's namespaces — that's a needless container->host pivot surface.
    let output = Command::new("rfkill").args(["unblock", "wifi"]).output();
    let output_all = Command::new("rfkill").args(["unblock", "all"]).output();

    let success = output.map(|o| o.status.success()).unwrap_or(false)
        || output_all.map(|o| o.status.success()).unwrap_or(false);

    Json(json!({
        "success": success,
        "message": if success { "Issued RF-kill unblock command successfully." } else { "Attempted RF-kill unblock command." }
    }))
}

async fn get_health(State(state): State<AppState>) -> impl IntoResponse {
    let docker_output = Command::new("docker").arg("ps").output();
    let docker_ok = docker_output.is_ok() && docker_output.unwrap().status.success();

    let (total_stacks, active_stacks) = match state.config_manager.load_stacks() {
        Ok(stacks) => {
            let total = stacks.len();
            let active = stacks.iter().filter(|s| {
                let (_, status) = aggregate_status(&state, &s.id);
                status == "running"
            }).count();
            (total, active)
        }
        Err(_) => (0, 0),
    };

    Json(json!({
        "status": "healthy",
        "docker_socket_reachable": docker_ok,
        "host_project_dir_defaulted": state.host_project_dir_defaulted,
        "total_stacks": total_stacks,
        "active_stacks": active_stacks
    }))
}
