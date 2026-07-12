# Vol

`Vol` is a small macOS menu bar app for using a keyboard volume knob with an
Audient iD14 MKII. It lowers the digital audio signal before it reaches the
interface; it does not alter the iD14's physical monitor-volume control.

## 남은 작업 목록
- 볼륨 퍼센트 지수적으로 바뀌도록 (현재는 선형적인거 같고, 70만 되도 거의 안들림)
- 애플리케이션 아이콘 클릭해서 volidge 실행하면 바로 라우팅 시작하도록.
- 메뉴 아이콘 클릭했을 때 "Open Sound Settings" 지우기
- virtual audio device, Play through 이름이 좀 직관적이지 않음.
- 메뉴 아이콘 클릭했을 때 맨 윗줄 상태 메세지? 그거 필요한가 싶음.
- Mute 없어도 될듯.
- dmg 파일 배경 좀 더 이쁘게

## What it needs

- macOS 14 or later
- [BlackHole 2ch](https://existential.audio/blackhole/) installed as a free
  virtual audio device
- An iD14 MKII connected as the output device

BlackHole is the audio pipe: Vol makes it the macOS output, receives that
audio, applies the requested gain, and plays it through the iD14.

Vol follows the macOS system-volume curve once. It deliberately does not apply
the same gain a second time in its audio bridge, so lower keyboard-knob values
remain usable instead of becoming abruptly quiet.

When routing starts, Vol temporarily matches BlackHole's sample rate to the
iD14's active sample rate. This prevents silent routing when, for example,
BlackHole is at 44.1 kHz and the iD14 is at 48 kHz.

Vol sends a stereo signal to the iD14's first two playback channels, so it also
works with `BlackHole 16ch` rather than requiring the 2-channel edition.

## Build and run

```sh
cd /Users/juno/Desktop/vol
chmod +x scripts/build_app.sh
scripts/build_app.sh
open dist/Vol.app
```

If Desktop is synchronised by iCloud or another file provider, install the app
outside Desktop instead. File-provider metadata can invalidate an ad-hoc app
signature between launches:

```sh
scripts/install_app.sh
open ~/Applications/Vol.app
```

The installed app enables **Launch at Login** automatically. You can turn it
off or on again from Vol's menu.

## Drag-and-drop installer

Create a standard macOS disk image with a drag-to-install background, `Vol.app`,
and an `Applications` shortcut:

```sh
scripts/create_dmg.sh
open release/Vol.dmg
```

Drag `Vol.app` onto the `Applications` shortcut in the disk image, then open
Vol from `/Applications`.

On first start, allow microphone access when macOS asks. The permission is
required because macOS treats the virtual audio input as a microphone. If the
keyboard knob does not change the Vol percentage, allow Vol in **Privacy &
Security → Input Monitoring**, quit Vol, then open it again.

## Use

1. In the Vol menu, choose `BlackHole 2ch` under **Virtual audio device**.
2. Choose `iD14 MKII` under **Play through**.
3. Click **Start routing**.
4. Use the keyboard volume knob; the menu bar percentage changes in 5% steps.

Vol restores the prior default output devices when you stop routing or quit the
app. It does not change your default microphone input.

## Limits

- Apps or DAWs explicitly configured to output directly to the iD14 bypass Vol.
- iD14 direct-monitoring audio does not pass through Vol, so its level remains
  controlled by the interface itself.
- The iD14's front-panel LEDs and physical encoder do not move when Vol changes
  the digital level.
