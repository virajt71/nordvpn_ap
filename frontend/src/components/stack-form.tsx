import { useState, useEffect, type FormEvent } from 'react';
import {
  AlertCircle,
  Check,
  ChevronDown,
  Eye,
  EyeOff,
  KeyRound,
  Lock,
  Radio,
  RefreshCw,
  Shield,
  Wifi,
  X,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useVpn } from './vpn-provider';
import type { AdGuardDetectResult, Location, ScannedAccessPoint, Stack, WifiInterface } from '@/lib/vpn';

type FormData = {
  id: string;
  ssid: string;
  password: string;
  ap_iface: string;
  mode: 'ap' | 'repeater';
  vpn_enabled: boolean;
  uplink_iface: string;
  uplink_ssid: string;
  uplink_password: string;
  adguard_dns: string;
  adguard_dns_port: string;
  vpn_type: string;
  vpn_country: string;
  vpn_city: string;
  ap_security: string;
  auto_reconnect_8h: boolean;
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

function generateRandomPassword(): string {
  const chars = '23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
  let generated = '';
  for (let i = 0; i < 10; i++) {
    generated += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return generated;
}

function getUniqueStackId(baseId: string, existingStacks: Stack[], editingStackId?: string): string {
  const cleanBase = baseId.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '') || 'wifi-ap';
  const isTaken = (id: string) => existingStacks.some(s => s.id === id && s.id !== editingStackId);
  if (!isTaken(cleanBase)) return cleanBase;
  let counter = 2;
  while (isTaken(`${cleanBase}-${counter}`)) {
    counter++;
  }
  return `${cleanBase}-${counter}`;
}

function getUniqueSsid(baseSsid: string, existingStacks: Stack[], editingStackId?: string): string {
  const cleanBase = baseSsid.trim() || 'AccessPoint';
  const isTaken = (name: string) => existingStacks.some(s => s.ssid.toLowerCase() === name.toLowerCase() && s.id !== editingStackId);
  if (!isTaken(cleanBase)) return cleanBase;
  let counter = 2;
  while (isTaken(`${cleanBase} ${counter}`)) {
    counter++;
  }
  return `${cleanBase} ${counter}`;
}

const popularCountries = [
  { name: 'United States', code: 'US', flag: '🇺🇸' },
  { name: 'Germany', code: 'DE', flag: '🇩🇪' },
  { name: 'United Kingdom', code: 'GB', flag: '🇬🇧' },
  { name: 'Japan', code: 'JP', flag: '🇯🇵' },
  { name: 'Switzerland', code: 'CH', flag: '🇨🇭' },
  { name: 'Singapore', code: 'SG', flag: '🇸🇬' },
  { name: 'India', code: 'IN', flag: '🇮🇳' },
];

export function StackForm({ stack, locations, onClose }: { stack?: Stack | undefined; locations: Location[]; onClose: () => void }) {
  const { interfaces, stacks, request, refresh, notify } = useVpn();

  // Helper: check if an interface is in use by another stack (excluding currently edited stack)
  const getInterfaceLock = (ifaceName: string) => {
    if (!ifaceName) return { locked: false, stackId: null, role: null };
    const otherStacks = stacks.filter(s => s.id !== stack?.id);
    const apStack = otherStacks.find(s => s.ap_iface === ifaceName);
    if (apStack) return { locked: true, stackId: apStack.id, role: 'AP' as const };
    const uplinkStack = otherStacks.find(s => s.uplink_iface === ifaceName);
    if (uplinkStack) return { locked: true, stackId: uplinkStack.id, role: 'Uplink' as const };
    return { locked: false, stackId: null, role: null };
  };

  const availableApInterfaces = interfaces.filter(
    i => i.supports_ap && !getInterfaceLock(i.name).locked
  );

  // Find an available country not already used by an existing stack
  const availablePopularCountry =
    popularCountries.find(c => !stacks.some(s => s.id === `vpn-${formatCountrySlug(c.name)}`))?.name ||
    locations.find(l => !stacks.some(s => s.id === `vpn-${formatCountrySlug(l.name)}`))?.name ||
    'United States';

  const initialCountry = stack?.vpn_country || availablePopularCountry;
  const initialMode = stack?.mode || 'ap';
  const initialVpnEnabled = stack ? stack.vpn_enabled : initialMode === 'ap';

  const initialId = stack?.id || (
    initialMode === 'repeater'
      ? getUniqueStackId('repeater-ap', stacks)
      : getUniqueStackId(`vpn-${formatCountrySlug(initialCountry)}`, stacks)
  );

  const initialSsid = stack?.ssid || (
    initialMode === 'repeater'
      ? getUniqueSsid('HomeNet-Repeater', stacks)
      : getUniqueSsid(`NordVPN-${initialCountry}`, stacks)
  );

  const initialPassword = stack?.password || generateRandomPassword();

  // Initial AP interface: choose existing stack's iface or first unlocked AP-capable adapter
  const initialApIface = stack?.ap_iface || availableApInterfaces[0]?.name || '';
  const initialApMeta = interfaces.find(i => i.name === initialApIface);

  // Initial Uplink interface (for repeater mode): choose unlocked adapter not matching AP iface
  const initialUplinkIface = stack?.uplink_iface || (
    interfaces.find(i => i.name !== initialApIface && !getInterfaceLock(i.name).locked)?.name || ''
  );

  const [form, setForm] = useState<FormData>({
    id: initialId,
    ssid: initialSsid,
    password: initialPassword,
    ap_iface: initialApIface,
    mode: initialMode,
    vpn_enabled: initialVpnEnabled,
    uplink_iface: initialUplinkIface,
    uplink_ssid: stack?.uplink_ssid || '',
    uplink_password: stack?.uplink_password || '',
    adguard_dns: stack?.adguard_dns || '',
    adguard_dns_port: stack?.adguard_dns_port ? String(stack.adguard_dns_port) : '53',
    vpn_type: stack?.vpn_type || 'wireguard',
    vpn_country: initialCountry,
    vpn_city: stack?.vpn_city || '',
    ap_security: stack?.ap_security || 'wpa2',
    auto_reconnect_8h: stack?.auto_reconnect_8h ?? stack?.auto_reconnect_12h ?? false,
    subnet: stack?.subnet || '',
    routing_table: stack ? String(stack.routing_table) : '',
    ap_channel: stack ? String(stack.ap_channel) : (initialApMeta ? String(initialApMeta.default_channel) : ''),
    ap_hw_mode: stack?.ap_hw_mode || initialApMeta?.default_hw_mode || '',
    ap_channel_width: stack ? String(stack.ap_channel_width) : (initialApMeta ? String(initialApMeta.default_width) : ''),
  });

  const [userEditedId, setUserEditedId] = useState(!!stack?.id);
  const [userEditedSsid, setUserEditedSsid] = useState(!!stack?.ssid);
  const [showPassword, setShowPassword] = useState(false);
  const [showParentPassword, setShowParentPassword] = useState(false);
  const [customParentSsid, setCustomParentSsid] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [scannedAps, setScannedAps] = useState<ScannedAccessPoint[]>([]);
  const [isScanning, setIsScanning] = useState(false);
  const [detectedAdGuard, setDetectedAdGuard] = useState<AdGuardDetectResult | null>(null);

  // Auto-detect running AdGuard Home instance on mount
  useEffect(() => {
    let active = true;
    request<AdGuardDetectResult>('/dns/adguard/detect')
      .then(res => {
        if (!active) return;
        setDetectedAdGuard(res);
        // If creating a new stack directly in repeater mode, auto-fill AdGuard DNS
        if (!stack && form.mode === 'repeater' && res?.detected && res.ip) {
          setForm(prev => (prev.adguard_dns ? prev : {
            ...prev,
            adguard_dns: res.ip || '',
            adguard_dns_port: String(res.port || 53),
          }));
        }
      })
      .catch(() => {
        if (active) setDetectedAdGuard({ detected: false, ip: null, port: 53 });
      });
    return () => { active = false; };
  }, []);

  // Filter out driver dump garbage (<invalid...) and empty/null SSIDs
  const validScannedAps = scannedAps.filter(
    ap => ap.ssid && !ap.ssid.startsWith('<invalid') && !ap.ssid.includes('\0')
  );

  const scanWifi = async (targetIface?: string) => {
    setIsScanning(true);
    try {
      const ifaceToScan = targetIface || form.uplink_iface;
      const query = ifaceToScan ? `?iface=${encodeURIComponent(ifaceToScan)}` : '';
      const list = await request<ScannedAccessPoint[]>(`/wifi/scan${query}`);
      const filtered = (list || []).filter(
        ap => ap.ssid && !ap.ssid.startsWith('<invalid') && !ap.ssid.includes('\0')
      );
      setScannedAps(filtered);
      if (filtered.length > 0) {
        notify(`Discovered ${filtered.length} nearby Wi-Fi network${filtered.length === 1 ? '' : 's'}.`);
      }
    } catch {
      // Keep existing list on transient scan errors
    } finally {
      setIsScanning(false);
    }
  };

  useEffect(() => {
    if (form.mode === 'repeater') {
      scanWifi(form.uplink_iface);
    }
  }, [form.mode, form.uplink_iface]);

  const selectedScannedAp = validScannedAps.find(a => a.ssid === form.uplink_ssid);

  const set = (key: keyof FormData, value: string | boolean) => setForm(prev => ({ ...prev, [key]: value }));
  const selected = interfaces.find(iface => iface.name === form.ap_iface);
  const selectedInUse = stacks.find(s => s.id !== form.id && s.ap_iface === form.ap_iface);

  const channelNum = Number(form.ap_channel);
  const effectiveHwMode = (
    channelNum > 14
      ? 'a'
      : channelNum > 0
      ? 'g'
      : selected && !selected.supports_5ghz
      ? 'g'
      : selected && !selected.supports_2_4ghz
      ? 'a'
      : form.ap_hw_mode === 'a' || form.ap_hw_mode === 'g'
      ? form.ap_hw_mode
      : selected?.default_hw_mode === 'a'
      ? 'a'
      : 'g'
  );

  const handleHwModeChange = (newMode: string) => {
    setForm(prev => {
      let nextChannel = prev.ap_channel;
      let nextWidth = prev.ap_channel_width;
      if (newMode === 'g') {
        if (Number(nextChannel) > 14) nextChannel = '6';
        if (Number(nextWidth) > 40) nextWidth = '20';
      } else if (newMode === 'a') {
        if (Number(nextChannel) <= 14 && nextChannel !== '') nextChannel = '36';
      }
      return {
        ...prev,
        ap_hw_mode: newMode,
        ap_channel: nextChannel,
        ap_channel_width: nextWidth,
      };
    });
  };

  const generateStrongPassword = () => {
    const pw = generateRandomPassword();
    set('password', pw);
    setShowPassword(true);
    notify('Generated a secure 10-character Wi-Fi password.');
  };

  // Auto-select first AP-capable interface that is NOT in use by another stack
  useEffect(() => {
    if (!stack && interfaces.length > 0) {
      const currentLock = getInterfaceLock(form.ap_iface);
      if (!form.ap_iface || currentLock.locked) {
        const candidate =
          availableApInterfaces.find(i => i.name !== form.uplink_iface) ||
          availableApInterfaces[0];
        if (candidate) {
          setForm(prev => ({
            ...prev,
            ap_iface: candidate.name,
            ap_channel: prev.ap_channel || String(candidate.default_channel),
            ap_hw_mode: prev.ap_hw_mode || candidate.default_hw_mode,
            ap_channel_width: prev.ap_channel_width || String(candidate.default_width),
          }));
        } else {
          setForm(prev => ({ ...prev, ap_iface: '' }));
        }
      }

      if (form.mode === 'repeater') {
        const uplinkLock = getInterfaceLock(form.uplink_iface);
        if (!form.uplink_iface || uplinkLock.locked || form.uplink_iface === form.ap_iface) {
          const candidateUplink = interfaces.find(
            i => i.name !== form.ap_iface && !getInterfaceLock(i.name).locked
          );
          if (candidateUplink) {
            setForm(prev => ({ ...prev, uplink_iface: candidateUplink.name }));
            scanWifi(candidateUplink.name);
          }
        }
      }
    }
  }, [interfaces, stacks, stack, form.ap_iface, form.uplink_iface, form.mode]);

  const selectApIface = (iface: WifiInterface) => {
    const lock = getInterfaceLock(iface.name);
    if (lock.locked) {
      notify(`Interface "${iface.name}" is locked by stack "${lock.stackId}". Selection blocked.`);
      return;
    }
    setForm(prev => {
      let nextUplink = prev.uplink_iface;
      if (prev.mode === 'repeater' && prev.uplink_iface === iface.name) {
        const alt = interfaces.find(i => i.name !== iface.name && !getInterfaceLock(i.name).locked);
        nextUplink = alt?.name || '';
      }

      let nextHwMode = prev.ap_hw_mode || iface.default_hw_mode;
      if (!iface.supports_5ghz && nextHwMode === 'a') {
        nextHwMode = 'g';
      } else if (!iface.supports_2_4ghz && nextHwMode === 'g') {
        nextHwMode = 'a';
      }

      let nextChannel = prev.ap_channel;
      if (nextHwMode === 'g' && Number(nextChannel) > 14) {
        nextChannel = String(iface.default_channel || 6);
      } else if (nextHwMode === 'a' && Number(nextChannel) <= 14 && nextChannel !== '') {
        nextChannel = '36';
      }

      let nextWidth = prev.ap_channel_width;
      if (nextHwMode === 'g' && Number(nextWidth) > 40) {
        nextWidth = '20';
      }

      return {
        ...prev,
        ap_iface: iface.name,
        uplink_iface: nextUplink,
        ap_security: (!iface.supports_wpa3 && prev.ap_security === 'wpa3') ? 'wpa2' : prev.ap_security,
        ap_channel: nextChannel,
        ap_hw_mode: nextHwMode,
        ap_channel_width: nextWidth,
      };
    });
  };

  // Operating Mode Switcher Handler
  const handleModeChange = (newMode: 'ap' | 'repeater') => {
    if (newMode === 'ap') {
      const countryToUse = form.vpn_country || availablePopularCountry;
      const autoId = getUniqueStackId(`vpn-${formatCountrySlug(countryToUse)}`, stacks, stack?.id);
      const autoSsid = getUniqueSsid(`NordVPN-${countryToUse}`, stacks, stack?.id);
      setForm(prev => ({
        ...prev,
        mode: 'ap',
        vpn_enabled: true,
        vpn_country: countryToUse,
        id: !stack && !userEditedId ? autoId : prev.id,
        ssid: !stack && !userEditedSsid ? autoSsid : prev.ssid,
      }));
    } else if (newMode === 'repeater') {
      const autoId = getUniqueStackId('repeater-ap', stacks, stack?.id);
      const autoSsid = getUniqueSsid('HomeNet-Repeater', stacks, stack?.id);
      const candidateUplink =
        interfaces.find(i => i.name !== form.ap_iface && !getInterfaceLock(i.name).locked)?.name || '';

      // Auto-detect & add AdGuard DNS IP for repeater mode when creating a stack
      let autoAdGuardDns = form.adguard_dns;
      let autoAdGuardPort = form.adguard_dns_port;
      if (!stack) {
        if (detectedAdGuard?.detected && detectedAdGuard.ip) {
          autoAdGuardDns = detectedAdGuard.ip;
          autoAdGuardPort = String(detectedAdGuard.port || 53);
        } else if (!form.adguard_dns) {
          autoAdGuardDns = '';
        }
      }

      setForm(prev => ({
        ...prev,
        mode: 'repeater',
        vpn_enabled: false,
        uplink_iface: candidateUplink,
        adguard_dns: autoAdGuardDns,
        adguard_dns_port: autoAdGuardPort,
        id: !stack && !userEditedId ? autoId : prev.id,
        ssid: !stack && !userEditedSsid ? autoSsid : prev.ssid,
      }));
      if (candidateUplink) {
        scanWifi(candidateUplink);
      }
    }
  };

  const handleCountryChange = (countryName: string) => {
    const targetLoc = locations.find(l => l.name === countryName);
    const autoCity = (targetLoc?.cities?.length === 1 && targetLoc.cities[0]) ? targetLoc.cities[0].name : '';
    const autoId = getUniqueStackId(`vpn-${formatCountrySlug(countryName)}`, stacks, stack?.id);
    const autoSsid = getUniqueSsid(`NordVPN-${countryName}`, stacks, stack?.id);

    setForm(prev => ({
      ...prev,
      vpn_country: countryName,
      vpn_city: autoCity,
      id: !stack && !userEditedId ? autoId : prev.id,
      ssid: !stack && !userEditedSsid ? autoSsid : prev.ssid,
    }));
  };

  // Derive effective ID
  const effectiveId = form.id.trim() || (
    form.mode === 'ap' && form.vpn_enabled && form.vpn_country
      ? getUniqueStackId(`vpn-${formatCountrySlug(form.vpn_country)}`, stacks, stack?.id)
      : form.mode === 'repeater'
      ? getUniqueStackId('repeater-ap', stacks, stack?.id)
      : 'wifi-ap'
  );

  // Check whether effectiveId is already taken by an existing stack
  const isIdConflict = !stack && stacks.some(s => s.id.toLowerCase() === effectiveId.toLowerCase());

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setMessage('');

    if (isIdConflict) {
      setMessage(`Stack ID "${effectiveId}" already exists. Please choose a unique Stack Identifier in Advanced Settings.`);
      setBusy(false);
      return;
    }

    const apLock = getInterfaceLock(form.ap_iface);
    if (apLock.locked) {
      setMessage(`Network interface "${form.ap_iface}" is already locked by stack "${apLock.stackId}". Operation blocked to prevent interface overlap.`);
      setBusy(false);
      return;
    }

    if (form.mode === 'repeater') {
      if (!form.uplink_iface) {
        setMessage('Please select an uplink interface for repeater mode.');
        setBusy(false);
        return;
      }
      const uplinkLock = getInterfaceLock(form.uplink_iface);
      if (uplinkLock.locked) {
        setMessage(`Uplink interface "${form.uplink_iface}" is already locked by stack "${uplinkLock.stackId}". Operation blocked to prevent interface overlap.`);
        setBusy(false);
        return;
      }
      if (!form.uplink_ssid.trim()) {
        setMessage('Please specify the parent Wi-Fi SSID for repeater mode.');
        setBusy(false);
        return;
      }
      if (form.uplink_iface === form.ap_iface) {
        setMessage('The uplink interface cannot be the same as the access point interface.');
        setBusy(false);
        return;
      }
    }

    try {
      const isApMode = form.mode === 'ap';
      const payload = {
        id: effectiveId,
        ssid: form.ssid.trim(),
        password: form.password,
        ap_iface: form.ap_iface,
        mode: form.mode,
        vpn_enabled: isApMode,
        uplink_iface: form.mode === 'repeater' ? form.uplink_iface : '',
        uplink_ssid: form.mode === 'repeater' ? form.uplink_ssid.trim() : '',
        uplink_password: form.mode === 'repeater' ? form.uplink_password : '',
        adguard_dns: form.adguard_dns.trim(),
        adguard_dns_port: Number(form.adguard_dns_port) || 53,
        vpn_type: isApMode ? form.vpn_type : 'wireguard',
        vpn_country: isApMode ? form.vpn_country : 'Direct',
        vpn_city: isApMode ? form.vpn_city : '',
        ap_security: form.ap_security,
        auto_reconnect_8h: isApMode ? form.auto_reconnect_8h : false,
        auto_reconnect_12h: isApMode ? form.auto_reconnect_8h : false,
        ...(form.subnet ? { subnet: form.subnet } : {}),
        ...(form.routing_table ? { routing_table: Number(form.routing_table) } : {}),
        ...(form.ap_channel ? { ap_channel: Number(form.ap_channel) } : {}),
        ...(effectiveHwMode ? { ap_hw_mode: effectiveHwMode } : {}),
        ...(form.ap_channel_width ? { ap_channel_width: Number(form.ap_channel_width) } : {}),
      };

      await request(stack ? `/stacks/${encodeURIComponent(stack.id)}` : '/stacks', {
        method: stack ? 'PATCH' : 'POST',
        body: JSON.stringify(payload),
      });
      await refresh();
      notify(stack ? 'Access point updated.' : 'Access point created. Ready to start from dashboard.');
      onClose();
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : 'Could not save access point.');
    } finally {
      setBusy(false);
    }
  };

  const apLock = getInterfaceLock(form.ap_iface);
  const uplinkLock = form.mode === 'repeater' ? getInterfaceLock(form.uplink_iface) : { locked: false, stackId: null, role: null };
  const isApLocked = Boolean(apLock.locked);
  const isUplinkLocked = Boolean(uplinkLock.locked);
  const isOverlap = Boolean(form.mode === 'repeater' && form.uplink_iface && form.uplink_iface === form.ap_iface);

  const isFormValid = Boolean(
    !isIdConflict &&
    !isApLocked &&
    !isUplinkLocked &&
    !isOverlap &&
    effectiveId &&
    form.ssid.trim() &&
    form.password &&
    form.password.length >= 8 &&
    form.ap_iface &&
    (form.mode !== 'repeater' || (form.uplink_iface && form.uplink_ssid.trim())) &&
    (form.mode !== 'ap' || form.vpn_country)
  );

  const missingHints: string[] = [];
  if (isIdConflict) missingHints.push(`ID taken ("${effectiveId}")`);
  if (isApLocked) missingHints.push(`AP interface "${form.ap_iface}" locked by ${apLock.stackId}`);
  if (isUplinkLocked) missingHints.push(`Uplink interface "${form.uplink_iface}" locked by ${uplinkLock.stackId}`);
  if (isOverlap) missingHints.push('AP and Uplink interface overlap');
  if (!form.ap_iface) missingHints.push('AP Adapter');
  if (!form.ssid.trim()) missingHints.push('SSID');
  if (!form.password || form.password.length < 8) missingHints.push('Password (min 8 chars)');
  if (form.mode === 'repeater' && !form.uplink_iface) missingHints.push('Uplink Adapter');
  if (form.mode === 'repeater' && !form.uplink_ssid.trim()) missingHints.push('Parent Wi-Fi');
  if (form.mode === 'ap' && !form.vpn_country) missingHints.push('VPN Country');

  const buttonLabel = busy
    ? 'Saving…'
    : stack
    ? 'Save Changes'
    : form.mode === 'repeater'
    ? 'Deploy Repeater AP'
    : form.vpn_country
    ? `Deploy AP (${form.vpn_country})`
    : 'Deploy VPN Access Point';

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-background/80 backdrop-blur-sm p-3 md:p-6"
      onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-label={stack ? 'Edit access point' : 'Create access point'}
        className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-xl border border-border bg-card p-5 shadow-2xl md:p-6 space-y-4"
      >
        {/* ─── Header ──────────────────────────────────────────────────────── */}
        <div className="flex items-start justify-between border-b border-border/60 pb-3">
          <div>
            <h2 className="font-mono text-base md:text-lg font-bold text-foreground flex items-center gap-2">
              <Wifi className="size-4 text-primary" />
              {stack ? 'Edit Access Point' : 'New Access Point'}
            </h2>
            <p className="mt-0.5 text-xs text-muted-foreground">
              Configure wireless AP, routing, and optional VPN tunnel.
            </p>
          </div>
          <Button variant="ghost" size="icon" aria-label="Close" onClick={onClose} className="text-muted-foreground hover:text-foreground">
            <X className="size-4" />
          </Button>
        </div>

        <form onSubmit={submit} className="space-y-4">
          {/* ─── 1. Operating Mode Switcher ─────────────────────────────────── */}
          <div>
            <label className="text-[11px] font-mono font-medium text-muted-foreground mb-1 block">Operating Mode</label>
            <div className="grid grid-cols-2 gap-1 rounded-lg border border-border bg-secondary/30 p-1 text-center">
              {[
                { id: 'ap' as const, label: 'Access Point', desc: 'VPN or Direct Hotspot', Icon: Radio },
                { id: 'repeater' as const, label: 'Repeater Mode', desc: 'Wi-Fi Extender', Icon: Wifi },
              ].map(m => {
                const Icon = m.Icon;
                const isActive = form.mode === m.id;
                return (
                  <button
                    key={m.id}
                    type="button"
                    onClick={() => handleModeChange(m.id)}
                    className={`flex flex-col items-center justify-center gap-0.5 rounded-md py-1.5 px-2 transition-all ${
                      isActive
                        ? 'bg-card text-foreground shadow-sm ring-1 ring-border font-semibold'
                        : 'text-muted-foreground hover:text-foreground hover:bg-secondary/40'
                    }`}
                  >
                    <div className="flex items-center gap-1.5 text-xs">
                      <Icon className="size-3.5" />
                      <span>{m.label}</span>
                    </div>
                    <span className="text-[10px] text-muted-foreground font-normal hidden sm:inline">{m.desc}</span>
                  </button>
                );
              })}
            </div>
          </div>

          {/* ─── 2. Uplink Settings (Repeater only) ─────────────────────────── */}
          {form.mode === 'repeater' && (
            <div className="rounded-lg border border-border bg-secondary/20 p-3.5 space-y-3">
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold text-foreground flex items-center gap-1.5">
                  <Wifi className="size-3.5 text-primary" />
                  Parent Wi-Fi Connection (Uplink)
                </span>
                <span className="text-[10px] font-mono text-muted-foreground">Source network</span>
              </div>

              <div className="grid gap-3 sm:grid-cols-2">
                <div className="sm:col-span-2">
                  <div className="flex items-center justify-between">
                    <label className="label text-xs" htmlFor="uplink-iface-select">
                      Uplink Interface
                    </label>
                    <span className="text-[10px] font-mono text-muted-foreground">
                      Wireless card connecting to upstream Wi-Fi
                    </span>
                  </div>
                  <div className="relative mt-1">
                    <select
                      id="uplink-iface-select"
                      className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                      value={form.uplink_iface}
                      onChange={e => {
                        const val = e.target.value;
                        set('uplink_iface', val);
                        if (val) {
                          scanWifi(val);
                        }
                      }}
                      required
                    >
                      <option value="" disabled className="bg-card text-muted-foreground">
                        Select uplink wireless interface...
                      </option>
                      {interfaces.map(i => {
                        const isCurrentAp = i.name === form.ap_iface;
                        const lock = getInterfaceLock(i.name);
                        const isOptDisabled = isCurrentAp || lock.locked;

                        const bandInfo = [
                          i.supports_2_4ghz && i.supports_5ghz ? '2.4 / 5 GHz' : i.supports_5ghz ? '5 GHz' : '2.4 GHz',
                          i.supports_ax ? 'Wi-Fi 6' : i.supports_ac ? 'AC' : i.supports_n ? 'N' : '',
                        ].filter(Boolean).join(' · ');

                        return (
                          <option
                            key={i.name}
                            value={i.name}
                            disabled={isOptDisabled}
                            className="bg-card text-foreground disabled:text-muted-foreground/60 py-1"
                          >
                            {i.name} — {i.vendor_model || 'Wireless Interface'} ({bandInfo}){
                              isCurrentAp
                                ? ' [Disabled: Currently Assigned as AP]'
                                : lock.locked
                                ? ` [Locked: in use by ${lock.stackId}]`
                                : ' — Available'
                            }
                          </option>
                        );
                      })}
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                  </div>
                  {interfaces.every(i => i.name === form.ap_iface || getInterfaceLock(i.name).locked) && (
                    <span className="text-[10px] text-destructive font-mono flex items-center gap-1 mt-1">
                      <AlertCircle className="size-3 shrink-0" />
                      No separate wireless interface available for repeater uplink.
                    </span>
                  )}
                </div>

                {form.mode === 'repeater' && (
                  <div className="sm:col-span-2 space-y-2">
                    <div className="flex items-center justify-between">
                      <label className="label text-xs" htmlFor="parent-ssid-input">
                        Parent Wi-Fi Network (SSID)
                      </label>
                      <button
                        type="button"
                        onClick={() => scanWifi(form.uplink_iface)}
                        disabled={isScanning}
                        className="text-[11px] text-primary hover:underline flex items-center gap-1 font-mono transition-opacity disabled:opacity-50"
                      >
                        <RefreshCw className={`size-3 ${isScanning ? 'animate-spin' : ''}`} />
                        <span>{isScanning ? 'Scanning Wi-Fi…' : 'Scan Nearby Wi-Fi'}</span>
                      </button>
                    </div>

                    {/* Scanned networks dropdown selector */}
                    {validScannedAps.length > 0 && !customParentSsid ? (
                      <div className="space-y-2">
                        <select
                          className="field text-xs bg-card"
                          value={validScannedAps.some(a => a.ssid === form.uplink_ssid) ? form.uplink_ssid : ''}
                          onChange={e => {
                            const val = e.target.value;
                            if (val === '__custom__') {
                              setCustomParentSsid(true);
                            } else if (val) {
                              set('uplink_ssid', val);
                              const ap = validScannedAps.find(a => a.ssid === val);
                              if (ap?.security === 'Open') {
                                notify(`"${ap.ssid}" is an open network (no password needed).`);
                              }
                            }
                          }}
                        >
                          <option value="">
                            {form.uplink_ssid && !validScannedAps.some(a => a.ssid === form.uplink_ssid)
                              ? `Selected custom SSID: "${form.uplink_ssid}"`
                              : `Select nearby Wi-Fi network (${validScannedAps.length} detected)...`}
                          </option>
                          {validScannedAps.map(ap => (
                            <option key={`${ap.bssid}-${ap.ssid}`} value={ap.ssid}>
                              {ap.ssid} · {ap.signal_percent}% ({ap.signal_dbm} dBm) · {ap.security} · Ch {ap.channel}
                            </option>
                          ))}
                          <option value="__custom__">✏️ Enter hidden or custom SSID manually...</option>
                        </select>

                        {/* Top quick-pick pills when no SSID selected or to switch quickly */}
                        <div className="flex flex-wrap items-center justify-between gap-1.5">
                          <div className="flex flex-wrap items-center gap-1.5">
                            <span className="text-[10px] text-muted-foreground font-mono">Nearby:</span>
                            {validScannedAps.slice(0, 4).map(ap => {
                              const isSelected = form.uplink_ssid === ap.ssid;
                              return (
                                <button
                                  key={ap.ssid}
                                  type="button"
                                  onClick={() => set('uplink_ssid', ap.ssid)}
                                  className={`flex items-center gap-1 rounded px-2 py-0.5 text-[10px] font-mono transition-all ${
                                    isSelected
                                      ? 'bg-primary/20 text-primary font-semibold ring-1 ring-primary/40'
                                      : 'bg-secondary/60 text-muted-foreground hover:bg-secondary hover:text-foreground'
                                  }`}
                                >
                                  <Wifi className="size-2.5" />
                                  <span className="truncate max-w-[120px]">{ap.ssid}</span>
                                  <span className="opacity-70 text-[9px]">{ap.signal_percent}%</span>
                                </button>
                              );
                            })}
                          </div>

                          <button
                            type="button"
                            onClick={() => setCustomParentSsid(true)}
                            className="text-[10px] text-primary hover:underline font-mono ml-auto"
                          >
                            + Custom SSID
                          </button>
                        </div>
                      </div>
                    ) : (
                      /* Manual SSID input fallback */
                      <div className="space-y-1.5">
                        <div className="relative">
                          <input
                            id="parent-ssid-input"
                            list="detected-ssids"
                            className="field text-xs font-mono"
                            required
                            value={form.uplink_ssid}
                            onChange={e => set('uplink_ssid', e.target.value)}
                            placeholder="Enter parent Wi-Fi SSID (e.g. HomeNet-5G)..."
                          />
                          <datalist id="detected-ssids">
                            {validScannedAps.map(ap => (
                              <option key={ap.ssid} value={ap.ssid}>
                                {ap.security} ({ap.signal_percent}% signal)
                              </option>
                            ))}
                          </datalist>
                        </div>
                        {validScannedAps.length > 0 && (
                          <div className="flex justify-end">
                            <button
                              type="button"
                              onClick={() => setCustomParentSsid(false)}
                              className="text-[10px] text-primary hover:underline font-mono"
                            >
                              ← Choose from {validScannedAps.length} scanned networks
                            </button>
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                )}

                {form.mode === 'repeater' && (
                  <div className="sm:col-span-2">
                    <div className="flex items-center justify-between">
                      <label className="label text-xs">Parent Wi-Fi Password</label>
                      {selectedScannedAp && (
                        <span className="text-[10px] font-mono">
                          {selectedScannedAp.security === 'Open' ? (
                            <span className="text-success font-medium flex items-center gap-1">
                              <Check className="size-3" /> Open network (no password needed)
                            </span>
                          ) : (
                            <span className="text-muted-foreground">Security: {selectedScannedAp.security}</span>
                          )}
                        </span>
                      )}
                    </div>
                    <div className="relative mt-1">
                      <input
                        className="field text-xs pr-8 font-mono"
                        type={showParentPassword ? 'text' : 'password'}
                        value={form.uplink_password}
                        onChange={e => set('uplink_password', e.target.value)}
                        placeholder={selectedScannedAp?.security === 'Open' ? 'Not required for open network' : 'Leave blank if parent network is open'}
                      />
                      <button
                        type="button"
                        onClick={() => setShowParentPassword(p => !p)}
                        className="absolute right-2 top-2.5 text-muted-foreground hover:text-foreground p-0.5"
                        title={showParentPassword ? 'Hide password' : 'Show password'}
                        aria-label={showParentPassword ? 'Hide password' : 'Show password'}
                      >
                        {showParentPassword ? <EyeOff className="size-3.5" /> : <Eye className="size-3.5" />}
                      </button>
                    </div>
                  </div>
                )}
              </div>
            </div>
          )}

          {/* ─── 3. Routing & VPN Notice/Configuration ─────────────────────── */}
          {form.mode === 'ap' && (
            <div className="rounded-lg border border-border bg-secondary/15 p-3.5 space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2 text-xs font-semibold text-foreground">
                  <Shield className="size-3.5 text-primary" />
                  <span>Tunnel through NordVPN</span>
                </div>
                <span className="text-[10px] font-mono text-primary font-medium flex items-center gap-1.5">
                  <span className="size-1.5 rounded-full bg-primary animate-pulse" />
                  Encrypted Gluetun tunnel
                </span>
              </div>

              <div className="space-y-3 pt-0.5">
                {/* Popular countries quick-pick */}
                <div>
                  <div className="text-[10px] font-mono text-muted-foreground mb-1.5">Popular:</div>
                  <div className="grid grid-cols-4 sm:grid-cols-7 gap-1.5">
                    {popularCountries.map(c => {
                      const isSelected = form.vpn_country === c.name;
                      return (
                        <button
                          key={c.name}
                          type="button"
                          onClick={() => handleCountryChange(c.name)}
                          className={`flex items-center justify-center gap-1 py-1.5 px-1.5 rounded-md border text-xs font-mono transition-all ${
                            isSelected
                              ? 'border-primary bg-primary/15 text-primary font-semibold ring-1 ring-primary/40'
                              : 'border-border/60 bg-secondary/40 text-muted-foreground hover:border-border hover:text-foreground'
                          }`}
                        >
                          <span>{c.flag}</span>
                          <span className="truncate">{c.code}</span>
                        </button>
                      );
                    })}
                  </div>
                </div>

                {/* Country, City, Protocol Row */}
                <div className="grid gap-2.5 sm:grid-cols-3">
                  <div>
                    <label className="label text-[11px]">Country</label>
                    <div className="relative mt-1">
                      <select
                        className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                        required
                        value={form.vpn_country}
                        onChange={e => handleCountryChange(e.target.value)}
                      >
                        <option value="">Select country</option>
                        {form.vpn_country && !locations.some(l => l.name === form.vpn_country) && (
                          <option value={form.vpn_country}>{form.vpn_country}</option>
                        )}
                        {locations.map(l => (
                          <option key={l.code || l.name} value={l.name}>{l.name}</option>
                        ))}
                      </select>
                      <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                    </div>
                  </div>

                  <div>
                    <label className="label text-[11px]">City (optional)</label>
                    <div className="relative mt-1">
                      <select
                        className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                        value={form.vpn_city}
                        onChange={e => set('vpn_city', e.target.value)}
                      >
                        <option value="">Any city</option>
                        {locations.find(l => l.name === form.vpn_country)?.cities?.map(c => (
                          <option key={c.name} value={c.name}>{c.name}</option>
                        ))}
                      </select>
                      <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                    </div>
                  </div>

                  <div>
                    <label className="label text-[11px]">Protocol</label>
                    <div className="relative mt-1">
                      <select
                        className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                        value={form.vpn_type}
                        onChange={e => set('vpn_type', e.target.value)}
                      >
                        <option value="wireguard">WireGuard (NordLynx)</option>
                        <option value="openvpn">OpenVPN</option>
                      </select>
                      <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                    </div>
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* ─── 4. Wireless Broadcast Radio & Credentials ──────────────────── */}
          <div className="rounded-lg border border-border bg-secondary/15 p-3.5 space-y-3">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold text-foreground flex items-center gap-1.5">
                <Radio className="size-3.5 text-primary" />
                Access Point Interface
              </span>
              <span className="text-[10px] font-mono text-muted-foreground">
                {interfaces.filter(i => i.supports_ap).length} AP-capable detected
              </span>
            </div>

            {!stack && availableApInterfaces.length === 0 && (
              <div className="rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-xs text-destructive flex items-start gap-2.5">
                <Lock className="size-4 shrink-0 mt-0.5" />
                <div>
                  <span className="font-semibold text-foreground">No available wireless adapters</span>
                  <p className="mt-0.5 text-[11px] text-muted-foreground">
                    All detected Wi-Fi interfaces are currently locked by other stacks. To avoid hardware and network overlap, you cannot deploy another access point until an adapter is released or an additional USB Wi-Fi dongle is connected.
                  </p>
                </div>
              </div>
            )}

            {/* Interface cards */}
            {interfaces.length === 0 ? (
              <div className="rounded-md border border-dashed border-border p-3 text-center">
                <input
                  className="field text-xs"
                  placeholder="Manual interface name (e.g. wlan0)"
                  value={form.ap_iface}
                  onChange={e => set('ap_iface', e.target.value)}
                  required
                />
              </div>
            ) : (
              <div className="grid gap-1.5">
                {interfaces.map(iface => {
                  const isSelected = form.ap_iface === iface.name;
                  const isCurrentUplink = form.mode === 'repeater' && form.uplink_iface === iface.name;
                  const lock = getInterfaceLock(iface.name);
                  const isLocked = lock.locked;
                  const isDisabled = isLocked || isCurrentUplink || !iface.supports_ap;

                  const bandSummary = [
                    iface.supports_2_4ghz && iface.supports_5ghz ? '2.4 / 5 GHz' : iface.supports_5ghz ? '5 GHz' : '2.4 GHz',
                    iface.supports_ax ? 'Wi-Fi 6' : iface.supports_ac ? 'AC' : iface.supports_n ? 'N' : '',
                  ].filter(Boolean).join(' · ');

                  return (
                    <button
                      key={iface.name}
                      type="button"
                      disabled={isDisabled}
                      onClick={() => !isDisabled && selectApIface(iface)}
                      className={`flex items-center justify-between px-3 py-2 rounded-md border text-left transition-all ${
                        isSelected
                          ? 'border-primary/70 bg-primary/10 shadow-sm ring-1 ring-primary/30'
                          : isLocked
                          ? 'border-destructive/30 bg-destructive/5 opacity-60 cursor-not-allowed select-none'
                          : isDisabled
                          ? 'border-border/40 opacity-40 cursor-not-allowed bg-secondary/10 select-none'
                          : 'border-border/70 bg-secondary/30 hover:border-border hover:bg-secondary/50 cursor-pointer'
                      }`}
                    >
                      <div className="flex items-center gap-2.5 min-w-0">
                        <div className={`size-3 rounded-full border flex items-center justify-center shrink-0 ${
                          isSelected
                            ? 'border-primary bg-primary'
                            : isLocked
                            ? 'border-destructive bg-destructive/20 text-destructive'
                            : 'border-border'
                        }`}>
                          {isSelected ? (
                            <div className="size-1 rounded-full bg-primary-foreground" />
                          ) : isLocked ? (
                            <Lock className="size-2 text-destructive" />
                          ) : null}
                        </div>
                        <div className="flex items-center gap-2 min-w-0">
                          <span className={`font-mono text-xs font-bold ${isLocked ? 'text-destructive/90' : 'text-foreground'}`}>
                            {iface.name}
                          </span>
                          <span className="text-[11px] text-muted-foreground truncate hidden sm:inline">
                            {iface.vendor_model}
                          </span>
                        </div>
                      </div>

                      <div className="flex items-center gap-2 shrink-0 font-mono text-[10px]">
                        {bandSummary && (
                          <span className="text-muted-foreground hidden md:inline">
                            {bandSummary}
                          </span>
                        )}
                        {isLocked ? (
                          <span className="flex items-center gap-1 rounded bg-destructive/15 px-2 py-0.5 text-destructive font-semibold">
                            <Lock className="size-3" />
                            Locked ({lock.stackId})
                          </span>
                        ) : isCurrentUplink ? (
                          <span className="rounded bg-warning/15 px-1.5 py-0.5 text-warning font-semibold">
                            Current Uplink
                          </span>
                        ) : iface.supports_ap ? (
                          <span className="rounded bg-success/15 px-1.5 py-0.5 text-success font-medium">
                            AP Ready
                          </span>
                        ) : (
                          <span className="text-muted-foreground">Station only</span>
                        )}
                      </div>
                    </button>
                  );
                })}
              </div>
            )}

            {/* Hotspot Credentials */}
            <div className="grid gap-3 pt-1 sm:grid-cols-2">
              <div>
                <label className="label text-xs" htmlFor="ssid-input">Wi-Fi name (SSID)</label>
                <input
                  id="ssid-input"
                  className="field mt-1 text-xs"
                  required
                  value={form.ssid}
                  onChange={e => {
                    set('ssid', e.target.value);
                    setUserEditedSsid(true);
                  }}
                  placeholder="e.g. NordVPN-AccessPoint"
                />
              </div>

              <div>
                <div className="flex items-center justify-between">
                  <label className="label text-xs" htmlFor="password-input">Wi-Fi password</label>
                  <span className="text-[10px] text-muted-foreground font-mono">min 8 chars</span>
                </div>
                <div className="relative mt-1">
                  <input
                    id="password-input"
                    className="field text-xs pr-16 font-mono"
                    type={showPassword ? 'text' : 'password'}
                    minLength={8}
                    required
                    value={form.password}
                    onChange={e => set('password', e.target.value)}
                    placeholder="At least 8 characters"
                  />
                  <div className="absolute right-1 top-1.5 flex items-center gap-0.5">
                    <button
                      type="button"
                      onClick={generateStrongPassword}
                      className="p-1 text-muted-foreground hover:text-primary transition-colors"
                      title="Generate new secure password"
                      aria-label="Generate new secure password"
                    >
                      <KeyRound className="size-3.5" />
                    </button>
                    <button
                      type="button"
                      onClick={() => setShowPassword(p => !p)}
                      className="p-1 text-muted-foreground hover:text-foreground transition-colors"
                      title={showPassword ? 'Hide password' : 'Show password'}
                      aria-label={showPassword ? 'Hide password' : 'Show password'}
                    >
                      {showPassword ? <EyeOff className="size-3.5" /> : <Eye className="size-3.5" />}
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* ─── 5. Advanced Settings Accordion ─────────────────────────────── */}
          <details className="group rounded-lg border border-border/80 bg-secondary/10 px-3.5 py-2.5">
            <summary className="flex cursor-pointer items-center justify-between text-xs font-mono text-muted-foreground hover:text-foreground select-none">
              <span className="flex items-center gap-1.5 font-medium">
                <span>Advanced wireless settings (channel, subnet, hw mode)</span>
              </span>
              <ChevronDown className="size-3.5 transition-transform group-open:rotate-180" />
            </summary>

            <div className="mt-3.5 space-y-3.5 border-t border-border/60 pt-3 text-xs">
              {/* Row 1: Stack Identifier & Wi-Fi Security Standard */}
              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <div className="flex items-center justify-between">
                    <label className="label text-[11px]" htmlFor="stack-id-input">Stack Identifier</label>
                    {!stack && (
                      <button
                        type="button"
                        onClick={() => {
                          const nextId = form.mode === 'repeater'
                            ? getUniqueStackId('repeater-ap', stacks)
                            : getUniqueStackId(`vpn-${formatCountrySlug(form.vpn_country)}`, stacks);
                          set('id', nextId);
                          setUserEditedId(true);
                        }}
                        className="text-[10px] text-primary hover:underline flex items-center gap-1 font-mono"
                      >
                        <RefreshCw className="size-2.5" /> Auto-name
                      </button>
                    )}
                  </div>
                  <input
                    id="stack-id-input"
                    className={`field mt-1 font-mono text-xs ${isIdConflict ? 'border-destructive ring-1 ring-destructive' : ''}`}
                    disabled={!!stack}
                    pattern="[a-zA-Z0-9_-]+"
                    value={form.id}
                    onChange={e => {
                      set('id', e.target.value);
                      setUserEditedId(true);
                    }}
                    placeholder={effectiveId}
                  />
                  <span className="text-[10px] text-muted-foreground mt-0.5 block">
                    {isIdConflict ? (
                      <span className="text-destructive font-mono flex items-center gap-1">
                        <AlertCircle className="size-3 shrink-0" /> Stack ID &quot;{effectiveId}&quot; is already in use.
                      </span>
                    ) : (
                      `Unique container identifier (e.g. ${effectiveId})`
                    )}
                  </span>
                </div>

                <div>
                  <div className="flex items-center justify-between">
                    <label className="label text-[11px]">Wi-Fi Security Standard</label>
                    {selected?.supports_wpa3 && (
                      <span className="text-[10px] font-mono text-success">WPA3 Capable</span>
                    )}
                  </div>
                  <div className="relative mt-1">
                    <select
                      className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                      value={form.ap_security}
                      onChange={e => set('ap_security', e.target.value)}
                    >
                      <option value="wpa2">WPA2-Personal (AES-CCMP) — Standard</option>
                      {selected?.supports_wpa3 && (
                        <option value="wpa3">WPA3-Personal (SAE) — Next-Gen</option>
                      )}
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                  </div>
                  <span className="text-[10px] text-muted-foreground mt-0.5 block">
                    {selected?.supports_wpa3
                      ? 'Modern hardware supports WPA3 encryption'
                      : 'WPA2-Personal (AES) encryption'}
                  </span>
                </div>
              </div>

              {/* Row 2: Radio Band / Hardware Mode & Wi-Fi Channel */}
              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <div className="flex items-center justify-between">
                    <label className="label text-[11px]">Radio Band / Hardware Mode</label>
                    {selected && (
                      <span className="text-[10px] font-mono text-muted-foreground">
                        {selected.supports_5ghz && selected.supports_2_4ghz
                          ? 'Dual-Band'
                          : selected.supports_5ghz
                          ? '5 GHz only'
                          : '2.4 GHz only'}
                      </span>
                    )}
                  </div>
                  <div className="relative mt-1">
                    <select
                      className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                      value={effectiveHwMode}
                      onChange={e => handleHwModeChange(e.target.value)}
                    >
                      {(!selected || selected.supports_2_4ghz) && (
                        <option value="g">
                          2.4 GHz ({selected?.supports_ax ? '802.11b/g/n/ax' : selected?.supports_n ? '802.11b/g/n' : '802.11b/g'})
                        </option>
                      )}
                      {(!selected || selected.supports_5ghz) && (
                        <option value="a">
                          5 GHz ({selected?.supports_ax ? 'Wi-Fi 6 / 802.11ax' : selected?.supports_ac ? 'Wi-Fi 5 / 802.11ac' : '802.11a/n'})
                        </option>
                      )}
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                  </div>
                  <span className="text-[10px] text-muted-foreground mt-0.5 block">
                    {effectiveHwMode === 'a' ? '5 GHz band: higher speed, lower range' : '2.4 GHz band: longer range, high compatibility'}
                  </span>
                </div>

                <div>
                  <div className="flex items-center justify-between">
                    <label className="label text-[11px]">Wi-Fi Channel</label>
                    <span className="text-[10px] font-mono text-muted-foreground">
                      {effectiveHwMode === 'a' ? '5 GHz' : '2.4 GHz'}
                    </span>
                  </div>
                  <div className="relative mt-1">
                    <select
                      className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                      value={form.ap_channel}
                      onChange={e => set('ap_channel', e.target.value)}
                    >
                      <option value="">Auto-select (Default: {effectiveHwMode === 'a' ? '36' : '6'})</option>
                      {effectiveHwMode === 'a' ? (
                        <>
                          <option value="36">Channel 36 (5180 MHz) — Recommended</option>
                          <option value="40">Channel 40 (5200 MHz)</option>
                          <option value="44">Channel 44 (5220 MHz)</option>
                          <option value="48">Channel 48 (5240 MHz)</option>
                          <option value="149">Channel 149 (5745 MHz)</option>
                          <option value="153">Channel 153 (5765 MHz)</option>
                          <option value="157">Channel 157 (5785 MHz)</option>
                          <option value="161">Channel 161 (5805 MHz)</option>
                        </>
                      ) : (
                        <>
                          <option value="1">Channel 1 (2412 MHz)</option>
                          <option value="6">Channel 6 (2437 MHz) — Recommended</option>
                          <option value="11">Channel 11 (2462 MHz) — Recommended</option>
                          <option value="2">Channel 2 (2417 MHz)</option>
                          <option value="3">Channel 3 (2422 MHz)</option>
                          <option value="4">Channel 4 (2427 MHz)</option>
                          <option value="5">Channel 5 (2432 MHz)</option>
                          <option value="7">Channel 7 (2442 MHz)</option>
                          <option value="8">Channel 8 (2447 MHz)</option>
                          <option value="9">Channel 9 (2452 MHz)</option>
                          <option value="10">Channel 10 (2457 MHz)</option>
                          <option value="12">Channel 12 (2467 MHz)</option>
                          <option value="13">Channel 13 (2472 MHz)</option>
                        </>
                      )}
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                  </div>
                  <span className="text-[10px] text-muted-foreground mt-0.5 block">
                    {effectiveHwMode === 'a' ? 'Non-DFS indoor channels' : 'Channels 1, 6, 11 are non-overlapping'}
                  </span>
                </div>
              </div>

              {/* Row 3: Channel Width & Subnet / Routing Table */}
              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <div className="flex items-center justify-between">
                    <label className="label text-[11px]">Channel Width (Bandwidth)</label>
                    <span className="text-[10px] font-mono text-muted-foreground">
                      {effectiveHwMode === 'a' ? 'Up to 80 MHz' : '20 / 40 MHz'}
                    </span>
                  </div>
                  <div className="relative mt-1">
                    <select
                      className="field text-xs bg-card pr-8 appearance-none cursor-pointer"
                      value={form.ap_channel_width}
                      onChange={e => set('ap_channel_width', e.target.value)}
                    >
                      <option value="">Auto-select (Default: {selected?.default_width || 20} MHz)</option>
                      <option value="20">20 MHz (Standard / Most stable)</option>
                      {(effectiveHwMode === 'g' ? (selected?.supports_n || selected?.supports_ax || !selected) : true) && (
                        <option value="40">40 MHz (High throughput)</option>
                      )}
                      {effectiveHwMode === 'a' && (selected?.supports_ac || selected?.supports_ax || !selected) && (
                        <option value="80">80 MHz (Very high throughput / VHT)</option>
                      )}
                      {effectiveHwMode === 'a' && selected?.supports_ax && (
                        <option value="160">160 MHz (Ultra-wide / Wi-Fi 6 HE160)</option>
                      )}
                    </select>
                    <ChevronDown className="pointer-events-none absolute right-2.5 top-3 size-4 text-muted-foreground" />
                  </div>
                  <span className="text-[10px] text-muted-foreground mt-0.5 block">
                    {form.ap_channel_width === '80'
                      ? '80 MHz VHT channel width for AC/AX speeds'
                      : form.ap_channel_width === '40'
                      ? '40 MHz bonded channel width'
                      : '20 MHz single-channel width'}
                  </span>
                </div>

                <div>
                  <div className="flex items-center justify-between">
                    <label className="label text-[11px]" htmlFor="subnet-input">
                      Subnet &amp; Routing Table
                    </label>
                    <span className="text-[10px] font-mono text-muted-foreground">IP Subnet &amp; RT ID</span>
                  </div>
                  <div className="grid grid-cols-4 gap-2 mt-1">
                    <div className="col-span-3">
                      <input
                        id="subnet-input"
                        className="field text-xs font-mono"
                        value={form.subnet}
                        onChange={e => set('subnet', e.target.value)}
                        placeholder="Auto subnet (10.x.0.0/24)"
                      />
                    </div>
                    <div className="col-span-1">
                      <input
                        className="field text-xs font-mono text-center"
                        type="number"
                        min="1"
                        max="255"
                        value={form.routing_table}
                        onChange={e => set('routing_table', e.target.value)}
                        placeholder="Table"
                        title="Routing Table ID (1-255)"
                      />
                    </div>
                  </div>
                  <span className="text-[10px] text-muted-foreground mt-0.5 block">
                    Isolated client subnet and Linux routing table ID
                  </span>
                </div>
              </div>

              {/* Row 4: AdGuard / DNS IP & (AP mode only) Auto-reconnect */}
              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <div className="flex items-center justify-between">
                    <label className="label text-[11px]" htmlFor="dns-ip-input">
                      AdGuard / DNS IP {form.mode === 'repeater' && detectedAdGuard?.detected && detectedAdGuard.ip ? '(Auto-Detected)' : '(Optional)'}
                    </label>
                    <span className="text-[10px] font-mono text-muted-foreground">Port: {form.adguard_dns_port || '53'}</span>
                  </div>
                  <div className="grid grid-cols-4 gap-2 mt-1">
                    <div className="col-span-3">
                      <input
                        id="dns-ip-input"
                        className="field text-xs font-mono"
                        value={form.adguard_dns}
                        onChange={e => set('adguard_dns', e.target.value)}
                        placeholder={form.mode === 'repeater' && detectedAdGuard?.detected && detectedAdGuard.ip ? detectedAdGuard.ip : 'e.g. 192.168.1.100 or 10.x.x.x'}
                      />
                    </div>
                    <div className="col-span-1">
                      <input
                        className="field text-xs font-mono text-center"
                        type="number"
                        min="1"
                        max="65535"
                        value={form.adguard_dns_port}
                        onChange={e => set('adguard_dns_port', e.target.value)}
                        placeholder="53"
                        title="DNS Resolver Port"
                      />
                    </div>
                  </div>
                  <div className="flex items-center justify-between mt-0.5">
                    <span className="text-[10px] text-muted-foreground">
                      {form.mode === 'repeater' && detectedAdGuard?.detected && form.adguard_dns === detectedAdGuard.ip ? (
                        <span className="text-emerald-500 font-medium">✓ Auto-detected AdGuard Home ({detectedAdGuard.ip})</span>
                      ) : (
                        'Custom ad-blocking DNS resolver (IP and port)'
                      )}
                    </span>
                    {detectedAdGuard?.detected && detectedAdGuard.ip && form.adguard_dns !== detectedAdGuard.ip && (
                      <button
                        type="button"
                        onClick={() => {
                          set('adguard_dns', detectedAdGuard.ip!);
                          set('adguard_dns_port', String(detectedAdGuard.port || 53));
                        }}
                        className="text-[10px] text-primary hover:underline cursor-pointer"
                      >
                        Use {detectedAdGuard.ip}
                      </button>
                    )}
                  </div>
                </div>

                {form.mode === 'ap' && (
                  <div>
                    <label className="label text-[11px]">Tunnel Auto-reconnect</label>
                    <div className="rounded-md border border-border/60 bg-secondary/20 p-2 mt-1">
                      <label className="flex items-center justify-between cursor-pointer">
                        <span className="text-xs font-medium text-foreground">Reconnect every 8 hours</span>
                        <input
                          type="checkbox"
                          checked={form.auto_reconnect_8h}
                          onChange={e => set('auto_reconnect_8h', e.target.checked)}
                          className="size-3.5 rounded accent-primary cursor-pointer"
                        />
                      </label>
                      <span className="text-[10px] text-muted-foreground mt-0.5 block">
                        Periodically restarts Gluetun tunnel every 8 hours for fresh encryption keys
                      </span>
                    </div>
                  </div>
                )}
              </div>
            </div>
          </details>

          {message && (
            <div className="rounded border border-destructive/30 bg-destructive/10 p-2.5 text-xs text-destructive flex items-center gap-2">
              <AlertCircle className="size-4 shrink-0" />
              <span>{message}</span>
            </div>
          )}

          {/* ─── 6. Footer Controls ────────────────────────────────────────── */}
          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border/70 pt-4">
            <div>
              {isIdConflict ? (
                <span className="text-xs text-destructive font-mono flex items-center gap-1.5 font-medium">
                  <AlertCircle className="size-3.5 shrink-0" />
                  Stack ID &quot;{effectiveId}&quot; already exists
                </span>
              ) : isApLocked || isUplinkLocked || isOverlap ? (
                <span className="text-xs text-destructive font-mono flex items-center gap-1.5 font-medium">
                  <Lock className="size-3.5 shrink-0" />
                  {isApLocked
                    ? `AP interface "${form.ap_iface}" is locked by ${apLock.stackId}`
                    : isUplinkLocked
                    ? `Uplink interface "${form.uplink_iface}" is locked by ${uplinkLock.stackId}`
                    : 'AP and Uplink cannot use same interface'}
                </span>
              ) : isFormValid ? (
                <span className="text-xs text-success font-mono flex items-center gap-1.5 font-medium">
                  <span className="size-2 rounded-full bg-success animate-pulse" />
                  Ready to deploy
                </span>
              ) : (
                <span className="text-xs text-warning font-mono flex items-center gap-1">
                  <AlertCircle className="size-3 shrink-0" />
                  Required: {missingHints.slice(0, 2).join(', ')}{missingHints.length > 2 ? ` (+${missingHints.length - 2})` : ''}
                </span>
              )}
            </div>

            <div className="flex items-center gap-2 ml-auto">
              <Button type="button" variant="outline" size="sm" onClick={onClose}>
                Cancel
              </Button>
              <Button disabled={busy || !isFormValid} size="sm" type="submit" className="gap-1.5">
                {busy ? (
                  <>
                    <RefreshCw className="size-3.5 animate-spin" />
                    <span>Saving…</span>
                  </>
                ) : (
                  <>
                    <Shield className="size-3.5" />
                    <span>{buttonLabel}</span>
                  </>
                )}
              </Button>
            </div>
          </div>
        </form>
      </section>
    </div>
  );
}
