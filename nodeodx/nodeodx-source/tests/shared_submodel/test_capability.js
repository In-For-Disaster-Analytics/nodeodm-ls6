'use strict';
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const configuration = {token: 'trusted-worker-token', sharedSubmodelV1: true,
    sharedSubmodelEngineV1: true, sharedSubmodelJobUuid: 'allocation', sharedSubmodelRoot: __dirname};
const sandbox = {module: {exports: {}}, require: name => {
    if (name === '../config') return configuration;
    if (name === 'rimraf') return () => {};
    return require(name);
}};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../libs/sharedSubmodel.js'), 'utf8'), sandbox);
const helper = sandbox.module.exports;
assert.strictEqual(helper.enabled(), true);
for (const key of ['token', 'sharedSubmodelV1', 'sharedSubmodelEngineV1', 'sharedSubmodelJobUuid', 'sharedSubmodelRoot']) {
    const saved = configuration[key];
    configuration[key] = '';
    assert.strictEqual(helper.enabled(), false, key + ' must be configured');
    configuration[key] = saved;
}
configuration.token = '';
helper.prepare({files: []}, '/unused', error => assert.match(error.message, /disabled/));
console.log('Shared capability guards passed');
