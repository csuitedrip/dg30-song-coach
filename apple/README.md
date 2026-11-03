# Song Coach for iPhone, iPad and Mac

A native app around the Song Coach website (https://kerrymelchior-ux.github.io/dg30-song-coach/).
It loads the live site, so every update to the website shows up in the app automatically.

Why an app: Safari on iPhone and Mac can't use Bluetooth or MIDI from a web page, so the website
can't reach the Kawai DG30 there. This app adds `window.SCNative` — the same bridge the Android app
provides — so the page's existing "inside the app" code path runs:

- Pianos connect through Apple's own MIDI system (USB cable or Bluetooth MIDI).
- "Find my piano" opens Apple's Bluetooth MIDI pairing screen; when the piano appears, the page is told it connected.
- Microphone (tuner, karaoke, Wait mode), saving and sharing files, "now playing", background audio.

## Build
Open `SongCoach.xcodeproj` in Xcode, pick a destination (My Mac, an iPhone simulator, or Kerry's iPhone), press Run.
For a real iPhone: Xcode › Settings › Apple Accounts must have admin@csuitedrip.com, then pick its Personal Team
under the target's Signing & Capabilities. Free signing: the app must be reinstalled every 7 days.

Bundle id: com.csuitedrip.songcoach
