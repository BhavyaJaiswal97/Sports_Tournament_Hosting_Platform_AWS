#!/usr/bin/env bash
set -euo pipefail

# ───── EDIT THESE ─────
REGION="ap-southeast-2"
FN="TournamentApi"
LAMBDA_DIR="./lambda"          # folder containing your Lambda code (index.js)
APP="src/App.tsx"
# ──────────────────────

echo "== 1/4 Patching $APP =="
cp "$APP" "$APP.bak"
python3 - "$APP" << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'const track = (' in s:
    print('already patched, skipping'); sys.exit(0)

def rep(old, new, label):
    global s
    if old not in s:
        sys.exit(f'ANCHOR NOT FOUND: {label}')
    s = s.replace(old, new, 1)

# a) track() helper after `pick`
pick_line = "const pick = (r: any, key: string) => (Array.isArray(r) ? r : Array.isArray(r?.[key]) ? r[key] : null);"
rep(pick_line, pick_line + """
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
};""", 'pick')

# b) report failed API calls
rep("say('Request failed: ' + (e as Error).message);",
    "if (API && url.startsWith(API)) track('client_error', { method, url, message: (e as Error).message });\n    say('Request failed: ' + (e as Error).message);",
    'ajax catch')

# c) page views + JS errors
rep("}, [teams, matches, votes, picks]);",
    """}, [teams, matches, votes, picks]);
  useEffect(() => { track('page_view', { tab }); }, [tab]);
  useEffect(() => {
    const h = (e: ErrorEvent) => track('js_error', { message: e.message, source: e.filename, line: e.lineno });
    window.addEventListener('error', h);
    return () => window.removeEventListener('error', h);
  }, []);""", 'localStorage effect')

# d) demo button
rep("const sendTest = () => {", "const sendTest = () => {\n    track('demo_test_update');", 'sendTest')

open(p, 'w', encoding='utf-8').write(s)
print('patched OK (backup: ' + p + '.bak)')
PYEOF

echo "== 2/4 Writing Lambda files =="
mkdir -p "$LAMBDA_DIR"
cat << 'CWEOF' > "$LAMBDA_DIR/cw.js"
// Structured logs + CloudWatch custom metrics via Embedded Metric Format
const NS = 'ICPL';
exports.log = (level, message, fields = {}) =>
  console.log(JSON.stringify({ level, message, ...fields }));

exports.metric = (name, value = 1, unit = 'Count', dims = {}) => {
  console.log(JSON.stringify({
    _aws: {
      Timestamp: Date.now(),
      CloudWatchMetrics: [{ Namespace: NS, Dimensions: [Object.keys(dims)], Metrics: [{ Name: name, Unit: unit }] }],
    },
    ...dims,
    [name]: value,
  }));
};
CWEOF

# Move the existing handler to api.js (only once), then create the wrapper as index.js
if [ -f "$LAMBDA_DIR/index.js" ] && [ ! -f "$LAMBDA_DIR/api.js" ] && ! grep -q "CLOUDWATCH_WRAPPER" "$LAMBDA_DIR/index.js"; then
  mv "$LAMBDA_DIR/index.js" "$LAMBDA_DIR/api.js"
  echo "moved your original handler to api.js"
fi
[ -f "$LAMBDA_DIR/api.js" ] || { echo "ERROR: $LAMBDA_DIR/api.js not found. Put your original handler file there (exports.handler)."; exit 1; }

cat << 'WRAPEOF' > "$LAMBDA_DIR/index.js"
// CLOUDWATCH_WRAPPER
const { log, metric } = require('./cw');
const { handler: apiHandler } = require('./api');
const CORS = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' };

exports.handler = async (event, context) => {
  const start = Date.now();
  const method = event.httpMethod || event.requestContext?.http?.method || 'UNKNOWN';
  const path = event.rawPath || event.path || '';

  if (method === 'POST' && path.endsWith('/telemetry')) {
    let b = {};
    try { b = JSON.parse(event.body || '{}'); } catch {}
    const ev = String(b.event || 'unknown').slice(0, 40);
    log(ev === 'client_error' || ev === 'js_error' ? 'error' : 'info', 'client_event',
      { event: ev, data: b.data, session: b.session, requestId: context.awsRequestId });
    metric('ClientEvent', 1, 'Count', { Event: ev });
    return { statusCode: 200, headers: CORS, body: '{}' };
  }

  try {
    const res = await apiHandler(event, context);
    const ms = Date.now() - start, status = res?.statusCode ?? 200;
    log(status >= 500 ? 'error' : 'info', 'request', { method, path, status, ms, requestId: context.awsRequestId });
    metric('Requests', 1, 'Count', { Method: method });
    metric('Latency', ms, 'Milliseconds', { Method: method });
    if (status >= 500) metric('Errors');
    if (status < 300 && method === 'PUT' && path.includes('/matches/')) metric('ScoreWrite');
    if (status < 300 && path.endsWith('/finalize')) metric('MatchFinalized');
    return res;
  } catch (e) {
    log('error', 'unhandled', { method, path, error: String(e), stack: e?.stack, requestId: context.awsRequestId });
    metric('Errors');
    throw e;
  }
};
WRAPEOF

echo "== 3/4 Deploying Lambda =="
( cd "$LAMBDA_DIR" && rm -f ../lambda.zip && zip -qr ../lambda.zip . -x "*.zip" )
aws lambda update-function-code --region "$REGION" --function-name "$FN" \
  --zip-file "fileb://$(dirname "$LAMBDA_DIR")/lambda.zip" --query LastModified --output text
aws lambda wait function-updated --region "$REGION" --function-name "$FN"

echo "== 4/4 CloudWatch setup =="
ROLE_NAME=$(aws lambda get-function-configuration --region "$REGION" --function-name "$FN" --query Role --output text | awk -F/ '{print $NF}')
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws logs put-retention-policy --region "$REGION" --log-group-name "/aws/lambda/$FN" --retention-in-days 14 \
  || echo "(log group appears after the first invoke; re-run this script after one request)"

aws cloudwatch put-metric-alarm --region "$REGION" --alarm-name ICPL-Errors \
  --namespace ICPL --metric-name Errors --statistic Sum --period 60 \
  --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching

cat << DASHEOF > /tmp/icpl-dashboard.json
{"widgets":[
 {"type":"metric","x":0,"y":0,"width":12,"height":6,"properties":{"region":"$REGION","title":"Score writes & finals","stat":"Sum","period":60,"metrics":[["ICPL","ScoreWrite"],["ICPL","MatchFinalized"],["ICPL","Errors"]]}},
 {"type":"metric","x":12,"y":0,"width":12,"height":6,"properties":{"region":"$REGION","title":"API latency (ms)","stat":"Average","period":60,"metrics":[["ICPL","Latency","Method","PUT"],["ICPL","Latency","Method","GET"]]}},
 {"type":"log","x":0,"y":6,"width":24,"height":6,"properties":{"region":"$REGION","title":"Recent requests","query":"SOURCE '/aws/lambda/$FN' | fields @timestamp, method, path, status, ms | filter message='request' | sort @timestamp desc | limit 20"}}
]}
DASHEOF
aws cloudwatch put-dashboard --region "$REGION" --dashboard-name ICPL --dashboard-body file:///tmp/icpl-dashboard.json

echo
echo "DONE. Now: restart 'npm run dev', open AWS Demo tab, click 'Send test update',"
echo "then open CloudWatch > Logs > /aws/lambda/$FN > Start Live Tail."
