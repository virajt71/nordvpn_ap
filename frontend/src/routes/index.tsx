import { Link, createFileRoute } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import { Activity, AlertTriangle, ArrowUpRight, FileText, Play, Plus, RadioTower, RotateCcw, Square, Trash2, Wifi } from 'lucide-react';
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

  useEffect(() => {
    if (health) void request<Location[]>('/vpn/locations').then(setLocations).catch(() => setLocations([]));
  }, [health?.status, request]);

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

  return (
    <div className="space-y-6">
      <PageHeading
        eyebrow="Dashboard / Live"
        title="Operations Console"
        description="Monitor and control your VPN network gateways."
        action={
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => { if (stacks[0]) setLogsId(stacks[0].id); }} disabled={!stacks.length}>
              <FileText className="size-4" /> View logs
            </Button>
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
            <div className="mt-3 font-mono text-3xl font-semibold">{health ? active.filter(s => s.vpn_ip).length : '—'}</div>
            <p className="mt-2 text-xs text-muted-foreground">Running stacks with a VPN IP</p>
          </div>
          <div className="metric">
            <span className="eyebrow">WI-FI HARDWARE</span>
            <div className="mt-3 font-mono text-3xl font-semibold">{health ? interfaces.filter(i => i.supports_ap).length : '—'}</div>
            <p className="mt-2 text-xs text-muted-foreground">AP-capable interfaces · {health ? interfaces.length : '—'} detected</p>
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
            {stacks.map(stack => (
              <article key={stack.id} className="surface p-5">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <StatusDot active={stack.status === 'running'} />
                      <h3 className="truncate font-mono text-sm font-semibold">{stack.ssid}</h3>
                    </div>
                    <p className="mt-1 pl-4 font-mono text-[11px] text-muted-foreground">{stack.id} · {stack.ap_iface}</p>
                  </div>
                  <span className={`rounded border px-2 py-1 font-mono text-[10px] uppercase ${
                    stack.status === 'running'
                      ? 'border-success/30 bg-success/10 text-success'
                      : stack.status === 'stopped'
                      ? 'border-border text-muted-foreground'
                      : 'border-warning/30 bg-warning/10 text-warning'
                  }`}>
                    {stack.status}
                  </span>
                </div>

                <div className="mt-5 grid grid-cols-2 gap-x-3 gap-y-4 border-y border-border py-4 text-xs sm:grid-cols-4">
                  <div><span className="eyebrow">VPN</span><p className="mt-1 truncate font-mono">{stack.vpn_type}</p></div>
                  <div><span className="eyebrow">LOCATION</span><p className="mt-1 truncate font-mono">{stack.vpn_city || stack.vpn_country || '—'}</p></div>
                  <div><span className="eyebrow">VPN IP</span><p className="mt-1 truncate font-mono">{stack.vpn_ip || '—'}</p></div>
                  <div><span className="eyebrow">SUBNET</span><p className="mt-1 truncate font-mono">{stack.subnet}</p></div>
                </div>

                <div className="mt-4 flex flex-wrap items-center gap-2">
                  <Button
                    size="sm"
                    variant={stack.status === 'running' ? 'outline' : 'default'}
                    disabled={busy === stack.id}
                    onClick={() => void run(stack.id, 'start')}
                  >
                    <Play className="size-3.5" /> Start
                  </Button>

                  <Button
                    size="sm"
                    variant={stack.status === 'running' ? 'default' : 'outline'}
                    disabled={busy === stack.id}
                    onClick={() => void run(stack.id, 'stop')}
                  >
                    <Square className="size-3.5" /> Stop
                  </Button>

                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy === stack.id}
                    onClick={() => void run(stack.id, 'restart')}
                  >
                    <RotateCcw className="size-3.5" /> Restart
                  </Button>

                  <Button size="sm" variant="outline" onClick={() => setFormStack(stack)}>Edit</Button>
                  <Button size="sm" variant="outline" onClick={() => setLogsId(stack.id)}><FileText className="size-3.5" /> Logs</Button>

                  <Button
                    size="icon"
                    variant="ghost"
                    title={`Delete ${stack.id}`}
                    aria-label={`Delete ${stack.id}`}
                    disabled={busy === stack.id}
                    onClick={() => setDeleteConfirmStack(stack)}
                    className="ml-auto text-destructive hover:bg-destructive/10"
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              </article>
            ))}
          </div>
        )}
      </section>

      <div className="grid gap-5 lg:grid-cols-2">
        <section className="surface p-5">
          <SectionTitle icon={RadioTower} detail={health ? `${active.length} active` : undefined}>
            VPN Tunnels
          </SectionTitle>
          {active.length ? (
            <div className="space-y-2">
              {active.map(s => (
                <div key={s.id} className="flex items-center justify-between gap-3 rounded-md border border-border bg-secondary/40 px-3 py-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <StatusDot active />
                      <strong className="truncate font-mono text-xs">{s.id} · {s.vpn_type}</strong>
                    </div>
                    <p className="mt-1 truncate pl-4 text-[11px] text-muted-foreground">{s.ap_iface} → {s.vpn_city || s.vpn_country}</p>
                  </div>
                  <span className="shrink-0 font-mono text-[11px] text-muted-foreground">{s.vpn_ip || 'IP pending'}</span>
                </div>
              ))}
            </div>
          ) : (
            <p className="py-8 text-center text-sm text-muted-foreground">{health ? 'No running VPN tunnels.' : 'Tunnel status appears when the Rust service is connected.'}</p>
          )}
        </section>

        <section className="surface p-5">
          <SectionTitle icon={FileText}>Live Logs</SectionTitle>
          {stacks.length ? (
            <div className="space-y-2">
              {stacks.slice(0, 3).map(s => (
                <div key={s.id} className="flex items-center justify-between gap-3 border-b border-border py-2 last:border-0">
                  <div className="flex min-w-0 items-center gap-2">
                    <StatusDot active={s.status === 'running'} />
                    <span className="truncate font-mono text-xs">{s.id}</span>
                  </div>
                  <Button variant="ghost" size="sm" onClick={() => setLogsId(s.id)}>
                    Inspect <ArrowUpRight className="size-3.5" />
                  </Button>
                </div>
              ))}
            </div>
          ) : (
            <p className="py-8 text-center text-sm text-muted-foreground">{health ? 'No stacks to inspect.' : 'Logs appear when the Rust service is connected.'}</p>
          )}
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
