pico-8 cartridge // http://www.pico-8.com
version 33
__lua__
-- vim:ft=lua:sw=1
------------------------------
-- NOTE: MUST UPDATE MANUALLY
--       WHEN UPDATING BANK
--
-- ---------------------------
--
-- Copyright 2022
-- Nameless Algorithm
-- See https://namelessalgorithm.com/
-- for more information.
--
-- LICENSE
-- You may use this source code
-- for any purpose. If you do
-- so, please attribute
-- 'Nameless Algorithm' in your
-- source, or mention us in
-- your game/demo credits.
-- Thank you.
--
-- ---------------------------
BANK_LENGTH=3798 -- bank file size in bytes
SPEED=3

--[[

TERMS
-----

              track
                |
             ------
               IVP
song --| 000 000000
       | 123 000000
       | 123 000000 <- line
         ---
          |
       pattern


FUNCTION OVERVIEW
-----------------
editor:
me_init    - init editor
me_update  - update editor
me_edit    - edit from input
me_draw    - render editor

replayer public api:
mu_init    - init replayer
mu_load    - load song
mu_update  - call dur. _update
mu_play    - start playing
mu_stop    - stop playing

replayer internal api:
mu_loadsmp - load samples
mu_render  - audio render
mu_step    - sequence step
mu_debug   - debug view



MEMORY
------

algotracker memory map:
------------------------------
3d00-4dff smp bank 4352b $1100
4e00-4eff song      256b  $100
4f00-5aff tracks   3072b  $c00
5b00-5b5f audiobuf   96b   $5f
5c00-5dff sine      512b  $200

proposed new memory map 2021-11-03
3a00-4aff smp bank 4352b $1100 *
4b00-4bff song      256b  $100 *
4c00-5aff tracks   3840b  $f00 *
5b00-5b5f audiobuf   96b   $5f
5c00-5dff sine      512b  $200

unused:
-- 3a00-49ff audio dly buf  4096b

5e00 end of usable RAM
                         -----
                        10496b

pico-8 memory map
--------------------------------
start end purpose
0000-0fff spr. sheet (0-127)
1000-1fff spr. sheet (128-255)
   / map (rows 32-63) (shared)
2000-2fff map (rows 0-31)
3000-30ff sprite flags
3100-31ff music
3200-42ff sound effects
4300-55ff gen.use(or work ram)
5600-5dff gen.use/custom font
usable part is 5e00 b = 24kb

5e00-5eff pers. cart data
5f00-5f3f draw state
5f40-5f7f hardware state
5f80-5fff gpio pins (128 b)
6000-7fff screen data (8kb)

4e00-4aff is loaded from
'music.p8'


hex table
hex     dec
-----------
0x1000 4096
0x0800 2048
0x0400 1024
0x0200  512
0x0100  256


Memory Usage
------------
audio delay buffer
total: 4096b

song
32 patterns x 2b: 64b

tracks

1 track is
64 lines of 3 bytes: 192b

proposed A-T tracks
3840b ($f00)

we have 16 tracks:
192b * 16 = 3072b ($c00)
track 0-f




music sequence

32 patterns x 1b: 4 bits of
trk0 pattern idx, 4bit of trk1
pattern idx.
total: 32b

music patterns
32 lines of 2 bytes of data
= 64 bytes per pattern.
if we have 32 patterns, they
will take up 32*64b
total: 2048b

sine table
total: 512b

audio buffer
total: 512b

total:  11296b
e.g. 0x4e00-0x5d20



Samples
-------
The 0x808 serial port allows
buffering up to 2048 b of
UNSIGNED 8-bit 5512.5 Hz samples



TODO
----
[ ] we need more tracks!
    could it be a-z instead of 0-a?
    25 should be enough
[ ] simple memory manager
    allocate from HIGH memory
    5e00 and down
    every allocation subtracts
    from a free memory ptr
    - might perform worse than 
    using constants
    From https://pico-8.fandom.com/wiki/CPU:
     Variable access (read):
     Local variables in same function: 0 cycles.
     Global variables: 2 cycles.
     Function call  : 4 cycles + 2 cycles per argument
     Function return: 2 cycles + 2 cycles per return value
     additive operators (+, -): 1 cycle
     multiplicative operators (*, /, %, \): 2 cycles
[x] select track pattern 0/1
    addr=0x4f00+0x20
    add state me.pat0|pat1
[x] song data, list of
    pattern0,pattern1_
    01 23 43
[x] play song/tracks
[x] samples?
[x] show only one track
    in editor
[x] select active track keys
[x] track is length 64
[x] add 3rd track to patterns
[x] use bank offsets
[x] fix switch track play
[x] fix song length wrap JK
[-] BUFSIZE
[x] yank / put
[ ] BUG: parts of tracks get wiped on save/reload
[ ] arpeggio





--]]

------------------------------
--PICO-8 CALLBACKS
------------------------------

function _init()

 profiler=false

 prof=true
 prf={} --profiler data
 prf.fx=0
 prf.scr=0
 prf.mus=0 -- replayer update time
 prf.mus1=0 -- ", prev. frame

 me_init() -- init editor
 mu_init() -- init replayer
end

function _update60()
 me_update() -- update editor

 local cputicks=stat(1)
 mu_update() -- update replayer
 prf.mus1=prf.mus
 prf.mus=stat(1)-cputicks
 --cputicks=stat(1)
end

function _draw()
 cls()
 if me.mode == 0 then
  me_draw() -- render editor
 elseif me.mode == 1 then
  me_osc()
 elseif me.mode == 2 then
  mu_debug()
 elseif me.mode == 3 then
  me_help()
 end
end


------------------------------
--MUSIC EDITOR
------------------------------
function me_init()
 me={}
 me.fr=0
 me.section=0 -- cursor section
           -- 0: track 1: pattern
 me.clin=0 -- cursor line
 me.coff=0 -- cursor offset
 me.trk=0  -- current track to edit
 me.mode=0 -- 0: normal
           -- 1: osc
           -- 2: debug
           -- 3: help

 poke(24365,1) -- mouse+key kit
 
 cls()
end

