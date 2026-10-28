'use strict';
const assert = require('assert');
const EventEmitter = require('events');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function fixture() {
    let child;
    const removed = [], renamed = [];
    const config = {token: 'token', sharedSubmodelV1: true, sharedSubmodelEngineV1: true,
        sharedSubmodelJobUuid: 'job', sharedSubmodelRoot: '/allocation'};
    const sandbox = {module: {exports: {}}, require: name => {
        if (name === '../config') return config;
        if (name === 'fs') return {statSync: () => ({isDirectory: () => true}), existsSync: () => false,
            mkdirSync: () => {}, renameSync: (src, dst) => renamed.push([src, dst])};
        if (name === 'rimraf') return (dir, cb) => { removed.push(dir); cb(); };
        if (name === 'child_process') return {spawn: () => {
            child = new EventEmitter();
            child.stderr = new EventEmitter(); child.stdin = new EventEmitter(); child.stdin.end = () => {};
            child.kill = () => { child.killed = true; };
            return child;
        }};
        return require(name);
    }, __dirname};
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../libs/sharedSubmodel.js'), 'utf8'), sandbox);
    const req = new EventEmitter(); req.id = 'attempt'; req.body = {}; req.files = [];
    return {helper: sandbox.module.exports, req, get child() { return child; }, removed, renamed};
}

// Cancel during a delayed copy: retain the tombstone until the child exits.
{
    const f = fixture(); let prepared, cancelled = false;
    f.helper.prepare(f.req, '/task', error => { prepared = error; });
    assert.strictEqual(f.helper.cancel('attempt', error => { assert.ifError(error); cancelled = true; }), true);
    assert.strictEqual(f.child.killed, true);
    assert.strictEqual(cancelled, false);
    f.helper.prepare(f.req, '/task', error => assert.match(error.message, /already initializing/));
    assert.throws(() => f.helper.publish('attempt'), /cancelled/);
    f.child.emit('close', null);
    assert(prepared instanceof Error || /cancelled/.test(prepared.message));
    assert.strictEqual(cancelled, true);
    assert.deepStrictEqual(f.removed, ['/task.initializing']);
    assert.deepStrictEqual(f.renamed, []);
}
// Cancellation after helper success but immediately before publication still wins.
{
    const f = fixture(); let prepared = false;
    f.helper.prepare(f.req, '/task', error => { assert.ifError(error); prepared = true; });
    f.child.emit('close', 0);
    assert.strictEqual(prepared, true);
    assert.strictEqual(f.helper.cancel('attempt', assert.ifError), true);
    assert.throws(() => f.helper.publish('attempt'), /cancelled/);
    assert.deepStrictEqual(f.renamed, []);
}
// Successful publication is synchronous and subsequent cancellation uses TaskManager.
{
    const f = fixture();
    f.helper.prepare(f.req, '/task', assert.ifError); f.child.emit('close', 0);
    f.helper.publish('attempt');
    assert.deepStrictEqual(f.renamed, [['/task.initializing', '/task']]);
    assert.strictEqual(f.helper.cancel('attempt', () => {}), false);
}
console.log('Shared initialization cancellation lifecycle passed');
// Both public TaskManager operations intercept initializing attempts before find().
{
    const filename = path.join(__dirname, '../../libs/TaskManager.js');
    const source = fs.readFileSync(filename, 'utf8');
    const sandbox = {module: {exports: {}}, require: name => {
        if (name === './sharedSubmodel') return {cancel: (id, cb) => { assert.strictEqual(id, 'attempt'); cb(); return true; }};
        if (name === './Directories') return {data: '/data'};
        if (name === 'path') return path;
        return {};
    }};
    vm.runInNewContext(source + '\nmodule.exports.Type = TaskManager;', sandbox);
    const manager = Object.create(sandbox.module.exports.Type.prototype);
    manager.find = () => { throw new Error('Initializing attempt must not reach find'); };
    for (const operation of ['cancel', 'remove']) {
        let finished = false;
        manager[operation]('attempt', error => { assert.ifError(error); finished = true; });
        assert.strictEqual(finished, true);
    }
}
