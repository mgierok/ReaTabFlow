# ReaTabFlow

ReaTabFlow displays guitar tablature directly on MIDI items in REAPER's arrange view. Each number shows which fret to play and sits where the note starts. Notes in a chord line up vertically. You can play, move, and edit the items as usual.

## Setup

ReaTabFlow was developed for REAPER 7.86 and requires js_ReaScriptAPI. To install the extension through ReaPack, open **Extensions → ReaPack → Browse packages…**, find **js_ReaScriptAPI**, mark it for installation, click **Apply**, and restart REAPER. [js_ReaScriptAPI repository](https://github.com/juliansader/js_ReaScriptAPI)

1. Open **Actions → Show action list…** and select the **Main** section. Choose **New action… → Load ReaScript…** and select **ReaTabFlow.lua**. Keep the file in that location so REAPER can find it.
2. Drag a MIDI file into the arrange view. You can try the included [guitar example](examples/Guitar.mid).
3. Select one or more guitar tracks in the track control panel. Find **ReaTabFlow** in the action list and click **Run**.
4. Increase the track height until the fret numbers are easy to read. For a dense riff, zoom in horizontally as well. Run the action again to turn off the display. You can assign a keyboard shortcut in the action list.

## Reading the tablature

- In standard guitar tuning, the lines run from **high E, B, G, D, A, to low E**. A zero means an open string. ReaTabFlow uses sounding pitches, so the open low E is MIDI note 40.
- For takes imported with **konst_Import MusicXML**, ReaTabFlow reads the string from each note's MIDI channel and calculates the fret from the tuning stored on the track. It also recognizes the importer's bass channel mapping. The number of lines matches the number of strings in the stored tuning. [MusicXML importer](https://github.com/kkonstantin2000/konst_reascripts)
- The example opens with an E minor chord. From the top line down, the frets are **0, 0, 0, 2, 2, 0**. The second bar contains four single notes.
- For ordinary MIDI files, ReaTabFlow chooses frets from 0 to 24. It accounts for the previous hand position and strings still occupied by ringing notes. An amber mark above the top line means at least one note at that point could not be assigned to a string.
- When fret numbers would overlap on the same string, the display skips the later number. Zoom in horizontally to see it.
- The display follows the active MIDI takes on the tracks selected when you start the action. To switch tracks, turn off the action, select the new tracks, and run it again. Use REAPER's MIDI editor to edit the notes.
