# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies are declared in the gemspec.
gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", "~> 5.0"
  gem "mocha", "~> 2.0"
  # Loaded by bump_gem_version in .neetoci/scripts/bump_version.sh, which
  # runs under bundler/setup.
  gem "thor"
end
