use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use tracing::info;

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct Stack {
    pub id: String, // unique alphanumeric stack identifier (corresponds to COUNTRY name in script)
    pub ssid: String,
    pub password: String,
    pub ap_iface: String,
    pub vpn_type: String, // "wireguard" or "openvpn"
    pub vpn_city: String,  // e.g. "Chicago" or "Germany"
    pub subnet: String,    // e.g. "192.168.60.0/24" (auto-allocated if empty)
    pub routing_table: u8, // e.g. 100 (auto-allocated if 0)
    pub ap_channel: u8,
    pub ap_hw_mode: String,
    pub ap_channel_width: u8,
    pub ap_security: String,
    #[serde(default)]
    pub auto_reconnect_12h: bool,
    #[serde(default)]
    pub last_reconnect_at: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Credentials {
    pub openvpn_user: Option<String>,
    pub openvpn_password: Option<String>,
    pub wireguard_private_key: Option<String>,
}

pub struct ConfigManager {
    data_dir: PathBuf,
    project_root: PathBuf,
}

impl ConfigManager {
    pub fn new(project_root: &Path) -> Self {
        let data_dir = project_root.join("data");
        if !data_dir.exists() {
            let _ = fs::create_dir_all(&data_dir);
        }
        Self {
            data_dir,
            project_root: project_root.to_path_buf(),
        }
    }

    fn stacks_path(&self) -> PathBuf {
        self.data_dir.join("stacks.json")
    }

    fn credentials_path(&self) -> PathBuf {
        self.data_dir.join("credentials.json")
    }

    pub fn load_stacks(&self) -> Result<Vec<Stack>, String> {
        let path = self.stacks_path();
        if !path.exists() {
            return Ok(Vec::new());
        }
        let content = fs::read_to_string(&path)
            .map_err(|e| format!("Failed to read stacks.json: {}", e))?;
        serde_json::from_str(&content)
            .map_err(|e| format!("Failed to parse stacks.json: {}", e))
    }

    pub fn save_stacks(&self, stacks: &[Stack]) -> Result<(), String> {
        let path = self.stacks_path();
        let content = serde_json::to_string_pretty(stacks)
            .map_err(|e| format!("Failed to serialize stacks: {}", e))?;
        fs::write(&path, content)
            .map_err(|e| format!("Failed to write stacks.json: {}", e))
    }

    pub fn load_credentials(&self) -> Credentials {
        let path = self.credentials_path();
        let mut loaded = None;

        if path.exists() {
            if let Ok(content) = fs::read_to_string(&path) {
                if let Ok(creds) = serde_json::from_str::<Credentials>(&content) {
                    loaded = Some(creds);
                }
            }
        }

        let creds = match loaded {
            Some(c) => c,
            None => {
                // Fallback to reading from .env.credentials at project root
                let fallback_path = self.project_root.join(".env.credentials");
                let mut openvpn_user = None;
                let mut openvpn_password = None;
                let mut wireguard_private_key = None;

                if fallback_path.exists() {
                    if let Ok(content) = fs::read_to_string(&fallback_path) {
                        for line in content.lines() {
                            let parts: Vec<&str> = line.splitn(2, '=').collect();
                            if parts.len() == 2 {
                                let key = parts[0].trim();
                                let val = parts[1].trim().trim_matches('"').trim_matches('\'').to_string();
                                match key {
                                    "OPENVPN_USER" => openvpn_user = Some(val),
                                    "OPENVPN_PASSWORD" => openvpn_password = Some(val),
                                    "WIREGUARD_PRIVATE_KEY" => wireguard_private_key = Some(val),
                                    _ => {}
                                }
                            }
                        }
                    }
                }

                Credentials {
                    openvpn_user,
                    openvpn_password,
                    wireguard_private_key,
                }
            }
        };

        if !path.exists() {
            let _ = self.save_credentials(&creds);
        }

        creds
    }

    pub fn save_credentials(&self, creds: &Credentials) -> Result<(), String> {
        let path = self.credentials_path();
        let content = serde_json::to_string_pretty(creds)
            .map_err(|e| format!("Failed to serialize credentials: {}", e))?;
        fs::write(&path, content)
            .map_err(|e| format!("Failed to write credentials.json: {}", e))
    }

    /// Automatically allocate next available subnet and routing table ID
    pub fn allocate_resources(&self, stacks: &[Stack]) -> (String, u8) {
        let mut used_subnets = HashSet::new();
        let mut used_tables = HashSet::new();

        for s in stacks {
            used_tables.insert(s.routing_table);
            // extract the octet from "192.168.X.0/24" or similar
            if let Some(octet) = s.subnet.split('.').nth(2) {
                if let Ok(o) = octet.parse::<u8>() {
                    used_subnets.insert(o);
                }
            }
        }

        // Find next free routing table ID starting at 100
        let mut routing_table = 100;
        while used_tables.contains(&routing_table) {
            routing_table += 1;
        }

        // Find next free subnet octet starting at 60
        let mut subnet_octet = 60;
        while used_subnets.contains(&subnet_octet) {
            subnet_octet += 1;
        }

        let subnet = format!("192.168.{}.0/24", subnet_octet);

        info!(
            "Auto-allocated routing_table={} and subnet={}",
            routing_table, subnet
        );
        (subnet, routing_table)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_allocation_empty() {
        let temp_dir = std::env::temp_dir();
        let manager = ConfigManager::new(&temp_dir);
        let stacks = Vec::new();
        let (subnet, table) = manager.allocate_resources(&stacks);
        assert_eq!(subnet, "192.168.60.0/24");
        assert_eq!(table, 100);
    }

    #[test]
    fn test_allocation_occupied() {
        let temp_dir = std::env::temp_dir();
        let manager = ConfigManager::new(&temp_dir);
        let stacks = vec![
            Stack {
                id: "test1".to_string(),
                ssid: "ssid1".to_string(),
                password: "pass12345".to_string(),
                ap_iface: "wlan0".to_string(),
                vpn_type: "wireguard".to_string(),
                vpn_city: "Chicago".to_string(),
                subnet: "192.168.60.0/24".to_string(),
                routing_table: 100,
                ap_channel: 6,
                ap_hw_mode: "g".to_string(),
                ap_channel_width: 20,
                ap_security: "wpa2".to_string(),
                auto_reconnect_12h: false,
                last_reconnect_at: 0,
            },
            Stack {
                id: "test2".to_string(),
                ssid: "ssid2".to_string(),
                password: "pass12345".to_string(),
                ap_iface: "wlan1".to_string(),
                vpn_type: "wireguard".to_string(),
                vpn_city: "Detroit".to_string(),
                subnet: "192.168.61.0/24".to_string(),
                routing_table: 101,
                ap_channel: 1,
                ap_hw_mode: "g".to_string(),
                ap_channel_width: 20,
                ap_security: "wpa2".to_string(),
                auto_reconnect_12h: false,
                last_reconnect_at: 0,
            },
        ];
        let (subnet, table) = manager.allocate_resources(&stacks);
        assert_eq!(subnet, "192.168.62.0/24");
        assert_eq!(table, 102);
    }
}
