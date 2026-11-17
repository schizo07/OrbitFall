# Orbitfall art style

This is the one look for every model in the game. It comes from the call-in set in
`new-art/art/` (previews in `new-art/art/previews/`). It is built with
`helper/parts_lib.py`. The Cog faction's details are in `helper/COGWORK_STYLE.md`.

In one line: **gritty field-military low-poly**. The models are dark, heavy and
bolted together, with a few bright accents that tell you what a thing is.

## Rules for every model
1. **Hard facets.** Use flat shading and chamfered corners. Build octagon and hexagon
   sections instead of round ones. Nothing is soft, bubbly or toy-rounded.
2. **Dark base, one colour, one bright accent.** Each object has:
   - a dark structure colour (about 55 %);
   - one identity colour (about 25 %);
   - a trim colour (about 10 %);
   - small bright accents.

   Avoid large areas of saturated colour.
3. **Silhouette first, then detail.** Get the big shape readable from 40 studs.
   Then add small, cheap detail:
   - bolts;
   - vents;
   - stencil glyphs;
   - hazard strips;
   - antennas;
   - lamps;
   - feet and brackets.
4. **Looks built, not sculpted.** Show seams, plates, hinges, legs and brackets.
5. **Glow is rare and recessed.** It only goes in lamps, eyes, nozzles and cores, and
   sits inside a socket or grille. Glow colour tells you the side:
   - squad: warm amber `ffb347`, or cyan `4fd8ff` for holo and shields;
   - Cog: `ff4a1a`;
   - Brood: green;
   - Lumen: violet.
6. **Wear:** grime on lower edges and soot around exhausts. Trim stays clean.
7. **Original marks only.** Use abstract stencil glyphs, never real logos or insignia
   from other games.

## Families
| Family | Palette | Structure | Identity | Trim | Accent |
|---|---|---|---|---|---|
| **Squad / call-ins / objectives / camps** | `human` | Charcoal, CharcoalDark | Tan armour plates (Olive for ammo and ordnance) | Steel bolts, Stencil glyphs | Hazard yellow-black strips, Orange caps and handles |
| **Cog** | `cogwork` | Gunmetal | CogRed armour panels | Brass gears, Copper pipes | Rust, red-orange glow |
| **Brood** | `brood` | Chitin, Carapace | Bone plates | Membrane | Goo green glow |
| **Lumen** | `lumen` | Obsidian, Slate | Pearl ceramic plates | Gold trim | Violet cores |
| **Environment** | `terrain` | Rock, RockDark | Biome tone (Sand, Ash, Ice, Moss, crystal) | RockLight strata bands | none (crystal biome only) |

## Environment rules
- Rocks are hard-faceted, low-poly and flat-shaded. Use `rock`, `rock_fin` and
  `strata_block`, with 2–3 tone strata bands.
- Keep them muted and slightly darker than the ground, so units, call-ins and
  objectives stay the brightest things on screen.
- Big rocks are about 80–300 tris and rubble is 120 or fewer. Few parts per model.
- Camp props, crates, barricades and wrecks use the **Squad** family, with extra
  grime.
- Cog barricades and pylons use **Cog**, and Brood mounds use **Brood**.

## Older assets
The first-pass models in `art/blender/` (orange and cream, rounded) don't match this
style. They will be rebuilt:
- enemies in their faction family;
- objectives, generator, silo and so on in the Squad family;
- rocks and props per the environment rules.
