# frozen_string_literal: true

require "rake"

desc "Regenerate the gRPC/protobuf stubs from proto/gqldb.proto into lib/tina4_ultipa/gen"
task :proto do
  sh "grpc_tools_ruby_protoc " \
     "-Iproto " \
     "--ruby_out=lib/tina4_ultipa/gen " \
     "--grpc_out=lib/tina4_ultipa/gen " \
     "proto/gqldb.proto"
end

desc "Run the live driver test (needs a reachable gqldb server)"
task :test do
  ruby "test/test_driver.rb"
end

task default: :test
