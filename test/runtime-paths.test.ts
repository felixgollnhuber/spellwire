import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { launchAgentPlist } from "../src/helper/launch-agent.js";
import { runtimePaths, spellwireVersion } from "../src/shared/runtime-paths.js";

test("runtimePaths resolves the package root and CLI entrypoint from built output", () => {
    const paths = runtimePaths();

    assert.equal(path.basename(paths.packageRoot), "spellwire");
    assert.match(paths.cliEntrypointPath, /dist\/src\/cli\.js$/);
    if (paths.platform === "darwin") {
        assert.match(paths.attachmentsRootPath, /Application Support\/Spellwire\/attachments$/);
        assert.equal(paths.serviceManager, "launch-agent");
    } else if (paths.platform === "linux") {
        assert.match(paths.attachmentsRootPath, /\.local\/state\/spellwire\/attachments$/);
        assert.equal(paths.serviceManager, "background-process");
    }
    assert.equal(path.dirname(paths.cliEntrypointPath), path.join(paths.packageRoot, "dist", "src"));
    assert.equal(spellwireVersion(), "0.1.0");
});

test("runtimePaths uses XDG state home on linux", () => {
    const paths = runtimePaths({
        platform: "linux",
        homeDirectory: "/tmp/home",
        env: {
            PATH: "/usr/bin:/bin",
            XDG_STATE_HOME: "/tmp/state-home",
        },
    });

    assert.equal(paths.runtimeRoot, "/tmp/state-home/spellwire");
    assert.equal(paths.socketPath, "/tmp/state-home/spellwire/run/spellwire-helper.sock");
    assert.equal(paths.serviceManager, "background-process");
});

test("launchAgentPlist wires the helper daemon command and log destinations", () => {
    const paths = runtimePaths({
        platform: "darwin",
        homeDirectory: "/tmp/home",
        env: {
            PATH: "/usr/bin:/bin",
        },
    });
    const plist = launchAgentPlist(paths);

    assert.match(plist, /<string>internal-daemon<\/string>/);
    assert.match(plist, new RegExp(paths.launchAgentLabel.replace(/\./g, "\\.")));
    assert.match(plist, new RegExp(paths.cliEntrypointPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(plist, new RegExp(paths.launchAgentStdoutPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(plist, new RegExp(paths.launchAgentStderrPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});
