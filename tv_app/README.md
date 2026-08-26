# Flux para webOS (televisores LG)

App independiente, en JavaScript, para ver desde el televisor la emisión que
sale de Movie Plus.

## Por qué no es la app de Flutter

Flutter no compila para webOS. Los televisores LG ejecutan apps web sobre su
propio runtime Chromium, empaquetadas en `.ipk`. Nada del código Dart se puede
reutilizar, así que esto es una app aparte que comparte el **protocolo**
aprendido, no el código.

Compilar Flutter Web y empaquetarlo tampoco valdría: iría lento en el hardware
de un televisor, no maneja la cruceta del mando, y perdería el escáner igual
que esta versión — porque el problema no es Flutter, es el navegador.

## Las tres limitaciones que definen esta versión

**1. No hay sockets crudos.** El escáner tipo nmap de la app de escritorio abre
conexiones TCP con timeout propio y 192 en paralelo. Aquí cada sondeo pasa por
el navegador. Se compensa barriendo menos y mejor elegido: primero lo
recordado, luego el puerto 4445 en toda la subred, y solo si eso falla otros
diez puertos.

**2. CORS.** Comprobado contra el servidor real: no manda
`Access-Control-Allow-Origin`. Desde JavaScript **no se pueden leer sus
cabeceras**, así que el nombre del episodio, el tamaño y la fecha no están
disponibles. De ahí que el sondeo tenga tres niveles:

| Nivel | Cómo | Qué da |
|---|---|---|
| 1 | `HEAD` leyendo cabeceras | Nombre, tamaño, fecha — solo si el runtime del televisor no aplica CORS a las apps empaquetadas |
| 2 | `fetch` en modo `no-cors` | Respuesta opaca e ilegible, pero que resuelva ya prueba que algo contestó por HTTP |
| 3 | Un `<video>` oculto | Reproducir no está sujeto a CORS: si dispara `loadedmetadata`, ahí hay video de verdad |

Si el nivel 1 funciona, se aprovecha; si no, se cae al 2 para barrer y al 3
para validar. No se da por supuesto: se comprueba en caliente.

**3. Un solo pipeline de medios.** Un televisor LG no puede tener dos `<video>`
decodificando a la vez. Abrir uno para vigilar mataría el que estás viendo. Por
eso, mientras se reproduce, el vigilante solo hace sondeos de nivel 2 y la
identidad del archivo se averigua con el elemento que ya está en uso, al
recargarlo.

## Cómo detecta el cambio de capítulo sin poder leer cabeceras

En escritorio la huella es nombre + tamaño + `Last-Modified`. Aquí no hay nada
de eso, así que **la huella es la duración exacta** que reporta el reproductor:
dos capítulos no duran lo mismo al milisegundo.

Funciona porque el servidor se cae al cambiar de capítulo — medido con un
monitor durante 40 minutos: entre 8 y 28 segundos sin responder. Esa caída es
la señal:

1. Sondeo barato cada 5 s. Al primer fallo, el ritmo sube a 1,2 s.
2. Dos fallos seguidos: "la emisión se detuvo".
3. Cuando vuelve, se recarga el mismo `<video>` y se compara la duración:
   igual → era el mismo capítulo, se reanuda donde ibas; distinta → capítulo
   nuevo, empieza de cero.

## Por qué el sondeo usa HEAD y no GET

Esto hizo que la app se cerrara sola en el televisor, y merece quedar escrito.

El sondeo de nivel 2 usaba `fetch` con `method: 'GET'`. La respuesta llega
opaca y no se puede leer... pero el navegador **sí se descarga el cuerpo**. Y
el cuerpo, aquí, es la película entera.

Medido contra un servidor de prueba que cuenta los bytes que llega a enviar: un
único sondeo que devolvía "listo" en 17 milisegundos se dejaba **59,3 MB** en
memoria por detrás. Y el vigilante sondea cada cinco segundos mientras
reproduces, así que en un minuto son unos 700 MB. Un PC lo absorbe sin
pestañear — por eso no apareció en las pruebas de escritorio — pero un
televisor no tiene ese presupuesto y webOS mata la app.