function me_update()
 -- get devkit keyboard input 
 me.inpt=-1
 local iskeydown=stat(30)
 while iskeydown do
  keyin=stat(31)
  keyno=ord(keyin)

  -- any key exits help screen
  if me.mode==3 then
   me.mode=0
  else
   -- mode switch
   if keyin=="m" and me.mode<3 then -- m
    me.mode=(me.mode-1)%3
   elseif keyin=="?" and me.mode<3 then -- m
    me.mode=(me.mode-1)%3
   end
   -- normal mode
   me_normal_inp(keyin, keyno)
  end

  iskeydown=stat(30)
 end

end

-- me.inpt :
--  0-15 - numeric
--  100  - copy
--  101  - paste
--  200  - copy track
--  201  - paste track
--  255  - delete
function me_normal_inp(keyin, keyno)
 if keyin=="j" then     -- j
  if me.section==0 then
   me.clin=(me.clin+1)%64
  else
   me.clin=(me.clin+1)%32
  end
 elseif keyin=="k" then -- k
  if me.section==0 then
   me.clin=(me.clin-1)%64
  else
   me.clin=(me.clin-1)%32
  end

 elseif keyno==137 then -- J
  mu.pat=(mu.pat+1)%32
  mu_set_chaddr(mu.pat)
 elseif keyno==138 then -- K
  mu.pat=(mu.pat-1)%32
  mu_set_chaddr(mu.pat)

 elseif keyno==139 then -- L
  me.trk=(me.trk+1)%12
  mu.playtrk = me.trk
  mu.st = 64
 elseif keyno==135 then -- H
  me.trk=(me.trk-1)%12
  mu.playtrk = me.trk
  mu.st = 64

 elseif keyin=="l" then -- l
  if me.section==0 then
   me.coff=(me.coff+1)%6
  else
   me.coff=(me.coff+1)%3
  end
 elseif keyin=="h" then -- h
  if me.section==0  then
   me.coff=(me.coff-1)%6
  else
   me.coff=(me.coff-1)%3
  end
 elseif keyin=="\t" then -- tab
  if me.section==0 then
   me.clin=(me.clin+16)%64
  else
   me.clin=(me.clin+8)%32
  end
  me.coff=0
 elseif keyin=="w" then -- w
  me.section=(me.section+1)%2
  me.clin=0
  me.coff=0
 elseif keyin=="m" then -- m
  me.mode=(me.mode-1)%3
 elseif keyno==32 then -- space
  mu.play = not mu.play
  if (mu.play) then
   mu.st = 0
  end
 elseif keyin=="q" then -- q
  mu.playmode=(mu.playmode+1)%3
  if mu.playmode==2 then
   mu.playtrk = me.trk
  end
 elseif keyno==8 then -- backspace
  me.inpt = 255
 elseif keyin=="i" then -- copy
  me.inpt = 100
 elseif keyin=="o" then -- paste
  me.inpt = 101
 elseif keyno==136 then -- I (copy track)
  me.inpt = 200
 elseif keyno==142 then -- O (paste track)
  me.inpt = 201

 elseif keyno==131 then -- (D)elete
  if me.section==0 then
   -- clear editor track
   memset(0x4f00+me.trk*0xC0,0,64*3)
  else
   -- clear patterns
   memset(0x4e00,0,32)
  end
 elseif keyno==145 then -- (R)eload
  mu_load("atrk-song.p8")
 elseif keyno==146 then -- (S)ave
  me_save("atrk-song.p8")
 elseif keyin=="?" then -- ?
  me.mode = 3

  -- hex numeric input 0-f
 elseif keyin>="0" and keyin<="9" then
  me.inpt=keyno-48
 elseif keyin>="a" and keyin<="f" then
  me.inpt=keyno-87
 end
end

function me_title()
  local title = "algotracker"
  for i=1,11 do
   local ch=ord(sub(title,i,i+1))-96
   spr(ch,i*9+6,0)
  end
  print("BY NAMELESS ALGORITHM",22,7,2)
end

function me_draw()
 me_title()
-- 4f00-35ff music patterns 1024b
 --pokerange(0x4f00,0x35ff)

 local cputicks=stat(1)
 mu_viz()
 prf.fx=stat(1)-cputicks
 cputicks=stat(1)

 me.fr += 1
 prf.scr=stat(1)-cputicks

 -- edit note data from input
 me_edit()

 local data0,data1,data2,ptr
 local note,instr,vol,param0,param1
 ptr = 0x4f00+me.trk*0xC0

 for i=0,63 do
  y=(i%16)*6+24
  x=(i\16)*25+26

  if i%16==0 then
   print("\141",x+4,18,12)
   print("i", x+12,18,11)
   print("v", x+16,18,10)
   print("p", x+20,18,9)
  end

  data0=@(ptr+0+i*3)
  data1=@(ptr+1+i*3)
  data2=@(ptr+2+i*3)

  note   = data0
  instr  = (data1&0xf0)>>>4 
  vol    = (data1&0x0f)
  param0 = (data2&0xf0)>>>4
  param1 = (data2&0x0f)

  local curs=(me.section==0 and i==me.clin)
  -- draw cursor background
  --if curs then
  -- rectfill(x, y, x+23, y+4, 4)
  --end

  --printx8(i,    x,   y,13)
  printx8(note, x+4, y,12)
  printx4(instr,x+12,y,11)
  printx4(vol  ,x+16,y,10)
  printx4(param0,x+20,y,9)
  printx4(param1,x+24,y,9)

  --if i%8==0 then
   --spr(0,x+2,y)
  if i%4==0 then
   spr(32,x+3,y)
  end

  -- draw cursor on top
  if curs then
   local off=me.coff
   rectfill(x+3+4*off,y,x+4*off+6,y+4,8)
   cursbyte = @(ptr+off/2+i*3)

   if off%2==0 then
    nibble = cursbyte>>>4
   else
    nibble = cursbyte&0xf
   end
   printx4(nibble,x+4*off+4,y,7)  
  end
 end
 
 -- song patterns
 for i=0,31 do
  y=(i%16)*6+24
  x=(i\16)*14
  local curs=(me.section==1 and i==me.clin)
  local off=me.coff
  if curs then
    rectfill(x+off*4+2, y, x+6+off*4, y+4, 8)
  end

  pat0 = @(0x4e00+i*2)&0xf
  pat1 = @(0x4e00+i*2+1)

  --if mu.pat == i then
  -- printx4(pat0,3,i*6+24,7)
  -- printx8(pat1,7,i*6+24,7)
  --else
   printx4(pat0,3+x,y,9)
   printx8(pat1,7+x,y,9)
  --end
 end
 
 print(stat(7).."fps", 0, 123, 7)  
 cpu=max(prf.mus,prf.mus1)
 print("cpu "..sub(cpu,0,4), 22, 123, 7)
 print("key",59,123,7)
 print(keyin,74,123,7)
 if keyin != nil then
  print(ord(keyin),84,123,7)
 end

 -- info
 local y = 0
 line(22,16,120,16,5)
 color(7)
 print("track ", 47,    10)
 printx4(me.trk, 47+23, 10, 7)
 --print("step "..mu.st,  40, y)--.." phase "..  mu.stph)
 if(mu.playmode == 0) then
  print("[song]", 78, 10)
 elseif(mu.playmode == 1) then
  print("[pattern]", 78, 10)
 elseif(mu.playmode == 2) then
  print("[trk solo]", 78, 10)
 end
 y+=6
 --print("ch0addr "..sub(tostr(mu.ch0addr,true),0,6), 0, y, 13)
 --print("ch0addr "..sub(tostr(mu.ch0addr,true),0,6), 0, y, 13)
 --print("ch1addr "..sub(tostr(mu.ch1addr,true),0,6), 60, y,13)
 --y+=6
 print("?: help", 100, 123,8) 

 print("song", 3, 18,9)
 spr(0,(mu.pat\16)*14+1,(mu.pat%16)*6+24)
