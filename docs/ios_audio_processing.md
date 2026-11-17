# Procesamiento de audio en iOS

iOS comparte los controles, los ajustes persistidos, las cinco bandas y los
dieciséis presets con Android y escritorio. No se añade otro reproductor:
`just_audio` conserva `AVQueuePlayer`, las sesiones de audio, el bloqueo de
pantalla, los fundidos y las mejoras de fuente. El mínimo de la app sigue siendo
iOS 13. El salto de silencios permanece desactivado de forma predeterminada.

## Ecualizador

`BStreamEqualizer` implementa `DarwinAudioEffect`; su configuración viaja en el
campo existente `darwinAudioEffects`. La capa nativa recibe una curva completa
por el canal del motor y la aplica tanto al reproductor activo como al de
reserva. Cambiar un preset conserva el elemento y su posición.

Cada elemento encolado recibe un único `MTAudioProcessingTap`. La reproducción
espera la instalación inicial del mix, con salida normal si falla o agota su
tiempo. Los siguientes cambios actualizan parámetros atómicos. El callback de
audio no toma bloqueos, no asigna memoria y no llama a Dart. Los buffers y el
historial se preparan fuera del procesamiento de muestras.

El núcleo C utiliza cinco biquads Q=1, frecuencias de 60, 230, 910, 3600 y
14000 Hz, ganancias de −12 a +12 dB y transiciones de 25 ms. Aplica
`−max(0, ganancias)` dB antes de los filtros. Esta compensación reduce la
saturación; no es un limitador para curvas extremas. Las bandas que alcanzan
Nyquist quedan sin filtro. El volumen y las ganancias de fundido se conservan.

Se admiten float32/64 y PCM16/32 nativos, planos o intercalados, hasta ocho
canales, con empaquetado validado. Apagado o plano, el núcleo preserva los
bytes originales tras completar una transición pendiente. Un formato no
admitido conserva el audio y comunica que el procesamiento no está disponible.
La disponibilidad no depende solo de instalar el mix: también se comprueba que
el motor entregue PCM cuando avanza la reproducción.

## Saltos de silencios

El [contrato del tap de Apple](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtapprocesscallback)
exige conservar los frames; devolver menos genera silencio de relleno. Por eso
iOS no copia el descarte de PCM de Media3. `BStreamSilenceAnalyzer` utiliza un
`AVAssetReader` nativo para confirmar intervalos por adelantado y programa
saltos exactos en el reloj original de `AVPlayerItem`.

El detector examina ventanas de 100 ms cada 25 ms, suaviza potencia durante
250 ms, entra a −52 dBFS y sale a −46 dBFS. Exige un 90 % de votos silenciosos,
un tramo de protección de 800 ms y un veto de picos de magnitud 64 en escala
PCM16. Una entrada real del archivo necesita 1,8 s; los demás tramos necesitan
4,5 s. Se conservan 150 ms antes y 250 ms después, con fundidos de 20 ms.
Los saltos o límites de una ventana de análisis no se tratan como finales de
archivo. Las pausas musicales, las colas de reverberación y los canales con
instrumentación tenue quedan protegidos por estas reglas.

Solo se analiza con la opción activada. Cada petición alcanza como máximo
12 segundos por delante; en fuentes remotas también se limita al buffer
contiguo disponible. Las extensiones se agrupan para evitar abrir un lector
en cada tick. El hint de buffer se aumenta a 12 s mientras se utiliza y se
restaura al desactivar. No se exige descargar o analizar toda la canción.

Una caché de hasta 32 entradas comparte los intervalos y la cobertura. Los
archivos se identifican por URL y versión; los recursos remotos comparten por
identidad del asset, sin mezclar cabeceras o credenciales de URLs iguales.
Solo existe un lector serial por entrada. Desactivar, retirar un elemento o
cambiar la cola cancela el trabajo que ya no tiene usuarios. Este enfoque
añade decodificación opcional al activar los saltos; no promete el mismo coste
que eliminar PCM dentro del motor Android.

Los saltos tienen guardas de identidad y generación. Pausar, buscar, cambiar
de pista o desactivar la opción invalida operaciones anteriores. Los fallos de
seek tienen espera entre reintentos y comunican indisponibilidad si persisten.
No se cambia el volumen del usuario ni se publica un evento Dart por cada
ventana de análisis. Los saltos confirmados actualizan la posición nativa para
mantener los fundidos y el cambio de calidad en el mismo reloj.

## Disponibilidad y validación

HLS/directos, contenido protegido, fuentes no legibles y assets con varias
pistas de audio no se presentan como compatibles. La reproducción normal
continúa. La interfaz muestra la disponibilidad del audio actual y conserva
la preferencia para la siguiente fuente compatible. Cast y la reproducción
externa no se presentan como audio procesado localmente. El lector respeta
las [limitaciones de AVAssetReader](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/05_Export.html).

El núcleo se verifica con señales PCM y DFT, bypass exacto, formatos, canales,
transiciones y secuencias musicales/silenciosas. Puede compilarse sin APIs de
Apple:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  -Ithird_party/just_audio/darwin/just_audio/Sources/just_audio/include/just_audio \
  test/native/bstream_audio_dsp_test.c \
  third_party/just_audio/darwin/just_audio/Sources/just_audio/BStreamAudioDSP.c \
  -lm -o /tmp/bstream-audio-dsp-test
/tmp/bstream-audio-dsp-test
```

La integración usa los mismos escenarios en Android e iOS: todos los presets,
ajustes manuales, bypass, reanudación, dos motores y mejora de fuente. La suite
de silencios comprueba pausas musicales, fundidos, CDN lento y búsquedas hacia
atrás. Su ejecución iOS requiere un Mac con Xcode y un simulador disponible:

```sh
flutter test integration_test/equalizer_ios_native_test.dart -d IOS_SIMULATOR_ID
flutter test integration_test/skip_silence_native_test.dart -d IOS_SIMULATOR_ID
flutter test integration_test/crossfade_native_test.dart -d IOS_SIMULATOR_ID
```

El job `ios-native` del workflow nocturno selecciona un simulador disponible y
ejecuta estos escenarios. Tener la prueba configurada no equivale a haberla
ejecutado: la compilación de AVFoundation y la ejecución del simulador no se
pueden validar desde un host Windows.
