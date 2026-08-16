/* Parámetros del descubrimiento en el televisor.
 *
 * Los números no son los mismos que en la app de escritorio y no pueden serlo:
 * allí se abren sockets TCP crudos con timeout propio y caben 192 en paralelo.
 * Aquí cada sondeo es una petición del navegador, Chromium limita el total de
 * conexiones y en webOS 4 ni siquiera se pueden cancelar. Así que se sondea
 * menos y mejor elegido. */
var FluxConfig = {

  /* Puerto de Movie Plus. Va solo en la primera pasada: 254 sondeos es lo
   * máximo razonable en un TV, y este puerto cubre el caso real. */
  primaryPort: 4445,

  /* Segunda pasada, solo si la primera no encontró nada. */
  secondaryPorts: [4444, 4446, 8080, 8888, 8000, 5000, 9000, 8090, 1234, 12345],

  /* Cuántos sondeos a la vez. En webOS 4 las peticiones no se pueden abortar,
   * así que las que caen en una IP vacía siguen ocupando socket hasta que el
   * sistema se rinde. Con 16 el navegador nunca se queda sin ranuras. */
  concurrency: 16,
  concurrencyWithAbort: 48,

  /* Tiempo que se espera a cada sondeo.
   *
   * Aquí no se mide lo mismo que en la app de escritorio. Allí se abre un
   * socket TCP crudo y un dispositivo vivo contesta en decenas de
   * milisegundos. Aquí el sondeo es una petición HTTP entera, y este servidor
   * tarda en responder porque antes abre un MKV de 1,5 GB: medido, entre 780 y
   * 1430 ms. Con el 900 ms que parecía razonable, el servidor real respondía a
   * los 877 ms — es decir, se salvaba por 23 ms y en cuanto se despistara no
   * aparecería en la lista.
   *
   * Además, un puerto cerrado tampoco falla rápido a través de fetch: agota el
   * plazo igual que una IP vacía. Así que este número marca el ritmo del
   * barrido entero, y por eso la concurrencia sube para compensar. */
  probeTimeout: 2500,

  /* Validar con <video> es caro (abre el pipeline de medios del televisor),
   * así que solo se hace sobre los pocos puertos que respondieron. */
  videoProbeTimeout: 9000,

  /* Seguimiento de la emisión, igual que en la app de escritorio. */
  watchInterval: 5000,
  watchRecoveryInterval: 1200,
  missesBeforeLost: 2,

  /* Reintentos del reproductor ante un corte. Medido sobre el servidor real:
   * al cambiar de capítulo se cae hasta medio minuto. */
  maxReconnectAttempts: 6,
  maxBackoffMs: 10000,

  /* Salto de los botones de avance/retroceso del mando. */
  seekStepSeconds: 10,
  bigSeekStepSeconds: 60,

  /* Milisegundos de debounce para el seek: toques rápidos del mando se
   * acumulan en este intervalo y se lanzan como un solo salto. */
  seekDebounceMs: 150,

  /* Si el reproductor lleva este tiempo (ms) sin avanzar ni un fotograma,
   * se da la conexión por muerta. Con reconexión no destructiva se puede
   * ser más paciente que antes (era 22 s hardcodeado) porque reanudar no
   * destruye el búfer. */
  stallTimeout: 30000,

  storageKey: 'flux.webos.known',

  /* Orden de barrido: los routers domésticos reparten DHCP desde el principio
   * del rango, así que las IPs bajas se prueban primero. No cambia el total,
   * pero adelanta el hallazgo varios segundos en el caso normal. */
  hostOrder: function () {
    var hosts = [];
    var i;
    for (i = 1; i <= 120; i++) { hosts.push(i); }
    for (i = 121; i <= 254; i++) { hosts.push(i); }
    return hosts;
  }
};
