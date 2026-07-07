#!/usr/bin/env bash
# AgentForge Stage 2 — provision a single EC2 instance and deploy the OpenEMR
# + Caddy stack. Idempotent-ish: re-running reuses the key pair and security
# group by name. Requires: aws CLI configured (region us-east-1), this repo's
# deploy/ directory as CWD.
#
# Usage:  cd deploy && ./provision.sh
# Output: the live HTTPS URL once OpenEMR reports healthy.
set -euo pipefail

# ---- config (override via env) ----
REGION="${REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.xlarge}"      # 4 vCPU / 16 GB, per DECISIONS.md §15
VOLUME_GB="${VOLUME_GB:-40}"
NAME="${NAME:-agentforge-openemr}"
KEY_NAME="${KEY_NAME:-agentforge-key}"
SG_NAME="${SG_NAME:-agentforge-sg}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
export AWS_DEFAULT_REGION="$REGION"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "Preflight: identity + region"
aws sts get-caller-identity --output table

# ---- key pair ----
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  say "Creating key pair $KEY_NAME -> $KEY_FILE"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
else
  say "Key pair $KEY_NAME exists (expecting private key at $KEY_FILE)"
fi

# ---- security group ----
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
if ! aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -q sg-; then
  say "Creating security group $SG_NAME in $VPC_ID"
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "AgentForge OpenEMR deploy" --vpc-id "$VPC_ID" --query GroupId --output text)
  MYIP=$(curl -fsSL https://checkip.amazonaws.com | tr -d '[:space:]')
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MYIP}/32,Description=ssh-admin}]" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
                     "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null
else
  SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)
  say "Security group $SG_NAME exists ($SG_ID)"
fi

# ---- AMI (latest Amazon Linux 2023, x86_64) ----
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
say "AMI: $AMI_ID"

# ---- launch ----
say "Launching $INSTANCE_TYPE ($NAME)"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${VOLUME_GB},VolumeType=gp3}" \
  --user-data file://cloud-init.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=project,Value=agentforge}]" \
  --query 'Instances[0].InstanceId' --output text)
say "Instance $INSTANCE_ID — waiting for running state"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
DOMAIN="${PUBLIC_IP//./-}.nip.io"
say "Public IP $PUBLIC_IP  ->  https://$DOMAIN"

# ---- render .env.prod (random secrets) ----
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }
cat > .env.prod <<EOF
DOMAIN=${DOMAIN}
MYSQL_ROOT_PASSWORD=$(gen)
MYSQL_PASS=$(gen)
OE_PASS=$(gen)
EOF
say "Wrote .env.prod (admin password is OE_PASS — keep this file safe, it is gitignored)"

# ---- wait for SSH, then push the compose bundle ----
say "Waiting for SSH on $PUBLIC_IP"
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$KEY_FILE" \
       "ec2-user@${PUBLIC_IP}" true 2>/dev/null; then break; fi
  sleep 5
done

say "Copying deploy bundle to /opt/agentforge"
ssh -i "$KEY_FILE" "ec2-user@${PUBLIC_IP}" 'sudo mkdir -p /opt/agentforge && sudo chown ec2-user /opt/agentforge'
scp -i "$KEY_FILE" docker-compose.prod.yml Caddyfile .env.prod "ec2-user@${PUBLIC_IP}:/opt/agentforge/"

say "Bundle delivered. cloud-init will run 'docker compose up'. First boot pulls images + OpenEMR self-installs (~5-10 min)."
echo
echo "  Instance : $INSTANCE_ID"
echo "  SSH      : ssh -i $KEY_FILE ec2-user@$PUBLIC_IP"
echo "  URL      : https://$DOMAIN   (admin / see OE_PASS in .env.prod)"
echo "  Health   : curl -sk https://$DOMAIN/meta/health/readyz"
echo
echo "Poll readiness with:"
echo "  until curl -fsk https://$DOMAIN/meta/health/readyz >/dev/null; do sleep 15; done && echo LIVE"
