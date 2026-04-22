// TokenDash — adapted from Claude Design Variant D2
// Modifications vs the pristine Claude Design source:
//   • Data is injected dynamically via window.TD_DATA (Swift bridge)
//   • Model mix legend is adaptive (1–3 models = single row; 4 = 2×2 grid)
//   • 7-day bar chart in the drawer shows per-bar tooltips on hover
//   • Hero cards have a subtle hover-lift (parity with compact cards)
//   • Both Claude Code AND Codex cards are expandable (JSX only had Claude)
//   • Palette nudged a touch lighter to match claude.ai product UI more closely
//   • React 18 createRoot instead of ReactDOM.render

// ─── Tokens ──────────────────────────────────────────────────────────────────

const TD_FONTS = {
  serif: '"Source Serif 4", "Source Serif Pro", "New York", ui-serif, Georgia, serif',
  sans: '"Inter", -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif',
  mono: '"JetBrains Mono", "SF Mono", ui-monospace, Menlo, monospace',
};

const TD = {
  coral: '#CC785C', green: '#6B8E5A', red: '#B44A3A',
  dCoral: '#D98B6F', dGreen: '#8FA87C', dRed: '#D07565',
  dGold: '#C8A46A',
  dBorder: '#3A3529', dInk: '#EDE6D6',
};

const VD2_LIGHT = {
  canvas: '#FCFBF7',
  surface: '#FFFFFF',
  surfaceAlt: '#F6F4ED',
  compactBg: '#F4F2EA',
  border: '#EBE6D8',
  borderSoft: '#F1ECDE',
  hair: 'rgba(26,25,21,0.06)',
  ink: '#1A1915',
  muted: '#6B6860',
  dim: '#9B978C',
  coral: '#CC785C',
  green: '#6B8E5A',
  red: '#B44A3A',
};

const VD2_DARK = {
  canvas: '#1C1A16',
  surface: '#24221C',
  surfaceAlt: '#2B2820',
  compactBg: 'rgba(237,230,214,0.03)',
  border: '#3A3529',
  borderSoft: '#302C24',
  hair: 'rgba(237,230,214,0.08)',
  ink: '#EDE6D6',
  muted: '#A39E90',
  dim: '#7A7668',
  coral: '#D98B6F',
  green: '#8FA87C',
  red: '#D07565',
};

const VD2_W = 420;

// ─── Mock fallback ───────────────────────────────────────────────────────────

const MOCK_DATA = {
  claude: {
    name: 'Claude Code', pill: 'Max', today: '11.80M',
    spark: [6.2, 7.8, 5.4, 9.1, 8.3, 10.6, 11.8],
    trend: '↗ 28% vs last wk',
    models: [
      { name: 'Opus 4.7', pct: 63 }, { name: 'Sonnet 4.6', pct: 20 },
      { name: 'Opus 4.6', pct: 14 }, { name: 'Haiku 4.5', pct: 3 },
    ],
    quotas: [
      { label: '5h window', pct: 52, resets: 'resets in 1h 48m' },
      { label: 'Weekly',    pct: 71, resets: 'resets in 4d 12h' },
    ],
    weekTotal: '58.3M', monthTotal: '214.6M', sessions: '47',
    dayBuckets: [6.2, 7.8, 5.4, 9.1, 8.3, 10.6, 11.8],
    dayLabels: ['M','T','W','T','F','S','S'],
    dayUnits: 'M', weeklyAvg: '8.5M',
    topSessions: [
      { time: '2:14 PM', tokens: '2.4M', duration: '38m' },
      { time: '11:02 AM', tokens: '1.9M', duration: '24m' },
      { time: '9:48 AM', tokens: '1.1M', duration: '14m' },
    ],
  },
  codex: {
    name: 'Codex CLI', pill: 'Plus', model: 'GPT-5.4', today: '2.14M',
    quotas: [
      { label: '5h window', pct: 24, resets: 'resets in 2h 14m' },
      { label: 'Weekly',    pct: 96, resets: 'resets in 2d 3h', warn: true },
    ],
    weekTotal: '12.4M', monthTotal: '46.1M', sessions: '—',
    dayBuckets: [1.1, 1.4, 0.9, 2.0, 1.6, 2.3, 2.14],
    dayLabels: ['M','T','W','T','F','S','S'],
    dayUnits: 'M', weeklyAvg: '1.6M',
    topSessions: [],
  },
  providers: [
    { id: 'elevenlabs', kind: 'eleven', name: 'ElevenLabs', pill: 'Creator',
      pct: 48, resets: 'resets Apr 27', usedLabel: '48,213', totalLabel: '100K' },
    { id: 'openrouter', kind: 'router', name: 'OpenRouter', pill: 'Pay-as-you-go',
      credits: '$12.47', spendLabel: '$1.82 · 24h' },
    { id: 'groq', kind: 'groq', name: 'Groq', pill: 'Free tier',
      note: 'no usage API — key stored' },
  ],
  footer: { providerCount: 5, nextRefresh: '18s', live: 'live' },
  header: { subtitle: 'Updated 12s ago · 2 active · 3 idle' },
};

// ─── Primitives ──────────────────────────────────────────────────────────────

function Sparkline({ data, width = 84, height = 26, stroke = '#CC785C', fill, dots = false }) {
  if (!data || data.length < 2) return null;
  const max = Math.max(...data), min = Math.min(...data);
  const range = max - min || 1;
  const step = width / (data.length - 1);
  const pts = data.map((v, i) => [i * step, height - ((v - min) / range) * (height - 2) - 1]);
  const d = pts.map((p, i) => (i === 0 ? 'M' : 'L') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
  const area = `${d} L ${width} ${height} L 0 ${height} Z`;
  return (
    <svg width={width} height={height} style={{ display: 'block', overflow: 'visible' }}>
      {fill && <path d={area} fill={fill} />}
      <path d={d} fill="none" stroke={stroke} strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" />
      {dots && pts.map((p, i) => (
        <circle key={i} cx={p[0]} cy={p[1]} r={i === pts.length - 1 ? 1.8 : 0.8} fill={stroke} />
      ))}
    </svg>
  );
}

// Micro bar chart for daily deltas (history7). Crisper at small sizes than
// a line sparkline because each bar maps 1:1 to a day.
function Sparkbars({ data, width = 86, height = 22, color = '#CC785C', dim = '#E6DDD0', todayHighlight = true }) {
  if (!data || data.length === 0) return null;
  const max = Math.max(...data, 1);
  const gap = 2;
  const barW = Math.max(1, (width - gap * (data.length - 1)) / data.length);
  return (
    <svg width={width} height={height} style={{ display: 'block' }}>
      {data.map((v, i) => {
        const h = Math.max(v > 0 ? 1.5 : 0.5, (v / max) * (height - 2));
        const x = i * (barW + gap);
        const y = height - h;
        const isToday = todayHighlight && i === data.length - 1;
        return (
          <rect key={i} x={x} y={y} width={barW} height={h} rx={1}
                fill={isToday ? color : dim} />
        );
      })}
    </svg>
  );
}

function TrendChip({ label, t }) {
  if (!label || label === 'flat') return null;
  const up = label.startsWith('+');
  const dark = t.ink === VD2_DARK.ink;
  const fg = up
    ? (dark ? TD.dCoral : '#B85A3B')
    : (dark ? TD.dGreen : '#5B7A4C');
  const bg = up
    ? (dark ? 'rgba(204,120,92,0.14)' : '#F6E6DD')
    : (dark ? 'rgba(143,168,124,0.14)' : '#E8EEDE');
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 2,
      fontFamily: TD_FONTS.mono, fontSize: 10, color: fg,
      background: bg, padding: '1px 6px', borderRadius: 99,
      fontVariantNumeric: 'tabular-nums', letterSpacing: 0.2,
    }}>{up ? '↗' : '↘'} {label.replace(/^[+-]/, '')}</span>
  );
}

// Single-line rank list: "Claude 3.5 Sonnet      $8.42"
function TopList({ rows, t, valueKey = 'tokens' }) {
  if (!rows || rows.length === 0) return null;
  return (
    <div style={{ marginTop: 10 }}>
      {rows.map((r, i) => (
        <div key={i} style={{
          display: 'grid', gridTemplateColumns: '14px 1fr auto', gap: 8,
          fontSize: 11, padding: '4px 0',
          color: t.muted, fontFamily: TD_FONTS.sans,
          borderBottom: i < rows.length - 1 ? `1px solid ${t.hair}` : 'none',
          alignItems: 'baseline',
        }}>
          <span style={{ color: t.dim, fontFamily: TD_FONTS.mono, fontSize: 10 }}>{i + 1}</span>
          <span style={{ color: t.ink, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{r.name}</span>
          <span style={{ fontFamily: TD_FONTS.mono, color: t.ink, fontVariantNumeric: 'tabular-nums' }}>
            {r[valueKey] != null ? r[valueKey] : (r.spend || r.tokens)}
          </span>
        </div>
      ))}
    </div>
  );
}

function QuotaBar({ pct, warn = false, dark = false }) {
  const track = dark ? TD.dBorder : '#EDE7D8';
  const isHot = warn || pct >= 85;
  const fillColor = isHot ? (dark ? TD.dRed : TD.red)
                          : (dark ? TD.dCoral : TD.coral);
  return (
    <div style={{
      position: 'relative', width: '100%', height: 6, borderRadius: 3,
      background: track, overflow: 'hidden',
    }}>
      <div style={{
        position: 'absolute', top: 0, left: 0, bottom: 0,
        width: Math.min(100, pct) + '%',
        background: fillColor, borderRadius: 3,
        animation: isHot ? 'td-pulse 2.2s ease-in-out infinite' : undefined,
      }} />
    </div>
  );
}

function Ring({ pct, size = 56, stroke = 5, t }) {
  const r = (size - stroke) / 2;
  const c = size / 2;
  const circ = 2 * Math.PI * r;
  const off = circ * (1 - Math.min(100, Math.max(0, pct)) / 100);
  const dark = t.ink === VD2_DARK.ink;
  const track = dark ? TD.dBorder : '#EDE7D8';
  const fill = pct >= 85 ? (dark ? TD.dRed : TD.red) : (dark ? TD.dCoral : TD.coral);
  return (
    <svg width={size} height={size} style={{ flexShrink: 0, display: 'block' }}>
      <circle cx={c} cy={c} r={r} fill="none" stroke={track} strokeWidth={stroke} />
      <circle cx={c} cy={c} r={r} fill="none" stroke={fill} strokeWidth={stroke}
        strokeDasharray={circ} strokeDashoffset={off} strokeLinecap="round"
        transform={`rotate(-90 ${c} ${c})`}
        style={{ transition: 'stroke-dashoffset 400ms ease' }} />
      <text x={c} y={c} textAnchor="middle" dominantBaseline="central"
        fontFamily={TD_FONTS.mono} fontSize={size * 0.26} fontWeight="500"
        fill={t.ink} style={{ fontVariantNumeric: 'tabular-nums' }}>{pct}%</text>
    </svg>
  );
}

function ModelBar({ models, dark = false }) {
  if (!models || models.length === 0) return null;
  const colors = dark ? ['#D98B6F', '#C48872', '#9E6E5C', '#5E544A']
                      : [TD.coral, '#D89780', '#B8897C', '#A59684'];
  const total = models.reduce((a, m) => a + m.pct, 0) || 100;
  return (
    <div style={{
      display: 'flex', width: '100%', height: 7, borderRadius: 3.5, overflow: 'hidden',
      background: dark ? TD.dBorder : '#EDE7D8',
    }}>
      {models.map((m, i) => (
        <div key={i} style={{ width: (m.pct / total * 100) + '%', background: colors[i % colors.length] }} />
      ))}
    </div>
  );
}

// ─── Shell / Header / Footer ─────────────────────────────────────────────────

function VD2_Shell({ children, dark = false, route, onSettings, onBack }) {
  const t = dark ? VD2_DARK : VD2_LIGHT;
  return (
    <div style={{
      width: VD2_W, height: '100vh', maxHeight: '100vh', background: t.canvas,
      fontFamily: TD_FONTS.sans, color: t.ink, overflow: 'hidden',
      position: 'relative', display: 'flex', flexDirection: 'column',
    }}>
      <VD2_Header t={t} dark={dark} route={route} onSettings={onSettings} onBack={onBack} />
      <div style={{
        flex: 1, overflowY: 'auto', padding: '12px 14px',
        display: 'flex', flexDirection: 'column', gap: 0,
      }}>{children}</div>
      <VD2_Footer t={t} />
    </div>
  );
}

function postSwift(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.td) {
    window.webkit.messageHandlers.td.postMessage(msg);
  }
}

function VD2_Header({ t, dark, route, onSettings, onBack }) {
  const h = (window.TD_DATA && window.TD_DATA.header) || MOCK_DATA.header;
  const inSettings = route === 'settings';
  return (
    <div style={{
      padding: '14px 16px 12px', borderBottom: `1px solid ${t.border}`,
      display: 'flex', alignItems: 'center', gap: 10,
      background: dark ? t.surface : '#FFFFFF',
    }}>
      {inSettings ? (
        <IconButton t={t} title="Back" onClick={onBack}>
          <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
            <path d="M8 3L3.5 6.5 8 10" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </IconButton>
      ) : (
        <span style={{
          width: 7, height: 7, borderRadius: 10, background: t.coral,
          boxShadow: `0 0 0 3px ${t.coral}22`, flexShrink: 0, marginLeft: 2,
        }} />
      )}
      <div style={{ flex: 1, minWidth: 0, marginLeft: inSettings ? 0 : 3 }}>
        <div style={{
          fontFamily: TD_FONTS.serif, fontSize: 20, fontWeight: 500,
          letterSpacing: -0.3, color: t.ink, lineHeight: 1,
        }}>{inSettings ? 'Settings' : 'TokenDash'}</div>
        {!inSettings && (
          <div style={{ fontSize: 10.5, color: t.dim, marginTop: 3, whiteSpace: 'nowrap' }}>
            {h.subtitle}
          </div>
        )}
        {inSettings && (
          <div style={{ fontSize: 10.5, color: t.dim, marginTop: 3 }}>
            Adjust plan & limits
          </div>
        )}
      </div>
      {!inSettings && (
        <>
          <IconButton t={t} title="Refresh" onClick={() => postSwift('refresh')}>
            <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
              <path d="M11 6.5A4.5 4.5 0 1 1 10 3.5M11 1.5v2.5h-2.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </IconButton>
          <IconButton t={t} title="Settings" onClick={onSettings}>
            <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
              <circle cx="6.5" cy="6.5" r="1.6" stroke="currentColor" strokeWidth="1.2"/>
              <path d="M6.5 1.2v1.6m0 7.4v1.6M1.2 6.5h1.6m7.4 0h1.6M2.8 2.8l1.1 1.1m5.2 5.2l1.1 1.1M2.8 10.2l1.1-1.1m5.2-5.2l1.1-1.1" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
            </svg>
          </IconButton>
          <IconButton t={t} title="Quit" onClick={() => postSwift('quit')}>
            <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
              <path d="M6.5 1.5v5M10 3a4.5 4.5 0 1 1-7 0" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
            </svg>
          </IconButton>
        </>
      )}
    </div>
  );
}

function IconButton({ children, onClick, t, title }) {
  const [hover, setHover] = React.useState(false);
  return (
    <button
      title={title}
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        width: 26, height: 26, border: 'none',
        background: hover ? t.surfaceAlt : 'transparent',
        borderRadius: 6, cursor: 'pointer', color: hover ? t.ink : t.muted,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        transition: 'background 120ms ease, color 120ms ease',
      }}>{children}</button>
  );
}

