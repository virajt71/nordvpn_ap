import { createFileRoute } from '@tanstack/react-router';
import { useState } from 'react';
import { LayoutGrid, List, Lock, RadioTower, RefreshCw, Wifi } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { OfflineNotice, PageHeading, StatusDot } from '@/components/vpn-shell';
import { useVpn } from '@/components/vpn-provider';

export const Route = createFileRoute('/interfaces')({
  head: () => ({
    meta: [
      { title: 'WiFi Interfaces | VPN AP Manager' },
      { name: 'description', content: 'Inspect wireless interface capabilities and access-point readiness.' },
      { property: 'og:title', content: 'VPN AP Manager WiFi Interfaces' },
      { property: 'og:description', content: 'Inspect wireless interface capabilities and access-point readiness.' },
      { property: 'og:type', content: 'website' },
      { name: 'twitter:card', content: 'summary_large_image' },
    ],
  }),
  component: InterfacesPage,
});

function InterfacesPage() {
  const { interfaces, stacks, health, refresh, request, notify } = useVpn();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [viewMode, setViewMode] = useState<'list' | 'grid'>('list');

  const unblock = async () => {
    setBusy(true);
    setError('');
    try {
      await request('/rfkill/unblock', { method: 'POST' });
      await refresh();
      notify('Wireless radio unblock requested.');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not unblock radio.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-7">
      <PageHeading
        eyebrow="Hardware / Wireless"
        title="WiFi interfaces"
        description="Inspect host radios, access-point capability, and assigned roles."
        action={
          <Button variant="outline" onClick={() => void refresh()}>
            <RefreshCw className="size-4" /> Refresh
          </Button>
        }
      />

      <OfflineNotice />
      {error && <p role="alert" className="border-l-2 border-warning bg-warning/10 px-4 py-3 text-sm text-warning">{error}</p>}

      <div className="flex flex-wrap items-center justify-between gap-4 border-y border-border py-4">
        <div className="flex items-center gap-3">
          <div>
            <strong className="font-mono text-sm">{health ? interfaces.length : '—'} detected</strong>
            <span className="ml-3 text-xs text-muted-foreground">
              {health ? interfaces.filter(i => i.supports_ap).length : '—'} AP-capable
            </span>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {/* View mode toggle: List vs Grid */}
          <div className="flex items-center rounded-md border border-border bg-secondary/40 p-0.5">
            <button
              type="button"
              aria-label="List view"
              onClick={() => setViewMode('list')}
              className={`flex items-center gap-1.5 rounded px-2.5 py-1 text-xs font-mono transition-colors ${
                viewMode === 'list'
                  ? 'bg-card text-foreground shadow-sm'
                  : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              <List className="size-3.5" />
              <span>List</span>
            </button>
            <button
              type="button"
              aria-label="Grid view"
              onClick={() => setViewMode('grid')}
              className={`flex items-center gap-1.5 rounded px-2.5 py-1 text-xs font-mono transition-colors ${
                viewMode === 'grid'
                  ? 'bg-card text-foreground shadow-sm'
                  : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              <LayoutGrid className="size-3.5" />
              <span>Grid</span>
            </button>
          </div>

          <Button variant="outline" size="sm" disabled={!health || busy} onClick={() => void unblock()}>
            <RadioTower className="size-4" /> {busy ? 'Unblocking…' : 'Attempt RF-unblock'}
          </Button>
        </div>
      </div>

      {health && !interfaces.length ? (
        <div className="border border-dashed border-border px-6 py-14 text-center">
          <Wifi className="mx-auto size-8 text-muted-foreground" />
          <h2 className="mt-4 font-mono text-sm">No wireless interfaces detected</h2>
          <p className="mt-2 text-sm text-muted-foreground">Connect an AP-capable adapter to the host and refresh.</p>
        </div>
      ) : viewMode === 'list' ? (
        /* ─── Clean Minimal List View ────────────────────────────────────── */
        <div className="divide-y divide-border rounded-lg border border-border bg-card/60">
          {interfaces.map(iface => {
            const apStacks = stacks.filter(s => s.ap_iface === iface.name);
            const uplinkStacks = stacks.filter(s => s.mode !== 'ap' && s.uplink_iface === iface.name);
            const bandSummary = [
              iface.supports_2_4ghz && iface.supports_5ghz ? '2.4 / 5 GHz' : iface.supports_5ghz ? '5 GHz' : '2.4 GHz',
              iface.supports_ax ? 'Wi-Fi 6' : iface.supports_ac ? 'Wi-Fi 5 (AC)' : iface.supports_n ? '802.11n' : '',
              iface.supports_wpa3 ? 'WPA3' : '',
            ].filter(Boolean).join(' · ');

            return (
              <div
                key={iface.name}
                className="flex flex-col gap-2 p-3.5 transition-colors hover:bg-secondary/20 sm:flex-row sm:items-center sm:justify-between"
              >
                {/* Left: Name, vendor, AP readiness */}
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <StatusDot active={iface.supports_ap} />
                    <span className="font-mono text-sm font-bold text-foreground">{iface.name}</span>
                    <span
                      className={`rounded px-1.5 py-0.5 font-mono text-[10px] font-medium ${
                        iface.supports_ap
                          ? 'bg-success/15 text-success'
                          : 'bg-muted text-muted-foreground'
                      }`}
                    >
                      {iface.supports_ap ? 'AP Ready' : 'Station only'}
                    </span>
                  </div>
                  <p className="mt-0.5 truncate text-xs text-muted-foreground pl-4">
                    {iface.vendor_model || 'Wireless Network Adapter'}
                  </p>
                </div>

                {/* Middle: Wireless specs */}
                <div className="flex items-center gap-4 text-xs font-mono text-muted-foreground sm:px-4">
                  <span>{bandSummary}</span>
                  <span className="hidden md:inline">
                    Ch {iface.default_channel} ({iface.default_width} MHz)
                  </span>
                </div>

                {/* Right: Assigned role & lock status */}
                <div className="shrink-0 text-xs font-mono">
                  {apStacks.length > 0 ? (
                    <span className="flex items-center gap-1 rounded bg-destructive/15 px-2 py-0.5 text-[11px] font-semibold text-destructive">
                      <Lock className="size-3" />
                      Locked (AP: {apStacks.map(s => s.id).join(', ')})
                    </span>
                  ) : uplinkStacks.length > 0 ? (
                    <span className="flex items-center gap-1 rounded bg-destructive/15 px-2 py-0.5 text-[11px] font-semibold text-destructive">
                      <Lock className="size-3" />
                      Locked (Uplink: {uplinkStacks.map(s => s.id).join(', ')})
                    </span>
                  ) : (
                    <span className="flex items-center gap-1.5 text-success text-[11px]">
                      <span className="size-1.5 rounded-full bg-success" />
                      Available
                    </span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        /* ─── Clean Minimal Grid View ─────────────────────────────────────── */
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {interfaces.map(iface => {
            const apStacks = stacks.filter(s => s.ap_iface === iface.name);
            const uplinkStacks = stacks.filter(s => s.mode !== 'ap' && s.uplink_iface === iface.name);
            const bandSummary = [
              iface.supports_2_4ghz && iface.supports_5ghz ? '2.4 / 5 GHz' : iface.supports_5ghz ? '5 GHz' : '2.4 GHz',
              iface.supports_ax ? 'Wi-Fi 6' : iface.supports_ac ? 'AC' : iface.supports_n ? 'N' : '',
            ].filter(Boolean).join(' · ');

            return (
              <article className="surface p-4 flex flex-col justify-between gap-3" key={iface.name}>
                <div>
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 min-w-0">
                      <StatusDot active={iface.supports_ap} />
                      <h3 className="font-mono text-sm font-bold truncate">{iface.name}</h3>
                    </div>
                    <span
                      className={`rounded px-1.5 py-0.5 font-mono text-[10px] font-medium ${
                        iface.supports_ap ? 'bg-success/15 text-success' : 'bg-muted text-muted-foreground'
                      }`}
                    >
                      {iface.supports_ap ? 'AP Ready' : 'Station only'}
                    </span>
                  </div>
                  <p className="mt-1 truncate text-xs text-muted-foreground">{iface.vendor_model}</p>
                </div>

                <div className="border-t border-border/60 pt-2.5 flex items-center justify-between text-[11px] font-mono text-muted-foreground">
                  <span>{bandSummary}</span>
                  <span>Ch {iface.default_channel} · {iface.default_width}MHz</span>
                </div>

                {(apStacks.length > 0 || uplinkStacks.length > 0) ? (
                  <div className="border-t border-border/60 pt-2 text-[11px] font-mono flex items-center justify-between">
                    <span className="flex items-center gap-1 text-destructive font-semibold">
                      <Lock className="size-3" /> Locked
                    </span>
                    <span className="text-muted-foreground truncate max-w-[150px]">
                      {apStacks.length > 0 ? `AP: ${apStacks.map(s => s.id).join(', ')}` : `Uplink: ${uplinkStacks.map(s => s.id).join(', ')}`}
                    </span>
                  </div>
                ) : (
                  <div className="border-t border-border/60 pt-2 text-[11px] font-mono flex items-center gap-1.5 text-success">
                    <span className="size-1.5 rounded-full bg-success" /> Available for AP
                  </div>
                )}
              </article>
            );
          })}
        </div>
      )}
    </div>
  );
}
