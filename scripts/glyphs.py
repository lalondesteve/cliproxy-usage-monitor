# Generates the compact menubar icons in assets/icons: python3 scripts/glyphs.py {spokes|ring} "#ffffff" {3|4}
import math, re, sys
C = 12.0
SW = 1.5          # stroke width for arms and open rings
DOT = 2.5         # filled node radius
RING = 1.85       # open node radius (stroke centerline)

def pt(r, a):
    a = math.radians(a)
    return (C + r * math.cos(a), C + r * math.sin(a))

def f(v): return f"{v:.2f}".rstrip('0').rstrip('.')

def arc_center(p, q, R, sweep):
    mx, my = (p[0]+q[0])/2, (p[1]+q[1])/2
    dx, dy = q[0]-p[0], q[1]-p[1]
    d = math.hypot(dx, dy); h = math.sqrt(R*R - d*d/4)
    nx, ny = -dy/d, dx/d
    s = 1 if sweep else -1
    return (mx + s*nx*h, my + s*ny*h)

def trim_end(p, q, R, sweep, cut):
    # point on the arc p->q (radius R) at chord distance `cut` before q
    cx, cy = arc_center(p, q, R, sweep)
    aq = math.atan2(q[1]-cy, q[0]-cx)
    da = 2*math.asin(cut/(2*R))
    a = aq - da if sweep else aq + da
    return (cx + R*math.cos(a), cy + R*math.sin(a))

def svg(body, ink):
    # fit the drawing's bounding box (from its circles) into 1..23, centered
    xs0, ys0, xs1, ys1 = [], [], [], []
    for cx, cy, r, filled in re.findall(r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"( fill)?', body):
        cx, cy = float(cx), float(cy); r = float(r) + (0 if filled else SW / 2)
        xs0.append(cx - r); xs1.append(cx + r); ys0.append(cy - r); ys1.append(cy + r)
    x0, x1, y0, y1 = min(xs0), max(xs1), min(ys0), max(ys1)
    s = 22 / max(x1 - x0, y1 - y0)
    tx, ty = 12 - s * (x0 + x1) / 2, 12 - s * (y0 + y1) / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
            f'<g transform="translate({f(tx)} {f(ty)}) scale({s:.3f})" fill="none" stroke="{ink}" stroke-width="{SW}">{body}</g></svg>')

def spokes(ink, n=3):
    # n nodes near the center, each sending a curved arm out to an open node
    global DOT, RING
    DOT, RING = 2.5, 1.85
    out = []
    dist, reach, turn, R = {3: (3.6, 8.9, 95, 7.0), 4: (4.4, 9.4, 80, 7.0)}[n]
    for k in range(n):
        a = -60 + 360/n*k
        d, e = pt(dist, a), pt(reach, a + turn)
        end = trim_end(d, e, R, True, RING)
        out.append(f'<path d="M{f(d[0])} {f(d[1])}A{R} {R} 0 0 1 {f(end[0])} {f(end[1])}"/>')
        out.append(f'<circle cx="{f(e[0])}" cy="{f(e[1])}" r="{RING}"/>')
        out.append(f'<circle cx="{f(d[0])}" cy="{f(d[1])}" r="{DOT}" fill="{ink}" stroke="none"/>')
    return svg(''.join(out), ink)

def ring(ink, n=3):
    # n arcs on one circle, filled node at the start, open node at the end
    global DOT, RING
    DOT, RING = (2.5, 1.85) if n == 3 else (2.1, 1.55)
    R, span, out = {3: (8.7, 78), 4: (9.4, 58)}[n] + ([],)
    for k in range(n):
        a = -114 + 360/n*k
        s, e = pt(R, a), pt(R, a + span)
        cut = trim_end(s, e, R, True, RING)
        out.append(f'<path d="M{f(s[0])} {f(s[1])}A{R} {R} 0 0 1 {f(cut[0])} {f(cut[1])}"/>')
        out.append(f'<circle cx="{f(e[0])}" cy="{f(e[1])}" r="{RING}"/>')
        out.append(f'<circle cx="{f(s[0])}" cy="{f(s[1])}" r="{DOT}" fill="{ink}" stroke="none"/>')
    return svg(''.join(out), ink)

which, ink = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 3
print({'spokes': spokes, 'ring': ring}[which](ink, n))
