use crate::config::{Credentials, Stack};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tracing::{info, error, warn};

pub struct DockerManager {
    project_root: PathBuf,
    host_project_dir: String,
}

impl DockerManager {
    pub fn new(project_root: &Path, host_project_dir: &str) -> Self {
        Self {
            project_root: project_root.to_path_buf(),
            host_project_dir: host_project_dir.to_string(),
        }
    }

    pub fn get_stack_dir(&self, id: &str) -> PathBuf {
        self.project_root.join("country").join(id)
    }

    pub fn generate_compose_file(&self, stack: &Stack, creds: &Credentials) -> Result<(), String> {
        let stack_dir = self.get_stack_dir(&stack.id);
        
        // Ensure directories exist
        fs::create_dir_all(stack_dir.join("gluetun-state"))
            .map_err(|e| format!("Failed to create gluetun-state dir: {}", e))?;
        fs::create_dir_all(stack_dir.join("adguard-work"))
            .map_err(|e| format!("Failed to create adguard-work dir: {}", e))?;
        
        let adguard_conf_dir = stack_dir.join("adguard-conf");
        fs::create_dir_all(&adguard_conf_dir)
            .map_err(|e| format!("Failed to create adguard-conf dir: {}", e))?;

        // Copy default AdGuardHome.yaml if missing
        let dest_adguard_yaml = adguard_conf_dir.join("AdGuardHome.yaml");
        if !dest_adguard_yaml.exists() {
            let src_adguard_yaml = self.project_root.join("access_point").join("AdGuardHome.yaml");
            if src_adguard_yaml.exists() {
                let _ = fs::copy(src_adguard_yaml, dest_adguard_yaml);
            }
        }

        // Host paths to use for compose mounts
        let host_stack_dir = format!("{}/country/{}", self.host_project_dir, stack.id);

        let vpn_user = creds.openvpn_user.as_deref().unwrap_or("");
        let vpn_pass = creds.openvpn_password.as_deref().unwrap_or("");
        let wg_key = creds.wireguard_private_key.as_deref().unwrap_or("");

        // Subnet calculation: find outbound subnet or default to 0.0.0.0/0
        let firewall_outbound_subnets = &stack.subnet;

        let location_env = resolve_location_env(stack);

        // Template string
        let compose_content = format!(
            r#"services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: gluetun-{id}
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - {host_stack_dir}/gluetun-state:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=nordvpn
      - VPN_TYPE={vpn_type}
      - OPENVPN_USER={vpn_user}
      - OPENVPN_PASSWORD={vpn_pass}
      - WIREGUARD_PRIVATE_KEY={wg_key}
      - {location_env}
      - FIREWALL_OUTBOUND_SUBNETS={firewall_outbound_subnets}
      - DNS_SERVER=off
      - DNS_UPSTREAM_RESOLVER_TYPE=plain
      - DNS_UPSTREAM_PLAIN_ADDRESSES=127.0.0.1:53
    sysctls:
      - net.ipv4.ip_forward=1
    healthcheck:
      test: ["CMD", "sh", "-c", "ip link show tun0 2>/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    restart: unless-stopped

  adguard:
    image: adguard/adguardhome
    container_name: adguard-{id}
    network_mode: service:gluetun
    volumes:
      - {host_stack_dir}/adguard-work:/opt/adguardhome/work
      - {host_stack_dir}/adguard-conf:/opt/adguardhome/conf
    # Must join gluetun's netns as soon as it *starts* (netns exists then),
    # NOT when it is healthy: gluetun's own healthcheck resolves DNS via
    # 127.0.0.1:53, which is this AdGuard instance. Waiting for healthy
    # creates a deadlock: gluetun can't be healthy without AdGuard, AdGuard
    # won't start until gluetun is healthy -> VPN restart loop (DNS refused).
    depends_on:
      gluetun:
        condition: service_started
    restart: unless-stopped

  wifi-ap:
    build:
      context: ../..
      dockerfile: access_point/Dockerfile.wifi-ap
    image: wifi-ap-image-{id}
    container_name: wifi-ap-{id}
    network_mode: host
    pid: host
    privileged: true
    environment:
      - AP_IFACE={ap_iface}
      - AP_SSID={ssid}
      - AP_PASSWORD={password}
      - AP_CHANNEL={ap_channel}
      - AP_HW_MODE={ap_hw_mode}
      - AP_CHANNEL_WIDTH={ap_channel_width}
      - AP_IP={ap_ip}
      - AP_SUBNET={ap_subnet}
      - AP_SECURITY={ap_security}
      - ROUTING_TABLE={routing_table}
      - COUNTRY={id}
    depends_on:
      gluetun:
        condition: service_healthy
    restart: unless-stopped
"#,
            id = stack.id,
            host_stack_dir = host_stack_dir,
            vpn_type = stack.vpn_type,
            vpn_user = vpn_user,
            vpn_pass = vpn_pass,
            wg_key = wg_key,
            location_env = location_env,
            firewall_outbound_subnets = firewall_outbound_subnets,
            ap_iface = stack.ap_iface,
            ssid = stack.ssid,
            password = stack.password,
            ap_channel = stack.ap_channel,
            ap_hw_mode = stack.ap_hw_mode,
            ap_channel_width = stack.ap_channel_width,
            // Gateway IP is typically the first IP in the subnet
            ap_ip = get_gateway_ip(&stack.subnet),
            ap_subnet = stack.subnet,
            ap_security = stack.ap_security,
            routing_table = stack.routing_table,
        );

        let compose_path = stack_dir.join("docker-compose.yaml");
        fs::write(compose_path, compose_content)
            .map_err(|e| format!("Failed to write docker-compose.yaml: {}", e))
    }

    pub fn start_stack(&self, id: &str) -> Result<String, String> {
        let compose_path = self.get_stack_dir(id).join("docker-compose.yaml");
        if !compose_path.exists() {
            return Err("docker-compose.yaml not found. Generate it first.".to_string());
        }

        info!("Starting docker compose for stack {}", id);
        let output = Command::new("docker")
            .args(["compose", "-f", &compose_path.to_string_lossy(), "up", "-d", "--build"])
            .output()
            .map_err(|e| format!("Failed to run docker compose: {}", e))?;

        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

        if !output.status.success() {
            error!(
                "Docker compose up failed for stack {}:\nSTDOUT:\n{}\nSTDERR:\n{}",
                id, stdout, stderr
            );
            return Err(format!("Docker Compose up failed: {}", stderr));
        }

        Ok(stdout)
    }

    pub fn stop_stack(&self, id: &str) -> Result<String, String> {
        let compose_path = self.get_stack_dir(id).join("docker-compose.yaml");
        if !compose_path.exists() {
            return Err("docker-compose.yaml not found.".to_string());
        }

        info!("Stopping docker compose for stack {}", id);
        let output = Command::new("docker")
            .args(["compose", "-f", &compose_path.to_string_lossy(), "stop"])
            .output()
            .map_err(|e| format!("Failed to run docker compose stop: {}", e))?;

        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

        if !output.status.success() {
            error!(
                "Docker compose stop failed for stack {}:\nSTDOUT:\n{}\nSTDERR:\n{}",
                id, stdout, stderr
            );
            return Err(format!("Docker Compose stop failed: {}", stderr));
        }

        Ok(stdout)
    }

    pub fn destroy_stack(&self, id: &str) -> Result<(), String> {
        let compose_path = self.get_stack_dir(id).join("docker-compose.yaml");
        if compose_path.exists() {
            info!("Tearing down docker compose for stack {}", id);
            let output = Command::new("docker")
                .args(["compose", "-f", &compose_path.to_string_lossy(), "down", "--rmi", "all", "--remove-orphans"])
                .output()
                .map_err(|e| format!("Failed to run docker compose down: {}", e))?;
            
            if !output.status.success() {
                warn!("Docker compose down failed for {}: {}", id, String::from_utf8_lossy(&output.stderr));
            }
        }

        // Clean containers manually just in case
        for name in &[format!("gluetun-{}", id), format!("adguard-{}", id), format!("wifi-ap-{}", id)] {
            let _ = Command::new("docker").args(["rm", "-f", name]).output();
        }
        let _ = Command::new("docker").args(["image", "rm", "-f", &format!("wifi-ap-image-{}", id)]).output();

        // Delete configuration folder
        let stack_dir = self.get_stack_dir(id);
        if stack_dir.exists() {
            // Root owned files could exist inside adguard-work, etc. Let's delete them via container
            let _ = Command::new("docker")
                .args([
                    "run", "--rm", 
                    "-v", &format!("{}:/mnt/country", self.project_root.join("country").to_string_lossy()),
                    "debian:bullseye-slim", "rm", "-rf", &format!("/mnt/country/{}", id)
                ])
                .output();
            let _ = fs::remove_dir_all(&stack_dir);
        }

        Ok(())
    }

    pub fn restart_stack(&self, id: &str) -> Result<String, String> {
        info!("Restarting stack {} via stop & start sequence", id);
        let _ = self.stop_stack(id);
        self.start_stack(id)
    }

    pub fn inspect_container_status(&self, container_name: &str) -> Option<String> {
        let output = Command::new("docker")
            .args(["inspect", "--format", "{{.State.Status}}", container_name])
            .output()
            .ok()?;

        if output.status.success() {
            let status = String::from_utf8_lossy(&output.stdout).trim().to_string();
            Some(status)
        } else {
            None
        }
    }

    pub fn get_container_logs(&self, container_name: &str, tail: usize) -> Result<String, String> {
        let output = Command::new("docker")
            .args(["logs", "--tail", &tail.to_string(), container_name])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| format!("Failed to run docker logs: {}", e))?;

        // docker logs prints to stderr
        let mut logs = String::from_utf8_lossy(&output.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        logs.push_str(&stderr);
        Ok(logs)
    }

    pub fn get_vpn_ip(&self, id: &str) -> Option<String> {
        let container_name = format!("gluetun-{}", id);
        let output = Command::new("docker")
            .args([
                "exec",
                &container_name,
                "wget", "-qO-", "--timeout=5", "https://api.ipify.org"
            ])
            .output()
            .ok()?;

        if output.status.success() {
            let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !ip.is_empty() {
                return Some(ip);
            }
        }
        None
    }
}
// Utility to parse subnet and get first host IP. E.g. "192.168.60.0/24" -> "192.168.60.1"
fn get_gateway_ip(subnet: &str) -> String {
    let parts: Vec<&str> = subnet.split('/').next().unwrap_or("").split('.').collect();
    if parts.len() == 4 {
        format!("{}.{}.{}.1", parts[0], parts[1], parts[2])
    } else {
        "192.168.60.1".to_string()
    }
}

pub fn resolve_location_env(stack: &Stack) -> String {
    match &stack.vpn_city {
        Some(city) if !city.is_empty() && !city.eq_ignore_ascii_case(&stack.vpn_country) => {
            format!("SERVER_CITIES={}", city)
        }
        _ => {
            let country = if stack.vpn_country.is_empty() {
                &stack.id
            } else {
                &stack.vpn_country
            };
            format!("SERVER_COUNTRIES={}", country)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_location_env_country_only() {
        let stack = Stack {
            id: "india".to_string(),
            ssid: "Test".to_string(),
            password: "password123".to_string(),
            ap_iface: "wlan0".to_string(),
            vpn_type: "wireguard".to_string(),
            vpn_country: "india".to_string(),
            vpn_city: None,
            subnet: "192.168.60.0/24".to_string(),
            routing_table: 100,
            ap_channel: 6,
            ap_hw_mode: "g".to_string(),
            ap_channel_width: 20,
            ap_security: "wpa2".to_string(),
            auto_reconnect_12h: false,
            last_reconnect_at: 0,
        };
        assert_eq!(resolve_location_env(&stack), "SERVER_COUNTRIES=india");
    }

    #[test]
    fn test_resolve_location_env_city_equals_country() {
        let stack = Stack {
            id: "india".to_string(),
            ssid: "Test".to_string(),
            password: "password123".to_string(),
            ap_iface: "wlan0".to_string(),
            vpn_type: "wireguard".to_string(),
            vpn_country: "india".to_string(),
            vpn_city: Some("india".to_string()),
            subnet: "192.168.60.0/24".to_string(),
            routing_table: 100,
            ap_channel: 6,
            ap_hw_mode: "g".to_string(),
            ap_channel_width: 20,
            ap_security: "wpa2".to_string(),
            auto_reconnect_12h: false,
            last_reconnect_at: 0,
        };
        assert_eq!(resolve_location_env(&stack), "SERVER_COUNTRIES=india");
    }

    #[test]
    fn test_resolve_location_env_distinct_city() {
        let stack = Stack {
            id: "us".to_string(),
            ssid: "Test".to_string(),
            password: "password123".to_string(),
            ap_iface: "wlan0".to_string(),
            vpn_type: "wireguard".to_string(),
            vpn_country: "United States".to_string(),
            vpn_city: Some("Seattle".to_string()),
            subnet: "192.168.60.0/24".to_string(),
            routing_table: 100,
            ap_channel: 6,
            ap_hw_mode: "g".to_string(),
            ap_channel_width: 20,
            ap_security: "wpa2".to_string(),
            auto_reconnect_12h: false,
            last_reconnect_at: 0,
        };
        assert_eq!(resolve_location_env(&stack), "SERVER_CITIES=Seattle");
    }
}
