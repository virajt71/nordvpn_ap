import { useEffect, useState } from 'react';
import { Check, Copy, RefreshCw, Terminal, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useVpn } from './vpn-provider';
import type { Logs } from '@/lib/vpn';
import { copyToClipboard } from '@/lib/clipboard';

const tabs: { key: keyof Logs; label: string }[] = [
  { key: 'wifi_ap', label: 'Wi-Fi AP' },
  { key: 'gluetun', label: 'VPN Tunnel (Gluetun)' },
  { key: 'adguard', label: 'AdGuard DNS' },
];

export function StackLogs({ id, onClose }: { id: string; onClose: () => void }) {
  const { stacks, request, notify } = useVpn();
  const stack = stacks.find(s => s.id === id);
  const isRepeater = stack?.mode === 'repeater' || !stack?.vpn_enabled;

  const availableTabs: { key: keyof Logs; label: string }[] = isRepeater
    ? [{ key: 'wifi_ap', label: 'Repeater AP' }]
    : [
        { key: 'wifi_ap', label: 'Wi-Fi AP' },
        { key: 'gluetun', label: 'VPN Tunnel (Gluetun)' },
        { key: 'adguard', label: 'AdGuard DNS' },
      ];

  const [logs, setLogs] = useState<Logs | null>(null);
  const [tab, setTab] = useState<keyof Logs>('wifi_ap');
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);
  const [loading, setLoading] = useState(false);

  const activeTab: keyof Logs = isRepeater ? 'wifi_ap' : tab;

  const load = async () => {
    setLoading(true);
    try {
      const data = await request<Logs>(`/stacks/${encodeURIComponent(id)}/logs?tail=150`);
      setLogs(data);
      setError('');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not load container logs.');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void load();
    const timer = window.setInterval(load, 5000);
    return () => window.clearInterval(timer);
  }, [id]);

  const copyCurrentLogs = async () => {
    const text = logs?.[activeTab] || '';
    if (!text) return;
    const ok = await copyToClipboard(text);
    if (ok) {
      setCopied(true);
      notify('Container logs copied to clipboard.');
      window.setTimeout(() => setCopied(false), 2000);
    } else {
      notify('Failed to copy to clipboard.');
    }
  };

  const currentLogText = logs?.[activeTab] || '';

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-background/85 p-3 md:p-6"
      onMouseDown={event => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-label={`Live logs for ${id}`}
        className="flex max-h-[90vh] w-full max-w-4xl flex-col rounded-lg border border-border bg-card p-5 shadow-2xl"
      >
        {/* ─── Header ──────────────────────────────────────────────────────── */}
        <div className="flex items-center justify-between pb-3 border-b border-border/60">
          <div className="flex items-center gap-2.5">
            <div className="grid size-8 place-items-center rounded bg-primary/10 text-primary">
              <Terminal className="size-4" />
            </div>
            <div>
              <h2 className="font-mono text-base font-bold text-foreground">
                Container Logs: {id} {isRepeater ? '(Repeater AP)' : ''}
              </h2>
              <p className="text-[11px] text-muted-foreground font-mono">
                Auto-refreshes every 5s · Tail: 150 lines
              </p>
            </div>
          </div>
          <Button variant="ghost" size="icon" aria-label="Close" onClick={onClose}>
            <X className="size-4" />
          </Button>
        </div>

        {/* ─── Tabs & Controls ─────────────────────────────────────────────── */}
        <div className="my-3 flex flex-wrap items-center justify-between gap-2">
          {availableTabs.length > 1 ? (
            <div className="flex items-center rounded-md border border-border bg-secondary/30 p-1">
              {availableTabs.map(item => (
                <button
                  key={item.key}
                  type="button"
                  onClick={() => setTab(item.key)}
                  className={`rounded px-3 py-1 font-mono text-xs transition-colors ${
                    activeTab === item.key
                      ? 'bg-card text-foreground font-semibold shadow-sm'
                      : 'text-muted-foreground hover:text-foreground'
                  }`}
                >
                  {item.label}
                </button>
              ))}
            </div>
          ) : (
            <div className="flex items-center gap-1.5 rounded-md border border-border bg-secondary/30 px-3 py-1 font-mono text-xs font-semibold text-foreground">
              <span>Repeater AP Service</span>
            </div>
          )}

          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={!currentLogText}
              onClick={copyCurrentLogs}
              className="text-xs font-mono"
            >
              {copied ? <Check className="size-3.5 text-success" /> : <Copy className="size-3.5" />}
              <span>{copied ? 'Copied' : 'Copy Logs'}</span>
            </Button>
            <Button
              variant="ghost"
              size="icon"
              title="Refresh now"
              aria-label="Refresh now"
              onClick={() => void load()}
            >
              <RefreshCw className={`size-3.5 ${loading ? 'animate-spin' : ''}`} />
            </Button>
          </div>
        </div>

        {error && <p role="alert" className="mb-2 text-xs text-warning">{error}</p>}

        {/* ─── Monospace Terminal Viewer ───────────────────────────────────── */}
        <div className="flex-1 min-h-[320px] max-h-[60vh] overflow-auto rounded-md border border-border bg-black/75 p-4 font-mono text-xs leading-relaxed text-zinc-300 selection:bg-primary/30">
          <pre className="whitespace-pre-wrap break-all font-mono">
            {currentLogText || (
              <span className="text-zinc-500 italic">No output received from {activeTab} container.</span>
            )}
          </pre>
        </div>
      </section>
    </div>
  );
}
