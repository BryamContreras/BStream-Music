# Ecualizador

El ecualizador se abre desde **Ajustes > Reproducción** y desde el menú de los tres puntos de todos los estilos del reproductor. Ambas entradas utilizan la misma pantalla y configuración. Está desactivado inicialmente; seleccionar un preset lo activa y aplica la curva inmediatamente. Los controles manuales cambian el preset a Personalizado. Restablecer devuelve las bandas a cero y conserva el estado activado/desactivado.

Su acceso aparece primero en Reproducción. La pantalla separa el interruptor
en una tarjeta; los presets, las cinco barras y el restablecimiento comparten
la siguiente. El gráfico queda en la última tarjeta. Reutilizan las superficies
existentes del tema, sin añadir desenfoques ni animaciones continuas.

Las cinco bandas comparten un panel compacto con controles verticales. Cada barra muestra su ganancia y frecuencia, con una marca central de 0 dB. El texto grande conserva su tamaño y permite desplazar las bandas horizontalmente cuando no caben juntas.

Un gráfico inferior representa los ajustes sobre una escala de frecuencia logarítmica. Es una aproximación visual de las cinco bandas, no una medición del audio ni de la respuesta del dispositivo. Se pinta únicamente al cambiar ajustes, tema o tamaño, sin muestrear audio ni mantener animaciones activas.

## Curva y motores