function VD2_Footer({ t }) {
  const f = (window.TD_DATA && window.TD_DATA.footer) || MOCK_DATA.footer;
  return (
    <div style={{
      padding: '10px 16px', borderTop: `1px solid ${t.border}`,
      display: 'flex', alignItems: 'center', gap: 8,
      fontSize: 10.5, color: t.dim,
    }}>
      <span style={{
        width: 5, height: 5, borderRadius: 10, background: t.coral,
        animation: 'td-blink 1.8s ease-in-out infinite',
      }} />
      <span style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', whiteSpace: 'nowrap' }}>
        {f.providerCount} providers
      </span>
      <span style={{ opacity: 0.4 }}>·</span>
      <span style={{ fontFamily: TD_FONTS.mono, whiteSpace: 'nowrap' }}>
        next refresh {f.nextRefresh}
      </span>
      <span style={{ flex: 1 }} />
      <span style={{ fontFamily: TD_FONTS.mono, fontSize: 9.5 }}>{f.live}</span>
    </div>
  );
}

// ─── Pill + Monogram ─────────────────────────────────────────────────────────

const PILL_TONES_LIGHT = {
  max:     { bg: '#F5E3DB', fg: '#CC785C' },
  plus:    { bg: '#E4EBDB', fg: '#5B7A4C' },
  creator: { bg: '#E7DFF1', fg: '#6A5A8B' },
  payg:    { bg: '#F0E5D8', fg: '#8B6A45' },
  free:    { bg: '#E8E6DE', fg: '#8E8A80' },
};
const PILL_TONES_DARK = {
  max:     { bg: 'rgba(217,139,111,0.2)', fg: '#D98B6F' },
  plus:    { bg: 'rgba(143,168,124,0.2)', fg: '#8FA87C' },
  creator: { bg: 'rgba(170,140,200,0.2)', fg: '#B79ED6' },
  payg:    { bg: 'rgba(200,160,110,0.2)', fg: '#C9A878' },
  free:    { bg: 'rgba(237,230,214,0.08)', fg: '#7A7668' },
};
function pillTone(name, dark) {
  const key = (name || 'free').toLowerCase().replace(/[^a-z]/g, '');
  const map = { max: 'max', plus: 'plus', creator: 'creator', payasyougo: 'payg', freetier: 'free', free: 'free' };
  const tone = map[key] || 'free';
  return (dark ? PILL_TONES_DARK : PILL_TONES_LIGHT)[tone];
}

function Pill({ children, t, tone }) {
  const dark = t.ink === VD2_DARK.ink;
  const s = pillTone(tone, dark);
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center',
      padding: '1px 7px', borderRadius: 10, flexShrink: 0,
      fontSize: 9.5, fontWeight: 500, letterSpacing: 0.3,
      background: s.bg, color: s.fg, whiteSpace: 'nowrap',
    }}>{children}</span>
  );
}

function Monogram({ letter, t, tone }) {
  const dark = t.ink === VD2_DARK.ink;
  const s = pillTone(tone, dark);
  return (
    <div style={{
      width: 28, height: 28, borderRadius: 14,
      background: s.bg, color: s.fg, flexShrink: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontFamily: TD_FONTS.serif, fontSize: 14, fontWeight: 500,
    }}>{letter}</div>
  );
}

// ─── Quota row ───────────────────────────────────────────────────────────────

function VD2_QuotaRow({ q, t }) {
  const pctColor = (q.warn || q.pct >= 85) ? t.red : t.ink;
  return (
    <div style={{ marginBottom: 8 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 4 }}>
        <span style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.ink }}>{q.label}</span>
        <span style={{ fontFamily: TD_FONTS.mono, fontSize: 10, color: t.dim, whiteSpace: 'nowrap' }}>{q.resets}</span>
        <span style={{ flex: 1 }} />
        <span style={{ fontFamily: TD_FONTS.mono, fontSize: 11.5, fontWeight: 500, color: pctColor, fontVariantNumeric: 'tabular-nums' }}>{Math.round(q.pct)}%</span>
      </div>
      <QuotaBar pct={q.pct} warn={q.warn} dark={t.ink === VD2_DARK.ink} />
    </div>
  );
}

// ─── Hero card shell (now with hover lift) ───────────────────────────────────

function VD2_Hero({ children, t, warn, expanded, onToggle }) {
  const [hover, setHover] = React.useState(false);
  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        background: t.surface,
        border: `1px solid ${warn ? (t.ink === VD2_DARK.ink ? '#8B4A3C' : '#E5BFB3') : (hover ? t.border : t.border)}`,
        borderRadius: 14, padding: '14px 16px', marginBottom: 12,
        boxShadow: t.ink === VD2_DARK.ink
          ? (hover ? '0 6px 18px rgba(0,0,0,0.4)' : 'none')
          : (hover ? '0 6px 16px rgba(60,45,30,0.08), 0 1px 0 rgba(60,45,30,0.03)' : '0 1px 0 rgba(60,45,30,0.02)'),
        transform: hover ? 'translateY(-1px)' : 'none',
        transition: 'box-shadow 160ms ease, transform 160ms ease',
        position: 'relative', cursor: onToggle ? 'pointer' : 'default',
      }}
      onClick={onToggle}>
      {children}
      {onToggle && (
        <div style={{
          position: 'absolute', top: 16, right: 14,
          color: t.dim, opacity: hover || expanded ? 0.9 : 0.35,
          transition: 'opacity 160ms ease',
          pointerEvents: 'none',
        }}>
          <svg width="10" height="10" viewBox="0 0 12 12" fill="none"
               style={{ transform: expanded ? 'rotate(180deg)' : 'none', transition: 'transform 200ms ease' }}>
            <path d="M2.5 4.5l3.5 3.5 3.5-3.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
      )}
    </div>
  );
}

// ─── Claude hero ─────────────────────────────────────────────────────────────

function VD2_ClaudeHero({ t, expanded, onToggle }) {
  const d = (window.TD_DATA && window.TD_DATA.claude) || MOCK_DATA.claude;
  return (
    <VD2_Hero t={t} expanded={expanded} onToggle={onToggle}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10, paddingRight: 18 }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: t.ink, whiteSpace: 'nowrap' }}>{d.name}</span>
        <Pill t={t} tone={d.pill}>{d.pill}</Pill>
        <span style={{ flex: 1 }} />
        <span style={{ fontFamily: TD_FONTS.mono, fontSize: 9, color: t.dim, whiteSpace: 'nowrap' }}>live</span>
      </div>

      {/* Big today headline */}
      <div style={{ marginBottom: 14 }}>
        <div style={{
          fontFamily: TD_FONTS.mono, fontSize: 40, fontWeight: 400,
          letterSpacing: -1.4, color: t.ink, lineHeight: 0.95,
          fontVariantNumeric: 'tabular-nums',
        }}>{d.today}</div>
        <div style={{
          fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: t.dim, marginTop: 5,
          display: 'flex', alignItems: 'baseline', gap: 6, flexWrap: 'wrap',
        }}>
          <span>tokens today</span>
          {d.trend && (
            <>
              <span style={{ opacity: 0.5 }}>·</span>
              <span style={{
                fontFamily: TD_FONTS.mono, fontStyle: 'normal', fontSize: 10,
                color: t.ink === VD2_DARK.ink ? TD.dGreen : '#5B7A4C',
              }}>{d.trend}</span>
            </>
          )}
        </div>
      </div>

      {/* 7-day + Month stats */}
      <div style={{ display: 'flex', gap: 14, marginBottom: 14 }}>
        <HairStat label="7-day" value={d.weekTotal || '—'} t={t} />
        <HairStat label="Month" value={d.monthTotal || '—'} t={t} />
        <HairStat label="Avg / day" value={d.weeklyAvg || '—'} t={t} />
      </div>

      {/* Per-day bar chart — primary now */}
      {d.dayBuckets && d.dayBuckets.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <WeekBarChart
            data={d.dayBuckets}
            labels={d.dayLabels || []}
            units={d.dayUnits || ''}
            avg={''}
            t={t} />
        </div>
      )}

      {/* Models */}
      {d.models && d.models.length > 0 && (
        <div>
          <div style={{
            display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 6,
          }}>
            <span style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 10.5, color: t.dim, letterSpacing: 0.2,
            }}>Models</span>
            <span style={{ flex: 1, height: 1, background: t.hair }} />
          </div>
          <ModelBar models={d.models} dark={t.ink === VD2_DARK.ink} />
          <ModelLegend models={d.models} t={t} />
        </div>
      )}

      {expanded && <VD2_ClaudeDrawer t={t} d={d} />}
    </VD2_Hero>
  );
}

// Claude drawer — three tabs (Overview / Models / Cache) mirroring Claude
// Code's own UI vocabulary. Each tab tells one story instead of stacking
// five boards of data on top of each other. The drawer grew organically in
// M3/M4 and was getting dense — tabs pay the (tiny) UX cost of an extra
// click in exchange for calmer per-screen density and a familiar pattern.
function VD2_ClaudeDrawer({ t, d }) {
  const [tab, setTab] = React.useState('overview');
  const fmtInt = (n) => n == null ? '—' : n.toLocaleString();
  const fmtTokens = (n) => {
    if (n == null) return '—';
    if (n < 1000) return String(n);
    if (n < 1_000_000) return (n / 1000).toFixed(1) + 'K';
    if (n < 1_000_000_000) return (n / 1_000_000).toFixed(2) + 'M';
    return (n / 1_000_000_000).toFixed(2) + 'B';
  };

  const tabs = [
    { id: 'overview', label: 'Overview' },
    { id: 'models',   label: 'Models'   },
    { id: 'cache',    label: 'Cache'    },
  ];

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{ marginTop: 14, paddingTop: 14, borderTop: `1px solid ${t.border}` }}>

      {/* Tab bar — matches Claude Code's own Overview/Models segmented pill */}
      <div style={{
        display: 'inline-flex', gap: 4, marginBottom: 12,
        background: t.compactBg, borderRadius: 8, padding: 3,
        border: `1px solid ${t.hair}`,
      }}>
        {tabs.map(x => (
          <button
            key={x.id}
            onClick={() => setTab(x.id)}
            style={{
              appearance: 'none', border: 'none', cursor: 'pointer',
              background: tab === x.id ? t.surface : 'transparent',
              color: tab === x.id ? t.ink : t.muted,
              fontFamily: TD_FONTS.sans, fontSize: 11.5,
              fontWeight: tab === x.id ? 600 : 400,
              padding: '3px 10px', borderRadius: 6,
              boxShadow: tab === x.id ? '0 1px 2px rgba(0,0,0,0.08)' : 'none',
              transition: 'background 120ms ease',
            }}
          >{x.label}</button>
        ))}
      </div>

      {tab === 'overview' && <ClaudeOverviewTab t={t} d={d} fmtInt={fmtInt} />}
      {tab === 'models'   && <ClaudeModelsTab   t={t} d={d} fmtTokens={fmtTokens} />}
      {tab === 'cache'    && <ClaudeCacheTab    t={t} d={d} fmtTokens={fmtTokens} />}
    </div>
  );
}

// Overview — "when and where I'm using Claude Code"
function ClaudeOverviewTab({ t, d, fmtInt }) {
  const hasSessions = d.topSessions && d.topSessions.length > 0;
  const hasProjects = d.topProjects && d.topProjects.length > 0;
  const msgToday = (typeof d.messagesToday === 'number') ? d.messagesToday : null;
  const msgWeek  = (typeof d.messagesWeek  === 'number') ? d.messagesWeek  : null;
  const msgMonth = (typeof d.messagesMonth === 'number') ? d.messagesMonth : null;
  const peakHour = d.peakHour || null;
  return (
    <div>
      {(msgToday !== null || peakHour) && (
        <div style={{
          display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr',
          gap: 8, marginBottom: 12, paddingBottom: 10,
          borderBottom: `1px solid ${t.hair}`,
        }}>
          {[
            { k: 'Messages today', v: fmtInt(msgToday) },
            { k: '7-day msgs',     v: fmtInt(msgWeek) },
            { k: 'Month msgs',     v: fmtInt(msgMonth) },
            { k: 'Peak hour',      v: peakHour || '—' },
          ].map((x, i) => (
            <div key={i} style={{
              background: t.compactBg,
              border: `1px solid ${t.hair}`,
              borderRadius: 6, padding: '6px 8px',
            }}>
              <div style={{
                fontFamily: TD_FONTS.serif, fontStyle: 'italic',
                fontSize: 9.5, color: t.dim, marginBottom: 2,
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              }}>{x.k}</div>
              <div style={{
                fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink,
                fontVariantNumeric: 'tabular-nums',
              }}>{x.v}</div>
            </div>
          ))}
        </div>
      )}

      {hasProjects && (
        <div style={{ marginBottom: 12, paddingBottom: 10, borderBottom: `1px solid ${t.hair}` }}>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 12, color: t.ink, marginBottom: 4,
          }}>Top projects this week</div>
          <TopList rows={d.topProjects} t={t} valueKey="tokens" />
        </div>
      )}

      <div style={{
        marginBottom: 8,
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 12, color: t.ink,
      }}>Top sessions today</div>
      {hasSessions ? d.topSessions.map((s, i) => (
        <div key={i} style={{
          display: 'grid', gridTemplateColumns: '70px 1fr 50px',
          fontSize: 11, padding: '5px 0',
          color: t.muted, fontFamily: TD_FONTS.mono,
          borderBottom: i < d.topSessions.length - 1 ? `1px solid ${t.hair}` : 'none',
          fontVariantNumeric: 'tabular-nums',
        }}>
          <span style={{ whiteSpace: 'nowrap' }}>{s.time}</span>
          <span style={{ color: t.ink, fontWeight: 500, textAlign: 'right' }}>{s.tokens}</span>
          <span style={{ textAlign: 'right' }}>{s.duration}</span>
        </div>
      )) : (
        <div style={{
          fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: t.dim,
        }}>No sessions yet today.</div>
      )}
    </div>
  );
}

// Models — "which models I'm using, and the in/out split"
function ClaudeModelsTab({ t, d, fmtTokens }) {
  const rows = d.modelBreakdown || [];
  if (rows.length === 0) {
    return (
      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim,
      }}>No model usage recorded yet this month.</div>
    );
  }
  const grand = rows.reduce((a, x) => a + ((x.input||0)+(x.output||0)), 0);
  return (
    <div>
      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 12, color: t.ink, marginBottom: 8,
      }}>Model breakdown (this month)</div>
      {rows.map((m, i) => {
        const total = (m.input||0) + (m.output||0);
        const share = grand > 0 ? Math.round(total / grand * 100) : 0;
        return (
          <div key={i} style={{
            display: 'grid', gridTemplateColumns: '1fr auto auto',
            columnGap: 10, alignItems: 'baseline',
            fontSize: 11, padding: '6px 0',
            borderBottom: i < rows.length - 1 ? `1px solid ${t.hair}` : 'none',
          }}>
            <span style={{
              color: t.ink, fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 12,
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{m.name}</span>
            <span style={{
              fontFamily: TD_FONTS.mono, color: t.muted,
              fontVariantNumeric: 'tabular-nums',
            }}>{fmtTokens(m.input)} in · {fmtTokens(m.output)} out</span>
            <span style={{
              fontFamily: TD_FONTS.mono, color: t.ink, fontWeight: 500,
              fontVariantNumeric: 'tabular-nums', minWidth: 40, textAlign: 'right',
            }}>{share}%</span>
          </div>
        );
      })}
    </div>
  );
}

