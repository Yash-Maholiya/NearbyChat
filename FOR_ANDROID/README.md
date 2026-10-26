# NearbyChat on the Android phone

`NearbyChat.apk` is the phone app (release build, about 17 MB, for 64 bit ARM phones, which is
practically every Android phone from the last several years).

It works like bitchat: no internet, no account, no SIM, no pairing. Phones (and the laptops
running `FOR_LAPTOP`) find each other over Bluetooth LE and every device relays for the others,
so messages hop from device to device to reach people out of direct range.

## Install

1. Send `NearbyChat.apk` to the phone (USB cable file copy, pen drive with OTG, or anything you
   have; it is a normal file).
2. Tap it. If asked, allow **Install unknown apps** for the app you opened it with (Files /
   WhatsApp / Drive), then Install. If Play Protect warns, choose "Install anyway" (it is not
   from the Play Store).
3. Installing over an older NearbyChat keeps your identity and chats.

USB alternative: with **USB debugging** on (Settings > About phone > tap Build number 7 times >
Developer options), plug into the PC with Flutter and run `tools\BUILD_APK.bat`; it builds,
installs and opens the app.

## First start

1. Open **nearby_chat**, enter a name (for example `Rohan`).
2. Allow **Nearby devices** and **Location** (Android needs them for Bluetooth scanning; no
   location is used or sent).
3. Turn Bluetooth on. Scanning and advertising start by themselves (the radar button at the top
   stops and starts them). You can turn mobile data and WiFi off; the app does not use them.

## Use

* **#nearby** (top of the list): public room. Everyone in the mesh sees it. Messages are signed,
  so nobody can post under someone else's name, but they are **not** encrypted.
* Below it, people:
  * no tag, with dBm: in direct Bluetooth range.
  * `linked`: a laptop that connected to the phone itself (reverse link mode).
  * `mesh, N hops`: out of direct range; their signed announce reached you through relays.
    You can still chat: the message is flooded through the mesh.
* Tap a person to chat privately. Messages are end to end encrypted; relays cannot read them.
  Status: sending, sent, delivered (delivered = the recipient sent back an authenticated ACK).
* **Safety number** (in a chat): compare it with the one on the other device. Same number means no
  man in the middle. Mark it verified.
* Failed messages are queued and resent automatically when that person becomes reachable again
  (or tap to retry).
* The `#nearby` tile shows how many packets this phone has relayed for others.

Keep the app open on screen during the demo: Android restricts Bluetooth for apps in the
background.

## Rebuilding

On the PC with Flutter: double click `tools\BUILD_APK.bat` in the main project folder. It runs
`flutter analyze` and all tests, builds the APK and copies it into this folder.