La configuración compartida tiene cinco bandas: **60 Hz, 230 Hz, 910 Hz, 3.6 kHz y 14 kHz**, con ganancias de **−12 a +12 dB**. Las dieciséis categorías de presets están inspiradas en [BitChord](https://github.com/kushagrasinghx/BitChord) y adaptadas a estas cinco bandas; el procesamiento y la integración de BStream son propios.

- **Android:** `BStreamEqualizer` configura un DSP propio en la ruta PCM de Media3. Cada motor tiene cinco filtros biquad con Q=1 y estado independiente por canal. No utiliza `android.media.audiofx.Equalizer` ni depende de los efectos del fabricante. Los cambios de curva se suavizan durante 25 ms.
- **Windows, Linux y macOS:** `media_kit` configura el filtro nativo mpv/FFmpeg identificado como `@bstream-eq`. Las sustituciones y la desactivación solo modifican ese filtro y conservan los filtros de otras funciones.
- **iOS:** un DSP propio en C procesa PCM dentro de `MTAudioProcessingTap`, conservando `AVQueuePlayer`. Utiliza las mismas bandas, Q, headroom y transiciones de 25 ms, con estado separado por canal y motor. No envía muestras a Dart. Las rutas que no exponen PCM se indican como no disponibles; las preferencias se conservan. Consulta [la arquitectura de audio de iOS](ios_audio_processing.md).
- **Cast:** el ecualizador solo afecta al motor local y no procesa el audio remoto. Los controles se deshabilitan mientras se transmite y conservan la curva guardada para volver a la reproducción local.

En iOS, ecualizar y saltar silencios tienen comprobaciones de disponibilidad
separadas. Un recurso HTTP puede reproducirse y exponer PCM al ecualizador,
pero rechazar el `AVAssetReader` que necesita el análisis anticipado de
silencios. La prueba de WAV por HTTP recibió `AVFoundationErrorDomain / -11838`
(`OperationNotSupportedForAsset`), incluso con `readable=true`: en ese caso los
saltos se indican como no disponibles y se conserva la reproducción normal.
Esto no desactiva un ecualizador cuyo tap continúa entregando PCM. No se fuerza
una descarga completa ni un segundo transporte para habilitar los saltos.
Los detalles y el contrato de pruebas están en
[procesamiento de audio iOS](ios_audio_processing.md).

La curva se aplica al motor activo y al de reserva; un motor creado después recibe la configuración antes de hacerse audible. Así los fundidos y los cambios a una fuente de mayor calidad conservan el ajuste. Actualizar el ecualizador no vuelve a abrir la canción ni modifica su posición.

Se compensa el nivel con `−max(0, ganancias)` dB para reducir el riesgo de saturación al realzar bandas. En Android esta atenuación ocurre **dentro del DSP, antes de los filtros y de cuantizar la salida**. El volumen del motor sigue siendo el volumen del usuario multiplicado por la ganancia del fundido. En escritorio las bandas se procesan en punto flotante de doble precisión y la compensación se combina con el volumen nativo de cada motor; no requiere otro filtro de FFmpeg ni otra dependencia. Los realces pueden reducir el volumen percibido. El solapamiento de bandas y los transitorios aún pueden saturar picos extremos; esta compensación no sustituye un limitador. Apagado o con una curva plana, el efecto queda en **bypass** y se retira la compensación.

## Ruta PCM en Android

La app mantiene su mínimo de **Android 7.0 / API 24**. El procesador admite PCM de 16, 24 y 32 bits y float, con los formatos endian que acepta Media3. No añade decodificadores. Las bandas que alcanzan o superan Nyquist quedan sin filtro para no introducir resonancias en frecuencias diferentes; el margen de nivel permanece conservador.

La cadena habitual procesa primero la detección de silencio y Sonic, y después el ecualizador. Así la curva no altera las decisiones del detector de silencio. Media3 1.4.1 evita su cadena personalizada en determinadas salidas float de alta resolución: `BStreamEqualizerAudioSink` cubre esa ruta, conservando el formato, los canales y el número de frames. El bypass conserva los bytes de entrada; tras una transición activa termina primero el suavizado de 25 ms. Los filtros reutilizan sus buffers y reinician su historial al vaciar la ruta, buscar otra posición o cambiar de formato.

Los motores que registran el DSP deshabilitan offload y passthrough comprimido, incluso con la curva apagada. Esto mantiene una ruta PCM disponible para activar el efecto sin reiniciar la canción. Por ello no se promete el ahorro energético de un decodificador de audio por offload. No se transportan muestras PCM por los canales de Flutter ni se ecualiza en Dart.

## Estado y coste

`EqualizerSettings` contiene únicamente el interruptor y las cinco ganancias. `SettingsController` actualiza la interfaz inmediatamente y persiste el JSON en `SharedPreferences`, clave `settings.equalizer`, tras **400 ms** sin cambios; también vacía una escritura pendiente al liberar el controlador. El preset se deduce de la curva y no necesita otra preferencia.

Un único `equalizerRuntimeProvider` escucha los cambios y agrupa las actualizaciones nativas con **80 ms** de espera. Las escrituras se serializan y las revisiones antiguas no pueden reemplazar la curva actual. La pantalla comparte las superficies y los menús existentes, sin añadir filtros visuales continuos.

`BStreamEqualizer.configure()` envía una configuración completa por el canal existente del motor. Su respuesta y `readStatus()` incluyen las ganancias, formato PCM, headroom, revisiones y frames procesados. La revisión aplicada alcanza a la solicitada cuando termina el suavizado. El servicio contrasta las ganancias reconocidas, sin el redondeo de los efectos OEM. Los avisos de estado usan el mismo canal; no hay consultas periódicas ligadas al reloj de reproducción. Ante un fallo de configuración se intenta desactivar el DSP, se informa del error y se conserva la reproducción.

El coste activo consiste en cinco filtros por canal en código nativo y depende del dispositivo y del formato. No hay nuevas librerías nativas, hilos de Dart para muestras ni animaciones de audio en la pantalla. Bypass evita el cálculo de los filtros. Esto no equivale a una medición de consumo en todos los equipos.

## Verificación

Las pruebas JVM procesan PCM real y miden las bandas con DFT. Cubren ganancias, headroom, formatos, bypass exacto, fragmentación, aislamiento entre canales, reinicios, transiciones, Nyquist y la ruta float con contrapresión. También se ejecutan las pruebas existentes del detector de silencio:

```powershell
cd android
./gradlew.bat :just_audio:testDebugUnitTest
```

Las pruebas Flutter cubren modelo, persistencia, coordinación, fallos nativos, reintentos, revisiones, motores, fundidos y navegación compartida:

```powershell
flutter test test/services/player test/features/music/presentation/providers/equalizer_settings_test.dart test/features/music/presentation/providers/equalizer_runtime_test.dart test/features/music/presentation/widgets/equalizer_settings_page_test.dart
```

La integración móvil selecciona los dieciséis presets desde la pantalla real, pasa por el coordinador de ajustes y contrasta lecturas nativas frescas. En Android y en el simulador iOS de CI se comprobó que fluyen frames PCM, la revisión aplicada, bypass, restablecimiento, continuidad de posición, dos motores y la mejora de fuente con señales WAV locales. Estas pruebas validan el procesamiento y su integración; no son una medición acústica ni una certificación de todos los fabricantes y rutas de audio.

```powershell
flutter test integration_test/equalizer_native_test.dart -d windows
flutter test integration_test/equalizer_android_native_test.dart -d ANDROID_DEVICE_ID
flutter test integration_test/equalizer_ios_native_test.dart -d IOS_SIMULATOR_ID
flutter test integration_test/crossfade_native_test.dart -d ANDROID_DEVICE_ID
flutter test integration_test/skip_silence_native_test.dart -d ANDROID_DEVICE_ID
```

En Linux o macOS, la prueba de escritorio se ejecuta con `-d linux` o `-d macos`. Un runner de escritorio sin salida de audio puede añadir `--dart-define=BSTREAM_HEADLESS_AUDIO=true`. Linux y macOS requieren comprobación en sus propios hosts; esta documentación no afirma validación física allí.
