// scripts/hooks/ultra-oracle-child/j-home.js — spec §5 J-home. READY only on the home composer with Pro selected.
(async () => {
  try {
    if (location.origin !== 'https://chatgpt.com') return 'ERR origin';
    if (location.pathname !== '/') return 'ERR not-home';
    const b = document.querySelector('button[aria-label="Select ChatGPT model"]');
    if (!b || !String(b.textContent || '').includes('Pro')) return 'ERR pro';
    return 'READY';
  } catch (e) {
    return 'ERR schema';
  }
})()
