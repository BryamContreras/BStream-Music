# BStream Music

BStream Music es un reproductor y gestor musical multiplataforma construido con Flutter. Permite buscar música, reproducirla, descargarla, organizar una biblioteca local y administrar playlists desde Android y Windows.

Versión actual: **1.1.9+119**.

> Este proyecto no incluye contenido multimedia ni binarios de terceros. El usuario es responsable de cumplir los derechos de autor, los términos de cada proveedor y las licencias de las herramientas que instale.

## Funciones principales

### Búsqueda, descargas y biblioteca

- Búsqueda de canciones con miniatura, título, artista/canal y duración.
- Reproducción remota y descarga de audio con progreso en tiempo real.
- Biblioteca local respaldada por SQLite.
- Reutilización de canciones ya descargadas para evitar descargas duplicadas.
- Filtrado, renombrado y eliminación de canciones guardadas.
- Creación, renombrado y eliminación de playlists.
- Playlist especial de **Favoritos**, con estrella visible en las canciones agregadas.
- Respaldo y restauración en ZIP de la base de datos, audios y miniaturas.

### Reproductor

- Play, pausa, anterior, siguiente, repetición y reproducción aleatoria.
- Cola de reproducción sincronizada con las playlists y la biblioteca.
- Panel lateral de cola en Windows y vista de cola dedicada en Android.
- Cambio de canción directamente desde la cola.
- La canción activa se destaca con un ecualizador segmentado de 13 barras.
- Fondo dinámico oscuro basado en la portada de la canción.
- Barra de progreso animada con ondas y color derivado de la portada.
- Control de volumen en Windows.
- Temporizador de apagado con duraciones rápidas y duración personalizada.
- Integración multimedia del sistema en Android.
- Manejo de canciones fallidas: un elemento que no puede descargarse o reproducirse no deja la cola bloqueada en la canción anterior.

### Interfaz

- Diseño adaptable para Android y Windows.
- Navegación que conserva únicamente las dos vistas recientes.
- Regreso desde el reproductor a la playlist o sección abierta previamente.
- Inicio con hasta 10 elementos recientes y 10 playlists.
- Gradientes sutiles, tarjetas translúcidas y controles visuales compartidos.
- Español e inglés desde Ajustes.
- Ventana de Windows con mínimo de `960 × 600` y reproductor que ajusta progresivamente portada, texto, espacios y controles según la altura disponible.
- Iconos generados desde una única fuente para Android, Windows, macOS y los recursos internos de Flutter.

## TikTok LIVE en Windows

La versión de Windows puede conectarse a un LIVE mediante un puente basado en `TikTokLive` y convertir comandos del chat en una cola musical temporal.

Funciones disponibles:

- Conexión mediante `@usuario` o `https://www.tiktok.com/@usuario/live`.
- Detección del usuario que solicitó cada canción.
- Identificación de moderadores.
- Permisos configurables para que los comandos funcionen para **Todos** o únicamente para **Moderadores**.
- Cola Live con estados de búsqueda, descarga, lista o fallida.
- Reutilización de canciones existentes en la biblioteca.
- Sincronización dinámica: los nuevos pedidos se agregan sin reemplazar la reproducción actual.
- Salto automático de solicitudes que fallen durante la descarga.

Comandos reconocidos:

```text
!play nombre de la canción
!skip
!next
!revoke
!stop
revoke!
```

`!play` busca el primer resultado, lo prepara y lo agrega a la cola. `!skip`/`!next` avanzan y `!revoke`/`!stop` limpian la cola Live.

La integración usa una librería no oficial. Si TikTok cambia su protocolo, el puente puede requerir una actualización.

## Plataformas y motores

| Plataforma | Reproductor | Descargas | Notas |
| --- | --- | --- | --- |
| Android | `just_audio` + `audio_service` | `youtubedl-android` | `minSdk 24`; FFmpeg llega como dependencia Gradle |
| Windows | `media_kit` | `yt-dlp` + FFmpeg | TikTok LIVE, cola lateral y herramientas externas |
| macOS | `media_kit` | `yt-dlp` + FFmpeg | Existe el scaffold; la versión 1.1.9 está enfocada y validada principalmente en Android/Windows |

## Arquitectura

La interfaz no depende directamente de SQLite, `yt-dlp`, `youtubedl-android` ni los motores de audio. La comunicación pasa por entidades, casos de uso, repositorios, providers y servicios intercambiables.

```text
lib/
  core/
    constants/
    errors/
    platform/
    utils/
  features/music/
    domain/
      entities/
      repositories/
      usecases/
    data/
      datasources/
      models/
      repositories/
    presentation/
      pages/
      providers/
      widgets/
  platform_channels/
  services/
    downloader/
    live/
    player/
    storage/
```

Los contratos principales son `DownloaderService`, `PlayerService` y `LibraryRepository`. Android usa canales de plataforma para las tareas nativas; Windows ejecuta herramientas locales mediante listas de argumentos y procesa sus salidas de forma asíncrona.

## Requisitos de desarrollo

