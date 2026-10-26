# How to run NearbyChat (2 laptops + 1 Android phone)

Bluetooth only: no internet, no WiFi, no pairing, no server.

| Folder | Put it on | Start | Read |
|---|---|---|---|
| `FOR_ANDROID` | the Android phone | install `NearbyChat.apk` | `FOR_ANDROID/README.md` |
| `FOR_LAPTOP` | both laptops (Python 3.11+ installed once) | `START_LAPTOP_NODE.bat` | `FOR_LAPTOP/README.md` |

Quick start:
1. Phone: install `FOR_ANDROID/NearbyChat.apk`, open it, enter a name, allow Nearby devices and
   Location, Bluetooth on.
2. Laptops: Bluetooth on, double click `FOR_LAPTOP/START_LAPTOP_NODE.bat`, names `LaptopA` and
   `LaptopB`. The local page opens at http://127.0.0.1:8765.
3. Within about 15 s every device lists the other two. Chat privately between any pair, or
   everyone together in `#nearby`. Devices out of direct range are reached through the others.
4. Step by step demo with the attacks: `DEMO_GUIDE.md`.

Developer files: app source `nearby_chat/`, mesh simulation `mesh_simulation/`, build scripts
`tools/` (`tools/BUILD_APK.bat` rebuilds the APK into `FOR_ANDROID`).
