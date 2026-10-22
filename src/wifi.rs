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

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ScannedAccessPoint {
    pub ssid: String,
    pub bssid: String,
    pub signal_dbm: i32,
    pub signal_percent: u8,
    pub frequency: u32,
    pub channel: u8,
    pub security: String,
}

pub fn dbm_to_percent(dbm: i32) -> u8 {
    if dbm <= -100 {
        0
    } else if dbm >= -50 {
        100
    } else {
        (2 * (dbm + 100)).clamp(0, 100) as u8
    }
}

pub fn freq_to_channel(freq: u32) -> u8 {
    if freq == 2484 {
        14
    } else if (2412..=2472).contains(&freq) {
        ((freq - 2407) / 5) as u8
    } else if (5170..=5885).contains(&freq) {
        ((freq - 5000) / 5) as u8
    } else {
        0
    }
}

pub fn parse_iw_scan(output: &str) -> Vec<ScannedAccessPoint> {
    let mut results: Vec<ScannedAccessPoint> = Vec::new();
    let mut current_bssid = String::new();
    let mut current_ssid = String::new();
    let mut current_freq: u32 = 0;
    let mut current_signal: i32 = -100;
    let mut current_channel: u8 = 0;
    let mut has_privacy = false;
    let mut has_rsn = false;
    let mut has_sae = false;
    let mut has_wpa = false;

    let finish_entry = |results: &mut Vec<ScannedAccessPoint>,
                        bssid: &str,
                        ssid: &str,
                        freq: u32,
                        signal: i32,
                        mut chan: u8,
                        privacy: bool,
                        rsn: bool,
                        sae: bool,
                        wpa: bool| {
        let clean_ssid = ssid.trim();
        // Skip hidden networks, null bytes, driver decoding errors (<invalid...), or unprintable control chars
        if clean_ssid.is_empty()
            || clean_ssid.contains('\0')
            || clean_ssid.starts_with("<invalid")
            || clean_ssid.chars().any(|c| c.is_control())
        {
            return;
        }

        if chan == 0 && freq > 0 {
            chan = freq_to_channel(freq);
        }

        let security = if rsn {
            if sae {
                "WPA3".to_string()
            } else {
                "WPA2".to_string()
            }
        } else if wpa {
            "WPA".to_string()
        } else if privacy {
            "WEP".to_string()
        } else {
            "Open".to_string()
        };

        let ap = ScannedAccessPoint {
            ssid: clean_ssid.to_string(),
            bssid: bssid.to_string(),
            signal_dbm: signal,
            signal_percent: dbm_to_percent(signal),
            frequency: freq,
            channel: chan,
            security,
        };

        // If SSID already exists, keep the one with stronger signal
        if let Some(existing) = results.iter_mut().find(|a| a.ssid == ap.ssid) {
            if ap.signal_dbm > existing.signal_dbm {
                *existing = ap;
            }
        } else {
            results.push(ap);
        }
    };

    for line in output.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("BSS ") {
            if !current_bssid.is_empty() {
                finish_entry(
                    &mut results,
                    &current_bssid,
                    &current_ssid,
                    current_freq,
                    current_signal,
                    current_channel,
                    has_privacy,
                    has_rsn,
                    has_sae,
                    has_wpa,
                );
            }
            let bssid_part = trimmed.strip_prefix("BSS ").unwrap_or("");
            let bssid = bssid_part
                .split(|c: char| c.is_whitespace() || c == '(')
                .next()
                .unwrap_or("")
                .trim();
            current_bssid = bssid.to_string();
            current_ssid.clear();
            current_freq = 0;
            current_signal = -100;
            current_channel = 0;
            has_privacy = false;
            has_rsn = false;
            has_sae = false;
            has_wpa = false;
        } else if trimmed.starts_with("freq:") {
            if let Some(val) = trimmed.strip_prefix("freq:") {
                let first_token = val.trim().split('.').next().unwrap_or("");
                current_freq = first_token.parse::<u32>().unwrap_or(0);
            }
        } else if trimmed.starts_with("signal:") {
            if let Some(val) = trimmed.strip_prefix("signal:") {
                if let Some(num_str) = val.split("dBm").next() {
                    if let Ok(f) = num_str.trim().parse::<f32>() {
                        current_signal = f.round() as i32;
                    }
                }
            }
        } else if trimmed.starts_with("SSID:") {
            let ssid = trimmed.strip_prefix("SSID:").unwrap_or("").trim();
            current_ssid = ssid.to_string();
        } else if trimmed.starts_with("capability:") {
            if trimmed.contains("Privacy") {
                has_privacy = true;
            }
        } else if trimmed.starts_with("RSN:") {
            has_rsn = true;
        } else if trimmed.starts_with("WPA:") {
            has_wpa = true;
        } else if trimmed.contains("SAE") || trimmed.contains("00-0f-ac:8") {
            has_sae = true;
        } else if trimmed.starts_with("DS Parameter set: channel") {
            if let Some(ch_str) = trimmed.split("channel").nth(1) {
                current_channel = ch_str.trim().parse::<u8>().unwrap_or(0);
            }
        } else if trimmed.starts_with("* primary channel:") {
            if let Some(ch_str) = trimmed.split(':').nth(1) {
                current_channel = ch_str.trim().parse::<u8>().unwrap_or(0);
            }
        }
    }

    if !current_bssid.is_empty() {
        finish_entry(
            &mut results,
            &current_bssid,
            &current_ssid,
            current_freq,
            current_signal,
            current_channel,
            has_privacy,
            has_rsn,
            has_sae,
            has_wpa,
        );
    }

    results.sort_by_key(|b| std::cmp::Reverse(b.signal_dbm));
    results
}

