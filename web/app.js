import { ESPLoader, Transport } from './esptool.js';

// DOM Elements
const btnConnect = document.getElementById('btnConnect');
const btnConnectText = document.getElementById('btnConnectText');
const portIndicator = document.getElementById('portIndicator');
const btnFlash = document.getElementById('btnFlash');
const unsupportedWarning = document.getElementById('unsupportedWarning');

const tabGithub = document.getElementById('tabGithub');
const tabLocal = document.getElementById('tabLocal');
const paneGithub = document.getElementById('paneGithub');
const paneLocal = document.getElementById('paneLocal');
const sourceBadge = document.getElementById('sourceBadge');

const selectRelease = document.getElementById('selectRelease');
const btnRefreshReleases = document.getElementById('btnRefreshReleases');
const selectPackageType = document.getElementById('selectPackageType');
const releaseDetails = document.getElementById('releaseDetails');
const prBuildWarning = document.getElementById('prBuildWarning');
const prBuildNumber = document.getElementById('prBuildNumber');
const infoReleaseName = document.getElementById('infoReleaseName');
const infoReleaseDate = document.getElementById('infoReleaseDate');
const infoReleaseTag = document.getElementById('infoReleaseTag');
const infoReleaseAssets = document.getElementById('infoReleaseAssets');

const dropzone = document.getElementById('dropzone');
const inputLocalFile = document.getElementById('inputLocalFile');
const localFileDetails = document.getElementById('localFileDetails');
const localFileName = document.getElementById('localFileName');
const localFileSize = document.getElementById('localFileSize');
const inputFlashOffset = document.getElementById('inputFlashOffset');

const selectBaud = document.getElementById('selectBaud');
const chkEraseAll = document.getElementById('chkEraseAll');

const statChip = document.getElementById('statChip');
const statMac = document.getElementById('statMac');
const statFlash = document.getElementById('statFlash');
const statStatus = document.getElementById('statStatus');
const chipBadge = document.getElementById('chipBadge');

const progressContainer = document.getElementById('progressContainer');
const progressBar = document.getElementById('progressBar');
const progressStatusText = document.getElementById('progressStatusText');
const progressPercentText = document.getElementById('progressPercentText');

const consoleOutput = document.getElementById('consoleOutput');
const btnClearConsole = document.getElementById('btnClearConsole');

// App State
let activeSource = 'github'; // 'github' | 'local'
let port = null;
let transport = null;
let esploader = null;
let isConnected = false;
let isFlashing = false;
let githubReleases = [];
let localFileBinary = null;
let localFileNameStr = '';

// Known fallback releases if GitHub API rate-limits
const FALLBACK_RELEASES = [
  {
    tag_name: 'v3.0.0-rc1',
    name: 'C5VRX-3 v3.0.0-rc1: Seamless 16K Phase5 Production Receiver',
    published_at: '2026-09-18T17:01:49Z',
    prerelease: true,
    assets: [
      { name: 'c5vrx3.bin', size: 1082064, browser_download_url: 'https://github.com/Twotoz/C5VRX/releases/download/v3.0.0-rc1/c5vrx3.bin' },
      { name: 'bootloader.bin', size: 23232, browser_download_url: 'https://github.com/Twotoz/C5VRX/releases/download/v3.0.0-rc1/bootloader.bin' },
      { name: 'partition-table.bin', size: 3072, browser_download_url: 'https://github.com/Twotoz/C5VRX/releases/download/v3.0.0-rc1/partition-table.bin' },
    ]
  }
];

const VERSION_TAG_PATTERN = /^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
const PR_BUILD_TAG_PATTERN = /^pr-(\d+)$/;

function getPrBuildNumber(rel) {
  const match = PR_BUILD_TAG_PATTERN.exec(rel?.tag_name || '');
  return match ? parseInt(match[1], 10) : null;
}

// Terminal output helper
function log(msg, type = 'info') {
  const time = new Date().toLocaleTimeString();
  const prefix = `[${time}] `;
  consoleOutput.textContent += prefix + msg + '\n';
  consoleOutput.scrollTop = consoleOutput.scrollHeight;
}

const terminal = {
  clean() {
    consoleOutput.textContent = '';
  },
  writeLine(data) {
    consoleOutput.textContent += data + '\n';
    consoleOutput.scrollTop = consoleOutput.scrollHeight;
  },
  write(data) {
    consoleOutput.textContent += data;
    consoleOutput.scrollTop = consoleOutput.scrollHeight;
  }
};

