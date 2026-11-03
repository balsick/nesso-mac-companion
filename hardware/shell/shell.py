"""Back shell for the Arduino Nesso N1 that holds a Modulino Pixels.

The shell goes on the Nesso either way round, with the Nesso always upright:
  below   the Modulino sits below the USB-C end, in front of a channel the USB-C
          plug and cable go through;
  on top  the shell turned 180 degrees in the screen plane puts the Modulino above
          the header end, and the USB-C cable comes out freely below.
A separate spacer fills the Nesso's back recess at the USB-C end in both cases.

Use-orientation coordinates, in mm, looking at the screen with USB-C down:
  X  left -> right   Nesso spans 0..24 (Qwiic and power on the left, KEY2 on the right)
  Y  front -> back   screen glass at 0, Nesso back at 14
  Z  bottom -> top   USB-C end at 0, 8-pin header end at 48

Sources: Nesso N1 datasheet TPX00227 (section 9, mechanical drawings),
Modulino Pixels datasheet ABX00109 (section 7.4) and CAD files, user manual photos.

`python shell.py [DIR]` checks both mountings for clashes and writes, under DIR
(default: next to this file), the print-ready STLs in stl/ and preview_config.json.
"""
import json
import os
import sys
from dataclasses import dataclass

import numpy as np
from manifold3d import Manifold, OpType

SEG = 64

# --- Nesso N1 (datasheet TPX00227) -----------------------------------------
N_W, N_H, N_D = 24.0, 48.0, 14.0     # width, length, thickness without antenna storage
N_R = 3.0                             # 4x R3 corners
REC_DEPTH = 2.0                       # back recess at the USB-C end (2 mm x 45 deg chamfer)
REC_LEN = 6.6                         # flat part of that recess, from the USB-C end
SCREW_X = (3.0, 21.0)                 # 2x dia 2 mm holes, 3 mm from the edges
SCREW_Z = 3.0

# --- Modulino Pixels (datasheet ABX00109) ----------------------------------
M_L, M_W, M_T = 41.0, 25.36, 1.6
M_R = 4.5                             # corner radius, from the board outline Gerber
M_HOLE_DX, M_HOLE_DZ = 16.0, 8.0      # 32 x 16 mm hole pattern, centred
M_HOLE_D = 3.2                        # NPTH; the top soldermask keeps a bare dia 5.6 ring around each

# --- Shell parameters --------------------------------------------------------
# The plate is the same at both ends, so the shell goes on either way round: head
# below the USB-C end, or turned 180 degrees with the head above the header end.
# The Nesso's screw holes and back recess are only at the USB-C end, so whichever
# end of the plate lands there uses its two holes, and a separate spacer fills the
# recess under it.
PLATE_T = 3.0          # back plate behind the Nesso: Y 14 .. 17
SPACER_T = 2.0         # spacer in the 2 mm recess; reprint thinner or thicker if the plate rocks
SPACER_LEN = REC_LEN - 0.2
# Small FDM holes print ~0.2 mm undersize: these come out at ~2.6 and ~4.6, which
# leaves room for M2 shanks, heads up to ~4.2 mm and some error in the hole positions.
SCREW_CLEAR_D = 2.8    # M2
CBORE_D = 4.8          # M2 socket head is 3.8
HEAD_FLOOR = 0.6       # plate left under the screw head; the 2 mm head sits 0.4 below the back face
FACE_RELIEF = 0.3      # pocket in the face that touches the Nesso back

# Faces whose distance matters (plate front, board seat, hook catch, screw seat) sit
# on multiples of this, in print Z, so slicing does not round them the wrong way.
LAYER = 0.2

BOARD_GAP_Z = 2.3      # Nesso end face to the Modulino's nearest edge

# How the Modulino is held: "screws" through its four holes, or "hooks" (snap hooks
# on the long edges, kept for reference: printed upright they are thin and fragile).
MOUNT = "screws"

