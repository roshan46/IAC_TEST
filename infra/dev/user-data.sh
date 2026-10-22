#!/bin/bash
# Ubuntu 24.04 x86_64 host prerequisites. Flask deployment comes in milestone 5.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install -y python3 python3-venv curl unzip ca-certificates groff less snapd

if ! id orderapp >/dev/null 2>&1; then
  useradd --system --home-dir /opt/order-manager --shell /usr/sbin/nologin orderapp
fi
install -d -m 755 -o orderapp -g orderapp /opt/order-manager /opt/order-manager/releases

# The official versioned ZIP was downloaded over HTTPS and its SHA256 recorded.
aws_archive=$(mktemp /tmp/order-manager-awscli.XXXXXX.zip)
aws_directory=$(mktemp -d /tmp/order-manager-awscli.XXXXXX)
curl --fail --silent --show-error --location --retry 3 \
  https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.32.0.zip -o "$aws_archive"
echo "2e57ed5587de3789d39841c0f309134ccc13a215af597c7739f7102deca30dad  $aws_archive" | sha256sum --check -
unzip -q "$aws_archive" -d "$aws_directory"
"$aws_directory/aws/install" --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin --update

# An isolated tooling venv avoids modifying Ubuntu's system Python packages.
python3 -m venv /opt/order-manager-tools
cat >/opt/order-manager-tools/requirements.txt <<'REQUIREMENTS'
uv==0.13.4 --hash=sha256:05e4332791b4d55b6dde8695b7fa6079b26991519f44760887c5dfbd5ca4fe53
REQUIREMENTS
/opt/order-manager-tools/bin/pip install --require-hashes --only-binary=:all: --no-deps \
  -r /opt/order-manager-tools/requirements.txt
ln -sfn /opt/order-manager-tools/bin/uv /usr/local/bin/uv

# Canonical's current Ubuntu AMI normally includes this snap. Do not install a
# second .deb agent alongside it.
if ! snap list amazon-ssm-agent >/dev/null 2>&1; then
  snap install amazon-ssm-agent --classic
fi
snap start --enable amazon-ssm-agent
systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service
/usr/local/bin/aws --version
/usr/local/bin/uv --version
python3 --version
install -d -m 755 /var/lib/order-manager
touch /var/lib/order-manager/bootstrap.ready
