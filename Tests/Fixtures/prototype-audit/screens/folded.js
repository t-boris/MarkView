// Not a problem: a folded panel with a little text, and a menu hidden on purpose (aria-hidden) with a lot of it.
App.register({ id: 'folded', route: '/folded', render: function () {
  var menu = '';
  for (var i = 0; i < 30; i++) menu += '<li>Menu entry number ' + i + ' of the hidden list</li>';
  return '<h1>Settings overview</h1><p>Account, notifications and the connected brokers are configured here.</p>' +
    '<button type="button">Show details</button>' +
    '<div style="height:0;overflow:hidden">Details: the account is verified and trading is enabled.</div>' +
    '<ul aria-hidden="true" style="height:0;overflow:hidden">' + menu + '</ul>';
} });