end

function me_osc()
 cls()
 me_title()
 mu_viz()
end

function me_edit()
 local off=0

 -- edit note data from input
 if (me.inpt != -1) then
  local ptr,val

  if me.section==1 then
   -- edit pattern
   ptr=0x4e00
   ptr+=me.clin*2
   if me.inpt == 255 then -- delete
    poke2(ptr, 0)
   elseif me.inpt == 100 then -- copy
    me.clip_pat = peek2(ptr)
    --printh("copy clipboard: "..me.clip_pat)
   elseif me.inpt == 101 then -- paste
    poke2(ptr,me.clip_pat)
    --printh("clipboard paste: "..me.clip_pat)
   else
    off=me.coff+1
    ptr+=off\2
   end
  else
   -- edit track
   ptr = 0x4f00+me.trk*0xC0
   if me.inpt == 255 then -- delete
    ptr+=3*me.clin
    poke2(ptr, 0)
    poke(ptr+2, 0)
   elseif me.inpt == 100 then -- copy
    ptr+=3*me.clin
    me.clip_track0=peek2(ptr)
    me.clip_track1=peek(ptr+2)
   elseif me.inpt == 101 then -- paste
    ptr+=3*me.clin
    poke2(ptr, me.clip_track0)
    poke(ptr+2, me.clip_track1)
   elseif me.inpt == 200 then -- copy track
    memcpy( 0x4f00+11*0xC0, ptr, 192 )
   elseif me.inpt == 201 then -- paste track
    memcpy( ptr, 0x4f00+11*0xC0, 192 )
   else
    off=me.coff
    ptr = 0x4f00+me.trk*0xC0
    ptr+=3*me.clin+off/2
   end
  end

  if me.inpt < 16 then -- numeric
   -- hex edit ptr
   val=@(ptr)
   nibb=off%2
   -- hi nibble
   if nibb==0 then
    val&=0x0f -- keep low nibble
    local inpt_clmp=me.inpt
    val|=(me.inpt<<4)
    -- low nibble
   elseif nibb==1 then
    val&=0xf0 -- keep hi nibble
    val|=(me.inpt)
   end
   poke(ptr,val)
   --if(me.coff==5)then
    --me.clin=(me.clin+1)%32
   --end
   --me.coff=(me.coff+1)%6
  end
  --me.clin=(me.clin+1)%64
 end
end

function me_save(song)
 cstore(0x0000,0x4e00,0xd00,song)
end

function me_help()
 cls()
 y = 0
 color(7)
 print("hjkl      - navigate", 0, y) y+=6
 print("0-9a-f    - input hex numbers", 0, y) y+=6
 print("SHIFT+j k - pattern up/down", 0, y) y+=6
 print("SHIFT+h l - switch edited track", 0, y) y+=6
 print("SHIFT+d   - clear pattern/track", 0, y) y+=6
 print("SHIFT+r   - load 'music.p8'", 0, y) y+=6
 print("SHIFT+s   - save 'music.p8'", 0, y) y+=6
 print("w         - edit pattern/track edit", 0, y) y+=6
 print("tab       - jump", 0, y) y+=6
 print("space     - play", 0, y) y+=6
 print("q         - toggle pattern loop", 0, y) y+=6
 print("m ?       - mode switch, help", 0, y) y+=6
 print("i o       - copy, paste value", 0, y) y+=6
 print("SHIFT+I O - copy, paste track", 0, y) y+=6

 print("       I V P", 0, y) y+=6

 print("00", 16, y, 12)
 print("0", 28, y, 11)
 print("0", 36, y, 10)
 print("00", 42, y, 9)
 y+=6

 color(7)
 print("   /   | |  \\_ PARAMS 0,1", 0, y) y+=6
 print("PITCH  | VOLUME", 0, y) y+=6
 print("--- instrument ---------------", 0, y) y+=6
 print("0 - sample 2 - hihat 4 - snare", 0, y) y+=6
 print("1 - fm     3 - bdrum 5 - sine", 0, y)
end


------------------------------
--DEBUG
------------------------------
poke_start = 0x0000
poke_end = 0xffff

function pokerange(start,endaddr)
 poke_start = start
 poke_end   = endaddr
end

