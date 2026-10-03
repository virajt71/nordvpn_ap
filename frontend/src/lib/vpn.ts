export type Stack = {
  id: string; ssid: string; password: string; ap_iface: string; vpn_type: string;
  vpn_country: string; vpn_city?: string | null; subnet: string; routing_table: number;
  ap_channel: number; ap_hw_mode: string; ap_channel_width: number;
  ap_security: string; auto_reconnect_12h: boolean; last_reconnect_at?: number;
  status: 'running' | 'stopped' | 'starting' | 'error'; vpn_ip: string | null;
  containers: { name: string; status: string }[];
};
export type WifiInterface = {
  name: string; vendor_model: string; supports_ap: boolean; supports_2_4ghz: boolean;
  supports_5ghz: boolean; supports_n: boolean; supports_ac: boolean;
  supports_ax: boolean; supports_wpa3: boolean; default_channel: number;
  default_hw_mode: string; default_width: number;
};
export type Health = { status: string; docker_socket_reachable: boolean; host_project_dir_defaulted: boolean; total_stacks: number; active_stacks: number };
export type Credentials = { has_openvpn_user: boolean; has_openvpn_password: boolean; has_wireguard_private_key: boolean };
export type Logs = { gluetun: string; adguard: string; wifi_ap: string };
export type Location = { name: string; code: string; cities?: { name: string }[] };

export async function vpnRequest<T>(path: string, token: string, options: RequestInit = {}): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`/api${path}`, {
      ...options,
      cache: 'no-store',
      headers: { ...(options.body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...options.headers },
    });
  } catch {
    throw new Error('Cannot reach the Rust service. Open this interface from your Rust server.');
  }
  if (response.status === 401) throw new Error('API token required or incorrect. Enter the AP_API_TOKEN to reconnect.');
  const contentType = response.headers.get('content-type') || '';
  if (!contentType.includes('application/json')) throw new Error('Rust API unavailable at this address. Serve this interface from the Rust server.');
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error || `Request failed (${response.status})`);
  return data as T;
}
