#!/bin/bash
# Zammad Elasticsearch 7.x to 9.x Master Upgrade Script (v5)
# Target: Ubuntu 22.04 | Host: help.domain.com | IP: 192.168.0.10

set -e

# Defined password to seed directly into the keystore
MY_ES_PASS="ZammadSecurePass2026!"

echo "========================================================"
echo " 0. Pre-Flight Cleanup"
echo "========================================================"
echo "[*] Removing legacy ingest-attachment plugin..."
/usr/share/elasticsearch/bin/elasticsearch-plugin remove ingest-attachment || true

echo "========================================================"
echo " 1. Preparing Dependencies & SSL Certificates"
echo "========================================================"
apt-get update && apt-get install unzip jq -y

mkdir -p /etc/elasticsearch/certs/

echo "[*] Generating Certificate Authority..."
/usr/share/elasticsearch/bin/elasticsearch-certutil ca --out /etc/elasticsearch/certs/elastic-stack-ca.p12 --pass ""

echo "[*] Generating Transport Certificate..."
/usr/share/elasticsearch/bin/elasticsearch-certutil cert --ca /etc/elasticsearch/certs/elastic-stack-ca.p12 --ca-pass "" --out /etc/elasticsearch/certs/elastic-certificates.p12 --pass ""

echo "[*] Generating HTTP Certificate for help.domain.com and 192.168.0.10..."
cat <<EOF > /tmp/instances.yml
instances:
  - name: "http"
    dns:
      - "localhost"
      - "help.domain.com"
    ip:
      - "127.0.0.1"
      - "192.168.0.10"
EOF

/usr/share/elasticsearch/bin/elasticsearch-certutil cert --silent --in /tmp/instances.yml --out /tmp/certs.zip --ca /etc/elasticsearch/certs/elastic-stack-ca.p12 --ca-pass "" --pass ""
unzip -o -j /tmp/certs.zip "http/http.p12" -d /etc/elasticsearch/certs/
rm -f /tmp/instances.yml /tmp/certs.zip

chown -R root:elasticsearch /etc/elasticsearch/certs
chmod -R 750 /etc/elasticsearch/certs
chmod 640 /etc/elasticsearch/certs/*

echo "========================================================"
echo " 2. Configuring X-Pack Security & Single-Node Mode"
echo "========================================================"
echo "[*] Updating elasticsearch.yml..."

# Sanitize potential config conflicts before applying single-node mode
sed -i 's/^cluster.initial_master_nodes/#cluster.initial_master_nodes/' /etc/elasticsearch/elasticsearch.yml

cat <<EOF >> /etc/elasticsearch/elasticsearch.yml

# Added by Zammad Upgrade Script
discovery.type: single-node
xpack.security.enabled: true
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.keystore.path: certs/http.p12
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.keystore.path: certs/elastic-certificates.p12
xpack.security.transport.ssl.truststore.path: certs/elastic-certificates.p12
EOF

echo "[*] Pre-seeding 'elastic' user password in keystore..."
echo "$MY_ES_PASS" | /usr/share/elasticsearch/bin/elasticsearch-keystore add -x 'bootstrap.password' -f

echo "[*] Starting Elasticsearch 7.x with security enabled..."
systemctl restart elasticsearch
sleep 20

echo "========================================================"
echo " 3. Upgrading to Elasticsearch 8.x"
echo "========================================================"
rm -f /etc/apt/sources.list.d/elastic-7.x.list

curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor | tee /usr/share/keyrings/elasticsearch-keyring.gpg > /dev/null
chmod 644 /usr/share/keyrings/elasticsearch-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | tee /etc/apt/sources.list.d/elastic-8.x.list

apt-get update
apt-get install -o Dpkg::Options::="--force-confold" elasticsearch -y

echo "[*] Restarting Elasticsearch 8.x..."
systemctl daemon-reload
systemctl restart elasticsearch
sleep 20

echo "========================================================"
echo " 4. Upgrading to Elasticsearch 9.x"
echo "========================================================"
# Stop service and clear old data/indices to prevent v9 metadata boot crashes
systemctl stop elasticsearch
rm -rf /var/lib/elasticsearch/*

rm -f /etc/apt/sources.list.d/elastic-8.x.list
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" | tee /etc/apt/sources.list.d/elastic-9.x.list

apt-get update
apt-get install -o Dpkg::Options::="--force-confold" elasticsearch -y

# Re-seed password to ensure 9.x keystore retention
echo "$MY_ES_PASS" | /usr/share/elasticsearch/bin/elasticsearch-keystore add -x 'bootstrap.password' -f

# Ensure file ownership permissions are preserved across major apt upgrades
chown -R root:elasticsearch /etc/elasticsearch/certs
chmod -R 750 /etc/elasticsearch/certs
chmod 640 /etc/elasticsearch/certs/*

echo "[*] Starting Elasticsearch 9.x..."
systemctl daemon-reload
systemctl restart elasticsearch
sleep 25

echo "========================================================"
echo " 5. Reconfiguring Zammad & Rebuilding Search Index"
echo "========================================================"
zammad run rails r "Setting.set('es_url', 'https://127.0.0.1:9200')"
zammad run rails r "Setting.set('es_user', 'elastic')"
zammad run rails r "Setting.set('es_password', '${MY_ES_PASS}')"

echo "[*] Triggering Zammad search index rebuild..."
zammad run rake zammad:searchindex:rebuild

echo "========================================================"
echo " Upgrade Complete! Password set to: ${MY_ES_PASS}"
echo "========================================================"