# M3 screws from the LED side, self-tapping into blind pilot holes. The M3 shank
# locates the board in its dia 3.2 holes, and an M3 socket head (dia 5.5) stays
# inside the bare ring the board keeps around each hole.
MOD_SCREW_HEAD_D, MOD_SCREW_HEAD_H = 5.5, 3.0
PILOT_D = 2.7          # prints at ~2.5, what M3 needs to tap into PLA
PILOT_DEPTH = 7.5      # from the board back: M3x6 bites 4.4 mm, M3x8 6.4 mm
PILOT_CHAMFER = 0.4    # lead-in at the mouth

BOARD_CLR = 0.15       # between board edge and hook
PEG_D = 3.0
PEG_LEN = 1.2          # well short of the 1.6 mm board

# The beams stand upright when printed, so they bend across the layers: keep the
# strain low enough for PLA (see hook_strain()).
HOOK_T = 1.0           # beam thickness (Z)
HOOK_LIP = 0.6         # how far the lip reaches over the board face
HOOK_LIP_T = 1.0       # lip thickness (Y), the front 0.6 of it chamfered
HOOK_CATCH_CLR = 0.2   # board front to lip, one layer: the board is 1.6 +- 0.2 mm
HOOK_FREE = 11.0       # free length of the beam
HEAD_INSET = 0.5       # head block front part sits this much inside the board outline

# The board sits in front of the USB-C plug. Plugs up to PLUG_W x PLUG_T fit.
PLUG_W, PLUG_T = 12.5, 7.5            # USB-C overmold, centred on the port
USB_Y = 4.1                           # USB-C port centre, from the USB-end photo
CHANNEL_HALF_W = 7.0                  # channel X = 12 +- 7, also clears a Grove plug
CHANNEL_BACK_Y = 13.2                 # Grove plug reaches Y 12.0, its latch a bit more
BOARD_BACK_Y = USB_Y - PLUG_T / 2 - 0.35

Y_BACK = N_D + PLATE_T


@dataclass
class Layout:
    z_b0: float          # board lower edge
    z_b1: float          # board upper edge
    front_y: float       # board LED face
    hooks_x: tuple       # (x0, x1) of each hook, on both long edges

    @property
    def back_y(self):
        return self.front_y + M_T

    @property
    def x_b0(self):
        return N_W / 2 - M_L / 2

    @property
    def x_b1(self):
        return N_W / 2 + M_L / 2

    @property
    def cz(self):
        return (self.z_b0 + self.z_b1) / 2

    @property
    def catch_y(self):
        return self.front_y - HOOK_CATCH_CLR

    @property
    def root_y(self):
        return self.catch_y - HOOK_LIP_T + HOOK_FREE


def layout():
    z1 = -BOARD_GAP_Z
    # Hooks sit on the frame's side walls, either side of the channel.
    hooks = ((-4.5, 0.5), (N_W - 0.5, N_W + 4.5))
    return Layout(z1 - M_W, z1, BOARD_BACK_Y - M_T, hooks)


def box(x0, x1, y0, y1, z0, z1):
    return Manifold.cube([x1 - x0, y1 - y0, z1 - z0]).translate([x0, y0, z0])


def cyl_y(x, z, d, y0, y1):
    """Cylinder along Y."""
    return Manifold.cylinder(y1 - y0, d / 2, d / 2, SEG).rotate([-90, 0, 0]).translate([x, y0, z])


def rbox_xz(x0, x1, z0, z1, y0, y1, r):
    """Box with its four Y-parallel edges rounded (rounded rectangle in the XZ plane)."""
    parts = [box(x0 + r, x1 - r, y0, y1, z0, z1), box(x0, x1, y0, y1, z0 + r, z1 - r)]
    for x in (x0 + r, x1 - r):
        for z in (z0 + r, z1 - r):
            parts.append(cyl_y(x, z, 2 * r, y0, y1))
    return Manifold.batch_boolean(parts, OpType.Add)


def hull(points):
    return Manifold.hull_points(np.array(points, dtype=float))


