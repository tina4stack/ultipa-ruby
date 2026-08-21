#!/usr/bin/env ruby
# frozen_string_literal: true

# Populate an Ultipa community-edition instance with a small demo social/work graph
# - people (with photos), companies, projects, skills and their relationships - so you
# can try the driver and GQL queries against real data in seconds.
#
#     ruby examples/seed.rb ultipa://admin:PASSWORD@HOST:60061
#     # graph defaults to "default"; override with TINA4_ULTIPA_GRAPH
#
# Re-running is safe: it clears the demo labels (Person/Company/Project/Skill) first.
# Photos are 64px JPEGs of AI-generated, non-existent people (thispersondoesnotexist.com),
# stored as BLOB properties - a nice demo of binary round-tripping through gqldb.

require "json"
require_relative "../lib/tina4_ultipa"

HERE = File.expand_path(__dir__)
DATA = File.join(HERE, "sample_data")
LABELS = %w[Person Company Project Skill].freeze

def load_people
  JSON.parse(File.read(File.join(DATA, "people.json"), encoding: "UTF-8"))
end

# Raw JPEG bytes as a binary (ASCII-8BIT) String -> the driver encodes it as a BLOB.
def face(name)
  File.binread(File.join(DATA, "faces", name))
end

def main
  url = ARGV[0] || ENV["TINA4_ULTIPA_URL"] || "ultipa://admin:C8e1234!@localhost:60061"
  graph = ENV["TINA4_ULTIPA_GRAPH"] || "default"
  db = Tina4Ultipa::Client.from_url(url, connect_timeout: 8).connect
  db.graph = graph
  data = load_people
  puts "Seeding demo graph into '#{graph}' on #{db.server_version} …"

  LABELS.each do |lbl|                                 # clean slate for the demo labels
    db.execute("MATCH (n:#{lbl}) DETACH DELETE n")
  end
  data["companies"].each { |c| db.execute("INSERT (:Company {name: $n})", params: { n: c }) }
  data["projects"].each  { |pr| db.execute("INSERT (:Project {name: $n})", params: { n: pr }) }
  data["skills"].each    { |s| db.execute("INSERT (:Skill {name: $n})", params: { n: s }) }
  data["people"].each do |p|                           # people carry a photo BLOB
    db.execute(
      "INSERT (:Person {name: $name, title: $title, city: $city, photo: $photo})",
      params: { name: p["name"], title: p["title"], city: p["city"], photo: face(p["face"]) },
    )
  end

  edges = 0
  link = lambda do |a_lbl, a, rel, b_lbl, b|
    db.execute(
      "MATCH (a:#{a_lbl} {name: $a}), (b:#{b_lbl} {name: $b}) INSERT (a)-[:#{rel}]->(b)",
      params: { a: a, b: b },
    )
    edges += 1
  end

  data["people"].each do |p|
    link.call("Person", p["name"], "WORKS_AT", "Company", p["company"])
    p["skills"].each   { |s| link.call("Person", p["name"], "HAS_SKILL", "Skill", s) }
    p["projects"].each { |pr| link.call("Person", p["name"], "CONTRIBUTES_TO", "Project", pr) }
    p["knows"].each    { |k| link.call("Person", p["name"], "KNOWS", "Person", k) }
  end
  data["manages"].each { |mgr, rep| link.call("Person", mgr, "MANAGES", "Person", rep) }

  puts "  #{data['people'].length} people · #{data['companies'].length} companies · " \
       "#{data['projects'].length} projects · #{data['skills'].length} skills · " \
       "#{edges} relationships"
  puts "Done. Try:  MATCH (n:Person)-[e]->(m) RETURN n, e, m LIMIT 100"
  db.close
end

main if $PROGRAM_NAME == __FILE__
