// The load callback never finishes, so the loading indicator stays.
App.register({ id: 'stuck', route: '/stuck', render: function () { return App.load(function () { return new Promise(function () {}); }); } });
