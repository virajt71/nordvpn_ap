import { useEffect, useState } from 'react';
import { RefreshCw, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useVpn } from './vpn-provider';
import type { Logs } from '@/lib/vpn';
const tabs: { key: keyof Logs; label: string }[] = [{ key: 'gluetun', label: 'VPN tunnel' }, { key: 'wifi_ap', label: 'Wi-Fi AP' }, { key: 'adguard', label: 'AdGuard' }];
export function StackLogs({ id, onClose }: { id: string; onClose: () => void }) {
  const { request } = useVpn(); const [logs, setLogs] = useState<Logs | null>(null);
  const [tab, setTab] = useState<keyof Logs>('gluetun'); const [error, setError] = useState('');
  const load = () => { void request<Logs>(`/stacks/${encodeURIComponent(id)}/logs?tail=150`).then(data => { setLogs(data); setError(''); }).catch(caught => setError(caught instanceof Error ? caught.message : 'Could not load logs.')); };
  useEffect(() => { load(); const timer = window.setInterval(load, 5000); return () => window.clearInterval(timer); }, [id, request]);
  return <div className="fixed inset-0 z-50 flex items-center justify-center bg-background/85 p-3 md:p-6" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}><section role="dialog" aria-modal="true" aria-label={`Logs for ${id}`} className="flex max-h-[88vh] w-full max-w-4xl flex-col rounded-md border border-border bg-card p-5 shadow-2xl"><div className="flex items-center justify-between"><div><h2 className="font-mono text-lg font-bold">Live logs</h2><p className="text-xs text-muted-foreground">{id} · refreshes every 5 seconds</p></div><Button variant="ghost" size="icon" aria-label="Close" onClick={onClose}><X /></Button></div><div className="my-5 flex flex-wrap items-center gap-2">{tabs.map(item => <Button key={item.key} size="sm" variant={tab === item.key ? 'default' : 'outline'} onClick={() => setTab(item.key)}>{item.label}</Button>)}<Button variant="ghost" size="icon" className="ml-auto" title="Refresh logs" aria-label="Refresh logs" onClick={load}><RefreshCw /></Button></div>{error && <p role="alert" className="mb-2 text-xs text-warning">{error}</p>}<pre className="min-h-64 overflow-auto rounded-md border border-border bg-background/60 p-4 font-mono text-xs leading-relaxed text-muted-foreground">{logs?.[tab] || 'No log entries from this container.'}</pre></section></div>;
}
