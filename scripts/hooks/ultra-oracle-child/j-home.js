// scripts/hooks/ultra-oracle-child/j-home.js — spec §5 J-home. READY only on the home composer with Pro selected.
(async () => {
  try {
    if (location.origin !== 'https://chatgpt.com') return 'ERR origin';
    // Right after navigate the model button has not rendered yet (#1086), so poll before deciding.
    const end = Date.now() + 10000;
    for (;;) {
      if (location.pathname !== '/') return 'ERR not-home';
      const b = document.querySelector('button[aria-label="Select ChatGPT model"]');
      if (b && String(b.textContent || '').includes('Pro')) return 'READY';
      if (Date.now() >= end) return 'ERR pro';
      await new Promise((r) => setTimeout(r, 250));
    }
  } catch (e) {
    return 'ERR schema';
  }
})()
