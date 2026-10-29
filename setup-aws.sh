#!/usr/bin/env bash
export AWS_REGION=ap-southeast-2 AWS_DEFAULT_REGION=ap-southeast-2 AWS_PAGER=""
PROJ=$(pwd)
step() { echo; echo "==> $1"; }
fail() { echo "FAILED: $1"; exit 1; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || fail "AWS credentials not working (run: aws configure)"
command -v zip >/dev/null || { echo "Installing zip..."; apt-get install -y zip >/dev/null 2>&1 || fail "install zip manually: apt-get install zip"; }
echo "Account: $ACCOUNT  Region: $AWS_REGION"

step "1/6 DynamoDB tables"
for T in LiveMatches ICPLTeams; do
  if aws dynamodb describe-table --table-name $T >/dev/null 2>&1; then echo "$T exists"; else
    aws dynamodb create-table --table-name $T --attribute-definitions AttributeName=id,AttributeType=S \
      --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null || fail "create table $T"
    echo "$T created"
  fi
  aws dynamodb wait table-exists --table-name $T
done

step "2/6 IAM role"
cat > /tmp/trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
if aws iam get-role --role-name icpl-lambda-role >/dev/null 2>&1; then echo "role exists"; else
  aws iam create-role --role-name icpl-lambda-role --assume-role-policy-document file:///tmp/trust.json >/dev/null || fail "create role (check IAM permissions)"
  echo "role created"; sleep 10
fi
aws iam attach-role-policy --role-name icpl-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
cat > /tmp/ddb.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["dynamodb:Scan","dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem"],"Resource":["arn:aws:dynamodb:$AWS_REGION:$ACCOUNT:table/LiveMatches","arn:aws:dynamodb:$AWS_REGION:$ACCOUNT:table/ICPLTeams"]}]}
EOF
aws iam put-role-policy --role-name icpl-lambda-role --policy-name icpl-ddb --policy-document file:///tmp/ddb.json || fail "put role policy"

step "3/6 Lambda code"
mkdir -p ~/icpl-lambda && cd ~/icpl-lambda
cat > index.mjs << 'EOF'
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand, PutCommand, GetCommand } from "@aws-sdk/lib-dynamodb";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}), { marshallOptions: { removeUndefinedValues: true } });
const T = process.env.TEAMS_TABLE, M = process.env.MATCHES_TABLE;
const res = (code, body) => ({ statusCode: code, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const put = (table, Item) => db.send(new PutCommand({ TableName: table, Item }));
const scan = async (table) => {
  let items = [], key;
  do { const r = await db.send(new ScanCommand({ TableName: table, ExclusiveStartKey: key })); items = items.concat(r.Items || []); key = r.LastEvaluatedKey; } while (key);
  return items;
};
const sortT = (t) => [...t].sort((a, b) => b.points - a.points || b.netScoreRate - a.netScoreRate);
const SEED = [
  { id: "1", teamName: "Chennai Super Kings", matchesPlayed: 2, points: 6, netScoreRate: 1.42 },
  { id: "2", teamName: "Mumbai Mavericks", matchesPlayed: 2, points: 4, netScoreRate: 0.85 },
  { id: "3", teamName: "Bangalore Blazers", matchesPlayed: 2, points: 3, netScoreRate: -0.15 },
  { id: "4", teamName: "Delhi Dynamos", matchesPlayed: 2, points: 0, netScoreRate: -2.1 },
];

export const handler = async (event) => {
  try {
    const route = event.routeKey;
    const body = event.body ? JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, "base64").toString() : event.body) : {};
    const id = event.pathParameters && event.pathParameters.id;
    console.log(route, JSON.stringify(body).slice(0, 300));

    if (route === "GET /teams") {
      let teams = await scan(T);
      if (!teams.length) { for (const s of SEED) await put(T, s); teams = SEED; }
      return res(200, { teams: sortT(teams) });
    }
    if (route === "POST /teams") {
      if (!body.teamName) return res(400, { error: "teamName required" });
      const team = { id: String(Date.now()), teamName: body.teamName, matchesPlayed: 0, points: 0, netScoreRate: 0 };
      await put(T, team);
      return res(200, { team });
    }
    if (route === "GET /matches") return res(200, { matches: await scan(M) });
    if (route === "PUT /matches/{id}") {
      await put(M, { ...body, id });
      return res(200, { ok: true, id });
    }
    if (route === "POST /matches/{id}/finalize") {
      const d = Number(body.nrrDelta || 0);
      const teams = await scan(T);
      for (const t of teams) {
        if (t.teamName === body.winner) { t.matchesPlayed += 1; t.points += 3; t.netScoreRate = +(t.netScoreRate + d).toFixed(2); await put(T, t); }
        else if (t.teamName === body.loser) { t.matchesPlayed += 1; t.netScoreRate = +(t.netScoreRate - d).toFixed(2); await put(T, t); }
      }
      const m = await db.send(new GetCommand({ TableName: M, Key: { id } }));
      if (m.Item) await put(M, { ...m.Item, scoreA: body.scoreA ?? m.Item.scoreA, scoreB: body.scoreB ?? m.Item.scoreB, status: "COMPLETED" });
      return res(200, { teams: sortT(teams) });
    }
    if (route === "POST /fixtures/generate") {
      const fixtures = body.fixtures || [];
      for (const f of fixtures) await put(M, f);
      return res(200, { fixtures });
    }
    return res(404, { error: "route not found: " + route });
  } catch (e) {
    console.error(e);
    return res(500, { error: String(e.message || e) });
  }
};
EOF
rm -f function.zip && zip -q function.zip index.mjs || fail "zip"

