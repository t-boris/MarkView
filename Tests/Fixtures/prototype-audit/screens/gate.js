// A sign-in gate (BUG-064): everything it shows is also a label of the shell's header, yet it is a finished screen.
App.register({ id: 'gate', route: '/gate', render: function () {
  return '<section><h1>Gate</h1><a href="#/gate">Sign in</a></section>';
} });
