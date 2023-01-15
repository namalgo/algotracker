# AlgoTracker
3-channel sample-based music tracker for Pico-8 .

Screenshot:

  <img src="https://raw.githubusercontent.com/namalgo/algotracker/main/screenshots/algotracker.png" width="400px" >

## Usage
Download all p8 files from src and put in the same directory, then load 'algotracker.p8' in Pico-8.

The left side of the screen shows the SONG, which has lines of 3 hex numbers, each correponding to a TRACK.

The right side shows a TRACK, which contains music data: pitch, instrument, volume, and 2 parameters.

- Pitch values are entered as hexadecimal numbers in the blue column.
- Instrument type is entered as a number 0-5 in the green column. Type 0 means sample playback.
- Volume is a hex number 0-F
- The two note parameters are entered as two digits 0-F. For the sample instrument type, the first digit indicates the sample index.

Press '?' for help.

Help screen:

  <img src="https://raw.githubusercontent.com/namalgo/algotracker/main/screenshots/algotracker-help.png" width="400px" >

## Replayer

AlgoTracker replayer is included at the end of the source, search for 'algotracker replayer'.

## Source

[Source code](src/algotracker.p8)