// Check Web Serial support
function checkSerialSupport() {
  if (!('serial' in navigator)) {
    unsupportedWarning.style.display = 'block';
    btnConnect.disabled = true;
    log('ERROR: Web Serial API not supported in this browser. Please use Google Chrome, MS Edge, or Brave.', 'error');
    return false;
  }
  return true;
}

// Tab Switching
tabGithub.addEventListener('click', () => {
  activeSource = 'github';
  tabGithub.classList.add('active');
  tabLocal.classList.remove('active');
  paneGithub.classList.add('active');
  paneLocal.classList.remove('active');
  const idx = parseInt(selectRelease.value, 10);
  if (Number.isInteger(idx)) {
    onReleaseSelected(idx);
  } else {
    sourceBadge.textContent = 'GitHub';
    sourceBadge.className = 'badge';
  }
  updateFlashButtonState();
});

tabLocal.addEventListener('click', () => {
  activeSource = 'local';
  tabLocal.classList.add('active');
  tabGithub.classList.remove('active');
  paneLocal.classList.add('active');
  paneGithub.classList.remove('active');
  sourceBadge.textContent = 'Local File';
  sourceBadge.className = 'badge badge-secondary';
  updateFlashButtonState();
});

// Drag & drop file handling
dropzone.addEventListener('click', () => inputLocalFile.click());
dropzone.addEventListener('dragover', (e) => {
  e.preventDefault();
  dropzone.classList.add('dragover');
});
dropzone.addEventListener('dragleave', () => dropzone.classList.remove('dragover'));
dropzone.addEventListener('drop', (e) => {
  e.preventDefault();
  dropzone.classList.remove('dragover');
  if (e.dataTransfer.files.length > 0) {
    handleLocalFile(e.dataTransfer.files[0]);
  }
});
inputLocalFile.addEventListener('change', (e) => {
  if (e.target.files.length > 0) {
    handleLocalFile(e.target.files[0]);
  }
});

function handleLocalFile(file) {
  if (!file.name.endsWith('.bin')) {
    alert('Please select a compiled firmware binary (.bin file)');
    return;
  }
  localFileNameStr = file.name;
  localFileName.textContent = file.name;
  localFileSize.textContent = `${(file.size / 1024).toFixed(1)} KB (${file.size.toLocaleString()} bytes)`;

  // Suggest default offset based on name
  if (file.name.toLowerCase().includes('merged')) {
    inputFlashOffset.value = '0x0';
  } else if (file.name.toLowerCase().includes('bootloader')) {
    inputFlashOffset.value = '0x2000';
  } else if (file.name.toLowerCase().includes('partition')) {
    inputFlashOffset.value = '0x8000';
  } else {
    inputFlashOffset.value = '0x10000';
  }

  const reader = new FileReader();
  reader.onload = (event) => {
    localFileBinary = event.target.result;
    localFileDetails.style.display = 'block';
    log(`Loaded local file: ${file.name} (${file.size} bytes)`);
    updateFlashButtonState();
  };
  reader.readAsArrayBuffer(file);
}

