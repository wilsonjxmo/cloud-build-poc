#!/bin/bash

function log() {
    STAMP=$(date +'%Y-%m-%d %H:%M:%S %Z')
    printf "\n%s    %s\n" "${STAMP}" "$1"
}

# **********************************************************************************************
# Main Flow
# **********************************************************************************************

set -e

export SCRIPT_DIR=$(dirname "$0")

export ONPREM_PROJECT="onprem-327304"
export VPCHOST_PROJECT="vpchost-eu-dev"
export SERVICE_PROJECT="usecase-eu-dev"

export ONPREM_VM_NAME="onprem-vm-1"
export ONPREM_VM_REGION="europe-west2"
export ONPREM_VM_ZONE="${ONPREM_VM_REGION}-c"

export VPCHOST_VM_NAME="vpchost-vm-1"
export VPCHOST_VM_REGION="europe-west2"
export VPCHOST_VM_ZONE="${ONPREM_VM_REGION}-c"
export VPCHOST_VPC_NAME="vpchost-eu-dev-vpc1"
export VPCHOST_ZONE_NAME="onprem"

export SERVICE_VM_NAME="usecase-vm-1"
export SERVICE_VM_REGION="europe-west2"
export SERVICE_VM_ZONE="${SERVICE_VM_REGION}-c"
export SERVICE_NAT_TEMPLATE_NAME="nat-template"
export SERVICE_NAT_HC_NAME="nat-hc"
export SERVICE_NAT_MIG_NAME="nat-mig"
export SERVICE_NAT_BE_NAME="nat-be"
export SERVICE_NAT_FR_NAME="nat-fr"
export SERVICE_NAT_ROUTE_NAME="onprem-route"
export SERVICE_VPC_NAME="usecase-vpc1"
export SERVICE_SUBNET_NAME="usecase-vpc1-europe-west2"

cat >${SCRIPT_DIR}/startup.sh<<EOF
#! /bin/bash

mkdir -p /opt/app

cat > /opt/app/server.py <<SEOF
import BaseHTTPServer
import SimpleHTTPServer


