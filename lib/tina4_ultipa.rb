# frozen_string_literal: true

# tina4-ultipa - a thin gRPC client for the Ultipa (gqldb) graph database.
#
# Used by Tina4's graph data layer, and usable standalone:
#
#     require "tina4_ultipa"
#     db = Tina4Ultipa::Client.from_url("ultipa://admin:pass@host:60061/mygraph")
#     db.query("MATCH (n) RETURN n LIMIT 10").each { |row| puts row }

require_relative "tina4_ultipa/version"
require_relative "tina4_ultipa/errors"
require_relative "tina4_ultipa/client"

module Tina4Ultipa
end
