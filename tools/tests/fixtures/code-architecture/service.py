class OrderService:
    def __init__(self, repository):
        self.repository = repository

    def place_order(self, product, quantity):
        if quantity < 1:
            raise ValueError("Quantity must be positive")
        total = quantity * 10
        return self.repository.save(product, quantity, total)
