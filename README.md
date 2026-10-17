# Mekong

Real-time, audio-reactive visuals for projecting behind improvised guitar over drones.
Abstract, monochrome, data-driven (after Ryoji Ikeda): no waveforms, no EQ bars.

    ./build.sh            # debug build + launch
    ./build.sh release    # optimised build → dist/Mekong.app

Keys (console focused): **P** present · **Esc** stop · **Space** blackout · **1–6** scene.

- Input: any CoreAudio input, a single channel of a multi-channel interface, or the built-in test signal.
- The screensaver and display sleep are held off while presenting.
- `Mekong --snapshot <dir>` renders each scene from the test signal to PNG (headless check).
