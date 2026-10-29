#!/usr/bin/env bash
set -euo pipefail
REGION="ap-southeast-2"; FN="TournamentApi"

W=$(mktemp -d); cd "$W"
HANDLER=$(aws lambda get-function-configuration --region "$REGION" --function-name "$FN" --query Handler --output text)
BASE="${HANDLER%.*}"; EXP="${HANDLER##*.}"
[ "$EXP" = "handler" ] || { echo "Handler export is '$EXP', expected 'handler'. Tell me and I'll adjust."; exit 1; }

echo "== Downloading current code =="
URL=$(aws lambda get-function --region "$REGION" --function-name "$FN" --query Code.Location --output text)
curl -s -o orig.zip "$URL"
cp orig.zip "$HOME/TournamentApi-backup.zip"
mkdir code && unzip -q orig.zip -d code && cd code

FILE=$(ls | grep -E "^${BASE}\.(mjs|js|cjs)$" | head -1 || true)
[ -n "$FILE" ] || { echo "Could not find $BASE.(mjs|js|cjs). Files: $(ls)"; exit 1; }
EXT="${FILE##*.}"
ESM=0
[ "$EXT" = "mjs" ] && ESM=1
[ "$EXT" = "js" ] && [ -f package.json ] && grep -q '"type": *"module"' package.json && ESM=1
echo "Detected: $FILE  (ESM=$ESM)"

if grep -q CLOUDWATCH_WRAPPER "$FILE"; then
  echo "Wrapper already installed, skipping code change."
else
  mv "$FILE" "api.$EXT"
  {
    echo "// CLOUDWATCH_WRAPPER"
    if [ "$ESM" = 1 ]; then echo "import { handler as apiHandler } from './api.$EXT';"
    else echo "const { handler: apiHandler } = require('./api.$EXT');"; fi
    cat << 'BODY'
const NS = 'ICPL';
const log = (level, message, fields = {}) => console.log(JSON.stringify({ level, message, ...fields }));
const metric = (name, value = 1, unit = 'Count', dims = {}) => console.log(JSON.stringify({
  _aws: { Timestamp: Date.now(), CloudWatchMetrics: [{ Namespace: NS, Dimensions: [Object.keys(dims)], Metrics: [{ Name: name, Unit: unit }] }] },
  ...dims, [name]: value,
}));
const CORS = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' };

const wrapped = async (event, context) => {
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
BODY
    if [ "$ESM" = 1 ]; then echo "export const handler = wrapped;"; else echo "exports.handler = wrapped;"; fi
  } > "$FILE"
fi

echo "== Deploying =="
zip -qr ../new.zip .
aws lambda update-function-code --region "$REGION" --function-name "$FN" --zip-file fileb://../new.zip --query LastModified --output text
aws lambda wait function-updated --region "$REGION" --function-name "$FN"

echo "== CloudWatch setup =="
ROLE=$(aws lambda get-function-configuration --region "$REGION" --function-name "$FN" --query Role --output text | awk -F/ '{print $NF}')
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws logs put-retention-policy --region "$REGION" --log-group-name "/aws/lambda/$FN" --retention-in-days 14 \
  || echo "(log group not created yet; invoke the API once and re-run)"
aws cloudwatch put-metric-alarm --region "$REGION" --alarm-name ICPL-Errors --namespace ICPL --metric-name Errors \
  --statistic Sum --period 60 --evaluation-periods 1 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching
cat << DASH > /tmp/icpl-dash.json
{"widgets":[
 {"type":"metric","x":0,"y":0,"width":12,"height":6,"properties":{"region":"$REGION","title":"Score writes & finals","stat":"Sum","period":60,"metrics":[["ICPL","ScoreWrite"],["ICPL","MatchFinalized"],["ICPL","Errors"]]}},
 {"type":"metric","x":12,"y":0,"width":12,"height":6,"properties":{"region":"$REGION","title":"API latency (ms)","stat":"Average","period":60,"metrics":[["ICPL","Latency","Method","PUT"],["ICPL","Latency","Method","GET"]]}},
 {"type":"log","x":0,"y":6,"width":24,"height":6,"properties":{"region":"$REGION","title":"Recent requests","query":"SOURCE '/aws/lambda/$FN' | fields @timestamp, method, path, status, ms | filter message='request' | sort @timestamp desc | limit 20"}}
]}
DASH
aws cloudwatch put-dashboard --region "$REGION" --dashboard-name ICPL --dashboard-body file:///tmp/icpl-dash.json
echo "DONE. Restart the site, click 'Send test update', then open CloudWatch > Logs > /aws/lambda/$FN > Start Live Tail."
