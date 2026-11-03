// The BUG-056 shape: the widget asks for height:100% of a host that has no height, so its flex body (flex:1 1 0; min-height:0;
// overflow:hidden) collapses to 0 px. The table is in the page and nothing throws, but none of it can be seen.
App.register({ id: 'chain', route: '/chain', render: function () {
  var rows = '';
  for (var i = 0; i < 60; i++) rows += '<tr><td>' + (5000 + i * 5) + '</td><td>Bid ' + i + '.25</td><td>Ask ' + i + '.50</td></tr>';
  return '<style>.chain{display:flex;flex-direction:column;height:100%}.chain-body{flex:1 1 0;min-height:0;overflow:hidden}</style>' +
    '<div class="chain"><div class="chain-bar">Option chain for SPX, expiry 10 Nov</div>' +
    '<div class="chain-body"><table><tr><th>Strike</th><th>Bid</th><th>Ask</th></tr>' + rows + '</table></div></div>';
} });
