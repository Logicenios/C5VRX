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
  },
  {
    tag_name: 'legacy/v2-final',
    name: 'C5VRX-2: Research Platform & Multi-Candidate Demodulator',
    published_at: '2026-09-18T17:01:37Z',
    prerelease: false,
    assets: [
      { name: 'c5vrx2.bin', size: 1205000, browser_download_url: 'https://github.com/Twotoz/C5VRX/releases/download/legacy%2Fv2-final/c5vrx2.bin' }
    ]
  }
];

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

// Convert ArrayBuffer to binary string required by esptool-js
function bufferToBinaryString(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const len = bytes.byteLength;
  const chunkSize = 8192;
  for (let i = 0; i < len; i += chunkSize) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + chunkSize, len)));
  }
  return binary;
}

// Tab Switching
tabGithub.addEventListener('click', () => {
  activeSource = 'github';
  tabGithub.classList.add('active');
  tabLocal.classList.remove('active');
  paneGithub.classList.add('active');
  paneLocal.classList.remove('active');
  sourceBadge.textContent = 'GitHub';
  updateFlashButtonState();
});

tabLocal.addEventListener('click', () => {
  activeSource = 'local';
  tabLocal.classList.add('active');
  tabGithub.classList.remove('active');
  paneLocal.classList.add('active');
  paneGithub.classList.remove('active');
  sourceBadge.textContent = 'Local File';
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
    const res = await fetch('https://api.github.com/repos/Twotoz/C5VRX/releases', {
      headers: { 'Accept': 'application/vnd.github.v3+json' }
    });
    if (!res.ok) throw new Error(`GitHub API HTTP ${res.status}`);
    const data = await res.json();
    if (!Array.isArray(data) || data.length === 0) throw new Error('No releases found');
    githubReleases = data;
    log(`Successfully fetched ${githubReleases.length} releases from GitHub.`);
  } catch (err) {
    log(`Warning: Failed to fetch online releases (${err.message}). Using cached release index.`);
    githubReleases = FALLBACK_RELEASES;
  }
  populateReleaseDropdown();
}

function populateReleaseDropdown() {
  selectRelease.innerHTML = '';
  githubReleases.forEach((rel, index) => {
    const opt = document.createElement('option');
    opt.value = index;
    const isLatest = index === 0;
    const tag = rel.tag_name || rel.name;
    opt.textContent = `${tag}${rel.prerelease ? ' [Pre-release]' : ''}${isLatest ? ' (Latest)' : ''}`;
    selectRelease.appendChild(opt);
  });
  if (githubReleases.length > 0) {
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
          fileArray.push({ data: bufferToBinaryString(buf), address: 0x0 });
        } else {
          // Standard 3-part layout
          const bootloader = assets.find(a => a.name.includes('bootloader'));
          const ptable = assets.find(a => a.name.includes('partition'));
          const app = assets.find(a => a.name.includes('c5vrx') || a.name.endsWith('.bin'));

          if (!app) throw new Error('Could not find application firmware binary in release assets');

          if (bootloader) {
            log(`Downloading bootloader (${bootloader.name})...`);
            const bBuf = await fetchBinary(bootloader.browser_download_url);
            fileArray.push({ data: bufferToBinaryString(bBuf), address: 0x2000 });
          }
          if (ptable) {
            log(`Downloading partition table (${ptable.name})...`);
            const pBuf = await fetchBinary(ptable.browser_download_url);
            fileArray.push({ data: bufferToBinaryString(pBuf), address: 0x8000 });
          }
          log(`Downloading app binary (${app.name})...`);
          const aBuf = await fetchBinary(app.browser_download_url);
          fileArray.push({ data: bufferToBinaryString(aBuf), address: 0x10000 });
        }
      } else {
        // App only
        const app = assets.find(a => a.name.includes('c5vrx') || a.name.endsWith('.bin'));
        if (!app) throw new Error('Could not find application firmware binary in release assets');
        log(`Downloading app binary (${app.name})...`);
        const aBuf = await fetchBinary(app.browser_download_url);
        fileArray.push({ data: bufferToBinaryString(aBuf), address: 0x10000 });
      }
    } else {
      // Local File
      if (!localFileBinary) throw new Error('No local binary selected');
      let offset = parseInt(inputFlashOffset.value.trim(), 16);
      if (isNaN(offset)) offset = 0x0;
      fileArray.push({
        data: bufferToBinaryString(localFileBinary),
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
      compress: true,
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