def back_plate():
    """Flat plate with the Nesso's outline."""
    return rbox_xz(0, N_W, 0, N_H, N_D, Y_BACK, N_R)


SEAT_Y = N_D + HEAD_FLOOR


def cut_screws_and_reliefs(body):
    # Holes at both ends; only the pair at the USB-C end takes screws.
    for sz in (SCREW_Z, N_H - SCREW_Z):
        for sx in SCREW_X:
            body = body - cyl_y(sx, sz, SCREW_CLEAR_D, N_D - 1, Y_BACK + 1)
            body = body - cyl_y(sx, sz, CBORE_D, SEAT_Y, Y_BACK + 1)
    # Relief in the face against the Nesso back, clear of the recess either way round.
    z0 = REC_LEN + REC_DEPTH + 0.8
    return body - rbox_xz(1.4, N_W - 1.4, z0, N_H - z0, N_D - 0.01, N_D + FACE_RELIEF, 1.5)


def spacer():
    """Fills the recess at the USB-C end, under whichever end of the plate is there."""
    body = rbox_xz(0, N_W, 0, SPACER_LEN + N_R, N_D - SPACER_T, N_D, N_R) - box(-1, N_W + 1, -1, N_D + 1, SPACER_LEN, 99)
    for sx in SCREW_X:
        body = body - cyl_y(sx, SCREW_Z, SCREW_CLEAR_D, N_D - SPACER_T - 1, N_D + 1)
    return body


def turned(m):
    """The shell turned 180 degrees in the screen plane: head above the header end."""
    return m.transform(np.array([[-1, 0, 0, N_W], [0, 1, 0, 0], [0, 0, -1, N_H]], dtype=float))


def mod_holes(lo):
    return [(N_W / 2 + sx * M_HOLE_DX, lo.cz + sz * M_HOLE_DZ) for sx in (-1, 1) for sz in (-1, 1)]


def head(lo):
    """Block that carries the Modulino: pilot holes (or pegs and snap hooks), and the cable channel."""
    if MOUNT == "screws":
        hz0, hz1 = lo.z_b0, lo.z_b1
        body = rbox_xz(lo.x_b0, lo.x_b1, hz0, hz1, lo.back_y, Y_BACK, M_R)
    else:
        hz0 = lo.z_b0 - BOARD_CLR - HOOK_T           # outer face of the lower hook beams
        hz1 = lo.z_b1 + BOARD_CLR + HOOK_T
        body = rbox_xz(lo.x_b0, lo.x_b1, hz0, hz1, lo.root_y, Y_BACK, M_R)
        body = body + rbox_xz(lo.x_b0 + HEAD_INSET, lo.x_b1 - HEAD_INSET, lo.z_b0 + HEAD_INSET, lo.z_b1 - HEAD_INSET,
                              lo.back_y, lo.root_y + 0.01, M_R - HEAD_INSET)
    # Neck: the back plate runs on into the head.
    body = body + box(0, N_W, N_D, Y_BACK, hz1 - 1, N_R)
    if MOUNT == "screws":
        for px, pz in mod_holes(lo):
            body = body - cyl_y(px, pz, PILOT_D, lo.back_y - 0.01, lo.back_y + PILOT_DEPTH)
            body = body - Manifold.cylinder(PILOT_CHAMFER + 0.01, PILOT_D / 2 + PILOT_CHAMFER + 0.01, PILOT_D / 2,
                                            SEG).rotate([-90, 0, 0]).translate([px, lo.back_y - 0.01, pz])
        return cut_channel(body, lo, hz0)

    for sx in (-1, 1):
        for sz in (-1, 1):
            px, pz = N_W / 2 + sx * M_HOLE_DX, lo.cz + sz * M_HOLE_DZ
            body = body + cyl_y(px, pz, PEG_D, lo.back_y - PEG_LEN + 0.3, lo.back_y + 0.01)
            body = body + Manifold.cylinder(0.3, PEG_D / 2 - 0.3, PEG_D / 2, SEG).rotate([-90, 0, 0]).translate(
                [px, lo.back_y - PEG_LEN, pz])

    catch_y = lo.catch_y
    tip_y = catch_y - HOOK_LIP_T
    gap = 0.6
    for hx0, hx1 in lo.hooks_x:
        for side in (-1, 1):
            if side < 0:
                inner = lo.z_b0 - BOARD_CLR
                beam = box(hx0, hx1, tip_y, lo.root_y + 0.01, inner - HOOK_T, inner)
                clear = box(hx0 - gap, hx1 + gap, lo.back_y - 0.01, lo.root_y, inner - 0.01, lo.z_b0 + gap)
            else:
                inner = lo.z_b1 + BOARD_CLR
                beam = box(hx0, hx1, tip_y, lo.root_y + 0.01, inner, inner + HOOK_T)
                clear = box(hx0 - gap, hx1 + gap, lo.back_y - 0.01, lo.root_y, lo.z_b1 - gap, inner + 0.01)
            reach = inner - side * HOOK_LIP          # lip reaches toward the board
            lip = hull([(x, y, z) for x in (hx0, hx1) for (y, z) in (
                (catch_y, inner), (catch_y, reach), (tip_y + HOOK_LIP, reach), (tip_y, inner))])
            # Keep the head's front part clear of the beam so it can flex.
            body = (body - clear) + beam + lip
    return cut_channel(body, lo, hz0)


