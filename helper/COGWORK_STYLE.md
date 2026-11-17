# Cogwork Legion art style: "Foundry Clockwork"

Every Cogwork model (robots, vehicles, set pieces, props) follows these rules.
The look extends the existing CW-7 Grindhammer tank. These machines are forged,
riveted and steam-driven. Their signature is that **you can see the gears that
make things move**.

The helpers in `parts_lib.py` (COGWORK section) carry the rules out in code. Use
them rather than hand-rolling gears.

## 1. Shape language
- Heavy riveted slabs with chamfered edges, built around boiler drums
  (`steam_boiler`) and round housings. Mass sits high and forward, so the
  machines look top-heavy and menacing.
- Everything looks bolted together from separate forged pieces. Leave visible
  seams, cradles, saddles and brackets rather than smooth blended forms.
- Use boxy chamfered sections (`chamfer_rect` lofts), not smooth aerodynamic
  curves. Flying Cogwork craft fly by brute thrust, not lift.

## 2. Colour blocking (palette `cogwork`)
| Share | Swatch | Use |
|---|---|---|
| ~55 % | Gunmetal / GunmetalDark | structure, frames, hull, housings |
| ~25 % | CogRed | armour panels only (never structure); the faction colour |
| ~10 % | Brass | every gear, toothed rim, hub, rivets on red panels, trim bands |
| ~5 % | Copper | pipes (brass joints at bends and ends) |
| accents | Rust / RustDark | boilers, stack rims, worn lower edges |
| accents | Soot / Grime / Oil | inside nozzles and stacks, under-hull wear |
| glow | `ff4a1a` red-orange (thrusters may use `ff7a2a`) | eyes, furnaces, thrusters. Nothing else glows |

Glow is **always recessed** inside geometry (sockets, grilles, nozzle bells,
stack mouths). Never use flat glowing discs on a surface (see brief, "Robot eyes").

## 3. Cog rules (the signature)
1. **Every joint is a gear.** Hinges, pivots, tilt mounts and claw knuckles show a
   brass gear on the joint axis (`cog_joint`), never a plain cylinder.
2. **Panels carry gear clusters.** Each large armour panel gets at most one
   `gear_cluster`: a big brass gear with one or two meshing smaller gears and
   CogRed hubs. Offset it to a third of the panel, never dead centre.
3. **Rotating hardware gets teeth.** Fans, turret rings, wheels and engine collars
   carry a toothed brass rim (`gear` around the housing). Fans/rotors are gears.
4. **Faction mark.** Every unit or vehicle has one `cog_mark` on its front: a brass
   gear with a recessed red lens (the "Cog Eye").
5. **Steam and pipes.** Boilers feed what they power through copper `pipe` runs.
   Exhausts are `smokestack`s with flared rust rims and an ember glow.

## 4. Eyes and sensors
- Small recessed red lenses (`cog_eye`) or slit visors with 1 to 3 lenses
  (`visor_slot`).
- Robot eyes sit inside sockets or under hoods.

## 5. Wear
- Rust and Grime go on lower edges and skids.
- Soot goes around stacks and nozzles.
- Brass stays bright, because it is polished by the machinery.

## 6. Performance
- Gears are the costly element: about 16 tris per tooth (10 teeth is about 160 tris).
- Use 6–8 teeth for gears under 1 stud and 10–12 for panel gears; keep it to 20 or
  fewer even on big rims.
- Gears never take a bevel modifier.
- Rivet rows: spacing of 1 stud or more on large panels (each rivet is about 20 tris).