// Cache — "what's happening under the hood, that official UI hides"
function ClaudeCacheTab({ t, d, fmtTokens }) {
  const hitRate = (typeof d.cacheHitRate === 'number') ? d.cacheHitRate : null;
  const input  = d.monthInput      || 0;
  const output = d.monthOutput     || 0;
  const cread  = d.monthCacheRead  || 0;
  const cwrite = d.monthCacheWrite || 0;
  const total  = input + output + cread + cwrite;
  const official = input + output;
  const reuse = cwrite > 0 ? cread / cwrite : 0;
  const dark = t.ink === VD2_DARK.ink;

  // Palette: cache_read is the "headline" (biggest), cache_write is the
  // cost input, output is earned value, input is raw prompt.
  const colors = dark
    ? { read: '#8AA9C4', write: '#A8876F', output: '#8EA68B', input: '#6D6860' }
    : { read: '#5A7898', write: '#C48872', output: '#7D9B78', input: '#7A7066' };

  const rows = [
    { k: 'Cache reads',  v: cread,  color: colors.read,   hint: 'cheap cached re-use' },
    { k: 'Cache writes', v: cwrite, color: colors.write,  hint: 'first-time cached'   },
    { k: 'Output',       v: output, color: colors.output, hint: 'model responses'     },
    { k: 'Input',        v: input,  color: colors.input,  hint: 'your new prompts'    },
  ];

  return (
    <div>
      {/* Cache hit rate headline */}
      {hitRate !== null && (
        <div style={{
          display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
          marginBottom: 12, paddingBottom: 10, borderBottom: `1px solid ${t.hair}`,
        }}>
          <div>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 12, color: t.ink,
            }}>Prompt cache hit rate</div>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10.5, color: t.dim, marginTop: 2,
            }}>cached reads ÷ total input (today)</div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 22, color: t.ink,
              fontVariantNumeric: 'tabular-nums', letterSpacing: -0.5,
            }}>{hitRate}%</div>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim,
            }}>{hitRate >= 60 ? 'healthy' : hitRate >= 30 ? 'ok' : 'low — prompts change often?'}</div>
          </div>
        </div>
      )}

      {/* Real consumption bars */}
      {total > 0 && (
        <div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 12, color: t.ink, marginBottom: 2,
          }}>Real consumption (this month)</div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10.5, color: t.dim, marginBottom: 8,
          }}>what Claude Code's UI hides — full token flow through the system</div>

          {rows.map((r, i) => {
            const pct = total > 0 ? (r.v / total * 100) : 0;
            // Minimum 2px so tiny slices stay visible; otherwise proportional.
            const barWidth = r.v === 0 ? 0 : Math.max(2, pct);
            return (
              <div key={i} style={{
                display: 'grid',
                gridTemplateColumns: '88px 1fr 72px 52px',
                columnGap: 8, alignItems: 'center',
                padding: '4px 0',
                fontSize: 11,
              }}>
                <span style={{
                  fontFamily: TD_FONTS.serif, fontStyle: 'italic', color: t.ink,
                }}>{r.k}</span>
                <div style={{
                  height: 8, background: t.hair, borderRadius: 3, overflow: 'hidden',
                }}>
                  <div style={{
                    height: '100%', width: `${barWidth}%`, background: r.color,
                    borderRadius: 3, transition: 'width 200ms ease',
                  }} />
                </div>
                <span style={{
                  fontFamily: TD_FONTS.mono, color: t.muted,
                  fontVariantNumeric: 'tabular-nums', textAlign: 'right',
                }}>{fmtTokens(r.v)}</span>
                <span style={{
                  fontFamily: TD_FONTS.mono, color: t.ink,
                  fontVariantNumeric: 'tabular-nums', textAlign: 'right',
                }}>{pct < 0.01 ? '<0.01%' : pct < 1 ? pct.toFixed(2) + '%' : pct.toFixed(1) + '%'}</span>
              </div>
            );
          })}

          {/* Contrast: what official UI shows vs. what really flowed */}
          <div style={{
            display: 'grid', gridTemplateColumns: '1fr 1fr',
            gap: 8, marginTop: 10, paddingTop: 10,
            borderTop: `1px solid ${t.hair}`,
          }}>
            <div style={{
              background: t.compactBg, border: `1px solid ${t.hair}`,
              borderRadius: 6, padding: '6px 8px',
            }}>
              <div style={{
                fontFamily: TD_FONTS.serif, fontStyle: 'italic',
                fontSize: 9.5, color: t.dim, marginBottom: 2,
              }}>Official UI shows</div>
              <div style={{
                fontFamily: TD_FONTS.mono, fontSize: 14, color: t.ink,
                fontVariantNumeric: 'tabular-nums',
              }}>{fmtTokens(official)}</div>
            </div>
            <div style={{
              background: t.compactBg, border: `1px solid ${t.hair}`,
              borderRadius: 6, padding: '6px 8px',
            }}>
              <div style={{
                fontFamily: TD_FONTS.serif, fontStyle: 'italic',
                fontSize: 9.5, color: t.dim, marginBottom: 2,
              }}>System actually processed</div>
              <div style={{
                fontFamily: TD_FONTS.mono, fontSize: 14, color: t.ink,
                fontVariantNumeric: 'tabular-nums',
              }}>{fmtTokens(total)}</div>
            </div>
          </div>

          {/* Insight — the line that makes this page worth reading */}
          {reuse >= 2 && (
            <div style={{
              marginTop: 10,
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 11, color: t.dim, lineHeight: 1.45,
            }}>
              <span style={{ color: t.ink }}>Cache reuse {reuse < 10 ? reuse.toFixed(1) : Math.round(reuse)}×</span>
              {' '}— each cached chunk was re-read {reuse < 10 ? reuse.toFixed(1) : Math.round(reuse)} times
              on average. Subscription plans don't bill for this, but on the API
              you'd have paid for every one.
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function ModelLegend({ models, t }) {
  const dark = t.ink === VD2_DARK.ink;
  const colors = dark ? ['#D98B6F', '#C48872', '#9E6E5C', '#5E544A']
                      : ['#CC785C', '#D89780', '#B8897C', '#A59684'];
  const cell = (m, i) => (
    <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0, flex: 1 }}>
      <span style={{ width: 7, height: 7, borderRadius: 2, background: colors[i % 4], flexShrink: 0 }} />
      <span style={{ color: t.muted, flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', fontSize: 11 }}>{m.name}</span>
      <span style={{ fontFamily: TD_FONTS.mono, color: t.ink, fontVariantNumeric: 'tabular-nums', fontSize: 11 }}>{m.pct}%</span>
    </div>
  );
  if (models.length >= 4) {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', rowGap: 4, columnGap: 14, marginTop: 10 }}>
        {models.slice(0, 4).map((m, i) => cell(m, i))}
      </div>
    );
  }
  return (
    <div style={{ display: 'flex', columnGap: 14, marginTop: 10 }}>
      {models.map((m, i) => cell(m, i))}
    </div>
  );
}

// ─── Drawer (used by BOTH Claude and Codex heroes) ───────────────────────────

function VD2_Drawer({ t, d }) {
  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{ marginTop: 14, paddingTop: 14, borderTop: `1px solid ${t.border}` }}>
      <div style={{ display: 'flex', gap: 14, marginBottom: 14 }}>
        <HairStat label="7-day" value={d.weekTotal || '—'} t={t} />
        <HairStat label="Month" value={d.monthTotal || '—'} t={t} />
        {d.sessions && <HairStat label="Sessions" value={d.sessions} t={t} />}
      </div>

      {d.dayBuckets && d.dayBuckets.length > 0 &&
        <WeekBarChart data={d.dayBuckets} labels={d.dayLabels || []} units={d.dayUnits || ''} avg={d.weeklyAvg || ''} t={t} />
      }

      {d.models && d.models.length > 0 && (
        <div style={{ marginTop: 14 }}>
          <div style={{
            display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 6,
          }}>
            <span style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 10.5, color: t.dim, letterSpacing: 0.2,
            }}>Models</span>
            <span style={{ flex: 1, height: 1, background: t.hair }} />
          </div>
          <ModelBar models={d.models} dark={t.ink === VD2_DARK.ink} />
          <ModelLegend models={d.models} t={t} />
        </div>
      )}

      {(d.topSessions && d.topSessions.length > 0) && (
        <>
          <div style={{
            marginTop: 14, marginBottom: 6,
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 12, color: t.ink,
          }}>Top sessions today</div>
          {d.topSessions.map((s, i) => (
            <div key={i} style={{
              display: 'grid', gridTemplateColumns: '70px 1fr 50px',
              fontSize: 11, padding: '5px 0',
              color: t.muted, fontFamily: TD_FONTS.mono,
              borderBottom: i < d.topSessions.length - 1 ? `1px solid ${t.hair}` : 'none',
              fontVariantNumeric: 'tabular-nums',
            }}>
              <span style={{ whiteSpace: 'nowrap' }}>{s.time}</span>
              <span style={{ color: t.ink, fontWeight: 500, textAlign: 'right' }}>{s.tokens}</span>
              <span style={{ textAlign: 'right' }}>{s.duration}</span>
            </div>
          ))}
        </>
      )}
    </div>
  );
}

function HairStat({ label, value, t }) {
  return (
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim, marginBottom: 2 }}>{label}</div>
      <div style={{ fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.2 }}>{value}</div>
    </div>
  );
}

function WeekBarChart({ data, labels, units, avg, t }) {
  const [hoverIdx, setHoverIdx] = React.useState(-1);
  if (!data || data.length === 0) return null;
  const max = Math.max(...data, 1);
  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 8 }}>
        <span style={{ fontFamily: TD_FONTS.serif, fontSize: 12, fontStyle: 'italic', color: t.ink }}>Last 7 days</span>
        <span style={{ fontFamily: TD_FONTS.mono, fontSize: 10, color: t.dim }}>{avg ? 'avg ' + avg : ''}</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 5, height: 52, position: 'relative' }}>
        {data.map((v, i) => {
          const h = (v / max) * 36;
          const isToday = i === data.length - 1;
          const isHover = i === hoverIdx;
          return (
            <div key={i}
              onMouseEnter={() => setHoverIdx(i)}
              onMouseLeave={() => setHoverIdx(h => h === i ? -1 : h)}
              style={{
                flex: 1, display: 'flex', flexDirection: 'column',
                alignItems: 'center', gap: 4, cursor: 'default',
                position: 'relative',
              }}>
              {isHover && (
                <div style={{
                  position: 'absolute', bottom: 48, left: '50%',
                  transform: 'translateX(-50%)',
                  padding: '3px 7px', borderRadius: 4,
                  background: t.ink, color: t.canvas,
                  fontSize: 10, fontFamily: TD_FONTS.mono, whiteSpace: 'nowrap',
                  fontVariantNumeric: 'tabular-nums',
                  boxShadow: '0 4px 12px rgba(0,0,0,0.18)',
                  pointerEvents: 'none', zIndex: 10,
                }}>{formatBarValue(v, units)}</div>
              )}
              <div style={{
                width: '100%', height: Math.max(2, h),
                background: isHover ? t.coral : (isToday ? t.coral : (t.ink === VD2_DARK.ink ? TD.dBorder : '#EDE7D8')),
                borderRadius: 2,
                transition: 'background 120ms ease, transform 120ms ease',
                transform: isHover ? 'translateY(-1px)' : 'none',
              }} />
              <span style={{ fontSize: 9, color: isHover ? t.ink : t.dim, fontFamily: TD_FONTS.mono, transition: 'color 120ms ease' }}>{labels[i] || ''}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function formatBarValue(v, units) {
  if (units) return v.toFixed(2) + units;
  if (v >= 1000) return (v / 1000).toFixed(2) + 'K';
  return v.toFixed(2);
}

// ─── Codex hero (now expandable) ─────────────────────────────────────────────

function VD2_CodexHero({ t, expanded, onToggle }) {
  const d = (window.TD_DATA && window.TD_DATA.codex) || MOCK_DATA.codex;
  const warn = (d.quotas || []).some(q => q.warn || q.pct >= 85);
  return (
    <VD2_Hero t={t} warn={warn} expanded={expanded} onToggle={onToggle}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10, paddingRight: 18 }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: t.ink, whiteSpace: 'nowrap' }}>{d.name}</span>
        <Pill t={t} tone={d.pill}>{d.pill}</Pill>
        <span style={{ flex: 1 }} />
        {d.model && (
          <span style={{
            fontFamily: TD_FONTS.mono, fontSize: 9.5, color: t.dim, whiteSpace: 'nowrap',
            padding: '2px 6px',
            background: t.ink === VD2_DARK.ink ? t.surfaceAlt : '#F6F2E5',
            borderRadius: 4,
          }}>{d.model}</span>
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', marginBottom: 14, gap: 12 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{
            fontFamily: TD_FONTS.mono, fontSize: 36, color: t.ink,
            letterSpacing: -1.2, fontVariantNumeric: 'tabular-nums', lineHeight: 0.95,
          }}>{d.today}</div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim, marginTop: 5 }}>tokens today</div>
        </div>
      </div>

      {(d.quotas || []).map((q, i) => <VD2_QuotaRow key={i} q={q} t={t} />)}

      {expanded && <VD2_Drawer t={t} d={d} />}
    </VD2_Hero>
  );
}

// ─── Compact rows ────────────────────────────────────────────────────────────

function VD2_Compact({ children, t }) {
  const [hover, setHover] = React.useState(false);
  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        background: hover ? t.surface : t.compactBg,
        border: `1px solid ${hover ? t.border : (t.ink === VD2_DARK.ink ? 'rgba(237,230,214,0.06)' : 'rgba(60,45,30,0.04)')}`,
        borderRadius: 10, padding: '12px 14px', marginBottom: 8, minHeight: 68,
        boxShadow: hover ? '0 4px 10px rgba(60,45,30,0.07)' : 'none',
        transform: hover ? 'translateY(-1px)' : 'none',
        transition: 'all 160ms ease',
        display: 'flex', alignItems: 'center', gap: 12, position: 'relative',
      }}>
      {children}
      {hover && (
        <div style={{ color: t.dim, opacity: 0.7, flexShrink: 0 }}>
          <svg width="11" height="11" viewBox="0 0 12 12" fill="none"><path d="M4.5 2.5l3 3.5-3 3.5" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round"/></svg>
        </div>
      )}
    </div>
  );
}

function InlineBar({ pct, t, width = 40 }) {
  return (
    <div style={{
      width, height: 4, borderRadius: 2,
      background: t.ink === VD2_DARK.ink ? TD.dBorder : '#EDE7D8',
      overflow: 'hidden', flexShrink: 0,
    }}>
      <div style={{ width: pct + '%', height: '100%', background: t.coral, borderRadius: 2 }} />
    </div>
  );
}

