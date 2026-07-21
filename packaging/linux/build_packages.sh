#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <flutter-bundle> <version> <output-directory>" >&2
  exit 64
fi

bundle="$(realpath "$1")"
version="$2"
output_dir="$(mkdir -p "$3" && realpath "$3")"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -x "$bundle/bstream_music" ]]; then
  echo "Flutter Linux bundle not found at $bundle" >&2
  exit 1
fi

for tool in yt-dlp ffmpeg; do
  if [[ ! -x "$bundle/tools/$tool" ]]; then
    echo "Bundled tool is missing or not executable: $bundle/tools/$tool" >&2
    exit 1
  fi
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

stage="$work_dir/root"
install -d \
  "$stage/opt/bstream-music" \
  "$stage/usr/bin" \
  "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/512x512/apps"
cp -a "$bundle/." "$stage/opt/bstream-music/"
install -m 0755 "$repo_root/packaging/linux/bstream-music" \
  "$stage/usr/bin/bstream-music"
install -m 0644 "$repo_root/packaging/linux/com.bstream.bstream_music.desktop" \
  "$stage/usr/share/applications/com.bstream.bstream_music.desktop"
install -m 0644 \
  "$repo_root/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png" \
  "$stage/usr/share/icons/hicolor/512x512/apps/com.bstream.bstream_music.png"

deb_root="$work_dir/deb"
cp -a "$stage" "$deb_root"
install -d "$deb_root/DEBIAN"
cat >"$deb_root/DEBIAN/control" <<EOF
Package: bstream-music
Version: $version
Section: sound
Priority: optional
Architecture: amd64
Maintainer: BryamContreras <BryamContreras@users.noreply.github.com>
Depends: libgtk-3-0 | libgtk-3-0t64, libmpv2 | libmpv1, libsqlite3-0, libc6, libstdc++6
Homepage: https://github.com/BryamContreras/BStream-Music
Description: Reproductor y gestor musical multiplataforma
 BStream Music permite buscar, reproducir, descargar y organizar musica,
 playlists y favoritos desde una interfaz construida con Flutter.
EOF

deb_path="$output_dir/BStream-Music-$version-linux-amd64.deb"
dpkg-deb --root-owner-group --build "$deb_root" "$deb_path"
dpkg-deb --info "$deb_path"
dpkg-deb --contents "$deb_path" >/dev/null

rpm_top="$work_dir/rpmbuild"
mkdir -p "$rpm_top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
rpmbuild -bb \
  --define "_topdir $rpm_top" \
  --define "app_version $version" \
  --define "staging_root $stage" \
  "$repo_root/packaging/linux/bstream-music.spec"

rpm_source="$(find "$rpm_top/RPMS" -type f -name '*.rpm' -print -quit)"
if [[ -z "$rpm_source" ]]; then
  echo "rpmbuild did not produce an RPM package" >&2
  exit 1
fi

rpm_path="$output_dir/BStream-Music-$version-linux-x86_64.rpm"
cp "$rpm_source" "$rpm_path"
rpm -qip "$rpm_path"
rpm -qlp "$rpm_path" >/dev/null
rpm -qpR "$rpm_path"

printf 'Created:\n  %s\n  %s\n' "$deb_path" "$rpm_path"
