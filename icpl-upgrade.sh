#!/usr/bin/env bash
set -euo pipefail

# ───── SETTINGS (ALERT_EMAIL is passed on the command line) ─────
REGION="ap-southeast-2"
FN="TournamentApi"
ALERT_EMAIL="${ALERT_EMAIL:-}"
AI="${AI:-on}"                                   # on | off  (Bedrock commentary)
MODEL="${MODEL:-apac.amazon.nova-micro-v1:0}"    # Bedrock model / inference profile id
DEPLOY_WEB="${DEPLOY_WEB:-yes}"                  # yes | no  (S3 + CloudFront)
# ────────────────────────────────────────────────────────────────

[ -n "$ALERT_EMAIL" ] || { echo "Run as:  ALERT_EMAIL=you@example.com ./icpl-upgrade.sh"; exit 1; }
ROOT="$(pwd)"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Account $ACCOUNT, region $REGION"

# ═════════ 1. SNS email alerts on the ICPL-Errors alarm ═════════
echo "== 1/6 SNS alerts =="
TOPIC=$(aws sns create-topic --region "$REGION" --name icpl-alerts --query TopicArn --output text)
aws sns subscribe --region "$REGION" --topic-arn "$TOPIC" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null
aws cloudwatch put-metric-alarm --region "$REGION" --alarm-name ICPL-Errors \
  --namespace ICPL --metric-name Errors --statistic Sum --period 60 \
  --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching --alarm-actions "$TOPIC" --ok-actions "$TOPIC"
echo "-> Confirmation email sent to $ALERT_EMAIL. You MUST click the link in it."

# ═════════ 2. Lambda wrapper v2 (CloudWatch + Bedrock commentary) ═════════
echo "== 2/6 Lambda code =="
W=$(mktemp -d); cd "$W"
aws lambda get-function --region "$REGION" --function-name "$FN" --query Code.Location --output text > url.txt
curl -s -o cur.zip "$(cat url.txt)"
cp cur.zip "$HOME/TournamentApi-backup-v2.zip"
mkdir code && unzip -q cur.zip -d code && cd code
[ -f api.mjs ] || { echo "api.mjs not found. Run the earlier cw-lambda.sh first. Files: $(ls)"; exit 1; }

cat << 'WRAP' > index.mjs
// CLOUDWATCH_WRAPPER v2
import { handler as apiHandler } from './api.mjs';

const NS = 'ICPL';
const log = (level, message, fields = {}) => console.log(JSON.stringify({ level, message, ...fields }));
const metric = (name, value = 1, unit = 'Count', dims = {}) => console.log(JSON.stringify({
  _aws: { Timestamp: Date.now(), CloudWatchMetrics: [{ Namespace: NS, Dimensions: [Object.keys(dims)], Metrics: [{ Name: name, Unit: unit }] }] },
  ...dims, [name]: value,
}));
const CORS = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' };

// ---- Bedrock AI commentary (fail-safe: any problem = original commentary kept) ----
const AI_ON = process.env.AI_COMMENTARY === 'on';
const MODEL = process.env.BEDROCK_MODEL || 'apac.amazon.nova-micro-v1:0';
let sdk = null, client = null, pausedUntil = 0;
const lastAi = {};

async function aiLine(m) {
  if (!AI_ON || Date.now() < pausedUntil) return null;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 2500);
  try {
    if (!client) { sdk = await import('@aws-sdk/client-bedrock-runtime'); client = new sdk.BedrockRuntimeClient({ region: process.env.AWS_REGION }); }
    const prompt = 'Write ONE short, exciting cricket commentary line (max 18 words) for this live match. ' +
      'Do not invent player names. Output only the line.\n' +
      `${m.teamA} ${m.scoreA} vs ${m.teamB} ${m.scoreB}. Over ${Math.floor((m.balls || 0) / 6)}.${(m.balls || 0) % 6}. ` +
      `Win probability for ${m.teamA}: ${m.winProbA}%. Last event: ${m.commentary || 'none'}`;
    const out = await client.send(new sdk.ConverseCommand({
      modelId: MODEL,
      messages: [{ role: 'user', content: [{ text: prompt }] }],
      inferenceConfig: { maxTokens: 60, temperature: 0.7 },
    }), { abortSignal: ctl.signal });
    const text = (out.output?.message?.content?.[0]?.text || '').trim().replace(/^["']|["']$/g, '').slice(0, 160);
    if (!text) return null;
    metric('AiCommentary');
    return text;
  } catch (e) {
    pausedUntil = Date.now() + 5 * 60 * 1000;   // back off for 5 minutes
    log('warn', 'ai_commentary_failed', { error: String(e).slice(0, 200), model: MODEL });
    metric('AiFailure');
    return null;
  } finally { clearTimeout(timer); }
}

export const handler = async (event, context) => {
  const start = Date.now();
  const method = event.httpMethod || event.requestContext?.http?.method || 'UNKNOWN';
  const path = event.rawPath || event.path || '';

  // Browser telemetry -> CloudWatch
  if (method === 'POST' && path.endsWith('/telemetry')) {
    let b = {};
    try { b = JSON.parse(event.body || '{}'); } catch {}
    const ev = String(b.event || 'unknown').slice(0, 40);
    log(ev === 'client_error' || ev === 'js_error' ? 'error' : 'info', 'client_event',
      { event: ev, data: b.data, session: b.session, requestId: context.awsRequestId });
    metric('ClientEvent', 1, 'Count', { Event: ev });
    return { statusCode: 200, headers: CORS, body: '{}' };
  }

  // AI commentary on live score writes (max once per 15s per match)
  if (AI_ON && method === 'PUT' && /\/matches\/[^/]+$/.test(path) && event.body && !event.isBase64Encoded) {
    try {
      const b = JSON.parse(event.body);
      if (b.status === 'LIVE' && Date.now() - (lastAi[b.id] || 0) > 15000) {
        lastAi[b.id] = Date.now();
        const line = await aiLine(b);
        if (line) { b.commentary = line; event = { ...event, body: JSON.stringify(b) }; }
      }
    } catch { /* ignore, keep original body */ }
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
WRAP

zip -qr ../new.zip .
aws lambda update-function-code --region "$REGION" --function-name "$FN" --zip-file fileb://../new.zip --query LastModified --output text
aws lambda wait function-updated --region "$REGION" --function-name "$FN"

# ═════════ 3. IAM: Bedrock + X-Ray permissions ═════════
echo "== 3/6 IAM =="
ROLE=$(aws lambda get-function-configuration --region "$REGION" --function-name "$FN" --query Role --output text | awk -F/ '{print $NF}')
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
cat << 'POL' > /tmp/icpl-bedrock.json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],"Resource":"*"}]}
POL
aws iam put-role-policy --role-name "$ROLE" --policy-name icpl-bedrock-invoke --policy-document file:///tmp/icpl-bedrock.json