function VD2_Eleven({ t, d }) {
  const [hover, setHover] = React.useState(false);
  const [expanded, setExpanded] = React.useState(false);
  const dark = t.ink === VD2_DARK.ink;
  const hasDetail = (d.hourBucketsReqs && d.hourBucketsReqs.length > 0)
                 || (d.topVoices && d.topVoices.length > 0);
  // Unconfigured / error → fall back to simple row
  if (d.pct == null) {
    return (
      <VD2_Compact t={t}>
        <Monogram letter="E" t={t} tone="creator" />
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.muted, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="creator">{d.pill}</Pill>
          </div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim, marginTop: 3 }}>
            {d.note || 'API key not configured'}
          </div>
        </div>
      </VD2_Compact>
    );
  }
  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      onClick={() => hasDetail && setExpanded(e => !e)}
      style={{
        background: hover ? t.surface : t.compactBg,
        border: `1px solid ${hover ? t.border : (dark ? 'rgba(237,230,214,0.06)' : 'rgba(60,45,30,0.04)')}`,
        borderRadius: 10, padding: '12px 14px', marginBottom: 8,
        boxShadow: hover ? '0 4px 10px rgba(60,45,30,0.07)' : 'none',
        transform: hover ? 'translateY(-1px)' : 'none',
        transition: 'all 160ms ease',
        cursor: hasDetail ? 'pointer' : 'default',
      }}>
      {/* Header row */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
        <span style={{ fontSize: 12, fontWeight: 600, color: t.ink, whiteSpace: 'nowrap' }}>{d.name}</span>
        <Pill t={t} tone={d.pill}>{d.pill}</Pill>
        <span style={{ flex: 1 }} />
        {d.resets && <span style={{
          fontFamily: TD_FONTS.mono, fontSize: 10, color: t.dim, whiteSpace: 'nowrap',
        }}>{d.resets}</span>}
      </div>
      {/* Body: ring + text */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
        <Ring pct={Number(d.pct)} t={t} />
        <div style={{ minWidth: 0, flex: 1 }}>
          {d.usedLabel && (
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 15, color: t.ink,
              fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3, lineHeight: 1.1,
            }}>{d.usedLabel} <span style={{ color: t.dim }}>/ {d.totalLabel}</span></div>
          )}
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic',
            fontSize: 11, color: t.dim, marginTop: 4,
          }}>characters this cycle</div>
          {d.reqsToday != null && (
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 10, color: t.muted, marginTop: 5,
              letterSpacing: 0.2, display: 'flex', alignItems: 'baseline', gap: 6, flexWrap: 'wrap',
            }}>
              <span>
                <span style={{ color: t.ink, fontWeight: 500 }}>{d.reqsToday}</span>
                <span style={{ opacity: 0.75 }}> reqs today</span>
              </span>
              {d.charsToday && Number(d.charsToday.replace(/,/g, '')) > 0 && (
                <>
                  <span style={{ opacity: 0.4 }}>·</span>
                  <span><span style={{ color: t.ink, fontWeight: 500 }}>{d.charsToday}</span><span style={{ opacity: 0.75 }}> chars</span></span>
                </>
              )}
              {d.reqTrend && (
                <>
                  <span style={{ opacity: 0.4 }}>·</span>
                  <span style={{
                    color: d.reqTrend.indexOf('↗') >= 0
                      ? (t.ink === VD2_DARK.ink ? TD.dGreen : '#5B7A4C')
                      : (d.reqTrend.indexOf('↘') >= 0 ? t.dim : t.dim),
                  }}>{d.reqTrend}</span>
                </>
              )}
            </div>
          )}
        </div>
      </div>

      {/* 7-day requests sparkbar */}
      {d.history7 && d.history7.length > 0 && (
        <div style={{
          marginTop: 10, display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <Sparkbars data={d.history7} color={dark ? TD.dGold : '#C89464'} dim={dark ? '#3A332C' : '#EEE4D1'} />
          <span style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic',
            fontSize: 10.5, color: t.dim,
          }}>7d reqs</span>
          <span style={{ flex: 1 }} />
          <TrendChip label={d.historyTrend} t={t} />
        </div>
      )}

      {expanded && <VD2_ElevenDrawer t={t} d={d} />}
    </div>
  );
}

// ── Shared primitives ───────────────────────────────────────────────────────

