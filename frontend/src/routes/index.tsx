import { Link, createFileRoute } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import {
  Activity,
  AlertTriangle,
  ArrowUpRight,
  Check,
  Copy,
  Cpu,
  Eye,
  EyeOff,
  FileText,
  KeyRound,
  Network,
  Play,
  Plus,
  RadioTower,
  RotateCcw,
  Shield,
  ShieldCheck,
  Square,
  Terminal,
  Trash2,
  Wifi,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { OfflineNotice, PageHeading, SectionTitle, StatusDot } from '@/components/vpn-shell';
import { useVpn } from '@/components/vpn-provider';
import { StackForm } from '@/components/stack-form';
import { StackLogs } from '@/components/stack-logs';
import type { Location, Stack } from '@/lib/vpn';
import { copyToClipboard } from '@/lib/clipboard';

export const Route = createFileRoute('/')({
  head: () => ({
    meta: [
      { title: 'Dashboard | VPN AP Manager' },
      { name: 'description', content: 'Monitor VPN access points, tunnel status, wireless hardware, and live logs.' },
      { property: 'og:title', content: 'VPN AP Manager Dashboard' },
      { property: 'og:description', content: 'Monitor VPN access points, tunnel status, wireless hardware, and live logs.' },
      { property: 'og:type', content: 'website' },
      { name: 'twitter:card', content: 'summary_large_image' },
    ],
  }),
  component: Dashboard,
});

function Dashboard() {
  const { stacks, interfaces, health, loading, request, refresh, notify } = useVpn();
  const [formStack, setFormStack] = useState<Stack | 'new' | null>(null);
  const [logsId, setLogsId] = useState<string | null>(null);
  const [deleteConfirmStack, setDeleteConfirmStack] = useState<Stack | null>(null);
  const [locations, setLocations] = useState<Location[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState('');
  const [showPassword, setShowPassword] = useState<Record<string, boolean>>({});
  const [copiedId, setCopiedId] = useState<string | null>(null);

  useEffect(() => {
    if (health) void request<Location[]>('/vpn/locations').then(setLocations).catch(() => setLocations([]));
  }, [health?.status, request]);

  const copyPassword = async (id: string, pwd: string) => {
    const ok = await copyToClipboard(pwd);
    if (ok) {
      setCopiedId(id);
      notify('Wi-Fi password copied to clipboard.');
      window.setTimeout(() => setCopiedId(null), 2000);
    } else {
      notify('Failed to copy to clipboard.');
    }
  };

  const run = async (id: string, action: 'start' | 'stop' | 'restart' | 'delete') => {
    setBusy(id);
    setActionError('');
    try {
      await request(`/stacks/${encodeURIComponent(id)}${action === 'delete' ? '' : `/${action}`}`, {
        method: action === 'delete' ? 'DELETE' : 'POST',
      });
      await refresh();
      notify(`${id} ${action === 'delete' ? 'deleted' : `${action} request completed`}.`);
    } catch (caught) {
      setActionError(caught instanceof Error ? caught.message : 'Action failed.');
    } finally {
      setBusy(null);
    }
  };

  const active = stacks.filter(s => s.status === 'running');
  const partial = stacks.filter(s => s.status === 'starting' || s.status === 'error');
  const repeaters = stacks.filter(s => s.mode === 'repeater');
  const activeRepeaters = repeaters.filter(s => s.status === 'running');

  return (
    <div className="space-y-6">
      <PageHeading
        eyebrow="Dashboard / Live"
        title="Operations Console"
        description="Monitor and control your VPN network gateways."
        action={
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => setFormStack('new')} disabled={!health}>
              <Plus className="size-4" /> New access point
            </Button>
          </div>
        }
      />

      <OfflineNotice />
      {actionError && <div role="alert" className="border-l-2 border-warning bg-warning/10 px-4 py-3 text-sm text-warning">{actionError}</div>}
      {health?.host_project_dir_defaulted && (
        <div role="alert" className="border-l-2 border-warning bg-warning/10 px-4 py-3 text-sm text-warning">
          HOST_PROJECT_DIR is not set on the host. New access points may fail to build or mount volumes.
        </div>
      )}

      <section className="surface p-5 md:p-6">
        <SectionTitle icon={Activity} detail={health ? `${active.length} running · ${stacks.length} total` : undefined}>
          Stack Statuses
        </SectionTitle>
        <div className="grid gap-3 md:grid-cols-3">
          <div className="metric">
            <span className="eyebrow">ACTIVE AP STACKS</span>
            <div className="mt-3 font-mono text-3xl font-semibold">{health ? `${active.length} / ${stacks.length}` : '—'}</div>
            <p className="mt-2 text-xs text-muted-foreground">Configured access points</p>
          </div>
          <div className="metric">
            <span className="eyebrow">VPN TUNNELS</span>
            <div className="mt-3 font-mono text-3xl font-semibold">{health ? active.filter(s => s.vpn_enabled && s.vpn_ip).length : '—'}</div>
            <p className="mt-2 text-xs text-muted-foreground">Running stacks with a VPN IP</p>
          </div>
          <div className="metric">
            <span className="eyebrow">REPEATER MODE</span>
            <div className="mt-3 font-mono text-3xl font-semibold">{health ? `${activeRepeaters.length} / ${repeaters.length}` : '—'}</div>
            <p className="mt-2 text-xs text-muted-foreground truncate" title={activeRepeaters[0]?.uplink_ssid ? `Extending "${activeRepeaters[0].uplink_ssid}" (${activeRepeaters[0].uplink_iface})` : undefined}>
              {activeRepeaters[0]?.uplink_ssid
                ? `Extending "${activeRepeaters[0].uplink_ssid}" (${activeRepeaters[0].uplink_iface})`
                : repeaters.length > 0
                ? `${repeaters.length} repeater stack configured`
                : 'Wi-Fi range extender mode'}
            </p>
          </div>
        </div>
        {!!partial.length && <p className="mt-4 text-xs text-warning">{partial.length} stack{partial.length === 1 ? '' : 's'} not fully running.</p>}
      </section>

      <section>
        <SectionTitle icon={RadioTower} detail={health ? `${stacks.length} configured` : undefined}>
          Access points
        </SectionTitle>
        {health && stacks.length === 0 ? (
          <div className="border border-dashed border-border px-6 py-12 text-center">
            <RadioTower className="mx-auto size-7 text-primary" />
            <h3 className="mt-3 font-mono text-sm font-semibold">No access points yet</h3>
            <p className="mt-2 text-sm text-muted-foreground">Create an access point to start routing Wi-Fi through your VPN.</p>
            <Button className="mt-5" onClick={() => setFormStack('new')}><Plus className="size-4" /> New access point</Button>
          </div>
        ) : !health ? (
          <div className="border border-dashed border-border px-6 py-10 text-sm text-muted-foreground">
            {loading ? 'Loading access points…' : 'Connect your Rust service to view access points.'}
          </div>
        ) : (
          <div className="grid gap-3 xl:grid-cols-2">
            {stacks.map(stack => {
              const isRunning = stack.status === 'running';
              const isBusy = busy === stack.id;

              return (
                <article key={stack.id} className="surface p-4 md:p-5 flex flex-col justify-between gap-3">
                  <div>
                    {/* ─── Header: SSID, Mode, Status ──────────────────────── */}
                    <div className="flex flex-wrap items-start justify-between gap-2.5">
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <StatusDot active={isRunning} />
                          <h3 className="truncate font-mono text-sm font-bold text-foreground">{stack.ssid}</h3>
                        </div>
                        <div className="mt-0.5 pl-4 flex flex-wrap items-center gap-1.5 font-mono text-[11px] text-muted-foreground">
                          <span>{stack.id}</span>
                          <span>·</span>
                          <span className="text-foreground">AP: {stack.ap_iface}</span>
                          {stack.mode !== 'ap' && stack.uplink_iface && (
                            <>
                              <span>·</span>
                              <span className="text-primary">Uplink: {stack.uplink_iface}</span>
                            </>
                          )}
                        </div>
                      </div>

                      <div className="flex flex-wrap items-center gap-1.5">
                        <span className="rounded border border-primary/30 bg-primary/10 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-wide text-primary">
                          {stack.mode === 'repeater' ? 'Repeater' : 'AP'}
                        </span>
                        {stack.vpn_enabled && (stack.auto_reconnect_8h || stack.auto_reconnect_12h) && (
                          <span
                            className="rounded border border-primary/40 bg-primary/10 px-1.5 py-0.5 font-mono text-[9px] text-primary flex items-center gap-1"
                            title="Auto-reconnects Gluetun tunnel every 8 hours"
                          >
                            <RotateCcw className="size-2.5" />
                            <span>8h Reconnect</span>
                          </span>
                        )}
                        {!stack.vpn_enabled && (
                          <span className="rounded border border-border bg-secondary px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-wide text-muted-foreground">
                            Direct NAT
                          </span>
                        )}
                        <span className={`rounded border px-2 py-0.5 font-mono text-[10px] uppercase font-semibold ${
                          isRunning
                            ? 'border-success/30 bg-success/10 text-success'
                            : stack.status === 'stopped'
                            ? 'border-border text-muted-foreground'
                            : 'border-warning/30 bg-warning/10 text-warning'
                        }`}>
                          {stack.status}
                        </span>
                      </div>
                    </div>

                    {/* ─── Wi-Fi Key & Telemetry ───────────────────────────── */}
                    <div className="mt-3 flex flex-wrap items-center justify-between gap-2 border-t border-border/50 pt-2.5 text-xs font-mono">
                      <div className="flex items-center gap-1.5 text-muted-foreground">
                        <span>Password:</span>
                        <span className="font-semibold text-foreground tracking-wider">
                          {showPassword[stack.id] ? stack.password : '••••••••'}
                        </span>
                        <button
                          type="button"
                          onClick={() => setShowPassword(p => ({ ...p, [stack.id]: !p[stack.id] }))}
                          className="text-muted-foreground hover:text-foreground p-0.5"
                          title={showPassword[stack.id] ? 'Hide password' : 'Show password'}
                          aria-label={showPassword[stack.id] ? 'Hide password' : 'Show password'}
                        >
                          {showPassword[stack.id] ? <EyeOff className="size-3" /> : <Eye className="size-3" />}
                        </button>
                        <button
                          type="button"
                          onClick={() => copyPassword(stack.id, stack.password)}
                          className="text-muted-foreground hover:text-foreground p-0.5"
                          title="Copy password"
                          aria-label="Copy password"
                        >
                          {copiedId === stack.id ? <Check className="size-3 text-success" /> : <Copy className="size-3" />}
                        </button>
                      </div>

                      <div className="flex items-center gap-2 text-muted-foreground text-[11px]">
                        <span>IP: <strong className="text-foreground">{stack.vpn_ip || stack.subnet}</strong></span>
                      </div>
                    </div>

                    {/* ─── Gateway / Route / Container Status ──────────────── */}
                    <div className="mt-2 flex flex-wrap items-center justify-between gap-2 text-[11px] font-mono text-muted-foreground">
                      <div className="flex items-center gap-1.5">
                        <span className="text-foreground">
                          {stack.vpn_enabled
                            ? `${stack.vpn_type === 'wireguard' ? 'WireGuard' : 'OpenVPN'} · ${stack.vpn_city || stack.vpn_country || 'NordVPN'}`
                            : 'Local Routing'}
                        </span>
                        {stack.adguard_dns && (
                          <>
                            <span>•</span>
                            <span className="text-primary">AdGuard: {stack.adguard_dns}</span>
                          </>
                        )}
                      </div>

                      {stack.containers && stack.containers.length > 0 && (
                        <div className="flex items-center gap-2 text-[10px]">
                          {stack.containers.map(c => (
                            <span key={c.name} className="flex items-center gap-1" title={`${c.name}: ${c.status}`}>
                              <span className={`size-1.5 rounded-full ${c.status === 'running' ? 'bg-success' : 'bg-muted-foreground/60'}`} />
                              <span>{c.name}</span>
                            </span>
                          ))}
                        </div>
                      )}
                    </div>
                  </div>

                  {/* ─── Actions Toolbar ─────────────────────────────────── */}
                  <div className="mt-2 flex flex-wrap items-center gap-2 border-t border-border/50 pt-3">
                    {isRunning ? (
                      <Button
                        size="sm"
                        variant="outline"
                        className="border-destructive/40 text-destructive hover:bg-destructive/10"
                        disabled={isBusy}
                        onClick={() => void run(stack.id, 'stop')}
                      >
                        <Square className="size-3.5 fill-current" /> Stop
                      </Button>
                    ) : (
                      <Button
                        size="sm"
                        variant="default"
                        disabled={isBusy}
                        onClick={() => void run(stack.id, 'start')}
                      >
                        <Play className="size-3.5 fill-current" /> Start
                      </Button>
                    )}

                    {isRunning && (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={isBusy}
                        onClick={() => void run(stack.id, 'restart')}
                      >
                        <RotateCcw className="size-3.5" /> Restart
                      </Button>
                    )}

                    <Button size="sm" variant="outline" onClick={() => setFormStack(stack)}>Edit</Button>
                    <Button size="sm" variant="outline" onClick={() => setLogsId(stack.id)}>
                      <FileText className="size-3.5" /> Logs
                    </Button>

                    <Button
                      size="icon"
                      variant="ghost"
                      title={`Delete ${stack.id}`}
                      aria-label={`Delete ${stack.id}`}
                      disabled={isBusy}
                      onClick={() => setDeleteConfirmStack(stack)}
                      className="ml-auto text-destructive hover:bg-destructive/10"
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </section>

      {/* ─── System Telemetry & Hardware Overview ─────────────────────────── */}
      <div className="grid gap-4 lg:grid-cols-2">
        <section className="surface p-4 md:p-5">
          <div className="flex items-center justify-between pb-3 border-b border-border">
            <div className="flex items-center gap-2 font-mono text-xs font-semibold">
              <Wifi className="size-4 text-primary" />
              <span>Wireless Hardware Radios</span>
            </div>
            <Link to="/interfaces" className="text-xs text-primary hover:underline font-mono">
              Manage Hardware →
            </Link>
          </div>

          <div className="mt-3 divide-y divide-border/60">
            {interfaces.map(iface => {
              const boundStack = stacks.find(s => s.ap_iface === iface.name);
              const isUplink = stacks.find(s => s.mode !== 'ap' && s.uplink_iface === iface.name);

              return (
                <div key={iface.name} className="flex items-center justify-between py-2.5 text-xs font-mono">
                  <div className="flex items-center gap-2.5 min-w-0">
                    <StatusDot active={iface.supports_ap} />
                    <span className="font-bold text-foreground">{iface.name}</span>
                    <span className="text-[11px] text-muted-foreground truncate hidden sm:inline">
                      {iface.vendor_model}
                    </span>
                  </div>

                  <div className="flex items-center gap-2 shrink-0">
                    {boundStack ? (
                      <span className="rounded bg-primary/15 px-1.5 py-0.5 text-[10px] text-primary font-semibold">
                        AP: {boundStack.id}
                      </span>
                    ) : isUplink ? (
                      <span className="rounded bg-secondary px-1.5 py-0.5 text-[10px] text-foreground">
                        Uplink: {isUplink.id}
                      </span>
                    ) : (
                      <span className="text-[10px] text-muted-foreground">Available</span>
                    )}
                    <span className="text-[10px] text-muted-foreground hidden md:inline">
                      Ch {iface.default_channel} ({iface.default_width}MHz)
                    </span>
                  </div>
                </div>
              );
            })}
          </div>
        </section>

        <section className="surface p-4 md:p-5">
          <div className="flex items-center justify-between pb-3 border-b border-border">
            <div className="flex items-center gap-2 font-mono text-xs font-semibold">
              <ShieldCheck className="size-4 text-success" />
              <span>Gateway & Security Subsystems</span>
            </div>
            <Link to="/credentials" className="text-xs text-primary hover:underline font-mono">
              VPN Settings →
            </Link>
          </div>

          <div className="mt-3 space-y-2.5 text-xs font-mono">
            <div className="flex items-center justify-between rounded-md border border-border/60 bg-secondary/20 p-2.5">
              <span className="text-muted-foreground">Docker Engine Socket</span>
              <span className={`flex items-center gap-1.5 font-medium ${health?.docker_socket_reachable ? 'text-success' : 'text-warning'}`}>
                <span className={`size-1.5 rounded-full ${health?.docker_socket_reachable ? 'bg-success' : 'bg-warning'}`} />
                {health?.docker_socket_reachable ? 'Connected & Healthy' : 'Unreachable'}
              </span>
            </div>

            <div className="flex items-center justify-between rounded-md border border-border/60 bg-secondary/20 p-2.5">
              <span className="text-muted-foreground">VPN Tunnel Subsystem</span>
              <span className="text-foreground">NordLynx / WireGuard & OpenVPN</span>
            </div>

            <div className="flex items-center justify-between rounded-md border border-border/60 bg-secondary/20 p-2.5">
              <span className="text-muted-foreground">DNS Interception & DoT Filter</span>
              <span className="text-foreground">Port 53 redirect · Port 853 TCP reset</span>
            </div>
          </div>
        </section>
      </div>



      {formStack && <StackForm stack={formStack === 'new' ? undefined : formStack} locations={locations} onClose={() => setFormStack(null)} />}
      {logsId && <StackLogs id={logsId} onClose={() => setLogsId(null)} />}

      {deleteConfirmStack && (
        <AlertDialog open={!!deleteConfirmStack} onOpenChange={open => { if (!open) setDeleteConfirmStack(null); }}>
          <AlertDialogContent className="border border-border bg-card p-6 shadow-2xl">
            <AlertDialogHeader>
              <div className="flex items-center gap-3">
                <div className="grid size-10 shrink-0 place-items-center rounded-full bg-destructive/15 text-destructive">
                  <AlertTriangle className="size-5" />
                </div>
                <div>
                  <AlertDialogTitle className="font-mono text-lg font-bold">Delete Access Point?</AlertDialogTitle>
                  <AlertDialogDescription className="mt-1 text-sm text-muted-foreground">
                    This action cannot be undone.
                  </AlertDialogDescription>
                </div>
              </div>
            </AlertDialogHeader>

            <div className="my-2 rounded-md border border-border bg-background/50 p-4 text-xs">
              <p className="font-mono text-sm font-semibold text-foreground">{deleteConfirmStack.ssid}</p>
              <p className="mt-1 font-mono text-muted-foreground">ID: {deleteConfirmStack.id} · Interface: {deleteConfirmStack.ap_iface}</p>
            </div>

            <p className="text-xs text-muted-foreground">
              Deleting this access point will remove its configuration files and terminate all associated Docker containers.
            </p>

            <AlertDialogFooter className="mt-4 flex gap-2 sm:justify-end">
              <AlertDialogCancel onClick={() => setDeleteConfirmStack(null)}>Cancel</AlertDialogCancel>
              <AlertDialogAction
                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                disabled={busy === deleteConfirmStack.id}
                onClick={() => {
                  const targetId = deleteConfirmStack.id;
                  setDeleteConfirmStack(null);
                  void run(targetId, 'delete');
                }}
              >
                {busy === deleteConfirmStack.id ? 'Deleting…' : 'Delete Access Point'}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}
    </div>
  );
}
