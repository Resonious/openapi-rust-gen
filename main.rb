require "json"

json = File.read ARGV[0]
schema = JSON.parse(json)

schema.fetch("paths").each do |path, methods|
  puts path
  methods.each do |method, definition|
    puts "  #{method}"
  end
end