def cut_channel(body, lo, hz0):
    # Straight through the head, open at the far end and toward the board.
    return body - box(N_W / 2 - CHANNEL_HALF_W, N_W / 2 + CHANNEL_HALF_W,
                      lo.back_y - 1, CHANNEL_BACK_Y, hz0 - 1, 0.01)


def shell():
    return cut_screws_and_reliefs(back_plate() + head(layout()))


def nesso():
    body = rbox_xz(0, N_W, 0, N_H, 0, N_D, N_R)
    body = body - box(-1, N_W + 1, N_D - REC_DEPTH, N_D + 1, -1, REC_LEN)
    body = body - hull([(x, y, z) for x in (-1, N_W + 1) for (y, z) in
                        ((N_D - REC_DEPTH, REC_LEN), (N_D + 0.001, REC_LEN), (N_D + 0.001, REC_LEN + REC_DEPTH))])
    return body


def keepouts(lo, cz):
    """Plugs, cables and buttons the shell must stay clear of, with the Modulino centred at cz."""
    usb_x0, usb_x1 = N_W / 2 - PLUG_W / 2, N_W / 2 + PLUG_W / 2
    usb_y0, usb_y1 = USB_Y - PLUG_T / 2, USB_Y + PLUG_T / 2
    k = [
        ("USB-C plug", box(usb_x0, usb_x1, usb_y0, usb_y1, -20, 0)),
        ("USB-C cable", Manifold.cylinder(60, 2.2, 2.2, SEG).translate([N_W / 2, USB_Y, -80])),
        ("Grove plug", box(6, 18, 6.8, 12.6, -15, 0)),
        ("Qwiic plug", box(-6, 0, 2.4, 5.7, 21, 27)),
        ("power button", box(-3, 0, 1.7, 9.9, 5.6, 10.6)),
        ("KEY2", box(N_W, N_W + 3, 2, 10, 20, 28)),
        ("screen face", box(0, N_W, -5, 0, 0, N_H)),
        # The cable goes into the Modulino connector on the Nesso port's side, the left.
        ("Modulino left Qwiic plug", box(lo.x_b0 - 5, lo.x_b0 + 0.5, lo.front_y - 3.2, lo.front_y,
                                         cz - 3.2, cz + 3.2)),
    ]
    return k


