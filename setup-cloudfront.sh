#!/bin/bash
set -e

# CC-CLAW CloudFront Setup
# Creates a CloudFront distribution in front of code-server for HTTPS access.
# Requires: AWS CLI configured with permissions for CloudFront + EC2.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if ! command -v aws >/dev/null 2>&1; then
    log_error "AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Detect instance metadata
log_info "Detecting instance metadata..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 30" 2>/dev/null)
if [ -z "$TOKEN" ]; then
    log_error "Cannot access EC2 metadata. Are you running on EC2?"
    exit 1
fi

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
PUBLIC_DNS=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)

if [ -z "$PUBLIC_DNS" ]; then
    log_error "No public DNS found. Ensure your EC2 instance has a public IP with DNS enabled."
    exit 1
fi

log_info "Instance: $INSTANCE_ID"
log_info "Region: $REGION"
log_info "Public DNS: $PUBLIC_DNS"

# Check if code-server is running
if ! curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 | grep -q "200\|302"; then
    log_warn "code-server does not appear to be running on port 8080."
    read -rp "Continue anyway? (y/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy] ]]; then
        exit 0
    fi
fi

# Restrict security group to CloudFront only
echo ""
read -rp "Restrict port 8080 to CloudFront IPs only? (recommended) (Y/n): " RESTRICT_SG
if [[ ! "$RESTRICT_SG" =~ ^[Nn] ]]; then
    SG_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)

    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
            --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
            --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null)

        if [ -n "$CF_PREFIX_LIST" ] && [ "$CF_PREFIX_LIST" != "None" ]; then
            # Remove existing 0.0.0.0/0 rule on port 8080 if present
            aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
                --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=0.0.0.0/0}]" 2>/dev/null || true

            # Add CloudFront prefix list rule
            aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
                --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,PrefixListIds=[{PrefixListId=$CF_PREFIX_LIST,Description=CloudFront origin access}]" 2>/dev/null || true

            log_info "Security group $SG_ID updated: port 8080 restricted to CloudFront."
        else
            log_warn "CloudFront prefix list not found. Skipping security group update."
        fi
    else
        log_warn "Could not determine security group. Skipping."
    fi
fi

# Create CloudFront distribution
log_info "Creating CloudFront distribution..."
CALLER_REF="cc-claw-$(date +%s)"

DIST_CONFIG=$(cat << CFEOF
{
    "CallerReference": "$CALLER_REF",
    "Comment": "CC-CLAW CloudFront Distribution",
    "Enabled": true,
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "CodeServerOrigin",
                "DomainName": "$PUBLIC_DNS",
                "CustomOriginConfig": {
                    "HTTPPort": 8080,
                    "HTTPSPort": 443,
                    "OriginProtocolPolicy": "http-only",
                    "OriginReadTimeout": 60,
                    "OriginKeepaliveTimeout": 60,
                    "OriginSslProtocols": {
                        "Quantity": 1,
                        "Items": ["TLSv1.2"]
                    }
                }
            }
        ]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "CodeServerOrigin",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 7,
            "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
            "CachedMethods": {
                "Quantity": 2,
                "Items": ["GET", "HEAD"]
            }
        },
        "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
        "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
        "Compress": true
    },
    "HttpVersion": "http2",
    "PriceClass": "PriceClass_All"
}
CFEOF
)

RESULT=$(aws cloudfront create-distribution --distribution-config "$DIST_CONFIG" --output json 2>&1)

if [ $? -ne 0 ]; then
    log_error "Failed to create CloudFront distribution:"
    echo "$RESULT"
    exit 1
fi

CF_DOMAIN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Distribution']['DomainName'])")
CF_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Distribution']['Id'])")

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${GREEN}  CloudFront distribution created!${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "  Distribution ID:  ${CYAN}$CF_ID${NC}"
echo -e "  HTTPS URL:        ${GREEN}https://$CF_DOMAIN${NC}"
echo ""
echo -e "  ${YELLOW}Note: It may take 5-10 minutes for the distribution to deploy.${NC}"
echo ""
