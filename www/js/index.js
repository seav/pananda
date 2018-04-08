var app = {
  // Application Constructor
  initialize: function() {
      document.addEventListener('deviceready', this.onDeviceReady.bind(this), false);
  },

  // deviceready Event Handler
  //
  // Bind any cordova events here. Common events are:
  // 'pause', 'resume', etc.
  onDeviceReady: function() {
    screen.orientation.lock('portrait');
    if (cordova.platformId == 'android') {
      StatusBar.backgroundColorByHexString("#123");
    }
  },
};

app.initialize();
