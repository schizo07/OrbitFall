import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
from kit import Part
import tinker, rivet, bulwark, colossus

kit.reset()
# front row (small -> large), Colossus looming behind
cap = Part("Player", (150, 154, 160), "SmoothPlastic", "body")
cap.cyl(1.0, 3.0, (0, 0, 2.5), verts=24, bevel=0)
cap.ball(1.0, (0, 0, 1.0), segs=24)
cap.ball(1.0, (0, 0, 4.0), segs=24)
cap.build()
cap.obj.location.x = -14.5
tinker.build(-9.0, 0)
rivet.build(-1.0, 0)
bulwark.build(11.5, -1.0)
colossus.build(2.5, 15.0)
kit.stage(target=(3.0, 9.0, 9.5), dist=90, height=30, yaw=0, size=(900, 700), ortho=54, floor=(90, 60))
kit.render("cog_lineup")