step "4/6 Lambda function"
if aws lambda get-function --function-name TournamentApi >/dev/null 2>&1; then
  aws lambda update-function-code --function-name TournamentApi --zip-file fileb://function.zip >/dev/null || fail "update lambda"
  echo "Lambda updated"
else
  for i in 1 2 3 4 5; do
    aws lambda create-function --function-name TournamentApi --runtime nodejs20.x --handler index.handler \
      --role arn:aws:iam::$ACCOUNT:role/icpl-lambda-role --zip-file fileb://function.zip --timeout 15 \
      --environment "Variables={TEAMS_TABLE=ICPLTeams,MATCHES_TABLE=LiveMatches}" >/dev/null 2>/tmp/lerr && { echo "Lambda created"; break; }
    echo "retry $i (role still propagating): $(tail -c 160 /tmp/lerr)"; sleep 8
    [ $i = 5 ] && fail "create lambda"
  done
fi
aws lambda wait function-active --function-name TournamentApi

step "5/6 API Gateway (HTTP API with CORS)"
for OLD in $(aws apigatewayv2 get-apis --query "Items[?Name=='icpl-api'].ApiId" --output text); do aws apigatewayv2 delete-api --api-id $OLD; echo "removed old API $OLD"; done
API_ID=$(aws apigatewayv2 create-api --name icpl-api --protocol-type HTTP \
  --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["GET","POST","PUT","OPTIONS"],"AllowHeaders":["content-type","x-api-key"]}' \
  --query ApiId --output text) || fail "create api"
INTEG=$(aws apigatewayv2 create-integration --api-id $API_ID --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:$AWS_REGION:$ACCOUNT:function:TournamentApi --payload-format-version 2.0 \
  --query IntegrationId --output text) || fail "create integration"
for R in "GET /teams" "POST /teams" "GET /matches" "PUT /matches/{id}" "POST /matches/{id}/finalize" "POST /fixtures/generate"; do
  aws apigatewayv2 create-route --api-id $API_ID --route-key "$R" --target integrations/$INTEG >/dev/null || fail "route $R"
  echo "route: $R"
done
aws lambda remove-permission --function-name TournamentApi --statement-id apigw-invoke >/dev/null 2>&1
aws lambda add-permission --function-name TournamentApi --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT:$API_ID/*/*" >/dev/null || fail "lambda permission"
aws apigatewayv2 create-stage --api-id $API_ID --stage-name prod --auto-deploy >/dev/null || fail "create stage"

step "6/6 Writing .env"
URL="https://$API_ID.execute-api.$AWS_REGION.amazonaws.com/prod"
cd "$PROJ"
cat > .env << EOF
VITE_API_BASE=$URL
VITE_AWS_REGION=$AWS_REGION
VITE_DDB_TABLE=LiveMatches
VITE_RDS_DB=
VITE_S3_BUCKET=
VITE_LAMBDA_NAME=TournamentApi
EOF
echo; echo "API ID : $API_ID"; echo "API URL: $URL"
echo "--- test GET /teams ---"; sleep 4; curl -s "$URL/teams"; echo
echo; echo "DONE. Now run: npm run dev"