function poked(ptr, val)
 if(ptr < poke_start or ptr > poke_end) then
  print("Out of bounds: \n" .. hexptr(ptr) .. " ("..hexptr(poke_start).."-"..hexptr(poke_end)..")")
  error("Out of bounds")
 else
  poke(ptr, val)
 end
end

function poke2d(ptr, val)
 if(ptr < poke_start or ptr+1 > poke_end) then
  print("Out of bounds: \n" .. hexptr(ptr) .. " ("..hexptr(poke_start).."-"..hexptr(poke_end)..")")
  error("Out of bounds")
 else
  poke2(ptr, val)
 end
end



------------------------------
-- algotracker replayer
-- ====================
-- 2021-11-08 08:01
-- by nameless algorithm
-- namelessalgorithm.com
--
-- how to use in your cart:
--
-- create song 'atrk-song.p8'
-- using algotracker
-- place next to your cart
-- along with
-- 'atrk-smpbank.p8'
--
-- copy all functions with the
-- mu_ prefix and call:
-- 
--  function _init()
--   mu_init()
--   mu_load("atrk-song.p8")
--   mu_play()
--  end
--  
--  function _update60()
--   mu_update();
--  end
--
-- relevant for animation:
--
-- mu.chx.vol <- channel power
-- if mu.chx.ins != -1:
--  mu.chx.fra <- note freq
--
------------------------------
function mu_init()
 local ch0={
  addr=0,
  pha=0,
  phb=0,
  fra=0, -- use for animation
  frb=0,
  ins=-1,
  amp=0,
  env=0,
  fr_env=0,
  sstr=0, -- sample start
  send=0, -- sample end
  debug_smpidx=0,
  debug_smp=0,
  vol=0  -- volume measurement
 }
 local ch1={
  addr=0,
  pha=0,
  phb=0,
  fra=0,
  frb=0,
  ins=-1,
  amp=0,
  env=0,
  fr_env=0,
  sstr = 0, -- sample start
  send = 0, -- sample end
  debug_smpidx=0,
  debug_smp=0,
  vol=0  -- volume measurement
 }
 local ch2={
  addr=0,
  pha=0,
  phb=0,
  fra=0,
  frb=0,
  ins=-1,
  amp=0,
  env=0,
  fr_env=0,
  sstr = 0, -- sample start
  send = 0, -- sample end
  debug_smpidx=0,
  debug_smp=0,
  vol=0  -- volume measurement
 }

 BUFSIZE=96 -- don't change this, rendering is
          -- not stable with other values

 -- ch0, osc a/b
 mu={}
 mu.ch0 = ch0
 mu.ch1 = ch1
 mu.ch2 = ch2
 --mu.ch3 = ch3

 mu.tick = 0
 mu.note = 0
 mu.pat = 0 -- music pattern idx
 mu.playtrk = 0 -- play track exclusively
                -- (only used in editor)
 mu.playmode = 0 -- 0 play song
                 -- 1 loop pattern
                 -- 2 play 'playtrk'
 mu.play = false
 mu.st   = 0   -- music step
 mu.stph = 0 -- step phase 0..1
 mu.dlyidx = 0
 --mu.xm1 = 0;
 --mu.ym1 = 0;
 mu_set_chaddr(0)

 gen_sine_tab()

 memset(0x4e00,0,32+0x600)
 --memset(0x4f00,0x00,1024)

 --pokerange(0x3d00,0x59ff)
 --gentest(0x3d00,0x1000) -- works
 mu_loadsmp("atrk-smpbank.p8",BANK_LENGTH,0x3d00)
end

function mu_update()
 -- get # of buffered samples
 local current_buf=stat(108)
 if current_buf < 512 then
  mu_render()
  current_buf=stat(108)
 end
end

function mu_load(song)
 reload(0x4e00,0x0000,0xd00,song)
 mu.pat = 0
 mu_set_chaddr(0)
end

function mu_play()
 mu.play = true
end

function mu_stop()
 mu.play = false
end


function mu_loadsmp(fn,length,addr)
 reload(addr,0x0000,length,fn)

 -- convert signed -> unsigned
 --for i=0,0x1000 do
 -- local smp=peek(addr+i)
 -- poke(addr+i,flr(smp+127)%255)
 --end
end

function gentest(ptr, length)
 for i=0,length do
  --local smp=sin(i/length)*127+127
  local smp=i/16
  poke(ptr+i,flr(smp))
  --poke(ptr+i,(i\8)%256)
 end
 poke(ptr,0xFE)
 poke(ptr+1,0xDE)
 poke(ptr+2,0xAB)
 poke(ptr+3,0xE0)
end

------------------------------
-- Music line
------------------------------
-- note             : 8 bit
-- instr  0-f       : 4 bit
-- vol    0-f       : 4 bit
-- param0 0-f       : 4 bit
-- param1 0-f       : 4 bit
-- ------------------------
--                   24 bit
--
------------------------------
-- Detecting sample end phase:
------------------------------
--
--    sample
--     data
--   (4096 smp)
--     /  \
--    |####----|
-- ph 0  |  | 255
--       |  |
--       |  ph end
--   ex. ph
--     start
--
-- if we wanted phase ph
-- [0;255] to correspond to
-- 4096 samples, we use
-- smpoff=ph*16 
-- but for phx_end to be
-- detected properly without
-- wrapping around, we use a
-- larger smpoff=ph*32, where
-- the waveform only is in the
-- first half of ph's
-- range, and the second half
-- is only used to detecting
-- if we reached phx_end
function mu_step()
 mu.stph = 0

 local note,instr,vol,param0,param1
 -- 0x4f00 mus. tracker data
 local data0
 local data1

 mu_update_ch(mu.ch0)
 mu_update_ch(mu.ch1)
 mu_update_ch(mu.ch2)

 mu.st += 1
 if (mu.st > 63) then
  mu.st = 0

 -- mu.playmode - 0 play song
 --             - 1 loop pattern
 --             - 2 play 'playtrk'
  if(mu.playmode == 0) then
   mu.pat = (mu.pat+1)%32
  end
  if(mu.playmode == 2) then
   mu.ch0.addr = 0x4f00+mu.playtrk*0xc0
  else
   mu_set_chaddr(mu.pat)
  end
  --mu.pat = pat
     -- step pattern
 end
