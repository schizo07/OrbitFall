import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
from kit import Part
import skitter, spitter, charger, titan

kit.reset()
cap = Part("Player", (150, 154, 160), "SmoothPlastic", "body")
cap.cyl(1.0, 3.0, (0, 0, 2.5), verts=24, bevel=0)
cap.ball(1.0, (0, 0, 1.0), segs=24)
cap.ball(1.0, (0, 0, 4.0), segs=24)
cap.build()
cap.obj.location.x = -26.0
skitter.build(-20.0, 0)
spitter.build(-10.5, 0)
charger.build(5.0, 0)
titan.build(27.0, 13.0)
kit.stage(target=(3.0, 6.0, 8.5), dist=120, height=40, yaw=0, size=(1300, 700), ortho=78, floor=(100, 60), boost=1.6)
kit.render("brood_lineup")
