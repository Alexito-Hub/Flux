
var FluxConfig = {

  primaryPort: 4445,

  secondaryPorts: [
    4444, 4446, 4447, 4448, 4449,
    8080, 8081, 8888, 8000, 8008, 8090,
    5000, 5001, 9000, 3000, 1234, 12345,
    7000, 8200, 32469, 2020
  ],

  concurrency: 16,
  concurrencyWithAbort: 48,

  probeTimeout: 2500,

  videoProbeTimeout: 9000,

  watchInterval: 5000,
  watchRecoveryInterval: 1200,
  missesBeforeLost: 2,

  maxReconnectAttempts: 6,
  maxBackoffMs: 10000,

  seekStepSeconds: 10,
  bigSeekStepSeconds: 60,

  seekDebounceMs: 150,

  stallTimeout: 30000,

  storageKey: 'flux.webos.known',

  hostOrder: function () {
    var hosts = [];
    var i;
    for (i = 1; i <= 120; i++) { hosts.push(i); }
    for (i = 121; i <= 254; i++) { hosts.push(i); }
    return hosts;
  }
};
