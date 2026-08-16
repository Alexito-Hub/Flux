
var FluxConfig = {

  primaryPort: 4445,

  secondaryPorts: [4444, 4446, 8080, 8888, 8000, 5000, 9000, 8090, 1234, 12345],

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
