#!/bin/bash

if [ -z "$NVM_DIR" ]; then
    echo "Error: NVM_DIR environment variable is not set" >&2
    exit 1
fi
if [ -z "$NODE_VERSION" ]; then
    echo "Error: NODE_VERSION environment variable is not set" >&2
    exit 1
fi

for i in {1..20}; do
    apt-get update && apt-get install -y curl gpg-agent && break
    echo "apt-get failed, retrying... ($i/20)"
    sleep 30
done

mkdir -p $NVM_DIR
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
. "$NVM_DIR/nvm.sh"
nvm install $NODE_VERSION
nvm alias default $NODE_VERSION

for i in {1..20}; do
    apt-get install -y unzip p7zip-full && npm install -g nodemon && break
    echo "apt-get failed, retrying... ($i/20)"
    sleep 30
done

npm install --production

# The runtime image is the dependency contract for the Tapis ZIP launcher.
# Fail the image build if any production dependency cannot be resolved; do not
# defer installation to an LS6 job, where package installation is unreliable.
node - <<'NODE'
const packageJson = require('./package.json');
const missing = Object.keys(packageJson.dependencies || {}).filter((name) => {
    try {
        require.resolve(name);
        return false;
    } catch (_) {
        return true;
    }
});
if (missing.length) {
    console.error(`missing production dependencies: ${missing.join(', ')}`);
    process.exit(1);
}
require.resolve('multer');
console.log('verified NodeODX production dependency tree');
NODE
