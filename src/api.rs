use crate::config::{ConfigManager, Stack};
use crate::docker::DockerManager;
use crate::wifi;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::process::Command;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub config_manager: Arc<ConfigManager>,
    pub docker_manager: Arc<DockerManager>,
    pub host_project_dir_defaulted: bool,
}

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
    pub vpn_city: String,
    pub subnet: Option<String>,
    pub routing_table: Option<u8>,
    pub ap_channel: Option<u8>,
    pub ap_hw_mode: Option<String>,
    pub ap_channel_width: Option<u8>,
    pub ap_security: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateCredentialsInput {
    pub openvpn_user: Option<String>,
    pub openvpn_password: Option<String>,
    pub wireguard_private_key: Option<String>,
}

pub fn create_router(state: AppState) -> Router {
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
        .route("/health", get(get_health));

    Router::new()
        .nest("/api", api_routes)
        .with_state(state)
}

// ─── Stack Handlers ──────────────────────────────────────────────────────────

async fn list_stacks(State(state): State<AppState>) -> impl IntoResponse {
    let stacks = match state.config_manager.load_stacks() {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    };

    let mut dtos = Vec::new();
    for s in stacks {
        let gluetun_c = format!("gluetun-{}", s.id);
        let adguard_c = format!("adguard-{}", s.id);
        let wifiap_c = format!("wifi-ap-{}", s.id);

        let gluetun_status = state.docker_manager.inspect_container_status(&gluetun_c);
        let adguard_status = state.docker_manager.inspect_container_status(&adguard_c);
        let wifiap_status = state.docker_manager.inspect_container_status(&wifiap_c);

        let mut containers = Vec::new();
        if let Some(ref st) = gluetun_status {
            containers.push(ContainerStatusDto { name: "gluetun".to_string(), status: st.clone() });
        }
        if let Some(ref st) = adguard_status {
            containers.push(ContainerStatusDto { name: "adguard".to_string(), status: st.clone() });
        }
        if let Some(ref st) = wifiap_status {
            containers.push(ContainerStatusDto { name: "wifi-ap".to_string(), status: st.clone() });
        }

        // Determine stack status
        let status = if gluetun_status.as_deref() == Some("running") 
            && adguard_status.as_deref() == Some("running") 
            && wifiap_status.as_deref() == Some("running") 
        {
            "running".to_string()
        } else if gluetun_status.is_some() || adguard_status.is_some() || wifiap_status.is_some() {
            "starting".to_string()
        } else {
            "stopped".to_string()
        };

        let vpn_ip = if status == "running" {
            state.docker_manager.get_vpn_ip(&s.id)
        } else {
            None
        };

        dtos.push(StackStatusDto {
            stack: s,
            status,
            vpn_ip,
            containers,
        });
    }

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

    let new_stack = Stack {
        id: input.id,
        ssid: input.ssid,
        password: input.password,
        ap_iface: input.ap_iface,
        vpn_type: input.vpn_type,
        vpn_city: input.vpn_city,
        subnet,
        routing_table,
        ap_channel,
        ap_hw_mode,
        ap_channel_width,
        ap_security: input.ap_security.unwrap_or_else(|| "wpa2".to_string()),
    };

    // Check collisions
    for s in &stacks {
        if s.ap_iface == new_stack.ap_iface {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("WiFi Interface '{}' is already in use by stack '{}'", new_stack.ap_iface, s.id) }))).into_response();
        }
        if s.subnet == new_stack.subnet {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("Subnet '{}' is already allocated", new_stack.subnet) }))).into_response();
        }
        if s.routing_table == new_stack.routing_table {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("Routing table '{}' is already allocated", new_stack.routing_table) }))).into_response();
        }
        if s.ssid == new_stack.ssid {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("SSID '{}' is already in use", new_stack.ssid) }))).into_response();
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

    let gluetun_c = format!("gluetun-{}", id);
    let adguard_c = format!("adguard-{}", id);
    let wifiap_c = format!("wifi-ap-{}", id);

    let gluetun_status = state.docker_manager.inspect_container_status(&gluetun_c);
    let adguard_status = state.docker_manager.inspect_container_status(&adguard_c);
    let wifiap_status = state.docker_manager.inspect_container_status(&wifiap_c);

    let mut containers = Vec::new();
    if let Some(st) = gluetun_status.clone() {
        containers.push(ContainerStatusDto { name: "gluetun".to_string(), status: st });
    }
    if let Some(st) = adguard_status.clone() {
        containers.push(ContainerStatusDto { name: "adguard".to_string(), status: st });
    }
    if let Some(st) = wifiap_status.clone() {
        containers.push(ContainerStatusDto { name: "wifi-ap".to_string(), status: st });
    }

    let status = if gluetun_status.as_deref() == Some("running") 
        && adguard_status.as_deref() == Some("running") 
        && wifiap_status.as_deref() == Some("running") 
    {
        "running".to_string()
    } else if gluetun_status.is_some() || adguard_status.is_some() || wifiap_status.is_some() {
        "starting".to_string()
    } else {
        "stopped".to_string()
    };

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
    updated.vpn_city = input.vpn_city;
    if let Some(sub) = input.subnet { updated.subnet = sub; }
    if let Some(rt) = input.routing_table { updated.routing_table = rt; }
    if let Some(ch) = input.ap_channel { updated.ap_channel = ch; }
    if let Some(hw) = input.ap_hw_mode { updated.ap_hw_mode = hw; }
    if let Some(width) = input.ap_channel_width { updated.ap_channel_width = width; }
    if let Some(sec) = input.ap_security { updated.ap_security = sec; }

    // Re-verify collisions (excluding itself)
    for (i, s) in stacks.iter().enumerate() {
        if i == idx { continue; }
        if s.ap_iface == updated.ap_iface {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("WiFi Interface '{}' is already in use", updated.ap_iface) }))).into_response();
        }
        if s.subnet == updated.subnet {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("Subnet '{}' is already allocated", updated.subnet) }))).into_response();
        }
        if s.routing_table == updated.routing_table {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("Routing table '{}' is already allocated", updated.routing_table) }))).into_response();
        }
        if s.ssid == updated.ssid {
            return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("SSID '{}' is already in use", updated.ssid) }))).into_response();
        }
    }

    // Regenerate compose config
    let creds = state.config_manager.load_credentials();
    if let Err(e) = state.docker_manager.generate_compose_file(&updated, &creds) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": format!("Compose generation failed: {}", e) }))).into_response();
    }

    // If running, warn that stack needs restart
    stacks[idx] = updated.clone();
    if let Err(e) = state.config_manager.save_stacks(&stacks) {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response();
    }

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

    Json(json!({ "success": true })).into_response()
}

