import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { launchAgentPlist } from "../src/helper/launch-agent.js";
import { runtimePaths, spellwireVersion } from "../src/shared/runtime-paths.js";

test("runtimePaths resolves the package root and CLI entrypoint from built output", () => {
    const paths = runtimePaths();

    assert.equal(path.basename(paths.packageRoot), "spellwire");
    assert.match(paths.cliEntrypointPath, /dist\/src\/cli\.js$/);
    assert.equal(path.dirname(paths.cliEntrypointPath), path.join(paths.packageRoot, "dist", "src"));
    assert.equal(spellwireVersion(), "0.1.0");
});

test("launchAgentPlist wires the helper daemon command and log destinations", () => {
    const paths = runtimePaths();
    const plist = launchAgentPlist(paths);

    assert.match(plist, /<string>internal-daemon<\/string>/);
    assert.match(plist, new RegExp(paths.launchAgentLabel.replace(/\./g, "\\.")));
    assert.match(plist, new RegExp(paths.cliEntrypointPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(plist, new RegExp(paths.launchAgentStdoutPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(plist, new RegExp(paths.launchAgentStderrPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});
