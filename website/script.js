// ==========================================================================
// OpenNook Interactive Website & Non-Scrolling Adaptive Simulator Controller
// ==========================================================================

document.addEventListener('DOMContentLoaded', () => {
  const island = document.getElementById('openNookIsland');
  const collapsedPill = document.getElementById('simCollapsedPill');
  const btnPinNook = document.getElementById('btnPinNook');
  const btnCycleNotchSize = document.getElementById('btnCycleNotchSize');
  const notchSizeBadgeText = document.getElementById('notchSizeBadgeText');
  const sizePresetBtns = document.querySelectorAll('.size-preset-btn');
  const simDropOverlay = document.getElementById('simDropOverlay');

  const tabBtns = document.querySelectorAll('.notch-tab-btn');
  const tabPanels = {
    nook: document.getElementById('panel-nook'),
    tray: document.getElementById('panel-tray')
  };

  // --------------------------------------------------------------------------
  // 1. Adaptive Notch & Widget Size Presets (Compact / Standard / Large)
  // --------------------------------------------------------------------------
  const sizeOrder = ['compact', 'standard', 'large'];
  const sizeLabels = {
    compact: 'Compact',
    standard: 'Standard',
    large: 'Large'
  };
  let currentSize = 'standard';

  function applyNotchSize(size) {
    if (!sizeOrder.includes(size)) return;
    currentSize = size;
    if (island) {
      island.classList.remove('size-compact', 'size-standard', 'size-large');
      island.classList.add(`size-${size}`);
      if (!isExpanded) setExpanded(true);
    }
    if (notchSizeBadgeText) {
      notchSizeBadgeText.textContent = sizeLabels[size];
    }
    sizePresetBtns.forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.size === size);
    });
  }

  sizePresetBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      applyNotchSize(btn.dataset.size);
    });
  });

  if (btnCycleNotchSize) {
    btnCycleNotchSize.addEventListener('click', (e) => {
      e.stopPropagation();
      const nextIdx = (sizeOrder.indexOf(currentSize) + 1) % sizeOrder.length;
      applyNotchSize(sizeOrder[nextIdx]);
    });
  }

  // --------------------------------------------------------------------------
  // 2. Hover to Expand / Leave to Collapse Notch
  // --------------------------------------------------------------------------
  let isExpanded = true;
  let isPinned = false;
  let isDraggingFile = false;
  let collapseTimer = null;

  function setExpanded(expand) {
    isExpanded = expand;
    if (!island) return;
    island.classList.toggle('expanded', expand);
    island.classList.toggle('collapsed', !expand);
  }

  if (collapsedPill) {
    collapsedPill.addEventListener('mouseenter', () => {
      clearTimeout(collapseTimer);
      setExpanded(true);
    });
    collapsedPill.addEventListener('click', () => {
      clearTimeout(collapseTimer);
      setExpanded(true);
    });
  }

  if (island) {
    island.addEventListener('mouseenter', () => {
      clearTimeout(collapseTimer);
      if (!isExpanded) setExpanded(true);
    });

    island.addEventListener('mouseleave', () => {
      if (isPinned || isDraggingFile) return;
      const activeEl = document.activeElement;
      if (activeEl && island.contains(activeEl) && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA')) {
        return;
      }
      collapseTimer = setTimeout(() => {
        setExpanded(false);
      }, 450);
    });
  }

  if (btnPinNook) {
    btnPinNook.addEventListener('click', (e) => {
      e.stopPropagation();
      isPinned = !isPinned;
      btnPinNook.classList.toggle('active', isPinned);
    });
  }

  // --------------------------------------------------------------------------
  // 3. Nook / Tray Tab Switching
  // --------------------------------------------------------------------------
  function switchTab(tabName) {
    if (!isExpanded) setExpanded(true);
    tabBtns.forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.tabTarget === tabName);
    });
    Object.keys(tabPanels).forEach((key) => {
      if (tabPanels[key]) {
        tabPanels[key].classList.toggle('active', key === tabName);
      }
    });
  }

  tabBtns.forEach((btn) => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tabTarget));
  });

  // --------------------------------------------------------------------------
  // 4. Widget 1: Media Player (Play/Pause, Skip, Inline Scrubber Seek)
  // --------------------------------------------------------------------------
  const playlist = [
    { title: 'My Seaside Morning', artist: 'Bonobo', duration: 800, elapsed: 173, color: '#d97706' },
    { title: 'Starboy', artist: 'The Weeknd • YT Music', duration: 230, elapsed: 64, color: '#1d4ed8' },
    { title: 'Veridis Quo', artist: 'Daft Punk • Apple Music', duration: 345, elapsed: 112, color: '#059669' }
  ];
  let trackIndex = 0;
  let isPlaying = true;

  const elTitle = document.getElementById('simTrackTitle');
  const elArtist = document.getElementById('simTrackArtist');
  const elAlbum = document.getElementById('simAlbumArt');
  const collapsedMiniArt = document.getElementById('collapsedMiniArt');
  const elCurrentTime = document.getElementById('simCurrentTime');
  const elTotalTime = document.getElementById('simTotalTime');
  const elProgressFill = document.getElementById('simProgressFill');
  const elScrubberTrack = document.getElementById('simScrubberTrack');
  const elPlayPauseBtn = document.getElementById('simPlayPauseBtn');
  const elPlayIcon = document.getElementById('simPlayIcon');
  const elPrevBtn = document.getElementById('simPrevBtn');
  const elNextBtn = document.getElementById('simNextBtn');
  const elVisualizer = document.getElementById('simVisualizer');

  function formatMMSS(sec) {
    const s = Math.max(0, Math.floor(sec));
    const m = Math.floor(s / 60);
    const rem = s % 60;
    return `${m < 10 ? '0' : ''}${m}:${rem < 10 ? '0' : ''}${rem}`;
  }

  function renderTrack() {
    const t = playlist[trackIndex];
    if (elTitle) elTitle.textContent = t.title;
    if (elArtist) elArtist.textContent = t.artist;
    if (elAlbum) elAlbum.style.backgroundColor = t.color;
    if (collapsedMiniArt) collapsedMiniArt.style.backgroundColor = t.color;
    if (elCurrentTime) elCurrentTime.textContent = formatMMSS(t.elapsed);
    if (elTotalTime) elTotalTime.textContent = formatMMSS(t.duration);
    if (elProgressFill) {
      const pct = Math.min(100, Math.max(0, (t.elapsed / t.duration) * 100));
      elProgressFill.style.width = `${pct}%`;
    }
  }

  function renderPlayIcon() {
    if (elVisualizer) elVisualizer.classList.toggle('playing', isPlaying);
    if (elPlayIcon) {
      elPlayIcon.innerHTML = isPlaying
        ? '<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>'
        : '<polygon points="6 4 20 12 6 20 6 4"/>';
    }
  }

  renderTrack();
  renderPlayIcon();

  if (elPlayPauseBtn) {
    elPlayPauseBtn.addEventListener('click', () => {
      isPlaying = !isPlaying;
      renderPlayIcon();
    });
  }

  if (elNextBtn) {
    elNextBtn.addEventListener('click', () => {
      trackIndex = (trackIndex + 1) % playlist.length;
      playlist[trackIndex].elapsed = 0;
      isPlaying = true;
      renderPlayIcon();
      renderTrack();
    });
  }

  if (elPrevBtn) {
    elPrevBtn.addEventListener('click', () => {
      trackIndex = (trackIndex - 1 + playlist.length) % playlist.length;
      playlist[trackIndex].elapsed = 0;
      isPlaying = true;
      renderPlayIcon();
      renderTrack();
    });
  }

  if (elScrubberTrack) {
    elScrubberTrack.addEventListener('click', (e) => {
      const rect = elScrubberTrack.getBoundingClientRect();
      const ratio = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
      const t = playlist[trackIndex];
      t.elapsed = Math.round(ratio * t.duration);
      renderTrack();
    });
  }

  setInterval(() => {
    if (!isPlaying) return;
    const t = playlist[trackIndex];
    t.elapsed = (t.elapsed + 1) % t.duration;
    renderTrack();
  }, 1000);

  // --------------------------------------------------------------------------
  // 5. Widget 2: Circular Mirror Widget
  // --------------------------------------------------------------------------
  const mirrorPod = document.getElementById('simMirrorPod');
  const mirrorIdle = document.getElementById('simMirrorIdle');
  const mirrorActive = document.getElementById('simMirrorActive');
  let mirrorOn = false;

  if (mirrorPod) {
    mirrorPod.addEventListener('click', (e) => {
      e.stopPropagation();
      mirrorOn = !mirrorOn;
      if (mirrorIdle) mirrorIdle.classList.toggle('hidden', mirrorOn);
      if (mirrorActive) mirrorActive.classList.toggle('hidden', !mirrorOn);
    });
  }

  // --------------------------------------------------------------------------
  // 6. Widget 3: Calendar Schedule Widget
  // --------------------------------------------------------------------------
  const calDays = document.querySelectorAll('.cw-day');
  const calStatusText = document.getElementById('simCalStatusText');
  const eventsByDay = {
    '26': 'Nothing for today',
    '27': 'Nothing for today',
    '28': 'Design Review • 10:30 AM',
    '29': 'Release Sync • 2:00 PM',
    '30': 'Nothing for today'
  };

  calDays.forEach((btn) => {
    btn.addEventListener('click', () => {
      calDays.forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      if (calStatusText) {
        calStatusText.textContent = eventsByDay[btn.dataset.day] || 'Nothing for today';
      }
    });
  });

  // --------------------------------------------------------------------------
  // 7. Widget 4: Rich Notes Widget (Aa, B, I, U, S + Trash)
  // --------------------------------------------------------------------------
  const notesInput = document.getElementById('simNotesInput');
  const btnClearNotes = document.getElementById('btnClearNotes');
  const fmtBtns = document.querySelectorAll('.nw-fmt-btn');

  if (btnClearNotes && notesInput) {
    btnClearNotes.addEventListener('click', () => {
      notesInput.value = '';
      notesInput.focus();
    });
  }

  fmtBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      if (!notesInput) return;
      const fmt = btn.dataset.fmt;
      if (fmt === 'size') {
        notesInput.style.fontSize = notesInput.style.fontSize === '0.78rem' ? '' : '0.78rem';
      } else if (fmt === 'bold') {
        notesInput.style.fontWeight = notesInput.style.fontWeight === '700' ? '400' : '700';
      } else if (fmt === 'italic') {
        notesInput.style.fontStyle = notesInput.style.fontStyle === 'italic' ? 'normal' : 'italic';
      } else if (fmt === 'underline') {
        notesInput.style.textDecoration = notesInput.style.textDecoration === 'underline' ? 'none' : 'underline';
      } else if (fmt === 'strike') {
        notesInput.style.textDecoration = notesInput.style.textDecoration === 'line-through' ? 'none' : 'line-through';
      }
    });
  });

  // --------------------------------------------------------------------------
  // 8. Widget 5: Multi-Timer Widget (Uniform Blue 03h:00m:00s Dial + Presets)
  // --------------------------------------------------------------------------
  let timerTotalSecs = 10800; // 03h : 00m : 00s
  let timerRunning = false;

  const twHours = document.getElementById('twHours');
  const twMins = document.getElementById('twMins');
  const twSecs = document.getElementById('twSecs');
  const simTimerToggle = document.getElementById('simTimerToggle');
  const simTimerReset = document.getElementById('simTimerReset');
  const timerChips = document.querySelectorAll('.tw-chip');
  const btnToggleTimerList = document.getElementById('btnToggleTimerList');
  const btnBackToDial = document.getElementById('btnBackToDial');
  const timerDialView = document.getElementById('timerDialView');
  const timerListView = document.getElementById('timerListView');
  const savedRows = document.querySelectorAll('.tw-saved-row');

  function pad2(n) {
    return n < 10 ? `0${n}` : `${n}`;
  }

  function renderTimerDigits() {
    const h = Math.floor(timerTotalSecs / 3600);
    const m = Math.floor((timerTotalSecs % 3600) / 60);
    const s = timerTotalSecs % 60;
    if (twHours) twHours.textContent = `${pad2(h)}h`;
    if (twMins) twMins.textContent = `${pad2(m)}m`;
    if (twSecs) twSecs.textContent = `${pad2(s)}s`;
    if (simTimerToggle) simTimerToggle.innerHTML = timerRunning ? '&#10074;&#10074;' : '&#9654;';
  }

  renderTimerDigits();

  if (twHours) {
    twHours.addEventListener('click', () => {
      timerTotalSecs += 3600;
      renderTimerDigits();
    });
  }
  if (twMins) {
    twMins.addEventListener('click', () => {
      timerTotalSecs += 60;
      renderTimerDigits();
    });
  }
  if (twSecs) {
    twSecs.addEventListener('click', () => {
      timerTotalSecs += 10;
      renderTimerDigits();
    });
  }

  timerChips.forEach((chip) => {
    chip.addEventListener('click', () => {
      timerChips.forEach((c) => c.classList.remove('active'));
      chip.classList.add('active');
      timerTotalSecs = parseInt(chip.dataset.mins || '5', 10) * 60;
      timerRunning = true;
      renderTimerDigits();
    });
  });

  if (simTimerToggle) {
    simTimerToggle.addEventListener('click', () => {
      if (timerTotalSecs <= 0) timerTotalSecs = 300;
      timerRunning = !timerRunning;
      renderTimerDigits();
    });
  }

  if (simTimerReset) {
    simTimerReset.addEventListener('click', () => {
      timerRunning = false;
      timerTotalSecs = 0;
      renderTimerDigits();
    });
  }

  if (btnToggleTimerList && timerDialView && timerListView) {
    btnToggleTimerList.addEventListener('click', () => {
      timerDialView.classList.add('hidden');
      timerListView.classList.remove('hidden');
    });
  }

  if (btnBackToDial && timerDialView && timerListView) {
    btnBackToDial.addEventListener('click', () => {
      timerListView.classList.add('hidden');
      timerDialView.classList.remove('hidden');
    });
  }

  savedRows.forEach((row) => {
    row.addEventListener('click', () => {
      timerTotalSecs = parseInt(row.dataset.mins || '5', 10) * 60;
      timerRunning = true;
      if (timerListView) timerListView.classList.add('hidden');
      if (timerDialView) timerDialView.classList.remove('hidden');
      renderTimerDigits();
    });
  });

  setInterval(() => {
    if (!timerRunning || timerTotalSecs <= 0) return;
    timerTotalSecs -= 1;
    if (timerTotalSecs <= 0) timerRunning = false;
    renderTimerDigits();
  }, 1000);

  // --------------------------------------------------------------------------
  // 9. Tray File Shelf & Drag-and-Drop from "OpenNook Drop Demo" Finder Window
  // --------------------------------------------------------------------------
  const trayShelf = document.getElementById('simTrayShelf');
  const trayBadgeCount = document.getElementById('trayBadgeCount');
  const finderItems = document.querySelectorAll('.finder-file-item');

  let trayFiles = [
    { name: 'Work 1.1', color: '#0a84ff', type: 'folder' },
    { name: 'Aqua Pulse.png', color: '#0284c7', type: 'image' },
    { name: 'Emerald Glow.png', color: '#059669', type: 'image' },
    { name: 'Solar Orbit.png', color: '#ea580c', type: 'image' },
    { name: 'Violet Vortex.png', color: '#7c3aed', type: 'image' }
  ];

  function renderTrayShelf() {
    if (!trayShelf) return;
    trayShelf.innerHTML = '';
    if (trayBadgeCount) trayBadgeCount.textContent = `${trayFiles.length}`;

    trayFiles.forEach((f, idx) => {
      const item = document.createElement('div');
      item.className = 'tray-shelf-item';
      const thumbHTML = f.type === 'folder'
        ? `<div class="tray-shelf-thumb" style="background: transparent; border: none;">
             <svg width="42" height="36" viewBox="0 0 48 40" fill="none">
               <path d="M4 8C4 5.79086 5.79086 4 8 4H18L22 8H40C42.2091 8 44 9.79086 44 12V32C44 34.2091 42.2091 36 40 36H8C5.79086 36 4 34.2091 4 32V8Z" fill="#38bdf8"/>
               <path d="M4 13H44V32C44 34.2091 42.2091 36 40 36H8C5.79086 36 4 34.2091 4 32V13Z" fill="#0284c7"/>
             </svg>
             <button type="button" class="tray-shelf-remove" data-idx="${idx}" title="Remove">&times;</button>
           </div>`
        : `<div class="tray-shelf-thumb" style="background-color: ${f.color};">
             <span style="width: 20px; height: 20px; border-radius: 50%; background: rgba(255,255,255,0.65);"></span>
             <button type="button" class="tray-shelf-remove" data-idx="${idx}" title="Remove">&times;</button>
           </div>`;

      item.innerHTML = `${thumbHTML}<span class="tray-shelf-name">${f.name}</span>`;
      trayShelf.appendChild(item);
    });

    trayShelf.querySelectorAll('.tray-shelf-remove').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const i = parseInt(btn.dataset.idx || '0', 10);
        trayFiles.splice(i, 1);
        renderTrayShelf();
      });
    });
  }

  renderTrayShelf();

  function showDropOverlay(show) {
    isDraggingFile = show;
    if (show) {
      clearTimeout(collapseTimer);
      setExpanded(true);
    }
    if (simDropOverlay) simDropOverlay.classList.toggle('hidden', !show);
    Object.values(tabPanels).forEach((p) => {
      if (p) p.style.display = show ? 'none' : '';
    });
  }

  function stageFileInTray(name, color, type) {
    if (!trayFiles.some((f) => f.name === name)) {
      trayFiles.unshift({ name, color, type });
      renderTrayShelf();
    }
    showDropOverlay(false);
    switchTab('tray');
  }

  finderItems.forEach((el) => {
    el.addEventListener('dragstart', (e) => {
      const payload = JSON.stringify({
        name: el.dataset.fileName,
        color: el.dataset.fileColor,
        type: el.dataset.fileType
      });
      if (e.dataTransfer) {
        e.dataTransfer.setData('text/plain', payload);
      }
      showDropOverlay(true);
    });

    el.addEventListener('dragend', () => {
      showDropOverlay(false);
    });

    el.addEventListener('click', () => {
      stageFileInTray(el.dataset.fileName, el.dataset.fileColor, el.dataset.fileType);
    });
  });

  if (island) {
    island.addEventListener('dragover', (e) => {
      e.preventDefault();
    });

    island.addEventListener('drop', (e) => {
      e.preventDefault();
      try {
        const raw = e.dataTransfer ? e.dataTransfer.getData('text/plain') : '';
        if (raw) {
          const parsed = JSON.parse(raw);
          stageFileInTray(parsed.name, parsed.color, parsed.type);
          return;
        }
      } catch (_) {}
      showDropOverlay(false);
      switchTab('tray');
    });
  }

  // --------------------------------------------------------------------------
  // 10. Feature Category Filter Buttons
  // --------------------------------------------------------------------------
  const filterBtns = document.querySelectorAll('.feature-filter-btn');
  const featureCards = document.querySelectorAll('.feature-card');

  filterBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      const cat = btn.dataset.filter;
      filterBtns.forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');

      featureCards.forEach((card) => {
        const match = cat === 'all' || card.dataset.category === cat;
        card.classList.toggle('hidden-card', !match);
      });
    });
  });
});
