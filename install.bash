#!/bin/bash

set -e

absolute_path=$(cd "$(dirname "./main.rb")" && pwd)/$(basename "./main.rb")
echo "exec ruby $absolute_path \"\$@\"" > /usr/local/bin/openapi-rust-gen
chmod +x /usr/local/bin/openapi-rust-gen
