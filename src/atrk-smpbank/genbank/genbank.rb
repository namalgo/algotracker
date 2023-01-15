require 'open3'

def exe(cmd, log)
  log.puts("#{cmd}")
  Open3.popen2e(cmd) {
    |i,stdout_and_err|
    log.puts(stdout_and_err.read())
  }
end

def log_puts(str, log_file)
  log_file.puts(str)
  puts(str)
end

def log_print(str, log_file)
  log_file.print(str)
  print(str)
end

def output_word_to_bank(value, bank, log)
  lsb = (value & 0xff)
  msb = (value >> 8)
  log_print("  bank <- #{value.to_s.rjust(6)} ", log)
  bank.putc(lsb)
  log_print("[ %02x " % lsb, log)
  bank.putc(msb)
  log_puts("%02x ]" % msb, log)
end

log = File.open("genbank-log.txt", "w")

count = 0
rawfiles = []

Dir.entries("./input").each do |fn|
  if fn =~ /.*\.wav$/ then
    rawname = "temp/"+File.basename(fn,".wav")+".raw"
    # sample rate convert and save as raw 8-bit unsigned
    exe("sox input/#{fn} -r 5512 -b8 -e unsigned-integer #{rawname}", log)
    rawfiles.push(rawname)
    count += 1
  end
end

# output file count
bank = File.open("bank.raw", "wb") # binary mode!
bank.putc('A')
bank.putc(count)

log_puts("Sound count: #{count}", log)

# AlgoBank format:
# 1B 'A' for AlgoTracker
#
# Metadata (2+2*N)
# 1B sound count (N)
# 2B sound 0 offset
# 2B sound 1 offset
# ...
# 2B sound N-1 offset
# 2B sample data end
#
# Sample data (3+2*N)
# ?? sound 0
# ?? sound 1
# ?? sound N-1

# output sound offsets
log_puts("Metadata", log)
log_puts("- offsets are output as LSB, MSB", log)
offset = 2 + 2 * count # first offset is after metadata
rawfiles.each do |fn|
  log_puts("#{File.basename(fn,".raw").ljust(10,' ')} offset = #{offset}", log)
  output_word_to_bank(offset, bank, log)
  size = File.size(fn)
  log_puts("#{File.basename(fn,".raw").ljust(10,' ')} size = #{size}", log)
  offset += size
end
# sample data offset
output_word_to_bank(offset, bank, log)

rawfiles.each do |fn|
  wave_data = File.read(fn, mode: "rb")
  bank.write(wave_data)
end

bank.close()
