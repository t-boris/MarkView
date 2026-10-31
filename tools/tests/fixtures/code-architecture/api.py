import json
import sqlite3
from http.server import BaseHTTPRequestHandler, HTTPServer
from repository import OrderRepository
from service import OrderService


class OrderHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/orders":
            self.send_error(404)
            return
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with sqlite3.connect("orders.db") as connection:
            service = OrderService(OrderRepository(connection))
            order_id = service.place_order(data["product"], data["quantity"])
        self.send_response(201)
        self.end_headers()
        self.wfile.write(json.dumps({"id": order_id}).encode())


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8080), OrderHandler).serve_forever()
