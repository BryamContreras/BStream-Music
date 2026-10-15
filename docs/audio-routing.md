# Salida de audio y transmisión

En el menú de los tres puntos del reproductor:

- **Salida de audio** muestra las salidas multimedia que expone el sistema y
  controla su volumen, no el volumen independiente del reproductor.
- **Transmitir a** busca receptores solo mientras está abierto. No busca equipos
  periódicamente en Inicio ni descarga la canción completa para transmitirla.

## Plataformas

Android 7+ admite selección preferente mediante el AudioTrack de Media3,
audífonos/cable/USB/Bluetooth según el hardware y el selector del sistema cuando
está disponible. Una preferencia no garantiza la ruta efectiva: la interfaz la
identifica como «Salida solicitada» cuando Android no puede confirmarla. No se
utiliza modo de llamada ni `setCommunicationDevice` para reproducir música.

Android transmite mediante Google Cast y DLNA/UPnP AVTransport. iOS usa el
selector público AirPlay y Google Cast. Apple no permite enumerar libremente
todas las salidas Bluetooth: la elección final se hace en su selector nativo.
DLNA/SSDP se deja deshabilitado en iOS porque requiere un entitlement multicast
restringido y aprobado por Apple; no se añade un permiso que rompa la firma.

Un equipo debe admitir el protocolo elegido y estar en la misma red. No todos
los televisores, bocinas o códecs son compatibles con todos los protocolos.
No se trata de duplicación de pantalla ni de Spotify Connect.

## Reproducción y consumo

Se conserva el reproductor local, la cola y la sesión multimedia existentes.
La salida remota toma control tras conectar y recibir la confirmación de carga;
el audio local se pausa antes de reproducir en el receptor. Pausa, búsqueda de
posición, siguiente/anterior y volumen mantienen un único reproductor lógico.
Una conexión o formato fallido devuelve la reproducción al dispositivo.

Google Cast recibe directamente el HTTPS del audio cuando no necesita cabeceras.
Si requiere cabeceras, es un archivo descargado o el receptor rechaza la URL,
se abre un relay HTTP de streaming limitado, sin transcodificar ni almacenar
una segunda copia. Usa rutas aleatorias de 256 bits, rangos HTTP y cancelación
de solicitudes; nunca expone directorios ni acepta URLs arbitrarias del receptor.
Se detiene al desconectar. Las credenciales no se envían en metadatos Cast.

En iOS no se garantiza streaming de archivos locales/URLs con cabeceras mediante
relay cuando el sistema suspende la app. HTTPS directo y AirPlay evitan esa
limitación; falta validación en un iPhone y un receptor físico.

## Referencias de diseño

Se revisaron las integraciones públicas de
[EchoMusic](https://github.com/EchoMusicApp/Echo-Music/blob/main/app/src/gms/kotlin/com/music/echo/playback/CastConnectionHandler.kt)
y [Metrolist](https://github.com/MetrolistGroup/Metrolist/blob/main/app/src/gms/kotlin/com/metrolist/music/playback/CastConnectionHandler.kt).
El código de esta integración es original. No se incorporó su reproductor ni se
cambió la versión Media3 fijada por BStream.

Documentación primaria:
[Google Cast, formatos](https://developers.google.com/cast/docs/media),
[salidas Android](https://developers.google.com/cast/docs/android_sender/output_switcher),
[privacidad de red Apple](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Verificación

Pruebas automatizadas de transporte, rangos/cancelación HTTP, SOAP DLNA,
concurrencia, cambios de canción, fallback local, volumen y tamaños de menú.
Prueba nativa de salidas/volumen y descubrimiento en el emulador Android.
No hay receptor físico disponible: descubrimiento vacío y simulaciones de
protocolo no sustituyen una prueba de audio real en Chromecast/TV/bocina.
La parte iOS requiere compilación y pruebas con Xcode; Windows no lo permite.

Los SDK Cast se fijan a Android 22.3.1 e iOS 4.8.0. La versión iOS preserva el
mínimo iOS 13; generaciones posteriores del SDK elevan ese mínimo. El SDK 4.8.0
no incluye simulador arm64, aunque sí dispositivos iOS arm64.
