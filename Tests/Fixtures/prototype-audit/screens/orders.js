App.register({ id: 'orders', route: '/orders', render: function () {
  return App.load(function () { return '<h1>Orders</h1><table><tr><th>No</th><th>Total</th></tr><tr><td>1001</td><td>42.50</td></tr></table>'; });
} });
