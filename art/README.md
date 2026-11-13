# OrbitFall assets

Every model in the game is built from Python scripts in Blender (`blender/`). Each one is exported as an FBX (`fbx/`) and rendered to a PNG (`images/`).

| Folder | Contents |
|---|---|
| `images/` | One PNG render per asset, plus lineups. PNGs only. |
| `fbx/` | Exported meshes. `manifest.json` lists the parts, pivots, palette and weak spots of each one. |
| `blender/` | The scripts that build the models. Run one with `blender -b --python <name>.py`. |
| `textures/` | Faction palette textures. |
| `tools/` | `gen_meshes.py` writes `src/shared/Data/Meshes.luau` from the manifest. |

`SINGLES=1 blender -b --python weapons.py` re-renders the individual weapon images without re-exporting any FBX.

## Image gallery

### Weapons

| | | | |
|:-:|:-:|:-:|:-:|
| ![PR-7 Pulse Carbine](images/wpn_carbine.png)<br>PR-7 Pulse Carbine | ![SG-4 Breacher Scatter](images/wpn_shotgun.png)<br>SG-4 Breacher Scatter | ![MR-9 Longwatch](images/wpn_marksman.png)<br>MR-9 Longwatch | ![SM-2 Buzz SMG](images/wpn_smg.png)<br>SM-2 Buzz SMG |
| ![Rocket Tube](images/wpn_rocket_tube.png)<br>Breacher Rocket Tube | ![Thrum Gatling](images/wpn_gatling.png)<br>Thrum Gatling | ![Rail Lance](images/wpn_rail_lance.png)<br>Rail Lance | ![P-3 Sidearm](images/wpn_pistol.png)<br>P-3 Sidearm |
| ![Frag Grenade](images/wpn_frag_grenade.png)<br>Frag Grenade | ![Impact Grenade](images/wpn_impact_grenade.png)<br>Impact Grenade | ![Stun Grenade](images/wpn_stun_grenade.png)<br>Stun Grenade | ![Call-in Beacon](images/wpn_beacon.png)<br>Call-in Beacon |

![Weapon lineup](images/wpn_lineup.png)

### The Cogwork Legion (robots)

| | | | |
|:-:|:-:|:-:|:-:|
| ![Tinker Drone](images/tinker.png)<br>Tinker Drone | ![Rivet Trooper](images/rivet.png)<br>Rivet Trooper | ![Bulwark](images/bulwark.png)<br>Bulwark | ![Strider Colossus](images/colossus.png)<br>Strider Colossus |

![Cogwork lineup](images/cog_lineup.png)

### The Skitter Brood (bugs)

| | | | |
|:-:|:-:|:-:|:-:|
| ![Skitterling](images/skitter.png)<br>Skitterling | ![Spitter](images/spitter.png)<br>Spitter | ![Carapace Charger](images/charger.png)<br>Carapace Charger | ![Hive Titan](images/titan.png)<br>Hive Titan |

![Brood lineup](images/brood_lineup.png)

### Animation rigs

| | | | |
|:-:|:-:|:-:|:-:|
| ![Tinker rig](images/tinker_rig.png)<br>Tinker | ![Rivet rig](images/rivet_rig.png)<br>Rivet | ![Bulwark rig](images/bulwark_rig.png)<br>Bulwark | ![Colossus rig](images/colossus_rig.png)<br>Colossus |
| ![Skitter rig](images/skitter_rig.png)<br>Skitterling | ![Spitter rig](images/spitter_rig.png)<br>Spitter | ![Charger rig](images/charger_rig.png)<br>Charger | ![Titan rig](images/titan_rig.png)<br>Hive Titan |
| ![Tinker pivots](images/tinker_rig_pivots.png)<br>Tinker pivots | ![Skitter pivots](images/skitter_rig_pivots.png)<br>Skitterling pivots | | |

### Trooper armour

| | |
|:-:|:-:|
| ![Armour front](images/armor_kit_front.png)<br>Front | ![Armour back](images/armor_kit_back.png)<br>Back |

### Objectives and set pieces

| | | | |
|:-:|:-:|:-:|:-:|
| ![Missile Silo](images/set_missile_silo.png)<br>Missile Silo | ![Trajectory Console](images/set_trajectory_console.png)<br>Trajectory Console | ![Uplink Dish](images/set_uplink_dish.png)<br>Uplink Dish | ![Generator](images/set_generator.png)<br>Generator |
| ![Fabricator](images/set_fabricator.png)<br>Fabricator | ![Sample Pod](images/set_sample_pod.png)<br>Sample Pod | ![Extraction Pad](images/set_extraction_pad.png)<br>Extraction Pad | ![Skiff](images/set_skiff.png)<br>Skiff |
| ![Courier Wreck](images/set_courier_wreck.png)<br>Courier Wreck | | | |

### Environment

| | | | |
|:-:|:-:|:-:|:-:|
| ![Rock A](images/env_rock_a.png)<br>Rock A | ![Rock B](images/env_rock_b.png)<br>Rock B | ![Rock C](images/env_rock_c.png)<br>Rock C | ![Supply Crate](images/env_supply_crate.png)<br>Supply Crate |
| ![Cog Barricade](images/env_cog_barricade.png)<br>Cog Barricade | ![Cog Pylon](images/env_cog_pylon.png)<br>Cog Pylon | ![Hive Mound](images/env_hive_mound.png)<br>Hive Mound | ![Crystal Cluster](images/env_crystal_cluster.png)<br>Crystal Cluster |
| ![Spire A](images/env_spire_a.png)<br>Spire A | ![Spire B](images/env_spire_b.png)<br>Spire B | | |

![Environment kit](images/env_kit.png)