// Format seconds as "5m", "1h 12m", etc.
function fmtDuration(secs) {
  if (!secs || secs < 60) return `${Math.round(secs || 0)}s`;
  const m = Math.round(secs / 60);
  if (m < 60) return `${m}m`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

// Compact token formatter for OpenRouter tables.
function fmtTokensAbbrev(n) {
  if (!n) return '0';
  if (n < 1000) return String(n);
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}K`;
  if (n < 1_000_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  return `${(n / 1_000_000_000).toFixed(2)}B`;
}

// A bar chart with a floating tooltip that follows the hovered bar.
// Designed to work inside tight drawers — the tooltip anchors to the bar's
// center and is clamped to the chart's horizontal bounds so it never
// overflows the popover. Vertically, it sits *above* the bar on a small gap
// so the cursor doesn't occlude it.
//
// props:
//   bars          array of { value: number, color?: string, dim?: bool }
//   heightPx      bar area height
//   tooltipLabel  fn(index) → string  (e.g. "Mon · $3.42 · 120 reqs")
//   axisLabels    optional array of strings rendered below (same slots as bars)
//   gap           px gap between bars (default 2)
//   minBarPx      guarantees tiny values stay visible (default 2)
function HoverBarChart({ t, bars, heightPx = 38, tooltipLabel, axisLabels, gap = 2, minBarPx = 2 }) {
  const [hoverIdx, setHoverIdx] = React.useState(-1);
  const ref = React.useRef(null);
  const [tipLeft, setTipLeft] = React.useState(0);
  const max = Math.max(1, ...bars.map(b => b.value || 0));
  const dark = t.ink === VD2_DARK.ink;

  // Compute tooltip x-position (center of hovered bar, clamped to chart).
  const handleEnter = (e, i) => {
    setHoverIdx(i);
    const parent = ref.current;
    if (!parent) return;
    const bar = parent.children[0].children[i];
    if (!bar) return;
    const pRect = parent.getBoundingClientRect();
    const bRect = bar.getBoundingClientRect();
    const center = bRect.left + bRect.width / 2 - pRect.left;
    setTipLeft(center);
  };

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <div style={{
        display: 'grid',
        gridTemplateColumns: `repeat(${bars.length}, 1fr)`,
        gap: `${gap}px`, alignItems: 'end', height: heightPx,
      }}>
        {bars.map((b, i) => {
          const val = b.value || 0;
          const h = val === 0 ? Math.max(1, minBarPx - 1)
                              : Math.max(minBarPx, (val / max) * heightPx);
          const bg = val === 0
            ? t.hair
            : (b.color || (b.dim ? (dark ? '#6B6057' : '#D4C4A8') : (dark ? TD.dGold : '#C89464')));
          const isHover = hoverIdx === i;
          return (
            <div key={i}
                 onMouseEnter={(e) => handleEnter(e, i)}
                 onMouseLeave={() => setHoverIdx(-1)}
                 style={{
                   height: `${h}px`, background: bg, borderRadius: 1,
                   transition: 'opacity 80ms ease',
                   opacity: hoverIdx >= 0 && !isHover ? 0.55 : 1,
                   cursor: 'default',
                 }} />
          );
        })}
      </div>

      {/* Tooltip */}
      {hoverIdx >= 0 && (
        <div style={{
          position: 'absolute',
          left: 0,
          bottom: heightPx + 6,
          width: '100%',
          pointerEvents: 'none',
        }}>
          <div style={{
            position: 'absolute',
            left: `${tipLeft}px`,
            transform: 'translateX(-50%)',
            background: dark ? '#2B2820' : '#1A1915',
            color: dark ? '#EDE6D6' : '#FCFBF7',
            borderRadius: 4, padding: '4px 8px',
            fontFamily: TD_FONTS.mono, fontSize: 10.5,
            whiteSpace: 'nowrap',
            fontVariantNumeric: 'tabular-nums',
            boxShadow: '0 2px 8px rgba(0,0,0,0.25)',
          }}>{tooltipLabel(hoverIdx)}</div>
        </div>
      )}

      {axisLabels && (
        <div style={{
          display: 'grid', gridTemplateColumns: `repeat(${axisLabels.length}, 1fr)`,
          marginTop: 4, fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 9, color: t.dim, textAlign: 'center',
        }}>
          {axisLabels.map((lb, i) => <span key={i}>{lb}</span>)}
        </div>
      )}
    </div>
  );
}

// ── ElevenLabs drawer ───────────────────────────────────────────────────────
//
// Drawer for the "monitor my kid's English TTS game" use case. Leads with
// parent-oriented screen-time metrics (play sessions + estimated speech
// minutes), then the raw hourly/request pattern, then abuse-detection
// banner + voice breakdown.
function VD2_ElevenDrawer({ t, d }) {
  const dark = t.ink === VD2_DARK.ink;
  const color = dark ? TD.dGold : '#C89464';
  const reqBuckets = d.hourBucketsReqs || [];
  const charBuckets = d.hourBucketsChars || [];
  const peakIdx = typeof d.peakHourIdx === 'number' ? d.peakHourIdx : null;
  const anomalyIdx = typeof d.anomalyHour === 'number' ? d.anomalyHour : null;
  const avgChars = typeof d.avgChars === 'number' ? d.avgChars : null;
  const maxChars = typeof d.maxCharsReq === 'number' ? d.maxCharsReq : null;
  const playSessions = typeof d.playSessions === 'number' ? d.playSessions : null;
  const speechSecs = typeof d.speechSeconds === 'number' ? d.speechSeconds : 0;
  const longestSec = typeof d.longestSessionSec === 'number' ? d.longestSessionSec : 0;
  const topVoices = d.topVoices || [];

  const fmtHour = (h) => {
    h = ((h % 24) + 24) % 24;
    if (h === 0) return '12 AM';
    if (h === 12) return '12 PM';
    return h < 12 ? `${h} AM` : `${h - 12} PM`;
  };
  const fmtInt = (n) => n == null ? '—' : Number(n).toLocaleString();
  const fmtChars = (n) => {
    if (n == null) return '—';
    if (n < 1000) return `${n}`;
    if (n < 1_000_000) return `${(n / 1000).toFixed(1)}K`;
    return `${(n / 1_000_000).toFixed(2)}M`;
  };

  const warnTextColor = dark ? '#E5A873' : '#B46B2F';
  const warnBg = dark ? 'rgba(196,136,114,0.12)' : 'rgba(180,107,47,0.08)';

  // Hourly bars wired with anomaly / peak coloring.
  const hourBars = reqBuckets.map((n, i) => ({
    value: n,
    color: anomalyIdx === i ? (dark ? '#D07565' : '#B44A3A')
         : peakIdx === i ? color
         : undefined,
    dim: anomalyIdx !== i && peakIdx !== i,
  }));
  const hourTooltip = (i) => {
    const r = reqBuckets[i] || 0;
    const c = charBuckets[i] || 0;
    return `${fmtHour(i)} · ${r} req${r === 1 ? '' : 's'} · ${fmtChars(c)} chars`;
  };

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{ marginTop: 12, paddingTop: 12, borderTop: `1px solid ${t.hair}` }}>

      {/* Screen-time tiles — the metric ElevenLabs' own UI doesn't show */}
      {playSessions !== null && (
        <div style={{
          display: 'grid', gridTemplateColumns: '1fr 1fr 1fr',
          gap: 8, marginBottom: 10,
        }}>
          {[
            { k: 'Play sessions', v: fmtInt(playSessions),
              hint: playSessions === 0 ? 'no activity today' : 'today' },
            { k: 'Speech time',   v: fmtDuration(speechSecs),
              hint: 'est. audio minutes' },
            { k: 'Longest session', v: fmtDuration(longestSec),
              hint: 'uninterrupted' },
          ].map((x, i) => (
            <div key={i} style={{
              background: t.compactBg, border: `1px solid ${t.hair}`,
              borderRadius: 6, padding: '6px 8px',
            }}>
              <div style={{
                fontFamily: TD_FONTS.serif, fontStyle: 'italic',
                fontSize: 9.5, color: t.dim, marginBottom: 2,
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              }}>{x.k}</div>
              <div style={{
                fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink,
                fontVariantNumeric: 'tabular-nums',
              }}>{x.v}</div>
              <div style={{
                fontFamily: TD_FONTS.serif, fontStyle: 'italic',
                fontSize: 9, color: t.dim, marginTop: 2,
              }}>{x.hint}</div>
            </div>
          ))}
        </div>
      )}

      {/* Secondary usage row: raw counts and outlier detection */}
      <div style={{
        display: 'grid', gridTemplateColumns: '1fr 1fr 1fr',
        gap: 8, marginBottom: 10,
      }}>
        {[
          { k: 'Reqs today',   v: fmtInt(d.reqsToday) },
          { k: 'Avg chars/req', v: fmtInt(avgChars) },
          { k: 'Longest req',   v: fmtChars(maxChars) },
        ].map((x, i) => (
          <div key={i} style={{
            background: t.compactBg, border: `1px solid ${t.hair}`,
            borderRadius: 6, padding: '6px 8px',
          }}>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 9.5, color: t.dim, marginBottom: 2,
            }}>{x.k}</div>
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink,
              fontVariantNumeric: 'tabular-nums',
            }}>{x.v}</div>
          </div>
        ))}
      </div>

      {/* 24-hour pattern today — now with floating tooltip */}
      {reqBuckets.length === 24 && (
        <div style={{ marginBottom: 12 }}>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
            marginBottom: 2,
          }}>Hourly pattern today</div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim,
            marginBottom: 8,
          }}>hover a bar for exact counts</div>
          <HoverBarChart
            t={t}
            bars={hourBars}
            heightPx={38}
            gap={2}
            tooltipLabel={hourTooltip}
            axisLabels={['12a', '6a', '12p', '6p'].flatMap((s, i) =>
              // 4 labels spread across 24 slots
              [s, ...(i < 3 ? ['', '', '', '', ''] : [])]
            ).slice(0, 24)}
          />
        </div>
      )}

      {/* Anomaly banner */}
      {anomalyIdx !== null && (
        <div style={{
          marginBottom: 12, padding: '8px 10px',
          background: warnBg, border: `1px solid ${warnTextColor}40`,
          borderRadius: 6,
          fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: warnTextColor, lineHeight: 1.4,
        }}>
          <span style={{ fontWeight: 600 }}>Unusual burst</span>{' '}
          at {fmtHour(anomalyIdx)}: {d.anomalyHourReqs} requests in one hour.
          {' '}Check if your API key leaked — typical kid-game usage is steady,
          not bursty.
        </div>
      )}

      {/* Top voices today */}
      {topVoices.length > 0 && (
        <div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
            marginBottom: 6,
          }}>Top voices today</div>
          {topVoices.map((v, i) => (
            <div key={i} style={{
              display: 'grid', gridTemplateColumns: '1fr auto auto',
              columnGap: 8, padding: '4px 0',
              borderBottom: i < topVoices.length - 1 ? `1px solid ${t.hair}` : 'none',
              fontSize: 11,
            }}>
              <span style={{
                color: t.ink, fontFamily: TD_FONTS.serif, fontStyle: 'italic',
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              }}>{v.name}</span>
              <span style={{
                fontFamily: TD_FONTS.mono, color: t.muted,
                fontVariantNumeric: 'tabular-nums',
              }}>{fmtInt(v.reqs)} reqs</span>
              <span style={{
                fontFamily: TD_FONTS.mono, color: t.dim,
                fontVariantNumeric: 'tabular-nums', minWidth: 56, textAlign: 'right',
              }}>{fmtChars(v.chars)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function VD2_Router({ t, d }) {
  const [expanded, setExpanded] = React.useState(false);
  const dark = t.ink === VD2_DARK.ink;
  // Expand whenever *anything* useful lives in the drawer. /v1/activity can
  // 404 on accounts without the extra OAuth scope — in that case topModels /
  // allModels come back empty but spend/reqs totals may still be present
  // (we store "$0.00" / 0 as defaults, so check for non-empty totals).
  const hasAnyModels   = (d.topModels && d.topModels.length > 0)
                       || (d.allModels && d.allModels.length > 0);
  const hasHistory     = d.history7 && d.history7.length > 0;
  const hasActivitySum = (typeof d.reqs7d === 'number' && d.reqs7d > 0)
                       || (typeof d.reqsToday === 'number' && d.reqsToday > 0)
                       || (d.spend7d && d.spend7d !== '$0.00')
                       || (d.burnPerDay && d.burnPerDay !== '$0.00');
  const hasDetail = hasAnyModels || hasHistory || hasActivitySum;
  const coral = dark ? TD.dCoral : TD.coral;

  if (!d.credits) {
    // Unconfigured / error fallback — keep old flat layout.
    return (
      <VD2_Compact t={t}>
        <Monogram letter="O" t={t} tone="payg" />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.muted, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="payg">{d.pill}</Pill>
          </div>
          {d.note && <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim, marginTop: 3 }}>{d.note}</div>}
        </div>
      </VD2_Compact>
    );
  }
  return (
    <div
      onClick={() => hasDetail && setExpanded(e => !e)}
      style={{
        background: t.compactBg,
        border: `1px solid ${dark ? 'rgba(237,230,214,0.06)' : 'rgba(60,45,30,0.04)'}`,
        borderRadius: 10, padding: '12px 14px', marginBottom: 8,
        cursor: hasDetail ? 'pointer' : 'default',
      }}>
      {/* Header row */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <Monogram letter="O" t={t} tone="payg" />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.ink, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="payg">{d.pill}</Pill>
          </div>
          {d.spendLabel && <div style={{ fontFamily: TD_FONTS.mono, fontSize: 10.5, color: t.dim, marginTop: 3, whiteSpace: 'nowrap' }}>{d.spendLabel}</div>}
        </div>
        <div style={{ flex: 1 }} />
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontFamily: TD_FONTS.mono, fontSize: 15, color: t.ink, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3, lineHeight: 1 }}>{d.credits}</div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim, marginTop: 4 }}>left</div>
        </div>
      </div>

      {/* Sparkbars row — daily spend for last 7 days */}
      {d.history7 && d.history7.length > 0 && (
        <div style={{
          marginTop: 10, display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <Sparkbars data={d.history7} color={coral} dim={dark ? '#3A332C' : '#E6DDD0'} />
          <span style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic',
            fontSize: 10.5, color: t.dim,
          }}>7d spend</span>
          <span style={{ flex: 1 }} />
          <TrendChip label={d.historyTrend} t={t} />
        </div>
      )}

      {/* Expanded: drawer */}
      {expanded && <VD2_RouterDrawer t={t} d={d} />}
    </div>
  );
}

// ── OpenRouter drawer ───────────────────────────────────────────────────────
//
// Three tabs mirror the Claude Code drawer pattern and OpenRouter's own web
// UI vocabulary. Overview for the at-a-glance picture, Models for cost
// efficiency comparison ($/1M tokens across models), Activity for daily
// spend breakdown with hover tooltips.
function VD2_RouterDrawer({ t, d }) {
  const [tab, setTab] = React.useState('overview');
  const fmtInt = (n) => n == null ? '—' : Number(n).toLocaleString();
  const fmtUsd = (n) => `$${(n || 0).toFixed(2)}`;

  const tabs = [
    { id: 'overview', label: 'Overview' },
    { id: 'models',   label: 'Models'   },
    { id: 'activity', label: 'Activity' },
  ];

  return (
    <div onClick={(e) => e.stopPropagation()} style={{
      marginTop: 12, paddingTop: 10, borderTop: `1px solid ${t.hair}`,
    }}>
      {/* Tab bar (same primitive as Claude drawer) */}
      <div style={{
        display: 'inline-flex', gap: 4, marginBottom: 12,
        background: t.compactBg, borderRadius: 8, padding: 3,
        border: `1px solid ${t.hair}`,
      }}>
        {tabs.map(x => (
          <button
            key={x.id}
            onClick={() => setTab(x.id)}
            style={{
              appearance: 'none', border: 'none', cursor: 'pointer',
              background: tab === x.id ? t.surface : 'transparent',
              color: tab === x.id ? t.ink : t.muted,
              fontFamily: TD_FONTS.sans, fontSize: 11.5,
              fontWeight: tab === x.id ? 600 : 400,
              padding: '3px 10px', borderRadius: 6,
              boxShadow: tab === x.id ? '0 1px 2px rgba(0,0,0,0.08)' : 'none',
              transition: 'background 120ms ease',
            }}
          >{x.label}</button>
        ))}
      </div>

      {tab === 'overview' && <RouterOverviewTab t={t} d={d} fmtInt={fmtInt} />}
      {tab === 'models'   && <RouterModelsTab   t={t} d={d} fmtInt={fmtInt} fmtUsd={fmtUsd} />}
      {tab === 'activity' && <RouterActivityTab t={t} d={d} fmtInt={fmtInt} fmtUsd={fmtUsd} />}
    </div>
  );
}

// Overview — today / 7d numbers + burn rate + sparkline with tooltips.
function RouterOverviewTab({ t, d, fmtInt }) {
  const dark = t.ink === VD2_DARK.ink;
  const daily = d.dailySpend || [];
  const tiles = [
    { k: 'Today',       v: d.spendToday || '$0.00' },
    { k: 'Reqs today',  v: fmtInt(d.reqsToday) },
    { k: '7-day spend', v: d.spend7d || '$0.00' },
    { k: '7-day reqs',  v: fmtInt(d.reqs7d) },
  ];
  const bars = daily.map((dpt) => ({ value: dpt.spend || 0 }));
  const tipFor = (i) => {
    const dpt = daily[i];
    if (!dpt) return '';
    return `${dpt.label} · $${(dpt.spend || 0).toFixed(2)} · ${dpt.reqs || 0} reqs`;
  };
  const axis = daily.map(d => d.label.split(' ')[1]);   // e.g. "15" from "Apr 15"

  return (
    <div>
      <div style={{
        display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr',
        gap: 8, marginBottom: 10,
      }}>
        {tiles.map((x, i) => (
          <div key={i} style={{
            background: t.compactBg, border: `1px solid ${t.hair}`,
            borderRadius: 6, padding: '6px 8px',
          }}>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 9.5, color: t.dim, marginBottom: 2,
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{x.k}</div>
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 12.5, color: t.ink,
              fontVariantNumeric: 'tabular-nums',
            }}>{x.v}</div>
          </div>
        ))}
      </div>

      {/* Burn rate + runway */}
      {d.burnPerDay && (
        <div style={{
          marginBottom: 12, paddingBottom: 10,
          borderBottom: `1px solid ${t.hair}`,
          fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: t.dim, lineHeight: 1.5,
        }}>
          <span style={{ color: t.ink }}>{d.burnPerDay}/day</span> average
          over the last 7 days
          {typeof d.daysLeft === 'number' && (
            <>
              {' — '}
              <span style={{ color: t.ink }}>
                credits last {d.daysLeft > 365 ? '365+' : d.daysLeft} day{d.daysLeft === 1 ? '' : 's'}
              </span>
              {' '}at this pace
            </>
          )}
        </div>
      )}

      {/* 7-day spend chart */}
      {bars.length > 0 && (
        <div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
            marginBottom: 2,
          }}>Spend last 7 days</div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim,
            marginBottom: 8,
          }}>hover a bar for exact $ + request count</div>
          <HoverBarChart
            t={t}
            bars={bars.map(b => ({ ...b, color: dark ? TD.dCoral : TD.coral }))}
            heightPx={42}
            gap={4}
            tooltipLabel={tipFor}
            axisLabels={axis}
          />
        </div>
      )}
    </div>
  );
}

// Models — sortable-feeling table: name, reqs, total tokens, $/req, total $,
// with an extra "$/1M tokens" column exposing which model is cheapest on
// this specific workload. That's the number that actually matters for
// optimizing spend; a $10/M model that batches well can beat a $5/M model
// that needs more round-trips.
function RouterModelsTab({ t, d, fmtInt, fmtUsd }) {
  const models = d.allModels || d.topModels || [];
  if (models.length === 0) {
    return (
      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim,
      }}>No model activity recorded in the last 7 days.</div>
    );
  }
  // Is the activity endpoint providing token counts? If not, we hide the
  // token-based columns rather than show a row of zeros.
  const hasTokens = models.some(m => (m.totalTokens || 0) > 0);

  return (
    <div>
      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
        marginBottom: 2,
      }}>Models (last 7 days)</div>
      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim,
        marginBottom: 6,
      }}>sorted by spend · $/1M shows cost efficiency</div>

      {/* Header row */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: hasTokens ? '1fr 52px 70px 70px 60px' : '1fr 60px 70px 70px',
        columnGap: 6, padding: '4px 0',
        borderBottom: `1px solid ${t.hair}`,
        fontFamily: TD_FONTS.serif, fontStyle: 'italic',
        fontSize: 9.5, color: t.dim,
      }}>
        <span>Model</span>
        <span style={{ textAlign: 'right' }}>Reqs</span>
        {hasTokens && <span style={{ textAlign: 'right' }}>Tokens</span>}
        <span style={{ textAlign: 'right' }}>{hasTokens ? '$ / 1M' : '$ / req'}</span>
        <span style={{ textAlign: 'right' }}>Spend</span>
      </div>

      {models.map((m, i) => {
        const reqs = m.reqs || 0;
        const tokens = m.totalTokens || 0;
        const avgPerReq = m.avgPerReq || 0;
        const perMillion = m.perMillion || 0;
        return (
          <div key={i} style={{
            display: 'grid',
            gridTemplateColumns: hasTokens ? '1fr 52px 70px 70px 60px' : '1fr 60px 70px 70px',
            columnGap: 6, padding: '5px 0', alignItems: 'baseline',
            borderBottom: i < models.length - 1 ? `1px solid ${t.hair}` : 'none',
            fontSize: 11,
          }}>
            <span style={{
              color: t.ink, fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{m.name}</span>
            <span style={{
              fontFamily: TD_FONTS.mono, color: t.muted,
              fontVariantNumeric: 'tabular-nums', textAlign: 'right',
            }}>{fmtInt(reqs)}</span>
            {hasTokens && (
              <span style={{
                fontFamily: TD_FONTS.mono, color: t.muted,
                fontVariantNumeric: 'tabular-nums', textAlign: 'right',
              }}>{fmtTokensAbbrev(tokens)}</span>
            )}
            <span style={{
              fontFamily: TD_FONTS.mono, color: t.muted,
              fontVariantNumeric: 'tabular-nums', textAlign: 'right',
            }}>{hasTokens ? fmtUsd(perMillion) : fmtUsd(avgPerReq)}</span>
            <span style={{
              fontFamily: TD_FONTS.mono, color: t.ink, fontWeight: 500,
              fontVariantNumeric: 'tabular-nums', textAlign: 'right',
            }}>{m.spend}</span>
          </div>
        );
      })}
    </div>
  );
}

// Activity — daily spend bars (larger) + insight callout "biggest day".
function RouterActivityTab({ t, d, fmtInt, fmtUsd }) {
  const dark = t.ink === VD2_DARK.ink;
  const daily = d.dailySpend || [];
  if (daily.length === 0) {
    return (
      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim,
      }}>No daily activity data available (OpenRouter /v1/activity may be unavailable on this account).</div>
    );
  }
  const bars = daily.map(dpt => ({ value: dpt.spend || 0 }));
  const tipFor = (i) => {
    const dpt = daily[i];
    if (!dpt) return '';
    return `${dpt.label} · $${(dpt.spend || 0).toFixed(2)} · ${dpt.reqs || 0} reqs`;
  };
  const axis = daily.map(d => d.label);

  const promptTokens = d.promptTokens7d || 0;
  const completionTokens = d.completionTokens7d || 0;

  return (
    <div>
      {d.biggestDayLabel && (
        <div style={{
          marginBottom: 12,
          fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: t.dim, lineHeight: 1.5,
        }}>
          <span style={{ color: t.ink, fontWeight: 600 }}>Biggest day:</span>{' '}
          {d.biggestDayLabel} — {d.biggestDaySpend}
        </div>
      )}

      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
        marginBottom: 2,
      }}>Daily spend</div>
      <div style={{
        fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim,
        marginBottom: 8,
      }}>hover a bar for detail</div>
      <HoverBarChart
        t={t}
        bars={bars.map(b => ({ ...b, color: dark ? TD.dCoral : TD.coral }))}
        heightPx={56}
        gap={6}
        tooltipLabel={tipFor}
        axisLabels={axis}
      />

      {(promptTokens > 0 || completionTokens > 0) && (
        <div style={{
          marginTop: 14, paddingTop: 10,
          borderTop: `1px solid ${t.hair}`,
          display: 'grid', gridTemplateColumns: '1fr 1fr',
          gap: 8,
        }}>
          <div style={{
            background: t.compactBg, border: `1px solid ${t.hair}`,
            borderRadius: 6, padding: '6px 8px',
          }}>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 9.5, color: t.dim, marginBottom: 2,
            }}>Prompt tokens (7d)</div>
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink,
              fontVariantNumeric: 'tabular-nums',
            }}>{fmtTokensAbbrev(promptTokens)}</div>
          </div>
          <div style={{
            background: t.compactBg, border: `1px solid ${t.hair}`,
            borderRadius: 6, padding: '6px 8px',
          }}>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 9.5, color: t.dim, marginBottom: 2,
            }}>Completion tokens (7d)</div>
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink,
              fontVariantNumeric: 'tabular-nums',
            }}>{fmtTokensAbbrev(completionTokens)}</div>
          </div>
        </div>
      )}
    </div>
  );
}

function VD2_Groq({ t, d }) {
  return (
    <VD2_Compact t={t}>
      <Monogram letter="G" t={t} tone="free" />
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: t.muted, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
          {d.name}<Pill t={t} tone="free">{d.pill}</Pill>
        </div>
        <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim, marginTop: 3, lineHeight: 1.3 }}>
          {d.note || 'no usage API'}
        </div>
      </div>
    </VD2_Compact>
  );
}

// ── Moonshot compact card + drawer ─────────────────────────────────────────
function VD2_Moonshot({ t, d }) {
  const [expanded, setExpanded] = React.useState(false);
  const dark = t.ink === VD2_DARK.ink;
  const hasDetail = (d.modelIds && d.modelIds.length > 0) || d.spentTodayLabel;

  if (!d.headline || d.state === 'unconfigured') {
    return (
      <VD2_Compact t={t}>
        <Monogram letter="M" t={t} tone="free" />
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.muted, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="free">{d.pill}</Pill>
          </div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim, marginTop: 3 }}>
            {d.note || 'API key not configured'}
          </div>
        </div>
      </VD2_Compact>
    );
  }
  return (
    <div
      onClick={() => hasDetail && setExpanded(e => !e)}
      style={{
        background: t.compactBg,
        border: `1px solid ${dark ? 'rgba(237,230,214,0.06)' : 'rgba(60,45,30,0.04)'}`,
        borderRadius: 10, padding: '12px 14px', marginBottom: 8,
        cursor: hasDetail ? 'pointer' : 'default',
      }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <Monogram letter="M" t={t} tone="free" />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.ink, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="free">{d.pill}</Pill>
          </div>
          <div style={{
            fontFamily: TD_FONTS.mono, fontSize: 10.5, color: t.dim, marginTop: 3,
            fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap',
          }}>{d.note}</div>
        </div>
        <div style={{ flex: 1 }} />
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontFamily: TD_FONTS.mono, fontSize: 15, color: t.ink, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3, lineHeight: 1 }}>{d.headline}</div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim, marginTop: 4 }}>available</div>
        </div>
      </div>

      {expanded && <VD2_MoonshotDrawer t={t} d={d} />}
    </div>
  );
}

function VD2_MoonshotDrawer({ t, d }) {
  const [modelsOpen, setModelsOpen] = React.useState(false);
  const dark = t.ink === VD2_DARK.ink;
  const modelIds = d.modelIds || [];
  const history7 = d.history7 || [];
  const currency = d.currency || '$';
  const fmtMoney = (n) => {
    const v = n || 0;
    return `${currency}${v.toFixed(2)}`;
  };

  // 7-day spend chart. Same primitive as OpenRouter's so the two feel
  // consistent when you tab between drawers.
  const bars = history7.map(v => ({ value: v }));
  const dayLabels = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date();
    d.setDate(d.getDate() - i);
    dayLabels.push(String(d.getDate()));
  }
  const tip = (i) => {
    const v = history7[i] || 0;
    const d = new Date();
    d.setDate(d.getDate() - (6 - i));
    const label = d.toLocaleDateString('en', { month: 'short', day: 'numeric' });
    return `${label} · ${fmtMoney(v)}`;
  };
  const hasSpendHistory = bars.some(b => b.value > 0);

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{ marginTop: 12, paddingTop: 10, borderTop: `1px solid ${t.hair}` }}>

      {/* Three tiles — the things an agent operator actually checks */}
      <div style={{
        display: 'grid', gridTemplateColumns: '1fr 1fr 1fr',
        gap: 8, marginBottom: 10,
      }}>
        {[
          {
            k: 'Spent today',
            v: d.spentTodayLabel || `${currency}0.00`,
            hint: 'derived from balance',
          },
          {
            k: 'Avg / day',
            v: d.avgPerDayLabel || `${currency}0.00`,
            hint: '7-day average',
          },
          {
            k: 'Days left',
            v: typeof d.daysLeft === 'number'
                 ? (d.daysLeft > 365 ? '365+' : String(d.daysLeft))
                 : '—',
            hint: 'at current pace',
          },
        ].map((x, i) => (
          <div key={i} style={{
            background: t.compactBg, border: `1px solid ${t.hair}`,
            borderRadius: 6, padding: '6px 8px',
          }}>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 9.5, color: t.dim, marginBottom: 2,
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{x.k}</div>
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink,
              fontVariantNumeric: 'tabular-nums',
            }}>{x.v}</div>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 9, color: t.dim, marginTop: 2,
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{x.hint}</div>
          </div>
        ))}
      </div>

      {/* 7-day spend trend */}
      {hasSpendHistory ? (
        <div style={{ marginBottom: 12 }}>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
            marginBottom: 2,
          }}>Daily spend · last 7 days</div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim,
            marginBottom: 8,
          }}>hover for exact amount</div>
          <HoverBarChart
            t={t}
            bars={bars.map(b => ({ ...b, color: dark ? TD.dCoral : TD.coral }))}
            heightPx={42}
            gap={4}
            tooltipLabel={tip}
            axisLabels={dayLabels}
          />
        </div>
      ) : (
        // First-day install — we need ≥ 24h of balance snapshots before
        // the chart is meaningful. Say so instead of rendering flatlined bars.
        <div style={{
          marginBottom: 12, padding: '10px',
          background: t.compactBg, border: `1px solid ${t.hair}`,
          borderRadius: 6,
          fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: t.dim, textAlign: 'center', lineHeight: 1.5,
        }}>
          Spend chart builds up as we record balance over the coming days.
        </div>
      )}

      {/* Models — collapsed by default, single-line summary → expand on tap */}
      {modelIds.length > 0 && (
        <div style={{ paddingTop: 8, borderTop: `1px solid ${t.hair}` }}>
          <button
            onClick={(e) => { e.stopPropagation(); setModelsOpen(v => !v); }}
            style={{
              appearance: 'none', border: 'none', background: 'transparent',
              padding: 0, cursor: 'pointer', width: '100%', textAlign: 'left',
              display: 'flex', alignItems: 'center', gap: 6,
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 11, color: t.dim,
            }}>
            <span style={{
              display: 'inline-block',
              transform: modelsOpen ? 'rotate(90deg)' : 'rotate(0deg)',
              transition: 'transform 150ms ease',
              fontSize: 9, color: t.dim,
            }}>▸</span>
            <span>{modelIds.length} models accessible to this key</span>
          </button>
          {modelsOpen && (
            <div style={{
              display: 'flex', flexWrap: 'wrap', gap: 4,
              marginTop: 8,
            }}>
              {modelIds.map((id, i) => (
                <span key={i} style={{
                  fontFamily: TD_FONTS.mono, fontSize: 10,
                  color: t.muted, background: dark ? 'rgba(237,230,214,0.04)' : 'rgba(60,45,30,0.04)',
                  padding: '2px 7px', borderRadius: 10,
                  border: `1px solid ${t.hair}`,
                  whiteSpace: 'nowrap',
                }}>{id}</span>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── GitHub compact card + drawer ───────────────────────────────────────────
function VD2_GitHub({ t, d }) {
  const [expanded, setExpanded] = React.useState(false);
  const dark = t.ink === VD2_DARK.ink;
  const hasDetail = (d.rateBuckets && d.rateBuckets.length > 0) || typeof d.actionsUsed === 'string';

  if (!d.headline || d.state === 'unconfigured') {
    return (
      <VD2_Compact t={t}>
        <Monogram letter="G" t={t} tone="free" />
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.muted, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="free">{d.pill}</Pill>
          </div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim, marginTop: 3 }}>
            {d.note || 'API key not configured'}
          </div>
        </div>
      </VD2_Compact>
    );
  }
  return (
    <div
      onClick={() => hasDetail && setExpanded(e => !e)}
      style={{
        background: t.compactBg,
        border: `1px solid ${dark ? 'rgba(237,230,214,0.06)' : 'rgba(60,45,30,0.04)'}`,
        borderRadius: 10, padding: '12px 14px', marginBottom: 8,
        cursor: hasDetail ? 'pointer' : 'default',
      }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <Monogram letter="G" t={t} tone="free" />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.ink, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="free">{d.pill}</Pill>
          </div>
          <div style={{ fontFamily: TD_FONTS.mono, fontSize: 10.5, color: t.dim, marginTop: 3, whiteSpace: 'nowrap' }}>
            {d.caption} · resets {d.resetIn}
          </div>
        </div>
        <div style={{ flex: 1 }} />
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontFamily: TD_FONTS.mono, fontSize: 15, color: t.ink, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3, lineHeight: 1 }}>{d.headline}</div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim, marginTop: 4 }}>remaining</div>
        </div>
      </div>

      {expanded && <VD2_GitHubDrawer t={t} d={d} />}
    </div>
  );
}

function VD2_GitHubDrawer({ t, d }) {
  const buckets = d.rateBuckets || [];
  const fmtInt = (n) => n == null ? '—' : Number(n).toLocaleString();
  const fmtETA = (unix) => {
    const s = Math.max(0, Math.round(unix - Date.now() / 1000));
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.floor(s / 60)}m`;
    return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  };
  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{ marginTop: 12, paddingTop: 10, borderTop: `1px solid ${t.hair}` }}>

      {/* Rate limit buckets */}
      {buckets.length > 0 && (
        <div style={{ marginBottom: 10 }}>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
            marginBottom: 6,
          }}>Rate limit buckets</div>
          {buckets.map((b, i) => {
            const pct = b.limit > 0 ? (b.limit - b.remaining) / b.limit * 100 : 0;
            const dark = t.ink === VD2_DARK.ink;
            const barColor = pct >= 90 ? (dark ? '#D07565' : '#B44A3A')
                           : pct >= 70 ? (dark ? '#E5A873' : '#B46B2F')
                           : (dark ? TD.dGreen : '#6B8E5A');
            return (
              <div key={i} style={{ marginBottom: 6 }}>
                <div style={{
                  display: 'grid', gridTemplateColumns: '80px 1fr auto',
                  columnGap: 8, alignItems: 'center',
                  fontSize: 11, padding: '2px 0',
                }}>
                  <span style={{ color: t.ink, fontFamily: TD_FONTS.serif, fontStyle: 'italic' }}>{b.name}</span>
                  <div style={{ height: 5, background: t.hair, borderRadius: 2, overflow: 'hidden' }}>
                    <div style={{
                      height: '100%', width: `${Math.min(100, pct)}%`,
                      background: barColor, borderRadius: 2,
                    }} />
                  </div>
                  <span style={{
                    fontFamily: TD_FONTS.mono, color: t.muted,
                    fontVariantNumeric: 'tabular-nums', fontSize: 10,
                  }}>{fmtInt(b.remaining)} / {fmtInt(b.limit)} · {fmtETA(b.reset)}</span>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* Actions minutes */}
      {typeof d.actionsUsed === 'string' && (
        <div style={{
          paddingTop: 10, borderTop: `1px solid ${t.hair}`,
          fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: t.dim, lineHeight: 1.5,
        }}>
          <span style={{ color: t.ink }}>Actions: {d.actionsUsed}</span> minutes used
          {d.actionsIncluded && ` of ${d.actionsIncluded} included`}
          {typeof d.actionsPct === 'number' && ` (${d.actionsPct}%)`}
        </div>
      )}
    </div>
  );
}

// ── Vercel compact card + drawer ───────────────────────────────────────────
function VD2_Vercel({ t, d }) {
  const [expanded, setExpanded] = React.useState(false);
  const dark = t.ink === VD2_DARK.ink;
  const hasDetail = (d.hourBucketsReqs && d.hourBucketsReqs.length > 0)
                 || (d.topProjects && d.topProjects.length > 0);

  if (!d.headline || d.state === 'unconfigured') {
    return (
      <VD2_Compact t={t}>
        <Monogram letter="V" t={t} tone="free" />
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.muted, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="free">{d.pill}</Pill>
          </div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim, marginTop: 3 }}>
            {d.note || 'API key not configured'}
          </div>
        </div>
      </VD2_Compact>
    );
  }
  return (
    <div
      onClick={() => hasDetail && setExpanded(e => !e)}
      style={{
        background: t.compactBg,
        border: `1px solid ${dark ? 'rgba(237,230,214,0.06)' : 'rgba(60,45,30,0.04)'}`,
        borderRadius: 10, padding: '12px 14px', marginBottom: 8,
        cursor: hasDetail ? 'pointer' : 'default',
      }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <Monogram letter="V" t={t} tone="free" />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.ink, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
            {d.name}<Pill t={t} tone="free">{d.pill}</Pill>
          </div>
          <div style={{ fontFamily: TD_FONTS.mono, fontSize: 10.5, color: t.dim, marginTop: 3, whiteSpace: 'nowrap' }}>
            {d.note}
          </div>
        </div>
        <div style={{ flex: 1 }} />
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontFamily: TD_FONTS.mono, fontSize: 15, color: t.ink, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3, lineHeight: 1 }}>{d.headline}</div>
          <div style={{ fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim, marginTop: 4 }}>24h</div>
        </div>
      </div>

      {expanded && <VD2_VercelDrawer t={t} d={d} />}
    </div>
  );
}