# ═════════ 4. Lambda config: env vars (merged) + X-Ray tracing ═════════
echo "== 4/6 Lambda config =="
aws lambda get-function-configuration --region "$REGION" --function-name "$FN" --query 'Environment.Variables' --output json > env_old.json
python3 - << PY
import json
try: v = json.load(open('env_old.json')) or {}
except Exception: v = {}
v['AI_COMMENTARY'] = '$AI'
v['BEDROCK_MODEL'] = '$MODEL'
json.dump({'Variables': v}, open('env_new.json', 'w'))
PY
aws lambda update-function-configuration --region "$REGION" --function-name "$FN" \
  --environment file://env_new.json --tracing-config Mode=Active --query LastModified --output text
aws lambda wait function-updated --region "$REGION" --function-name "$FN"

# ═════════ 5. API Gateway throttling (HTTP APIs that call this Lambda) ═════════
echo "== 5/6 API throttling =="
FOUND=0
for ID in $(aws apigatewayv2 get-apis --region "$REGION" --query 'Items[].ApiId' --output text 2>/dev/null); do
  HIT=$(aws apigatewayv2 get-integrations --region "$REGION" --api-id "$ID" \
        --query "Items[?contains(IntegrationUri,'$FN')].IntegrationId" --output text 2>/dev/null || true)
  [ -n "$HIT" ] || continue
  FOUND=1
  for ST in $(aws apigatewayv2 get-stages --region "$REGION" --api-id "$ID" --query 'Items[].StageName' --output text); do
    aws apigatewayv2 update-stage --region "$REGION" --api-id "$ID" --stage-name "$ST" \
      --default-route-settings ThrottlingBurstLimit=200,ThrottlingRateLimit=100 >/dev/null \
      && echo "throttle set on API $ID stage $ST (100 req/s, burst 200)" || echo "could not update stage $ST"
  done
done
[ "$FOUND" = 1 ] || echo "No HTTP API found pointing to $FN (maybe a REST API). Skipped throttling."

# ═════════ 6. Host the website on S3 + CloudFront ═════════
if [ "$DEPLOY_WEB" = "yes" ]; then
  echo "== 6/6 Website hosting =="
  cd "$ROOT"
  [ -f package.json ] || { echo "package.json not found in $ROOT"; exit 1; }
  npm run build
  BUCKET="icpl-web-$ACCOUNT"
  if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3 sync dist "s3://$BUCKET" --delete --only-show-errors

  OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='icpl-oac'].Id | [0]" --output text 2>/dev/null || echo None)
  if [ -z "$OAC_ID" ] || [ "$OAC_ID" = "None" ]; then
    OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config \
      Name=icpl-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3 \
      --query OriginAccessControl.Id --output text)
  fi

  DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='ICPL web'].Id | [0]" --output text 2>/dev/null || echo None)
  if [ -z "$DIST_ID" ] || [ "$DIST_ID" = "None" ]; then
    cat << CFG > /tmp/icpl-cf.json
{"CallerReference":"icpl-$(date +%s)","Comment":"ICPL web","Enabled":true,"DefaultRootObject":"index.html",
 "Origins":{"Quantity":1,"Items":[{"Id":"s3","DomainName":"$BUCKET.s3.$REGION.amazonaws.com","S3OriginConfig":{"OriginAccessIdentity":""},"OriginAccessControlId":"$OAC_ID"}]},
 "DefaultCacheBehavior":{"TargetOriginId":"s3","ViewerProtocolPolicy":"redirect-to-https","CachePolicyId":"658327ea-f89d-4fab-a63d-7e88639e58f6","Compress":true}}
CFG
    DIST_ID=$(aws cloudfront create-distribution --distribution-config file:///tmp/icpl-cf.json --query Distribution.Id --output text)
  else
    aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" >/dev/null
  fi

  cat << BPOL > /tmp/icpl-bucket.json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},
 "Action":"s3:GetObject","Resource":"arn:aws:s3:::$BUCKET/*",
 "Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID"}}}]}
BPOL
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/icpl-bucket.json
  DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)
  echo "Website URL: https://$DOMAIN   (takes 5-10 minutes to go live the first time)"
fi

echo
echo "DONE. Next: 1) confirm the SNS email  2) run the checks below."
