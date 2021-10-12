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
