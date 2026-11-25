"""Validate that two signed Android release APKs differ only by the native engine."""
import argparse
import hashlib
import json
import re
import ssl
import subprocess
from pathlib import Path
from zipfile import ZipFile

def sha(data):
    return hashlib.sha256(data).hexdigest()

def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True, stderr=subprocess.STDOUT)

p=argparse.ArgumentParser()
p.add_argument("--control",type=Path,required=True)
p.add_argument("--candidate",type=Path,required=True)
p.add_argument("--library",type=Path,required=True)
p.add_argument("--aapt2",type=Path,required=True)
p.add_argument("--apksigner",type=Path,required=True)
p.add_argument("--output",type=Path,required=True)
a=p.parse_args()
engine="lib/arm64-v8a/libflutter.so"
aot="lib/arm64-v8a/libapp.so"

def metadata(apk):
    badging=output(a.aapt2,"dump","badging",apk)
    package=re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",badging,re.M)
    assert package and package.group(1)=="com.bstream.bstream_music", badging.splitlines()[0]
    assert re.search(r"^native-code: 'arm64-v8a'\s*$",badging,re.M), "Unexpected APK native ABIs"
    certificate=output(a.apksigner,"verify","--print-certs-pem",apk)
    # Derive the digest from the verified X.509 certificate itself, not the
    # tool's version-dependent display labels or hexadecimal formatting.
    # Repeated copies for different Android platform ranges are deduplicated.
    pems=re.findall(r"-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+?-----END CERTIFICATE-----",certificate)
    digests={sha(ssl.PEM_cert_to_DER_cert(pem)) for pem in pems}
    assert len(digests)==1, f"Expected one distinct signing certificate; found {len(digests)}"
    return dict(package=package.group(1),versionCode=package.group(2),versionName=package.group(3),
                certificateSha256=next(iter(digests)),sha256=sha(apk.read_bytes()))

def payload_names(z):
    # v1 signature records are not application code, and can differ when the
    # engine payload changes. v2/v3 signing blocks are outside the ZIP entries.
    return {name for name in z.namelist()
            if not re.fullmatch(r"META-INF/(?:MANIFEST\.MF|[^/]+\.(?:SF|RSA|DSA|EC))",name,re.I)}

control=metadata(a.control)
candidate=metadata(a.candidate)
assert {k:control[k] for k in control if k!="sha256"}=={k:candidate[k] for k in candidate if k!="sha256"}
with ZipFile(a.control) as base, ZipFile(a.candidate) as patched:
    assert len(base.namelist())==len(set(base.namelist()))
    assert len(patched.namelist())==len(set(patched.namelist()))
    assert payload_names(base)==payload_names(patched),"Application payload entry names differ"
    for z in (base,patched):
        abis={n.split("/")[1] for n in z.namelist() if n.startswith("lib/") and n.endswith(".so")}
        assert abis=={"arm64-v8a"},abis
        assert not any("VkLayer_bstream_profile" in n for n in z.namelist())
    assert patched.read(engine)==a.library.read_bytes(),"Candidate has the wrong native engine"
    assert base.read(engine)!=patched.read(engine),"Control and candidate use the same engine"
    assert base.read(aot)==patched.read(aot),"Control and candidate have different AOT Dart code"
    differences=sorted(n for n in payload_names(base) if base.read(n)!=patched.read(n))
    assert differences==[engine],differences
    control["engineSha256"]=sha(base.read(engine))
    candidate["engineSha256"]=sha(patched.read(engine))
    record=dict(control=control,candidate=candidate,dartAotSha256=sha(base.read(aot)),
                changedPayloadEntries=differences,nativeMode="release",abi="arm64-v8a")
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(record,indent=2)+"\n",encoding="utf8")
print(json.dumps(record,indent=2))