// Fetch GitHub Releases
async function fetchReleases() {
  selectRelease.innerHTML = '<option value="">Fetching releases from GitHub...</option>';
  try {
    const res = await fetch('https://api.github.com/repos/Twotoz/C5VRX/releases?per_page=100', {
      headers: { 'Accept': 'application/vnd.github.v3+json' }
    });
    if (!res.ok) throw new Error(`GitHub API HTTP ${res.status}`);
    const data = await res.json();
    if (!Array.isArray(data) || data.length === 0) throw new Error('No releases found');

    // Production releases always stay first and remain the default selection.
    // PR builds are explicit prereleases tagged pr-<number>.
    let productionReleases = data
      .filter(rel => VERSION_TAG_PATTERN.test(rel.tag_name || ''))
      .sort((a, b) => new Date(b.published_at || 0) - new Date(a.published_at || 0));
    const prBuilds = data
      .filter(rel => rel.prerelease && PR_BUILD_TAG_PATTERN.test(rel.tag_name || ''))
      .sort((a, b) => new Date(b.published_at || 0) - new Date(a.published_at || 0));

    if (productionReleases.length === 0) {
      log('Warning: No versioned release returned by GitHub. Keeping the cached production release as the safe default.');
      productionReleases = FALLBACK_RELEASES;
    }

    githubReleases = [...productionReleases, ...prBuilds];
    log(`Fetched ${productionReleases.length} versioned release(s) and ${prBuilds.length} experimental PR build(s).`);
  } catch (err) {
    log(`Warning: Failed to fetch versioned releases (${err.message}). Using cached release index.`);
    githubReleases = FALLBACK_RELEASES;
  }

  populateReleaseDropdown();
}
function populateReleaseDropdown() {
  selectRelease.innerHTML = '';

  const releaseGroup = document.createElement('optgroup');
  releaseGroup.label = 'Versioned releases';
  const prGroup = document.createElement('optgroup');
  prGroup.label = '⚠ Experimental PR builds';

  githubReleases.forEach((rel, index) => {
    const opt = document.createElement('option');
    opt.value = index;
    const tag = rel.tag_name || rel.name;
    const prNumber = getPrBuildNumber(rel);

    if (prNumber !== null) {
      opt.textContent = `PR #${prNumber} [EXPERIMENTAL / UNMERGED]`;
      prGroup.appendChild(opt);
      return;
    }

    const isLatestProduction = releaseGroup.children.length === 0;
    if (rel.prerelease) {
      opt.textContent = `${tag} [Pre-release]${isLatestProduction ? ' (Latest available)' : ''}`;
    } else {
      opt.textContent = `${tag}${isLatestProduction ? ' (Latest - Recommended)' : ''}`;
    }
    releaseGroup.appendChild(opt);
  });

  if (releaseGroup.children.length > 0) selectRelease.appendChild(releaseGroup);
  if (prGroup.children.length > 0) selectRelease.appendChild(prGroup);

  // Normal releases are stored before PR builds, so index 0 is never a PR
  // build when a versioned release (or the cached safe release) exists.
  if (githubReleases.length > 0) {
    selectRelease.value = '0';
    onReleaseSelected(0);
  }
}
selectRelease.addEventListener('change', () => {
  const idx = parseInt(selectRelease.value, 10);
  onReleaseSelected(idx);
});

btnRefreshReleases.addEventListener('click', () => {
  log('Refreshing releases from GitHub...');
  fetchReleases();
});

function onReleaseSelected(index) {
  const rel = githubReleases[index];
  if (!rel) return;
  releaseDetails.style.display = 'block';
  infoReleaseName.textContent = rel.name || rel.tag_name;
  infoReleaseDate.textContent = rel.published_at ? new Date(rel.published_at).toLocaleDateString() : 'N/A';
  infoReleaseTag.textContent = rel.tag_name;

  const prNumber = getPrBuildNumber(rel);
  if (prNumber !== null) {
    prBuildNumber.textContent = `#${prNumber}`;
    prBuildWarning.style.display = 'block';
    sourceBadge.textContent = `PR #${prNumber}`;
    sourceBadge.className = 'badge badge-danger';
  } else {
    prBuildWarning.style.display = 'none';
    sourceBadge.textContent = 'GitHub';
    sourceBadge.className = 'badge';
  }

  const assetNames = (rel.assets || []).map(a => a.name).join(', ') || 'No binary assets attached';
  infoReleaseAssets.textContent = assetNames;

  updateFlashButtonState();
}

function updateFlashButtonState() {
  if (!isConnected || isFlashing) {
    btnFlash.disabled = true;
    return;
  }
  if (activeSource === 'github') {
    btnFlash.disabled = (githubReleases.length === 0);
  } else {
    btnFlash.disabled = (localFileBinary === null);
  }
}

function findApplicationAsset(assets) {
  // GitHub returns release assets in upload order. Never use the first .bin:
  // bootloader.bin is commonly uploaded before the application image.
  return assets.find(asset => /^c5vrx(?:3)?\.bin$/i.test(asset.name || '')) ||
    assets.find(asset => {
      const name = (asset.name || '').toLowerCase();
      return name.endsWith('.bin') &&
        !name.includes('bootloader') &&
        !name.includes('partition') &&
        !name.includes('merged');
    });
}

// Connect / Disconnect Handler
btnConnect.addEventListener('click', async () => {
  if (isConnected) {
    await disconnectDevice();
  } else {
    await connectDevice();
  }
});

