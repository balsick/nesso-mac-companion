"""Build preview.html, a self-contained 3D view of the shell, from the STLs in stl/.

Run shell.py first: it writes the STLs and preview_config.json this reads.
three.js r147 is downloaded once into .cache/ and inlined, so the page works offline.
"""
import base64
import json
import os
import subprocess
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
THREE = {
    "three.min.js": "https://unpkg.com/three@0.147.0/build/three.min.js",
    "OrbitControls.js": "https://unpkg.com/three@0.147.0/examples/js/controls/OrbitControls.js",
}


def library(name):
    path = os.path.join(HERE, ".cache", name)
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            urllib.request.urlretrieve(THREE[name], path)
        except urllib.error.URLError:
            # Some Python builds reject the CA chain that curl, using the system's, accepts.
            subprocess.run(["curl", "-sSfL", "-o", path, THREE[name]], check=True)
    return open(path).read()


def b64(name):
    return base64.b64encode(open(os.path.join(HERE, "stl", name), "rb").read()).decode()


cfg = json.load(open(os.path.join(HERE, "preview_config.json")))
h = open(os.path.join(HERE, "preview_template.html")).read()
h = h.replace("/*THREE*/", library("three.min.js")).replace("/*ORBIT*/", library("OrbitControls.js"))
h = h.replace("/*TITLE*/", cfg["title"]).replace("/*SIZE*/", cfg["size"])
h = h.replace("/*CFG*/", json.dumps(cfg, ensure_ascii=False))
h = h.replace("/*SHELL*/", b64("shell.stl")).replace("/*SPACER*/", b64("spacer.stl"))
h = h.replace("/*NESSO*/", b64("ref_nesso.stl")).replace("/*MODULINO*/", b64("ref_modulino.stl"))
out = os.path.join(HERE, "preview.html")
open(out, "w").write(h)
print(out, len(h))
