'use strict';
const fs = require('fs');
const path = require('path');
const spawn = require('child_process').spawn;
const config = require('../config');
const rimraf = require('rimraf');

function enabled() {
    if (!config.token || !config.sharedSubmodelRoot || !config.sharedSubmodelV1 || !config.sharedSubmodelEngineV1 || !config.sharedSubmodelJobUuid) return false;
    try {
        return fs.statSync(config.sharedSubmodelRoot).isDirectory();
    } catch (error) { return false; }
}

// Keep entries until publication or completed cancellation cleanup, including
// the interval between helper exit and task registration.
const initializing = new Map();
function cancel(id, callback) {
    const state = initializing.get(id);
    if (!state) return false;
    state.cancelled = true;
    state.waiters.push(callback);
    if (state.exited) state.cleanup();
    else state.child.kill('SIGTERM');
    return true;
}
function publish(id) {
    const state = initializing.get(id);
    if (!state || state.cancelled) throw new Error('Shared initialization cancelled.');
    if (!state.exited) throw new Error('Shared initialization incomplete.');
    // No async boundary between the cancellation guard, rename and registration.
    fs.renameSync(state.staging, state.destination);
    state.req.removeListener('aborted', state.abort);
    initializing.delete(id);
}
function prepare(req, destination, callback) {
    if (!enabled()) return callback(new Error('Shared submodel v1 is disabled on this worker.'));
    if (req.files && req.files.length) return callback(new Error('Shared submodels cannot include uploaded files.'));
    const staging = destination + '.initializing';
    if (initializing.has(req.id)) return callback(new Error('Task is already initializing.'));
    try {
        if (fs.existsSync(destination)) throw new Error('Task destination exists.');
        fs.mkdirSync(staging);
    } catch (error) { return callback(error); }
    const child = spawn('python3', [path.join(__dirname, '../helpers/shared_submodel.py')], {stdio: ['pipe', 'ignore', 'pipe']});
    const state = {child, staging, destination, req, cancelled: false, exited: false, waiters: [], cleaning: false};
    initializing.set(req.id, state);
    let message = '';
    let called = false;
    const done = error => { if (!called) { called = true; callback(error); } };
    state.cleanup = () => {
        if (state.cleaning) return;
        state.cleaning = true;
        rimraf(staging, error => {
            req.removeListener('aborted', state.abort);
            initializing.delete(req.id);
            done(error || state.error || new Error('Shared initialization cancelled or failed.'));
            state.waiters.forEach(waiter => waiter(error));
        });
    };
    state.abort = () => cancel(req.id, () => {});
    req.once('aborted', state.abort);
    child.stderr.on('data', data => { message = (message + data.toString()).slice(-4096); });
    let closed = false;
    const finish = error => {
        if (closed) return;
        closed = true;
        state.exited = true;
        state.error = state.cancelled ? new Error('Shared initialization cancelled.') : error;
        if (error || state.cancelled) state.cleanup();
        else done();
    };
    child.once('error', finish);
    child.once('close', code => finish(code === 0 ? null : new Error(message.trim() || 'Shared initialization failed.')));
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify({body: req.body, id: req.id, root: config.sharedSubmodelRoot,
        job: config.sharedSubmodelJobUuid, imageRoots: config.sharedSubmodelImageRoots || [],
        destination: path.resolve(destination), staging: path.resolve(staging), maxImages: config.maxImages}));
}

module.exports = { enabled, prepare, cancel, publish };
