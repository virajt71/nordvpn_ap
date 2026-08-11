use serde::{Deserialize, Serialize};
use std::process::Command;
use std::fs;
use tracing::warn;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WifiInterface {
    pub name: String,
    pub vendor_model: String,
    pub supports_ap: bool,
    pub supports_2_4ghz: bool,
    pub supports_5ghz: bool,
    pub supports_n: bool,
    pub supports_ac: bool,
    pub supports_ax: bool,
    pub supports_wpa3: bool,
    pub default_channel: u8,
    pub default_hw_mode: String,
    pub default_width: u8,
}

pub fn list_wifi_interfaces() -> Vec<WifiInterface> {
    let mut interfaces = Vec::new();
    let sys_net = "/sys/class/net";
    
    let entries = match fs::read_dir(sys_net) {
        Ok(e) => e,
        Err(_) => return interfaces,
    };

    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let wireless_path = entry.path().join("wireless");
        if wireless_path.exists() {
            // It is a wireless interface. Let's query vendor/model details from sysfs/udev properties if possible.
            let vendor_model = get_vendor_model(&name);
            let mut info = audit_interface(&name);
            info.vendor_model = vendor_model;
            interfaces.push(info);
        }
    }

    interfaces
}

fn get_vendor_model(iface: &str) -> String {
    // Attempt to read via udevadm or just default
    let udev_output = Command::new("udevadm")
        .args(["info", "-q", "property", "-p", &format!("/sys/class/net/{}", iface)])
        .output();

    if let Ok(out) = udev_output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        let mut vendor = "";
        let mut model = "";
        let mut bus = "";

        for line in stdout.lines() {
            if line.starts_with("ID_VENDOR_FROM_DATABASE=") {
                vendor = line.split('=').nth(1).unwrap_or("");
            } else if line.starts_with("ID_MODEL_FROM_DATABASE=") {
                model = line.split('=').nth(1).unwrap_or("");
            } else if line.starts_with("ID_BUS=") {
                bus = line.split('=').nth(1).unwrap_or("");
            }
        }

        let desc = format!("{} {}", vendor, model).trim().to_string();
        if !desc.is_empty() {
            let bus_desc = match bus {
                "pci" => " (Built-in)",
                "usb" => " (External)",
                _ => "",
            };
            return format!("{}{}", desc, bus_desc);
        }
    }

    "Wireless Interface".to_string()
}

fn audit_interface(iface: &str) -> WifiInterface {
    let mut default_interface = WifiInterface {
        name: iface.to_string(),
        vendor_model: "Wireless Interface".to_string(),
        supports_ap: false,
        supports_2_4ghz: false,
        supports_5ghz: false,
        supports_n: false,
        supports_ac: false,
        supports_ax: false,
        supports_wpa3: false,
        default_channel: 6,
        default_hw_mode: "g".to_string(),
        default_width: 20,
    };

    // Find the wiphy phy name
    let phy_output = Command::new("iw")
        .args(["dev", iface, "info"])
        .output();

    let mut phy_name = String::new();
    if let Ok(out) = phy_output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            if line.contains("wiphy") {
                if let Some(num) = line.split_whitespace().last() {
                    phy_name = format!("phy{}", num);
                }
            }
        }
    }

    if phy_name.is_empty() {
        // Fallback checks from /sys/class/net
        let index_path = format!("/sys/class/net/{}/phy80211/index", iface);
        if let Ok(index) = fs::read_to_string(index_path) {
            phy_name = format!("phy{}", index.trim());
        }
    }

    if phy_name.is_empty() {
        return default_interface;
    }

    let phy_info = Command::new("iw")
        .args(["phy", &phy_name, "info"])
        .output();

    if let Ok(out) = phy_info {
        let stdout = String::from_utf8_lossy(&out.stdout);
        
        // Parse AP support
        let mut in_modes = false;
        let mut supports_ap = false;
        let mut supports_2_4ghz = false;
        let mut supports_5ghz = false;
        let mut supports_n = false;
        let mut supports_ac = false;
        let mut supports_ax = false;

        for line in stdout.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("Supported interface modes:") {
                in_modes = true;
                continue;
            }
            if in_modes {
                if trimmed.starts_with('*') {
                    if trimmed.contains("AP") {
                        supports_ap = true;
                    }
                } else if !trimmed.is_empty() {
                    in_modes = false; // exit supported modes block
                }
            }

            if trimmed.contains("Band 1:") {
                supports_2_4ghz = true;
            }
            if trimmed.contains("Band 2:") {
                supports_5ghz = true;
            }
            if trimmed.contains("HT20/HT40") {
                supports_n = true;
            }
            if trimmed.contains("VHT Capabilities") {
                supports_ac = true;
            }
            if trimmed.contains("HE Capabilities") {
                supports_ax = true;
            }
        }

        let mut supports_wpa3 = false;
        if stdout.to_lowercase().contains("sae") || stdout.contains("00-0f-ac:8") {
            supports_wpa3 = true;
        }

        default_interface.supports_ap = supports_ap;
        default_interface.supports_2_4ghz = supports_2_4ghz;
        default_interface.supports_5ghz = supports_5ghz;
        default_interface.supports_n = supports_n;
        default_interface.supports_ac = supports_ac;
        default_interface.supports_ax = supports_ax;
        default_interface.supports_wpa3 = supports_wpa3;

        // Determine recommended defaults
        if supports_5ghz {
            default_interface.default_channel = 36;
            default_interface.default_hw_mode = if supports_ax {
                "ax".to_string()
            } else if supports_ac {
                "ac".to_string()
            } else {
                "a".to_string()
            };
            default_interface.default_width = if supports_ax || supports_ac { 80 } else { 40 };
        } else if supports_n {
            default_interface.default_channel = 1;
            default_interface.default_hw_mode = "g".to_string();
            default_interface.default_width = 20;
        } else {
            default_interface.default_channel = 6;
            default_interface.default_hw_mode = "g".to_string();
            default_interface.default_width = 20;
        }
    } else {
        warn!("Failed to query iw phy info for {}", phy_name);
    }

    default_interface
}