def modulino(lo):
    board = rbox_xz(lo.x_b0, lo.x_b1, lo.z_b0, lo.z_b1, lo.front_y, lo.back_y, M_R)
    for sx in (-1, 1):
        for sz in (-1, 1):
            board = board - cyl_y(N_W / 2 + sx * M_HOLE_DX, lo.cz + sz * M_HOLE_DZ, M_HOLE_D, lo.front_y - 1, lo.back_y + 1)
    parts = [board]
    for sx in (-1, 1):  # Qwiic receptacles on the LED face, at the short ends
        x0 = lo.x_b0 + 0.5 if sx < 0 else lo.x_b1 - 0.5 - 4.25
        parts.append(box(x0, x0 + 4.25, lo.front_y - 2.9, lo.front_y, lo.cz - 3, lo.cz + 3))
    for i in range(8):  # LEDs, 2 x 2 mm on a 3.31 mm pitch
        x = N_W / 2 + (i - 3.5) * 3.31
        parts.append(box(x - 1, x + 1, lo.front_y - 0.8, lo.front_y, lo.cz - 1, lo.cz + 1))
    return parts


def mod_screw_heads(lo):
    return [cyl_y(px, pz, MOD_SCREW_HEAD_D, lo.front_y - MOD_SCREW_HEAD_H, lo.front_y) for px, pz in mod_holes(lo)]


def hook_strain():
    """Peak strain in percent of a hook beam pushed aside by the board edge."""
    deflection = HOOK_LIP - BOARD_CLR
    return 100 * 1.5 * HOOK_T * deflection / HOOK_FREE ** 2


def on_layer(z):
    return abs(z / LAYER - round(z / LAYER)) < 1e-6


def to_print(m, back_y=Y_BACK):
    """Back face down on the bed: print Z = back_y - Y, print Y = Z."""
    return m.transform(np.array([[1, 0, 0, 0], [0, 0, 1, 0], [0, -1, 0, back_y]], dtype=float))


def write_stl(m, path):
    import trimesh
    mesh = m.to_mesh()
    v = np.asarray(mesh.vert_properties)[:, :3]
    trimesh.Trimesh(vertices=v, faces=np.asarray(mesh.tri_verts), process=False).export(path)


