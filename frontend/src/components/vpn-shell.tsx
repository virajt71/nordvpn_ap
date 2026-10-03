import { useState, type ReactNode } from 'react';
import { Link, Outlet, useRouterState } from '@tanstack/react-router';
import { Activity, CircleHelp, KeyRound, LayoutDashboard, Menu, RadioTower, RefreshCw, Shield, Wifi, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { VpnProvider, useVpn } from './vpn-provider';

const nav = [
  { to: '/' as const, label: 'Dashboard', Icon: LayoutDashboard },
  { to: '/credentials' as const, label: 'Credentials', Icon: KeyRound },
  { to: '/interfaces' as const, label: 'WiFi interfaces', Icon: Wifi },
];

function ShellContent() {
  const { health, stacks, interfaces, error, loading, refresh, token, setToken, notice } = useVpn();
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [showAccess, setShowAccess] = useState(false);
  const path = useRouterState({ select: state => state.location.pathname });
  const live = !!health && !error;
  const running = stacks.filter(stack => stack.status === 'running');

  return (
    <div className="vpn-app min-h-screen bg-background text-foreground">
      {mobileOpen && <div className="fixed inset-0 z-30 bg-background/80 lg:hidden" onClick={() => setMobileOpen(false)} />}
      <div className="flex min-h-screen">
        <aside className={`z-40 flex shrink-0 flex-col border-r border-border bg-sidebar/90 backdrop-blur-xl transition-[width,transform] duration-200 ${collapsed ? 'lg:w-[72px]' : 'lg:w-60'} fixed inset-y-0 left-0 w-60 lg:sticky lg:top-0 lg:h-screen ${mobileOpen ? 'translate-x-0' : '-translate-x-full lg:translate-x-0'}`}>
          <div className={`flex h-20 items-center border-b border-border/40 ${collapsed ? 'justify-center px-2' : 'justify-between px-4'}`}>
            {collapsed ? (
              <Button
                variant="ghost"
                size="icon"
                className="hidden lg:inline-flex shrink-0 size-10"
                aria-label="Expand sidebar"
                title="Expand sidebar"
                onClick={() => setCollapsed(false)}
              >
                <Menu className="size-5 text-primary" />
              </Button>
            ) : (
              <>
                <div className="flex items-center gap-2.5 min-w-0">
                  <div className="grid size-9 shrink-0 place-items-center rounded-md border border-primary/30 bg-primary/20"><Shield className="size-5 text-primary" strokeWidth={2.2} /></div>
                  <div className="min-w-0"><div className="font-mono text-sm font-bold leading-none">VPN AP</div><div className="mt-1 text-[10px] font-semibold uppercase text-muted-foreground">Access-point manager</div></div>
                </div>
                <Button
                  variant="ghost"
                  size="icon"
                  className="hidden lg:inline-flex shrink-0 ml-auto"
                  aria-label="Collapse sidebar"
                  title="Collapse sidebar"
                  onClick={() => setCollapsed(true)}
                >
                  <Menu className="size-4" />
                </Button>
              </>
            )}
            <Button
              variant="ghost"
              size="icon"
              className="lg:hidden shrink-0 ml-auto"
              aria-label="Close menu"
              onClick={() => setMobileOpen(false)}
            >
              <X className="size-4" />
            </Button>
          </div>

          <nav className="space-y-1 px-3 py-4" aria-label="Main navigation">
            {nav.map(({ to, label, Icon }) => (
              <Link
                to={to}
                key={to}
                onClick={() => setMobileOpen(false)}
                title={collapsed ? label : undefined}
                className={`flex h-10 items-center gap-3 rounded-md border px-3 font-mono text-xs transition-colors ${path === to ? 'border-primary/20 bg-primary/15 text-foreground' : 'border-transparent text-muted-foreground hover:bg-accent hover:text-foreground'}`}
              >
                <Icon className={`size-4 shrink-0 ${path === to ? 'text-primary' : ''}`} />
                {!collapsed && <span>{label}</span>}
              </Link>
            ))}
          </nav>

          <div className="mt-auto space-y-3 px-3 pb-5">
            {!collapsed && live && !health.docker_socket_reachable && (
              <div className="rounded-md border border-warning/25 bg-warning/10 p-3 text-xs text-warning">Docker socket unavailable. Stack controls may fail.</div>
            )}
            {!collapsed && live && health.host_project_dir_defaulted && (
              <div className="rounded-md border border-warning/25 bg-warning/10 p-3 text-xs text-warning">HOST_PROJECT_DIR is not set on the host.</div>
            )}
            {!collapsed && (
              <div className="rounded-md border border-border bg-card/60 p-3">
                <div className="flex items-center gap-2 text-xs">
                  <span className={`size-2 rounded-full ${live ? 'bg-success' : 'bg-warning'}`} />
                  <span>{loading ? 'Connecting…' : live ? 'Live stack telemetry' : 'Rust service offline'}</span>
                </div>
                <div className="mt-3 grid grid-cols-3 gap-2">
                  {[[stacks.length, 'STACKS'], [running.length, 'TUNNELS'], [interfaces.length, 'APs']].map(([value, label]) => (
                    <div className="min-w-0 rounded-md border border-border bg-background/50 p-2" key={label}>
                      <div className="font-mono text-lg font-bold leading-none">{live ? value : '—'}</div>
                      <div className="mt-1 text-[9px] text-muted-foreground">{label}</div>
                    </div>
                  ))}
                </div>
              </div>
            )}
            <div className="flex items-center justify-between gap-1 border-t border-border pt-3">
              <span className="flex items-center gap-2 text-xs text-muted-foreground">
                <span className={`size-2 rounded-full ${live ? 'bg-success' : 'bg-warning'}`} />
                {!collapsed && (live ? 'System connected' : 'Disconnected')}
              </span>
              <Button variant="ghost" size="icon" title="Refresh connection" aria-label="Refresh connection" onClick={() => void refresh()}>
                <RefreshCw className="size-4" />
              </Button>
            </div>
          </div>
        </aside>

        <div className="min-w-0 flex-1 flex flex-col min-h-screen">
          <div className="mx-auto w-full max-w-[1480px] flex-1 flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between border-b border-border px-5 py-3 lg:hidden">
                <Button variant="ghost" size="icon" aria-label="Open menu" onClick={() => setMobileOpen(true)}><Menu className="size-4" /></Button>
                <span className="font-mono text-sm font-bold">VPN AP</span>
                <span className={`size-2 rounded-full ${live ? 'bg-success' : 'bg-warning'}`} />
              </div>
              <main className="px-5 py-7 md:px-8 lg:px-10 lg:py-9"><Outlet /></main>
            </div>

            {health && interfaces.length > 0 && (
              <footer className="mt-auto border-t border-border px-5 py-4 md:px-8 lg:px-10">
                <div className="flex flex-wrap items-center justify-between gap-4 font-mono text-xs text-muted-foreground">
                  <span className="flex items-center gap-2">
                    <Wifi className="size-4 text-primary" />
                    <span>
                      <strong className="font-bold text-foreground">{interfaces.length}</strong> wireless interface{interfaces.length === 1 ? '' : 's'} detected
                    </span>
                  </span>
                  <Link to="/interfaces" onClick={() => setMobileOpen(false)} className="text-primary hover:underline flex items-center gap-1">
                    Inspect hardware →
                  </Link>
                </div>
              </footer>
            )}
          </div>
        </div>
      </div>

      {notice && <div role="status" className="fixed bottom-5 right-5 z-50 max-w-sm rounded-md border border-primary/40 bg-card px-4 py-3 text-sm shadow-lg">{notice}</div>}
      {showAccess && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-background/80 p-4" onMouseDown={event => { if (event.target === event.currentTarget) setShowAccess(false); }}>
          <section className="w-full max-w-md rounded-md border border-border bg-card p-6 shadow-xl">
            <div className="flex items-center justify-between">
              <h2 className="font-mono text-lg font-semibold">API access</h2>
              <Button variant="ghost" size="icon" aria-label="Close" onClick={() => setShowAccess(false)}><X /></Button>
            </div>
            <p className="mt-3 text-sm text-muted-foreground">If AP_API_TOKEN is enabled on your Rust server, enter it to authorize requests. It stays in this tab only.</p>
            <label className="mt-5 block text-xs font-semibold text-muted-foreground" htmlFor="api-token">Bearer token</label>
            <input id="api-token" type="password" autoComplete="off" value={token} onChange={event => setToken(event.target.value)} className="field mt-2" placeholder="Enter token" />
            <div className="mt-5 flex justify-end gap-2">
              <Button variant="outline" onClick={() => setToken('')}>Clear</Button>
              <Button onClick={() => { setShowAccess(false); void refresh(); }}>Connect</Button>
            </div>
          </section>
        </div>
      )}
      {!live && !loading && (
        <Button variant="outline" size="icon" className="fixed bottom-5 left-5 z-20 shadow-lg" title="API access" aria-label="API access" onClick={() => setShowAccess(true)}>
          <KeyRound />
        </Button>
      )}
      {live && (
        <Button variant="ghost" size="icon" className="fixed bottom-5 left-5 z-20" title="API access" aria-label="API access" onClick={() => setShowAccess(true)}>
          <KeyRound />
        </Button>
      )}
    </div>
  );
}