end

function mu_update_ch(ch)
 local chaddr=ch.addr
 local data0,data1,data2
 data0  = @(chaddr+0+mu.st*3)
 data1  = @(chaddr+1+mu.st*3)
 data2  = @(chaddr+2+mu.st*3)
 local note   = data0
 local instr  = (data1&0xf0)>>>4 
 local vol    = (data1&0x0f)
 local param0 = (data2&0xf0)>>>4
 local param1 = (data2&0x0f)

 if(vol > 0) then
  local bf = 1*2^(note/12)

  ch.ins = instr
  ch.amp = 0.25 * vol
  ch.env = 1
  ch.pha = 0
  ch.phb = 0
  ch.ampb = 0
  ch.sstr = 0 -- sample start
  ch.send = 0 -- sample end

  if ch.ins==0 then
   ch.fra = bf * 0.01
   ch.amp = vol * 0.002
   ch.pha = 0
   ch.sstr = mu_smp_off(param0)
   ch.send = mu_smp_off(param0+1)-1
  elseif ch.ins == 1 then
   ch.fra = bf
   ch.frb = bf * param0
   ch.ampb = lerp(0,1.2,param1)
   ch.fr_env = 0.9997
  elseif ch.ins == 2 then
   ch.fr = 1
   ch.fr_env = lerp(0.97, 0.99997, param0/15)
  elseif ch.ins==3 or ch.ins==4 then
   ch.fra = bf * 4
   ch.amp = 0.5 * vol
   ch.fr_env = 0.994
  elseif ch.ins==5 then
   ch.fra = bf
   ch.fr_env = 0.994
  end
 end
end

-- AlgoBank format:
-- 1B 'A' for AlgoTracker
--
-- Metadata (1+2*N)
-- 1B sound count (N)
-- 2B sound 0 offset
-- 2B sound 1 offset
-- ...
-- 2B sound N-1 offset
-- 2B sample data end
--
-- Sample data (3+2*N)
-- ?? sound 0
-- ?? sound 1
-- ?? sound N-1
function mu_smp_off(idx)
 local smp_cnt = @(0x3d00+1)
 if(idx <= smp_cnt) then
  return peek2(0x3d00+2 + idx*2)
 else
  return -1
 end
end
-- return end address of sample bank
function mu_smp_end()
 local smp_cnt = @(0x3d00+1)
 return peek2(0x3d00+2 + smp_cnt*2)
end


-- render buf
function mu_render()

 if(mu.play == false) then
  -- clear
  --for i=0,95 do
   --poke(0x5b00+i,128)
  --en--d
  memset(0x5b00,128,BUFSIZE)
  serial(0x808,0x5b00,BUFSIZE)
  mu.ch0.vol=0
  mu.ch1.vol=0
  mu.ch2.vol=0
  return
 end

-- 5b00-385f audio buf        96b
 --pokerange(0x5b00,0x385f)
 local d_stph = 1/512 -- per smp
 local out,ch0,ch1,ch2
 local ch0vol,ch1vol,ch2vol

 if(mu.tick % SPEED == 0) then
  mu_step()
 end

 ch0vol=0
 ch1vol=0
 ch2vol=0
 for i=0,(BUFSIZE-1) do
  out = 0
  mu.stph += d_stph
  local osc, osc_b, osc_a

 -- mu.playmode - 0 play song
 --             - 1 loop pattern
 --             - 2 play 'playtrk'
  if(mu.playmode == 2) then
   out=mu_render_smp(mu.ch0)
  else
   ch0=mu_render_smp(mu.ch0)
   ch1=mu_render_smp(mu.ch1)
   ch2=mu_render_smp(mu.ch2)
   --ch3=mu_render_smp(mu.ch3)
 
   -- delay ch1
   
   -- local dlyidx0 = mu.dlyidx
   -- local dlyidx1 = (dlyidx0-1)%0x800
   -- local dly=0
   -- dly0=peek2(0x3a00+dlyidx0*2)
   -- dly1=peek2(0x3a00+dlyidx1*2)
   -- ch1+=dly0*0.11+dly1*0.11 -- lpf
 
   -- -- dc filter
   -- ch1_dcb=ch1-mu.xm1+0.995*mu.ym1;
   -- mu.xm1=ch1;
   -- mu.ym1=ch1_dcb;
 
   -- poke2(0x3a00+dlyidx0*2, ch1_dcb)
   -- mu.dlyidx = (mu.dlyidx+1)%0x800

   -- amp measure
   ch0vol+=ch0*ch0
   ch1vol+=ch1*ch1
   ch2vol+=ch2*ch2
 
   -- mix
   out=ch0+ch1+ch2 --+ch3
  end

  local smp=(out/4)*127+128 -- [0;255]
  --local old=peek(0x5b00+i)
  poke(0x5b00+i,smp)
 end

 mu.ch0.vol = ch0vol * 0.008
 mu.ch1.vol = ch1vol * 0.008
 mu.ch2.vol = ch2vol * 0.008
 
 --for i=0,511 do
 -- local out=tsin(i*2)*0.001
 -- local smp=out*127+128 -- [0;255]
 -- poke(0x5b00+i,smp)
 --end

 serial(0x808,0x5b00,BUFSIZE)
 mu.tick += 1
end

-- renders 1 sample for a channel
function mu_render_smp(ch)
 local osc
 local out=0

 if ch.ins==0 then     -- smp
  local smpidx = ch.sstr + flr(ch.pha*8)
  -- oneshot
  if(smpidx > ch.send) then
   ch.ins = -1
   out = 0
   ch.debug_smpidx = 0
   ch.debug_smp = 0;
  else
   -- samples are unsigned
   local smp= @(0x3d00+smpidx)
   osc=smp-128
   out=osc*0.7*ch.amp
   ch.debug_smpidx = smpidx;
   ch.debug_smp = out;
  end
 elseif ch.ins==1 then -- fm
  local osc_b=tsin(ch.phb) -- [-1;1]
  local osc_a=tsins(ch.pha+osc_b*ch.env*ch.ampb)
  out=osc_a * ch.env * ch.amp * 0.20
 elseif ch.ins==2 then -- hh
  out=rnd() * ch.env * ch.amp
 elseif ch.ins==3 then -- bd
  osc= tsins(ch.pha) * ch.amp
  ch.fra *= 0.98
  out=osc * ch.env
 elseif ch.ins==4 then -- sn
  osc= tsins(ch.pha) * ch.amp
  ch.fra *= 0.98
  out=(osc+rnd()*2-1) * ch.env
 elseif ch.ins==5 then -- sine
  osc=tsins(ch.pha)
  out=osc * ch.env * ch.amp
 end

 ch.pha=(ch.pha+ch.fra)%256
 ch.phb=(ch.phb+ch.frb)%256
 ch.env *= ch.fr_env

 return out