def preview_config(lo, s):
    """Positions the HTML preview needs, so it follows the model."""
    (x0, y0, z0), (x1, y1, z1) = s.bounding_box()[:3], s.bounding_box()[3:]
    mm = lambda v: ("%.1f" % v).rstrip("0").rstrip(".").replace(".", ",")
    plug_y = lo.front_y - 1.45
    plug_x = lo.x_b0 - 4.5
    # The Qwiic cable, from the Nesso port down to the Modulino's left connector.
    cable = [[-4.5, 4.0, 24], [-9, 4.0, 22], [-13, 2.0, 10], [-15.5, -0.5, lo.z_b1 + 0.3],
             [-16, lo.front_y - 0.9, lo.cz + 4], [plug_x, plug_y, lo.cz]]
    centre = (z0 + z1) / 2
    return {
        "title": "Guscio Nesso N1 – Modulino sotto o sopra",
        "size": "%s × %s × %s mm" % (mm(x1 - x0), mm(z1 - z0), mm(y1 - y0)),
        "front": round(lo.front_y, 3), "ledZ": round(lo.cz, 3), "topDz": round(N_H - 2 * lo.cz, 3),
        "plugM": [round(v, 3) for v in (plug_x, lo.x_b0 + 0.5, lo.front_y - 2.9, lo.front_y, lo.cz - 3, lo.cz + 3)],
        "cable": [[round(v, 3) for v in p] for p in cable],
        "cableTop": [[round(x, 3), round(y, 3), round(N_H - z, 3)] for x, y, z in cable],
        "usb": [N_W / 2 - PLUG_W / 2, N_W / 2 + PLUG_W / 2, USB_Y - PLUG_T / 2, USB_Y + PLUG_T / 2, -18, 0],
        "usbCableZ": -33,
        "centerZ": round(centre, 2), "centerZTop": round(N_H - centre, 2), "printZ": round(centre, 2),
        "yBack": Y_BACK, "spacerBack": N_D, "nessoScrewY": SEAT_Y + 1.0,
        "screws": "2× M2×6 o M2×8 nel Nesso · 4× M3×6 nel Modulino",
    }


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    os.makedirs(f"{out}/stl", exist_ok=True)
    lo = layout()
    s = shell()
    print("status", s.status(), "genus", s.genus(), "volume %.0f mm3" % s.volume())
    print("use bbox", [round(v, 2) for v in s.bounding_box()])
    print("board", "z %.2f..%.2f" % (lo.z_b0, lo.z_b1), "front y %.2f" % lo.front_y, "back y %.2f" % lo.back_y)
    sp = spacer()
    print("spacer volume %.0f mm3, %.1f mm thick" % (sp.volume(), SPACER_T))
    faces = [("plate front", N_D), ("board seat", lo.back_y), ("screw seat", SEAT_Y)]
    for length in (6, 8):
        print("M2x%d: bites %.1f mm into the Nesso" % (length, length - (SEAT_Y - (N_D - REC_DEPTH))))
    if MOUNT == "hooks":
        print("hook strain %.2f %%" % hook_strain())
        faces.append(("hook catch", lo.catch_y))
    else:
        for length in (6, 8):
            print("M3x%d: bites %.1f mm, %.1f mm short of the pilot bottom" % (length, length - M_T, PILOT_DEPTH - (length - M_T)))
    for name, y in faces:
        z = Y_BACK - y
        print("print z of %-11s %.3f  %s" % (name, z, "on a layer" if on_layer(z) else "OFF THE LAYER GRID"))
    print("spacer thickness %s" % ("on a layer" if on_layer(SPACER_T) else "OFF THE LAYER GRID"))

    bad = 0
    parts = modulino(lo)
    heads = mod_screw_heads(lo) if MOUNT == "screws" else []
    # The heads must clear the Modulino's parts (not the board they clamp).
    for i, h in enumerate(heads):
        for j, p in enumerate(parts[1:], 1):
            v = (h ^ p).volume()
            bad += v > 1e-6
            print("clash M3 head %d / Modulino part %-2d %.3f" % (i, j, v))
    # Both ways round: the spacer stays in the Nesso's recess, the rest turns with the shell.
    for way, sh, cz, move in (("below", s, lo.cz, lambda m: m), ("on top", turned(s), N_H - lo.cz, turned)):
        checks = [("Nesso", nesso()), ("spacer", sp)] + keepouts(lo, cz)
        checks += [(f"Modulino part {i}", move(p)) for i, p in enumerate(parts)]
        checks += [(f"M3 head {i}", move(h)) for i, h in enumerate(heads)]
        for name, k in checks:
            v = (sh ^ k).volume()
            if v > 1e-6:
                bad += 1
                print("clash, Modulino %s: %-26s %.3f" % (way, name, v))
        # The plate's holes at the USB-C end must line up with the Nesso's.
        for sx in SCREW_X:
            probe = cyl_y(sx, SCREW_Z, SCREW_CLEAR_D - 0.1, N_D - 0.5, Y_BACK + 0.5)
            v = (sh ^ probe).volume()
            bad += v > 1e-6
            print("Modulino %s: screw hole at x %.0f %s" % (way, sx, "clear" if v <= 1e-6 else "BLOCKED"))
    print("clashes:", bad)
    # Shell and spacer lie on their backs, ready to slice; the references are in
    # use orientation.
    write_stl(to_print(s), f"{out}/stl/shell.stl")
    write_stl(to_print(sp, N_D), f"{out}/stl/spacer.stl")
    write_stl(nesso(), f"{out}/stl/ref_nesso.stl")
    write_stl(Manifold.batch_boolean(modulino(lo), OpType.Add), f"{out}/stl/ref_modulino.stl")
    with open(f"{out}/preview_config.json", "w") as f:
        json.dump(preview_config(lo, s), f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("print bbox", [round(v, 2) for v in to_print(s).bounding_box()])
