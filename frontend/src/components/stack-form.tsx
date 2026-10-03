import { useState, type FormEvent } from 'react';
import { RefreshCw, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useVpn } from './vpn-provider';
import type { Location, Stack } from '@/lib/vpn';

type FormData = {
  id: string;
  ssid: string;
  password: string;
  ap_iface: string;
  vpn_type: string;
  vpn_country: string;
  vpn_city: string;
  ap_security: string;
  auto_reconnect_12h: boolean;
  subnet: string;
  routing_table: string;
  ap_channel: string;
  ap_hw_mode: string;
  ap_channel_width: string;
};

function formatCountrySlug(country: string): string {
  if (!country) return '';
  return country.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

export function StackForm({ stack, locations, onClose }: { stack?: Stack | undefined; locations: Location[]; onClose: () => void }) {
  const { interfaces, request, refresh, notify } = useVpn();
  const [form, setForm] = useState<FormData>({
    id: stack?.id || '',
    ssid: stack?.ssid || '',
    password: stack?.password || '',
    ap_iface: stack?.ap_iface || '',
    vpn_type: stack?.vpn_type || 'wireguard',
    vpn_country: stack?.vpn_country || '',
    vpn_city: stack?.vpn_city || '',
    ap_security: stack?.ap_security || 'wpa2',
    auto_reconnect_12h: stack?.auto_reconnect_12h || false,
    subnet: stack?.subnet || '',
    routing_table: stack ? String(stack.routing_table) : '',
    ap_channel: stack ? String(stack.ap_channel) : '',
    ap_hw_mode: stack?.ap_hw_mode || '',
    ap_channel_width: stack ? String(stack.ap_channel_width) : '',
  });

  const [userEditedId, setUserEditedId] = useState(!!stack?.id);
  const [userEditedSsid, setUserEditedSsid] = useState(!!stack?.ssid);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');

  const set = (key: keyof FormData, value: string | boolean) => setForm(prev => ({ ...prev, [key]: value }));
  const selected = interfaces.find(iface => iface.name === form.ap_iface);

  const applyCountryDefaults = (countryName: string, force = false) => {
    const slug = formatCountrySlug(countryName);
    const defaultId = slug ? `vpn-${slug}` : '';
    const defaultSsid = countryName ? `NordVPN-${countryName}` : '';
    const targetLoc = locations.find(l => l.name === countryName);
    const autoCity = (targetLoc?.cities?.length === 1) ? targetLoc.cities[0].name : '';

    setForm(prev => ({
      ...prev,
      vpn_country: countryName,
      vpn_city: autoCity,
      id: (!stack && (force || !userEditedId || !prev.id)) ? defaultId : prev.id,
      ssid: (force || !userEditedSsid || !prev.ssid) ? defaultSsid : prev.ssid,
    }));
  };

  const handleCountryChange = (countryName: string) => {
    applyCountryDefaults(countryName, false);
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setMessage('');
    try {
      const payload = {
        id: form.id.trim(),
        ssid: form.ssid.trim(),
        password: form.password,
        ap_iface: form.ap_iface,
        vpn_type: form.vpn_type,
        vpn_country: form.vpn_country,
        vpn_city: form.vpn_city,
        ap_security: form.ap_security,
        auto_reconnect_12h: form.auto_reconnect_12h,
        ...(form.subnet ? { subnet: form.subnet } : {}),
        ...(form.routing_table ? { routing_table: Number(form.routing_table) } : {}),
        ...(form.ap_channel ? { ap_channel: Number(form.ap_channel) } : {}),
        ...(form.ap_hw_mode ? { ap_hw_mode: form.ap_hw_mode } : {}),
        ...(form.ap_channel_width ? { ap_channel_width: Number(form.ap_channel_width) } : {}),
      };
      await request(stack ? `/stacks/${encodeURIComponent(stack.id)}` : '/stacks', {
        method: stack ? 'PATCH' : 'POST',
        body: JSON.stringify(payload),
      });
      await refresh();
      notify(stack ? 'Access point updated.' : 'Access point created. Start it from the dashboard.');
      onClose();
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : 'Could not save access point.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-background/85 p-3 md:p-6" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}>
      <section role="dialog" aria-modal="true" aria-label={stack ? 'Edit access point' : 'Create access point'} className="max-h-[92vh] w-full max-w-2xl overflow-auto rounded-md border border-border bg-card p-5 shadow-2xl md:p-7">
        <div className="mb-6 flex items-start justify-between">
          <div>
            <h2 className="font-mono text-xl font-bold">{stack ? 'Edit access point' : 'Create access point'}</h2>
            <p className="mt-1 text-sm text-muted-foreground">Configure Wi-Fi and VPN routing for this stack.</p>
          </div>
          <Button variant="ghost" size="icon" aria-label="Close" onClick={onClose}><X /></Button>
        </div>

        <form onSubmit={submit} className="space-y-5">
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="label">
              VPN country
              <select className="field mt-2" required value={form.vpn_country} onChange={e => handleCountryChange(e.target.value)}>
                <option value="">Select a country</option>
                {form.vpn_country && !locations.some(l => l.name === form.vpn_country) && (
                  <option value={form.vpn_country}>{form.vpn_country}</option>
                )}
                {locations.map(l => (
                  <option key={l.code || l.name} value={l.name}>{l.name}</option>
                ))}
              </select>
            </label>

            {(locations.find(l => l.name === form.vpn_country)?.cities?.length || !!form.vpn_city) && (
              <label className="label">
                VPN city (optional)
                <select className="field mt-2" value={form.vpn_city} onChange={e => set('vpn_city', e.target.value)}>
                  <option value="">Any city</option>
                  {form.vpn_city && !locations.find(l => l.name === form.vpn_country)?.cities?.some(c => c.name === form.vpn_city) && (
                    <option value={form.vpn_city}>{form.vpn_city}</option>
                  )}
                  {locations.find(l => l.name === form.vpn_country)?.cities?.map(c => (
                    <option key={c.name} value={c.name}>{c.name}</option>
                  ))}
                </select>
              </label>
            )}

            <div>
              <div className="flex items-center justify-between">
                <label className="label" htmlFor="stack-id-input">Stack ID</label>
                {form.vpn_country && !stack && (
                  <button type="button" onClick={() => applyCountryDefaults(form.vpn_country, true)} className="text-[11px] text-primary hover:underline flex items-center gap-1">
                    <RefreshCw className="size-3" /> Auto-name
                  </button>
                )}
              </div>
              <input
                id="stack-id-input"
                className="field mt-2"
                required
                disabled={!!stack}
                pattern="[a-zA-Z0-9_-]+"
                value={form.id}
                onChange={e => {
                  set('id', e.target.value);
                  setUserEditedId(true);
                }}
                placeholder="e.g. vpn-germany"
              />
              <p className="mt-1 text-[11px] text-muted-foreground">Unique identifier used for Docker containers.</p>
            </div>

            <div>
              <div className="flex items-center justify-between">
                <label className="label" htmlFor="ssid-input">Wi-Fi name (SSID)</label>
                {form.vpn_country && (
                  <button type="button" onClick={() => applyCountryDefaults(form.vpn_country, true)} className="text-[11px] text-primary hover:underline flex items-center gap-1">
                    <RefreshCw className="size-3" /> Auto-name
                  </button>
                )}
              </div>
              <input
                id="ssid-input"
                className="field mt-2"
                required
                value={form.ssid}
                onChange={e => {
                  set('ssid', e.target.value);
                  setUserEditedSsid(true);
                }}
                placeholder="e.g. NordVPN-Germany"
              />
              <p className="mt-1 text-[11px] text-muted-foreground">Broadcasted wireless network name.</p>
            </div>

            <label className="label">
              Wi-Fi password
              <input className="field mt-2" type="password" minLength={8} required value={form.password} onChange={e => set('password', e.target.value)} placeholder="At least 8 characters" />
            </label>

            <label className="label">
              Wireless interface
              <select className="field mt-2" required value={form.ap_iface} onChange={e => set('ap_iface', e.target.value)}>
                <option value="">Select an interface</option>
                {interfaces.filter(i => i.supports_ap || i.name === form.ap_iface).map(i => (
                  <option key={i.name} value={i.name}>{i.name} · {i.vendor_model}</option>
                ))}
              </select>
            </label>

            <label className="label">
              VPN protocol
              <select className="field mt-2" value={form.vpn_type} onChange={e => set('vpn_type', e.target.value)}>
                <option value="wireguard">WireGuard (NordLynx)</option>
                <option value="openvpn">OpenVPN</option>
              </select>
            </label>

            <label className="label">
              Wi-Fi security
              <select className="field mt-2" value={form.ap_security} onChange={e => set('ap_security', e.target.value)}>
                <option value="wpa2">WPA2</option>
                {selected?.supports_wpa3 && <option value="wpa3">WPA3</option>}
              </select>
            </label>
          </div>

          <label className="flex items-center gap-3 text-sm text-foreground">
            <input type="checkbox" checked={form.auto_reconnect_12h} onChange={e => set('auto_reconnect_12h', e.target.checked)} className="accent-primary" />
            Reconnect VPN every 12 hours
          </label>

          <details className="border-t border-border pt-4">
            <summary className="cursor-pointer font-mono text-xs text-muted-foreground">Advanced network settings</summary>
            <div className="mt-4 grid gap-4 sm:grid-cols-2">
              <label className="label">
                Subnet
                <input className="field mt-2" value={form.subnet} onChange={e => set('subnet', e.target.value)} placeholder="Auto-allocate" />
              </label>
              <label className="label">
                Routing table
                <input className="field mt-2" type="number" min="1" max="255" value={form.routing_table} onChange={e => set('routing_table', e.target.value)} placeholder="Auto-allocate" />
              </label>
              <label className="label">
                Channel
                <input className="field mt-2" type="number" min="1" max="255" value={form.ap_channel} onChange={e => set('ap_channel', e.target.value)} placeholder="Auto-select" />
              </label>
              <label className="label">
                Hardware mode
                <select className="field mt-2" value={form.ap_hw_mode} onChange={e => set('ap_hw_mode', e.target.value)}>
                  <option value="">Auto-select</option>
                  <option value="g">2.4 GHz (g)</option>
                  <option value="a">5 GHz (a)</option>
                </select>
              </label>
              <label className="label">
                Channel width
                <select className="field mt-2" value={form.ap_channel_width} onChange={e => set('ap_channel_width', e.target.value)}>
                  <option value="">Auto-select</option>
                  <option value="20">20 MHz</option>
                  <option value="40">40 MHz</option>
                  <option value="80">80 MHz</option>
                </select>
              </label>
            </div>
          </details>

          {message && <p role="alert" className="text-sm text-warning">{message}</p>}
          <div className="flex justify-end gap-2 border-t border-border pt-5">
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button disabled={busy || !form.ap_iface || !form.vpn_country} type="submit">
              {busy ? 'Saving…' : stack ? 'Save changes' : 'Create access point'}
            </Button>
          </div>
        </form>
      </section>
    </div>
  );
}
