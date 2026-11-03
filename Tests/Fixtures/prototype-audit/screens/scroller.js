// Not a problem: the same long table in a box with a definite height that scrolls (what the clipped check must leave alone).
App.register({ id: 'scroller', route: '/scroller', render: function () {
  var rows = '';
  for (var i = 0; i < 60; i++) rows += '<tr><td>' + (5000 + i * 5) + '</td><td>Bid ' + i + '.25</td><td>Ask ' + i + '.50</td></tr>';
  return '<h1>Chain</h1><div style="height:200px;overflow:auto"><table><tr><th>Strike</th><th>Bid</th><th>Ask</th></tr>' + rows + '</table></div>';
} });
