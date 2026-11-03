// The load callback fails, so the screen ends in the error card.
App.register({ id: 'risky', route: '/risky', render: function () { return App.load(function () { throw new Error('boom'); }); } });
