# Ecualizador

El ecualizador se abre desde **Ajustes > Reproducción** y desde el menú de los tres puntos de todos los estilos del reproductor. Ambas entradas utilizan la misma pantalla y configuración. Está desactivado inicialmente; seleccionar un preset lo activa y aplica la curva inmediatamente. Los controles manuales cambian el preset a Personalizado. Restablecer devuelve las bandas a cero y conserva el estado activado/desactivado.

Su acceso aparece primero en Reproducción. El interruptor tiene su propia tarjeta;
los presets, incluido Personalizado, aparecen en una fila con desplazamiento
horizontal encima de las bandas, con botones de tamaño uniforme, bordes del
acento y el mismo degradado de selección que las categorías de búsqueda.
Las diez barras aprovechan todo el ancho,
sin una tarjeta alrededor, y el botón de restablecer queda independiente debajo.
Reutiliza el fondo de las pestañas de navegación
y los colores y superficies compartidos del tema.

Personalizado conserva la última curva manual al elegir otros presets y al
reiniciar la app. La curva guardada y el preset seleccionado se persisten junto
con el ajuste activo, en la misma preferencia y con el mismo guardado agrupado.
Los motores nativos reciben únicamente los valores de la curva activa.

Las diez bandas comparten un panel más alto con controles verticales. En móvil
se distribuyen en una sola fila de diez con líneas y tiradores delgados; el
botón de restablecer aparece debajo de las barras. Las barras tienen más
altura y se adaptan al espacio disponible. Cada barra muestra su
ganancia y frecuencia, con una marca central de 0 dB y una leyenda común de dB.
El texto ampliado conserva su tamaño y permite desplazamiento cuando hace falta.

La cuadrícula y un trazo interpolado tenue se dibujan detrás de las barras,
alineados con sus posiciones de ganancia. Sustituyen la gráfica inferior y
sirven como referencia visual de los ajustes, sin medir el audio ni la respuesta
del dispositivo. Solo se repintan al cambiar las ganancias, el tema o el tamaño,
sin muestrear audio ni mantener animaciones activas.

## Curva y motores

