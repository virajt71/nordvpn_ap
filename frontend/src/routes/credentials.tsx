import { createFileRoute } from '@tanstack/react-router';
import { useEffect, useState, type FormEvent } from 'react';
import { Eye, EyeOff, KeyRound, LockKeyhole, Save, ShieldCheck } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { OfflineNotice, PageHeading } from '@/components/vpn-shell';
import { useVpn } from '@/components/vpn-provider';
import type { Credentials } from '@/lib/vpn';

export const Route = createFileRoute('/credentials')({
  head: () => ({
    meta: [
      { title: 'Credentials | VPN AP Manager' },
      { name: 'description', content: 'Manage NordVPN, WireGuard, and OpenVPN credentials for your access points.' },
      { property: 'og:title', content: 'VPN AP Manager Credentials' },
      { property: 'og:description', content: 'Manage NordVPN, WireGuard, and OpenVPN credentials for your access points.' },
      { property: 'og:type', content: 'website' },
      { name: 'twitter:card', content: 'summary_large_image' },
    ],
  }),
  component: CredentialsPage,
});

function CredentialsPage() {
  const { health, request, notify } = useVpn();
  const [status, setStatus] = useState<Credentials | null>(null);
  const [values, setValues] = useState({
    nordvpn_token: '',
    wireguard_private_key: '',
    openvpn_user: '',
    openvpn_password: '',
  });
  const [visible, setVisible] = useState<Record<string, boolean>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (health) {
      void request<Credentials>('/credentials')
        .then(setStatus)
        .catch(caught => setError(caught instanceof Error ? caught.message : 'Could not load credential status.'));
    }
  }, [health?.status, request]);

  const save = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError('');

    const payload = Object.fromEntries(Object.entries(values).filter(([, value]) => value.trim()));
    if (!Object.keys(payload).length) {
      setError('Enter a new value before saving.');
      setBusy(false);
      return;
    }

    try {
      await request('/credentials', { method: 'PATCH', body: JSON.stringify(payload) });
      setStatus(await request<Credentials>('/credentials'));
      setValues({ nordvpn_token: '', wireguard_private_key: '', openvpn_user: '', openvpn_password: '' });
      notify('VPN credentials updated successfully.');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not save credentials.');
    } finally {
      setBusy(false);
    }
  };

  const renderField = (key: keyof typeof values, label: string, hint: string, configured?: boolean) => (
    <div className="space-y-1.5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <label className="label text-xs" htmlFor={key}>{label}</label>
        <span
          className={`rounded px-1.5 py-0.5 font-mono text-[10px] font-medium ${
            configured ? 'bg-success/15 text-success' : 'bg-muted text-muted-foreground'
          }`}
        >
          {configured ? 'Configured' : 'Not Set'}
        </span>
      </div>

      <div className="relative">
        <input
          id={key}
          className="field pr-10 text-xs font-mono"
          autoComplete="off"
          type={visible[key] ? 'text' : key === 'openvpn_user' ? 'text' : 'password'}
          value={values[key]}
          onChange={e => setValues(v => ({ ...v, [key]: e.target.value }))}
          placeholder={configured ? '•••••••••••••••• (Leave blank to keep current)' : `Enter ${label.toLowerCase()}`}
        />
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="absolute right-1 top-1 size-8 text-muted-foreground hover:text-foreground"
          title={visible[key] ? 'Hide' : 'Show'}
          aria-label={visible[key] ? 'Hide' : 'Show'}
          onClick={() => setVisible(v => ({ ...v, [key]: !v[key] }))}
        >
          {visible[key] ? <EyeOff className="size-3.5" /> : <Eye className="size-3.5" />}
        </Button>
      </div>

      <p className="text-[11px] text-muted-foreground">{hint}</p>
    </div>
  );

  return (
    <div className="max-w-3xl space-y-6">
      <PageHeading
        eyebrow="Settings / Security"
        title="VPN Credentials"
        description="NordVPN account secrets and WireGuard private keys used by client access point tunnels."
      />

      <OfflineNotice />

      <div className="flex items-center gap-2.5 rounded-md border border-border bg-secondary/20 p-3 text-xs text-muted-foreground">
        <LockKeyhole className="size-4 text-primary shrink-0" />
        <span>Stored credentials are secure and never transmitted back to the browser. Leave fields blank to keep existing values.</span>
      </div>

      <form onSubmit={save} className="space-y-6">
        {/* ─── NordVPN & WireGuard ────────────────────────────────────────── */}
        <section className="surface p-5 space-y-4">
          <div className="flex items-center justify-between border-b border-border/60 pb-3">
            <div className="flex items-center gap-2 font-mono text-xs font-semibold text-foreground">
              <KeyRound className="size-4 text-primary" />
              <span>NordVPN / WireGuard (NordLynx)</span>
            </div>
            <span className="text-[10px] font-mono text-success bg-success/10 px-2 py-0.5 rounded">
              Recommended Protocol
            </span>
          </div>

          <div className="grid gap-4 md:grid-cols-2">
            {renderField(
              'nordvpn_token',
              'NordVPN Access Token',
              'Saving a token prompts the service to automatically retrieve and store your WireGuard private key.'
            )}
            {renderField(
              'wireguard_private_key',
              'WireGuard Private Key',
              'Direct base64 private key required for NordLynx encrypted tunnel connections.',
              status?.has_wireguard_private_key
            )}
          </div>
        </section>

        {/* ─── OpenVPN Credentials ────────────────────────────────────────── */}
        <section className="surface p-5 space-y-4">
          <div className="flex items-center justify-between border-b border-border/60 pb-3">
            <div className="flex items-center gap-2 font-mono text-xs font-semibold text-foreground">
              <ShieldCheck className="size-4 text-muted-foreground" />
              <span>OpenVPN Service Credentials</span>
            </div>
            <span className="text-[10px] font-mono text-muted-foreground bg-secondary px-2 py-0.5 rounded">
              Fallback Protocol
            </span>
          </div>

          <div className="grid gap-4 md:grid-cols-2">
            {renderField(
              'openvpn_user',
              'OpenVPN Username',
              'Service credentials username from your NordVPN dashboard.',
              status?.has_openvpn_user
            )}
            {renderField(
              'openvpn_password',
              'OpenVPN Password',
              'Service credentials password from your NordVPN dashboard.',
              status?.has_openvpn_password
            )}
          </div>
        </section>

        {error && <p role="alert" className="text-xs text-warning">{error}</p>}

        <div className="flex justify-end pt-2">
          <Button type="submit" disabled={!health || busy}>
            <Save className="size-4" /> {busy ? 'Saving…' : 'Save Credentials'}
          </Button>
        </div>
      </form>
    </div>
  );
}