function VD2_VercelDrawer({ t, d }) {
  const dark = t.ink === VD2_DARK.ink;
  const color = dark ? TD.dCoral : TD.coral;
  const buckets = d.hourBucketsReqs || [];
  const topProjects = d.topProjects || [];
  const fmtHour = (h) => {
    h = ((h % 24) + 24) % 24;
    if (h === 0) return '12 AM'; if (h === 12) return '12 PM';
    return h < 12 ? `${h} AM` : `${h - 12} PM`;
  };
  const hourBars = buckets.map((n) => ({ value: n, color }));
  const hourTooltip = (i) => {
    const n = buckets[i] || 0;
    return `${fmtHour(i)} · ${n} deploy${n === 1 ? '' : 's'}`;
  };

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      style={{ marginTop: 12, paddingTop: 10, borderTop: `1px solid ${t.hair}` }}>

      {/* Tile row */}
      <div style={{
        display: 'grid', gridTemplateColumns: '1fr 1fr 1fr',
        gap: 8, marginBottom: 10,
      }}>
        {[
          { k: 'Projects',    v: d.projectCount || '0' },
          { k: 'Deploys 24h', v: d.deployments24h || '0' },
          { k: 'Failed 24h',  v: d.failed24h || '0' },
        ].map((x, i) => (
          <div key={i} style={{
            background: t.compactBg, border: `1px solid ${t.hair}`,
            borderRadius: 6, padding: '6px 8px',
          }}>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic',
              fontSize: 9.5, color: t.dim, marginBottom: 2,
            }}>{x.k}</div>
            <div style={{
              fontFamily: TD_FONTS.mono, fontSize: 13, color: t.ink,
              fontVariantNumeric: 'tabular-nums',
            }}>{x.v}</div>
          </div>
        ))}
      </div>

      {/* 24-hour deploy pattern */}
      {buckets.length === 24 && (
        <div style={{ marginBottom: 12 }}>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
            marginBottom: 2,
          }}>Deploys by hour (last 24h)</div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 10, color: t.dim,
            marginBottom: 8,
          }}>hover a bar for exact count · spikes may signal a build loop</div>
          <HoverBarChart
            t={t}
            bars={hourBars}
            heightPx={38}
            gap={2}
            tooltipLabel={hourTooltip}
          />
        </div>
      )}

      {/* Top projects by deploy count */}
      {topProjects.length > 0 && (
        <div>
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11.5, color: t.ink,
            marginBottom: 6,
          }}>Most-deployed projects (24h)</div>
          {topProjects.map((p, i) => (
            <div key={i} style={{
              display: 'grid', gridTemplateColumns: '1fr auto',
              columnGap: 8, padding: '4px 0',
              borderBottom: i < topProjects.length - 1 ? `1px solid ${t.hair}` : 'none',
              fontSize: 11,
            }}>
              <span style={{
                color: t.ink, fontFamily: TD_FONTS.serif, fontStyle: 'italic',
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              }}>{p.name}</span>
              <span style={{
                fontFamily: TD_FONTS.mono, color: t.ink, fontWeight: 500,
                fontVariantNumeric: 'tabular-nums',
              }}>{p.count} deploy{p.count === 1 ? '' : 's'}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function VD2_CompactRouter({ t, p }) {
  switch (p.kind) {
    case 'eleven':   return <VD2_Eleven t={t} d={p} />;
    case 'router':   return <VD2_Router t={t} d={p} />;
    case 'groq':     return <VD2_Groq t={t} d={p} />;
    case 'moonshot': return <VD2_Moonshot t={t} d={p} />;
    case 'github':   return <VD2_GitHub t={t} d={p} />;
    case 'vercel':   return <VD2_Vercel t={t} d={p} />;
    default:         return <VD2_Groq t={t} d={p} />;
  }
}

// ─── API key row ─────────────────────────────────────────────────────────────

function KeyRow({ t, label, account, hasKey, hint, docsUrl, removable }) {
  const [val, setVal] = React.useState('');
  const [saved, setSaved] = React.useState(false);

  const save = () => {
    const trimmed = val.trim();
    if (!trimmed) return;
    postSwift('set-key:' + account + ':' + trimmed);
    setVal('');
    setSaved(true);
    setTimeout(() => setSaved(false), 1800);
  };

  const clear = () => {
    postSwift('clear-key:' + account);
    setVal('');
  };

  const remove = () => {
    // User-added extra: pull the provider entirely (drops key + card).
    postSwift('remove-provider:' + account);
  };

  return (
    <div style={{ marginTop: 10 }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8, marginBottom: 5,
      }}>
        <span style={{ fontFamily: TD_FONTS.sans, fontSize: 12, color: t.ink, flex: 1 }}>{label}</span>
        {hasKey && (
          <span style={{
            fontFamily: TD_FONTS.mono, fontSize: 9.5,
            color: t.green || '#6B8E5A',
            background: t.ink === VD2_DARK.ink ? 'rgba(143,168,124,0.15)' : '#E4EBDB',
            padding: '1px 7px', borderRadius: 8,
          }}>stored</span>
        )}
        {removable && (
          <button
            onClick={remove}
            title="Remove this provider entirely"
            style={{
              border: 'none', background: 'transparent',
              cursor: 'pointer', color: t.dim,
              fontFamily: TD_FONTS.sans, fontSize: 10.5,
              padding: '1px 6px', borderRadius: 4,
            }}
            onMouseEnter={(e) => e.currentTarget.style.color = t.red || '#B44A3A'}
            onMouseLeave={(e) => e.currentTarget.style.color = t.dim}>
            Remove
          </button>
        )}
      </div>
      <div style={{ display: 'flex', gap: 6 }}>
        <input
          type="password"
          value={val}
          onChange={e => setVal(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && save()}
          placeholder={hasKey ? '••••••  (paste to replace)' : (hint || 'Paste API key…')}
          style={{
            flex: 1, fontFamily: TD_FONTS.mono, fontSize: 11,
            padding: '7px 9px', borderRadius: 7,
            border: `1px solid ${t.border}`,
            background: t.ink === VD2_DARK.ink ? t.surfaceAlt : t.compactBg,
            color: t.ink, outline: 'none',
          }}
        />
        {val.trim() ? (
          <button onClick={save} style={{
            padding: '0 12px', borderRadius: 7,
            border: 'none', cursor: 'pointer',
            background: saved ? (t.ink === VD2_DARK.ink ? 'rgba(143,168,124,0.25)' : '#E4EBDB')
                               : t.coral,
            color: saved ? (t.green || '#6B8E5A') : '#fff',
            fontFamily: TD_FONTS.sans, fontSize: 12, fontWeight: 600,
            transition: 'background 200ms',
          }}>{saved ? '✓' : 'Save'}</button>
        ) : hasKey ? (
          <button onClick={clear} style={{
            padding: '0 10px', borderRadius: 7,
            border: `1px solid ${t.border}`, cursor: 'pointer',
            background: 'transparent', color: t.muted,
            fontFamily: TD_FONTS.sans, fontSize: 12,
          }}>Clear</button>
        ) : null}
      </div>
    </div>
  );
}

// ─── Provider picker modal ───────────────────────────────────────────────────
//
// Two-step flow: (1) pick a provider type from the list, (2) paste its API
// key, hit Enter / Add. Dismisses on escape, outside-click, or success.
function ProviderPicker({ t, options, onClose }) {
  const [selected, setSelected] = React.useState(null);
  const [key, setKey] = React.useState('');
  const inputRef = React.useRef(null);
  const dark = t.ink === VD2_DARK.ink;

  React.useEffect(() => {
    if (selected && inputRef.current) inputRef.current.focus();
  }, [selected]);

  React.useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  const submit = () => {
    const trimmed = key.trim();
    if (!selected || !trimmed) return;
    postSwift('add-provider:' + selected.type + ':' + trimmed);
    onClose();
  };

  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0,
        background: dark ? 'rgba(0,0,0,0.55)' : 'rgba(26,25,21,0.35)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 16, zIndex: 1000,
      }}>
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: '100%', maxWidth: 360,
          background: t.surface,
          border: `1px solid ${t.border}`,
          borderRadius: 12, padding: 16,
          boxShadow: '0 8px 40px rgba(0,0,0,0.25)',
        }}>

        {selected == null ? (
          // Step 1: pick a type
          <>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 14, color: t.ink,
              marginBottom: 2,
            }}>Add a provider</div>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim,
              marginBottom: 12,
            }}>Pick one to configure. Key stays local.</div>
            <div style={{ maxHeight: 300, overflowY: 'auto', margin: '0 -4px' }}>
              {options.map(p => (
                <button
                  key={p.type}
                  onClick={() => setSelected(p)}
                  style={{
                    display: 'block', width: '100%',
                    background: 'transparent', border: 'none',
                    textAlign: 'left',
                    padding: '8px 10px', marginBottom: 2,
                    borderRadius: 7,
                    cursor: 'pointer',
                    transition: 'background 120ms',
                  }}
                  onMouseEnter={(e) => e.currentTarget.style.background = t.compactBg}
                  onMouseLeave={(e) => e.currentTarget.style.background = 'transparent'}>
                  <div style={{
                    fontFamily: TD_FONTS.sans, fontSize: 12.5, fontWeight: 600, color: t.ink,
                  }}>{p.displayName}</div>
                  <div style={{
                    fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim,
                    marginTop: 1, lineHeight: 1.4,
                  }}>{p.description}</div>
                </button>
              ))}
            </div>
            <button
              onClick={onClose}
              style={{
                marginTop: 10, width: '100%',
                background: 'transparent', border: `1px solid ${t.border}`,
                borderRadius: 7, padding: '6px',
                cursor: 'pointer', color: t.muted,
                fontFamily: TD_FONTS.sans, fontSize: 12,
              }}>Cancel</button>
          </>
        ) : (
          // Step 2: paste API key
          <>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 14, color: t.ink,
              marginBottom: 2,
            }}>{selected.displayName}</div>
            <div style={{
              fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11, color: t.dim,
              marginBottom: 10, lineHeight: 1.4,
            }}>
              {selected.description}
              {selected.docsUrl && (
                <>
                  {' · '}
                  <a
                    href={selected.docsUrl}
                    onClick={(e) => { e.preventDefault(); postSwift('open-url:' + selected.docsUrl); }}
                    style={{ color: t.coral, textDecoration: 'none' }}
                  >Get a key →</a>
                </>
              )}
            </div>
            <input
              ref={inputRef}
              type="password"
              value={key}
              onChange={(e) => setKey(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') submit(); }}
              placeholder={selected.keyHint || 'Paste API key…'}
              style={{
                width: '100%', boxSizing: 'border-box',
                fontFamily: TD_FONTS.mono, fontSize: 11,
                padding: '8px 10px', borderRadius: 7,
                border: `1px solid ${t.border}`,
                background: dark ? t.surfaceAlt : t.compactBg,
                color: t.ink, outline: 'none',
              }}
            />
            <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
              <button
                onClick={() => setSelected(null)}
                style={{
                  flex: '0 0 auto', padding: '7px 12px',
                  borderRadius: 7, border: `1px solid ${t.border}`,
                  background: 'transparent', color: t.muted,
                  fontFamily: TD_FONTS.sans, fontSize: 12,
                  cursor: 'pointer',
                }}>Back</button>
              <button
                onClick={submit}
                disabled={!key.trim()}
                style={{
                  flex: 1, padding: '7px 12px',
                  borderRadius: 7, border: 'none',
                  background: key.trim() ? t.coral : t.compactBg,
                  color: key.trim() ? '#fff' : t.dim,
                  fontFamily: TD_FONTS.sans, fontSize: 12, fontWeight: 600,
                  cursor: key.trim() ? 'pointer' : 'default',
                }}>Add</button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// ─── Settings overlay ────────────────────────────────────────────────────────

function VD2_Settings({ t, theme, setTheme, onResetOrder, orderDirty }) {
  const dark = t.ink === VD2_DARK.ink;
  const themeOptions = [
    { id: 'light', label: 'Light' },
    { id: 'dark',  label: 'Dark'  },
    { id: 'auto',  label: 'Auto'  },
  ];
  const ks = (window.TD_DATA && window.TD_DATA.keyStatus) || {};
  const catalog = (window.TD_DATA && window.TD_DATA.providerCatalog) || [];
  const configuredExtras = (window.TD_DATA && window.TD_DATA.configuredExtras) || [];

  // Active = built-ins that need keys + any user-added extras (whether key
  // is stored yet or not). Built-ins without keys are always visible because
  // the user can configure them inline; extras only appear after being added
  // via the picker.
  const activeProviders = catalog.filter(p => {
    if (p.isBuiltIn && p.needsKey) return true;
    if (!p.isBuiltIn && configuredExtras.includes(p.type)) return true;
    return false;
  });
  const addableProviders = catalog.filter(p =>
    !p.isBuiltIn && !configuredExtras.includes(p.type)
  );

  const [pickerOpen, setPickerOpen] = React.useState(false);

  return (
    <div style={{ padding: '4px 2px 0' }}>
      <SectionCard t={t}>
        <SectionLabel t={t}>API Keys</SectionLabel>
        <div style={{
          marginTop: 6, fontFamily: TD_FONTS.sans, fontSize: 11, color: t.dim, lineHeight: 1.5,
        }}>Keys live in <code style={{ fontFamily: TD_FONTS.mono, fontSize: 10 }}>~/Library/Application Support/TokenDash/keys.plist</code> (0600, owner-only). Nothing leaves your Mac.</div>

        {activeProviders.map(p => (
          <KeyRow
            key={p.type}
            t={t}
            label={p.displayName}
            account={p.type}
            hasKey={!!ks[p.type]}
            hint={p.keyHint}
            docsUrl={p.docsUrl}
            removable={!p.isBuiltIn}
          />
        ))}

        {addableProviders.length > 0 && (
          <button
            onClick={() => setPickerOpen(true)}
            style={{
              width: '100%', marginTop: 12,
              background: 'transparent',
              border: `1px dashed ${t.border}`,
              borderRadius: 10, padding: '10px',
              color: t.muted, fontFamily: TD_FONTS.sans, fontSize: 12, fontWeight: 500,
              cursor: 'pointer', display: 'flex', alignItems: 'center',
              justifyContent: 'center', gap: 6,
              transition: 'all 120ms',
            }}
            onMouseEnter={(e) => { e.currentTarget.style.background = t.surfaceAlt; e.currentTarget.style.color = t.ink; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = 'transparent'; e.currentTarget.style.color = t.muted; }}>
            <svg width="11" height="11" viewBox="0 0 12 12" fill="none">
              <path d="M6 2v8M2 6h8" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round"/>
            </svg>
            <span>Add provider ({addableProviders.length} available)</span>
          </button>
        )}
      </SectionCard>

      {pickerOpen && (
        <ProviderPicker
          t={t}
          options={addableProviders}
          onClose={() => setPickerOpen(false)}
        />
      )}

      <SectionCard t={t}>
        <SectionLabel t={t}>Appearance</SectionLabel>
        <div style={{
          display: 'flex', gap: 0, marginTop: 8,
          background: dark ? t.surfaceAlt : t.compactBg,
          borderRadius: 8, padding: 3,
          border: `1px solid ${t.border}`,
        }}>
          {themeOptions.map(opt => (
            <button key={opt.id}
              onClick={() => setTheme(opt.id)}
              style={{
                flex: 1, border: 'none', cursor: 'pointer',
                padding: '7px 8px', borderRadius: 6,
                background: opt.id === theme ? t.surface : 'transparent',
                color: opt.id === theme ? t.ink : t.muted,
                fontFamily: TD_FONTS.sans, fontSize: 12,
                fontWeight: opt.id === theme ? 600 : 500,
                boxShadow: opt.id === theme
                  ? (dark ? '0 1px 2px rgba(0,0,0,0.5)' : '0 1px 2px rgba(60,45,30,0.08)')
                  : 'none',
                transition: 'all 140ms ease',
              }}>{opt.label}</button>
          ))}
        </div>
        <div style={{
          marginTop: 10, fontFamily: TD_FONTS.serif, fontStyle: 'italic',
          fontSize: 11, color: t.dim, lineHeight: 1.45,
        }}>
          Auto follows your macOS system appearance.
        </div>
      </SectionCard>

      <SectionCard t={t}>
        <SectionLabel t={t}>Card layout</SectionLabel>
        <div style={{
          marginTop: 8, fontFamily: TD_FONTS.sans,
          fontSize: 11.5, color: t.muted, lineHeight: 1.55,
        }}>
          Drag any card to reorder. The layout is saved to this machine.
        </div>
        <button
          onClick={onResetOrder}
          disabled={!orderDirty}
          style={{
            marginTop: 12, width: '100%',
            background: 'transparent',
            border: `1px solid ${t.border}`,
            color: orderDirty ? t.ink : t.dim,
            fontFamily: TD_FONTS.sans, fontSize: 11.5,
            padding: '8px 10px', borderRadius: 8,
            cursor: orderDirty ? 'pointer' : 'not-allowed',
            opacity: orderDirty ? 1 : 0.55,
          }}>
          {orderDirty ? 'Reset to default order' : 'Default order'}
        </button>
      </SectionCard>

      <SectionCard t={t}>
        <SectionLabel t={t}>About</SectionLabel>
        <div style={{
          marginTop: 8, fontFamily: TD_FONTS.sans,
          fontSize: 11.5, color: t.muted, lineHeight: 1.55,
        }}>
          TokenDash reads Claude Code and Codex CLI logs locally.
          Nothing leaves your machine.
        </div>
        <div style={{
          marginTop: 10, fontFamily: TD_FONTS.mono, fontSize: 10.5,
          color: t.dim, lineHeight: 1.55, wordBreak: 'break-all',
        }}>
          ~/.claude/projects/<br />
          ~/.codex/sessions/
        </div>
      </SectionCard>
    </div>
  );
}

function SectionCard({ children, t }) {
  return (
    <div style={{
      background: t.surface,
      border: `1px solid ${t.border}`,
      borderRadius: 12, padding: '14px 16px', marginBottom: 10,
      boxShadow: t.ink === VD2_DARK.ink ? 'none' : '0 1px 0 rgba(60,45,30,0.02)',
    }}>{children}</div>
  );
}

function SectionLabel({ children, t }) {
  return (
    <div style={{
      fontFamily: TD_FONTS.serif, fontStyle: 'italic',
      fontSize: 11, color: t.ink, letterSpacing: 0.1,
    }}>{children}</div>
  );
}

function LimitRow({ t, label, value }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
      gap: 8,
    }}>
      <span style={{ fontSize: 12, color: t.muted }}>{label}</span>
      <span style={{
        fontFamily: TD_FONTS.mono, fontSize: 14, color: t.ink,
        fontVariantNumeric: 'tabular-nums', letterSpacing: -0.2,
      }}>{value}</span>
    </div>
  );
}

