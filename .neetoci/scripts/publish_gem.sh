# Pushes the gem to private-gems.neeto.com when main carries a version the
# server doesn't have yet. This repo is public, so the token comes from the
# NEETO_GEM_SERVER_TOKEN env var in NeetoCI project settings, never the file.
set -euo pipefail

git fetch -q origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]]; then
  echo "Not on main; skipping gem publish."
  exit 0
fi

GEM_FILE=$(gem build ./*.gemspec | awk '/File:/ { print $2 }')
HOST="https://${NEETO_GEM_SERVER_TOKEN}@private-gems.neeto.com"

if curl -sfI "$HOST/gems/$GEM_FILE" >/dev/null; then
  echo "$GEM_FILE is already on the gem server; skipping."
  exit 0
fi

gem install -q geminabox
gem inabox "$GEM_FILE" --host "$HOST"