La configuración compartida tiene diez bandas: **31 Hz, 62 Hz, 125 Hz, 250 Hz, 500 Hz, 1 kHz, 2 kHz, 4 kHz, 8 kHz y 16 kHz**, con ganancias de **−12 a +12 dB**. Las dieciséis categorías de presets están inspiradas en [BitChord](https://github.com/kushagrasinghx/BitChord); las curvas, el procesamiento y la integración de BStream son propios.

Los presets definen ahora diez ganancias explícitas mediante listas constantes,
en pasos de 0.5 dB y con ajustes iniciales entre −5 y +5 dB. No se generan
interpolando cinco controles. Los perfiles de voz concentran su presencia en
1–4 kHz; Altavoces pequeños atenúa 31/62 Hz y concentra su realce en 250/500 Hz.
Son puntos de partida de balance tonal, no una corrección de un altavoz concreto
ni un compresor de volumen. Noche también cambia el balance tonal sin comprimir
el rango dinámico. Las curvas guardadas de cinco bandas se siguen migrando sin
reemplazarlas por las nuevas: cuando ya no coinciden con un preset aparecen como
Personalizado. Las curvas guardadas de diez bandas conservan sus valores.

- **Android:** `BStreamEqualizer` configura un DSP propio en la ruta PCM de Media3. Cada motor tiene diez filtros biquad con Q=1 y estado independiente por canal. No utiliza `android.media.audiofx.Equalizer` ni depende de los efectos del fabricante. Los cambios de curva se suavizan durante 25 ms.
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

Se compensa el nivel según una estimación de la respuesta combinada de los realces: con una sola banda positiva se reserva exactamente su ganancia; con varias se evalúan 257 puntos logarítmicos y los diez centros, se añade un margen de 0.1 dB y se limita la atenuación a la suma de las ganancias positivas. Los cortes se ignoran en esta estimación conservadora. El cálculo ocurre una vez por configuración, nunca por muestra. En Android e iOS esta atenuación ocurre **dentro del DSP, antes de los filtros y de cuantizar la salida**. El volumen del motor sigue siendo el volumen del usuario multiplicado por la ganancia del fundido. En escritorio las bandas se procesan en punto flotante de doble precisión y la compensación se combina con el volumen nativo de cada motor; no requiere otro filtro de FFmpeg ni otra dependencia. Los realces pueden reducir el volumen percibido. La estimación no sustituye un limitador ni garantiza evitar todos los picos transitorios. Apagado o con una curva plana, el efecto queda en **bypass** y se retira la compensación.

## Ruta PCM en Android

La app mantiene su mínimo de **Android 7.0 / API 24**. El procesador admite PCM de 16, 24 y 32 bits y float, con los formatos endian que acepta Media3. No añade decodificadores. Las bandas que alcanzan o superan Nyquist quedan sin filtro para no introducir resonancias en frecuencias diferentes; el margen de nivel permanece conservador.

La cadena habitual procesa primero la detección de silencio y Sonic, y después el ecualizador. Así la curva no altera las decisiones del detector de silencio. Media3 1.4.1 evita su cadena personalizada en determinadas salidas float de alta resolución: `BStreamEqualizerAudioSink` cubre esa ruta, conservando el formato, los canales y el número de frames. El bypass conserva los bytes de entrada; tras una transición activa termina primero el suavizado de 25 ms. Los filtros reutilizan sus buffers y reinician su historial al vaciar la ruta, buscar otra posición o cambiar de formato.

Los motores que registran el DSP deshabilitan offload y passthrough comprimido, incluso con la curva apagada. Esto mantiene una ruta PCM disponible para activar el efecto sin reiniciar la canción. Por ello no se promete el ahorro energético de un decodificador de audio por offload. No se transportan muestras PCM por los canales de Flutter ni se ecualiza en Dart.

## Estado y coste

`EqualizerSettings` contiene únicamente el interruptor y las diez ganancias. `SettingsController` actualiza la interfaz inmediatamente y persiste el JSON en `SharedPreferences`, clave `settings.equalizer`, tras **400 ms** sin cambios; también vacía una escritura pendiente al liberar el controlador. Las curvas guardadas con cinco bandas se migran por interpolación logarítmica a las diez frecuencias actuales; el estado activado se conserva. El preset se deduce de la curva y no necesita otra preferencia.

Un único `equalizerRuntimeProvider` escucha los cambios y agrupa las actualizaciones nativas con **80 ms** de espera. Las escrituras se serializan y las revisiones antiguas no pueden reemplazar la curva actual. La pantalla comparte las superficies y los menús existentes, sin añadir filtros visuales continuos.

`BStreamEqualizer.configure()` envía una configuración completa por el canal existente del motor. Su respuesta y `readStatus()` incluyen las ganancias, formato PCM, headroom, revisiones y frames procesados. La revisión aplicada alcanza a la solicitada cuando termina el suavizado. El servicio contrasta las ganancias reconocidas, sin el redondeo de los efectos OEM. Los avisos de estado usan el mismo canal; no hay consultas periódicas ligadas al reloj de reproducción. Ante un fallo de configuración se intenta desactivar el DSP, se informa del error y se conserva la reproducción.

El coste activo consiste en diez filtros por canal en código nativo y depende del dispositivo y del formato. No hay nuevas librerías nativas, hilos de Dart para muestras ni animaciones de audio en la pantalla. Bypass evita el cálculo de los filtros. Esto no equivale a una medición de consumo en todos los equipos.

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

## Medición reproducible de rendimiento

Los benchmarks se ejecutan aparte de la app distribuida. Las comparaciones
antes/después utilizan **el mismo banco nuevo de dieciséis presets**: retocar
las curvas antes de medir evita confundir una curva diferente con una mejora
del motor. El exportador mantiene los fixtures alineados con el modelo real:

```powershell
dart run tool/benchmarks/export_equalizer_presets.dart --json .dart_tool/eq-presets-ten.json
dart run tool/benchmarks/export_equalizer_presets.dart .dart_tool/eq-presets-final.txt
```

El formato JSON alimenta el benchmark Android y el texto alimenta el DSP
portable en C. Ambos leen directamente las mismas definiciones de
`EqualizerPreset`, sin mantener otro banco manual de ganancias. Sin ruta de
salida el exportador imprime el formato elegido en stdout.

La medición Android usa `app_process` sobre ART y las clases de producción de
Media3; no es una simulación del procesador en Dart ni una medición JVM en el
PC. Cubre PCM estéreo de 16 bits y float32 a 48/96 kHz, apagado/plano, cada una
de las diez bandas a ±6 dB, ajustes combinados, todos los presets y cambios
repetidos cada 80 ms. Aplica calentamiento global y por caso, orden de escenarios
reproducible y varias repeticiones. El detalle de ejecución está en
[el benchmark Android](../tool/benchmarks/android/README.md).

`tool/benchmarks/equalizer_dsp_benchmark.c` mide el mismo DSP portable en C
utilizado por iOS, compilado con optimización para el host indicado en el
reporte. Usa los mismos tipos y frecuencias de muestreo, bandas individuales,
curvas combinadas, presets y una transición inicial. Ejecutar ese código en
un emulador Android valida su coste allí; no equivale a medir un iPhone ni el
coste adicional de `MTAudioProcessingTap`.

Ambos benchmarks nativos informan CPU en **milisegundos por segundo de audio**.
Dividir ese valor entre diez da una fracción porcentual equivalente de un núcleo
para ese trabajo. No representa el consumo de CPU de toda la app ni batería.
Android registra el p95 de llamadas individuales de bloques de 10 ms; C informa
el p95 entre lotes promediados por bloque. Esos percentiles tienen poblaciones
distintas y no deben compararse como latencias equivalentes. Los contadores
Android de asignación y GC son globales de ART durante la ventana medida;
incluyen posibles actividades de JIT o instrumentación.

`integration_test/equalizer_performance_test.dart` mide en Windows el proceso
completo del runner Flutter en modo profile mientras mpv reproduce WAV local
con salida `null` y volumen cero. Incluye tres repeticiones de seis escenarios
por frecuencia, con ventanas de tres segundos, y comprueba que la posición
avanza. `GetProcessTimes` suma CPU de usuario y kernel de todos sus hilos;
la conversión FFI de `FILETIME` conserva sus unidades de 100 ns. La medición
incluye el motor Flutter, decodificación y tareas del proceso, sin la interfaz
musical ni red. Los tiempos de configuración cubren actualizar el filtro
nativo, no toda la latencia del botón o la persistencia de ajustes. Las ventanas
cortas pueden ser ruidosas y estar cuantizadas: que un escenario quede por
encima de otro no demuestra por sí solo el coste incremental del ecualizador.

El resumen se genera con
`tool/benchmarks/summarize_equalizer_benchmarks.py`. Valida que ambas versiones
tengan los mismos casos, formatos, duración y hashes antes de calcular sus
diferencias. El consumidor Android incorpora tres palabras de cada bloque a
su checksum; C verifica el buffer completo y consistencia entre repeticiones.
Apagado/plano además comprueban que el bypass conserve los bytes. Los hashes
se comparan dentro de cada motor y fixture, no entre los dos benchmarks.
Estos controles acompañan las pruebas de respuesta de frecuencia y transiciones;
ninguno sustituye una medición de energía en dispositivos físicos.

### Resultados de la comparación

La comparación final utilizó un emulador Android API 37, x86_64, en un host
Intel Core i7-14700K. Cada caso nativo incluye siete repeticiones con
calentamiento. Los datos completos, incluidos percentiles, asignaciones,
comprobaciones de integridad y Windows, están en
[equalizer-results.json](benchmarks/equalizer-results.json).

Ejemplos a 48 kHz, estéreo y float32, en **ms de CPU por segundo de audio**:

| Procesador y ajuste | Antes | Después | Resultado |
| --- | ---: | ---: | --- |
| Android, banda de 1 kHz a +6 dB | 2.145 | 1.004 | 53% menos CPU |
| Android, las diez bandas a +6 dB | 2.127 | 2.089 | Coste similar |
| DSP C, banda de 1 kHz a +6 dB | 1.158 | 0.380 | 67% menos CPU |
| DSP C, las diez bandas a +6 dB | 1.123 | 1.145 | Coste similar |

Al agrupar las diez bandas individuales con cortes y realces, el ahorro
mediano fue de aproximadamente **48–55% en Android** y **62–66% en C**, según
formato y frecuencia. La ruta densa conserva el kernel original. La ruta para
pocas bandas omite secciones neutras únicamente cuando su historial permite
hacerlo, y conserva las colas, los ceros IEEE y los cambios suaves de 25 ms.

Los 176 casos Android y 168 casos C conservaron sus respectivos checksums.
En Android se midieron 369600 bloques; ninguno alcanzó los 10 ms de duración
de un bloque de audio. El mayor p95 observado fue de 82.637 microsegundos.
Esto mide ejecución del DSP en el benchmark; no demuestra ausencia de cortes
del reproductor en todos los dispositivos o situaciones de carga.

Los cambios continuos de ajustes añaden trabajo de configuración. En la
comparación final, los casos PCM16 con cambios cada 80 ms aumentaron entre
aproximadamente 6% y 8% respecto al baseline, aunque el peor caso mediano
permaneció en 5.41 ms de CPU por segundo de audio (aproximadamente 0.54% de
un núcleo equivalente). La mejora de curvas dispersas no implica que todas
las combinaciones reduzcan su consumo.

En Windows, las ventanas del proceso completo fluctuaron aproximadamente
entre 0.5% y 3.1% de un núcleo en sus medianas por caso. Su cuantización y
variación no permiten atribuir un coste incremental fiable al ecualizador;
por ello no se presenta una reducción de CPU para mpv.

Los benchmarks y sus dependencias de desarrollo quedan fuera de la app
distribuida. Estas cifras no representan consumo de batería ni una medición
física de iOS, Linux o macOS. En particular, Android conserva la ruta PCM sin
offload descrita anteriormente, incluso cuando la curva está apagada.
