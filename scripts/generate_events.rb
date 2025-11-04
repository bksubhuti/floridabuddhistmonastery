require 'open-uri'
require 'json'
require 'date'
require 'time'

ICS_URL = "https://calendar.google.com/calendar/ical/a9990f54cc62171dfef7a892c552c8964dc1a18735784e6d8c36803ce3cffb9b%40group.calendar.google.com/public/basic.ics"

ics = URI.open(ICS_URL).read

events = []

ics.split("BEGIN:VEVENT")[1..]&.each do |block|
  body = block.split("END:VEVENT")[0]

  summary = body[/SUMMARY:(.+)/,1]&.strip
  next unless summary

  if body =~ /DTSTART;VALUE=DATE:(\d{8})/
    # all day event
    d = Date.strptime($1, "%Y%m%d")
    start_time = Time.utc(d.year, d.month, d.day, 12, 0, 0) # noon UTC
    all_day = true
  else
    raw = body[/DTSTART(?:;[^:]+)?:([0-9T]+Z?)/,1]
    next unless raw
    start_time = Time.parse(raw)
    all_day = false
  end

  events << {
    summary: summary,
    startRaw: start_time.utc.iso8601,
    allDay: all_day
  }
end

# sort by actual time
events.sort_by! { |e| Time.parse(e[:startRaw]) }

File.write("assets/events.json", JSON.pretty_generate({
  generatedAt: Time.now.utc.iso8601,
  events: events
}))

puts "Generated assets/events.json with #{events.size} events"
