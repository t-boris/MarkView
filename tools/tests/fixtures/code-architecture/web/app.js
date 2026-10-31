export async function placeOrder(product, quantity) {
    const response = await fetch('/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ product, quantity }),
    });
    if (!response.ok) throw new Error('Order failed');
    return response.json();
}
