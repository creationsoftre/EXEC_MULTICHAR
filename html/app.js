(() => {
  try {
    document.documentElement.style.background = 'transparent';
    document.documentElement.style.backgroundColor = 'transparent';
    document.body.style.background = 'transparent';
    document.body.style.backgroundColor = 'transparent';
  } catch (err) {
    // ignore
  }

  const resource = typeof GetParentResourceName === 'function'
    ? GetParentResourceName()
    : 'exec_multichar';
  const defaultStatus = 'Pick a character or create a new one.';

  const app = document.getElementById('app');
  const cardList = document.getElementById('cardList');
  const detailName = document.getElementById('detailName');
  const detailId = document.getElementById('detailId');
  const detailGender = document.getElementById('detailGender');
  const detailDob = document.getElementById('detailDob');
  const statusText = document.getElementById('statusText');

  const btnPlay = document.getElementById('btnPlay');
  const btnDelete = document.getElementById('btnDelete');
  const btnCreate = document.getElementById('btnCreate');

  const modalCreate = document.getElementById('modalCreate');
  const modalDelete = document.getElementById('modalDelete');
  const createForm = document.getElementById('createForm');
  const btnCancelCreate = document.getElementById('btnCancelCreate');
  const btnCancelDelete = document.getElementById('btnCancelDelete');
  const btnConfirmDelete = document.getElementById('btnConfirmDelete');
  const deleteMessage = document.getElementById('deleteMessage');

  const toast = document.getElementById('toast');

  function applyColors(colors) {
    if (!colors || typeof colors !== 'object') return;
    const map = {
      accent: '--accent',
      accentBorder: '--accent-border',
      accentGlow: '--accent-glow',
      danger: '--danger',
      panelBg: '--bg',
      surfaceBg: '--bg-alt',
      border: '--border',
      text: '--text',
      textMuted: '--text-muted',
      chipBg: '--chip-bg',
      chipBorder: '--chip-border',
      scrollbar: '--scrollbar',
      buttonBg: '--button-bg',
      buttonText: '--button-text',
      primaryFrom: '--primary-from',
      primaryTo: '--primary-to',
      primaryBorder: '--primary-border',
      ghostBorder: '--ghost-border',
      dangerBg: '--danger-bg',
      dangerBorder: '--danger-border',
      modalBackdrop: '--modal-backdrop',
      modalBg: '--modal-bg',
      modalBorder: '--modal-border',
      inputBg: '--input-bg',
      inputBorder: '--input-border',
      toastBg: '--toast-bg',
      toastBorder: '--toast-border',
      placeholderBorder: '--placeholder-border'
    };

    Object.entries(map).forEach(([key, cssVar]) => {
      if (colors[key]) {
        document.documentElement.style.setProperty(cssVar, colors[key]);
      }
    });
  }

  function modalsVisible() {
    return !modalCreate.classList.contains('hidden') || !modalDelete.classList.contains('hidden');
  }

  const state = {
    visible: false,
    loading: false,
    characters: [],
    selected: null,
    busy: false,
    pendingDelete: null
  };

  if (app) {
    app.setAttribute('tabindex', '-1');
    app.style.background = 'transparent';
  }

  let toastTimer = null;

  function viewportScaleFactor() {
    const widthFactor = window.innerWidth / 2560;
    const heightFactor = window.innerHeight / 1440;
    const responsive = Math.min(widthFactor, heightFactor);
    return Math.min(1, Math.max(0.54, responsive));
  }

  function applyViewportScale() {
    document.documentElement.style.setProperty('--mc-scale', viewportScaleFactor().toFixed(3));
  }

  ['resize', 'orientationchange'].forEach((eventName) => {
    window.addEventListener(eventName, applyViewportScale);
  });
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', applyViewportScale);
  }
  applyViewportScale();

  function escapeHtml(str) {
    return String(str ?? '').replace(/[&<>"']/g, (ch) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;'
    })[ch]);
  }

  function post(action, data) {
    return fetch(`https://${resource}/${action}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data || {})
    }).then((res) => res.json().catch(() => ({}))).catch(() => ({}));
  }

  function setStatus(text) {
    statusText.textContent = text || defaultStatus;
  }

  function toggleApp(on) {
    state.visible = !!on;
    app.classList.toggle('hidden', !state.visible);
    if (state.visible && app) {
      requestAnimationFrame(() => {
        try {
          app.focus();
        } catch (err) {
          // ignore focus errors
        }
      });
    }
    if (!state.visible) {
      closeCreateModal();
      closeDeleteModal();
      setBusy(false);
      state.characters = [];
      state.selected = null;
      renderCards();
      renderDetails();
      updateButtons();
      setStatus(defaultStatus);
    }
  }

  function setLoading(on) {
    state.loading = !!on;
    renderCards();
  }

  function setBusy(on) {
    state.busy = !!on;
    app.classList.toggle('busy', state.busy);
    updateButtons();
  }

  function normalizeCharacters(list) {
    return (Array.isArray(list) ? list : []).map((c) => {
      const first = c.firstname || '';
      const last = c.lastname || '';
      const name = c.name || `${first} ${last}`.trim();
      return {
        citizenid: c.citizenid,
        firstname: first,
        lastname: last,
        name,
        gender: c.gender || '',
        dob: c.dob || ''
      };
    });
  }

  function findCharacter(id) {
    return state.characters.find((c) => c.citizenid === id);
  }

  function applySelection(id, notify) {
    const next = id || null;
    const changed = state.selected !== next;
    state.selected = next;
    renderCards();
    renderDetails();
    updateButtons();
    if (notify && changed && state.selected) {
      post('setSelection', { citizenid: state.selected });
    }
  }

  function setCharacters(list, selectedId, notify) {
    state.characters = normalizeCharacters(list);
    let next = selectedId || state.selected;
    if (next && !findCharacter(next)) {
      next = state.characters.length ? state.characters[0].citizenid : null;
    }
    applySelection(next, notify);
  }

  function renderCards() {
    cardList.innerHTML = '';

    if (state.loading) {
      const placeholder = document.createElement('div');
      placeholder.className = 'cards__placeholder';
      placeholder.textContent = 'Loading characters...';
      cardList.appendChild(placeholder);
      return;
    }

    if (!state.characters.length) {
      const empty = document.createElement('div');
      empty.className = 'card card--empty';
      empty.innerHTML = '<h3>No characters yet</h3><p>Create one to get started.</p>';
      cardList.appendChild(empty);
      return;
    }

    state.characters.forEach((char) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'card' + (char.citizenid === state.selected ? ' card--selected' : '');
      const genderText = (char.gender || '--').toUpperCase();
      const dobText = char.dob || '--';
      const idText = char.citizenid || '--';
      btn.innerHTML = `
        <h3 class="card__name">${escapeHtml(char.name || 'Unknown')}</h3>
        <div class="card__meta">
          <span><span>ID</span><span>${escapeHtml(idText)}</span></span>
          <span><span>Gender</span><span>${escapeHtml(genderText)}</span></span>
          <span><span>DOB</span><span>${escapeHtml(dobText)}</span></span>
        </div>
      `;
      btn.addEventListener('click', () => {
        if (state.busy) return;
        applySelection(char.citizenid, true);
      });
      cardList.appendChild(btn);
    });
  }

  function renderDetails() {
    const char = state.selected ? findCharacter(state.selected) : null;
    if (!char) {
      detailName.textContent = 'No Character Selected';
      detailId.textContent = '--';
      detailGender.textContent = '--';
      detailDob.textContent = '--';
      return;
    }
    detailName.textContent = char.name || 'Unknown';
    detailId.textContent = char.citizenid || '--';
    detailGender.textContent = (char.gender || '--').toUpperCase();
    detailDob.textContent = char.dob || '--';
  }

  function updateButtons() {
    const hasSelection = !!state.selected && !!findCharacter(state.selected);
    btnPlay.disabled = !hasSelection || state.busy;
    btnDelete.disabled = !hasSelection || state.busy;
    btnCreate.disabled = state.busy;
  }

  function showToast(message, duration) {
    if (!message) return;
    const time = typeof duration === 'number' ? duration : 2400;
    toast.textContent = message;
    toast.classList.remove('hidden');
    requestAnimationFrame(() => toast.classList.add('show'));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toast.classList.remove('show');
      setTimeout(() => toast.classList.add('hidden'), 180);
    }, time);
  }

  function openCreateModal() {
    if (state.busy) return;
    createForm.reset();
    const firstInput = createForm.elements.firstname;
    const lastInput = createForm.elements.lastname;
    const dobInput = createForm.elements.dob;
    if (firstInput) firstInput.value = '';
    if (lastInput) lastInput.value = '';
    if (dobInput && !dobInput.value) dobInput.value = '2000-01-01';
    modalCreate.classList.remove('hidden');
  }

  function closeCreateModal() {
    modalCreate.classList.add('hidden');
  }

  function openDeleteModal() {
    if (state.busy) return;
    const char = state.selected ? findCharacter(state.selected) : null;
    if (!char) return;
    state.pendingDelete = char.citizenid;
    deleteMessage.textContent = `Delete ${char.name || 'this character'}? This cannot be undone.`;
    modalDelete.classList.remove('hidden');
  }

  function closeDeleteModal() {
    modalDelete.classList.add('hidden');
    state.pendingDelete = null;
  }

  createForm.addEventListener('submit', (ev) => {
    ev.preventDefault();
    if (state.busy) return;
    const data = new FormData(createForm);
    const firstname = (data.get('firstname') || '').trim();
    const lastname = (data.get('lastname') || '').trim();
    const gender = (data.get('gender') || 'male').toLowerCase();
    const dob = (data.get('dob') || '2000-01-01').trim();
    if (!firstname || !lastname) {
      showToast('Please enter a first and last name.');
      return;
    }
    setBusy(true);
    post('createCharacter', { firstname, lastname, gender, dob }).then((res) => {
      if (!res || !res.ok) {
        setBusy(false);
        showToast(res && res.error ? res.error : 'Unable to create character.');
        return;
      }
      closeCreateModal();
      showToast('Starting character creation...');
    });
  });

  btnCreate.addEventListener('click', openCreateModal);
  btnCancelCreate.addEventListener('click', closeCreateModal);

  btnDelete.addEventListener('click', openDeleteModal);
  btnCancelDelete.addEventListener('click', closeDeleteModal);
  btnConfirmDelete.addEventListener('click', () => {
    if (state.busy || !state.pendingDelete) return;
    setBusy(true);
    post('deleteCharacter', { citizenid: state.pendingDelete }).then((res) => {
      if (!res || !res.ok) {
        setBusy(false);
        showToast(res && res.error ? res.error : 'Delete failed.');
        return;
      }
      showToast('Character deleted.');
      closeDeleteModal();
    });
  });

  btnPlay.addEventListener('click', () => {
    if (state.busy || !state.selected) return;
    setBusy(true);
    post('playCharacter', { citizenid: state.selected }).then((res) => {
      if (!res || !res.ok) {
        setBusy(false);
        showToast(res && res.error ? res.error : 'Unable to load character.');
      }
    });
  });

  window.addEventListener('wheel', (ev) => {
    if (!state.visible || modalsVisible()) return;
    if (ev.target && ev.target.closest && ev.target.closest('input, select, textarea')) return;
    ev.preventDefault();
    const direction = ev.deltaY < 0 ? 'in' : 'out';
    const magnitude = Math.min(3, Math.max(0.3, Math.abs(ev.deltaY) / 150));
    post('cameraZoom', { direction, amount: magnitude });
  }, { passive: false });

  window.addEventListener('keydown', (ev) => {
    if (!state.visible) return;
    const key = ev.key || '';
    const lower = key.toLowerCase();
    const target = ev.target;
    const tag = target && target.tagName ? target.tagName.toLowerCase() : '';
    const typing = tag === 'input' || tag === 'textarea' || tag === 'select' || (target && target.isContentEditable);

    if (!typing && !modalsVisible()) {
      if (lower === 'a' || key === 'ArrowLeft') {
        ev.preventDefault();
        post('cameraPan', { direction: 'left', amount: ev.repeat ? 0.6 : 1 });
        return;
      }
      if (lower === 'd' || key === 'ArrowRight') {
        ev.preventDefault();
        post('cameraPan', { direction: 'right', amount: ev.repeat ? 0.6 : 1 });
        return;
      }
      if (lower === 'q') {
        ev.preventDefault();
        post('cameraCycle', { direction: 'prev' });
        return;
      }
      if (lower === 'e') {
        ev.preventDefault();
        post('cameraCycle', { direction: 'next' });
        return;
      }
      if (lower === 'z') {
        ev.preventDefault();
        post('cameraPose', { delta: -1 });
        return;
      }
      if (lower === 'x') {
        ev.preventDefault();
        post('cameraPose', { delta: 1 });
        return;
      }
    }

    if (key === 'Escape') {
      if (!modalDelete.classList.contains('hidden')) {
        closeDeleteModal();
        return;
      }
      if (!modalCreate.classList.contains('hidden')) {
        closeCreateModal();
        return;
      }
      post('requestClose', {});
    }
  });

  window.addEventListener('message', (event) => {
    const data = event.data || {};
    switch (data.action) {
      case 'open':
        applyColors(data.colors);
        toggleApp(true);
        setLoading(!!data.loading);
        setCharacters(data.characters || [], data.selected, false);
        setStatus(data.status || defaultStatus);
        break;
      case 'updateCharacters':
        setCharacters(data.characters || [], data.selected, !!data.preview);
        if (typeof data.status === 'string') setStatus(data.status);
        break;
      case 'select':
        applySelection(data.citizenid, false);
        break;
      case 'busy':
        setBusy(!!data.value);
        if (typeof data.status === 'string') setStatus(data.status);
        break;
      case 'loading':
        setLoading(!!data.value);
        break;
      case 'status':
        setStatus(data.text);
        break;
      case 'toast':
        showToast(data.text, data.duration);
        break;
      case 'close':
        toggleApp(false);
        break;
      default:
        break;
    }
  });
})();
