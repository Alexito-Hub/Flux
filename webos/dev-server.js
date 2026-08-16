/* Servidor estático mínimo para probar la app del televisor en un navegador de
 * escritorio, sin tener que empaquetar e instalar en la TV a cada cambio.
 *
 *   node webos/dev-server.js     →  http://localhost:8123
 *
 * Servir por HTTP y no abrir el index.html con file:// no es un capricho: con
 * `file://` el navegador trata cada archivo como origen opaco, no aplica bien
 * las hojas de estilo y bloquea `fetch`, así que el descubrimiento no se puede
 * probar. Con un origen http:// el comportamiento se parece al del televisor.
 *
 * Lo que NO se puede probar en un navegador de escritorio:
 *   - Reproducir MKV. Chrome no soporta Matroska; el televisor sí, porque
 *     delega en su pipeline de medios nativo.
 *   - `PalmServiceBridge`, que es como se averigua la IP del televisor. Sin él
 *     la app avisa y ofrece escribir la dirección a mano.
 */
var http = require('http');
var fs = require('fs');
var path = require('path');

var root = __dirname;
var port = process.env.PORT ? parseInt(process.env.PORT, 10) : 8123;

var types = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png'
};

http.createServer(function (req, res) {
  var relative = decodeURIComponent(req.url.split('?')[0]);
  if (relative === '/') { relative = '/index.html'; }

  var target = path.join(root, path.normalize(relative));
  // Nadie sale de la carpeta de la app por mucho ../ que ponga.
  if (target.indexOf(root) !== 0) {
    res.writeHead(403);
    res.end('Prohibido');
    return;
  }

  fs.readFile(target, function (error, data) {
    if (error) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('No encontrado: ' + relative);
      return;
    }
    res.writeHead(200, {
      'Content-Type': types[path.extname(target)] || 'application/octet-stream',
      'Cache-Control': 'no-store'
    });
    res.end(data);
  });
}).listen(port, function () {
  console.log('Flux webOS servido en http://localhost:' + port);
});
