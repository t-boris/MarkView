import sqlite3


class OrderRepository:
    def __init__(self, connection: sqlite3.Connection):
        self.connection = connection

    def save(self, product, quantity, total):
        cursor = self.connection.execute(
            "INSERT INTO orders (product, quantity, total) VALUES (?, ?, ?)",
            (product, quantity, total),
        )
        self.connection.commit()
        return cursor.lastrowid
