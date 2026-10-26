# NearbyChat: Teammate Quick Start

Everything for the NearbyChat project (Design and Security Analysis of a Secure Peer to Peer Mesh
Communication System): app code, mesh simulation, documents, slides and browser demos.

## What is where

| Path | What |
|---|---|
| `README.md` | Overview, status, security design |
| `PROJECT_CONTEXT.md` | Full architecture and protocol details |
| `nearby_chat/` | Flutter app (Android / iOS), 34 tests |
| `mesh_simulation/` | Python mesh simulation, 21 tests, experiments, dashboard |
| `mesh_simulation/results/` | Experiment CSVs, charts and `SUMMARY.md` for the report |
| `nearbychat_demo.html`, `nearbychat_relay_demo.html` | Browser demos, double click to open |
| `tools/` | Windows helpers for Flutter and the Android SDK |

## Flutter app

Windows shortcut: double click `tools/START_FLUTTER_TOOLS.bat` (installs git and Flutter if
missing, then runs analyze and test), then `tools/SETUP_ANDROID_SDK.bat` and
`tools/FIX_ANDROID_BUILD.bat` once to be able to build an APK.

Manual:
```bash
cd nearby_chat
flutter pub get
flutter analyze
flutter test
flutter run          # phone connected over USB, developer mode and USB debugging on
```
Testing on phones: install on two phones, open the app on both, allow Bluetooth (and location on
older Android), pick different names. Each phone should appear in the other's Nearby list. Open a
chat, compare the safety number, send a message and wait for the double tick (delivered).

## Mesh simulation

```bash
pip install -r mesh_simulation/requirements.txt
python -m pytest mesh_simulation/tests -v
python -m mesh_simulation.experiments.run_experiments     # regenerates results/
python -m mesh_simulation.dashboard.app                   # open http://127.0.0.1:5000
```
Mininet-WiFi (Ubuntu, root): see `mesh_simulation/README.md`.

## Demo order for a review

1. Slides: problem, existing systems, design.
2. Dashboard: send A to D, cut link B-D and watch the route move to A-C-E-D, make B a dropper,
   run the tamper, replay and intruder attacks and show the security log.
3. Results: charts in `mesh_simulation/results/charts/`.
4. App: two phones exchanging an encrypted message, safety number comparison.
