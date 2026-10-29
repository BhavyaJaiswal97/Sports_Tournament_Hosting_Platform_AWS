#!/usr/bin/env bash
set -euo pipefail
REGION="ap-southeast-2"; FN="TournamentApi"
ROOT="$(pwd)"; APP="$ROOT/src/App.tsx"
[ -f "$APP" ] || { echo "Run this from the project root (src/App.tsx not found)"; exit 1; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# ═════════ 1. Frontend: add the CloudWatch panel to the AWS Demo tab ═════════
echo "== 1/4 Patching App.tsx =="
cp "$APP" "$APP.bak2"
python3 - "$APP" << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# (a) browser telemetry helper, only if missing (feeds the "Browser events" counter)
if 'const track = (' not in s:
    pick_line = "const pick = (r: any, key: string) => (Array.isArray(r) ? r : Array.isArray(r?.[key]) ? r[key] : null);"
    pairs = [
      (pick_line, pick_line + r'''
const SESSION = Math.random().toString(36).slice(2, 10);
const track = (event: string, data: Record<string, unknown> = {}) => {
  if (!API) return;
  try {
    fetch(API + '/telemetry', {
      method: 'POST', keepalive: true,
      headers: { 'Content-Type': 'application/json', ...(API_KEY ? { 'x-api-key': API_KEY } : {}) },
      body: JSON.stringify({ event, data, session: SESSION, ts: Date.now() }),
    }).catch(() => {});
  } catch { /* never break the app for telemetry */ }
};'''),
      ("say('Request failed: ' + (e as Error).message);",
       "if (API && url.startsWith(API)) track('client_error', { method, url, message: (e as Error).message });\n    say('Request failed: ' + (e as Error).message);"),
      ("}, [teams, matches, votes, picks]);",
       r'''}, [teams, matches, votes, picks]);
  useEffect(() => { track('page_view', { tab }); }, [tab]);
  useEffect(() => {
    const h = (e: ErrorEvent) => track('js_error', { message: e.message, source: e.filename, line: e.lineno });
    window.addEventListener('error', h);
    return () => window.removeEventListener('error', h);
  }, []);'''),
      ("const sendTest = () => {", "const sendTest = () => {\n    track('demo_test_update');"),
    ]
    if all(a in s for a, _ in pairs):
        for a, b in pairs: s = s.replace(a, b, 1)
        print('telemetry patch applied')
    else:
        print('WARNING: telemetry anchors not found, skipped (panel still works)')

# (b) the CloudWatch panel
if 'CLOUDWATCH_PANEL' in s:
    print('panel already installed')
else:
    A = "export default function App() {"
    B = '<h2 className="sec">AWS Services</h2>'
    if A not in s or B not in s: sys.exit('ANCHOR NOT FOUND for panel')
    PANEL = r'''/* CLOUDWATCH_PANEL */
interface CwData { alarm: string; window: number; requests: number; gets: number; puts: number; posts: number; errors: number; avgMs: number; scoreWrites: number; finals: number; clientEvents: number; aiLines: number; aiFailures: number; lastAi: string; recent: { t: string; text: string }[]; }
const CW_DASH = `${base}/cloudwatch/home?region=${REGION}#dashboards/dashboard/ICPL`;
const CW_ALARM = `${base}/cloudwatch/home?region=${REGION}#alarmsV2:alarm/ICPL-Errors`;
const CW_LOGS = `${base}/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/$252Faws$252Flambda$252F${LAMBDA}`;
const CwPanel = () => {
  const [d, setD] = useState<CwData | null>(null);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [on, setOn] = useState(true);
  const hdr = { 'Content-Type': 'application/json', ...(API_KEY ? { 'x-api-key': API_KEY } : {}) };
  const refresh = async () => {
    if (!API) return;
    try {
      const r = await fetch(API + '/cw/summary', { headers: hdr });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      setD(await r.json()); setErr('');
    } catch (e) { setErr((e as Error).message); }
  };
  useEffect(() => {
    if (!API || !on) return;
    refresh();
    const t = setInterval(refresh, 5000);
    return () => clearInterval(t);
    // eslint-disable-next-line
  }, [on]);
  const fire = async () => {
    setBusy(true); setMsg('');
    try {
      const r = await fetch(API + '/cw/alarm-test', { method: 'POST', headers: hdr, body: '{}' });
      const j = await r.json().catch(() => ({ message: 'HTTP ' + r.status }));
      setMsg(j.message || 'Done');
      setTimeout(refresh, 1500);
    } catch (e) { setMsg('Request failed: ' + (e as Error).message); }
    setBusy(false);
  };
  const col = d?.alarm === 'ALARM' ? 'var(--accent)' : d?.alarm === 'OK' ? 'var(--live)' : 'var(--mute)';
  const v = (n: number | undefined) => (d && n !== undefined ? n : '-');
  return (
    <div style={{ marginBottom: 40 }}>
      <h2 className="sec">CloudWatch Live Monitor</h2>
      <div className="card" style={{ marginBottom: 16, display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <div style={{ fontSize: 11, letterSpacing: '.1em', color: 'var(--mute)' }}>ALARM ICPL-ERRORS / EMAILS VIA SNS</div>
          <div style={{ fontSize: 22, fontWeight: 700, color: col }}>{d?.alarm || '-'}</div>
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <button className="btn pri" disabled={busy || !API} onClick={fire}>Send test alarm email</button>
          <button className="btn" onClick={() => setOn(!on)}>{on ? 'Pause' : 'Resume'}</button>
          <Ext href={CW_DASH}>Dashboard</Ext>
          <Ext href={CW_ALARM}>Alarm</Ext>
          <Ext href={CW_LOGS}>Live logs</Ext>
        </div>
      </div>
      {!API && <p style={{ color: 'var(--mute)' }}>Backend not configured (VITE_API_BASE missing).</p>}
      {msg && <div style={{ marginBottom: 12, fontSize: 13 }}>{msg}</div>}
      {err && <div className="neg" style={{ marginBottom: 12, fontSize: 13 }}>Could not read CloudWatch summary: {err}</div>}
      <div className="kpi" style={{ marginBottom: 16 }}>
        <div><small>REQUESTS (5 MIN)</small><b>{v(d?.requests)}</b></div>
        <div><small>SCORE WRITES</small><b>{v(d?.scoreWrites)}</b></div>
        <div><small>ERRORS</small><b className={d && d.errors > 0 ? 'neg' : ''}>{v(d?.errors)}</b></div>
        <div><small>AVG LATENCY</small><b>{d ? d.avgMs + ' ms' : '-'}</b></div>
      </div>
      <div className="kpi" style={{ marginBottom: 16 }}>
        <div><small>BROWSER EVENTS</small><b>{v(d?.clientEvents)}</b></div>
        <div><small>AI COMMENTARY LINES</small><b>{v(d?.aiLines)}</b></div>
        <div><small>AI FAILURES</small><b>{v(d?.aiFailures)}</b></div>
        <div><small>MATCHES FINALIZED</small><b>{v(d?.finals)}</b></div>
      </div>
      {d?.lastAi && <div className="kv"><span>Latest AI commentary</span><b style={{ textAlign: 'right' }}>{d.lastAi}</b></div>}
      <h3 className="side" style={{ marginTop: 20 }}>Recent backend activity (from CloudWatch Logs)</h3>
      <div className="con" style={{ height: 190 }}>
        {d?.recent?.length ? d.recent.map((r, i) => <div key={i}>{r.t}  {r.text}</div>) : <div>No activity in the last 5 minutes.</div>}
      </div>
    </div>
  );
};

'''
    s = s.replace(A, PANEL + A, 1)
    s = s.replace(B, '<CwPanel />\n            ' + B, 1)
    print('panel installed')
open(p, 'w', encoding='utf-8').write(s)
PYEOF

# ═════════ 2. Lambda: add /cw/summary and /cw/alarm-test ═════════
echo "== 2/4 Lambda code =="
W=$(mktemp -d); cd "$W"
curl -s -o cur.zip "$(aws lambda get-function --region "$REGION" --function-name "$FN" --query Code.Location --output text)"
cp cur.zip "$HOME/TournamentApi-backup-v3.zip"
mkdir code && unzip -q cur.zip -d code && cd code
grep -q "CLOUDWATCH_WRAPPER" index.mjs || { echo "index.mjs wrapper not found. Run icpl-upgrade.sh first."; exit 1; }

cat << 'MJS' > cwdemo.mjs
// Read-only CloudWatch summary + test alarm trigger for the demo panel
let cw = null, logs = null, sdkCw = null, sdkLogs = null, lastFire = 0;
const H = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' };
const ok = (o, c = 200) => ({ statusCode: c, headers: H, body: JSON.stringify(o) });
const LOG_GROUP = '/aws/lambda/' + process.env.AWS_LAMBDA_FUNCTION_NAME;
const ALARM = 'ICPL-Errors';

async function clients() {
  if (cw) return;
  sdkCw = await import('@aws-sdk/client-cloudwatch');
  sdkLogs = await import('@aws-sdk/client-cloudwatch-logs');
  cw = new sdkCw.CloudWatchClient({ region: process.env.AWS_REGION });
  logs = new sdkLogs.CloudWatchLogsClient({ region: process.env.AWS_REGION });
}

async function summary() {
  try {
    await clients();
    const WINDOW = 5;
    const start = Date.now() - WINDOW * 60000;
    const out = { window: WINDOW, alarm: 'UNKNOWN', requests: 0, gets: 0, puts: 0, posts: 0, errors: 0, avgMs: 0,
      scoreWrites: 0, finals: 0, clientEvents: 0, aiLines: 0, aiFailures: 0, lastAi: '', recent: [] };
    try {
      const a = await cw.send(new sdkCw.DescribeAlarmsCommand({ AlarmNames: [ALARM] }));
      out.alarm = a.MetricAlarms?.[0]?.StateValue || 'NOT_FOUND';
    } catch { /* keep UNKNOWN */ }

    const events = []; let token, pages = 0;
    do {
      const r = await logs.send(new sdkLogs.FilterLogEventsCommand({ logGroupName: LOG_GROUP, startTime: start, nextToken: token, limit: 1000 }));
      events.push(...(r.events || [])); token = r.nextToken; pages++;
    } while (token && pages < 4);

    let msSum = 0; const recent = [];
    for (const e of events) {
      const i = (e.message || '').indexOf('{'); if (i < 0) continue;
      let o; try { o = JSON.parse(e.message.slice(i)); } catch { continue; }
      const t = new Date(e.timestamp).toLocaleTimeString('en-GB', { timeZone: 'Asia/Kolkata' });
      if (o.message === 'request') {
        out.requests++; msSum += Number(o.ms) || 0;
        if (o.method === 'GET') out.gets++; else if (o.method === 'PUT') out.puts++; else if (o.method === 'POST') out.posts++;
        if (o.status >= 500) out.errors++;
        if (o.method === 'PUT' && String(o.path).includes('/matches/') && o.status < 300) out.scoreWrites++;
        if (String(o.path).endsWith('/finalize') && o.status < 300) out.finals++;
        recent.push({ t, text: `${o.method} ${o.path} ${o.status} ${o.ms}ms` });
      } else if (o.message === 'unhandled') { out.errors++; recent.push({ t, text: `ERROR ${o.method} ${o.path} ${String(o.error).slice(0, 80)}` }); }
      else if (o.message === 'client_event') { out.clientEvents++; recent.push({ t, text: `browser: ${o.event}` }); }
      else if (o.message === 'ai_commentary') { out.aiLines++; out.lastAi = o.line; recent.push({ t, text: 'AI commentary generated' }); }
      else if (o.message === 'ai_commentary_failed') { out.aiFailures++; recent.push({ t, text: 'AI commentary failed (see logs)' }); }
    }
    out.avgMs = out.requests ? Math.round(msSum / out.requests) : 0;
    out.recent = recent.slice(-12).reverse();
    return ok(out);
  } catch (e) { return ok({ error: String(e).slice(0, 200) }, 500); }
}

async function fire() {
  const wait = 60000 - (Date.now() - lastFire);
  if (wait > 0) return ok({ ok: false, message: `Please wait ${Math.ceil(wait / 1000)}s before sending another test alarm.` }, 429);
  try {
    await clients(); lastFire = Date.now();
    await cw.send(new sdkCw.SetAlarmStateCommand({ AlarmName: ALARM, StateValue: 'ALARM', StateReason: 'Demo test triggered from the website' }));
    return ok({ ok: true, message: 'Test alarm sent. Check the subscribed inboxes in about a minute.' });
  } catch (e) { return ok({ ok: false, message: String(e).slice(0, 200) }, 500); }
}

export async function demoRoute(method, path) {
  const mine = path.endsWith('/cw/summary') || path.endsWith('/cw/alarm-test') || path.endsWith('/telemetry');
  if (method === 'OPTIONS' && mine)
    return { statusCode: 204, headers: { ...H, 'Access-Control-Allow-Headers': 'Content-Type,x-api-key', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS' }, body: '' };
  if (method === 'GET' && path.endsWith('/cw/summary')) return summary();
  if (method === 'POST' && path.endsWith('/cw/alarm-test')) return fire();
  return null;
}
MJS

python3 - << 'PYEOF'
w = open('index.mjs', encoding='utf-8').read()
if 'CW_DEMO' in w:
    print('index.mjs already patched')
else:
    imp = "import { handler as apiHandler } from './api.mjs';"
    anc = "const path = event.rawPath || event.path || '';"
    ai = "metric('AiCommentary');"
    for a in (imp, anc, ai):
        if a not in w: raise SystemExit('ANCHOR NOT FOUND in index.mjs: ' + a)
    w = w.replace(imp, imp + "\nimport { demoRoute } from './cwdemo.mjs'; // CW_DEMO", 1)
    w = w.replace(anc, anc + "\n  const demo = await demoRoute(method, path); // CW_DEMO\n  if (demo) return demo;", 1)
    w = w.replace(ai, ai + "\n    log('info', 'ai_commentary', { line: text, match: m.id });", 1)
    open('index.mjs', 'w', encoding='utf-8').write(w)
    print('index.mjs patched')
PYEOF

zip -qr ../new.zip .
aws lambda update-function-code --region "$REGION" --function-name "$FN" --zip-file fileb://../new.zip --query LastModified --output text
aws lambda wait function-updated --region "$REGION" --function-name "$FN"

# ═════════ 3. IAM (least privilege for the panel) ═════════
echo "== 3/4 IAM =="
ROLE=$(aws lambda get-function-configuration --region "$REGION" --function-name "$FN" --query Role --output text | awk -F/ '{print $NF}')
cat << POL > /tmp/icpl-cw-demo.json
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"logs:FilterLogEvents","Resource":"arn:aws:logs:$REGION:$ACCOUNT:log-group:/aws/lambda/$FN:*"},
 {"Effect":"Allow","Action":"cloudwatch:SetAlarmState","Resource":"arn:aws:cloudwatch:$REGION:$ACCOUNT:alarm:ICPL-Errors"},
 {"Effect":"Allow","Action":"cloudwatch:DescribeAlarms","Resource":"*"}
]}
POL
aws iam put-role-policy --role-name "$ROLE" --policy-name icpl-cw-demo --policy-document file:///tmp/icpl-cw-demo.json

