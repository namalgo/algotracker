bank = File.open("genbank/bank.raw", "rb")
data = bank.read
bank.close

f = File.open("samples.p8", "w")

length = data.length

f.puts("pico-8 cartridge // http://www.pico-8.com")
f.puts("version 33")
f.puts("__gfx__")
puts "length: #{length}"

# generate single line string
s = ""
(0...length).each do |v|
  val = data[v].ord
  # val = (val+127)%255 # signed -> unsigned

  # disgustingly, Pico-8 data is stored little-endian
  val_ms = val >> 4  # most  sign. 4 bit
  val_ls = val & 0xf # least sign. 4 bit
  s += ("%x" % val_ls)
  s += ("%x" % val_ms)
end

# split into lines
lines=s.length/127
(0..lines).each do |line|
  f.puts(s.slice(line*128,128))
end
f.close