end

-- 128 pixel oscilloscope
-- render 512 byte buf by
-- sampling every 4th value
-- centered vertically
function mu_viz()
 --cls()

 -- oscillator
 y1=peek(0x5b00)/2
 color(2)
 for x=0,94 do
  y=peek(0x5b00+x+1)/2
  line(x*1.333,y1,x*1.333+1,y)
  y1=y
 end


 -- rectfill( x0, y0, x1, y1, [col] )
 local vol0=mu.ch0.vol*127
 local vol1=mu.ch1.vol*127
 local vol2=mu.ch2.vol*127
 rectfill(0,0,vol0,2,12)
 rectfill(0,4,vol1,6,12)
 rectfill(0,8,vol2,10,12)

 --print(mu.ch0.vol,0,20,7)
 --print(mu.ch1.vol,0,30,7)
 --print(mu.ch2.vol,0,40,7)

end

-- debug view
function mu_debug()
 cls();
 -- draw box (height 64px)
 color(1)
 rectfill(0,60, 127,63+60)

 -- sample data
 local y,sy
 y=peek(0x3d00)
 local sy1=(256-y)\4+60
 local bank_size =mu_smp_end()
 local scale =bank_size/127
 print("bank_size "..bank_size, 0, 0, 7)
 print("scale     "..scale, 0, 6, 7)
 color(3)
 for x=0,127 do
  y=peek(0x3d00+flr(x*scale))
  sy=(256-y)/4+60
  line(x,sy1,x+1,sy)
  sy1=sy
 end

 -- sine table 0..255
 --  scl=128*16
 --  s=sin(f/256)*(scl-1)+scl
 --  flr(s)
 y1=peek2(0x5c00)/64+64
 color(4)
 local scl=256/(128*16)
 sy1=0+60
 for x=0,127 do
  y=flr(peek2(0x5c00+x*4)*scl*0.5)
  sy=(255-y)\4+60
  line(x,sy1,x+1,sy)
  sy1=sy
 end

 color(9)
 mu_debug_ch(mu.ch0, 0, 12)
 --mu_debug_ch(mu.ch1, 64, 0)
 --mu_debug_ch(mu.ch2, 0, 43)


 color(6)
 local y = 58
 print("ply "..tostr(mu.play), 0, y)
 y+=6
 --print("lop "..tostr(mu.pat_loop), 64, y)
 --y+=6
 print("pat "..mu.pat, 0, y)
 print("tck "..mu.tick, 24, y)
 y+=6
 print("st  "..mu.st, 0, y)
 --y+=6
 --print("stph"..mu.stph, 0, y)

 -- bank dump
 for y=0,1 do
  for x=0,7 do
   byte = @(0x3d00+y*6+x)
   printx8(byte, 64+x*8, y*6,9)
  end
 end
 
 local y = 14
 color(7)
 local smp_cnt = @(0x3d00+1)
 print("smp cnt "..tostr(smp_cnt), 64, y)
 y+=6
 for i=0,(smp_cnt-1) do
  print("- offset"..i.." "..mu_smp_off(i), 64, y)
  y+=6
 end
 print("- smp end "..mu_smp_off(smp_cnt), 64, y)

 print("wav 3d00", 0, 123, 3)
 print("sin 5c00", 48, 123, 4)
 --mu_viz()
end

function mu_debug_ch(ch, x, y)
 color(12)
 print("adr 0x", x, y) 
 printx16(ch.addr,x+24,y,12)
 y+=6
 print("ins "..ch.ins, x, y) y+=6
 --print("pha "..ch.pha, x, y) y+=6
 --print("phb "..ch.phb, x, y) y+=6
 print("sstr "..ch.sstr, x, y) y+=6
 print("send "..ch.send, x, y) y+=6
 print("smpidx "..ch.debug_smpidx, x, y) y+=6
 print("smp "..ch.debug_smp, x, y) y+=6
 --print("fra "..ch.fra, x, y) y+=6
 --print("frb "..ch.frb, x, y) y+=6
 print("amp "..ch.amp, x, y) y+=6
end

function mu_set_chaddr(pat)
 local trks0 =@(0x4e00+pat*2)
 local trks12=@(0x4e00+pat*2+1)
 local ch0trk=flr(trks0&0xf)
 local ch1trk=flr(trks12>>>4)
 local ch2trk=trks12&0xf
 --local ch3trk=trks23&0xf
 mu.ch0.addr = 0x4f00+ch0trk*0xc0
 mu.ch1.addr = 0x4f00+ch1trk*0xc0
 mu.ch2.addr = 0x4f00+ch2trk*0xc0
 --mu.ch3.addr = 0x4f00+ch3trk*0xc0
end

-- generate 16-bit fixnum
-- sine table in 0x5c00
function gen_sine_tab()
-- 5c00-37ff sine            512b
 --pokerange(0x5c00,0x37ff)
 -- [0;255] -> [0;255]
 -- result is a 16 bit fixnum
 --scl=32768
 scl=128*16
 local ptr=0
 local s=0
 for f=0,255 do
  s=sin(f/256)*(scl-1)+scl
  ptr=0x5c00+f*2
  poke2(ptr,flr(s))
 end
end

-- sine table
-- [0;255] -> [0;255]
function tsin(f)
 local idx=flr(f)%256
 local ptr=0x5c00+idx*2
 -- %(ptr) is peek2 but faster
 return %(ptr)/16
