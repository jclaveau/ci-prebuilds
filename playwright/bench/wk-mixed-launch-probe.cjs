// Launches WebKit LAUNCH_COUNT times after WARM_COUNT warm launches and prints
// one JSON line per measured launch, splitting the CPU between node itself and
// the browser tree.
//
//   node_cpu_ms      process.cpuUsage() of this node process, launch + close
//   children_cpu_ms  utime+stime of every child node reaped during the launch
//                    (pw_run.sh, MiniBrowser, the WPE processes, transitively)
//   cgroup_cpu_ms    the container cgroup's usage_usec, which also catches a
//                    process nobody reaped
//   alive_ticks      per-comm ticks of the processes alive just before close
//
// GO_FILE: when set, the probe prints `ready <pid>` after the warm launches and
// waits for that file, so the host can attach perf to this pid first.
const fs = require('fs');
const { webkit } = require('playwright');

const warmCount = Number(process.env.WARM_COUNT || 3);
const launchCount = Number(process.env.LAUNCH_COUNT || 10);
const armName = process.env.ARM_NAME;
if (!armName) throw new Error('ARM_NAME is not set');

const clockTicksPerSecond = 100;
const tickToMs = 1000 / clockTicksPerSecond;

const readStatFields = (statPath) => {
  const statText = fs.readFileSync(statPath, 'utf8');
  return {
    commName: statText.slice(statText.indexOf('(') + 1, statText.lastIndexOf(')')),
    statFields: statText.slice(statText.lastIndexOf(')') + 2).split(' '),
  };
};

const readReapedChildrenMs = () => {
  const { statFields } = readStatFields('/proc/self/stat');
  return (Number(statFields[13]) + Number(statFields[14])) * tickToMs;
};

const readCgroupCpuMs = () => {
  const cpuStatText = fs.readFileSync('/sys/fs/cgroup/cpu.stat', 'utf8');
  const usageMatch = cpuStatText.match(/^usage_usec (\d+)$/m);
  if (!usageMatch) throw new Error(`no usage_usec in cpu.stat: ${cpuStatText}`);
  return Number(usageMatch[1]) / 1000;
};

const readAliveTicks = () => {
  const tickTotals = {};
  for (const entryName of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entryName) || Number(entryName) === process.pid) continue;
    let statRecord;
    try {
      statRecord = readStatFields(`/proc/${entryName}/stat`);
    } catch (readError) {
      // The process exited between readdir and read: nothing left to count.
      if (readError.code === 'ENOENT' || readError.code === 'ESRCH') continue;
      throw readError;
    }
    const { commName, statFields } = statRecord;
    const ownTicks = Number(statFields[11]) + Number(statFields[12]);
    tickTotals[commName] = (tickTotals[commName] || 0) + ownTicks;
  }
  return tickTotals;
};

const waitForGoFile = async (goFile) => {
  console.log(`ready ${process.pid}`);
  while (!fs.existsSync(goFile)) await new Promise((r) => setTimeout(r, 50));
};

(async () => {
  for (let warmIndex = 0; warmIndex < warmCount; warmIndex++) {
    await (await webkit.launch()).close();
  }
  if (process.env.GO_FILE) await waitForGoFile(process.env.GO_FILE);
  for (let launchIndex = 0; launchIndex < launchCount; launchIndex++) {
    const cpuBefore = process.cpuUsage();
    const childrenBefore = readReapedChildrenMs();
    const cgroupBefore = readCgroupCpuMs();
    const wallBefore = performance.now();
    const browserHandle = await webkit.launch();
    const launchWallMs = performance.now() - wallBefore;
    const aliveTicks = readAliveTicks();
    await browserHandle.close();
    const cpuDelta = process.cpuUsage(cpuBefore);
    console.log(JSON.stringify({
      arm: armName,
      launch_index: launchIndex,
      launch_wall_ms: launchWallMs,
      node_cpu_ms: (cpuDelta.user + cpuDelta.system) / 1000,
      node_user_ms: cpuDelta.user / 1000,
      node_sys_ms: cpuDelta.system / 1000,
      children_cpu_ms: readReapedChildrenMs() - childrenBefore,
      cgroup_cpu_ms: readCgroupCpuMs() - cgroupBefore,
      alive_ticks: aliveTicks,
    }));
  }
})().catch((probeError) => {
  console.error(probeError);
  process.exit(1);
});
