#!/bin/bash
set -e

# ── Config ────────────────────────────────────────────────────────────────────
REGION="us-east-1"
BUCKET_FRONTEND="jimmy-resume-matcher"
LAMBDA_NAME="jimmy-resume-matcher"
LAMBDA_ROLE_NAME="jimmy-resume-matcher-role"
API_NAME="jimmy-resume-matcher-api"
RUNTIME="python3.11"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   AI Resume Matcher — Deploy Script      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Prompt for Anthropic API key ──────────────────────────────────────────────
if [ -z "$ANTHROPIC_API_KEY" ]; then
  read -rsp "Enter your Anthropic API key: " ANTHROPIC_API_KEY
  echo ""
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "✓ AWS Account: $ACCOUNT_ID"

# ── 1. Package Lambda ─────────────────────────────────────────────────────────
echo ""
echo "▶ Packaging Lambda..."
TMPDIR=$(mktemp -d)
pip install -r backend/requirements.txt -t "$TMPDIR" \
    --platform manylinux2014_x86_64 \
    --only-binary=:all: \
    --python-version 3.11 \
    --implementation cp \
    --quiet
cp backend/lambda_function.py "$TMPDIR/"
cd "$TMPDIR"
zip -r9 /tmp/resume-matcher.zip . --quiet
cd - > /dev/null
rm -rf "$TMPDIR"
echo "✓ Package ready: /tmp/resume-matcher.zip"

# ── 2. IAM Role ───────────────────────────────────────────────────────────────
echo ""
echo "▶ Setting up IAM role..."
ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)

if [ -z "$ROLE_ARN" ]; then
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  ROLE_ARN=$(aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "$TRUST" \
    --query Role.Arn --output text)
  aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "✓ IAM role created: $ROLE_ARN"
  echo "  Waiting 10s for role to propagate..."
  sleep 10
else
  echo "✓ IAM role exists: $ROLE_ARN"
fi

# ── 3. Lambda Function ────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying Lambda function..."
EXISTING=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime "$RUNTIME" \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb:///tmp/resume-matcher.zip \
    --timeout 60 \
    --memory-size 512 \
    --region "$REGION" \
    --environment "Variables={ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY}" \
    --output text > /dev/null
  echo "✓ Lambda function created"
else
  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file fileb:///tmp/resume-matcher.zip \
    --region "$REGION" \
    --output text > /dev/null
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "Variables={ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY}" \
    --region "$REGION" \
    --output text > /dev/null
  echo "✓ Lambda function updated"
fi

LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$LAMBDA_NAME"

# ── 4. API Gateway ────────────────────────────────────────────────────────────
echo ""
echo "▶ Setting up API Gateway..."
API_ID=$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='$API_NAME'].id | [0]" --output text 2>/dev/null)

if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
  API_ID=$(aws apigateway create-rest-api \
    --name "$API_NAME" \
    --region "$REGION" \
    --query id --output text)
  echo "✓ API created: $API_ID"
else
  echo "✓ API exists: $API_ID"
fi

# Get root resource
ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" \
  --region "$REGION" \
  --query "items[?path=='/'].id | [0]" --output text)

# Create /analyze resource if needed
RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" \
  --region "$REGION" \
  --query "items[?path=='/analyze'].id | [0]" --output text 2>/dev/null)

if [ -z "$RESOURCE_ID" ] || [ "$RESOURCE_ID" == "None" ]; then
  RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$ROOT_ID" \
    --path-part "analyze" \
    --region "$REGION" \
    --query id --output text)
fi

# POST method
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method POST \
  --authorization-type NONE \
  --region "$REGION" 2>/dev/null || true

# Lambda integration
aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
  --region "$REGION" 2>/dev/null || true

# OPTIONS method for CORS
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method OPTIONS \
  --authorization-type NONE \
  --region "$REGION" 2>/dev/null || true

aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method OPTIONS \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
  --region "$REGION" 2>/dev/null || true

# Lambda permission for API Gateway
aws lambda add-permission \
  --function-name "$LAMBDA_NAME" \
  --statement-id "apigateway-invoke" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*/analyze" \
  --region "$REGION" 2>/dev/null || true

# Deploy
aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name prod \
  --region "$REGION" \
  --output text > /dev/null

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/analyze"
echo "✓ API deployed: $API_ENDPOINT"

# ── 5. Frontend S3 Bucket ─────────────────────────────────────────────────────
echo ""
echo "▶ Setting up frontend S3 bucket..."
if ! aws s3 ls "s3://$BUCKET_FRONTEND" --region "$REGION" 2>/dev/null; then
  aws s3 mb "s3://$BUCKET_FRONTEND" --region "$REGION"
fi

aws s3api put-bucket-ownership-controls \
  --bucket "$BUCKET_FRONTEND" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerPreferred}]' 2>/dev/null || true

aws s3api put-public-access-block \
  --bucket "$BUCKET_FRONTEND" \
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

aws s3api put-bucket-policy \
  --bucket "$BUCKET_FRONTEND" \
  --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicRead\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET_FRONTEND/*\"}]}"

aws s3 website "s3://$BUCKET_FRONTEND" \
  --index-document index.html \
  --error-document index.html

echo "✓ S3 bucket configured"

# ── 6. Inject API URL into frontend ──────────────────────────────────────────
echo ""
echo "▶ Injecting API endpoint into frontend..."
sed "s|API_ENDPOINT_PLACEHOLDER|$API_ENDPOINT|g" \
  index.html > /tmp/index-deployed.html
echo "✓ API URL injected"

# ── 7. Upload frontend ────────────────────────────────────────────────────────
echo ""
echo "▶ Uploading frontend..."
aws s3 cp /tmp/index-deployed.html \
  "s3://$BUCKET_FRONTEND/index.html" \
  --content-type "text/html" \
  --region "$REGION"
echo "✓ Frontend uploaded"

# ── 8. CloudFront invalidation ────────────────────────────────────────────────
echo ""
echo "▶ Invalidating CloudFront cache..."
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Origins.Items[0].DomainName, '$BUCKET_FRONTEND')].Id | [0]" \
  --output text 2>/dev/null)

if [ -n "$CF_ID" ] && [ "$CF_ID" != "None" ]; then
  aws cloudfront create-invalidation \
    --distribution-id "$CF_ID" \
    --paths "/*" \
    --output text > /dev/null
  echo "✓ CloudFront invalidation started for $CF_ID"
else
  echo "  (no CloudFront distribution found — skipping)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
SITE_URL="http://$BUCKET_FRONTEND.s3-website-$REGION.amazonaws.com"
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              Deploy Complete!            ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  🌐 Site:     $SITE_URL"
echo "  ⚡ API:      $API_ENDPOINT"
echo "  🔧 Lambda:   $LAMBDA_NAME"
echo ""
