import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
from kit import Part
import env_rocks as R
import env_props as P

kit.reset()
cap = Part("Player", (150, 154, 160), "SmoothPlastic", "body")
cap.cyl(1.0, 3.0, (0, 0, 2.5), verts=24, bevel=0)
cap.ball(1.0, (0, 0, 1.0), segs=24)
cap.ball(1.0, (0, 0, 4.0), segs=24)
cap.build()
cap.obj.location.x = -60.0
cap.obj.location.y = -14.0

# back row: tall spires
R.spire_a(-55, 40)
R.spire_b(6, 46)
# mid row
R.rock_c(-50, 0)
R.rock_b(-33, 4)
R.rock_a(-20, 2)
R.crystal_cluster(-8, 0)
P.build_one("hive_mound", 52, 8)
P.build_one("cog_pylon", 34, 6)
# front row
P.build_one("cog_barricade", 14, -4)
P.build_one("supply_crate", 0, -8)
P.build_one("supply_crate", 4.2, -8.2)
kit.stage(target=(0, 12, 20), dist=170, height=40, yaw=0, size=(1600, 860), ortho=150, floor=(190, 100), boost=1.0)
kit.render("env_kit")
