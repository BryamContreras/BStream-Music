# Motor Impeller regional para Android

Esta carpeta conserva la implementación nativa de la optimización de los
backdrops que se validó en BStream Music. El código no contiene condiciones por
fabricante, GPU, resolución ni frecuencia de refresco. La integración de Gradle
es deliberadamente optativa para **Android arm64**. El perfil se ha probado
físicamente. El motor release se compila y verifica por separado para los
artefactos candidatos de CI; no se mezcla una biblioteca de perfil con una
compilación de release.

## Usar el motor local preparado

Desde PowerShell, en la raíz de BStream Music, con Flutter **3.47.9**:

```powershell
$repo = (Resolve-Path 'build/bstream-impeller/maven').Path
flutter build apk --profile --target-platform android-arm64 --android-project-arg "bstream-impeller-engine-repo=$repo"
```

El build estándar sin el argumento anterior sigue usando los artefactos
oficiales de Flutter. La sustitución usa una coordenada Maven distinta
(`com.bstream.engine:arm64_v8a_profile`), conserva la dependencia oficial de
embedding e impide utilizarla con otra revisión del SDK o en otro modo.

## Validación en GitHub Actions

El workflow `.github/workflows/android-impeller-candidate.yml` compila el
engine **release arm64** en un runner de GitHub, verifica el parche y sus
pruebas geométricas, y crea dos APK firmadas con el mismo código Dart:
una de control con el engine oficial y una candidata con el engine modificado.
El artefacto contiene las huellas SHA-256, identidad de firma y comprobación
de que solo cambia `libflutter.so`. Se ejecuta en la rama
`ci/impeller-candidate` o manualmente una vez que el workflow esté en la rama
predeterminada. No publica releases ni sustituye el workflow ordinario.

## Regenerar el motor

Se necesita un checkout **aislado** del repositorio Flutter en la etiqueta
`3.47.9`, con el entorno de desarrollo del engine y sus dependencias
sincronizadas. No se aplica el parche al SDK compartido que utiliza la app.

- Revisión framework: `c197ca5199e9ee5661e865596c9c07294dfab51c`.
- Revisión engine de los artefactos publicados:
  `89c39edfdfae2949f6806e4a315c0c08522238b7`.

En Linux o WSL, desde el directorio de BStream Music:

```bash
bash tool/impeller/test_geometry.sh /ruta/flutter-3.47.9
bash tool/impeller/build_android_profile.sh /ruta/flutter-3.47.9 build/bstream-impeller/libflutter-profile-arm64.so
```

Para reproducir un motor release candidato, el script general exige un modo
separado y genera también un manifiesto verificable:

```bash
bash tool/impeller/build_android_engine.sh release /ruta/flutter-3.47.9 build/bstream-impeller/libflutter-release-arm64.so
```

El script comprueba la revisión, aplica `downsample-scissor.patch` una sola
vez y compila el target nativo oficial de Android. Requiere `depot_tools`
en PATH (o en `BSTREAM_DEPOT_TOOLS`) y Ninja. El límite de trabajos se puede
ajustar con `BSTREAM_ENGINE_JOBS`. La preparación del checkout sigue
[la documentación del engine de Flutter](https://github.com/flutter/flutter/blob/3.47.9/docs/engine/contributing/Setting-up-the-Engine-development-environment.md).

Desde PowerShell, genere el repositorio Maven usando el JAR oficial de la
misma revisión, presente en la caché local de Gradle:

```powershell
python tool/impeller/create_engine_maven.py --library build/bstream-impeller/libflutter-profile-arm64.so --repo build/bstream-impeller/maven
```

Si el JAR oficial está en otra ubicación, use `--official-jar`. El script
conserva todos los otros archivos del JAR y registra las huellas SHA-256 en
`bstream-engine-manifest.json`. Después se puede compilar usando el argumento
Gradle del primer apartado.

## Alcance técnico

El parche limita únicamente el rasterizado del pase de downsample en un
backdrop gaussiano directo, sin reutilizar un resultado filtrado compartido, cuando el recorrido original
requiere reducir el snapshot completo por un factor de al menos ocho y el
muestreo es clamp. Usa la cobertura real del saveLayer, la inversa del
transform final, los dos radios del kernel y un margen de interpolación.
No cambia la resolución ni las UV de la textura temporal, los shaders,
la refracción, los pases gaussianos, el agrupamiento de backdrops o la
sincronización de buffers.

El test nativo reproduce la función de geometría exacta del parche con
`Matrix` y `Rect` de Impeller; comprueba 15.000 transformaciones aleatorias
y sus dependencias. Los tests del engine incluidos en el parche también
cubren el halo, coordenadas fraccionales y retorno al comportamiento
original. Los resultados físicos y limitaciones se detallan en el informe
de implementación.

La validación de release, otras arquitecturas, S22 Ultra, Mali y 90 Hz debe
realizarse con el mismo protocolo de presentación y comparación visual
antes de habilitar el motor personalizado en las compilaciones de
distribución.
