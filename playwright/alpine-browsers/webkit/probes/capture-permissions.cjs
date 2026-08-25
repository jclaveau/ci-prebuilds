// Does this WebKit artifact honour Browser.grantPermissions for camera and
// microphone? Prints one row per grant state so a run can be diffed against the
// official image.
//
// Reports BOTH navigator.permissions.query and getUserMedia on purpose: they
// travel different paths through PW's patches, and the whole camera/mic
// investigation turned on the fact that query agreed with official on every row
// while getUserMedia did not. A probe that only called getUserMedia would have
// said "permissions are broken" and sent the next person to the wrong layer.
//
// Serves over http://localhost: navigator.mediaDevices is undefined outside a
// secure context, and about:blank does not qualify. Testing there measures the
// secure-context rule rather than the artifact.

const http = require('http');
const { webkit } = require('playwright-core');

const GRANT_STATES = [
  { label: 'none', permissions: [] },
  { label: 'camera-only', permissions: ['camera'] },
  { label: 'camera+mic', permissions: ['camera', 'microphone'] },
];

async function queryPermissions(page) {
  return await page.evaluate(async () => {
    const states = {};
    for (const name of ['camera', 'microphone']) {
      try {
        states[name] = (await navigator.permissions.query({ name })).state;
      } catch (error) {
        states[name] = 'ERR ' + error.name;
      }
    }
    return states;
  });
}

async function getUserMedia(page, constraints) {
  return await page.evaluate(async requested => {
    if (!navigator.mediaDevices) {
      return 'no navigator.mediaDevices';
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia(requested);
      return stream.getTracks().map(track => track.kind).sort().join('+');
    } catch (error) {
      return error.name;
    }
  }, constraints);
}

async function enumerateDevices(page) {
  return await page.evaluate(async () => {
    if (!navigator.mediaDevices) {
      return [];
    }
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices.map(device => device.kind + '|' + device.label);
  });
}

(async () => {
  const server = http.createServer((_, response) => {
    response.setHeader('content-type', 'text/html');
    response.end('<h1>capture-permissions probe</h1>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = 'http://localhost:' + server.address().port;

  const browser = await webkit.launch();
  console.log('browser  ' + browser.version());
  console.log('origin   ' + origin);
  console.log('');
  console.log('grant         query(camera/mic)  video+audio      video            audio');
  console.log('------------  -----------------  ---------------  ---------------  ---------------');

  for (const { label, permissions } of GRANT_STATES) {
    // A fresh context per CELL, not per row. grantPermissions replaces the set
    // for an origin so a stale grant would silently pass the next row, and
    // repeated getUserMedia calls on one ungranted page take the browser down —
    // official dies on the third. Isolating each cell is also how the PW tests
    // this probe mirrors are written.
    const cell = async constraints => {
      const context = await browser.newContext();
      const page = await context.newPage();
      await page.goto(origin + '/');
      if (permissions.length) {
        await context.grantPermissions(permissions, { origin });
      }
      const result = { query: await queryPermissions(page) };
      result.media = constraints ? await getUserMedia(page, constraints) : null;
      // Labels stay blank until capture has actually been granted, so this
      // has to run after getUserMedia on the same page, not on a fresh one.
      result.devices = await enumerateDevices(page);
      await context.close();
      return result;
    };

    const both = await cell({ video: true, audio: true });
    const video = await cell({ video: true });
    const audio = await cell({ audio: true });

    console.log(
      label.padEnd(14)
      + (both.query.camera + '/' + both.query.microphone).padEnd(19)
      + both.media.padEnd(17) + video.media.padEnd(17) + audio.media);

    if (label === 'camera+mic') {
      console.log('');
      console.log('devices after a granted capture:');
      for (const device of both.devices) {
        console.log('  ' + device);
      }
    }
  }

  await browser.close();
  server.close();
})().catch(error => {
  console.error('probe failed:', error);
  process.exit(1);
});