end

-- sine table
-- [0;255] -> [0;1]
function tsin01(f)
 local idx=flr(f)%256
 local ptr=0x5c00+idx*2
 -- %(ptr) is peek2 but faster
 return %(ptr)/4096
end

-- sine table
-- [0;255] -> [-1;1]
function tsins(f)
 local idx=flr(f)%256
 local ptr=0x5c00+idx*2
 -- %(ptr) is peek2 but faster
 return (%(ptr)/2048)-1
end

-- hex print utils
function printx4(num,x,y,col)
 print(sub(tostr(num,true),6,6),x,y,col)
end
function printx8(num,x,y,col)
 print(sub(tostr(num,true),5,6),x,y,col)
end
function printx16(num,x,y,col)
 print(sub(tostr(num,true),3,6),x,y,col)
end
function hexptr(ptr)
 return sub(tostr(ptr,true),0,6)
end
function lerp(a,b,f)
 return (1-f)*a + b*f;
end
------------------------------
-- END OF ALGOTRACKER REPLAYER
------------------------------





__gfx__
000000000e888880e888888000e88880e8888800e8888888e88888880e888880e80000e8000e8000e8888888e8000882e8000000e80000e8e80000e800e88800
c0000000e8888888880002880e888888888888808888888888888888e8888888880000880008800088888888880088208800000088800088888000880e888880
cc0000008800008888000088e88000288800088888000000880000008820028888000088000880000000008888288200880000008888088888880088e8800888
c0000000880000888888888288000000880000888888000088888000880000008888888800088000000000888888200088000000882888888828808888000088
00000000888888888822228888000000880000888822000088222000880088888822228800088000000000888828800088000000880282888802888888000088
00000000882222888800008888800028880008888800000088000000882022888800008800088000880002888802880088000000880020888800288888800888
000000008800008888000e8808888888888888808888888888000000888888888800008800088000888888888800288088888888880000888800028808888880
00000000880000888888888000888880888888008888888888000000088888808800008800088000088888808800028888888888880000888800008800888800
e888888000000000e8888880e8888888e8888888e80000e800000000e80000e888000088e80000e8e8888888b000000000000000000000000000000000000088
88888888000000008888888888888888888888888800008800000000880000888880088888800888888888880000000000000000009900000000000000000882
8800008800aaaa008800028888000000000880008800008800000000880000880888888008888880000088200000000000000000009000000000000000008820
880000880aa00aa08888888228888882000880008800008800000000880000880088880000888800000882000000000000000000009000000000000000088200
888888880aaaaa0088888220022222880008800088000088000000008828828800888800000880000088200000000000000e8800009000000000000000882000
8888888000aaa00088028800000000880008800088200288000000008888888808888880000880000882000000000000000888000090000000e8820008820000
8800000000000a008800288088888888000880008888888800000000888228888880088800088000888888880000000000022800009000000088820088200000
88000000000000a08800028888888882000880000888888000000000882002888800008800088000888888880000000000088200000000000022220082000000
000000000e8888800000000000000000000000000000000000000000000000000ee8888000000000000000000000000000000000000000000000000000000000
00000000e8888888000000000000000000000000000000000000000000000000e888888800000000000000000000000000000000000000000000000000000000
90000000880000880000000000000000000000000000000000000000000000008800008800000000000000000000000000000000000000000000000000000000
00000000880000880000000000000000000000000000000000000000000000002888888200000000000000000000000000000000000000000000000000000000
00000000888888880000000000000000000000000000000000000000000000008822228800000000000000000000000000000000000000000000000000000000
00000000882222880000000000000000000000000000000000000000000000008800008800000000000000000000000000000000000000000000000000000000
00000000880000880000000000000000000000000000000000000000000000008888888800000000000000000000000000000000000000000000000000000000
00000000880000880000000000000000000000000000000000000000000000000888888000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000cccc0088888888600000007000000050000000d00000000000000000000000000000000000000000000000
000000000000000000000000000cc00000cccc000c66ccc080000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000011000000cc00000c6cc000c6cccc0c676cccc80000000000000000000000000000000000000000000000000000000000000000000000000000000
00011000001c110000c6cd000c676cc00676ccc0c66ccccc81111111000000000000000000000000000000000000000000000000000000000000000000000000
000110000011110000cccd000cc6ccc00c6cccc0cccccccc81111111000000000000000000000000000000000000000000000000000000000000000000000000
0000000000011000000dd00000cccc000cccccc0cccccccc82222222000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000cc00000cccc000cccccc082222222000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000cccc0088888888000000000000000000000000000000000000000000000000000000000000000000000000
__label__
77707770077070700000707077700000000000000000000000000000000007707770777077700000770077000000000000000000000000000000000000000000
07000700700070700000707000700000000000000000000000000000000070000700700070700000070007000000000000000000000000000000000000000000
07000700700077000000777077700000000000000000000000000000000077700700770077700000070007000000000000000000000000000000000000000000
07000700700070700000007070000000000000000000000000000000000000700700700070000000070007000000000000000000000000000000000000000000
07007770077070700000007077700000000000000000000000000000000077000700777070000000777077700000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0dd0d0d0ddd0ddd0dd00dd00ddd00000ddd0d0d0ddd0ddd0ddd0ddd000000dd0d0d0dd00ddd0dd00dd00ddd00000ddd0d0d0ddd0ddd0d0d0d0d0000000000000
d000d0d0d0d0d0d0d0d0d0d0d0d00000d0d0d0d000d000d0d0d0d0d00000d000d0d00d00d0d0d0d0d0d0d0d00000d0d0d0d000d000d0d0d0d0d0000000000000
d000ddd0d0d0ddd0d0d0d0d0dd000000d0d00d000dd0ddd0d0d0d0d00000d000ddd00d00ddd0d0d0d0d0dd000000d0d00d000dd0ddd0ddd0ddd0000000000000
d000d0d0d0d0d0d0d0d0d0d0d0d00000d0d0d0d000d0d000d0d0d0d00000d000d0d00d00d0d0d0d0d0d0d0d00000d0d0d0d000d0d00000d000d0000000000000
0dd0d0d0ddd0d0d0ddd0ddd0d0d00000ddd0d0d0ddd0ddd0ddd0ddd000000dd0d0d0ddd0d0d0ddd0ddd0d0d00000ddd0d0d0ddd0ddd000d000d0000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
77007770707000007070777070707000000077707770707000007770777077700000077070700000700000700770000070000770777077000070077077707070
70707070707007007070070070707000000007007070707007000700707070700000700070700700700007007000070070007070707070700700700070707070
70707770707000007770070077007000000007007700770000000700777077000000777077707770700007007770000070007070777070700700777077707070
70707070777007007070070070707000000007007070707007000700707070700000007070700700700007000070070070007070707070700700007070707770
70707070070000007070770070707770000007007070707000000700707077700000770070700000777070007700000077707700707077707000770070700700
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000ccc0077707070777000000000000ccc0077707070777000000000000ccc0077707070777000000000000ccc0077707070777
0000000000000000000000000000c000007007070707000000000000c000007007070707000000000000c000007007070707000000000000c000007007070707
0000000000000000000000000000c000007007070777000000000000c000007007070777000000000000c000007007070777000000000000c000007007070777
00000000000000000000000000ccc0000070077707000000000000ccc0000070077707000000000000ccc0000070077707000000000000ccc000007007770700
00000000000000000000000000ccc0000777007007000000000000ccc0000777007007000000000000ccc0000777007007000000000000ccc000077700700700
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd4ddd87778ccc4bbb4aaa49990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d4d4d4d87878c4c4b4b4a4a490900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d4d4d4d87878c4c4b4b4a4a490900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d4d4d4d87878c4c4b4b4a4a490900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd4ddd87778ccc4bbb4aaa49990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0dd00ccc0ccc0bbb0aaa09990dd00dd00ccc0ccc0bbb0aaa09990ddd0dd00ccc0ccc0bbb0aaa09990dd00dd00ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d00d00c0c0c0c0b0b0a0a090900d000d00c0c0c0c0b0b0a0a09090d0d00d00c0c0c0c0b0b0a0a090900d000d00c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d00d00c0c0c0c0b0b0a0a090900d000d00c0c0c0c0b0b0a0a09090d0d00d00c0c0c0c0b0b0a0a090900d000d00c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d00d00c0c0c0c0b0b0a0a090900d000d00c0c0c0c0b0b0a0a09090d0d00d00c0c0c0c0b0b0a0a090900d000d00c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a09090d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d00dd0c0c0c0c0b0b0a0a090900d000dd0c0c0c0c0b0b0a0a09090d0d00dd0c0c0c0c0b0b0a0a090900d000dd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0d0d0ccc0ccc0bbb0aaa09990dd00d0d0ccc0ccc0bbb0aaa09990ddd0d0d0ccc0ccc0bbb0aaa09990dd00d0d0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a09090d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a09090d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0d000ccc0ccc0bbb0aaa09990dd00d000ccc0ccc0bbb0aaa09990ddd0d000ccc0ccc0bbb0aaa09990dd00d000ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a09090d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
99929992aaa2aaa22ddd2ddd2ccc2ccc2bbb2aaa29992ddd2ddd2ccc2ccc2bbb2aaa29992ddd2ddd2ccc2ccc2bbb2aaa29992ddd2ddd2ccc2ccc2bbb2aaa2999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a09090d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a09090d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a09090d0d000d0c0c0c0c0b0b0a0a090900d0000d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa09990ddd000d0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a09090d0d0ddd0c0c0c0c0b0b0a0a090900d00ddd0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0d0d0ccc0ccc0bbb0aaa09990ddd0d0d0ccc0ccc0bbb0aaa09990ddd0d0d0ccc0ccc0bbb0aaa09990ddd0d0d0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0dd00c0c0c0c0b0b0a0a090900d00dd00c0c0c0c0b0b0a0a09090d0d0dd00c0c0c0c0b0b0a0a090900d00dd00c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd00dd0ccc0ccc0bbb0aaa09990dd000dd0ccc0ccc0bbb0aaa09990ddd00dd0ccc0ccc0bbb0aaa09990dd000dd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd00dd0ccc0ccc0bbb0aaa09990ddd00dd0ccc0ccc0bbb0aaa09990ddd00dd0ccc0ccc0bbb0aaa09990ddd00dd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0dd00ccc0ccc0bbb0aaa09990dd00dd00ccc0ccc0bbb0aaa09990ddd0dd00ccc0ccc0bbb0aaa09990dd00dd00ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a09090d0d0d0d0c0c0c0c0b0b0a0a090900d00d0d0c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0dd00c0c0c0c0b0b0a0a090900d00dd00c0c0c0c0b0b0a0a09090d0d0dd00c0c0c0c0b0b0a0a090900d00dd00c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
99909990aaa0aaa00ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa09990ddd0ddd0ccc0ccc0bbb0aaa09990dd00ddd0ccc0ccc0bbb0aaa0999
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0dd00c0c0c0c0b0b0a0a090900d00dd00c0c0c0c0b0b0a0a09090d0d0dd00c0c0c0c0b0b0a0a090900d00dd00c0c0c0c0b0b0a0a0909
90909090a0a0a0a00d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a09090d0d0d000c0c0c0c0b0b0a0a090900d00d000c0c0c0c0b0b0a0a0909
99909990aaa0aaa00ddd0d000ccc0ccc0bbb0aaa09990ddd0d000ccc0ccc0bbb0aaa09990ddd0d000ccc0ccc0bbb0aaa09990ddd0d000ccc0ccc0bbb0aaa0999
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
70007770777077700770000007707770707000007770000077007070000707077707070777077000000077007700777070000770000000000000000000000000
70007070700070707000000070007070707000007070000007007070000707070007070070070700000070007070070070000070000000000000000000000000
77707070770077707770000070007770707000007070000007007770000770077007770070070700000070007070070070000070000000000000000000000000
70707070700070000070000070007000707000007070000007000070000707070000070070070700000070007070070070000070000000000000000000000000
77707770700070007700000007707000077000007770070077700070000707077707770777070700000077007070777077700770000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

__music__
00 00014344