# ═════════ 4. API Gateway routes ═════════
echo "== 4/4 API routes =="
API_ID=""; INTEG=""
for ID in $(aws apigatewayv2 get-apis --region "$REGION" --query 'Items[].ApiId' --output text 2>/dev/null); do
  HIT=$(aws apigatewayv2 get-integrations --region "$REGION" --api-id "$ID" \
        --query "Items[?contains(IntegrationUri,'$FN')].IntegrationId" --output text 2>/dev/null || true)
  if [ -n "$HIT" ]; then API_ID="$ID"; INTEG=$(echo $HIT | awk '{print $1}'); break; fi
done
if [ -z "$API_ID" ]; then
  echo "No HTTP API found for $FN. Add these routes by hand to the $FN integration:"
  echo "  GET /cw/summary   POST /cw/alarm-test   POST /telemetry   (+ OPTIONS for each)"
else
  EXISTING=$(aws apigatewayv2 get-routes --region "$REGION" --api-id "$API_ID" --query 'Items[].RouteKey' --output text)
  for KEY in "GET /cw/summary" "POST /cw/alarm-test" "POST /telemetry" "OPTIONS /cw/summary" "OPTIONS /cw/alarm-test" "OPTIONS /telemetry"; do
    if echo "$EXISTING" | grep -qF -- "$KEY"; then echo "route exists: $KEY"; else
      aws apigatewayv2 create-route --region "$REGION" --api-id "$API_ID" --route-key "$KEY" --target "integrations/$INTEG" >/dev/null && echo "route created: $KEY"
    fi
  done
  aws lambda add-permission --region "$REGION" --function-name "$FN" --statement-id icpl-apigw-all \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*/*/*" >/dev/null 2>&1 || true
  AUTO=$(aws apigatewayv2 get-stage --region "$REGION" --api-id "$API_ID" --stage-name prod --query AutoDeploy --output text 2>/dev/null || echo True)
  [ "$AUTO" = "True" ] || aws apigatewayv2 create-deployment --region "$REGION" --api-id "$API_ID" --stage-name prod >/dev/null
fi

echo
echo "DONE. Run 'npm run dev', open the AWS Demo tab, and look for 'CloudWatch Live Monitor'."