async function connectDevice() {
  if (!checkSerialSupport()) return;

  try {
    log('Opening Web Serial port selector...');
    port = await navigator.serial.requestPort();
    log('Port selected. Initializing connection...');

    statStatus.textContent = 'Connecting...';
    btnConnect.disabled = true;

    transport = new Transport(port);
    const baudrate = parseInt(selectBaud.value, 10) || 460800;

    esploader = new ESPLoader({
      transport: transport,
      baudrate: baudrate,
      terminal: terminal,
      romBaudrate: 115200,
      debugLogging: false
    });

    log('Handshaking with ESP32-C5 ROM bootloader...');
    // Attempt connection with hardware reset
    await esploader.main("usb_reset");

    isConnected = true;
    portIndicator.className = 'indicator indicator-on';
    btnConnectText.textContent = 'Disconnect';
    btnConnect.disabled = false;
    btnConnect.classList.remove('btn-primary');
    btnConnect.classList.add('btn-secondary');

    const chipName = esploader.chip ? esploader.chip.CHIP_NAME : 'ESP32-C5';
    statChip.textContent = chipName;
    chipBadge.textContent = chipName;
    chipBadge.className = 'badge';

    try {
      const mac = await esploader.chip.readMac(esploader);
      statMac.textContent = mac || 'Unknown';
    } catch (e) {
      statMac.textContent = '—';
    }

    statStatus.textContent = 'Ready';
    log(`Connected successfully to ${chipName}!`);
    updateFlashButtonState();

  } catch (err) {
    log(`Connection failed: ${err.message || err}`, 'error');
    alert(`Failed to connect: ${err.message || err}\n\nTroubleshooting Tip:\nIf port timed out, hold BOOT (B) on the XIAO board, tap RESET (R), and release BOOT to force ROM bootloader mode.`);
    await disconnectDevice();
  }
}

async function disconnectDevice() {
  try {
    if (transport) {
      await transport.disconnect();
    }
  } catch (e) {
    // Ignore close errors
  }
  port = null;
  transport = null;
  esploader = null;
  isConnected = false;

  portIndicator.className = 'indicator indicator-off';
  btnConnectText.textContent = 'Connect Device';
  btnConnect.disabled = false;
  btnConnect.classList.remove('btn-secondary');
  btnConnect.classList.add('btn-primary');

  statChip.textContent = 'ESP32-C5';
  statMac.textContent = '—';
  statStatus.textContent = 'Disconnected';
  chipBadge.textContent = 'No Device';
  chipBadge.className = 'badge badge-secondary';

  log('Device disconnected.');
  updateFlashButtonState();
}