// ─── Drag-and-drop reorder (with live push-out-of-way FLIP animation) ────────
//
// Module-level drag state: HTML5 DnD doesn't let us read dataTransfer during
// dragover (only during drop), so we stash the active drag here.
const _dragState = { group: null, id: null };

function useOrder(key, defaultOrder) {
  const [order, setOrder] = React.useState(() => {
    try {
      const s = window.localStorage.getItem(key);
      if (s) {
        const parsed = JSON.parse(s);
        if (Array.isArray(parsed)) return parsed;
      }
    } catch (e) {}
    return defaultOrder;
  });
  React.useEffect(() => {
    try { window.localStorage.setItem(key, JSON.stringify(order)); } catch (e) {}
  }, [order, key]);
  // Reconcile against current defaultOrder — add any new ids, drop missing ones,
  // preserving user's existing order for ids that still exist.
  const reconciled = React.useMemo(() => {
    const kept = order.filter(id => defaultOrder.includes(id));
    const added = defaultOrder.filter(id => !kept.includes(id));
    return [...kept, ...added];
  }, [order, defaultOrder.join('|')]);

  // Wrapper around setOrder that feeds the reconciled list (what the UI is
  // actually rendering) into the updater — NOT the raw state. Without this,
  // Draggable's reorder callback sees the stale localStorage-backed order
  // that doesn't include any providers added at runtime, so indexOf returns
  // -1 for every new provider and the whole reorder silently no-ops.
  //
  // This was the bug that made Moonshot/GitHub/Vercel "un-draggable": drag
  // events fired correctly, findTargetId found the right neighbour, setOrder
  // was called with a working updater — but the updater saw a list that
  // didn't contain the dragged id, so it returned unchanged.
  const setOrderReconciled = React.useCallback((updater) => {
    setOrder(curr => {
      const liveReconciled = [
        ...curr.filter(id => defaultOrder.includes(id)),
        ...defaultOrder.filter(id => !curr.includes(id)),
      ];
      return typeof updater === 'function' ? updater(liveReconciled) : updater;
    });
  }, [defaultOrder.join('|')]);

  const reset = React.useCallback(() => setOrder(defaultOrder.slice()), [defaultOrder.join('|')]);
  return [reconciled, setOrderReconciled, reset];
}