export function VpnShell() { return <VpnProvider><ShellContent /></VpnProvider>; }
export function OfflineNotice() { const { error, loading, refresh } = useVpn(); if (loading) return <div className="border border-border bg-card/50 p-5 text-sm text-muted-foreground">Connecting to your Rust service…</div>; if (!error) return null; return <div role="alert" className="flex flex-wrap items-center justify-between gap-4 rounded-md border border-warning/30 bg-warning/10 px-5 py-4"><div className="flex items-start gap-3"><CircleHelp className="mt-0.5 size-5 shrink-0 text-warning" /><div><strong className="text-sm text-foreground">Rust service not connected</strong><p className="mt-1 text-sm text-muted-foreground">{error}</p></div></div><Button variant="outline" size="sm" onClick={() => void refresh()}><RefreshCw /> Retry</Button></div>; }
export function PageHeading({ eyebrow, title, description, action }: { eyebrow: string; title: string; description: string; action?: ReactNode }) { return <header className="flex flex-wrap items-end justify-between gap-5"><div><div className="mb-2 flex items-center gap-2 font-mono text-[11px] font-medium uppercase text-primary"><Activity className="size-3" /> {eyebrow}</div><h1 className="font-mono text-2xl font-bold md:text-3xl">{title}</h1><p className="mt-2 text-sm text-muted-foreground">{description}</p></div>{action}</header>; }
export function StatusDot({ active }: { active: boolean }) { return <span className={`inline-block size-2 shrink-0 rounded-full ${active ? 'bg-success' : 'bg-muted-foreground'}`} />; }
export function SectionTitle({ icon: Icon, children, detail }: { icon: typeof RadioTower; children: ReactNode; detail?: string | undefined }) { return <div className="mb-4 flex items-center justify-between gap-3"><h2 className="flex items-center gap-2 font-mono text-sm font-semibold"><Icon className="size-4 text-primary" />{children}</h2>{detail && <span className="font-mono text-[11px] text-muted-foreground">{detail}</span>}</div>; }
