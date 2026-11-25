"""Assemble a local, version-pinned Flutter arm64 engine dependency.

The official Flutter embedding and all other JAR entries are preserved.
Profile and release libraries must never be interchanged. Release candidates
require the matching manifest from the native build.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

ENGINE="89c39edfdfae2949f6806e4a315c0c08522238b7"
FRAMEWORK="c197ca5199e9ee5661e865596c9c07294dfab51c"
VERSION=f"1.0.0-{ENGINE}-bstream-region-v2"
ENTRY="lib/arm64-v8a/libflutter.so"
OFFICIAL_JAR_SHA256={
    "profile":"9065eb853b41cde1ff1ee6c4b53098b7a026f943572aae9eebbeef8e1fd06532",
    "release":"b7acf0d2e33f4bf6eaacb335df1812d9c6e894a5342fb78e92840ece6d6d8cc4",
}
p=argparse.ArgumentParser()
p.add_argument("--mode",choices=("profile","release"),default="profile")
p.add_argument("--library",type=Path,required=True)
p.add_argument("--repo",type=Path,required=True)
p.add_argument("--official-jar",type=Path)
p.add_argument("--manifest",type=Path)
a=p.parse_args()
ARTIFACT=f"arm64_v8a_{a.mode}"
cache=Path.home()/".gradle/caches/modules-2/files-2.1/io.flutter"/ARTIFACT/f"1.0.0-{ENGINE}"
files=list(cache.rglob(f"{ARTIFACT}-1.0.0-{ENGINE}.jar"))
official=a.official_jar or (files[0] if len(files)==1 else None)
if official is None or not official.is_file():
    raise SystemExit("The exact pinned official Flutter JAR is required.")
if hashlib.sha256(official.read_bytes()).hexdigest()!=OFFICIAL_JAR_SHA256[a.mode]:
    raise SystemExit("The official JAR does not match the pinned Flutter 3.47.9 artifact.")
native=a.library.read_bytes()
if native[:5]!=b"\x7fELF\x02" or native[18:20]!=b"\xb7\x00":
    raise SystemExit("The supplied library must be an arm64 ELF.")
build_manifest=a.manifest or a.library.with_suffix(a.library.suffix+".json")
if build_manifest.is_file():
    facts=json.loads(build_manifest.read_text(encoding="utf8"))
    expected=dict(mode=a.mode,abi="arm64-v8a",frameworkRevision=FRAMEWORK,
                  engineRevision=ENGINE,
                  patchSha256=hashlib.sha256(Path(__file__).with_name("downsample-scissor.patch").read_bytes()).hexdigest(),
                  librarySha256=hashlib.sha256(native).hexdigest())
    if any(facts.get(k)!=v for k,v in expected.items()):
        raise SystemExit("Native build manifest does not match the requested mode, revision, patch or library.")
elif a.mode=="release":
    raise SystemExit("A matching native release build manifest is required.")
dest=a.repo/"com/bstream/engine"/ARTIFACT/VERSION
dest.mkdir(parents=True,exist_ok=True)
jar=dest/f"{ARTIFACT}-{VERSION}.jar"
pom=dest/f"{ARTIFACT}-{VERSION}.pom"
with ZipFile(official) as ref,ZipFile(jar,"w") as out:
    assert ENTRY in ref.namelist()
    assert len(ref.infolist())==len(set(ref.namelist()))
    for z in ref.infolist():
        out.writestr(copy.copy(z),native if z.filename==ENTRY else ref.read(z.filename))
with ZipFile(official) as ref,ZipFile(jar) as out:
    assert ref.namelist()==out.namelist()
    assert all(ref.read(n)==out.read(n) for n in ref.namelist() if n!=ENTRY)
    assert out.read(ENTRY)==native
pom.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.bstream.engine</groupId>
  <artifactId>{ARTIFACT}</artifactId>
  <version>{VERSION}</version>
  <packaging>jar</packaging>
</project>
""",encoding="utf8")
def sha(data):return hashlib.sha256(data).hexdigest()
manifest=dict(frameworkRevision=FRAMEWORK,engineRevision=ENGINE,mode=a.mode,abi="arm64-v8a",
              artifact=f"com.bstream.engine:{ARTIFACT}:{VERSION}",
              originalArtifactSha256=sha(official.read_bytes()),jarSha256=sha(jar.read_bytes()),
              librarySha256=sha(native),replacedEntry=ENTRY)
(a.repo/"bstream-engine-manifest.json").write_text(json.dumps(manifest,indent=2),encoding="utf8")
print(json.dumps(manifest),flush=True)
