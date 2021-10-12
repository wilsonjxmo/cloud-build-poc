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