Con `HEAD` no hay cuerpo que descargar: los mismos doce sondeos mueven cero
bytes. El servidor de Movie Plus admite HEAD (se comprobó al principio de todo,
responde 200 con las cabeceras completas), y aunque algún servidor contestara
405, la respuesta opaca resuelve igual — que es lo único que se necesita saber
aquí: que hay alguien al otro lado.

Dos cosas más salieron del mismo hilo:

- **Al abrir el reproductor se corta la búsqueda.** El barrido enseña lo que
  encuentra sin esperar a terminar, así que al entrar al vídeo podía seguir
  habiendo decenas de sondeos en vuelo. En un PC no se nota; en un televisor
  compiten con el pipeline de medios justo en el arranque.
- **Cancelar aborta lo que ya salió**, no solo deja de lanzar peticiones
  nuevas. Medido: al cancelar, el contador se para en la tanda en vuelo en vez
  de seguir subiendo hasta 254.

## Números medidos, no supuestos

El sondeo tarda **2,5 segundos** y no 900 ms porque el servidor tarda entre 780
y 1430 ms en contestar — antes abre un MKV de 1,5 GB. Con 900 ms, el servidor
real respondía a los 877 ms: se salvaba por 23 milisegundos.

Barrer los 254 hosts lleva unos 15 segundos, pero el resultado no espera al
final: se valida sobre la marcha, así que el teléfono (que suele estar en una
IP baja) aparece en el primer segundo y ya puedes estar viendo el capítulo
mientras el resto de la red se sigue barriendo por detrás.

## Mando

| Tecla | Búsqueda | Reproductor |
|---|---|---|
| Cruceta ◀ ▶ | Moverse entre tarjetas | Saltar 10 s |
| Cruceta ▲ ▼ | Cambiar entre tarjetas y botones | Saltar 60 s |
| OK | Abrir / activar | Reproducir o pausar |
| ATRÁS | Salir de la app | Volver a la búsqueda |

También responden las teclas de medios del mando: reproducir, pausa, parar,
avance y retroceso rápidos.

## Probar sin televisor

```bash
node webos/dev-server.js
```

Abre `http://localhost:8123`. Hay que servirlo por HTTP: con `file://` el
navegador no aplica bien las hojas de estilo y bloquea `fetch`, así que el
descubrimiento no se puede probar.

Lo que **no** se puede comprobar en un navegador de escritorio:

- Reproducir MKV. Chrome no soporta Matroska; el televisor sí, porque delega
  en su pipeline de medios nativo.
- `PalmServiceBridge`, que es como se averigua la IP del televisor. Sin él la
  app avisa y ofrece escribir la dirección a mano.

## Empaquetar e instalar

```bash
ares-package webos --outdir build/webos
```

Con el modo desarrollador activado en el televisor y el Developer Mode app
abierto:

```bash
ares-setup-device
```

```bash
ares-install --device tv build/webos/com.aur.flux_1.0.0_all.ipk
```

```bash
ares-launch --device tv com.aur.flux
```

Para ver la consola mientras corre en el televisor:

```bash
ares-inspect --device tv --app com.aur.flux
```

## Estado

Verificado en navegador de escritorio contra el servidor real: el barrido de
los 254 hosts encuentra `192.168.1.5:4445` sin falsos positivos, la validación
sobre la marcha enseña el resultado antes de terminar el barrido, la
reproducción automática entra sola y la app degrada correctamente cuando no
hay puente Luna.

**Sin verificar todavía sobre un televisor**, que es donde se decide:

- Que el `<video>` de webOS reproduzca este MKV. Es el riesgo número uno: si
  el modelo no admite el códec del archivo, no hay nada que hacer desde la app.
- Si el runtime aplica CORS a las apps empaquetadas. Si no lo aplica, salen
  gratis los nombres de los episodios.
- Los subtítulos incrustados. En webOS se controlan con la API propia de LG,
  no con la estándar; esta versión todavía no los toca.
- Las teclas del mando, sobre el mando real.