// Flashing Handler
btnFlash.addEventListener('click', async () => {
  if (!isConnected || !esploader || isFlashing) return;

  if (activeSource === 'github') {
    const selectedRelease = githubReleases[parseInt(selectRelease.value, 10)];
    const prNumber = getPrBuildNumber(selectedRelease);
    if (prNumber !== null) {
      const accepted = window.confirm(
        `WARNING: PR #${prNumber} is an experimental, unmerged test build.\n\n` +
        'It may be unstable, fail to boot, corrupt settings, or produce broken video. ' +
        'Only continue if you intentionally want to test this PR build.\n\nFlash it anyway?'
      );
      if (!accepted) {
        log(`Cancelled experimental PR #${prNumber} flash.`);
        return;
      }
    }
  }

  isFlashing = true;
  btnFlash.disabled = true;
  btnConnect.disabled = true;
  progressContainer.style.display = 'block';
  progressBar.style.width = '0%';
  progressPercentText.textContent = '0%';
  progressStatusText.textContent = 'Preparing firmware images...';

  try {
    const fileArray = [];

    if (activeSource === 'github') {
      const rel = githubReleases[parseInt(selectRelease.value, 10)];
      if (!rel) throw new Error('No release selected');
      const assets = rel.assets || [];
      const packageType = selectPackageType.value;

      log(`Fetching binaries for release ${rel.tag_name} (${packageType})...`);

      if (packageType === 'merged') {
        const mergedAsset = assets.find(a => a.name.includes('merged'));
        if (mergedAsset) {
          log(`Downloading ${mergedAsset.name}...`);
          const buf = await fetchBinary(mergedAsset.browser_download_url);
          fileArray.push({ data: new Uint8Array(buf), address: 0x0 });
        } else {
          // Standard 3-part layout
          const bootloader = assets.find(a => a.name.includes('bootloader'));
          const ptable = assets.find(a => a.name.includes('partition'));
          const app = findApplicationAsset(assets);
          const missing = [
            !bootloader && 'bootloader',
            !ptable && 'partition table',
            !app && 'application firmware',
          ].filter(Boolean);
          if (missing.length > 0) {
            throw new Error(`Incomplete full firmware package: missing ${missing.join(', ')}`);
          }

          log(`Downloading bootloader (${bootloader.name})...`);
          const bBuf = await fetchBinary(bootloader.browser_download_url);
          fileArray.push({ data: new Uint8Array(bBuf), address: 0x2000 });
          log(`Downloading partition table (${ptable.name})...`);
          const pBuf = await fetchBinary(ptable.browser_download_url);
          fileArray.push({ data: new Uint8Array(pBuf), address: 0x8000 });
          log(`Downloading app binary (${app.name})...`);
          const aBuf = await fetchBinary(app.browser_download_url);
          fileArray.push({ data: new Uint8Array(aBuf), address: 0x10000 });
        }
      } else {
        // App only
        const app = findApplicationAsset(assets);
        if (!app) throw new Error('Could not find application firmware binary in release assets');
        log(`Downloading app binary (${app.name})...`);
        const aBuf = await fetchBinary(app.browser_download_url);
        fileArray.push({ data: new Uint8Array(aBuf), address: 0x10000 });
      }
    } else {
      // Local File
      if (!localFileBinary) throw new Error('No local binary selected');
      let offset = parseInt(inputFlashOffset.value.trim(), 16);
      if (isNaN(offset)) offset = 0x0;
      fileArray.push({
        data: new Uint8Array(localFileBinary),
        address: offset
      });
    }

    if (fileArray.length === 0) throw new Error('No files to flash');

    const totalBytes = fileArray.reduce((acc, f) => acc + f.data.length, 0);
    log(`Starting flash operation: ${fileArray.length} file(s), ${totalBytes.toLocaleString()} total bytes.`);

    progressStatusText.textContent = 'Flashing...';

    const flashOptions = {
      fileArray: fileArray,
      flashSize: '8MB',
      flashMode: 'dio',
      flashFreq: '80m',
      eraseAll: chkEraseAll.checked,
      // ESP32-C5 native USB-Serial/JTAG can fail mid-write in the compressed path (status 201,0).
      compress: false,
      reportProgress: (fileIndex, written, total) => {
        const percent = Math.floor((written / total) * 100);
        progressBar.style.width = `${percent}%`;
        progressPercentText.textContent = `${percent}%`;
        progressStatusText.textContent = `Writing file ${fileIndex + 1}/${fileArray.length} (${(written / 1024).toFixed(0)}KB / ${(total / 1024).toFixed(0)}KB)`;
      }
    };

    await esploader.writeFlash(flashOptions);

    progressBar.style.width = '100%';
    progressPercentText.textContent = '100%';
    progressStatusText.textContent = 'Flash Complete! Resetting device...';
    log('Flash written and hash verified successfully!');

    log('Hard resetting device into new firmware...');
    try {
      await esploader.after('hard_reset');
    } catch (e) {
      // Hardware reset pulse might close port on USB-CDC
    }

    log('====================================================');
    log('FLASHING COMPLETED SUCCESSFULLY!');
    log('Your C5VRX receiver is now running the new firmware.');
    log('====================================================');
    alert('Flashing completed successfully! Device has been reset.');

  } catch (err) {
    log(`Flashing failed: ${err.message || err}`, 'error');
    alert(`Flashing error: ${err.message || err}`);
    progressStatusText.textContent = 'Flash Failed';
  } finally {
    isFlashing = false;
    btnConnect.disabled = false;
    updateFlashButtonState();
  }
});

async function fetchBinary(url) {
  // Use CORS proxy if needed or direct fetch
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.arrayBuffer();
  } catch (e) {
    // If browser blocks GitHub release redirect via CORS, try github raw or corsproxy
    log(`Direct fetch failed (${e.message}), attempting CORS proxy...`);
    const proxyUrl = `https://corsproxy.io/?${encodeURIComponent(url)}`;
    const res = await fetch(proxyUrl);
    if (!res.ok) throw new Error(`Proxy HTTP ${res.status}`);
    return await res.arrayBuffer();
  }
}

btnClearConsole.addEventListener('click', () => {
  terminal.clean();
  log('Console cleared.');
});

// Initialization
document.addEventListener('DOMContentLoaded', () => {
  log('C5VRX Web Flasher initialized.');
  checkSerialSupport();
  fetchReleases();
});
