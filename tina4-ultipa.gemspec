# frozen_string_literal: true

require_relative "lib/tina4_ultipa/version"

Gem::Specification.new do |spec|
  spec.name = "tina4-ultipa"
  spec.version = Tina4Ultipa::VERSION
  spec.authors = ["Tina4 Stack"]
  spec.email = ["info@tina4.com"]

  spec.summary = "Thin gRPC client for the Ultipa graph database (ultipa-gqldb)"
  spec.description = "A thin, standalone gRPC client for the Ultipa graph database " \
                     "(ultipa-gqldb) - the Ultipa driver behind Tina4's graph layer, " \
                     "usable on its own."
  spec.homepage = "https://github.com/tina4stack/ultipa-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir[
    "lib/**/*.rb",
    "proto/*.proto",
    "README.md",
    "LICENSE",
    "tina4-ultipa.gemspec",
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "google-protobuf", ">= 3.25"
  spec.add_dependency "grpc", ">= 1.60"
end