- Flutter estable compatible con Dart `^3.12.0`.
- Android Studio y Android SDK para Android.
- Visual Studio/Build Tools con **Desktop development with C++** para Windows.
- Python 3.11–3.13 únicamente si se desarrolla o recompila el puente de TikTok.
- `yt-dlp` y FFmpeg para búsquedas y descargas en escritorio.

Comprueba el entorno con:

```powershell
flutter doctor -v
flutter pub get
```

## Ejecutar el proyecto

```powershell
flutter run -d windows
flutter run -d android
```

Para listar dispositivos disponibles:

```powershell
flutter devices
```

## Herramientas de Windows

Los binarios de terceros **no se guardan en Git**. Durante desarrollo puedes instalarlos en el `PATH` o colocarlos así:

```text
windows/tools/
  yt-dlp.exe
  ffmpeg.exe
  tiktok-live-bridge/
    tiktok_live_bridge.exe
    ...runtime generado...
```

También se reconoce `windows/tools/ffmpeg/bin/ffmpeg.exe`.

Instalación mediante `winget`:

```powershell
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg
```

Para una build portable de Windows, coloca versiones verificadas de `yt-dlp` y FFmpeg en `windows/tools` antes de compilar Release. CMake copiará las herramientas junto al ejecutable. En Debug se priorizan las herramientas del árbol del proyecto para evitar copiar o bloquear runtimes grandes en cada compilación.

## Puente de TikTok LIVE

En desarrollo, BStream puede ejecutar directamente:

```text
scripts/tiktok_live_bridge.py
```

La aplicación crea un entorno virtual automáticamente si no encuentra el puente empaquetado. También puedes prepararlo manualmente:

```powershell
py -3 -m venv .venv-tiktok
.\.venv-tiktok\Scripts\python.exe -m pip install -r scripts\requirements-tiktok.txt
```

Para generar el runtime portable que utiliza una build Release de Windows:

```powershell
.\scripts\build_tiktok_bridge.ps1 -Jobs 28
```

El resultado se escribe en `windows/tools/tiktok-live-bridge/`. Esa carpeta contiene Python, DLLs y dependencias compiladas, por lo que está excluida de Git y debe regenerarse localmente. El puente vigila el PID de BStream y se cierra si la aplicación termina, evitando procesos huérfanos y DLLs bloqueadas.

## Android

La integración nativa se encuentra en:

```text
lib/platform_channels/android_ytdl_channel.dart
android/app/src/main/kotlin/com/bstream/bstream_music/MainActivity.kt
```

Dependencias principales:

```kotlin
implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
```

`youtubedl-android` y FFmpeg se descargan mediante Gradle; no se agregan ejecutables manuales al repositorio.

### Firma de Release

Copia `android/key.properties.example` a `android/key.properties` y configura una llave fuera del repositorio:

```properties
storeFile=../release/bstream-upload-keystore.jks
storePassword=...
keyAlias=bstream
keyPassword=...
```

También se aceptan estas variables de entorno:

```powershell
$env:BSTREAM_ANDROID_STORE_FILE="D:\keys\bstream-upload-keystore.jks"
$env:BSTREAM_ANDROID_STORE_PASSWORD="..."
$env:BSTREAM_ANDROID_KEY_ALIAS="bstream"
$env:BSTREAM_ANDROID_KEY_PASSWORD="..."
```

`android/key.properties`, `*.jks` y `*.keystore` están excluidos de Git.

## Base de datos, favoritos y respaldos

- Android/macOS usan `sqflite`; Windows usa `sqflite_common_ffi`.
- Las migraciones son incrementales y conservan bibliotecas existentes.
- Favoritos se implementa como una playlist reservada (`bstream:favorites`), por lo que no requiere una tabla separada.
- El respaldo ZIP contiene la base de datos, `audio/`, `thumbnails/` y un manifiesto.
- La restauración valida rutas y límites del archivo antes de reemplazar los datos locales.

## Generar iconos

La fuente vive en `assets/icons/source/ico.png`. Para regenerar todas las variantes:

```powershell
.\scripts\generate_app_icons.ps1
```

El script produce los mipmaps de Android, el `.ico` de Windows, el AppIcon de macOS y las variantes de recursos Flutter.

## Compilar

```powershell
flutter build windows --release
flutter build apk --release
```

Artefactos habituales:

```text
build/windows/x64/runner/Release/bstream_music.exe
build/app/outputs/flutter-apk/app-release.apk
```

La versión se define en `pubspec.yaml` y el texto mostrado por la aplicación en `lib/core/constants/app_constants.dart`.

## Calidad

```powershell
dart format .
flutter analyze
flutter test
```

La suite actual incluye pruebas de modelos, casos de uso, servicios, temporizador, permisos de TikTok, navegación, favoritos, cola, adaptación móvil y reproductor de Windows en su tamaño mínimo.

## Archivos que no se publican

El repositorio excluye deliberadamente:

- Builds, APK, EXE y paquetes de distribución.
- `yt-dlp`, FFmpeg y sus carpetas auxiliares.
- Runtime compilado del puente de TikTok.
- Entornos virtuales y cachés de Python.
- Claves de firma, contraseñas y archivos locales de Android.
- Bases de datos, música descargada, miniaturas y respaldos del usuario.
