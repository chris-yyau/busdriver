// scripts/hooks/ultra-oracle-child/j-attached.js — spec §5 J-attached. Polls the composer form for up to 38 s.
(async () => {
  try {
    if (location.origin !== 'https://chatgpt.com') return 'ERR origin';
    const name = 'uora-__UORA_TAG__.txt';
    const end = Date.now() + 38000;
    for (;;) {
      const ed = document.querySelector('.ProseMirror');
      const form = ed && ed.closest('form');
      if (form) {
        const labels = Array.from(form.querySelectorAll('button[aria-label^="Remove "]'), (b) => b.getAttribute('aria-label'));
        if (labels.some((l) => l !== 'Remove ' + name)) return 'ERR upload';
        const send = form.querySelector('button[aria-label="Send"]');
        if (labels.includes('Remove ' + name) && send && !send.disabled && !form.querySelector('[role=progressbar]')) return 'ATTACHED';
      }
      if (Date.now() >= end) return 'PENDING';
      await new Promise((r) => setTimeout(r, 500));
    }
  } catch (e) {
    return 'ERR schema';
  }
})()
