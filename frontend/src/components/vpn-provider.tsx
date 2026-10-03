import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { vpnRequest, type Health, type Stack, type WifiInterface } from '@/lib/vpn';

type VpnContextValue = {
  stacks: Stack[]; interfaces: WifiInterface[]; health: Health | null; loading: boolean;
  error: string; token: string; setToken: (value: string) => void;
  refresh: () => Promise<void>; notify: (message: string) => void; notice: string;
  request: <T>(path: string, options?: RequestInit) => Promise<T>;
};
const VpnContext = createContext<VpnContextValue | null>(null);

export function VpnProvider({ children }: { children: ReactNode }) {
  const [stacks, setStacks] = useState<Stack[]>([]);
  const [interfaces, setInterfaces] = useState<WifiInterface[]>([]);
  const [health, setHealth] = useState<Health | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [token, setToken] = useState('');
  const [notice, setNotice] = useState('');
  const request = useCallback(<T,>(path: string, options: RequestInit = {}) => vpnRequest<T>(path, token, options), [token]);
  const notify = useCallback((message: string) => { setNotice(message); window.setTimeout(() => setNotice(''), 5500); }, []);
  const refresh = useCallback(async () => {
    try {
      const nextHealth = await request<Health>('/health');
      setHealth(nextHealth);
      const [nextStacks, nextInterfaces] = await Promise.all([
        request<Stack[]>('/stacks'), request<WifiInterface[]>('/wifi/interfaces'),
      ]);
      setStacks(nextStacks); setInterfaces(nextInterfaces); setError('');
    } catch (caught) {
      setHealth(null); setStacks([]); setInterfaces([]);
      setError(caught instanceof Error ? caught.message : 'Could not connect to the Rust service.');
    } finally { setLoading(false); }
  }, [request]);
  useEffect(() => { void refresh(); const timer = window.setInterval(() => void refresh(), 30000); return () => window.clearInterval(timer); }, [refresh]);
  useEffect(() => {
    if (!health) return;
    let socket: WebSocket | null = null;
    try {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      socket = new WebSocket(`${protocol}//${window.location.host}/ws/stacks`);
      socket.onmessage = (event) => {
        try {
          const snapshot = JSON.parse(event.data);
          if (Array.isArray(snapshot)) setStacks(snapshot);
        } catch { /* ignore malformed snapshots */ }
      };
      socket.onerror = () => { /* ignore socket errors */ };
    } catch {
      /* ignore socket initialization failures */
    }
    return () => {
      if (socket) {
        try { socket.close(); } catch { /* ignore */ }
      }
    };
  }, [health?.status]);
  return <VpnContext.Provider value={{ stacks, interfaces, health, loading, error, token, setToken, refresh, notify, notice, request }}>{children}</VpnContext.Provider>;
}
export function useVpn() {
  const context = useContext(VpnContext);
  if (!context) throw new Error('VPN context missing');
  return context;
}
