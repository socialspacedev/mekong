/// Written into the Scenes folder the first time Mekong creates it.
enum CustomScenesGuide {
    static let readme = """
    MEKONG — YOUR OWN SCENES
    ========================

    Easiest: use "Add scene…" in Mekong's console, or drag files onto the scene
    list. You can set an image's name, style and black-and-white there too.

    Anything you put in this folder shows up in Mekong's scene list within a
    second or so. No rebuild, no restart. Edit a file while it's on the wall
    and the change appears straight away. Delete a file to remove its scene.


    1. IMAGE SCENES
    ---------------
    Drop in a picture (PNG, JPEG, HEIC, TIFF, GIF, WebP). It becomes a scene,
    played by the sound in the "drift" style.

    To choose a style or name, select the scene in Mekong and use the controls
    under the scene list. (They save a JSON file with the same name beside the
    image, which you can also write by hand.)
    For "lambeth.jpg" that's "lambeth.json":

        {
          "name": "Lambeth",
          "description": "Shown under the scene buttons.",
          "style": "slices",
          "mono": false
        }

    Every field is optional. Styles:

        drift   slow zoom and pan, breathing with loudness; attacks split the colour
        slices  vertical strips that slip with the sound and scatter on attacks
        scan    one-bit black and white, thresholded by loudness, rows torn by attacks
        mosaic  a grid of cells, each row lit by its part of the sound

    "mono": true draws it in monochrome and follows the White / Tint / Inverted
    palette. The Density slider changes slices and mosaic.


    2. SHADER SCENES (.metal)
    -------------------------
    For anything else, write a Metal function. The file needs exactly one
    entry point, called `scene`, that returns the colour of one pixel:

        // Name: My Scene
        // Description: One line shown in the console.

        float3 scene(float2 px, constant U& u, constant float* b) {
            float2 uv = px / float2(u.width, u.height);   // 0…1 across the screen
            return mono(u.level * uv.x, u);
        }

    You can add your own helper functions in the same file; each file is
    kept separate, so names never clash with another file.

    What you get, all smoothed and 0…1 unless noted:

        u.level      loudness
        u.onset      jumps up on each attack (a picked note), then decays
        u.seed       counts attacks — use it to re-randomise on each note
        u.low / u.mid / u.high   energy in three regions of the sound
        u.centroid   brightness of the sound (dull → bright)
        band(b, i)   energy in band i of 32, low (0) to high (31)
        u.tick       a clock that runs faster when you play louder
        u.scroll     a slower clock for drifting motion (both follow Motion)
        u.time       seconds since launch
        u.density    the Density slider
        u.width, u.height   the output size in pixels

    Helpers: h11(x) and h21(xy) give stable random numbers 0…1, vnoise(xy)
    gives smooth noise, mono(v, u) turns a 0…1 value into the palette colour.
    Return float3(r, g, b) for colour. Brightness, the CRT start/stop,
    crossfades and blackout are applied for you.

    Mistakes don't break anything: a file that doesn't compile is listed
    under "Your scenes" in the console with the compiler's message (file and
    line number), and the other scenes keep working. Fix it and save.

    Tide.metal is an example to copy from. Edit it or delete it.

    Tip: you can describe a scene to Claude and ask for a .metal file for
    Mekong. Point it at this README.
    """

    static let example = """
    // Name: Tide
    // Description: Soft swells that rise with the drone; attacks scatter light. An example — edit or delete me.

    float3 scene(float2 px, constant U& u, constant float* b) {
        float2 uv = px / float2(u.width, u.height);
        float v = 0.0;
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float y = 0.5 + 0.35 * sin(u.scroll * (0.6 + fi * 0.13) + fi * 1.7);
            float width = 0.003 + 0.025 * band(b, fi * 5.0);
            float d = (uv.y - y) / width;
            v += exp(-d * d) * (0.15 + 0.6 * u.level);
        }
        v += u.onset * step(0.96, vnoise(px * 0.05 + u.seed));
        return mono(v, u);
    }
    """
}