class Handler(SimpleHTTPServer.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write("Hello World".encode("utf-8"))
        return


if __name__ == "__main__":
    http_d = BaseHTTPServer.HTTPServer(("0.0.0.0", 80), Handler)
    print "app is serving at port 80"
    http_d.serve_forever()

SEOF

nohup python /opt/app/server.py 2>&1 &
EOF


if [[ $(gcloud compute instances list \
          --project=${ONPREM_PROJECT} \
          --filter="NAME=${ONPREM_VM_NAME}" \
          --format="csv(NAME)[no-heading]" \
          --verbosity="error") ]]; then
    gcloud compute instances delete ${ONPREM_VM_NAME} --zone ${ONPREM_VM_ZONE} --project=${ONPREM_PROJECT} -q
fi
gcloud compute instances create ${ONPREM_VM_NAME} \
  --project=${ONPREM_PROJECT} --zone=${ONPREM_VM_ZONE} --machine-type=e2-micro \
  --network-interface=network-tier=PREMIUM,subnet=onprem-vpc1-eurpe-west2,no-address \
  --image-project=centos-cloud \
  --image-family=centos-7 \
  --metadata-from-file=startup-script=${SCRIPT_DIR}/startup.sh


if [[ $(gcloud compute instances list \
        --project=${VPCHOST_PROJECT} \
        --filter="NAME=${VPCHOST_VM_NAME}" \
        --format="csv(NAME)[no-heading]" \
        --verbosity="error") ]]; then
    gcloud compute instances delete ${VPCHOST_VM_NAME} --zone ${VPCHOST_VM_ZONE} --project=${VPCHOST_PROJECT} -q
fi
gcloud compute instances create ${VPCHOST_VM_NAME} \
  --project=${VPCHOST_PROJECT} --zone=${VPCHOST_VM_ZONE} --machine-type=e2-micro \
  --network-interface=network-tier=PREMIUM,subnet=vpc1-europe-west2,no-address \
  --image-project=centos-cloud \
  --image-family=centos-7


export ONPREM_VM_IP=$(gcloud compute instances list \
                        --project=${ONPREM_PROJECT} \
                        --filter="NAME=${ONPREM_VM_NAME}" \
                        --format="csv(INTERNAL_IP)[no-heading]" \
                        --verbosity="error")
if [[ $(gcloud dns record-sets list \
          --zone=${VPCHOST_ZONE_NAME} \
          --project=${VPCHOST_PROJECT} | grep "service.${VPCHOST_ZONE_NAME}") ]]; then

  gcloud dns record-sets update "service.${VPCHOST_ZONE_NAME}" \
    --project=${VPCHOST_PROJECT} \
    --rrdatas=${ONPREM_VM_IP} \
    --ttl=300 \
    --type=A \
    --zone=${VPCHOST_ZONE_NAME}

else

  gcloud dns record-sets transaction start --zone=${VPCHOST_ZONE_NAME} --project=${VPCHOST_PROJECT}
  gcloud dns record-sets transaction add ${ONPREM_VM_IP} \
    --project=${VPCHOST_PROJECT} \
    --name="service.${VPCHOST_ZONE_NAME}" \
    --ttl=300 \
    --type=A \
    --zone=${VPCHOST_ZONE_NAME}
  gcloud dns record-sets transaction execute \
     --zone=${VPCHOST_ZONE_NAME} \
     --project=${VPCHOST_PROJECT}

fi

if [[ $(gcloud compute instances list \
        --project=${SERVICE_PROJECT} \
        --filter="NAME=${SERVICE_VM_NAME}" \
        --format="csv(NAME)[no-heading]" \
        --verbosity="error") ]]; then
    gcloud compute instances delete ${SERVICE_VM_NAME} --zone ${SERVICE_VM_ZONE} --project=${SERVICE_PROJECT} -q
fi
gcloud compute instances create ${SERVICE_VM_NAME} \
  --project=${SERVICE_PROJECT} --zone=${SERVICE_VM_ZONE} --machine-type=e2-micro \
  --network-interface=subnet=${SERVICE_SUBNET_NAME},no-address \
  --image-project=centos-cloud \
  --image-family=centos-7


cat >${SCRIPT_DIR}/nat-startup.sh<<'EOF'
#! /bin/bash

mkdir -p /opt/app

cat > /opt/app/server.py <<SEOF
import BaseHTTPServer
import SimpleHTTPServer


class Handler(SimpleHTTPServer.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write("Hello World".encode("utf-8"))
        return


if __name__ == "__main__":
    http_d = BaseHTTPServer.HTTPServer(("0.0.0.0", 8443), Handler)
    print "app is serving at port 8443"
    http_d.serve_forever()

SEOF

cat >/etc/systemd/system/health-check.service<<HEOF
[Unit]
Description="Health Check Service"
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/python /opt/app/server.py
User=root
Group=root
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=multi-user.target
HEOF

cat > /opt/app/nat.sh <<'NEOF'
#! /bin/bash

sleep 30

ip addr show eth1

while ! ip addr show eth1 | grep -q 'inet' ; do
  echo "waiting for network"
  sleep 5
done

ip addr show eth1

export SECONDARY_NIC_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/1/ip)
export SECONDARY_NIC_GW=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/1/gateway)

iptables -F
iptables -F -t nat

iptables -t nat -A POSTROUTING -d 172.16.0.0/18 -o eth1 -j SNAT --to-source ${SECONDARY_NIC_IP}
iptables -t nat -A POSTROUTING -d 172.16.0.0/18 -o eth1 -j LOG --log-prefix='natting'

ip route add to 172.16.0.0/18 via ${SECONDARY_NIC_GW} dev eth1

ip route

sysctl -w 'net.ipv4.conf.all.forwarding=1'
NEOF

chmod +x /opt/app/nat.sh

cat >/etc/systemd/system/nat.service<<NSEOF
[Unit]
Description="NAT Service"
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/app/nat.sh
User=root
Group=root
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=multi-user.target
NSEOF

systemctl enable health-check.service --now
systemctl enable nat.service --now


EOF

if [[ $(gcloud compute routes list \
          --project=${SERVICE_PROJECT} \
          --filter="name=${SERVICE_NAT_ROUTE_NAME}" \
          --format="csv(NAME)[no-heading]" \
          --verbosity="error") ]]; then
    gcloud compute routes delete ${SERVICE_NAT_ROUTE_NAME} --project=${SERVICE_PROJECT} -q
fi

if [[ $(gcloud compute forwarding-rules list \
          --project=${SERVICE_PROJECT} \
          --filter="name=${SERVICE_NAT_FR_NAME}" \
          --format="csv(NAME)[no-heading]" \
          --verbosity="error") ]]; then
    gcloud compute forwarding-rules delete ${SERVICE_NAT_FR_NAME} --project=${SERVICE_PROJECT} --region ${SERVICE_VM_REGION} -q
fi

