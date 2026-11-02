# Yasin's Tweaks

Tweaks for rootless jailbreaks (such as Dopamine). Settings live in the **XS Tweaks** app on the home screen, because PreferenceLoader (2.2.8) doesn't load into the iOS 18 Settings app.

| Package | What it does | Installs on |
|---|---|---|
| [**CarCast**](#carcast) | Run any app on CarPlay, with per-app settings and iPad layouts (e.g. a YouTube video grid). | iOS 17+ |
| [**XS Tweaks**](#xs-tweaks) | Settings app for CarCast, LineFix and SpeedBoost. Shows pages only for the tweaks you have installed. | iOS 15+ |
| [**LineFix**](#linefix) | Makes a broken vertical screen line (the green/pink line some OLED iPhones develop) much less visible. | iOS 15+ |
| [**SpeedBoost**](#speedboost) | Faster home screen animations and fewer heavy background services. | iOS 15+ |

## Add the repo to Sileo

1. Open **Sileo** and go to the **Sources** tab.
2. Tap **+** (top right).
3. Enter `https://zephyranthess.github.io/yasin-tweaks/` and tap **Add Source**.
4. Open the **Yasin's Tweaks** source and install what you want. Install **XS Tweaks** too, to get the settings.
5. Tap **Respring** when Sileo asks.

You can also download the `.deb` files from [`docs/debs/`](docs/debs) and open them with Sileo or Filza.

---

## CarCast

Shows your apps on the CarPlay home screen and runs them on the car's display.

- Each app gets a window shaped like the car screen and lays itself out to fill it. Any screen size works (tested with simulated 800×480, 1280×720 and 1920×720 screens).
- **iPad layout:** apps that also have an iPad version (YouTube, Netflix…) can use their iPad design, e.g. a grid of videos instead of one huge video. CarCast restarts the app when you open or close it on CarPlay, because apps choose their layout when they start.
- A side dock on the car screen has a **home** button (closes the app), a button to switch between the **car-shaped and phone-shaped** layout, and, in the phone-shaped layout, a **fit / fill** button.
- Apps that already have their own CarPlay version (Spotify, WhatsApp, YouTube Music…) are left alone.

### Settings (XS Tweaks → CarCast)

| Setting | Options |
|---|---|
| iPad layout | On / Off (default: On) |
| Dock side | Left / Right |
| Text size | Large / Normal / Small: how far the app is zoomed on the car screen |
| Apps on CarPlay | Show or hide each app, or Show all / Hide all |
| Per app (tap an app) | Show on CarPlay; iPad layout Automatic / Always / Never; Test on phone |
| Test on the phone | Runs any app inside a fake car screen on the phone, with a simulated screen size |

Showing or hiding apps takes effect the next time you connect to CarPlay. Dock side and text size update right away.

### Compatibility

| iOS | Status |
|---|---|
| 18.1.1 | Tested on an iPhone XS Max: CarPlay app list, app hosting, dynamic sizing, iPad layout and all settings, using the phone test mode. |
| 17.7, 18.6.2, 26.6.2, 27.2 | Checked against Apple's firmware for each version: every private iOS API that CarCast uses has a working code path. Not yet tested on devices running these versions. |

**Not yet tested in a real car.** The parts that only run with a car connected (opening an app on the car display and touch input from the car's screen) have not been tried yet. Please test while parked, and report what happens.

CarCast checks at runtime which iOS APIs exist. If an optional one is missing it skips that feature instead of crashing, and it logs which code path it used.

### Known limitations

- Rootless jailbreaks only. roothide is not supported.
- iPad layout restarts the app when it opens or closes on CarPlay.
- On iOS 27, CarCast can't tell whether the app is also open on the phone, so it may restart the app when you close it on CarPlay.
- Built and tested for iPhone.

### Reporting a problem

Open an [issue](../../issues) with your device, iOS version and jailbreak, and attach these log files:

- `/var/mobile/Library/Logs/CarCast.log`
- `/var/mobile/Library/Logs/CarCast-CarPlay.log` (or `/var/tmp/CarCast-CarPlay.log`)

---

## XS Tweaks

A home screen app with the settings pages for the other tweaks. Needed because PreferenceLoader (2.2.8) doesn't load into the iOS 18 Settings app, so tweak pages don't appear there. Tested on iOS 18.1.1.

## LineFix

Draws a thin strip, always on top, over a broken pixel column and lets you tune its color so the line blends in. A broken column can't be repaired in software; the goal is a faint neutral line instead of a bright green or pink one.

1. XS Tweaks → LineFix. With **Find mode** on, a red strip appears. Move it with the buttons until it covers the line (it turns yellow when it sits exactly on a green line).
2. Turn **Find mode** off and raise **Red** and **Blue** together until the line looks neutral grey on both dark and white screens.

The strip also appears in screenshots. Tested on iOS 18.1.1.

## SpeedBoost

- Speeds up home screen animations (app open/close, app switcher, folders, Control Center). Adjustable from 1.0× to 3.0× (default 1.6×). Animations inside apps are unchanged.
- Switches for Reduce Transparency (no blur) and Reduce Motion, the same as in Settings › Accessibility.
- On install, turns off these background services: Photos analysis (`photoanalysisd`, `mediaanalysisd`), iOS update downloads (`softwareupdated`, `softwareupdateservicesd`), analytics (`analyticsd`, `geoanalyticsd`, `wifianalyticsd`, `inputanalyticsd`) and Tips (`tipsd`). Uninstalling SpeedBoost turns them back on. Manual control over SSH: `sudo speedboost-services enable | disable | status`.

Side effects: Settings › General › Software Update won't load, and Photos stops creating Memories and recognizing people. The services are disabled through launchd, so they stay off after a reboot until SpeedBoost is uninstalled (while jailbroken). Tested on iOS 18.1.1.

---

## Building from source

Requires macOS with Xcode, [Theos](https://theos.dev) (with the iOS 16.5 SDK from [theos/sdks](https://github.com/theos/sdks)), `ldid` and `dpkg`.

```sh
cd CarCast && make package FINALPACKAGE=1    # same for LineFix, SpeedBoost, XSTweaksApp
```

- `make package FINALPACKAGE=1 CC_DEBUG=1` builds CarCast with test helpers for [`CarCast/tools/carcastctl.m`](CarCast/tools/carcastctl.m) (`launch`, `close`, `snapshot`, `wake`, `cpdebug` over SSH). Don't ship debug builds.
- `scripts/update-repo.sh` regenerates the Sileo index in `docs/` after you put new `.deb` files in `docs/debs/`.

### Checking a new iOS version

[`compat/api_manifest.txt`](compat/api_manifest.txt) lists every private iOS API the tweaks use, with alternative routes where iOS versions differ. [`compat/check_firmware.py`](compat/check_firmware.py) checks them against a firmware's dyld shared cache using [ipsw](https://github.com/blacktop/ipsw):

```sh
ipsw download ipsw --device iPhone12,1 --build <build> --dyld --dyld-arch arm64e
python3 compat/check_firmware.py <path>/dyld_shared_cache_arm64e <ios-version>
```

Results for 17.7, 18.6.2, 26.6.2 and 27.2 are in [`compat/`](compat).

## Contributing

Issues and pull requests are welcome. Only the maintainer can merge into `main`.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Credits

Huge thanks to **Ethan Arbuckle** ([@EthanArbuckle](https://github.com/EthanArbuckle)) for [carplay-cast](https://github.com/EthanArbuckle/carplay-cast), the original "any app on CarPlay" tweak. CarCast is built on his research and code (Apache License 2.0), and this repository is open source, as he asks of projects that use it. His license and a list of changes also ship inside the CarCast package (`/var/jb/usr/share/doc/com.yasin.carcast/`).

Built with [Theos](https://theos.dev). Firmware analysis with [ipsw](https://github.com/blacktop/ipsw).
