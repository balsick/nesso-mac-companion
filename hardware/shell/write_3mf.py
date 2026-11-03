"""Write several STLs into one 3MF, side by side on a printer plate.

usage: write_3mf.py OUT.3mf PLATE_W PLATE_D name=file.stl[@cx,cy] ...
Each part is centred on (cx, cy), default the plate centre, and dropped onto the bed.
"""
import sys
import zipfile
from xml.sax.saxutils import escape

import trimesh

out, plate_w, plate_d = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
objects = []
for arg in sys.argv[4:]:
    name, rest = arg.split("=", 1)
    path, _, at = rest.partition("@")
    cx, cy = map(float, at.split(",")) if at else (plate_w / 2, plate_d / 2)
    m = trimesh.load(path)
    m.merge_vertices()
    lo, hi = m.bounds
    m.apply_translation([cx - (lo[0] + hi[0]) / 2, cy - (lo[1] + hi[1]) / 2, -lo[2]])
    lo, hi = m.bounds
    assert lo[0] >= 0 and lo[1] >= 0 and hi[0] <= plate_w and hi[1] <= plate_d, f"{name} is off the plate"
    objects.append((name, m))

parts = []
for i, (name, m) in enumerate(objects, 1):
    verts = "".join('<vertex x="%.5f" y="%.5f" z="%.5f"/>' % tuple(v) for v in m.vertices)
    tris = "".join('<triangle v1="%d" v2="%d" v3="%d"/>' % tuple(f) for f in m.faces)
    parts.append('<object id="%d" name="%s" type="model"><mesh><vertices>%s</vertices>'
                 '<triangles>%s</triangles></mesh></object>' % (i, escape(name), verts, tris))
items = "".join('<item objectid="%d"/>' % i for i in range(1, len(objects) + 1))
model = ('<?xml version="1.0" encoding="UTF-8"?>'
         '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
         '<resources>%s</resources><build>%s</build></model>' % ("".join(parts), items))
types = ('<?xml version="1.0" encoding="UTF-8"?>'
         '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
         '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>')
rels = ('<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Target="/3D/3dmodel.model" Id="rel0" '
        'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    # A fixed date keeps the file identical when nothing changed.
    for name, data in (("[Content_Types].xml", types), ("_rels/.rels", rels), ("3D/3dmodel.model", model)):
        z.writestr(zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0)), data, zipfile.ZIP_DEFLATED)
for name, m in objects:
    print(name, "watertight", m.is_watertight, "vol", round(m.volume), "bounds", m.bounds.round(2).tolist())
