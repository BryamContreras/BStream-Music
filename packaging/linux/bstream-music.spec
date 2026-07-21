%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           bstream-music
Version:        %{app_version}
Release:        1
Summary:        Reproductor y gestor musical multiplataforma
License:        Proprietary
URL:            https://github.com/BryamContreras/BStream-Music
Vendor:         BryamContreras
BuildArch:      x86_64
AutoReqProv:    no

Requires:       gtk3
Requires:       mpv-libs
Requires:       sqlite-libs
Requires:       glibc
Requires:       libstdc++

%description
BStream Music permite buscar, reproducir, descargar y organizar musica,
playlists y favoritos desde una interfaz construida con Flutter.

%install
mkdir -p "%{buildroot}"
cp -a "%{staging_root}/." "%{buildroot}/"

%files
/opt/bstream-music
/usr/bin/bstream-music
/usr/share/applications/com.bstream.bstream_music.desktop
/usr/share/icons/hicolor/512x512/apps/com.bstream.bstream_music.png