// FLIP animation: measure each draggable's rect before/after order changes,
// then play the inverse translate so the browser animates it back to 0.
// Sortable-style drag with live reordering. As the cursor passes over a
// sibling, that sibling animates out of the way via FLIP, without waiting
// for drop. Keys to making this stable (earlier attempts caused layout
// chaos):
//
//   • Grip-based transform: we remember the cursor's offset within the
//     card at drag start, then on each frame compute the card's natural
//     position (by temporarily clearing its transform) and set a new
//     transform that keeps the card anchored under the cursor. When a
//     reorder moves the card to a new DOM slot, the recompute puts the
//     transform in the right place automatically — no offset drift.
//
//   • FLIP skips the dragged card (activeRef.current gate). Siblings
//     FLIP normally, animating smoothly into their new slots.
//
//   • lastTargetRef throttles reorders to "only when the target changes",
//     preventing the cascade of state updates that broke layout before.
//
//   • After drop, we transition the dragged card's transform back to ''
//     so it settles into its final slot instead of snapping.
function Draggable({ id, group, order, setOrder, t, children }) {
  const ref = React.useRef(null);
  const prevRectRef = React.useRef(null);
  const [dragging, setDragging] = React.useState(false);

  // All drag state lives in refs so mid-drag re-renders don't clobber it.
  const startRef = React.useRef(null);       // cursor {x,y} at pointerdown (for activation threshold only)
  const gripRef = React.useRef({ x: 0, y: 0 }); // cursor - card top-left at drag activation
  const lastCursorRef = React.useRef(null);  // latest pointermove position, for re-anchor on re-render
  const activeRef = React.useRef(false);
  const lastTargetRef = React.useRef(null);  // most recent sibling we reordered past
  const justDraggedRef = React.useRef(false);

  // FLIP animation — only runs on cards that are NOT the one being dragged.
  // For the dragged card, re-anchor its transform to the last cursor
  // position so a mid-drag reorder doesn't leave it visually offset for a
  // frame before the next pointermove catches up.
  React.useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (activeRef.current && lastCursorRef.current) {
      el.style.transition = 'none';
      el.style.transform = '';
      const nat = el.getBoundingClientRect();
      const c = lastCursorRef.current;
      const tx = (c.x - gripRef.current.x) - nat.left;
      const ty = (c.y - gripRef.current.y) - nat.top;
      el.style.transform = `translate(${tx}px, ${ty}px)`;
      prevRectRef.current = el.getBoundingClientRect();
      return;
    }
    const prev = prevRectRef.current;
    const curr = el.getBoundingClientRect();
    if (prev && (prev.top !== curr.top || prev.left !== curr.left)) {
      const dx = prev.left - curr.left;
      const dy = prev.top - curr.top;
      el.style.transition = 'none';
      el.style.transform = `translate(${dx}px, ${dy}px)`;
      void el.offsetHeight;
      el.style.transition = 'transform 260ms cubic-bezier(0.2, 0.8, 0.2, 1)';
      el.style.transform = '';
    }
    prevRectRef.current = curr;
  });

  // Returns the id of the sibling card whose rect contains (x, y), or null.
  const findTargetId = (x, y) => {
    const all = document.querySelectorAll(`[data-drag-group="${group}"]`);
    for (const el of all) {
      if (el === ref.current) continue;
      const r = el.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        return el.getAttribute('data-drag-id');
      }
    }
    return null;
  };

  // Recompute the translate() for the dragged card so its top-left sits at
  // (cursor.x - grip.x, cursor.y - grip.y) regardless of where React has
  // just placed it in the DOM after a reorder.
  const anchorToCursor = (x, y) => {
    const el = ref.current;
    if (!el) return;
    // Clear transform so getBoundingClientRect returns the current *natural*
    // position of the card in its new DOM slot.
    el.style.transition = 'none';
    el.style.transform = '';
    const nat = el.getBoundingClientRect();
    const tx = (x - gripRef.current.x) - nat.left;
    const ty = (y - gripRef.current.y) - nat.top;
    el.style.transform = `translate(${tx}px, ${ty}px)`;
  };

  const onPointerDown = (e) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    if (e.target.closest('input, button, a, textarea, select')) return;
    startRef.current = { x: e.clientX, y: e.clientY };
    activeRef.current = false;
    lastTargetRef.current = null;
    try { ref.current.setPointerCapture(e.pointerId); } catch (err) {}
  };

  const onPointerMove = (e) => {
    const start = startRef.current;
    if (!start) return;
    const dx = e.clientX - start.x;
    const dy = e.clientY - start.y;

    // Activation: only start dragging once the pointer has moved enough to
    // clearly indicate intent — keeps single clicks from feeling "grabby".
    if (!activeRef.current) {
      if (Math.abs(dx) + Math.abs(dy) < 5) return;
      activeRef.current = true;
      setDragging(true);
      // Capture grip once: where inside the card the cursor grabbed.
      const el = ref.current;
      if (el) {
        const r = el.getBoundingClientRect();
        gripRef.current = { x: e.clientX - r.left, y: e.clientY - r.top };
        el.style.zIndex = '10';
        el.style.pointerEvents = 'none';   // hit-test passes through to siblings
      }
    }

    // Remember cursor pos so useLayoutEffect can re-anchor after re-renders.
    lastCursorRef.current = { x: e.clientX, y: e.clientY };
    // Keep the card under the cursor. Recomputing against current natural
    // position means reorders don't leave stale offsets behind.
    anchorToCursor(e.clientX, e.clientY);

    // Live reorder: as soon as the cursor enters a different sibling's rect,
    // move this card to that sibling's slot. Throttled via lastTargetRef so
    // we don't hammer setOrder every move frame.
    const targetId = findTargetId(e.clientX, e.clientY);
    if (targetId && targetId !== id && targetId !== lastTargetRef.current) {
      lastTargetRef.current = targetId;
      setOrder(ord => {
        const next = ord.slice();
        const from = next.indexOf(id);
        const to = next.indexOf(targetId);
        if (from < 0 || to < 0) return ord;
        next.splice(from, 1);
        next.splice(to, 0, id);
        return next;
      });
      // The React render hasn't happened yet. After it does, the useLayoutEffect
      // will FLIP the displaced sibling into position. On the next pointermove
      // we re-anchor this card, so no offset drift.
    }
  };

  const onPointerUp = (e) => {
    const wasActive = activeRef.current;
    const el = ref.current;
    startRef.current = null;

    if (!wasActive) {
      activeRef.current = false;
      if (el) el.style.pointerEvents = '';
      return;   // just a click — let it through
    }

    // Animate the card from its current cursor-anchored visual position
    // down to the natural top-left of its final DOM slot.
    if (el) {
      el.style.transition = 'transform 200ms cubic-bezier(0.2, 0.8, 0.2, 1)';
      el.style.transform = '';
      el.style.zIndex = '';
      el.style.pointerEvents = '';
      // Clear after the animation finishes so we don't leave a lingering
      // transition on the element.
      setTimeout(() => {
        if (el) el.style.transition = 'none';
      }, 220);
    }
    activeRef.current = false;
    setDragging(false);
    lastTargetRef.current = null;
    lastCursorRef.current = null;

    // Suppress the synthetic click that fires right after mouseup.
    justDraggedRef.current = true;
    setTimeout(() => { justDraggedRef.current = false; }, 0);
    e.stopPropagation();
  };

  const onPointerCancel = () => {
    const el = ref.current;
    startRef.current = null;
    activeRef.current = false;
    setDragging(false);
    lastTargetRef.current = null;
    lastCursorRef.current = null;
    if (el) {
      el.style.transition = 'transform 180ms cubic-bezier(0.2, 0.8, 0.2, 1)';
      el.style.transform = '';
      el.style.zIndex = '';
      el.style.pointerEvents = '';
    }
  };

  return (
    <div
      ref={ref}
      data-drag-id={id}
      data-drag-group={group}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerCancel}
      onClickCapture={(e) => {
        // If a drag just ended, stop the click from toggling the drawer.
        if (justDraggedRef.current) { e.stopPropagation(); e.preventDefault(); }
      }}
      style={{
        position: 'relative',
        opacity: dragging ? 0.85 : 1,
        borderRadius: 14,
        cursor: dragging ? 'grabbing' : 'grab',
        userSelect: 'none',
        WebkitUserSelect: 'none',
        touchAction: 'none',
        boxShadow: dragging ? '0 8px 22px rgba(0,0,0,0.18)' : 'none',
      }}>
      {children}
    </div>
  );
}

// ─── Root ────────────────────────────────────────────────────────────────────

function VD2_App() {
  const [route, setRoute] = React.useState('dashboard');
  const [expanded, setExpanded] = React.useState({ claude: false, codex: false });
  const toggle = (k) => setExpanded(s => ({ ...s, [k]: !s[k] }));

  // Theme: 'light' | 'dark' | 'auto'
  const [theme, setThemeState] = React.useState(() => {
    try { return window.localStorage.getItem('td.theme') || 'auto'; }
    catch (e) { return 'auto'; }
  });
  const setTheme = (v) => {
    setThemeState(v);
    try { window.localStorage.setItem('td.theme', v); } catch (e) {}
  };
  const [systemDark, setSystemDark] = React.useState(() =>
    window.matchMedia('(prefers-color-scheme: dark)').matches);
  React.useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const h = (e) => setSystemDark(e.matches);
    mq.addEventListener('change', h);
    return () => mq.removeEventListener('change', h);
  }, []);
  const dark = theme === 'dark' || (theme === 'auto' && systemDark);

  const [, force] = React.useReducer(x => x + 1, 0);
  React.useEffect(() => { window.__render = force; }, []);
  React.useEffect(() => { window.__setRoute = setRoute; return () => { window.__setRoute = null; }; }, []);

  const t = dark ? VD2_DARK : VD2_LIGHT;
  const providers = (window.TD_DATA && window.TD_DATA.providers) || MOCK_DATA.providers;

  const defaultHeroOrder = ['claude', 'codex'];
  const [heroOrder, setHeroOrder, resetHero] = useOrder('td.heroOrder', defaultHeroOrder);
  const providerIds = providers.map(p => p.id);
  const [providerOrder, setProviderOrder, resetProviders] = useOrder('td.providerOrder', providerIds);
  const orderDirty =
    heroOrder.join(',') !== defaultHeroOrder.join(',') ||
    providerOrder.join(',') !== providerIds.join(',');
  const resetOrder = () => { resetHero(); resetProviders(); };
  const providersById = {};
  providers.forEach(p => { providersById[p.id] = p; });

  const renderHero = (id) => {
    if (id === 'claude') {
      return <VD2_ClaudeHero t={t} expanded={expanded.claude} onToggle={() => toggle('claude')} />;
    }
    if (id === 'codex') {
      return <VD2_CodexHero t={t} expanded={expanded.codex} onToggle={() => toggle('codex')} />;
    }
    return null;
  };

  return (
    <VD2_Shell
      dark={dark}
      route={route}
      onSettings={() => setRoute('settings')}
      onBack={() => setRoute('dashboard')}>
      {route === 'settings' ? (
        <VD2_Settings
          t={t}
          theme={theme}
          setTheme={setTheme}
          onResetOrder={resetOrder}
          orderDirty={orderDirty} />
      ) : (
        <>
          {heroOrder.map(id => (
            <Draggable key={id} id={id} group="hero" order={heroOrder} setOrder={setHeroOrder} t={t}>
              {renderHero(id)}
            </Draggable>
          ))}
          <div style={{
            fontFamily: TD_FONTS.serif, fontStyle: 'italic', fontSize: 11,
            color: t.dim, letterSpacing: 0.2,
            padding: '2px 4px 8px', display: 'flex', alignItems: 'center', gap: 8,
          }}>
            <span>Other providers</span>
            <span style={{ flex: 1, height: 1, background: t.hair }} />
          </div>
          {providerOrder.map(id => {
            const p = providersById[id];
            if (!p) return null;
            return (
              <Draggable key={id} id={id} group="provider" order={providerOrder} setOrder={setProviderOrder} t={t}>
                <VD2_CompactRouter t={t} p={p} />
              </Draggable>
            );
          })}
        </>
      )}
    </VD2_Shell>
  );
}

// Bootstrap
window.__render = () => {};
window.__update = function (json) {
  try { window.TD_DATA = JSON.parse(json); } catch (e) { console.error(e); }
  if (window.__render) window.__render();
};

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<VD2_App />);