// ─── Stack Actions ───────────────────────────────────────────────────────────

async fn start_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    // Regenerate compose config on start to pick up template or credential updates
    if let Ok(stacks) = state.config_manager.load_stacks() {
        if let Some(s) = stacks.into_iter().find(|x| x.id == id) {
            let creds = state.config_manager.load_credentials();
            let _ = state.docker_manager.generate_compose_file(&s, &creds);
        }
    }

    match state.docker_manager.start_stack(&id) {
        Ok(out) => Json(json!({ "success": true, "output": out })).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    }
}

async fn stop_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    match state.docker_manager.stop_stack(&id) {
        Ok(out) => Json(json!({ "success": true, "output": out })).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e }))).into_response(),
    }
}

async fn restart_stack(Path(id): Path<String>, State(state): State<AppState>) -> impl IntoResponse {
    match state.docker_manager.restart_stack(&id) {
        Ok(out) => Json(json!({ "success": true, "output": out })).into_response(),
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
    // Do not return password/key values directly for security, just let user know if they exist
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

async fn get_health(State(state): State<AppState>) -> impl IntoResponse {
    let docker_output = Command::new("docker").arg("ps").output();
    let docker_ok = docker_output.is_ok() && docker_output.unwrap().status.success();

    Json(json!({
        "status": "healthy",
        "docker_socket_reachable": docker_ok,
        "host_project_dir_defaulted": state.host_project_dir_defaulted
    }))
}
