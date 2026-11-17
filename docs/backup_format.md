# Respaldos ZIP de la biblioteca

La exportación conserva SQLite y las miniaturas e incluye una sola copia de
cada archivo de audio. No descarga canciones de catálogo que todavía no están
guardadas en la biblioteca ni vuelve a leer sus etiquetas. El diseño se calcula
desde los datos guardados y una instantánea de los archivos.

Cuando hay playlists con canciones descargadas, el ZIP organiza el audio así:

```text
database/bstream_music.db
manifest.json
audio-index.json
audio/
  Mi playlist/
    Canción A.mp3
    Canción B.m4a
    playlist.m3u8
  Otra playlist/
    Canción C.mp3
    playlist.m3u8
  Canciones descargadas/
    Canción sin playlist.mp3
thumbnails/
```

El nombre real del archivo SQLite es `AppConstants.databaseName`. La carpeta
de canciones sin playlist utiliza el idioma seleccionado en la app; los
nombres de las playlists conservan los del usuario, saneados para el sistema
de archivos.

Un archivo que pertenece a varias playlists se guarda en la primera del orden
exportado. Las listas M3U8 usan rutas relativas y mantienen el orden y las
ocurrencias repetidas: por ejemplo, `../Mi playlist/Canción A.mp3`. Ninguna
copia adicional de ese audio se añade a Otra playlist ni a Descargadas.
Las playlists sin audio local conservan sus datos en SQLite y no generan
carpetas vacías.

Sin playlists con audio guardado, los archivos se exportan directamente en
`audio/`. Si antes estaban en subcarpetas, se aplanan sin sobrescribir nombres
iguales. No se fusionan archivos distintos por contenido ni se calcula un
hash de toda la colección.

## Formato y restauración

El manifiesto mantiene el esquema 1 para los respaldos planos cuyo diseño no
cambia y que tienen disponibles todos los archivos registrados. Los respaldos
organizados, con nombres/rutas reasignados o con archivos ausentes utilizan
esquema 2 e incluyen `audio-index.json`. Ese índice tiene su propio esquema 1:

```json
{
  "schema": 1,
  "audioFiles": ["audio/Mi playlist/Canción A.mp3"],
  "playlistFiles": ["audio/Mi playlist/playlist.m3u8"],
  "tracks": {"id-de-la-canción": "audio/Mi playlist/Canción A.mp3"}
}
```

SQLite se guarda intacta. Al restaurar, las rutas de audio se actualizan por
ID usando el índice; las relaciones de playlists no cambian. Esto evita que
el comportamiento antiguo, que rebasa nombres planos, pierda las nuevas
subcarpetas. Varias filas pueden referirse al mismo archivo físico. Las filas
sin audio incluido permanecen no disponibles en una ruta interna inexistente;
no se les asocia otro archivo por compartir el nombre.

Las M3U8 son auxiliares para quien descomprime el ZIP y escucha su música fuera
de BStream. La app restaura las playlists desde SQLite y excluye esas listas
auxiliares de su carpeta interna. La siguiente exportación vuelve a crearlas
desde la biblioteca actual.

Se siguen aceptando respaldos antiguos con esquema 1 o sin manifiesto. Las
versiones antiguas de la app que solo entienden el esquema 1 rechazan el nuevo
formato en vez de importarlo con rutas incorrectas.

## Integridad y coste

- Una transacción lee metadatos y pertenencias, incluyendo las marcas de
  borrado necesarias para no revivir relaciones antiguas. No hay una consulta
  por playlist ni acceso a la base activa desde el worker del ZIP.
- La instantánea existente se reutiliza: agrupar cambia los nombres de las
  entradas del ZIP y no crea otra copia temporal por playlist.
- El audio y las imágenes se guardan sin recompresión; la base de datos, el
  índice y las listas pequeñas pueden comprimirse.
- Las carpetas y archivos usan nombres seguros, límites UTF-8, sufijos para
  colisiones y protección de nombres reservados. M3U8 elimina saltos de línea
  de sus etiquetas y referencia únicamente archivos incluidos.
- El índice se limita a 16 MiB y a los presupuestos de entradas del respaldo.
  Se verifican rutas, duplicados, archivos ausentes y pertenencia al índice
  antes de sustituir la biblioteca. Se rechazan enlaces y escapes de carpetas.
  Solo se eliminan auxiliares con el nombre y la cabecera M3U8 generados.
- La restauración mantiene el staging y rollback existentes. Un índice con
  IDs ajenos a SQLite, un fallo de activación o de sincronización devuelve la
  biblioteca anterior. Las rutas equivalentes del sistema de archivos tampoco
  pueden sobrescribir otra entrada durante la extracción.

Las pruebas utilizan SQLite y ZIP reales: cubren playlists con canciones
sueltas, archivos compartidos, M3U8, rutas conflictivas, compatibilidad con el
formato anterior, respaldos manipulados y exportar/restaurar/exportar tras
eliminar playlists.