pub fn scan_access_points(preferred_iface: Option<&str>) -> Vec<ScannedAccessPoint> {
    let mut interfaces_to_try = Vec::new();

    if let Some(iface) = preferred_iface {
        let clean = iface.trim();
        if !clean.is_empty() {
            interfaces_to_try.push(clean.to_string());
        }
    }

    for iface in list_wifi_interfaces() {
        if !interfaces_to_try.contains(&iface.name) {
            interfaces_to_try.push(iface.name);
        }
    }

    for iface in &interfaces_to_try {
        // Active scan if allowed
        let _ = Command::new("iw")
            .args(["dev", iface, "scan"])
            .output();

        // Cached/active dump
        let dump_res = Command::new("iw")
            .args(["dev", iface, "scan", "dump"])
            .output();

        if let Ok(out) = dump_res {
            if out.status.success() {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let aps = parse_iw_scan(&stdout);
                if !aps.is_empty() {
                    return aps;
                }
            }
        }
    }

    // NetworkManager nmcli fallback
    let nmcli_res = Command::new("nmcli")
        .args(["-t", "-f", "SSID,BSSID,CHAN,SIGNAL,SECURITY", "dev", "wifi", "list"])
        .output();

    if let Ok(out) = nmcli_res {
        if out.status.success() {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let mut results = Vec::new();
            for line in stdout.lines() {
                let parts: Vec<&str> = line.split(':').collect();
                if parts.len() >= 5 {
                    let ssid = parts[0].trim();
                    let bssid = parts[1].trim();
                    let chan = parts[2].trim().parse::<u8>().unwrap_or(0);
                    let signal_pct = parts[3].trim().parse::<u8>().unwrap_or(0);
                    let sec = parts[4].trim();
                    if !ssid.is_empty()
                        && !ssid.contains('\0')
                        && !ssid.starts_with("<invalid")
                        && !ssid.chars().any(|c| c.is_control())
                    {
                        let signal_dbm = -100 + (signal_pct as i32 / 2);
                        let ap = ScannedAccessPoint {
                            ssid: ssid.to_string(),
                            bssid: bssid.to_string(),
                            signal_dbm,
                            signal_percent: signal_pct,
                            frequency: if chan > 14 { 5000 + (chan as u32 * 5) } else { 2407 + (chan as u32 * 5) },
                            channel: chan,
                            security: if sec.contains("WPA3") {
                                "WPA3".to_string()
                            } else if sec.contains("WPA2") {
                                "WPA2".to_string()
                            } else if sec.contains("WPA") {
                                "WPA".to_string()
                            } else {
                                "Open".to_string()
                            },
                        };
                        if !results.iter().any(|a: &ScannedAccessPoint| a.ssid == ap.ssid) {
                            results.push(ap);
                        }
                    }
                }
            }
            if !results.is_empty() {
                results.sort_by_key(|b| std::cmp::Reverse(b.signal_dbm));
                return results;
            }
        }
    }

    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_freq_to_channel() {
        assert_eq!(freq_to_channel(2412), 1);
        assert_eq!(freq_to_channel(2437), 6);
        assert_eq!(freq_to_channel(2462), 11);
        assert_eq!(freq_to_channel(2472), 13);
        assert_eq!(freq_to_channel(2484), 14);
        assert_eq!(freq_to_channel(5180), 36);
        assert_eq!(freq_to_channel(5200), 40);
        assert_eq!(freq_to_channel(5745), 149);
    }

    #[test]
    fn test_dbm_to_percent() {
        assert_eq!(dbm_to_percent(-50), 100);
        assert_eq!(dbm_to_percent(-40), 100);
        assert_eq!(dbm_to_percent(-60), 80);
        assert_eq!(dbm_to_percent(-75), 50);
        assert_eq!(dbm_to_percent(-100), 0);
        assert_eq!(dbm_to_percent(-110), 0);
    }

    #[test]
    fn test_parse_iw_scan() {
        let sample = r#"
BSS 8c:86:dd:94:e0:ea(on wlo1) -- associated
	freq: 2412.0
	capability: ESS Privacy ShortSlotTime RadioMeasure (0x1411)
	signal: -58.00 dBm
	SSID: Planck_EXT2
	DS Parameter set: channel 1
	RSN:	 * Version: 1
		 * Authentication suites: PSK
BSS 7e:8c:b5:24:23:ec(on wlp0s20u2)
	freq: 2472.0
	capability: ESS Privacy ShortPreamble ShortSlotTime RadioMeasure (0x1431)
	signal: -56.00 dBm
	SSID: TP-Link_23EC
	DS Parameter set: channel 13
	RSN:	 * Version: 1
		 * Authentication suites: PSK
BSS 00:00:00:00:00:00(on wlp0s20u2)
	freq: 2412.0
	signal: -90.00 dBm
	SSID: 
BSS aa:bb:cc:dd:ee:ff(on wlp0s20u2)
	freq: 2412.0
	signal: -45.00 dBm
	SSID: <invalid: 128 bytes: 8a 3b 4c>
"#;
        let parsed = parse_iw_scan(sample);
        assert_eq!(parsed.len(), 2);
        // Best signal first (-56 dBm before -58 dBm)
        assert_eq!(parsed[0].ssid, "TP-Link_23EC");
        assert_eq!(parsed[0].signal_dbm, -56);
        assert_eq!(parsed[0].channel, 13);
        assert_eq!(parsed[0].security, "WPA2");

        assert_eq!(parsed[1].ssid, "Planck_EXT2");
        assert_eq!(parsed[1].signal_dbm, -58);
        assert_eq!(parsed[1].channel, 1);
        assert_eq!(parsed[1].security, "WPA2");
    }
}