if [[ $(gcloud compute backend-services list \
          --project=${SERVICE_PROJECT} \
          --filter="name=${SERVICE_NAT_BE_NAME}" \
          --format="csv(NAME)[no-heading]" \
          --verbosity="error") ]]; then
    gcloud compute backend-services delete ${SERVICE_NAT_BE_NAME} --project=${SERVICE_PROJECT} --region ${SERVICE_VM_REGION} -q
fi

if [[ $(gcloud compute instance-groups managed list \
          --project=${SERVICE_PROJECT} \
          --filter="NAME=${SERVICE_NAT_MIG_NAME}" \
          --format="csv(NAME)[no-heading]" \
          --verbosity="error") ]]; then
    gcloud compute instance-groups managed delete ${SERVICE_NAT_MIG_NAME} --project=${SERVICE_PROJECT} --region ${SERVICE_VM_REGION} -q
fi

if [[ $(gcloud compute health-checks list \
          --project=${SERVICE_PROJECT} \
          --filter="name=${SERVICE_NAT_HC_NAME}" \
          --format="csv(NAME)[no-heading]" \
          --verbosity="error") ]]; then
    gcloud compute health-checks delete ${SERVICE_NAT_HC_NAME} --project=${SERVICE_PROJECT} -q
fi

if [[ $(gcloud beta compute instance-templates list \
          --project=${SERVICE_PROJECT} \
          --filter="name=${SERVICE_NAT_TEMPLATE_NAME}" \
          --format="csv(NAME)[no-heading]" \
          --verbosity="error") ]]; then
    gcloud beta compute instance-templates delete ${SERVICE_NAT_TEMPLATE_NAME} --project=${SERVICE_PROJECT} -q
fi

gcloud beta compute instance-templates create ${SERVICE_NAT_TEMPLATE_NAME} \
  --project=${SERVICE_PROJECT} --machine-type=e2-micro \
  --network-interface=subnet=projects/${SERVICE_PROJECT}/regions/${SERVICE_VM_REGION}/subnetworks/${SERVICE_SUBNET_NAME},no-address \
  --network-interface=subnet=projects/${VPCHOST_PROJECT}/regions/${VPCHOST_VM_REGION}/subnetworks/vpc1-europe-west2,no-address \
  --can-ip-forward \
  --region=${SERVICE_VM_REGION} \
  --image-project=centos-cloud \
  --image-family=centos-7 \
  --metadata-from-file=startup-script=${SCRIPT_DIR}/nat-startup.sh

gcloud compute health-checks create tcp ${SERVICE_NAT_HC_NAME} \
  --project=${SERVICE_PROJECT} \
  --port 8443 \
  --check-interval 5 --healthy-threshold 1 --unhealthy-threshold 2

gcloud compute instance-groups managed create ${SERVICE_NAT_MIG_NAME} \
  --project=${SERVICE_PROJECT} \
  --size 1 \
  --template ${SERVICE_NAT_TEMPLATE_NAME} \
  --region ${SERVICE_VM_REGION} \
  --health-check ${SERVICE_NAT_HC_NAME} \
  --initial-delay 120

gcloud compute backend-services create ${SERVICE_NAT_BE_NAME} \
  --project ${SERVICE_PROJECT} \
  --load-balancing-scheme=internal \
  --protocol=tcp \
  --region=${SERVICE_VM_REGION} \
  --health-checks=${SERVICE_NAT_HC_NAME}

gcloud compute backend-services add-backend ${SERVICE_NAT_BE_NAME} \
  --project ${SERVICE_PROJECT} \
  --region=${SERVICE_VM_REGION} \
  --instance-group=${SERVICE_NAT_MIG_NAME} \
  --instance-group-region=${SERVICE_VM_REGION}

gcloud compute forwarding-rules create ${SERVICE_NAT_FR_NAME} \
  --project ${SERVICE_PROJECT} \
  --region=${SERVICE_VM_REGION} \
  --load-balancing-scheme=internal \
  --network=${SERVICE_VPC_NAME} \
  --subnet=${SERVICE_SUBNET_NAME} \
  --ip-protocol=TCP \
  --ports=ALL \
  --backend-service=${SERVICE_NAT_BE_NAME} \
  --backend-service-region=${SERVICE_VM_REGION}

gcloud compute routes create ${SERVICE_NAT_ROUTE_NAME} \
  --project ${SERVICE_PROJECT} \
  --destination-range=172.16.0.0/18 \
  --network=${SERVICE_VPC_NAME} \
  --next-hop-ilb=projects/${SERVICE_PROJECT}/regions/${SERVICE_VM_REGION}/forwardingRules/${SERVICE_NAT_FR_NAME}


